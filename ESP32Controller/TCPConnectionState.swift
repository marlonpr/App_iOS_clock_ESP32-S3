//
//  TCPConnectionState.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation

enum TCPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .failed:
            "Failed"
        }
    }

    var detail: String? {
        if case let .failed(message) = self {
            return message
        }

        return nil
    }
}
