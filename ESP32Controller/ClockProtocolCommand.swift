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
    case setDisplayMode(PaletteMode)
    case readConfiguration
    case reset(resetID: UInt8)
    case restoreDefaultLogo
    case loadPalette(PaletteMode)
    case savePalette(ModePaletteDraft)
    case restoreDefaultPalette(PaletteMode)

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
        case let .setDisplayMode(mode):
            "SM Set Display Mode \(mode.rawValue)"
        case .readConfiguration:
            "RC Read Configuration"
        case .reset:
            "RT Reset Device"
        case .restoreDefaultLogo:
            "DL Restore Default Logo"
        case let .loadPalette(mode):
            "LP Read Palette Mode \(mode.rawValue)"
        case let .savePalette(draft):
            "CP Save Palette Mode \(draft.mode.rawValue)"
        case let .restoreDefaultPalette(mode):
            "DP Restore Palette Mode \(mode.rawValue)"
        }
    }

    var sentStatusMessage: String {
        switch self {
        case .syncTime:
            "Time synchronization command sent"
        case .nextDisplayMode:
            "Display mode command sent"
        case let .setDisplayMode(mode):
            "Display mode \(mode.rawValue) requested"
        case .restoreDefaultLogo:
            "Default-logo restore command sent"
        case let .loadPalette(mode):
            "Palette read requested for Mode \(mode.rawValue)"
        case let .savePalette(draft):
            "Palette save requested for Mode \(draft.mode.rawValue)"
        case let .restoreDefaultPalette(mode):
            "Palette default restore requested for Mode \(mode.rawValue)"
        default:
            "Sent \(logLabel)"
        }
    }
}
