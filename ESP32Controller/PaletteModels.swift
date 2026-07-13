//
//  PaletteModels.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import Foundation

struct RGB888: Hashable, Codable, Sendable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: String) throws {
        guard hex.utf8.count == 6 else {
            throw RGB888Error.invalidLength
        }

        let bytes = Array(hex.utf8)
        guard
            let r = Self.decodeByte(bytes[0], bytes[1]),
            let g = Self.decodeByte(bytes[2], bytes[3]),
            let b = Self.decodeByte(bytes[4], bytes[5])
        else {
            throw RGB888Error.invalidHex
        }

        self.init(r: r, g: g, b: b)
    }

    var uppercaseHex: String {
        String(format: "%02X%02X%02X", r, g, b)
    }

    var uppercaseHexASCII: [UInt8] {
        Array(uppercaseHex.utf8)
    }

    private static func decodeByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
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

enum RGB888Error: LocalizedError, Equatable {
    case invalidLength
    case invalidHex

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            "RGB888 colors must contain exactly six hexadecimal characters."
        case .invalidHex:
            "RGB888 colors may contain only hexadecimal characters."
        }
    }
}

enum PaletteMode: UInt8, CaseIterable, Codable, Sendable {
    case mode1 = 0x01
    case mode2 = 0x02
    case mode3 = 0x03
    case rotation = 0x04

    static let editableCases: [PaletteMode] = [.mode1, .mode2, .mode3]

    var isEditable: Bool {
        self != .rotation
    }

    var uppercaseHex: String {
        String(format: "%02X", rawValue)
    }
}

enum PaletteRole: UInt8, CaseIterable, Codable, Comparable, Sendable {
    case time = 0x01
    case date = 0x02
    case weekday = 0x03
    case temperatureCold = 0x10
    case temperatureCool = 0x11
    case temperatureWarm = 0x12
    case temperatureHot = 0x13

    static func < (lhs: PaletteRole, rhs: PaletteRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .time:
            "Time"
        case .date:
            "Date"
        case .weekday:
            "Weekday"
        case .temperatureCold:
            "Temperature Cold"
        case .temperatureCool:
            "Temperature Cool"
        case .temperatureWarm:
            "Temperature Warm"
        case .temperatureHot:
            "Temperature Hot"
        }
    }

    var supportedModes: Set<PaletteMode> {
        switch self {
        case .weekday:
            [.mode3]
        case .time, .date, .temperatureCold, .temperatureCool, .temperatureWarm, .temperatureHot:
            [.mode1, .mode2, .mode3]
        }
    }

    func isSupported(in mode: PaletteMode) -> Bool {
        supportedModes.contains(mode)
    }

    static func requiredRoles(for mode: PaletteMode) -> [PaletteRole] {
        allCases.filter { $0.isSupported(in: mode) }.sorted()
    }
}

enum PaletteStatus: UInt8, CaseIterable, Codable, Sendable {
    case success = 0x00
    case unsupportedMode = 0x01
    case unsupportedVersion = 0x02
    case invalidCountOrLength = 0x03
    case duplicateRole = 0x04
    case unsupportedRole = 0x05
    case incompleteRequiredRoleSet = 0x06
    case invalidHex = 0x07
    case nvsFailure = 0x08
    case busy = 0x09
    case internalFailure = 0x0A

    var uppercaseHex: String {
        String(format: "%02X", rawValue)
    }

    var isSuccess: Bool {
        self == .success
    }

    var indicatesUnsupportedFirmware: Bool {
        self == .unsupportedMode || self == .unsupportedVersion
    }

    var message: String {
        switch self {
        case .success:
            "Success"
        case .unsupportedMode:
            "The CLOCK does not support a palette for this mode."
        case .unsupportedVersion:
            "The CLOCK does not support this palette schema version."
        case .invalidCountOrLength:
            "The CLOCK rejected the palette role count or payload length."
        case .duplicateRole:
            "The CLOCK rejected a duplicate palette role."
        case .unsupportedRole:
            "The CLOCK does not support one of the palette roles."
        case .incompleteRequiredRoleSet:
            "The CLOCK requires a complete palette role set."
        case .invalidHex:
            "The CLOCK rejected invalid hexadecimal palette data."
        case .nvsFailure:
            "The CLOCK could not persist the palette."
        case .busy:
            "The CLOCK is busy with another palette operation."
        case .internalFailure:
            "The CLOCK reported an internal palette failure."
        }
    }
}

struct ModePaletteRecord: Equatable, Sendable {
    let mode: PaletteMode
    let schemaVersion: UInt8
    let status: PaletteStatus
    let roleValues: [PaletteRole: RGB888]
    let unknownRoleValues: [UInt8: RGB888]

    init(
        mode: PaletteMode,
        schemaVersion: UInt8 = PaletteProtocolCodec.supportedSchemaVersion,
        status: PaletteStatus = .success,
        roleValues: [PaletteRole: RGB888],
        unknownRoleValues: [UInt8: RGB888] = [:]
    ) {
        self.mode = mode
        self.schemaVersion = schemaVersion
        self.status = status
        self.roleValues = roleValues
        self.unknownRoleValues = unknownRoleValues
    }

