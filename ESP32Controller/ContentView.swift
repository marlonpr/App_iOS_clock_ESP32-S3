//
//  ContentView.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ESP32ControllerViewModel()
    @State private var isAdvancedDiagnosticsExpanded = false
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan for ESP32 Devices") {
                        dismissKeyboard()
                        viewModel.presentDeviceScanner()
                    }

                    if let connectedDevice = viewModel.connectedDiscoveredDevice {
                        ConnectedDeviceSummary(
                            device: connectedDevice,
                            statusText: viewModel.connectionStatusText,
                            healthAccessibilityValue: viewModel.connectionHealthAccessibilityValue
                        )
                    }

                    ConnectionStatusRow(
                        statusText: viewModel.connectionStatusText,
                        detail: viewModel.state.detail,
                        healthAccessibilityValue: viewModel.connectionHealthAccessibilityValue
                    )

                    if viewModel.canDisconnect {
                        Button("Disconnect", role: .destructive) {
                            dismissKeyboard()
                            viewModel.disconnect()
                        }
                    }
                } header: {
                    Text("ESP32 Devices")
                }

                Section("Clock Controls") {
                    Button("Apply Settings") {
                        dismissKeyboard()
                        viewModel.applyClockConfiguration()
                    }
                    .disabled(!viewModel.canUseClockControls)

                    Picker("Time Format", selection: $viewModel.is24HourFormat) {
                        Text("12 Hour").tag(false)
                        Text("24 Hour").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!viewModel.canUseClockControls)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Brightness")
                            Spacer()
                            Text("\(Int(viewModel.brightnessLevel))")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $viewModel.brightnessLevel, in: 1...10, step: 1)
                            .disabled(!viewModel.canUseClockControls)
                    }

                    Button("Device Default Configuration", role: .destructive) {
                        dismissKeyboard()
                        viewModel.isResetConfirmationPresented = true
                    }
                    .accessibilityLabel("Device Default Configuration")
                    .disabled(!viewModel.canUseClockControls)
                }

                DisclosureGroup("Advanced / Diagnostics", isExpanded: $isAdvancedDiagnosticsExpanded) {
                    AdvancedDiagnosticsContent(
                        viewModel: viewModel,
                        focusedField: $focusedField,
                        dismissKeyboard: dismissKeyboard
                    )
                }
                .accessibilityLabel("Advanced / Diagnostics")
                .accessibilityValue(isAdvancedDiagnosticsExpanded ? "Expanded" : "Collapsed")
                .onChange(of: isAdvancedDiagnosticsExpanded) { _, isExpanded in
                    if !isExpanded, focusedField?.isAdvancedDiagnosticsField == true {
                        dismissKeyboard()
                    }
                }
            }
            .navigationTitle("ESP32 TCP")
            .confirmationDialog(
                "Apply Device Default Configuration?",
                isPresented: $viewModel.isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Apply Default Configuration", role: .destructive) {
                    dismissKeyboard()
                    // Product terminology says "default configuration"; the current transport command remains RT with reset ID 0.
                    viewModel.requestDeviceReset(resetID: 0x00)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will send the device default-configuration command to the connected ESP32.")
            }
            .onDisappear {
                viewModel.stopDiscovery()
            }
            .sheet(isPresented: $viewModel.isScannerPresented) {
                DeviceScannerSheet(viewModel: viewModel)
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
    }
}

private enum FocusedField: Hashable {
    case host
    case port
    case boardID
    case hex

    var isAdvancedDiagnosticsField: Bool {
        switch self {
        case .host, .port, .boardID, .hex:
            true
        }
    }
}

private struct ConnectionStatusRow: View {
    let statusText: String
    let detail: String?
    let healthAccessibilityValue: String

    var body: some View {
        HStack {
            Text("State")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText)
                    .fontWeight(.semibold)
                    .frame(minWidth: 210, alignment: .trailing)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .accessibilityValue(healthAccessibilityValue)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private struct AdvancedDiagnosticsContent: View {
    @ObservedObject var viewModel: ESP32ControllerViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let dismissKeyboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            manualConnection
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Manual Connection")

            Divider()

            rawProtocolCommand
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Raw Protocol Command")

            Divider()

            deviceDiagnostics
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Device Diagnostics")

            Divider()

            commandStatus
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Command Status")

            Divider()

            communicationLog
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Communication Log")
        }
        .padding(.vertical, 4)
    }

    private var manualConnection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual Connection")
                .font(.headline)

            TextField("Host/IP", text: $viewModel.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .focused(focusedField, equals: .host)

            TextField("Port", text: $viewModel.port)
                .keyboardType(.numberPad)
                .focused(focusedField, equals: .port)

            LabeledContent("Board ID") {
                TextField("Optional decimal 0-255, except 92", text: $viewModel.manualBoardID)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .focused(focusedField, equals: .boardID)
            }

            if let detail = viewModel.state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Connect Manually") {
                dismissKeyboard()
                viewModel.connect()
            }
            .disabled(!viewModel.canConnect)
        }
    }

    private var rawProtocolCommand: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw Protocol Command")
                .font(.headline)

            TextField("Example: A5 01 00", text: $viewModel.outgoingHex, axis: .vertical)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .lineLimit(2...4)
                .focused(focusedField, equals: .hex)

            Toggle("Append delimiter 5C", isOn: $viewModel.appendFrameDelimiter)

            Button("Send") {
                dismissKeyboard()
                viewModel.sendHexBytes()
            }
            .disabled(!viewModel.canSend)
        }
    }

    private var deviceDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Diagnostics")
                .font(.headline)

            Button("Read Configuration") {
                dismissKeyboard()
                viewModel.requestClockConfiguration()
            }
            .disabled(!viewModel.canUseClockControls)

            Button("Test Connection") {
                dismissKeyboard()
                viewModel.sendConnectionTest()
            }
            .disabled(!viewModel.canUseClockControls)

            if let unavailableMessage = viewModel.clockControlsUnavailableMessage {
                Text(unavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command Status")
                .font(.headline)

            if let statusMessage = viewModel.commandStatusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No clock command sent yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var communicationLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Communication Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    dismissKeyboard()
                    viewModel.clearLog()
                }
                .font(.caption)
            }

            if viewModel.logEntries.isEmpty {
                Text("No communication yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.logEntries) { entry in
                    CommunicationLogRow(entry: entry)
                }
            }
        }
    }
}

private struct ConnectedDeviceSummary: View {
    let device: DiscoveredESP32
    let statusText: String
    let healthAccessibilityValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.serviceName)
                    .fontWeight(.semibold)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
                    .frame(minWidth: 190, alignment: .trailing)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .accessibilityValue(healthAccessibilityValue)
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
                                connectedStatusText: viewModel.connectionStatusText,
                                connectedHealthAccessibilityValue: viewModel.connectionHealthAccessibilityValue,
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
    let connectedStatusText: String
    let connectedHealthAccessibilityValue: String
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
                            Text(connectedStatusText)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                                .frame(minWidth: 190, alignment: .leading)
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                                .accessibilityValue(connectedHealthAccessibilityValue)
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

            if let message = entry.message, !entry.bytes.isEmpty {
                Text(message)
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
