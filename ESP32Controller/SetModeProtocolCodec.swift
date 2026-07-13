//
//  SetModeProtocolCodec.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import Foundation

enum SetModeProtocolCodec {
    static func makeRequest(boardID: UInt8?, mode: PaletteMode) throws -> [UInt8] {
        guard let boardID else {
            throw ClockProtocolEncodingError.missingBoardID
        }
        guard boardID != ClockProtocolEncoder.reservedBoardID else {
            throw ClockProtocolEncodingError.reservedBoardID
        }

        return ClockProtocolEncoder.requestPrefix +
            [boardID, 0x53, 0x4D] +
            hexASCII(mode.rawValue) +
            [ClockProtocolEncoder.frameTerminator]
    }

    static func decodeResponse(
        _ bytes: [UInt8],
        expectedBoardID boardID: UInt8
    ) throws -> SetModeAcknowledgement {
        guard bytes.count == 11 else {
            throw SetModeProtocolError.invalidLength
        }
        guard bytes[0...2].elementsEqual([0x2F, 0x74, 0x61]) else {
            throw SetModeProtocolError.invalidPrefix
        }
        guard bytes[3] == boardID else {
            throw SetModeProtocolError.unexpectedBoardID(bytes[3])
        }
        guard bytes[4] == 0x73, bytes[5] == 0x6D else {
            throw SetModeProtocolError.unexpectedCommand
        }
        guard bytes[10] == ClockProtocolEncoder.frameTerminator else {
            throw SetModeProtocolError.missingTerminator
        }
        guard
            let modeValue = decodeHexByte(bytes[6], bytes[7]),
            let statusValue = decodeHexByte(bytes[8], bytes[9])
        else {
            throw SetModeProtocolError.invalidHex
        }
        guard let status = SetModeStatus(rawValue: statusValue) else {
            throw SetModeProtocolError.unknownStatus(statusValue)
        }
        if status == .success, PaletteMode(rawValue: modeValue) == nil {
            throw SetModeProtocolError.unsupportedAppliedMode(modeValue)
        }

        return SetModeAcknowledgement(modeValue: modeValue, status: status)
    }

    private static func hexASCII(_ value: UInt8) -> [UInt8] {
        Array(String(format: "%02X", value).utf8)
    }

    private static func decodeHexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        guard let high = hexNibble(high), let low = hexNibble(low) else {
            return nil
        }
        return (high << 4) | low
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
}

struct SetModeAcknowledgement: Equatable, Sendable {
    let modeValue: UInt8
    let status: SetModeStatus

    var mode: PaletteMode? {
        PaletteMode(rawValue: modeValue)
    }
}

enum SetModeStatus: UInt8, CaseIterable, Sendable {
    case success = 0x00
    case unsupportedMode = 0x01
    case invalidLength = 0x02
    case invalidHex = 0x03
    case settingsSaveFailure = 0x04
    case internalFailure = 0x0A

    var uppercaseHex: String {
        String(format: "%02X", rawValue)
    }

    var message: String {
        switch self {
        case .success:
            "Success"
        case .unsupportedMode:
            "The CLOCK does not support this display mode."
        case .invalidLength:
            "The CLOCK rejected the Set Mode command length."
        case .invalidHex:
            "The CLOCK rejected the Set Mode hexadecimal value."
        case .settingsSaveFailure:
            "The CLOCK changed mode but could not save the setting."
        case .internalFailure:
            "The CLOCK could not change display mode because of an internal failure."
        }
    }
}

enum SetModeProtocolError: LocalizedError, Equatable {
    case invalidLength
    case invalidPrefix
    case unexpectedBoardID(UInt8)
    case unexpectedCommand
    case missingTerminator
    case invalidHex
    case unknownStatus(UInt8)
    case unsupportedAppliedMode(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            "The Set Mode response length is invalid."
        case .invalidPrefix:
            "The Set Mode response prefix is invalid."
        case let .unexpectedBoardID(boardID):
            "The Set Mode response used unexpected Board ID \(boardID)."
        case .unexpectedCommand:
            "The Set Mode response command is invalid."
        case .missingTerminator:
            "The Set Mode response is missing its terminator."
        case .invalidHex:
            "The Set Mode response contains invalid hexadecimal text."
        case let .unknownStatus(status):
            "The Set Mode response contains unknown status \(String(format: "%02X", status))."
        case let .unsupportedAppliedMode(mode):
            "The CLOCK reported unsupported display mode \(String(format: "%02X", mode))."
        }
    }
}
