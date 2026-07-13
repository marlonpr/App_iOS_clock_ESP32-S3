//
//  PaletteProtocolCodec.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import Foundation

enum PaletteProtocolCodec {
    static let supportedSchemaVersion: UInt8 = 0x01

    static func makeLPRequest(boardID: UInt8?, mode: PaletteMode) throws -> [UInt8] {
        let boardID = try validatedBoardID(boardID)
        try validateEditableMode(mode)
        return frame(boardID: boardID, command: [0x4C, 0x50], payload: hexASCII(mode.rawValue))
    }

    static func makeCPRequest(boardID: UInt8?, draft: ModePaletteDraft) throws -> [UInt8] {
        let boardID = try validatedBoardID(boardID)
        let entries = try validatedEntries(for: draft)
        guard entries.count <= Int(UInt8.max) else {
            throw PaletteProtocolError.tooManyRoles
        }

        var payload = hexASCII(draft.mode.rawValue)
        payload += hexASCII(draft.schemaVersion)
        payload += hexASCII(UInt8(entries.count))
        for entry in entries {
            payload += hexASCII(entry.roleID)
            payload += entry.value.uppercaseHexASCII
        }

        return frame(boardID: boardID, command: [0x43, 0x50], payload: payload)
    }

    static func makeDPRequest(boardID: UInt8?, mode: PaletteMode) throws -> [UInt8] {
        let boardID = try validatedBoardID(boardID)
        try validateEditableMode(mode)
        return frame(boardID: boardID, command: [0x44, 0x50], payload: hexASCII(mode.rawValue))
    }

