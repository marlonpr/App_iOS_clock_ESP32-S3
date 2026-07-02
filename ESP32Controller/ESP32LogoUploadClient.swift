//
//  ESP32LogoUploadClient.swift
//  ESP32Controller
//

import Foundation
import Network

enum LogoUploadState: Equatable {
    case idle
    case converting
    case ready
    case connecting
    case waitingForReady
    case uploading(progress: Double)
    case waitingForConfirmation
    case succeeded
    case failed(String)

    var isUploadInProgress: Bool {
        switch self {
        case .connecting, .waitingForReady, .uploading, .waitingForConfirmation:
            true
        case .idle, .converting, .ready, .succeeded, .failed:
            false
        }
    }
}

struct LogoUploadTimeouts: Equatable {
    let connection: TimeInterval
    let ready: TimeInterval
    let payload: TimeInterval
    let confirmation: TimeInterval

    static let `default` = LogoUploadTimeouts(
        connection: 4,
        ready: 4,
        payload: 8,
        confirmation: 4
    )
}

private struct LogoUploadCallbackContext: @unchecked Sendable {
    let operationID: UUID
    weak var connection: TCPConnection?
}

@MainActor
final class ESP32LogoUploadClient {
    typealias ConnectionFactory = (NWEndpoint) -> TCPConnection
    typealias TimeoutScheduler = (TimeInterval, @escaping @Sendable () -> Void) -> CancellableTask
    typealias StateHandler = (UUID, LogoUploadState) -> Void
    typealias CompletionHandler = (UUID, Result<Void, ESP32LogoUploadError>) -> Void

    static let payloadChunkLength = 1024
    static let responseLineLimit = 128

    private enum TimeoutPhase {
        case connection
        case ready
        case payload
        case confirmation
    }

    private let queue = DispatchQueue(label: "ESP32Controller.LogoUpload")
    private let connectionFactory: ConnectionFactory
    private let timeoutScheduler: TimeoutScheduler
    private let timeouts: LogoUploadTimeouts
    private var connection: TCPConnection?
    private var activeOperationID: UUID?
    private var receiveBuffer = Data()
    private var timeoutTask: CancellableTask?
    private var stateHandler: StateHandler?
    private var completionHandler: CompletionHandler?

