//
//  ClockProtocolCommand.swift
//  ESP32Controller
//
//  Created by Codex on 29/06/26.
//

import Foundation

enum ClockProtocolCommand: Equatable {
    case connectionTest
    case setConfiguration(format24Hour: Bool, brightnessLevel: UInt8)
    case readConfiguration
    case reset(resetID: UInt8)

    var logLabel: String {
        switch self {
        case .connectionTest:
            "ES Connection Test"
        case .setConfiguration:
            "CT Apply Settings"
        case .readConfiguration:
            "RC Read Configuration"
        case .reset:
            "RT Reset Device"
        }
    }
}
