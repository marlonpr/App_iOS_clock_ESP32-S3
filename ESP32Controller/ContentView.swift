//
//  ContentView.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ESP32ControllerViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan for ESP32 Devices") {
                        viewModel.presentDeviceScanner()
                    }

                    if let connectedDevice = viewModel.connectedDiscoveredDevice {
                        ConnectedDeviceSummary(device: connectedDevice)
                    }
                } header: {
                    Text("ESP32 Devices")
                }

                Section("Manual Connection") {
                    TextField("IPv4 address", text: $viewModel.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                    TextField("TCP port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    HStack {
                        Text("State")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(viewModel.state.title)
                                .fontWeight(.semibold)

                            if let detail = viewModel.state.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    HStack {
                        Button("Connect") {
                            viewModel.connect()
                        }
                        .disabled(!viewModel.canConnect)

                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                        }
                        .disabled(!viewModel.canDisconnect)
                    }
                }

                Section("Send Hex Bytes") {
                    TextField("Example: A5 01 00", text: $viewModel.outgoingHex, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)

                    Toggle("Append delimiter 5C", isOn: $viewModel.appendFrameDelimiter)

                    Button("Send") {
                        viewModel.sendHexBytes()
                    }
                    .disabled(!viewModel.canSend)
                }

                Section {
                    if viewModel.logEntries.isEmpty {
                        Text("No communication yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.logEntries) { entry in
                            CommunicationLogRow(entry: entry)
                        }
                    }
                } header: {
                    HStack {
                        Text("Communication Log")
                        Spacer()
                        Button("Clear") {
                            viewModel.clearLog()
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("ESP32 TCP")
            .onDisappear {
                viewModel.stopDiscovery()
            }
            .sheet(isPresented: $viewModel.isScannerPresented) {
                DeviceScannerSheet(viewModel: viewModel)
            }
        }
    }
}

private struct ConnectedDeviceSummary: View {
    let device: DiscoveredESP32

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.serviceName)
                    .fontWeight(.semibold)
                Spacer()
                Text("Connected")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            DeviceMetadata(device: device)
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceScannerSheet: View {
    @ObservedObject var viewModel: ESP32ControllerViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch viewModel.scannerState {
                    case .idle:
                        Text("Scanner idle")
                            .foregroundStyle(.secondary)
                    case .scanning:
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning for ESP32 devices...")
                                .foregroundStyle(.secondary)
                        }
                    case .completed:
                        if viewModel.discoveredDevices.isEmpty {
                            Text("No ESP32 devices found.")
                                .foregroundStyle(.secondary)
                        }
                    case let .failed(error):
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    if let connectionError = viewModel.scannerConnectionErrorText {
                        Text(connectionError)
                            .foregroundStyle(.red)
                    }
                }

                Section("Reachable Devices") {
                    if viewModel.discoveredDevices.isEmpty, viewModel.scannerState == .scanning {
                        Text("Waiting for reachable devices")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.discoveredDevices) { device in
                            ScannerDeviceRow(
                                device: device,
                                isConnected: viewModel.connectedEndpointDescription == device.stableEndpointDescription,
                                isPending: viewModel.pendingSelectedEndpointDescription == device.stableEndpointDescription,
                                canConnect: viewModel.canSelectScannedDevice(device)
                            ) {
                                viewModel.connect(to: device)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ESP32 Devices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.closeDeviceScanner()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Rescan") {
                        viewModel.beginDeviceScan()
                    }
                    .disabled(viewModel.scannerState == .scanning)
                }
            }
            .onAppear {
                viewModel.beginDeviceScan()
            }
            .onDisappear {
                viewModel.closeDeviceScanner()
            }
        }
    }
}

private struct ScannerDeviceRow: View {
    let device: DiscoveredESP32
    let isConnected: Bool
    let isPending: Bool
    let canConnect: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.serviceName)
                            .fontWeight(.semibold)

                        if isConnected {
                            Text("Connected")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        } else if isPending {
                            Text("Connecting...")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Online")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                    }

                    DeviceMetadata(device: device)
                }

                Spacer()

                Button(isPending ? "Connecting..." : "Connect", action: connect)
                    .disabled(!canConnect || isConnected)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceMetadata: View {
    let device: DiscoveredESP32

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let boardID = device.boardID {
                Text("Board ID: \(boardID)")
            }

            if let model = device.model {
                Text("Model: \(model)")
            }

            if let firmwareVersion = device.firmwareVersion {
                Text("Firmware: \(firmwareVersion)")
            }

            if let protocolVersion = device.protocolVersion {
                Text("Protocol: \(protocolVersion)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CommunicationLogRow: View {
    let entry: CommunicationLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.direction.rawValue)
                    .font(.caption.monospaced())
                    .fontWeight(.bold)

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.bytes.isEmpty {
                Text(entry.asciiText)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("ASCII") {
                    Text(entry.asciiText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("HEX") {
                    Text(entry.hexText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