    static func decodeLPResponse(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> PaletteLPResponse {
        try validateResponseEnvelope(bytes, boardID: boardID, command: [0x6C, 0x70], minimumCount: 15)

        guard
            let modeByte = decodeHexByte(bytes[6], bytes[7]),
            let mode = PaletteMode(rawValue: modeByte),
            let statusByte = decodeHexByte(bytes[8], bytes[9]),
            let status = PaletteStatus(rawValue: statusByte)
        else {
            throw PaletteProtocolError.invalidHex
        }

        if !status.isSuccess {
            guard
                bytes.count == 15,
                bytes[10...13].allSatisfy({ $0 == 0x30 })
            else {
                throw PaletteProtocolError.invalidCountOrLength
            }

            return .failure(mode: mode, status: status)
        }

        try validateEditableMode(mode)
        guard
            let version = decodeHexByte(bytes[10], bytes[11]),
            let count = decodeHexByte(bytes[12], bytes[13])
        else {
            throw PaletteProtocolError.invalidHex
        }
        guard version == supportedSchemaVersion else {
            throw PaletteProtocolError.unsupportedVersion(version)
        }

        let expectedLength = 15 + (Int(count) * 8)
        guard bytes.count == expectedLength else {
            throw PaletteProtocolError.invalidCountOrLength
        }

        var knownValues: [PaletteRole: RGB888] = [:]
        var unknownValues: [UInt8: RGB888] = [:]
        var receivedRoleIDs: Set<UInt8> = []
        var index = 14
        for _ in 0..<Int(count) {
            guard let roleID = decodeHexByte(bytes[index], bytes[index + 1]) else {
                throw PaletteProtocolError.invalidHex
            }
            guard receivedRoleIDs.insert(roleID).inserted else {
                throw PaletteProtocolError.duplicateRole(roleID)
            }

            let colorBytes = Array(bytes[(index + 2)..<(index + 8)])
            guard let colorHex = String(bytes: colorBytes, encoding: .ascii) else {
                throw PaletteProtocolError.invalidHex
            }
            let color: RGB888
            do {
                color = try RGB888(hex: colorHex)
            } catch {
                throw PaletteProtocolError.invalidHex
            }

            if let role = PaletteRole(rawValue: roleID) {
                guard role.isSupported(in: mode) else {
                    throw PaletteProtocolError.unsupportedRole(roleID, mode)
                }
                knownValues[role] = color
            } else {
                unknownValues[roleID] = color
            }

            index += 8
        }

        let required = Set(PaletteRole.requiredRoles(for: mode))
        guard required.isSubset(of: Set(knownValues.keys)) else {
            throw PaletteProtocolError.incompleteRequiredRoles(mode)
        }

        return .success(
            ModePaletteRecord(
                mode: mode,
                schemaVersion: version,
                status: status,
                roleValues: knownValues,
                unknownRoleValues: unknownValues
            )
        )
    }

    static func decodeCPACK(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> PaletteAcknowledgement {
        try decodeAcknowledgement(bytes, expectedBoardID: boardID, command: [0x63, 0x70])
    }

    static func decodeDPACK(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> PaletteAcknowledgement {
        try decodeAcknowledgement(bytes, expectedBoardID: boardID, command: [0x64, 0x70])
    }

    static func persistedSignature(for record: ModePaletteRecord) throws -> PalettePersistedSignature {
        try PalettePersistedSignature(record: record)
    }

    static func persistedSignature(for draft: ModePaletteDraft) throws -> PalettePersistedSignature {
        try PalettePersistedSignature(draft: draft)
    }

    static func validateCompleteDraft(_ draft: ModePaletteDraft) throws {
        _ = try validatedEntries(for: draft)
    }

    private static func decodeAcknowledgement(
        _ bytes: [UInt8],
        expectedBoardID boardID: UInt8,
        command: [UInt8]
    ) throws -> PaletteAcknowledgement {
        try validateResponseEnvelope(bytes, boardID: boardID, command: command, minimumCount: 11)
        guard bytes.count == 11 else {
            throw PaletteProtocolError.invalidCountOrLength
        }
        guard
            let modeByte = decodeHexByte(bytes[6], bytes[7]),
            let mode = PaletteMode(rawValue: modeByte),
            let statusByte = decodeHexByte(bytes[8], bytes[9]),
            let status = PaletteStatus(rawValue: statusByte)
        else {
            throw PaletteProtocolError.invalidHex
        }

        if status.isSuccess {
            try validateEditableMode(mode)
        }

        return PaletteAcknowledgement(mode: mode, status: status)
    }

    private static func validatedEntries(for draft: ModePaletteDraft) throws -> [PalettePersistedSignature.Entry] {
        try validateEditableMode(draft.mode)
        guard draft.schemaVersion == supportedSchemaVersion else {
            throw PaletteProtocolError.unsupportedVersion(draft.schemaVersion)
        }

        for role in draft.roleValues.keys where !role.isSupported(in: draft.mode) {
            throw PaletteProtocolError.unsupportedRole(role.rawValue, draft.mode)
        }

        let required = Set(PaletteRole.requiredRoles(for: draft.mode))
        guard required.isSubset(of: Set(draft.roleValues.keys)) else {
            throw PaletteProtocolError.incompleteRequiredRoles(draft.mode)
        }

        let signature = try PalettePersistedSignature(draft: draft)
        return signature.entries
    }

    private static func validatedBoardID(_ boardID: UInt8?) throws -> UInt8 {
        guard let boardID else {
            throw PaletteProtocolError.missingBoardID
        }
        guard boardID != ESP32TCPClient.reservedBoardID else {
            throw PaletteProtocolError.reservedBoardID
        }
        return boardID
    }

    private static func validateEditableMode(_ mode: PaletteMode) throws {
        guard mode.isEditable else {
            throw PaletteProtocolError.unsupportedEditableMode
        }
    }

    private static func frame(boardID: UInt8, command: [UInt8], payload: [UInt8]) -> [UInt8] {
        ClockProtocolEncoder.requestPrefix + [boardID] + command + payload + [ESP32TCPClient.frameDelimiter]
    }

    private static func validateResponseEnvelope(
        _ bytes: [UInt8],
        boardID: UInt8,
        command: [UInt8],
        minimumCount: Int
    ) throws {
        guard bytes.count >= minimumCount else {
            throw PaletteProtocolError.malformedResponse
        }
        guard bytes[0...2].elementsEqual([0x2F, 0x74, 0x61]) else {
            throw PaletteProtocolError.invalidPrefix
        }
        guard bytes[3] == boardID else {
            throw PaletteProtocolError.wrongBoardID
        }
        guard bytes[4] == command[0], bytes[5] == command[1] else {
            throw PaletteProtocolError.wrongCommand
        }
        guard bytes.last == ESP32TCPClient.frameDelimiter else {
            throw PaletteProtocolError.missingTerminator
        }
    }

    private static func hexASCII(_ byte: UInt8) -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
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

enum PaletteLPResponse: Equatable, Sendable {
    case success(ModePaletteRecord)
    case failure(mode: PaletteMode, status: PaletteStatus)
}

struct PaletteAcknowledgement: Equatable, Sendable {
    let mode: PaletteMode
    let status: PaletteStatus
}

enum PaletteProtocolError: LocalizedError, Equatable {
    case missingBoardID
    case reservedBoardID
    case unsupportedEditableMode
    case invalidPrefix
    case wrongBoardID
    case wrongCommand
    case missingTerminator
    case malformedResponse
    case invalidHex
    case unsupportedVersion(UInt8)
    case invalidCountOrLength
    case duplicateRole(UInt8)
    case unsupportedRole(UInt8, PaletteMode)
    case incompleteRequiredRoles(PaletteMode)
    case tooManyRoles

    var errorDescription: String? {
        switch self {
        case .missingBoardID:
            "A valid Board ID is required for palette commands."
        case .reservedBoardID:
            ESP32ControllerViewModel.reservedBoardIDMessage
        case .unsupportedEditableMode:
            "Rotation Mode 4 has no independent editable palette."
        case .invalidPrefix:
            "Palette response has an invalid prefix."
        case .wrongBoardID:
            "Palette response is for a different CLOCK."
        case .wrongCommand:
            "Palette response command does not match the active operation."
        case .missingTerminator:
            "Palette response is missing its frame terminator."
        case .malformedResponse:
            "Malformed palette response."
        case .invalidHex:
            "Palette response contains invalid hexadecimal data."
        case let .unsupportedVersion(version):
            "Unsupported palette schema version \(String(format: "%02X", version))."
        case .invalidCountOrLength:
            "Palette role count does not match the exact frame length."
        case let .duplicateRole(roleID):
            "Palette contains duplicate role \(String(format: "%02X", roleID))."
        case let .unsupportedRole(roleID, mode):
            "Palette role \(String(format: "%02X", roleID)) is not supported in Mode \(mode.rawValue)."
        case let .incompleteRequiredRoles(mode):
            "Mode \(mode.rawValue) requires a complete palette role set."
        case .tooManyRoles:
            "Palette contains more than 255 roles."
        }
    }
}