    init(
        connectionFactory: @escaping ConnectionFactory = { endpoint in
            NWConnection(to: endpoint, using: .tcp)
        },
        timeoutScheduler: @escaping TimeoutScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return LogoUploadDispatchWorkItemCancellable(workItem: workItem)
        },
        timeouts: LogoUploadTimeouts = .default
    ) {
        self.connectionFactory = connectionFactory
        self.timeoutScheduler = timeoutScheduler
        self.timeouts = timeouts
    }

    func upload(
        file: LogoFile,
        to endpoint: NWEndpoint,
        operationID: UUID,
        onStateChange: @escaping StateHandler,
        onCompletion: @escaping CompletionHandler
    ) {
        cancel()

        guard file.header.count == LogoFileFormat.headerLength else {
            onCompletion(operationID, .failure(.invalidHeaderLength(file.header.count)))
            return
        }

        guard file.payload.count == LogoFileFormat.payloadLength else {
            onCompletion(operationID, .failure(.invalidPayloadLength(file.payload.count)))
            return
        }

        let connection = connectionFactory(endpoint)
        self.connection = connection
        activeOperationID = operationID
        receiveBuffer.removeAll(keepingCapacity: true)
        stateHandler = onStateChange
        completionHandler = onCompletion

        publish(.connecting, operationID: operationID)
        scheduleTimeout(.connection, operationID: operationID)

        let callbackContext = LogoUploadCallbackContext(operationID: operationID, connection: connection)
        connection.stateUpdateHandler = { [weak self, callbackContext] state in
            Task { @MainActor [weak self, callbackContext] in
                guard let connection = callbackContext.connection else {
                    return
                }

                self?.handleConnectionState(
                    state,
                    operationID: callbackContext.operationID,
                    connection: connection,
                    file: file
                )
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        let connectionToCancel = connection
        timeoutTask?.cancel()
        timeoutTask = nil
        connectionToCancel?.stateUpdateHandler = nil
        connectionToCancel?.cancel()
        connection = nil
        activeOperationID = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        stateHandler = nil
        completionHandler = nil
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        operationID: UUID,
        connection: TCPConnection,
        file: LogoFile
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        switch state {
        case .setup, .preparing, .waiting:
            publish(.connecting, operationID: operationID)
        case .ready:
            timeoutTask?.cancel()
            timeoutTask = nil
            sendHeader(file.header, payload: file.payload, operationID: operationID, connection: connection)
        case let .failed(error):
            fail(.network(error.localizedDescription), operationID: operationID, connection: connection)
        case .cancelled:
            fail(.cancelled, operationID: operationID, connection: connection)
        @unknown default:
            fail(.network("Unknown connection state"), operationID: operationID, connection: connection)
        }
    }

    private func sendHeader(
        _ header: Data,
        payload: Data,
        operationID: UUID,
        connection: TCPConnection
    ) {
        publish(.waitingForReady, operationID: operationID)
        scheduleTimeout(.ready, operationID: operationID)

        let callbackContext = LogoUploadCallbackContext(operationID: operationID, connection: connection)
        connection.send(content: header, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self, callbackContext] error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let connection = callbackContext.connection,
                    self?.isActive(operationID: callbackContext.operationID, connection: connection) == true
                else {
                    return
                }

                if let error {
                    self?.fail(.network(error.localizedDescription), operationID: callbackContext.operationID, connection: connection)
                    return
                }

                self?.receiveLine(operationID: callbackContext.operationID, connection: connection) { [weak self] line in
                    self?.handleReadyLine(line, payload: payload, operationID: callbackContext.operationID, connection: connection)
                }
            }
        })
    }

    private func handleReadyLine(
        _ line: String,
        payload: Data,
        operationID: UUID,
        connection: TCPConnection
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        guard line == "READY" else {
            fail(responseError(for: line, expected: "READY"), operationID: operationID, connection: connection)
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        publish(.uploading(progress: 0), operationID: operationID)
        scheduleTimeout(.payload, operationID: operationID)
        sendPayloadChunk(payload, offset: 0, operationID: operationID, connection: connection)
    }

    private func sendPayloadChunk(
        _ payload: Data,
        offset: Int,
        operationID: UUID,
        connection: TCPConnection
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        guard offset < payload.count else {
            timeoutTask?.cancel()
            timeoutTask = nil
            publish(.waitingForConfirmation, operationID: operationID)
            scheduleTimeout(.confirmation, operationID: operationID)
            receiveLine(operationID: operationID, connection: connection) { [weak self] line in
                self?.handleConfirmationLine(line, operationID: operationID, connection: connection)
            }
            return
        }

        let nextOffset = min(offset + Self.payloadChunkLength, payload.count)
        let chunk = payload.subdata(in: offset..<nextOffset)
        let callbackContext = LogoUploadCallbackContext(operationID: operationID, connection: connection)
        connection.send(content: chunk, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self, callbackContext] error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActive(operationID: callbackContext.operationID, connection: connection)
                else {
                    return
                }

                if let error {
                    self.fail(.network(error.localizedDescription), operationID: callbackContext.operationID, connection: connection)
                    return
                }

                self.publish(
                    .uploading(progress: Double(nextOffset) / Double(payload.count)),
                    operationID: callbackContext.operationID
                )
                self.sendPayloadChunk(
                    payload,
                    offset: nextOffset,
                    operationID: callbackContext.operationID,
                    connection: connection
                )
            }
        })
    }

    private func handleConfirmationLine(
        _ line: String,
        operationID: UUID,
        connection: TCPConnection
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        guard line == "OK" else {
            fail(responseError(for: line, expected: "OK"), operationID: operationID, connection: connection)
            return
        }

        let completion = completionHandler
        cleanupActiveUpload(connection: connection)
        completion?(operationID, .success(()))
    }

    private func receiveLine(
        operationID: UUID,
        connection: TCPConnection,
        completion: @escaping (String) -> Void
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        let callbackContext = LogoUploadCallbackContext(operationID: operationID, connection: connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.responseLineLimit) { [weak self, callbackContext] data, _, isComplete, error in
            Task { @MainActor [weak self, callbackContext] in
                guard
                    let self,
                    let connection = callbackContext.connection,
                    self.isActive(operationID: callbackContext.operationID, connection: connection)
                else {
                    return
                }

                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                }

                if let lineFeedIndex = self.receiveBuffer.firstIndex(of: 0x0A) {
                    let lineData = self.receiveBuffer.prefix(through: lineFeedIndex)
                    self.receiveBuffer.removeSubrange(...lineFeedIndex)
                    guard
                        lineData.count <= Self.responseLineLimit,
                        let line = String(data: lineData.dropLast(), encoding: .utf8)
                    else {
                        self.fail(.invalidResponse("ESP32 response was not valid UTF-8."), operationID: callbackContext.operationID, connection: connection)
                        return
                    }

                    completion(line)
                    return
                }

                if self.receiveBuffer.count > Self.responseLineLimit {
                    self.fail(.responseLineTooLong(Self.responseLineLimit), operationID: callbackContext.operationID, connection: connection)
                    return
                }

                if let error {
                    self.fail(.network(error.localizedDescription), operationID: callbackContext.operationID, connection: connection)
                    return
                }

                if isComplete {
                    self.fail(.invalidResponse("Connection closed before a complete response line was received."), operationID: callbackContext.operationID, connection: connection)
                    return
                }

                self.receiveLine(
                    operationID: callbackContext.operationID,
                    connection: connection,
                    completion: completion
                )
            }
        }
    }

    private func responseError(for line: String, expected: String) -> ESP32LogoUploadError {
        if line.hasPrefix("ERR ") {
            return .firmware(line)
        }

        return .unexpectedResponse(expected: expected, actual: line)
    }

    private func scheduleTimeout(_ phase: TimeoutPhase, operationID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = timeoutScheduler(timeout(for: phase)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTimeout(phase, operationID: operationID)
            }
        }
    }

    private func handleTimeout(_ phase: TimeoutPhase, operationID: UUID) {
        guard
            activeOperationID == operationID,
            let connection
        else {
            return
        }

        fail(.timeout(message(for: phase)), operationID: operationID, connection: connection)
    }

    private func timeout(for phase: TimeoutPhase) -> TimeInterval {
        switch phase {
        case .connection:
            timeouts.connection
        case .ready:
            timeouts.ready
        case .payload:
            timeouts.payload
        case .confirmation:
            timeouts.confirmation
        }
    }

    private func message(for phase: TimeoutPhase) -> String {
        switch phase {
        case .connection:
            "Timed out connecting to the logo upload service."
        case .ready:
            "Timed out waiting for READY from the logo upload service."
        case .payload:
            "Timed out sending the logo payload."
        case .confirmation:
            "Timed out waiting for logo upload confirmation."
        }
    }

    private func fail(
        _ error: ESP32LogoUploadError,
        operationID: UUID,
        connection: TCPConnection
    ) {
        guard isActive(operationID: operationID, connection: connection) else {
            return
        }

        let completion = completionHandler
        cleanupActiveUpload(connection: connection)
        completion?(operationID, .failure(error))
    }

    private func cleanupActiveUpload(connection: TCPConnection) {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        activeOperationID = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        stateHandler = nil
        completionHandler = nil
    }

    private func publish(_ state: LogoUploadState, operationID: UUID) {
        stateHandler?(operationID, state)
    }

    private func isActive(operationID: UUID, connection: TCPConnection) -> Bool {
        activeOperationID == operationID && self.connection === connection
    }
}

