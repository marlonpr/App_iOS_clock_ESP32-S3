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
    let serviceType: String?
    let serviceDomain: String?
    let hostname: String?
    let controlPort: UInt16?
    var logoEndpoint: NWEndpoint?
    var logoUploadEndpoint: DiscoveredLogoUploadEndpoint?
    var livenessState: ESP32LivenessState

    init(
        id: String,
        serviceName: String,
        endpoint: NWEndpoint,
        boardID: String?,
        model: String?,
        protocolVersion: String?,
        firmwareVersion: String?,
        serviceType: String? = nil,
        serviceDomain: String? = nil,
        hostname: String? = nil,
        controlPort: UInt16? = nil,
        logoEndpoint: NWEndpoint? = nil,
        logoUploadEndpoint: DiscoveredLogoUploadEndpoint? = nil,
        livenessState: ESP32LivenessState = .unknown
    ) {
        self.id = id
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.boardID = boardID
        self.model = model
        self.protocolVersion = protocolVersion
        self.firmwareVersion = firmwareVersion
        self.serviceType = serviceType
        self.serviceDomain = serviceDomain
        self.hostname = hostname
        self.controlPort = controlPort
        self.logoEndpoint = logoEndpoint
        self.logoUploadEndpoint = logoUploadEndpoint
        self.livenessState = livenessState
    }

    var stableEndpointDescription: String {
        String(describing: endpoint)
    }
}
