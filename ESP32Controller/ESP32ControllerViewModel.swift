//
//  ESP32ControllerViewModel.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation
import Combine
import Network

@MainActor
final class ESP32ControllerViewModel: ObservableObject {
    @Published var host = "192.168.4.1"
    @Published var port = String(ESP32TCPClient.defaultPort)
    @Published var manualBoardID = ""
    @Published private(set) var state: TCPConnectionState = .disconnected
    @Published private(set) var discoveryState: ESP32DiscoveryState = .stopped
    @Published private(set) var scannerState: ESP32ScannerState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredESP32] = []
    @Published private(set) var discoveryErrorText: String?
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var connectedEndpointDescription: String?
    @Published private(set) var connectedDiscoveredDevice: DiscoveredESP32?
    @Published private(set) var pendingSelectedEndpointDescription: String?
    @Published private(set) var scannerConnectionErrorText: String?
    @Published private(set) var connectionHealth: ConnectionHealthState = .idle
    @Published var isScannerPresented = false
    @Published private(set) var logEntries: [CommunicationLogEntry] = []
    @Published var outgoingHex = ""
    @Published var appendFrameDelimiter = true

    static let reservedBoardIDMessage = "Board ID 92 is reserved because it equals the protocol frame delimiter 0x5C."

    private let client: ESP32TCPClient
    private let discoveryService: ESP32DiscoveryService
    private let maxLogEntries = 200
    private var pendingConnectionEndpointDescription: String?
    private var pendingConnectionDevice: DiscoveredESP32?
    private var connectionAttempt: ConnectionAttempt = .idle
    private var isExpectingInitialDisconnect = false
    private var cancellables: Set<AnyCancellable> = []

    var canConnect: Bool {
        switch state {
        case .disconnected, .failed:
            true
        case .connecting, .connected:
            false
        }
    }

    var canDisconnect: Bool {
        switch state {
        case .connecting, .connected, .failed:
            true
        case .disconnected:
            false
        }
    }

    var canSend: Bool {
        state == .connected
    }

    var connectionStatusText: String {
        switch state {
        case .connected:
            switch connectionHealth {
            case .idle, .healthy:
                return "Connected"
            case .waitingForACK:
                return "Connected"
            case let .degraded(missedCount):
                return "Connected · Unstable (\(missedCount)/\(ESP32TCPClient.defaultHeartbeatConfiguration.maximumConsecutiveMisses) missed)"
            case .timedOut:
                return "Connection lost"
            }
        case .disconnected:
            return connectionHealth == .timedOut ? "Connection lost" : state.title
        case .failed:
            return state.detail == "Heartbeat timed out" ? "Connection lost" : state.title
        case .connecting:
            return state.title
        }
    }

    var connectionHealthAccessibilityValue: String {
        switch connectionHealth {
        case .idle:
            return "Heartbeat unavailable"
        case .healthy:
            return "Heartbeat healthy"
        case .waitingForACK:
            return "Heartbeat awaiting acknowledgement"
        case let .degraded(missedCount):
            return "Heartbeat unstable, \(missedCount) of \(ESP32TCPClient.defaultHeartbeatConfiguration.maximumConsecutiveMisses) missed"
        case .timedOut:
            return "Heartbeat timed out"
        }
    }

    init(client: ESP32TCPClient? = nil, discoveryService: ESP32DiscoveryService? = nil) {
        self.client = client ?? ESP32TCPClient()
        self.discoveryService = discoveryService ?? ESP32DiscoveryService()

        self.client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionStateChange(state)

                self?.state = state
                self?.appendEvent(state.title)
            }
        }

        self.client.onFrameReceived = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.appendLog(direction: .incoming, bytes: bytes)
            }
        }

        self.client.onConnectionHealthChange = { [weak self] health in
            DispatchQueue.main.async {
                self?.connectionHealth = health
            }
        }

        self.discoveryService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.discoveryState = state
            }
            .store(in: &cancellables)

        self.discoveryService.$scannerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.scannerState = state
            }
            .store(in: &cancellables)

        self.discoveryService.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.discoveredDevices = devices
            }
            .store(in: &cancellables)

        self.discoveryService.$errorText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorText in
                self?.discoveryErrorText = errorText
            }
            .store(in: &cancellables)

        self.discoveryService.$isRefreshing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRefreshing in
                self?.isRefreshingDevices = isRefreshing
            }
            .store(in: &cancellables)
    }

    func startDiscovery() {
        beginDeviceScan()
    }

    func stopDiscovery() {
        discoveryService.stopDiscovery()
    }

    func refreshDiscovery() {
        refreshDevices()
    }

    func refreshDevices() {
        beginDeviceScan()
    }

    func presentDeviceScanner() {
        isScannerPresented = true
    }

    func beginDeviceScan() {
        pendingSelectedEndpointDescription = nil
        scannerConnectionErrorText = nil
        discoveryService.beginDeviceScan(connectedEndpointDescription: connectedEndpointDescription)
    }

    func closeDeviceScanner() {
        isScannerPresented = false
        pendingSelectedEndpointDescription = nil
        discoveryService.stopScan()
    }

    func connect() {
        guard let parsedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("Port must be 0 through 65535")
            appendEvent("Invalid port")
            return
        }

        let parsedBoardID: UInt8?
        switch Self.manualBoardIDByte(from: manualBoardID) {
        case let .valid(boardID):
            parsedBoardID = boardID
        case let .invalid(message):
            state = .failed(message)
            appendEvent("Invalid board ID")
            return
        }

        beginConnectionAttempt(.manual)
        client.connect(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: parsedPort,
            boardID: parsedBoardID
        )
    }

    func connect(to device: DiscoveredESP32) {
        guard canSelectScannedDevice(device) else {
            return
        }

        pendingSelectedEndpointDescription = device.stableEndpointDescription
        pendingConnectionDevice = device
        scannerConnectionErrorText = nil
        beginConnectionAttempt(.discovered(device.stableEndpointDescription))

        let boardID = Self.boardIDByte(from: device.boardID)
        if boardID == nil, Self.isReservedBoardIDText(device.boardID) {
            appendEvent("Heartbeat unavailable: \(Self.reservedBoardIDMessage)")
        }

        client.connect(to: device.endpoint, boardID: boardID)
    }

    func canSelectScannedDevice(_ device: DiscoveredESP32) -> Bool {
        if case .connecting = state {
            return false
        }

        if pendingSelectedEndpointDescription != nil {
            return false
        }

        return connectedEndpointDescription != device.stableEndpointDescription
    }

    func disconnect() {
        connectionAttempt = .explicitDisconnect
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingSelectedEndpointDescription = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        discoveryService.updateConnectedEndpointDescription(nil)
        client.disconnect()
    }

    func sendHexBytes() {
        do {
            var bytes = try Self.parseHexBytes(outgoingHex)
            if appendFrameDelimiter {
                bytes.append(ESP32TCPClient.frameDelimiter)
            }

            let data = Data(bytes)
            client.send(data) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.appendEvent("Send failed: \(error.localizedDescription)")
                    } else {
                        self?.appendLog(direction: .outgoing, bytes: bytes)
                    }
                }
            }
        } catch {
            appendEvent(error.localizedDescription)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    private func appendEvent(_ message: String) {
        appendLog(direction: .event, bytes: [], message: message)
    }

    private func beginConnectionAttempt(_ target: ConnectionTarget) {
        connectionAttempt = .starting(target)
        isExpectingInitialDisconnect = true
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        discoveryService.updateConnectedEndpointDescription(nil)

        switch target {
        case .manual:
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingSelectedEndpointDescription = nil
            scannerConnectionErrorText = nil
        case let .discovered(endpointDescription):
            pendingConnectionEndpointDescription = endpointDescription
        }
    }

    private func handleConnectionStateChange(_ newState: TCPConnectionState) {
        switch newState {
        case .connecting:
            if case let .starting(target) = connectionAttempt {
                connectionAttempt = .connecting(target)
            }
        case .connected:
            switch connectionAttempt {
            case let .starting(target), let .connecting(target):
                completeConnection(to: target)
            case .idle, .connected, .explicitDisconnect:
                break
            }
        case .failed:
            isExpectingInitialDisconnect = false
            connectionAttempt = .idle
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingSelectedEndpointDescription = nil
            scannerConnectionErrorText = newState.detail ?? newState.title
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
            discoveryService.updateConnectedEndpointDescription(nil)
        case .disconnected:
            if isExpectingInitialDisconnect {
                isExpectingInitialDisconnect = false
                return
            }

            connectionAttempt = .idle
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingSelectedEndpointDescription = nil
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
            discoveryService.updateConnectedEndpointDescription(nil)
        }
    }

    private func completeConnection(to target: ConnectionTarget) {
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil

        switch target {
        case .manual:
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
        case let .discovered(endpointDescription):
            connectedEndpointDescription = endpointDescription
            connectedDiscoveredDevice = pendingConnectionDevice
            isScannerPresented = false
            discoveryService.stopScan()
        }

        pendingSelectedEndpointDescription = nil
        pendingConnectionDevice = nil
        scannerConnectionErrorText = nil
        discoveryService.updateConnectedEndpointDescription(connectedEndpointDescription)
        connectionAttempt = .connected(target)
    }

    private func appendLog(
        direction: CommunicationLogEntry.Direction,
        bytes: [UInt8],
        message: String? = nil
    ) {
        logEntries.append(
            CommunicationLogEntry(
                timestamp: Date(),
                direction: direction,
                bytes: bytes,
                message: message
            )
        )

        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    private static func parseHexBytes(_ text: String) throws -> [UInt8] {
        let compact = text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let tokens = compact
            .split(separator: " ")
            .map(String.init)

        guard !tokens.isEmpty else {
            throw HexInputError.empty
        }

        return try tokens.map { token in
            guard token.count <= 2, let byte = UInt8(token, radix: 16) else {
                throw HexInputError.invalidToken(token)
            }

            return byte
        }
    }

    static func boardIDByte(from boardID: String?) -> UInt8? {
        guard let boardID else {
            return nil
        }

        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let byte = UInt8(trimmed, radix: 10), byte != ESP32TCPClient.reservedBoardID else {
            return nil
        }

        return byte
    }

    static func manualBoardIDByte(from boardID: String) -> ManualBoardIDParseResult {
        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .valid(nil)
        }

        guard let byte = boardIDByte(from: trimmed) else {
            if isReservedBoardIDText(trimmed) {
                return .invalid(reservedBoardIDMessage)
            }

            return .invalid("Board ID must be a decimal value from 0 through 255")
        }

        return .valid(byte)
    }

    private static func isReservedBoardIDText(_ boardID: String?) -> Bool {
        guard let boardID else {
            return false
        }

        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            return false
        }

        return UInt8(trimmed, radix: 10) == ESP32TCPClient.reservedBoardID
    }
}

enum ManualBoardIDParseResult: Equatable {
    case valid(UInt8?)
    case invalid(String)
}

private enum ConnectionTarget: Equatable {
    case manual
    case discovered(String)
}

private enum ConnectionAttempt: Equatable {
    case idle
    case starting(ConnectionTarget)
    case connecting(ConnectionTarget)
    case connected(ConnectionTarget)
    case explicitDisconnect
}

enum HexInputError: LocalizedError {
    case empty
    case invalidToken(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter at least one hex byte"
        case let .invalidToken(token):
            "Invalid hex byte: \(token)"
        }
    }
}
