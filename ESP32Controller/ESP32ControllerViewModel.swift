//
//  ESP32ControllerViewModel.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation

@MainActor
final class ESP32ControllerViewModel: ObservableObject {
    @Published var host = "192.168.4.1"
    @Published var port = String(ESP32TCPClient.defaultPort)
    @Published private(set) var state: TCPConnectionState = .disconnected
    @Published private(set) var logEntries: [CommunicationLogEntry] = []
    @Published var outgoingHex = ""
    @Published var appendFrameDelimiter = true

    private let client: ESP32TCPClient
    private let maxLogEntries = 200

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

    init(client: ESP32TCPClient? = nil) {
        self.client = client ?? ESP32TCPClient()

        self.client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.state = state
                self?.appendEvent(state.title)
            }
        }

        self.client.onFrameReceived = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.appendLog(direction: .incoming, bytes: bytes)
            }
        }
    }

    func connect() {
        guard let parsedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("Port must be 0 through 65535")
            appendEvent("Invalid port")
            return
        }

        client.connect(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: parsedPort)
    }

    func disconnect() {
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
