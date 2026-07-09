//
//  AlarmProtocolCodec.swift
//  ESP32Controller
//
//  Created by Codex on 07/07/26.
//

import Foundation

enum AlarmProtocolCodec {
    static let maximumAlarmID = AlarmRecord.maximumAlarmCount
    static let supportedDurationRange = 1...15

    static func makeLARequest(boardID: UInt8?, alarmID: Int) throws -> [UInt8] {
        let boardID = try validatedBoardID(boardID)
        let alarmID = try validatedAlarmID(alarmID)
        return [
            0x2F,
            0x54,
            0x41,
            boardID,
            0x4C,
            0x41,
            alarmID,
            ESP32TCPClient.frameDelimiter
        ]
    }

    static func makeDARequest(boardID: UInt8?, alarmID: Int) throws -> [UInt8] {
        let boardID = try validatedBoardID(boardID)
        let alarmID = try validatedAlarmID(alarmID)
        return [
            0x2F,
            0x54,
            0x41,
            boardID,
            0x44,
            0x41,
            alarmID,
            ESP32TCPClient.frameDelimiter
        ]
    }

    static func makeCARequest(boardID: UInt8?, draft: AlarmDraft) throws -> AlarmCAFrame {
        let boardID = try validatedBoardID(boardID)
        let signature = try persistedSignature(for: draft)
        let payload: [UInt8] = [
            0x43,
            0x41,
            signature.alarmID,
            signature.hour,
            signature.minute,
            signature.frequency,
            signature.durationEffect
        ]

        let bytes = ClockProtocolEncoder.requestPrefix + [boardID] + payload + [ESP32TCPClient.frameDelimiter]
        return AlarmCAFrame(bytes: bytes, frequency: signature.frequency, durationEffect: signature.durationEffect)
    }

    static func persistedSignature(for draft: AlarmDraft) throws -> AlarmPersistedSignature {
        try persistedSignature(
            id: draft.id,
            hour: draft.hour,
            minute: draft.minute,
            weekdays: draft.weekdays,
            isEnabled: draft.isEnabled,
            durationSeconds: draft.durationSeconds,
            effect: draft.effect
        )
    }

    static func persistedSignature(for record: AlarmRecord) throws -> AlarmPersistedSignature {
        try persistedSignature(
            id: record.id,
            hour: record.hour,
            minute: record.minute,
            weekdays: record.weekdays,
            isEnabled: record.isEnabled,
            durationSeconds: record.durationSeconds,
            effect: record.effect
        )
    }

