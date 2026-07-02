//
//  ESP32TCPClient.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation
import Network

protocol TCPConnection: AnyObject {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    )
    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    )
}

extension NWConnection: TCPConnection {}

private struct ConnectionCallbackContext: @unchecked Sendable {
    let connectionID: UUID
    weak var connection: TCPConnection?
}

@MainActor
final class ESP32TCPClient {
    typealias StateHandler = (TCPConnectionState) -> Void
    typealias FrameHandler = ([UInt8]) -> Void
    typealias HostConnectionFactory = (IPv4Address, NWEndpoint.Port) -> TCPConnection
    typealias EndpointConnectionFactory = (NWEndpoint) -> TCPConnection
    typealias HeartbeatScheduler = (TimeInterval, @escaping @Sendable () -> Void) -> CancellableTask

    nonisolated static let defaultPort: UInt16 = 5000
    nonisolated static let frameDelimiter: UInt8 = 0x5C
    nonisolated static let reservedBoardID: UInt8 = frameDelimiter
    nonisolated static let defaultHeartbeatConfiguration = HeartbeatConfiguration(
        interval: 12,
        ackTimeout: 4,
        maximumConsecutiveMisses: 3
    )

    var onStateChange: StateHandler?
    var onFrameReceived: FrameHandler?
    var onConnectionHealthChange: ((ConnectionHealthState) -> Void)?
    var isHeartbeatDebugLoggingEnabled = false

    private let queue = DispatchQueue(label: "ESP32Controller.TCPClient")
    private let hostConnectionFactory: HostConnectionFactory
    private let endpointConnectionFactory: EndpointConnectionFactory
    private let heartbeatConfiguration: HeartbeatConfiguration
    private let heartbeatScheduler: HeartbeatScheduler
    private let heartbeatACKTimeoutScheduler: HeartbeatScheduler
    private var connection: TCPConnection?
    private var activeConnectionID: UUID?
    private var receiveBuffer: [UInt8] = []
    private var boardID: UInt8?
    private var heartbeatSequence: UInt8 = 0
    private var awaitingHeartbeatSequence: UInt8?
    private var missedHeartbeatCount = 0
    private var heartbeatLoopTask: CancellableTask?
    private var heartbeatACKTimeoutTask: CancellableTask?
    private var foregroundValidationTimeoutTask: CancellableTask?
    private var foregroundValidationSequence: UInt8?
    private var foregroundValidationCompletion: ((Bool) -> Void)?
    private var isHeartbeatEnabledForActiveConnection = false

