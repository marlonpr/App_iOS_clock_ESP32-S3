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
    typealias ConnectionFactory = (IPv4Address, NWEndpoint.Port) -> TCPConnection

    static let defaultPort: UInt16 = 5000
    static let frameDelimiter: UInt8 = 0x5C

    var onStateChange: StateHandler?
    var onFrameReceived: FrameHandler?

    private let queue = DispatchQueue(label: "ESP32Controller.TCPClient")
    private let connectionFactory: ConnectionFactory
    private var connection: TCPConnection?
    private var activeConnectionID: UUID?
    private var receiveBuffer: [UInt8] = []

    init(connectionFactory: @escaping ConnectionFactory = { address, port in
        NWConnection(host: .ipv4(address), port: port, using: .tcp)
    }) {
        self.connectionFactory = connectionFactory
    }

    func connect(host: String, port: UInt16) {
        disconnect()

        guard let address = IPv4Address(host) else {
            onStateChange?(.failed("Invalid IPv4 address"))
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange?(.failed("Invalid TCP port"))
            return
        }

        let connectionID = UUID()
        let connection = connectionFactory(address, nwPort)
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
        receiveBuffer.removeAll(keepingCapacity: true)
        activeConnectionID = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
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
        case let .failed(error):
            onStateChange?(.failed(error.localizedDescription))
            connection.cancel()
            if isActiveConnection(connectionID, connection: connection) {
                self.connection = nil
                activeConnectionID = nil
            }
        case .cancelled:
            onStateChange?(.disconnected)
            if isActiveConnection(connectionID, connection: connection) {
                self.connection = nil
                activeConnectionID = nil
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
            onFrameReceived?(frame)
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
        receiveBuffer.removeAll(keepingCapacity: true)
        self.connection = nil
        activeConnectionID = nil
        onStateChange?(state)
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