    var draft: ModePaletteDraft {
        ModePaletteDraft(record: self)
    }
}

struct ModePaletteDraft: Equatable, Sendable {
    let mode: PaletteMode
    var schemaVersion: UInt8
    var roleValues: [PaletteRole: RGB888]
    var unknownRoleValues: [UInt8: RGB888]

    init(
        mode: PaletteMode,
        schemaVersion: UInt8 = PaletteProtocolCodec.supportedSchemaVersion,
        roleValues: [PaletteRole: RGB888],
        unknownRoleValues: [UInt8: RGB888] = [:]
    ) {
        self.mode = mode
        self.schemaVersion = schemaVersion
        self.roleValues = roleValues
        self.unknownRoleValues = unknownRoleValues
    }

    init(record: ModePaletteRecord) {
        self.init(
            mode: record.mode,
            schemaVersion: record.schemaVersion,
            roleValues: record.roleValues,
            unknownRoleValues: record.unknownRoleValues
        )
    }
}

struct PalettePersistedSignature: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let roleID: UInt8
        let value: RGB888
    }

    let mode: PaletteMode
    let schemaVersion: UInt8
    let entries: [Entry]

    init(record: ModePaletteRecord) throws {
        try self.init(
            mode: record.mode,
            schemaVersion: record.schemaVersion,
            roleValues: record.roleValues,
            unknownRoleValues: record.unknownRoleValues
        )
    }

    init(draft: ModePaletteDraft) throws {
        try self.init(
            mode: draft.mode,
            schemaVersion: draft.schemaVersion,
            roleValues: draft.roleValues,
            unknownRoleValues: draft.unknownRoleValues
        )
    }

    private init(
        mode: PaletteMode,
        schemaVersion: UInt8,
        roleValues: [PaletteRole: RGB888],
        unknownRoleValues: [UInt8: RGB888]
    ) throws {
        var valuesByRoleID = unknownRoleValues
        for (role, value) in roleValues {
            guard valuesByRoleID.updateValue(value, forKey: role.rawValue) == nil else {
                throw PaletteProtocolError.duplicateRole(role.rawValue)
            }
        }

        self.mode = mode
        self.schemaVersion = schemaVersion
        self.entries = valuesByRoleID
            .map { Entry(roleID: $0.key, value: $0.value) }
            .sorted { $0.roleID < $1.roleID }
    }
}

enum PaletteFactoryDefaults {
    static func record(for mode: PaletteMode) -> ModePaletteRecord? {
        guard mode.isEditable else {
            return nil
        }

        let dateHex = mode == .mode1 ? "00FF00" : "0000FF"
        var values: [PaletteRole: RGB888] = [
            .time: rgb("FFFFFF"),
            .date: rgb(dateHex),
            .temperatureCold: rgb("FFFFFF"),
            .temperatureCool: rgb("00FFFF"),
            .temperatureWarm: rgb("FF4100"),
            .temperatureHot: rgb("FF0000")
        ]
        if mode == .mode3 {
            values[.weekday] = rgb("00FF00")
        }

        return ModePaletteRecord(mode: mode, roleValues: values)
    }

    static func draft(for mode: PaletteMode) -> ModePaletteDraft? {
        record(for: mode)?.draft
    }

    private static func rgb(_ hex: String) -> RGB888 {
        // Constants in this file are covered by codec tests and are always valid.
        try! RGB888(hex: hex)
    }
}

enum PaletteFeatureAvailability: Equatable, Sendable {
    case unknown
    case available
    case unsupported(String)

    var isAvailable: Bool {
        self == .available
    }
}

enum PaletteReadState: Equatable, Sendable {
    case idle
    case reading(mode: PaletteMode)
    case succeeded(mode: PaletteMode)
    case failed(mode: PaletteMode?, message: String)

    var isReading: Bool {
        if case .reading = self {
            return true
        }
        return false
    }
}

enum PaletteSaveState: Equatable, Sendable {
    case idle
    case saving(mode: PaletteMode)
    case succeeded(mode: PaletteMode)
    case failed(mode: PaletteMode, message: String)

    var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }
}

enum PaletteDefaultRestoreState: Equatable, Sendable {
    case idle
    case restoring(mode: PaletteMode)
    case succeeded(mode: PaletteMode)
    case failed(mode: PaletteMode, message: String)

    var isRestoring: Bool {
        if case .restoring = self {
            return true
        }
        return false
    }
}

enum PaletteOperationKind: String, Equatable, Sendable {
    case read
    case save
    case restoreDefaults
}

struct PaletteOperationFailure: LocalizedError, Equatable, Sendable {
    let operation: PaletteOperationKind
    let mode: PaletteMode?
    let status: PaletteStatus?
    let message: String

    var errorDescription: String? {
        message
    }
}
