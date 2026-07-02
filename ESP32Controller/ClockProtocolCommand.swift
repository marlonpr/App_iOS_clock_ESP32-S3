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
    case syncTime(Date)
    case nextDisplayMode
    case readConfiguration
    case reset(resetID: UInt8)
    case restoreDefaultLogo

    var logLabel: String {
        switch self {
        case .connectionTest:
            "ES Connection Test"
        case .setConfiguration:
            "CT Apply Settings"
        case .syncTime:
            "UC Sync Time"
        case .nextDisplayMode:
            "NM Next Display Mode"
        case .readConfiguration:
            "RC Read Configuration"
        case .reset:
            "RT Reset Device"
        case .restoreDefaultLogo:
            "DL Restore Default Logo"
        }
    }

    var sentStatusMessage: String {
        switch self {
        case .syncTime:
            "Time synchronization command sent"
        case .nextDisplayMode:
            "Display mode command sent"
        case .restoreDefaultLogo:
            "Default-logo restore command sent"
        default:
            "Sent \(logLabel)"
        }
    }
}
