//
//  DiscoveredESP32.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 23/06/26.
//

import Foundation
import Network

enum ESP32LivenessState: Equatable {
    case unknown
    case checking
    case online
    case offline
    case connected

    var title: String {
        switch self {
        case .unknown:
            "Unknown"
        case .checking:
            "Checking"
        case .online:
            "Online"
        case .offline:
            "Offline"
        case .connected:
            "Connected"
        }
    }
}

struct DiscoveredESP32: Identifiable, Equatable {
    let id: String
    let serviceName: String
    let endpoint: NWEndpoint
    let boardID: String?
    let model: String?
    let protocolVersion: String?
    let firmwareVersion: String?
    var livenessState: ESP32LivenessState = .unknown

    var stableEndpointDescription: String {
        String(describing: endpoint)
    }
}
