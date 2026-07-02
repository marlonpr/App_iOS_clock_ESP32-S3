//
//  LogoFileFormat.swift
//  ESP32Controller
//

import Foundation

struct LogoFile: Equatable {
    let header: Data
    let payload: Data
}

enum LogoFileFormat {
    static let magic = Data([0x4C, 0x47, 0x4F, 0x31])
    static let width: UInt16 = 64
    static let height: UInt16 = 32
    static let pixelFormatRGB888: UInt8 = 1
    static let flags: UInt8 = 0
    static let payloadLength = Int(width) * Int(height) * 3
    static let headerLength = 20
    static let logoUploadPort: UInt16 = 5001

    static func makeFile(payload: Data) throws -> LogoFile {
        LogoFile(
            header: try makeHeader(payload: payload),
            payload: payload
        )
    }

    static func makeHeader(payload: Data) throws -> Data {
        guard payload.count == payloadLength else {
            throw LogoFileFormatError.invalidPayloadLength(payload.count)
        }

        var header = Data()
        header.reserveCapacity(headerLength)
        header.append(magic)
        appendLittleEndian(width, to: &header)
        appendLittleEndian(height, to: &header)
        header.append(pixelFormatRGB888)
        header.append(flags)
        appendLittleEndian(UInt16(0), to: &header)
        appendLittleEndian(UInt32(payloadLength), to: &header)
        appendLittleEndian(crc32(payload), to: &header)

        guard header.count == headerLength else {
            throw LogoFileFormatError.invalidHeaderLength(header.count)
        }

        return header
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }

        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x0000_00FF))
        data.append(UInt8((value >> 8) & 0x0000_00FF))
        data.append(UInt8((value >> 16) & 0x0000_00FF))
        data.append(UInt8((value >> 24) & 0x0000_00FF))
    }
}

enum LogoFileFormatError: LocalizedError, Equatable {
    case invalidPayloadLength(Int)
    case invalidHeaderLength(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidPayloadLength(length):
            "Logo payload must be exactly \(LogoFileFormat.payloadLength) bytes, got \(length)."
        case let .invalidHeaderLength(length):
            "Logo header must be exactly \(LogoFileFormat.headerLength) bytes, got \(length)."
        }
    }
}