    init(
        connectionFactory: @escaping HostConnectionFactory = { address, port in
            NWConnection(host: .ipv4(address), port: port, using: ESP32TCPClient.tcpParameters())
        },
        endpointConnectionFactory: @escaping EndpointConnectionFactory = { endpoint in
            NWConnection(to: endpoint, using: ESP32TCPClient.tcpParameters())
        },
        heartbeatConfiguration: HeartbeatConfiguration = ESP32TCPClient.defaultHeartbeatConfiguration,
        heartbeatScheduler: @escaping HeartbeatScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return TCPDispatchWorkItemCancellable(workItem: workItem)
        },
        heartbeatACKTimeoutScheduler: @escaping HeartbeatScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return TCPDispatchWorkItemCancellable(workItem: workItem)
        }
    ) {
        self.hostConnectionFactory = connectionFactory
        self.endpointConnectionFactory = endpointConnectionFactory
        self.heartbeatConfiguration = heartbeatConfiguration
        self.heartbeatScheduler = heartbeatScheduler
        self.heartbeatACKTimeoutScheduler = heartbeatACKTimeoutScheduler
    }

    func connect(host: String, port: UInt16, boardID: UInt8?) {
        disconnect()
        let heartbeatBoardID = Self.validHeartbeatBoardID(from: boardID)
        self.boardID = heartbeatBoardID
        isHeartbeatEnabledForActiveConnection = heartbeatBoardID != nil

        guard let address = IPv4Address(host) else {
            onStateChange?(.failed("Invalid IPv4 address"))
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange?(.failed("Invalid TCP port"))
            return
        }

        startConnection(hostConnectionFactory(address, nwPort))
    }

    func connect(to endpoint: NWEndpoint, boardID: UInt8?) {
        disconnect()
        let heartbeatBoardID = Self.validHeartbeatBoardID(from: boardID)
        self.boardID = heartbeatBoardID
        isHeartbeatEnabledForActiveConnection = heartbeatBoardID != nil
        startConnection(endpointConnectionFactory(endpoint))
    }

    private func startConnection(_ connection: TCPConnection) {
        let connectionID = UUID()
        self.connection = connection
        activeConnectionID = connectionID
        receiveBuffer.removeAll(keepingCapacity: true)
        onStateChange?(.connecting)

        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        connection.stateUpdateHandler = { [weak self, callbackContext] state in
            Task { @MainActor [weak self, callbackContext] in
                guard let connection = callbackContext.connection else {
                    return
                }

                self?.handleStateUpdate(state, for: callbackContext.connectionID, connection: connection)
            }
        }

        connection.start(queue: queue)
    }

    func disconnect() {
        stopHeartbeat()
        boardID = nil
        isHeartbeatEnabledForActiveConnection = false
        receiveBuffer.removeAll(keepingCapacity: true)
        activeConnectionID = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        publishHealth(.idle)
        onStateChange?(.disconnected)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard let connection else {
            completion(TCPClientError.notConnected)
            return
        }

        guard let connectionID = activeConnectionID else {
            completion(TCPClientError.notConnected)
            return
        }

        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection)
                else {
                    return
                }

                completion(error)
            }
        })
    }

    func validateActiveConnectionWithHeartbeat(
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            let connection,
            let connectionID = activeConnectionID,
            isActiveConnection(connectionID, connection: connection),
            isHeartbeatEnabledForActiveConnection,
            let boardID
        else {
            completion(false)
            return
        }

        stopHeartbeat()

        let sequence = heartbeatSequence
        heartbeatSequence &+= 1

        guard let frame = Self.heartbeatRequestFrame(boardID: boardID, sequence: sequence) else {
            completion(false)
            return
        }

        awaitingHeartbeatSequence = sequence
        foregroundValidationSequence = sequence
        foregroundValidationCompletion = completion
        publishHealth(.waitingForACK)
        scheduleForegroundValidationTimeout(
            for: connectionID,
            connection: connection,
            sequence: sequence,
            timeout: timeout
        )

        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        connection.send(content: Data(frame), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection),
                    self.foregroundValidationSequence == sequence
                else {
                    return
                }

                if error != nil {
                    self.completeForegroundValidation(success: false)
                }
            }
        })
    }

    private func handleStateUpdate(
        _ state: NWConnection.State,
        for connectionID: UUID,
        connection: TCPConnection
    ) {
        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        switch state {
        case .setup, .preparing, .waiting:
            onStateChange?(.connecting)
        case .ready:
            onStateChange?(.connected)
            receiveNextChunk(for: connectionID, connection: connection)
            if isHeartbeatEnabledForActiveConnection, boardID != nil {
                startHeartbeat(for: connectionID, connection: connection)
            } else {
                publishHealth(.idle)
            }
        case let .failed(error):
            stopHeartbeat()
            onStateChange?(.failed(error.localizedDescription))
            connection.cancel()
            if isActiveConnection(connectionID, connection: connection) {
                self.connection = nil
                activeConnectionID = nil
                boardID = nil
                isHeartbeatEnabledForActiveConnection = false
            }
        case .cancelled:
            stopHeartbeat()
            onStateChange?(.disconnected)
            if isActiveConnection(connectionID, connection: connection) {
                self.connection = nil
                activeConnectionID = nil
                boardID = nil
                isHeartbeatEnabledForActiveConnection = false
            }
        @unknown default:
            onStateChange?(.failed("Unknown connection state"))
        }
    }

    private func receiveNextChunk(for connectionID: UUID, connection: TCPConnection) {
        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, callbackContext] data, _, isComplete, error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection)
                else {
                    return
                }

                self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    for: callbackContext.connectionID,
                    connection: connection
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        for connectionID: UUID,
        connection: TCPConnection
    ) {
        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        if let data, !data.isEmpty {
            receiveBuffer.append(contentsOf: data)
            emitDelimitedFrames()
        }

        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        if let error {
            terminateActiveConnection(
                connectionID,
                connection: connection,
                state: .failed(error.localizedDescription)
            )
            return
        }

        if isComplete {
            terminateActiveConnection(
                connectionID,
                connection: connection,
                state: .disconnected
            )
            return
        }

        receiveNextChunk(for: connectionID, connection: connection)
    }

    private func emitDelimitedFrames() {
        while let delimiterIndex = receiveBuffer.firstIndex(of: Self.frameDelimiter) {
            let frame = Array(receiveBuffer[...delimiterIndex])
            receiveBuffer.removeSubrange(...delimiterIndex)
            if !handleHeartbeatACKFrame(frame) {
                onFrameReceived?(frame)
            }
        }
    }

    private func isActiveConnection(_ connectionID: UUID, connection: TCPConnection) -> Bool {
        activeConnectionID == connectionID && self.connection === connection
    }

    private func terminateActiveConnection(
        _ connectionID: UUID,
        connection: TCPConnection,
        state: TCPConnectionState
    ) {
        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        connection.stateUpdateHandler = nil
        connection.cancel()
        stopHeartbeat()
        receiveBuffer.removeAll(keepingCapacity: true)
        self.connection = nil
        activeConnectionID = nil
        boardID = nil
        isHeartbeatEnabledForActiveConnection = false
        onStateChange?(state)
    }

    private func startHeartbeat(for connectionID: UUID, connection: TCPConnection) {
        guard isActiveConnection(connectionID, connection: connection) else {
            return
        }

        stopHeartbeat()
        missedHeartbeatCount = 0
        awaitingHeartbeatSequence = nil
        publishHealth(.healthy)
        scheduleHeartbeat(after: 1, connectionID: connectionID, connection: connection)
    }

    private func scheduleHeartbeat(after delay: TimeInterval, connectionID: UUID, connection: TCPConnection) {
        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        heartbeatLoopTask = heartbeatScheduler(delay) { [weak self, callbackContext] in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection)
                else {
                    return
                }

                self.heartbeatLoopTask = nil
                self.sendHeartbeatIfNeeded(for: callbackContext.connectionID, connection: connection)
                if self.isActiveConnection(callbackContext.connectionID, connection: connection) {
                    self.scheduleHeartbeat(
                        after: self.heartbeatConfiguration.interval,
                        connectionID: callbackContext.connectionID,
                        connection: connection
                    )
                }
            }
        }
    }

    private func sendHeartbeatIfNeeded(for connectionID: UUID, connection: TCPConnection) {
        guard isActiveConnection(connectionID, connection: connection), awaitingHeartbeatSequence == nil else {
            return
        }

        let sequence = heartbeatSequence
        heartbeatSequence &+= 1
        guard let boardID else {
            return
        }

        guard let frame = Self.heartbeatRequestFrame(boardID: boardID, sequence: sequence) else {
            awaitingHeartbeatSequence = nil
            publishHealth(.idle)
            return
        }

        awaitingHeartbeatSequence = sequence
        publishHealth(.waitingForACK)
        scheduleHeartbeatACKTimeout(for: connectionID, connection: connection, sequence: sequence)

        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        connection.send(content: Data(frame), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection)
                else {
                    return
                }

                if let error {
                    self.terminateActiveConnection(
                        callbackContext.connectionID,
                        connection: connection,
                        state: .failed(error.localizedDescription)
                    )
                }
            }
        })
    }

    private func scheduleHeartbeatACKTimeout(
        for connectionID: UUID,
        connection: TCPConnection,
        sequence: UInt8
    ) {
        heartbeatACKTimeoutTask?.cancel()
        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        heartbeatACKTimeoutTask = heartbeatACKTimeoutScheduler(heartbeatConfiguration.ackTimeout) { [weak self, callbackContext] in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection),
                    self.awaitingHeartbeatSequence == sequence
                else {
                    return
                }

                self.heartbeatACKTimeoutTask = nil
                self.awaitingHeartbeatSequence = nil
                self.missedHeartbeatCount += 1

                if self.missedHeartbeatCount >= self.heartbeatConfiguration.maximumConsecutiveMisses {
                    self.publishHealth(.timedOut)
                    self.terminateActiveConnection(
                        callbackContext.connectionID,
                        connection: connection,
                        state: .failed("Heartbeat timed out")
                    )
                } else {
                    self.publishHealth(.degraded(missedCount: self.missedHeartbeatCount))
                }
            }
        }
    }

    private func scheduleForegroundValidationTimeout(
        for connectionID: UUID,
        connection: TCPConnection,
        sequence: UInt8,
        timeout: TimeInterval
    ) {
        foregroundValidationTimeoutTask?.cancel()
        let callbackContext = ConnectionCallbackContext(connectionID: connectionID, connection: connection)
        foregroundValidationTimeoutTask = heartbeatACKTimeoutScheduler(timeout) { [weak self, callbackContext] in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActiveConnection(callbackContext.connectionID, connection: connection),
                    self.foregroundValidationSequence == sequence,
                    self.awaitingHeartbeatSequence == sequence
                else {
                    return
                }

                self.completeForegroundValidation(success: false)
            }
        }
    }

    private func handleHeartbeatACKFrame(_ frame: [UInt8]) -> Bool {
        guard
            isHeartbeatEnabledForActiveConnection,
            let boardID,
            let pendingSequence = awaitingHeartbeatSequence,
            Self.isHeartbeatACKCandidate(frame),
            frame[3] == boardID,
            let sequence = Self.decodeHexByte(high: frame[6], low: frame[7]),
            pendingSequence == sequence
        else {
            return false
        }

        heartbeatACKTimeoutTask?.cancel()
        heartbeatACKTimeoutTask = nil
        foregroundValidationTimeoutTask?.cancel()
        foregroundValidationTimeoutTask = nil
        awaitingHeartbeatSequence = nil
        missedHeartbeatCount = 0
        publishHealth(.healthy)

        if foregroundValidationSequence == sequence {
            foregroundValidationSequence = nil
            let completion = foregroundValidationCompletion
            foregroundValidationCompletion = nil
            if
                let activeConnectionID,
                let connection,
                isActiveConnection(activeConnectionID, connection: connection)
            {
                startHeartbeat(for: activeConnectionID, connection: connection)
            }
            completion?(true)
        }

        return true
    }

    private func completeForegroundValidation(success: Bool) {
        guard foregroundValidationCompletion != nil else {
            return
        }

        foregroundValidationTimeoutTask?.cancel()
        foregroundValidationTimeoutTask = nil
        foregroundValidationSequence = nil
        awaitingHeartbeatSequence = nil
        let completion = foregroundValidationCompletion
        foregroundValidationCompletion = nil
        completion?(success)
    }

    private func stopHeartbeat() {
        heartbeatLoopTask?.cancel()
        heartbeatLoopTask = nil
        heartbeatACKTimeoutTask?.cancel()
        heartbeatACKTimeoutTask = nil
        foregroundValidationTimeoutTask?.cancel()
        foregroundValidationTimeoutTask = nil
        foregroundValidationSequence = nil
        foregroundValidationCompletion = nil
        awaitingHeartbeatSequence = nil
        missedHeartbeatCount = 0
    }

    private func publishHealth(_ health: ConnectionHealthState) {
        onConnectionHealthChange?(health)
    }

    static func heartbeatRequestFrame(boardID: UInt8, sequence: UInt8) -> [UInt8]? {
        guard boardID != reservedBoardID else {
            return nil
        }

        let hex = hexASCII(for: sequence)
        return [0x2F, 0x54, 0x41, boardID, 0x48, 0x42, hex.high, hex.low, frameDelimiter]
    }

    private static func validHeartbeatBoardID(from boardID: UInt8?) -> UInt8? {
        guard let boardID, boardID != reservedBoardID else {
            return nil
        }

        return boardID
    }

    static func heartbeatACKFrame(boardID: UInt8, sequence: UInt8) -> [UInt8] {
        let hex = hexASCII(for: sequence)
        return [0x2F, 0x74, 0x61, boardID, 0x68, 0x62, hex.high, hex.low, frameDelimiter]
    }

    private static func isHeartbeatACKCandidate(_ frame: [UInt8]) -> Bool {
        frame.count == 9 &&
            frame[0] == 0x2F &&
            frame[1] == 0x74 &&
            frame[2] == 0x61 &&
            frame[4] == 0x68 &&
            frame[5] == 0x62 &&
            decodeHexByte(high: frame[6], low: frame[7]) != nil &&
            frame[8] == frameDelimiter
    }

    private static func hexASCII(for byte: UInt8) -> (high: UInt8, low: UInt8) {
        let digits = Array("0123456789ABCDEF".utf8)
        return (digits[Int(byte >> 4)], digits[Int(byte & 0x0F)])
    }

    private static func decodeHexByte(high: UInt8, low: UInt8) -> UInt8? {
        guard let highNibble = hexNibble(high), let lowNibble = hexNibble(low) else {
            return nil
        }

        return (highNibble << 4) | lowNibble
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            byte - 0x30
        case 0x41...0x46:
            byte - 0x41 + 10
        case 0x61...0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }

    private nonisolated static func tcpParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcpOptions)
    }
}

struct HeartbeatConfiguration: Equatable {
    let interval: TimeInterval
    let ackTimeout: TimeInterval
    let maximumConsecutiveMisses: Int
}

enum ConnectionHealthState: Equatable {
    case idle
    case healthy
    case waitingForACK
    case degraded(missedCount: Int)
    case timedOut
}

private struct TCPDispatchWorkItemCancellable: CancellableTask {
    let workItem: DispatchWorkItem

    func cancel() {
        workItem.cancel()
    }
}

enum TCPClientError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "TCP client is not connected"
        }
    }
}
