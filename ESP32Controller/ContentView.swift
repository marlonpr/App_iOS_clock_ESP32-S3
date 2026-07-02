//
//  ContentView.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: ESP32ControllerViewModel
#if LOGIN_ENABLED
    let authenticationDiagnostics: AuthenticationDiagnostics?
    let onLogOutConfirmed: () -> Void
#endif
    @State private var isAdvancedDiagnosticsExpanded = false
    @State private var selectedLogoPhotoItem: PhotosPickerItem?
    @State private var isPNGFileImporterPresented = false
#if LOGIN_ENABLED
    @State private var isLogoutConfirmationPresented = false
#endif
    @FocusState private var focusedField: FocusedField?

#if LOGIN_ENABLED
    init(
        viewModel: ESP32ControllerViewModel,
        authenticationDiagnostics: AuthenticationDiagnostics?,
        onLogOutConfirmed: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.authenticationDiagnostics = authenticationDiagnostics
        self.onLogOutConfirmed = onLogOutConfirmed
    }
#else
    init(viewModel: ESP32ControllerViewModel) {
        self.viewModel = viewModel
    }
#endif

    private var esp32DevicesSection: some View {
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
    }

    private var logoSection: some View {
        Section("Logo") {
            PhotosPicker(
                selection: $selectedLogoPhotoItem,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label("Choose Photo", systemImage: "photo")
            }

            LogoPreviewView(previewImage: viewModel.processedLogoPreview)

            Button("Upload Logo") {
                dismissKeyboard()
                viewModel.uploadLogo()
            }
            .disabled(!viewModel.canUploadLogo)

            Button("Restore Default Logo") {
                dismissKeyboard()
                viewModel.presentRestoreDefaultLogoConfirmation()
            }
            .disabled(!viewModel.canRestoreDefaultLogo)
        }
    }

    private var clockControlsSection: some View {
        Section("Clock Controls") {
            Button("Sync Time") {
                dismissKeyboard()
                viewModel.syncDeviceTime()
            }
            .accessibilityLabel("Sync Time")
            .accessibilityHint("Sets the ESP32 clock to the current date and time from this iPhone.")
            .accessibilityValue(viewModel.timeSyncState.isConfirmationPending ? "Synchronizing" : "")
            .disabled(!viewModel.canSyncTime)

            Button("Next Display Mode") {
                dismissKeyboard()
                viewModel.requestNextDisplayMode()
            }
            .accessibilityLabel("Next Display Mode")
            .accessibilityHint("Advances the ESP32 clock display to the next mode.")
            .accessibilityValue(viewModel.displayModeChangeState.isConfirmationPending ? "Changing" : "")
            .disabled(!viewModel.canRequestNextDisplayMode)

            Picker("Time Format", selection: Binding(
                get: { viewModel.is24HourFormat },
                set: { newValue in
                    dismissKeyboard()
                    viewModel.userSelectedTimeFormat(newValue)
                }
            )) {
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

                Slider(
                    value: $viewModel.brightnessLevel,
                    in: 1...10,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            dismissKeyboard()
                        }
                        viewModel.brightnessEditingChanged(isEditing)
                    }
                )
                    .disabled(!viewModel.canUseClockControls)
            }

            Button("Device Default Configuration", role: .destructive) {
                dismissKeyboard()
                viewModel.isResetConfirmationPresented = true
            }
            .accessibilityLabel("Device Default Configuration")
            .disabled(!viewModel.canUseClockControls)
        }
    }

    private var advancedDiagnosticsSection: some View {
        DisclosureGroup("Advanced / Diagnostics", isExpanded: $isAdvancedDiagnosticsExpanded) {
#if LOGIN_ENABLED
            AdvancedDiagnosticsContent(
                viewModel: viewModel,
                authenticationDiagnostics: authenticationDiagnostics,
                focusedField: $focusedField,
                dismissKeyboard: dismissKeyboard,
                presentPNGImporter: presentLogoPNGFileImporter,
                presentLogoutConfirmation: {
                    dismissKeyboard()
                    isLogoutConfirmationPresented = true
                }
            )
#else
            AdvancedDiagnosticsContent(
                viewModel: viewModel,
                focusedField: $focusedField,
                dismissKeyboard: dismissKeyboard,
                presentPNGImporter: presentLogoPNGFileImporter
            )
#endif
        }
        .accessibilityLabel("Advanced / Diagnostics")
        .accessibilityValue(isAdvancedDiagnosticsExpanded ? "Expanded" : "Collapsed")
        .onChange(of: isAdvancedDiagnosticsExpanded) { _, isExpanded in
            if !isExpanded, focusedField?.isAdvancedDiagnosticsField == true {
                dismissKeyboard()
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                esp32DevicesSection
                logoSection
                clockControlsSection
                advancedDiagnosticsSection
            }
            .navigationTitle("ESP32 TCP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ControllerNavigationTitle()
                }
            }
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
                Text(ESP32ControllerViewModel.deviceDefaultConfigurationConfirmationMessage)
            }
            .alert(
                "Restore Default Logo?",
                isPresented: $viewModel.isRestoreDefaultLogoConfirmationPresented
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    dismissKeyboard()
                    viewModel.restoreDefaultLogo()
                }
            } message: {
                Text(ESP32ControllerViewModel.defaultLogoRestoreConfirmationMessage)
            }
            .alert(
                "Time Synchronized",
                isPresented: Binding(
                    get: { viewModel.isTimeSyncSuccessAlertPresented },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.dismissTimeSyncSuccessAlert()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.dismissTimeSyncSuccessAlert()
                }
            } message: {
                Text("Time synchronized successfully.")
            }
            .alert(
                "Display Mode Changed",
                isPresented: Binding(
                    get: { viewModel.isDisplayModeSuccessAlertPresented },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.dismissDisplayModeSuccessAlert()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.dismissDisplayModeSuccessAlert()
                }
            } message: {
                Text("Display mode changed to Mode \(viewModel.confirmedDisplayMode ?? 0).")
            }
            .alert(
                "Logo Updated",
                isPresented: Binding(
                    get: { viewModel.isLogoUploadSuccessAlertPresented },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.dismissLogoUploadSuccessAlert()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.dismissLogoUploadSuccessAlert()
                }
            } message: {
                Text("The new logo was saved and activated successfully.")
            }
            .alert(
                "Default Logo Restored",
                isPresented: Binding(
                    get: { viewModel.isDefaultLogoRestoreSuccessAlertPresented },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.dismissDefaultLogoRestoreSuccessAlert()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.dismissDefaultLogoRestoreSuccessAlert()
                }
            } message: {
                Text(ESP32ControllerViewModel.defaultLogoRestoreSuccessMessage)
            }