    static func decodeLAResponse(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> AlarmRecord {
        guard bytes.count == 12 else {
            throw AlarmProtocolError.malformedLAResponse
        }

        guard
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID,
            bytes[4] == 0x6C,
            bytes[5] == 0x61,
            bytes[11] == ESP32TCPClient.frameDelimiter
        else {
            throw AlarmProtocolError.malformedLAResponse
        }

        let alarmID = Int(bytes[6])
        guard AlarmRecord.validIDRange.contains(alarmID) else {
            throw AlarmProtocolError.invalidAlarmID
        }

        let hour = Int(bytes[7])
        let minute = Int(bytes[8])
        guard (0...23).contains(hour) else {
            throw AlarmProtocolError.invalidHour
        }
        guard (0...59).contains(minute) else {
            throw AlarmProtocolError.invalidMinute
        }

        let frequency = bytes[9]
        let durationEffect = bytes[10]
        let isEmpty = hour == 0 &&
            minute == 0 &&
            frequency == 0 &&
            durationEffect == 0

        return AlarmRecord(
            id: alarmID,
            hour: hour,
            minute: minute,
            weekdays: decodeWeekdays(from: frequency),
            durationSeconds: decodeDurationSeconds(from: durationEffect),
            effect: decodeEffect(from: durationEffect),
            isConfigured: !isEmpty,
            isEnabled: decodeEnabled(from: frequency),
            readState: .loaded,
            rawFrequency: frequency,
            rawDurationEffect: durationEffect
        )
    }

    static func decodeCAACK(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> Int {
        guard
            bytes.count == 8,
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID,
            bytes[4] == 0x63,
            bytes[5] == 0x61,
            bytes[7] == ESP32TCPClient.frameDelimiter
        else {
            throw AlarmProtocolError.malformedCAACK
        }

        let alarmID = Int(bytes[6])
        guard AlarmRecord.validIDRange.contains(alarmID) else {
            throw AlarmProtocolError.invalidAlarmID
        }

        return alarmID
    }

    static func decodeDAACK(_ bytes: [UInt8], expectedBoardID boardID: UInt8) throws -> Int {
        guard
            bytes.count == 8,
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID,
            bytes[4] == 0x64,
            bytes[5] == 0x61,
            bytes[7] == ESP32TCPClient.frameDelimiter
        else {
            throw AlarmProtocolError.malformedDAACK
        }

        let alarmID = Int(bytes[6])
        guard AlarmRecord.validIDRange.contains(alarmID) else {
            throw AlarmProtocolError.invalidAlarmID
        }

        return alarmID
    }

    static func encodeFrequency(weekdays: Set<AlarmWeekday>, isEnabled: Bool) -> UInt8 {
        let dayMask = weekdays.reduce(UInt8(0)) { partialResult, weekday in
            partialResult | weekday.frequencyMask
        }
        return dayMask | (isEnabled ? 0x80 : 0x00)
    }

    static func decodeWeekdays(from frequency: UInt8) -> Set<AlarmWeekday> {
        let weekdayMask = frequency & 0x7F
        return Set(AlarmWeekday.allCases.filter { (weekdayMask & $0.frequencyMask) != 0 })
    }

    static func decodeEnabled(from frequency: UInt8) -> Bool {
        (frequency & 0x80) != 0
    }

    static func encodeDurationEffect(durationSeconds: Int, effect: AlarmEffect) throws -> UInt8 {
        guard supportedDurationRange.contains(durationSeconds) else {
            throw AlarmProtocolError.invalidDuration
        }

        guard effect.isSupported else {
            throw AlarmProtocolError.unsupportedEffect
        }

        return (effect.rawValue << 6) | UInt8(durationSeconds & 0x0F)
    }

    static func decodeDurationSeconds(from durationEffect: UInt8) -> Int {
        let duration = Int(durationEffect & 0x0F)
        return max(duration, 1)
    }

    static func decodeEffect(from durationEffect: UInt8) -> AlarmEffect {
        AlarmEffect(rawValue: (durationEffect >> 6) & 0x03)
    }

    private static func validatedBoardID(_ boardID: UInt8?) throws -> UInt8 {
        guard let boardID else {
            throw AlarmProtocolError.missingBoardID
        }

        guard boardID != ESP32TCPClient.reservedBoardID else {
            throw AlarmProtocolError.reservedBoardID
        }

        return boardID
    }

    private static func validatedAlarmID(_ alarmID: Int) throws -> UInt8 {
        guard AlarmRecord.validIDRange.contains(alarmID) else {
            throw AlarmProtocolError.invalidAlarmID
        }

        return UInt8(alarmID)
    }

    private static func persistedSignature(
        id: Int,
        hour: Int,
        minute: Int,
        weekdays: Set<AlarmWeekday>,
        isEnabled: Bool,
        durationSeconds: Int,
        effect: AlarmEffect
    ) throws -> AlarmPersistedSignature {
        let alarmID = try validatedAlarmID(id)
        guard (0...23).contains(hour) else {
            throw AlarmProtocolError.invalidHour
        }
        guard (0...59).contains(minute) else {
            throw AlarmProtocolError.invalidMinute
        }

        return AlarmPersistedSignature(
            alarmID: alarmID,
            hour: UInt8(hour),
            minute: UInt8(minute),
            frequency: encodeFrequency(weekdays: weekdays, isEnabled: isEnabled),
            durationEffect: try encodeDurationEffect(durationSeconds: durationSeconds, effect: effect)
        )
    }
}

struct AlarmPersistedSignature: Equatable {
    let alarmID: UInt8
    let hour: UInt8
    let minute: UInt8
    let frequency: UInt8
    let durationEffect: UInt8
}

struct AlarmCAFrame: Equatable {
    let bytes: [UInt8]
    let frequency: UInt8
    let durationEffect: UInt8
}

enum AlarmProtocolError: LocalizedError, Equatable {
    case missingBoardID
    case reservedBoardID
    case invalidAlarmID
    case invalidHour
    case invalidMinute
    case invalidDuration
    case unsupportedEffect
    case malformedLAResponse
    case malformedCAACK
    case malformedDAACK

    var errorDescription: String? {
        switch self {
        case .missingBoardID:
            "A valid Board ID is required for alarm commands."
        case .reservedBoardID:
            ESP32ControllerViewModel.reservedBoardIDMessage
        case .invalidAlarmID:
            "Alarm ID must be 1 through 60."
        case .invalidHour:
            "Alarm hour must be 0 through 23."
        case .invalidMinute:
            "Alarm minute must be 0 through 59."
        case .invalidDuration:
            "Alarm duration must be 1 through 15 seconds."
        case .unsupportedEffect:
            "Choose a supported alarm effect before sending."
        case .malformedLAResponse:
            "Malformed alarm read response."
        case .malformedCAACK:
            "Malformed alarm save acknowledgement."
        case .malformedDAACK:
            "Malformed alarm delete acknowledgement."
        }
    }
}