enum ESP32LogoUploadError: LocalizedError, Equatable {
    case invalidHeaderLength(Int)
    case invalidPayloadLength(Int)
    case network(String)
    case invalidResponse(String)
    case unexpectedResponse(expected: String, actual: String)
    case responseLineTooLong(Int)
    case firmware(String)
    case timeout(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidHeaderLength(length):
            "Logo header must be exactly \(LogoFileFormat.headerLength) bytes, got \(length)."
        case let .invalidPayloadLength(length):
            "Logo payload must be exactly \(LogoFileFormat.payloadLength) bytes, got \(length)."
        case let .network(message):
            "Logo upload network error: \(message)"
        case let .invalidResponse(message):
            message
        case let .unexpectedResponse(expected, actual):
            "Expected \(expected) from the logo upload service, got \(actual)."
        case let .responseLineTooLong(limit):
            "Logo upload response exceeded \(limit) bytes."
        case let .firmware(line):
            Self.firmwareMessage(for: line)
        case let .timeout(message):
            message
        case .cancelled:
            "Logo upload was cancelled."
        }
    }

    private static func firmwareMessage(for line: String) -> String {
        switch line {
        case "ERR HEADER":
            "The ESP32 rejected the logo header."
        case "ERR SIZE":
            "The ESP32 rejected the logo dimensions or payload size."
        case "ERR CRC":
            "The ESP32 reported a logo checksum mismatch."
        case "ERR SD":
            "The ESP32 could not access SD storage."
        case "ERR WRITE":
            "The ESP32 could not write the logo file."
        case "ERR LOAD":
            "The ESP32 saved the logo but could not load it."
        case "ERR TIMEOUT":
            "The ESP32 timed out while receiving the logo."
        default:
            "ESP32 logo upload error: \(line)"
        }
    }
}

private struct LogoUploadDispatchWorkItemCancellable: CancellableTask {
    let workItem: DispatchWorkItem

    func cancel() {
        workItem.cancel()
    }
}
