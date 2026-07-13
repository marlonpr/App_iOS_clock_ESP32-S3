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
        try encode(command, boardID: boardID, calendar: localGregorianCalendar())
    }

    static func encode(
        _ command: ClockProtocolCommand,
        boardID: UInt8?,
        calendar: Calendar
    ) throws -> [UInt8] {
        guard let boardID else {
            throw ClockProtocolEncodingError.missingBoardID
        }

        guard boardID != reservedBoardID else {
            throw ClockProtocolEncodingError.reservedBoardID
        }

        switch command {
        case let .setDisplayMode(mode):
            return try SetModeProtocolCodec.makeRequest(boardID: boardID, mode: mode)
        case .readDisplayMode:
            return try ReadModeProtocolCodec.makeRequest(boardID: boardID)
        case let .loadPalette(mode):
            return try PaletteProtocolCodec.makeLPRequest(boardID: boardID, mode: mode)
        case let .savePalette(draft):
            return try PaletteProtocolCodec.makeCPRequest(boardID: boardID, draft: draft)
        case let .restoreDefaultPalette(mode):
            return try PaletteProtocolCodec.makeDPRequest(boardID: boardID, mode: mode)
        default:
            break
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
        case let .syncTime(date):
            let components = calendar.dateComponents(
                [.year, .month, .day, .weekday, .hour, .minute, .second],
                from: date
            )
            payload = try encodeSyncTimePayload(
                year: components.year,
                month: components.month,
                day: components.day,
                weekday: components.weekday,
                hour: components.hour,
                minute: components.minute,
                second: components.second
            )
        case .nextDisplayMode:
            payload = [0x4E, 0x4D]
        case let .reset(resetID):
            payload = [0x52, 0x54, resetID]
        case .restoreDefaultLogo:
            payload = [0x44, 0x4C]
        case .setDisplayMode:
            preconditionFailure("Set Mode commands return through SetModeProtocolCodec.")
        case .readDisplayMode:
            preconditionFailure("Read Mode commands return through ReadModeProtocolCodec.")
        case .loadPalette, .savePalette, .restoreDefaultPalette:
            preconditionFailure("Palette commands return through PaletteProtocolCodec.")
        }

        for byte in payload where byte == frameTerminator {
            throw ClockProtocolEncodingError.delimiterConflict
        }

        return requestPrefix + [boardID] + payload + [frameTerminator]
    }

    static func encodeSyncTimePayload(
        year: Int?,
        month: Int?,
        day: Int?,
        weekday: Int?,
        hour: Int?,
        minute: Int?,
        second: Int?
    ) throws -> [UInt8] {
        guard
            let year,
            let month,
            let day,
            let weekday,
            let hour,
            let minute,
            let second,
            (2025...2099).contains(year),
            (1...12).contains(month),
            (1...7).contains(weekday),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second),
            isValidDate(year: year, month: month, day: day)
        else {
            throw ClockProtocolEncodingError.invalidDateTime
        }

        return [
            0x55,
            0x43,
            packedBCD(second),
            packedBCD(minute),
            packedBCD(hour),
            packedBCD(weekday),
            packedBCD(day),
            packedBCD(month),
            packedBCD(year % 100)
        ]
    }

    private static func localGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else {
            return false
        }

        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static func packedBCD(_ value: Int) -> UInt8 {
        UInt8((value / 10) << 4 | (value % 10))
    }
}

enum ClockProtocolEncodingError: LocalizedError, Equatable {
    case missingBoardID
    case reservedBoardID
    case invalidBrightnessLevel
    case invalidDateTime
    case delimiterConflict

    var errorDescription: String? {
        switch self {
        case .missingBoardID:
            "A valid Board ID is required for clock commands."
        case .reservedBoardID:
            ESP32ControllerViewModel.reservedBoardIDMessage
        case .invalidBrightnessLevel:
            "Brightness level must be 1 through 10."
        case .invalidDateTime:
            "Date and time values are outside the supported clock range."
        case .delimiterConflict:
            "Command payload cannot contain frame delimiter 0x5C before the terminator."
        }
    }
}