#if LOGIN_ENABLED
            .alert(
                "Log Out?",
                isPresented: $isLogoutConfirmationPresented
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Log Out", role: .destructive) {
                    dismissKeyboard()
                    onLogOutConfirmed()
                }
            } message: {
                Text("This disconnects from the ESP32 and returns to the login screen.")
            }
#endif
            .fileImporter(
                isPresented: $isPNGFileImporterPresented,
                allowedContentTypes: [.png],
                allowsMultipleSelection: false
            ) { result in
                handleLogoPNGFileImport(result)
            }
            .onChange(of: selectedLogoPhotoItem) { _, newItem in
                guard let newItem else {
                    return
                }

                let selectionID = viewModel.beginLogoPhotoSelection()
                Task {
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self) else {
                            await MainActor.run {
                                viewModel.failLogoPhotoSelection("Unable to load the selected photo.", selectionID: selectionID)
                            }
                            return
                        }

                        await MainActor.run {
                            viewModel.convertSelectedLogoImage(
                                data,
                                selectionID: selectionID,
                                source: .photos
                            )
                        }
                    } catch {
                        await MainActor.run {
                            viewModel.failLogoPhotoSelection(error.localizedDescription, selectionID: selectionID)
                        }
                    }
                }
            }
            .sheet(isPresented: $viewModel.isScannerPresented) {
                DeviceScannerSheet(viewModel: viewModel)
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
    }

    private func presentLogoPNGFileImporter() {
        dismissKeyboard()
        isPNGFileImporterPresented = true
    }

    private func handleLogoPNGFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            return
        }

        let selectionID = viewModel.beginLogoFileSelection()
        Task {
            do {
                let data = try readLogoPNGFileData(from: url)
                _ = try LogoImageConverter.validateLosslessPNGData(data)
                await MainActor.run {
                    viewModel.convertSelectedLogoImage(
                        data,
                        selectionID: selectionID,
                        source: .files
                    )
                }
            } catch {
                await MainActor.run {
                    viewModel.failLogoFileSelection(error.localizedDescription, selectionID: selectionID)
                }
            }
        }
    }

    private func readLogoPNGFileData(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try Data(contentsOf: url)
    }
}

private struct ControllerNavigationTitle: View {
    var body: some View {
        HStack(spacing: 7) {
            Text("ESP32 TCP")
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.95)
                .accessibilityAddTraits(.isHeader)

            ZeitBrandBadge(width: 54, isDecorative: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ESP32 TCP")
    }
}

private struct LogoPreviewView: View {
    let previewImage: CGImage?

