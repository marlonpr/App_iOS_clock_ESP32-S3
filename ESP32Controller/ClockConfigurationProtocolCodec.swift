//
//  ClockConfigurationProtocolCodec.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import Foundation

struct ClockConfigurationReadback: Equatable {
    let isMemoryWritten: Bool
    let is24HourFormat: Bool
    let protocolIntensity: UInt8
    let second: UInt8
    let minute: UInt8
    let hour: UInt8
    let dayOfWeek: UInt8
    let day: UInt8
    let month: UInt8
    let year: UInt8

    var brightnessLevel: UInt8 {
        Self.brightnessLevel(forProtocolIntensity: protocolIntensity)
    }

    static func brightnessLevel(forProtocolIntensity intensity: UInt8) -> UInt8 {
        let normalizedIntensity = max(Int(intensity), 1)
        let level = (normalizedIntensity * 10 + 254) / 255
        return UInt8(min(max(level, 1), 10))
    }
}

enum ClockConfigurationProtocolCodec {
    static let responseLength = 17

    static func decodeRCResponse(
        _ bytes: [UInt8],
        expectedBoardID: UInt8
    ) throws -> ClockConfigurationReadback {
        guard bytes.count == responseLength else {
            throw ClockConfigurationProtocolError.invalidLength
        }
        guard bytes[0] == 0x2F, bytes[1] == 0x74, bytes[2] == 0x61 else {
            throw ClockConfigurationProtocolError.invalidPrefix
        }
        guard bytes[3] == expectedBoardID else {
            throw ClockConfigurationProtocolError.boardIDMismatch
        }
        guard bytes[4] == 0x72, bytes[5] == 0x63 else {
            throw ClockConfigurationProtocolError.invalidCommand
        }
        guard bytes[16] == ClockProtocolEncoder.frameTerminator else {
            throw ClockConfigurationProtocolError.invalidTerminator
        }
        guard bytes[6] == 0x00 || bytes[6] == 0x01 else {
            throw ClockConfigurationProtocolError.invalidMemoryStatus
        }
        guard bytes[7] == 0x00 || bytes[7] == 0x01 else {
            throw ClockConfigurationProtocolError.invalidTimeFormat
        }

        return ClockConfigurationReadback(
            isMemoryWritten: bytes[6] == 0x01,
            is24HourFormat: bytes[7] == 0x01,
            protocolIntensity: bytes[8],
            second: bytes[9],
            minute: bytes[10],
            hour: bytes[11],
            dayOfWeek: bytes[12],
            day: bytes[13],
            month: bytes[14],
            year: bytes[15]
        )
    }
}

enum ClockConfigurationProtocolError: LocalizedError, Equatable {
    case invalidLength
    case invalidPrefix
    case boardIDMismatch
    case invalidCommand
    case invalidTerminator
    case invalidMemoryStatus
    case invalidTimeFormat

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            "Invalid RC response length."
        case .invalidPrefix:
            "Invalid RC response prefix."
        case .boardIDMismatch:
            "RC response Board ID does not match the connected CLOCK."
        case .invalidCommand:
            "Invalid RC response command."
        case .invalidTerminator:
            "Invalid RC response terminator."
        case .invalidMemoryStatus:
            "Invalid RC memory status."
        case .invalidTimeFormat:
            "Invalid RC time format."
        }
    }
}

enum ClockConfigurationReadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}
