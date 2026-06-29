//
//  ClockProtocolEncoder.swift
//  ESP32Controller
//
//  Created by Codex on 29/06/26.
//

import Foundation

enum ClockProtocolEncoder {
    static let requestPrefix: [UInt8] = [0x2F, 0x54, 0x41]
    static let frameTerminator: UInt8 = 0x5C
    static let reservedBoardID: UInt8 = frameTerminator

    static func encode(_ command: ClockProtocolCommand, boardID: UInt8?) throws -> [UInt8] {
        guard let boardID else {
            throw ClockProtocolEncodingError.missingBoardID
        }

        guard boardID != reservedBoardID else {
            throw ClockProtocolEncodingError.reservedBoardID
        }

        let payload: [UInt8]
        switch command {
        case .connectionTest:
            payload = [0x45, 0x53]
        case .readConfiguration:
            payload = [0x52, 0x43]
        case let .setConfiguration(format24Hour, brightnessLevel):
            guard (1...10).contains(brightnessLevel) else {
                throw ClockProtocolEncodingError.invalidBrightnessLevel
            }

            let format: UInt8 = format24Hour ? 0x01 : 0x00
            let intensity = UInt8((Int(brightnessLevel) * 255) / 10)
            payload = [0x43, 0x54, format, intensity]
        case let .reset(resetID):
            payload = [0x52, 0x54, resetID]
        }

        for byte in payload where byte == frameTerminator {
            throw ClockProtocolEncodingError.delimiterConflict
        }

        return requestPrefix + [boardID] + payload + [frameTerminator]
    }
}

enum ClockProtocolEncodingError: LocalizedError, Equatable {
    case missingBoardID
    case reservedBoardID
    case invalidBrightnessLevel
    case delimiterConflict

    var errorDescription: String? {
        switch self {
        case .missingBoardID:
            "A valid Board ID is required for clock commands."
        case .reservedBoardID:
            ESP32ControllerViewModel.reservedBoardIDMessage
        case .invalidBrightnessLevel:
            "Brightness level must be 1 through 10."
        case .delimiterConflict:
            "Command payload cannot contain frame delimiter 0x5C before the terminator."
        }
    }
}