    var body: some View {
        ZStack {
            Color.black

            if let previewImage {
                Image(decorative: previewImage, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(2, contentMode: .fit)
            }
        }
        .aspectRatio(2, contentMode: .fit)
        .frame(maxWidth: 256)
        .accessibilityLabel("Processed logo preview")
    }
}

private struct LogoUploadStatusView: View {
    let state: LogoUploadState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .converting:
                ProgressView()
                    .controlSize(.small)
                Text("Converting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text("Connecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForReady:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for READY")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .uploading(progress):
                ProgressView(value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .waitingForConfirmation:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for OK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .succeeded:
                Text("Updated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20, alignment: .leading)
    }
}

private struct TimeSyncStatusView: View {
    let state: TimeSyncState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .sending:
                ProgressView()
                    .controlSize(.small)
                Text("Sending time synchronization command...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForConfirmation:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for device confirmation...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .succeeded:
                EmptyView()
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20, alignment: .leading)
    }
}

private struct DisplayModeStatusView: View {
    let state: DisplayModeChangeState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .sending:
                ProgressView()
                    .controlSize(.small)
                Text("Sending display mode command...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForConfirmation:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for device confirmation...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .succeeded:
                EmptyView()
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20, alignment: .leading)
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
#if LOGIN_ENABLED
    let authenticationDiagnostics: AuthenticationDiagnostics?
#endif
    let focusedField: FocusState<FocusedField?>.Binding
    let dismissKeyboard: () -> Void
    let presentPNGImporter: () -> Void
#if LOGIN_ENABLED
    let presentLogoutConfirmation: () -> Void
#endif

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

            appLifecycleDiagnostics
                .accessibilityElement(children: .contain)
                .accessibilityLabel("App Lifecycle Diagnostics")

            Divider()

            timeSynchronizationStatus
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Time Synchronization Status")

            Divider()

            displayModeStatus
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Display Mode Status")

            Divider()

            logoDiagnostics
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Logo Diagnostics")

            Divider()

            commandStatus
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Command Status")

            Divider()

            communicationLog
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Communication Log")

#if LOGIN_ENABLED
            Divider()

            authenticationControls
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Authentication")
#endif
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

    private var logoDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Logo Diagnostics")
                .font(.headline)

            if let diagnostics = viewModel.logoSourceDiagnostics {
                LabeledContent("Source Format") {
                    Text(diagnostics.sourceDisplayName)
                }

                LabeledContent("Source Dimensions") {
                    Text(diagnostics.dimensionsDisplayText)
                }

                LabeledContent("Conversion") {
                    Text(diagnostics.conversionDisplayName)
                }

                if let warning = viewModel.logoSourceCompressionWarning {
                    Label {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("No logo source selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LogoUploadStatusView(state: viewModel.logoUploadState)

            LabeledContent("Logo Service") {
                Text(viewModel.logoServiceDiagnosticsText)
            }

            LabeledContent("Logo Endpoint Source") {
                Text(viewModel.logoEndpointSourceDiagnosticsText)
            }

            LabeledContent("Logo Destination") {
                Text(viewModel.logoDestinationDiagnosticsText)
            }

            Text("Default Logo Restore: \(viewModel.defaultLogoRestoreDiagnosticsText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Import Lossless PNG File") {
                dismissKeyboard()
                presentPNGImporter()
            }
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

            Button("Send Current Settings") {
                dismissKeyboard()
                viewModel.sendCurrentClockConfiguration()
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

    private var appLifecycleDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Lifecycle")
                .font(.headline)

            LabeledContent("App Phase") {
                Text(viewModel.appPhaseDiagnosticsText)
            }

            LabeledContent("Last Device") {
                Text(viewModel.lastDeviceDiagnosticsText)
            }

            LabeledContent("Auto Reconnect") {
                Text(viewModel.autoReconnectDiagnosticsText)
            }

            LabeledContent("Resume Action") {
                Text(viewModel.resumeActionDiagnosticsText)
            }

            LabeledContent("Reconnect Attempt") {
                Text(viewModel.reconnectAttemptDiagnosticsText)
            }

            LabeledContent("Endpoint Source") {
                Text(viewModel.endpointSourceDiagnosticsText)
            }

            LabeledContent("Foreground Validation") {
                Text(viewModel.foregroundValidationDiagnosticsText)
            }
        }
    }

    private var timeSynchronizationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time Synchronization Status")
                .font(.headline)

            TimeSyncStatusView(state: viewModel.timeSyncState)
        }
    }

    private var displayModeStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display Mode Status")
                .font(.headline)

            DisplayModeStatusView(state: viewModel.displayModeChangeState)
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

#if LOGIN_ENABLED
    private var authenticationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authentication")
                .font(.headline)

            if let authenticationDiagnostics {
                LabeledContent("Authentication", value: authenticationDiagnostics.provider)
                LabeledContent("User", value: authenticationDiagnostics.username)
                LabeledContent("Role", value: authenticationDiagnostics.role.rawValue)
                LabeledContent("Server", value: authenticationDiagnostics.server)
                LabeledContent("Session", value: authenticationDiagnostics.sessionStatus)
                if let expiresAt = authenticationDiagnostics.expiresAt {
                    LabeledContent("Expires", value: Self.expirationFormatter.string(from: expiresAt))
                }
            }

            Button("Log Out", role: .destructive) {
                presentLogoutConfirmation()
            }
        }
    }

    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
#endif
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
#if LOGIN_ENABLED
    ContentView(
        viewModel: ESP32ControllerViewModel(),
        authenticationDiagnostics: nil,
        onLogOutConfirmed: {}
    )
#else
    ContentView(viewModel: ESP32ControllerViewModel())
#endif
}
