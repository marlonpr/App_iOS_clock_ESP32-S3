//
//  CommunicationLogEntry.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation

struct CommunicationLogEntry: Identifiable {
    enum Direction: String {
        case incoming = "RX"
        case outgoing = "TX"
        case event = "EV"
    }

    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let bytes: [UInt8]
    let message: String?

    var asciiText: String {
        guard !bytes.isEmpty else {
            return message ?? ""
        }

        return bytes.map { byte in
            switch byte {
            case 0x20...0x7E:
                return String(UnicodeScalar(byte))
            default:
                return "."
            }
        }
        .joined()
    }

    var hexText: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
