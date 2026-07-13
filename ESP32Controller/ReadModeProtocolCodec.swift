//
//  ReadModeProtocolCodec.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import Foundation

enum ReadModeProtocolCodec {
    static func makeRequest(boardID: UInt8?) throws -> [UInt8] {
        guard let boardID else {
            throw ClockProtocolEncodingError.missingBoardID
        }
        guard boardID != ClockProtocolEncoder.reservedBoardID else {
            throw ClockProtocolEncodingError.reservedBoardID
        }

        return ClockProtocolEncoder.requestPrefix +
            [boardID, 0x52, 0x4D] +
            [ClockProtocolEncoder.frameTerminator]
    }

    static func decodeResponse(
        _ bytes: [UInt8],
        expectedBoardID boardID: UInt8
    ) throws -> ReadModeAcknowledgement {
        guard bytes.count == 11 else {
            throw ReadModeProtocolError.invalidLength
        }
        guard bytes[0...2].elementsEqual([0x2F, 0x74, 0x61]) else {
            throw ReadModeProtocolError.invalidPrefix
        }
        guard bytes[3] == boardID else {
            throw ReadModeProtocolError.unexpectedBoardID(bytes[3])
        }
        guard bytes[4] == 0x72, bytes[5] == 0x6D else {
            throw ReadModeProtocolError.unexpectedCommand
        }
        guard bytes[10] == ClockProtocolEncoder.frameTerminator else {
            throw ReadModeProtocolError.missingTerminator
        }
        guard
            let modeValue = decodeHexByte(bytes[6], bytes[7]),
            let statusValue = decodeHexByte(bytes[8], bytes[9])
        else {
            throw ReadModeProtocolError.invalidHex
        }
        guard let status = ReadModeStatus(rawValue: statusValue) else {
            throw ReadModeProtocolError.unknownStatus(statusValue)
        }
        if status == .success, PaletteMode(rawValue: modeValue) == nil {
            throw ReadModeProtocolError.invalidAppliedMode(modeValue)
        }

        return ReadModeAcknowledgement(modeValue: modeValue, status: status)
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

struct ReadModeAcknowledgement: Equatable, Sendable {
    let modeValue: UInt8
    let status: ReadModeStatus

    var mode: PaletteMode? {
        PaletteMode(rawValue: modeValue)
    }
}

enum ReadModeStatus: UInt8, CaseIterable, Sendable {
    case success = 0x00
    case internalFailure = 0x0A

    var uppercaseHex: String {
        String(format: "%02X", rawValue)
    }

    var message: String {
        switch self {
        case .success:
            "Success"
        case .internalFailure:
            "The CLOCK could not read its display mode because of an internal failure."
        }
    }
}

enum ReadModeProtocolError: LocalizedError, Equatable {
    case invalidLength
    case invalidPrefix
    case unexpectedBoardID(UInt8)
    case unexpectedCommand
    case missingTerminator
    case invalidHex
    case unknownStatus(UInt8)
    case invalidAppliedMode(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            "The Read Mode response length is invalid."
        case .invalidPrefix:
            "The Read Mode response prefix is invalid."
        case let .unexpectedBoardID(boardID):
            "The Read Mode response used unexpected Board ID \(boardID)."
        case .unexpectedCommand:
            "The Read Mode response command is invalid."
        case .missingTerminator:
            "The Read Mode response is missing its terminator."
        case .invalidHex:
            "The Read Mode response contains invalid hexadecimal text."
        case let .unknownStatus(status):
            "The Read Mode response contains unknown status \(String(format: "%02X", status))."
        case let .invalidAppliedMode(mode):
            "The CLOCK reported invalid display mode \(String(format: "%02X", mode))."
        }
    }
}

enum ReadDisplayModeState: Equatable, Sendable {
    case idle
    case loading
    case loaded(mode: UInt8)
    case failed(String)

    var isLoading: Bool {
        self == .loading
    }
}
