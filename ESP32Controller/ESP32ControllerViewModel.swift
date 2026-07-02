//
//  ESP32ControllerViewModel.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import Foundation
import Combine
import CoreGraphics
import Network

@MainActor
final class ESP32ControllerViewModel: ObservableObject {
    typealias TimeSyncScheduler = (TimeInterval, @escaping @Sendable () -> Void) -> CancellableTask
    typealias LogoConversion = @Sendable (Data, LogoImageImportSource) throws -> LogoImageConversionResult

    @Published var host = "192.168.4.1"
    @Published var port = String(ESP32TCPClient.defaultPort)
    @Published var manualBoardID = ""
    @Published private(set) var state: TCPConnectionState = .disconnected
    @Published private(set) var discoveryState: ESP32DiscoveryState = .stopped
    @Published private(set) var scannerState: ESP32ScannerState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredESP32] = []
    @Published private(set) var discoveryErrorText: String?
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var connectedEndpointDescription: String?
    @Published private(set) var connectedDiscoveredDevice: DiscoveredESP32?
    @Published private(set) var pendingSelectedEndpointDescription: String?
    @Published private(set) var scannerConnectionErrorText: String?
    @Published private(set) var connectionHealth: ConnectionHealthState = .idle
    @Published var isScannerPresented = false
    @Published private(set) var logEntries: [CommunicationLogEntry] = []
    @Published var outgoingHex = ""
    @Published var appendFrameDelimiter = true
    @Published var is24HourFormat = true
    @Published var brightnessLevel: Double = 5 {
        didSet {
            let clamped = min(max(brightnessLevel, 1), 10)
            if brightnessLevel != clamped {
                brightnessLevel = clamped
            }
        }
    }
    @Published var commandStatusMessage: String?
    @Published var isResetConfirmationPresented = false
    @Published var isRestoreDefaultLogoConfirmationPresented = false
    @Published private(set) var timeSyncState: TimeSyncState = .idle
    @Published private(set) var isTimeSyncSuccessAlertPresented = false
    @Published private(set) var displayModeChangeState: DisplayModeChangeState = .idle
    @Published private(set) var confirmedDisplayMode: UInt8?
    @Published private(set) var isDisplayModeSuccessAlertPresented = false
    @Published private(set) var defaultLogoRestoreState: DefaultLogoRestoreState = .idle
    @Published private(set) var isDefaultLogoRestoreSuccessAlertPresented = false
    @Published private(set) var logoUploadState: LogoUploadState = .idle
    @Published private(set) var convertedLogoPayload: Data?
    @Published private(set) var processedLogoPreview: CGImage?
    @Published private(set) var logoSourceDiagnostics: LogoImageSourceDiagnostics?
    @Published private(set) var isLogoUploadSuccessAlertPresented = false
    @Published private(set) var lastConnectedDevice: LastConnectedDevice?
    @Published private(set) var discoveredLogoUploadEndpoints: [DiscoveredLogoUploadEndpoint] = []
    @Published private(set) var appPhaseDiagnosticsText = "Inactive"
    @Published private(set) var resumeActionDiagnosticsText = "Idle"
    @Published private(set) var reconnectAttemptDiagnosticsText = "None"
    @Published private(set) var endpointSourceDiagnosticsText = "None"
    @Published private(set) var foregroundValidationDiagnosticsText = "Idle"

    nonisolated static let reservedBoardIDMessage = "Board ID 92 is reserved because it equals the protocol frame delimiter 0x5C."
    nonisolated static let defaultLogoRestoreConfirmationMessage = "This removes the uploaded logo from the SD card and activates the logo built into the ESP32."
    nonisolated static let defaultLogoRestoreSuccessMessage = "The logo built into the ESP32 is now active."
    nonisolated static let defaultLogoRestoreTimeoutMessage = "Default-logo restore was not confirmed by the ESP32."
    nonisolated static let deviceDefaultConfigurationConfirmationMessage = "This sends only the device default-configuration command to the connected ESP32. The ESP32 also restores the compiled default logo built into its firmware."
    nonisolated static let timeSyncCompensation: TimeInterval = 1.0
    nonisolated static let timeSyncConfirmationTimeout: TimeInterval = 4
    nonisolated static let defaultLogoRestoreConfirmationTimeout: TimeInterval = 4
    nonisolated static let foregroundHeartbeatValidationTimeout: TimeInterval = 1.75
    nonisolated static let automaticReconnectDelays: [TimeInterval] = [0, 0.5, 1, 2]

    private let client: ESP32TCPClient
    private let discoveryService: ESP32DiscoveryService
    private let currentDateProvider: () -> Date
    private let timeSyncScheduler: TimeSyncScheduler
    private let reconnectScheduler: TimeSyncScheduler
    private let logoImageConverter: LogoConversion
    private let logoUploadClient: ESP32LogoUploadClient
    private let userDefaults: UserDefaults
    private let maxLogEntries = 200
    nonisolated static let lastConnectedDeviceDefaultsKey = "ESP32Controller.LastConnectedDevice.v1"
    private var pendingConnectionEndpointDescription: String?
    private var pendingConnectionDevice: DiscoveredESP32?
    private var pendingManualHost: String?
    private var pendingManualPort: UInt16?
    private var pendingAutomaticReconnectRecord: LastConnectedDevice?
    private var pendingProtocolBoardID: UInt8?
    private var connectedProtocolBoardID: UInt8?
    private var connectionAttempt: ConnectionAttempt = .idle
    private var isExpectingInitialDisconnect = false
    private var isAppActive = false
    private var isBackgroundDisconnectInProgress = false
    private var foregroundReconnectRequired = false
    private var automaticReconnectEnabled = true
    private var userRequestedDisconnect = false
    private var automaticReconnectGeneration: UUID?
    private var automaticReconnectTasks: [CancellableTask] = []
    private var automaticReconnectLastStartedAttemptIndex: Int?
    private var foregroundValidationGeneration: UUID?
    private var foregroundValidationConnectionGeneration: UUID?
    private var didValidateActiveConnectionGeneration: UUID?
    private var brightnessLevelAtEditingStart: UInt8?
    private var lastRequestedClockConfiguration: ClockConfiguration?
    private var pendingTimeSyncOperationID: UUID?
    private var pendingTimeSyncConnectionGeneration: UUID?
    private var timeSyncConfirmationTimeoutTask: CancellableTask?
    private var pendingDisplayModeOperationID: UUID?
    private var pendingDisplayModeConnectionGeneration: UUID?
    private var displayModeConfirmationTimeoutTask: CancellableTask?
    private var pendingDefaultLogoRestoreOperationID: UUID?
    private var pendingDefaultLogoRestoreConnectionGeneration: UUID?
    private var pendingDefaultLogoRestoreBoardID: UInt8?
    private var pendingDefaultLogoRestoreRequestBytes: [UInt8]?
    private var hasLoggedPendingDefaultLogoRestoreRequest = false
    private var defaultLogoRestoreConfirmationTimeoutTask: CancellableTask?
    private var isDeviceDefaultConfigurationSendPending = false
    private var activeConnectionGeneration: UUID?
    private var pendingLogoConversionID: UUID?
    private var logoConversionTask: Task<Void, Never>?
    private var pendingLogoUploadOperationID: UUID?
    private var pendingLogoUploadConnectionGeneration: UUID?
    private var pendingLogoUploadBoardID: UInt8?
    private var cancellables: Set<AnyCancellable> = []

    var canConnect: Bool {
        switch state {
        case .disconnected, .failed:
            true
        case .connecting, .connected:
            false
        }
    }

    var canDisconnect: Bool {
        switch state {
        case .connecting, .connected, .failed:
            true
        case .disconnected:
            false
        }
    }

    var canSend: Bool {
        state == .connected
    }

    var canUseClockControls: Bool {
        state == .connected && connectedProtocolBoardID != nil
    }

    var canSyncTime: Bool {
        canUseClockControls && !timeSyncState.isConfirmationPending
    }

    var canRequestNextDisplayMode: Bool {
        canUseClockControls && !displayModeChangeState.isConfirmationPending
    }

    var canUploadLogo: Bool {
        guard
            state == .connected,
            convertedLogoPayload?.count == LogoFileFormat.payloadLength,
            resolvedLogoUploadTargetForActiveDevice() != nil,
            !logoUploadState.isUploadInProgress
        else {
            return false
        }

        return true
    }

    var canRestoreDefaultLogo: Bool {
        guard
            canUseClockControls,
            let boardID = connectedProtocolBoardID,
            boardID != ESP32TCPClient.reservedBoardID,
            !defaultLogoRestoreState.isConfirmationPending,
            !isRestoreDefaultLogoConfirmationPresented,
            !logoUploadState.isUploadInProgress,
            !isResetConfirmationPresented,
            !isDeviceDefaultConfigurationSendPending
        else {
            return false
        }

        return true
    }

    var defaultLogoRestoreDiagnosticsText: String {
        defaultLogoRestoreState.diagnosticsText
    }

    var lastDeviceDiagnosticsText: String {
        lastConnectedDevice?.displayName ?? "None"
    }

    var autoReconnectDiagnosticsText: String {
        automaticReconnectEnabled && !userRequestedDisconnect ? "Enabled" : "Disabled"
    }

    var logoSourceCompressionWarning: String? {
        logoSourceDiagnostics?.compressionWarning
    }

    var logoServiceDiagnosticsText: String {
        guard state == .connected, connectedProtocolBoardID != nil else {
            return "Unavailable"
        }

        if resolvedLogoUploadTargetForActiveDevice() != nil {
            return "Ready"
        }

        return isRefreshingDevices ? "Resolving…" : "Unavailable"
    }

    var logoEndpointSourceDiagnosticsText: String {
        resolvedLogoUploadTargetForActiveDevice()?.source.diagnosticsText ?? "None"
    }

    var logoDestinationDiagnosticsText: String {
        resolvedLogoUploadTargetForActiveDevice()?.destinationDescription ?? "None"
    }

    var clockControlsUnavailableMessage: String? {
        guard state == .connected else {
            return "Connect to an ESP32 before using clock controls."
        }

        guard connectedProtocolBoardID != nil else {
            return "Clock controls require a valid protocol Board ID. Enter a manual decimal Board ID from 0 through 255 except 92, or connect to a discovered device that advertises one."
        }

        return nil
    }

    var connectionStatusText: String {
        if shouldShowAutomaticReconnectStatus, let lastConnectedDevice {
            return "Reconnecting to \(lastConnectedDevice.displayName)…"
        }

        switch state {
        case .connected:
            switch connectionHealth {
            case .idle, .healthy:
                return "Connected"
            case .waitingForACK:
                return "Connected"
            case let .degraded(missedCount):
                return "Connected · Unstable (\(missedCount)/\(ESP32TCPClient.defaultHeartbeatConfiguration.maximumConsecutiveMisses) missed)"
            case .timedOut:
                return "Connection lost"
            }
        case .disconnected:
            return connectionHealth == .timedOut ? "Connection lost" : state.title
        case .failed:
            return state.detail == "Heartbeat timed out" ? "Connection lost" : state.title
        case .connecting:
            return state.title
        }
    }

    var connectionHealthAccessibilityValue: String {
        switch connectionHealth {
        case .idle:
            return "Heartbeat unavailable"
        case .healthy:
            return "Heartbeat healthy"
        case .waitingForACK:
            return "Heartbeat awaiting acknowledgement"
        case let .degraded(missedCount):
            return "Heartbeat unstable, \(missedCount) of \(ESP32TCPClient.defaultHeartbeatConfiguration.maximumConsecutiveMisses) missed"
        case .timedOut:
            return "Heartbeat timed out"
        }
    }

    init(
        client: ESP32TCPClient? = nil,
        discoveryService: ESP32DiscoveryService? = nil,
        currentDateProvider: @escaping () -> Date = Date.init,
        timeSyncScheduler: @escaping TimeSyncScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return ViewModelDispatchWorkItemCancellable(workItem: workItem)
        },
        reconnectScheduler: @escaping TimeSyncScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return ViewModelDispatchWorkItemCancellable(workItem: workItem)
        },
        logoImageConverter: @escaping LogoConversion = { data, source in
            try LogoImageConverter().convert(data: data, source: source)
        },
        logoUploadClient: ESP32LogoUploadClient? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client ?? ESP32TCPClient()
        self.discoveryService = discoveryService ?? ESP32DiscoveryService()
        self.currentDateProvider = currentDateProvider
        self.timeSyncScheduler = timeSyncScheduler
        self.reconnectScheduler = reconnectScheduler
        self.logoImageConverter = logoImageConverter
        self.logoUploadClient = logoUploadClient ?? ESP32LogoUploadClient()
        self.userDefaults = userDefaults
        self.lastConnectedDevice = Self.loadLastConnectedDevice(from: userDefaults)

        self.client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionStateChange(state)

                self?.state = state
                self?.appendEvent(state.title)
            }
        }

        self.client.onFrameReceived = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.handleReceivedFrame(bytes)
            }
        }

        self.client.onConnectionHealthChange = { [weak self] health in
            DispatchQueue.main.async {
                self?.connectionHealth = health
            }
        }

        self.discoveryService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.discoveryState = state
            }
            .store(in: &cancellables)

        self.discoveryService.$scannerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.scannerState = state
            }
            .store(in: &cancellables)

        self.discoveryService.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.discoveredDevices = devices
                self?.updateConnectedDeviceLogoEndpoint(from: devices)
            }
            .store(in: &cancellables)

        self.discoveryService.$logoUploadEndpoints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endpoints in
                self?.discoveredLogoUploadEndpoints = endpoints
                self?.updateLastConnectedDeviceLogoCache(from: endpoints)
            }
            .store(in: &cancellables)

        self.discoveryService.$errorText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorText in
                self?.discoveryErrorText = errorText
            }
            .store(in: &cancellables)

        self.discoveryService.$isRefreshing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRefreshing in
                self?.isRefreshingDevices = isRefreshing
            }
            .store(in: &cancellables)
    }

    deinit {
        automaticReconnectTasks.forEach { $0.cancel() }
        logoConversionTask?.cancel()
    }

    func startDiscovery() {
        beginDeviceScan()
    }

    func stopDiscovery() {
        discoveryService.stopDiscovery()
    }

    func handleAppBecameActive() {
        let wasActive = isAppActive
        isAppActive = true
        appPhaseDiagnosticsText = "Active"

        if !wasActive {
            discoveryService.resumeDiscoveryPreservingCache(connectedEndpointDescription: connectedEndpointDescription)
        }

        if wasActive, automaticReconnectGeneration != nil || foregroundValidationGeneration != nil {
            return
        }

        if state == .connected {
            validateForegroundConnectionIfNeeded()
        } else {
            startAutomaticReconnectIfPossible()
        }
    }

    func handleAppBecameInactive() {
        appPhaseDiagnosticsText = "Inactive"
    }

    func handleAppEnteredBackground() {
        isAppActive = false
        appPhaseDiagnosticsText = "Background"
        foregroundReconnectRequired = true
        foregroundValidationDiagnosticsText = "Idle"
        cancelForegroundValidation()
        cancelAutomaticReconnect(resetDiagnostics: true)
        resumeActionDiagnosticsText = "Backgrounded"
        discoveryService.pauseDiscoveryPreservingCache()

        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        activeConnectionGeneration = nil
        connectionAttempt = .idle
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingSelectedEndpointDescription = nil
        pendingAutomaticReconnectRecord = nil
        pendingProtocolBoardID = nil
        connectedProtocolBoardID = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        discoveryService.updateConnectedEndpointDescription(nil)
        isBackgroundDisconnectInProgress = true
        client.disconnect()
    }

    func refreshDiscovery() {
        refreshDevices()
    }

    func refreshDevices() {
        beginDeviceScan()
    }

    func presentDeviceScanner() {
        isScannerPresented = true
    }

    func beginDeviceScan() {
        pendingSelectedEndpointDescription = nil
        scannerConnectionErrorText = nil
        discoveryService.beginDeviceScan(connectedEndpointDescription: connectedEndpointDescription)
    }

    func closeDeviceScanner() {
        isScannerPresented = false
        pendingSelectedEndpointDescription = nil
        discoveryService.stopScan()
    }

    func connect() {
        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelForegroundValidation()
        userRequestedDisconnect = false
        automaticReconnectEnabled = true
        foregroundReconnectRequired = false

        guard let parsedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("Port must be 0 through 65535")
            appendEvent("Invalid port")
            return
        }

        let parsedBoardID: UInt8?
        switch Self.manualBoardIDByte(from: manualBoardID) {
        case let .valid(boardID):
            parsedBoardID = boardID
        case let .invalid(message):
            state = .failed(message)
            appendEvent("Invalid board ID")
            return
        }

        pendingProtocolBoardID = parsedBoardID
        pendingManualHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingManualPort = parsedPort
        beginConnectionAttempt(.manual)
        client.connect(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: parsedPort,
            boardID: parsedBoardID
        )
    }

    func connect(to device: DiscoveredESP32) {
        guard canSelectScannedDevice(device) else {
            return
        }

        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelForegroundValidation()
        userRequestedDisconnect = false
        automaticReconnectEnabled = true
        foregroundReconnectRequired = false
        pendingSelectedEndpointDescription = device.stableEndpointDescription
        pendingConnectionDevice = device
        scannerConnectionErrorText = nil
        beginConnectionAttempt(.discovered(device.stableEndpointDescription))

        let boardID = Self.boardIDByte(from: device.boardID)
        pendingProtocolBoardID = boardID
        if boardID == nil, Self.isReservedBoardIDText(device.boardID) {
            appendEvent("Heartbeat unavailable: \(Self.reservedBoardIDMessage)")
        }

        client.connect(to: device.endpoint, boardID: boardID)
    }

    func canSelectScannedDevice(_ device: DiscoveredESP32) -> Bool {
        if automaticReconnectGeneration != nil {
            return connectedEndpointDescription != device.stableEndpointDescription
        }

        if case .connecting = state {
            return false
        }

        if pendingSelectedEndpointDescription != nil {
            return false
        }

        return connectedEndpointDescription != device.stableEndpointDescription
    }

    func disconnect() {
        userRequestedDisconnect = true
        automaticReconnectEnabled = false
        foregroundReconnectRequired = false
        cancelForegroundValidation()
        cancelAutomaticReconnect(resetDiagnostics: true)
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        activeConnectionGeneration = nil
        connectionAttempt = .explicitDisconnect
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingManualHost = nil
        pendingManualPort = nil
        pendingSelectedEndpointDescription = nil
        pendingProtocolBoardID = nil
        connectedProtocolBoardID = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        discoveryService.updateConnectedEndpointDescription(nil)
        client.disconnect()
    }

    func beginLogoPhotoSelection() -> UUID {
        beginLogoSelection()
    }

    func beginLogoFileSelection() -> UUID {
        beginLogoSelection()
    }

    private func beginLogoSelection() -> UUID {
        cancelActiveLogoUpload(resetState: false)
        logoConversionTask?.cancel()
        let conversionID = UUID()
        pendingLogoConversionID = conversionID
        convertedLogoPayload = nil
        processedLogoPreview = nil
        logoSourceDiagnostics = nil
        isLogoUploadSuccessAlertPresented = false
        logoUploadState = .converting
        return conversionID
    }

    func convertSelectedLogoImage(
        _ data: Data,
        selectionID: UUID,
        source: LogoImageImportSource = .photos
    ) {
        guard pendingLogoConversionID == selectionID else {
            return
        }

        logoConversionTask?.cancel()
        let converter = logoImageConverter
        let workerTask = Task.detached(priority: .userInitiated) { () throws -> (LogoImageConversionResult, LogoImageSourceDiagnostics?) in
            let diagnostics = try? LogoImageConverter.sourceDiagnostics(from: data)
            let result = try converter(data, source)
            return (result, diagnostics)
        }
        logoConversionTask = Task { [weak self] in
            do {
                let (result, diagnostics) = try await workerTask.value
                try Task.checkCancellation()
                self?.finishLogoConversion(
                    result,
                    diagnostics: diagnostics,
                    selectionID: selectionID
                )
            } catch is CancellationError {
            } catch {
                self?.failLogoConversion(error.localizedDescription, selectionID: selectionID)
            }
        }
    }

    func failLogoPhotoSelection(_ message: String, selectionID: UUID) {
        failLogoConversion(message, selectionID: selectionID)
    }

    func failLogoFileSelection(_ message: String, selectionID: UUID) {
        failLogoConversion(message, selectionID: selectionID)
    }

    func uploadLogo() {
        guard state == .connected else {
            logoUploadState = .failed("Connect to an ESP32 before uploading a logo.")
            return
        }

        guard let payload = convertedLogoPayload, payload.count == LogoFileFormat.payloadLength else {
            logoUploadState = .failed("Choose and convert a logo image before uploading.")
            return
        }

        guard let target = resolvedLogoUploadTargetForActiveDevice() else {
            logoUploadState = .failed("No matching logo upload service is available.")
            return
        }

        cancelActiveLogoUpload(resetState: false)
        isLogoUploadSuccessAlertPresented = false

        let operationID = UUID()
        let connectionGeneration = activeConnectionGeneration
        let boardID = connectedProtocolBoardID
        pendingLogoUploadOperationID = operationID
        pendingLogoUploadConnectionGeneration = connectionGeneration
        pendingLogoUploadBoardID = boardID

        do {
            let file = try LogoFileFormat.makeFile(payload: payload)
            logoUploadState = .connecting
            logoUploadClient.upload(
                file: file,
                to: target.endpoint,
                operationID: operationID,
                onStateChange: { [weak self] operationID, state in
                    guard
                        let self,
                        self.isCurrentLogoUpload(operationID: operationID, connectionGeneration: connectionGeneration)
                    else {
                        return
                    }

                    self.logoUploadState = state
                },
                onCompletion: { [weak self] operationID, result in
                    guard
                        let self,
                        self.isCurrentLogoUpload(operationID: operationID, connectionGeneration: connectionGeneration)
                    else {
                        return
                    }

                    self.pendingLogoUploadOperationID = nil
                    self.pendingLogoUploadConnectionGeneration = nil
                    self.pendingLogoUploadBoardID = nil
                    switch result {
                    case .success:
                        self.logoUploadState = .succeeded
                        self.isLogoUploadSuccessAlertPresented = true
                        self.appendEvent("Logo upload confirmed")
                    case let .failure(error):
                        let message = error.localizedDescription
                        self.logoUploadState = .failed(message)
                        self.appendEvent("Logo upload failed: \(message)")
                    }
                }
            )
        } catch {
            pendingLogoUploadOperationID = nil
            pendingLogoUploadConnectionGeneration = nil
            pendingLogoUploadBoardID = nil
            logoUploadState = .failed(error.localizedDescription)
        }
    }

    func dismissLogoUploadSuccessAlert() {
        isLogoUploadSuccessAlertPresented = false
        if logoUploadState == .succeeded {
            logoUploadState = convertedLogoPayload?.count == LogoFileFormat.payloadLength ? .ready : .idle
        }
    }

    func presentRestoreDefaultLogoConfirmation() {
        guard canRestoreDefaultLogo else {
            return
        }

        isRestoreDefaultLogoConfirmationPresented = true
    }

    func restoreDefaultLogo() {
        guard !defaultLogoRestoreState.isConfirmationPending else {
            return
        }

        guard state == .connected else {
            failDefaultLogoRestoreBeforeSend("Connect to an ESP32 before sending clock commands.")
            return
        }

        guard !logoUploadState.isUploadInProgress else {
            return
        }

        guard !isDeviceDefaultConfigurationSendPending else {
            return
        }

        cancelDefaultLogoRestoreTasks()
        isDefaultLogoRestoreSuccessAlertPresented = false
        isRestoreDefaultLogoConfirmationPresented = false

        let operationID = UUID()
        let connectionGeneration = activeConnectionGeneration
        let boardID = connectedProtocolBoardID

        pendingDefaultLogoRestoreOperationID = operationID
        pendingDefaultLogoRestoreConnectionGeneration = connectionGeneration
        pendingDefaultLogoRestoreBoardID = boardID
        defaultLogoRestoreState = .sending

        do {
            let bytes = try ClockProtocolEncoder.encode(.restoreDefaultLogo, boardID: boardID)
            pendingDefaultLogoRestoreRequestBytes = bytes
            hasLoggedPendingDefaultLogoRestoreRequest = false

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingDefaultLogoRestoreOperationID == operationID,
                        self.pendingDefaultLogoRestoreConnectionGeneration == connectionGeneration,
                        self.activeConnectionGeneration == connectionGeneration
                    else {
                        return
                    }

                    if let error {
                        self.cancelDefaultLogoRestoreConfirmationTimeout()
                        self.clearPendingDefaultLogoRestoreOperation()
                        self.defaultLogoRestoreState = .failed("Unable to send default-logo restore command")
                        self.commandStatusMessage = "Unable to send default-logo restore command"
                        self.appendEvent("Unable to send default-logo restore command: \(error.localizedDescription)")
                    } else {
                        guard self.defaultLogoRestoreState == .sending else {
                            return
                        }

                        self.defaultLogoRestoreState = .waitingForConfirmation
                        self.logPendingDefaultLogoRestoreRequestIfNeeded()
                        self.scheduleDefaultLogoRestoreConfirmationTimeout(
                            operationID: operationID,
                            connectionGeneration: connectionGeneration
                        )
                        self.commandStatusMessage = ClockProtocolCommand.restoreDefaultLogo.sentStatusMessage
                    }
                }
            }
        } catch {
            clearPendingDefaultLogoRestoreOperation()
            defaultLogoRestoreState = .failed(error.localizedDescription)
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
        }
    }

    func dismissDefaultLogoRestoreSuccessAlert() {
        isDefaultLogoRestoreSuccessAlertPresented = false
        if defaultLogoRestoreState == .succeeded {
            defaultLogoRestoreState = .idle
        }
    }

    func sendHexBytes() {
        do {
            var bytes = try Self.parseHexBytes(outgoingHex)
            if appendFrameDelimiter {
                bytes.append(ESP32TCPClient.frameDelimiter)
            }

            let data = Data(bytes)
            client.send(data) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.appendEvent("Send failed: \(error.localizedDescription)")
                    } else {
                        self?.appendLog(direction: .outgoing, bytes: bytes)
                    }
                }
            }
        } catch {
            appendEvent(error.localizedDescription)
        }
    }

    func sendConnectionTest() {
        sendClockCommand(.connectionTest)
    }

    func userSelectedTimeFormat(_ is24Hour: Bool) {
        guard is24HourFormat != is24Hour else {
            return
        }

        is24HourFormat = is24Hour
        sendCurrentClockConfiguration(
            reason: .timeFormat,
            skipIfLastRequestedMatches: true
        )
    }

    func brightnessEditingChanged(_ isEditing: Bool) {
        if isEditing {
            brightnessLevelAtEditingStart = roundedBrightnessLevel
        } else {
            userFinishedBrightnessSelection()
        }
    }

    func userFinishedBrightnessSelection() {
        let finalLevel = roundedBrightnessLevel
        brightnessLevel = Double(finalLevel)
        defer {
            brightnessLevelAtEditingStart = nil
        }

        if let startLevel = brightnessLevelAtEditingStart, startLevel == finalLevel {
            return
        }

        sendCurrentClockConfiguration(
            reason: .brightness,
            skipIfLastRequestedMatches: true
        )
    }

    func syncDeviceTime() {
        guard state == .connected else {
            let message = "Connect to an ESP32 before sending clock commands."
            isTimeSyncSuccessAlertPresented = false
            timeSyncState = .failed(message)
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        cancelTimeSyncTasks()
        isTimeSyncSuccessAlertPresented = false
        let operationID = UUID()
        pendingTimeSyncOperationID = operationID
        pendingTimeSyncConnectionGeneration = activeConnectionGeneration
        timeSyncState = .sending

        let capturedDate = currentDateProvider()
        let compensatedDate = Self.compensatedTimeSyncDate(from: capturedDate)

        do {
            let bytes = try ClockProtocolEncoder.encode(.syncTime(compensatedDate), boardID: connectedProtocolBoardID)

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingTimeSyncOperationID == operationID,
                        self.pendingTimeSyncConnectionGeneration == self.activeConnectionGeneration
                    else {
                        return
                    }

                    if let error {
                        self.cancelTimeSyncConfirmationTimeout()
                        self.pendingTimeSyncOperationID = nil
                        self.pendingTimeSyncConnectionGeneration = nil
                        self.timeSyncState = .failed("Unable to send time synchronization command")
                        self.commandStatusMessage = "Unable to send time synchronization command"
                        self.appendEvent("Unable to send time synchronization command: \(error.localizedDescription)")
                    } else {
                        guard self.timeSyncState == .sending else {
                            return
                        }

                        self.timeSyncState = .waitingForConfirmation
                        self.scheduleTimeSyncConfirmationTimeout(
                            operationID: operationID,
                            connectionGeneration: self.activeConnectionGeneration
                        )
                        self.commandStatusMessage = "Time synchronization command sent"
                        self.appendLog(direction: .outgoing, bytes: bytes, message: ClockProtocolCommand.syncTime(compensatedDate).logLabel)
                    }
                }
            }
        } catch {
            pendingTimeSyncOperationID = nil
            pendingTimeSyncConnectionGeneration = nil
            timeSyncState = .failed(error.localizedDescription)
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
        }
    }

    func dismissTimeSyncSuccessAlert() {
        isTimeSyncSuccessAlertPresented = false
        if timeSyncState == .succeeded {
            timeSyncState = .idle
        }
    }

    func dismissDisplayModeSuccessAlert() {
        isDisplayModeSuccessAlertPresented = false
        if case .succeeded = displayModeChangeState {
            displayModeChangeState = .idle
        }
        confirmedDisplayMode = nil
    }

    func requestClockConfiguration() {
        sendClockCommand(.readConfiguration)
    }

    func requestNextDisplayMode() {
        guard state == .connected else {
            let message = "Connect to an ESP32 before sending clock commands."
            isDisplayModeSuccessAlertPresented = false
            confirmedDisplayMode = nil
            displayModeChangeState = .failed(message)
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        cancelDisplayModeTasks()
        isDisplayModeSuccessAlertPresented = false
        confirmedDisplayMode = nil
        let operationID = UUID()
        pendingDisplayModeOperationID = operationID
        pendingDisplayModeConnectionGeneration = activeConnectionGeneration
        displayModeChangeState = .sending

        do {
            let bytes = try ClockProtocolEncoder.encode(.nextDisplayMode, boardID: connectedProtocolBoardID)

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingDisplayModeOperationID == operationID,
                        self.pendingDisplayModeConnectionGeneration == self.activeConnectionGeneration
                    else {
                        return
                    }

                    if let error {
                        self.cancelDisplayModeConfirmationTimeout()
                        self.pendingDisplayModeOperationID = nil
                        self.pendingDisplayModeConnectionGeneration = nil
                        self.displayModeChangeState = .failed("Unable to send display mode command")
                        self.commandStatusMessage = "Unable to send display mode command"
                        self.appendEvent("Unable to send display mode command: \(error.localizedDescription)")
                    } else {
                        guard self.displayModeChangeState == .sending else {
                            return
                        }

                        self.displayModeChangeState = .waitingForConfirmation
                        self.scheduleDisplayModeConfirmationTimeout(
                            operationID: operationID,
                            connectionGeneration: self.activeConnectionGeneration
                        )
                        self.commandStatusMessage = ClockProtocolCommand.nextDisplayMode.sentStatusMessage
                        self.appendLog(direction: .outgoing, bytes: bytes, message: ClockProtocolCommand.nextDisplayMode.logLabel)
                    }
                }
            }
        } catch {
            pendingDisplayModeOperationID = nil
            pendingDisplayModeConnectionGeneration = nil
            displayModeChangeState = .failed(error.localizedDescription)
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
        }
    }

    func sendCurrentClockConfiguration() {
        sendCurrentClockConfiguration(
            reason: .currentSettings,
            skipIfLastRequestedMatches: false
        )
    }

    func requestDeviceReset(resetID: UInt8) {
        let tracksDeviceDefaultConfiguration = resetID == 0x00
        if tracksDeviceDefaultConfiguration {
            isDeviceDefaultConfigurationSendPending = true
        }

        let command = ClockProtocolCommand.reset(resetID: resetID)
        sendClockCommand(
            command,
            logLabel: command.logLabel,
            statusMessage: command.sentStatusMessage,
            onSendFinished: { [weak self] in
                if tracksDeviceDefaultConfiguration {
                    self?.isDeviceDefaultConfigurationSendPending = false
                }
            }
        )
    }

    func sendClockCommand(_ command: ClockProtocolCommand) {
        sendClockCommand(command, logLabel: command.logLabel, statusMessage: command.sentStatusMessage)
    }

    private func sendClockCommand(
        _ command: ClockProtocolCommand,
        logLabel: String,
        statusMessage: String,
        onSendSucceeded: (() -> Void)? = nil,
        onSendFinished: (() -> Void)? = nil
    ) {
        guard state == .connected else {
            commandStatusMessage = "Connect to an ESP32 before sending clock commands."
            appendEvent(commandStatusMessage ?? "")
            onSendFinished?()
            return
        }

        do {
            let bytes = try ClockProtocolEncoder.encode(command, boardID: connectedProtocolBoardID)
            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    defer {
                        onSendFinished?()
                    }

                    if let error {
                        self?.commandStatusMessage = "Send failed: \(error.localizedDescription)"
                        self?.appendEvent(self?.commandStatusMessage ?? "Send failed")
                    } else {
                        onSendSucceeded?()
                        self?.commandStatusMessage = statusMessage
                        self?.appendLog(direction: .outgoing, bytes: bytes, message: logLabel)
                    }
                }
            }
        } catch {
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
            onSendFinished?()
        }
    }

    private var roundedBrightnessLevel: UInt8 {
        UInt8(brightnessLevel.rounded())
    }

    private func sendCurrentClockConfiguration(
        reason: ClockConfigurationChangeReason,
        skipIfLastRequestedMatches: Bool
    ) {
        let configuration = ClockConfiguration(
            is24HourFormat: is24HourFormat,
            brightnessLevel: roundedBrightnessLevel
        )

        if skipIfLastRequestedMatches, lastRequestedClockConfiguration == configuration {
            return
        }

        sendClockCommand(
            .setConfiguration(
                format24Hour: configuration.is24HourFormat,
                brightnessLevel: configuration.brightnessLevel
            ),
            logLabel: reason.logLabel,
            statusMessage: reason.statusMessage,
            onSendSucceeded: { [weak self] in
                self?.lastRequestedClockConfiguration = configuration
            }
        )
    }

    func clearLog() {
        logEntries.removeAll()
    }

    private func finishLogoConversion(
        _ result: LogoImageConversionResult,
        diagnostics: LogoImageSourceDiagnostics?,
        selectionID: UUID
    ) {
        guard pendingLogoConversionID == selectionID else {
            return
        }

        pendingLogoConversionID = nil
        logoConversionTask = nil
        convertedLogoPayload = result.payload
        processedLogoPreview = result.previewImage
        logoSourceDiagnostics = diagnostics
        isLogoUploadSuccessAlertPresented = false
        logoUploadState = .ready
    }

    private func failLogoConversion(_ message: String, selectionID: UUID) {
        guard pendingLogoConversionID == selectionID else {
            return
        }

        pendingLogoConversionID = nil
        logoConversionTask = nil
        convertedLogoPayload = nil
        processedLogoPreview = nil
        logoSourceDiagnostics = nil
        isLogoUploadSuccessAlertPresented = false
        logoUploadState = .failed(message)
    }

    private func isCurrentLogoUpload(operationID: UUID, connectionGeneration: UUID?) -> Bool {
        pendingLogoUploadOperationID == operationID &&
            pendingLogoUploadConnectionGeneration == connectionGeneration &&
            activeConnectionGeneration == connectionGeneration &&
            pendingLogoUploadBoardID == connectedProtocolBoardID
    }

    private func cancelActiveLogoUpload(resetState: Bool) {
        logoUploadClient.cancel()
        pendingLogoUploadOperationID = nil
        pendingLogoUploadConnectionGeneration = nil
        pendingLogoUploadBoardID = nil
        isLogoUploadSuccessAlertPresented = false

        if resetState, logoUploadState.isUploadInProgress || logoUploadState == .succeeded {
            logoUploadState = convertedLogoPayload?.count == LogoFileFormat.payloadLength ? .ready : .idle
        }
    }

    private func resolvedLogoUploadTargetForActiveDevice() -> LogoUploadTarget? {
        guard
            state == .connected,
            let boardID = connectedProtocolBoardID,
            boardID != ESP32TCPClient.reservedBoardID
        else {
            return nil
        }

        let record = lastConnectedDevice?.boardID == boardID ? lastConnectedDevice : nil

        if let endpoint = discoveredLogoUploadEndpoint(for: boardID, record: record) {
            return LogoUploadTarget(
                endpoint: endpoint.endpoint,
                source: .discoveredBonjour,
                destinationDescription: Self.destinationDescription(for: endpoint.endpoint)
            )
        }

        if let target = cachedLogoServiceTarget(for: record) {
            return target
        }

        if let target = cachedHostnameLogoTarget(for: record, boardID: boardID) {
            return target
        }

        return nil
    }

    private func discoveredLogoUploadEndpoint(
        for boardID: UInt8,
        record: LastConnectedDevice?
    ) -> DiscoveredLogoUploadEndpoint? {
        let candidates = discoveredLogoUploadEndpoints.filter { $0.boardID == boardID }

        if
            let endpoint = connectedDiscoveredDevice?.logoUploadEndpoint,
            endpoint.boardID == boardID,
            logoEndpoint(endpoint, matches: record)
        {
            return endpoint
        }

        if
            let endpoint = candidates.first(where: { logoEndpoint($0, matches: record) })
        {
            return endpoint
        }

        return candidates.first
    }

    private func logoEndpoint(
        _ endpoint: DiscoveredLogoUploadEndpoint,
        matches record: LastConnectedDevice?
    ) -> Bool {
        guard let record else {
            return true
        }

        if let serviceName = record.logoServiceName, let endpointServiceName = endpoint.serviceName, serviceName != endpointServiceName {
            return false
        }

        if let serviceType = record.logoServiceType, let endpointServiceType = endpoint.serviceType, serviceType != endpointServiceType {
            return false
        }

        if let serviceDomain = record.logoServiceDomain, let endpointServiceDomain = endpoint.serviceDomain, serviceDomain != endpointServiceDomain {
            return false
        }

        if let hostname = record.logoHostname, let endpointHostname = endpoint.hostname, hostname != endpointHostname {
            return false
        }

        return true
    }

    private func cachedLogoServiceTarget(for record: LastConnectedDevice?) -> LogoUploadTarget? {
        guard
            let record,
            let serviceName = record.logoServiceName
        else {
            return nil
        }

        let serviceType = record.logoServiceType ?? ESP32DiscoveryService.logoServiceType
        let serviceDomain = record.logoServiceDomain ?? record.serviceDomain ?? "local"
        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: serviceType,
            domain: serviceDomain,
            interface: nil
        )
        return LogoUploadTarget(
            endpoint: endpoint,
            source: .cachedBonjour,
            destinationDescription: Self.destinationDescription(for: endpoint)
        )
    }

    private func cachedHostnameLogoTarget(
        for record: LastConnectedDevice?,
        boardID: UInt8
    ) -> LogoUploadTarget? {
        let host: String?
        let source: LogoUploadEndpointSource
        if let record {
            switch record.source {
            case .bonjour:
                host = record.logoHostname ?? record.hostname ?? Self.defaultBonjourHostname(boardID: boardID)
                source = .cachedHostname
            case .manual:
                host = record.manualHost ?? record.logoHostname ?? record.hostname
                source = .cachedManualHost
            }
        } else if let connectedDiscoveredDevice {
            host = connectedDiscoveredDevice.hostname ?? Self.defaultBonjourHostname(boardID: boardID)
            source = .cachedHostname
        } else {
            host = nil
            source = .cachedHostname
        }

        let port = record?.logoPort ?? LogoFileFormat.logoUploadPort
        guard
            let host,
            let endpoint = Self.hostPortEndpoint(host: host, port: port)
        else {
            return nil
        }

        return LogoUploadTarget(
            endpoint: endpoint,
            source: source,
            destinationDescription: "\(host):\(port)"
        )
    }

    private static func destinationDescription(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host: host, port: port):
            return "\(host):\(port.rawValue)"
        default:
            return String(describing: endpoint)
        }
    }

    private func clearLogoUploadStateForConnectionChange() {
        cancelActiveLogoUpload(resetState: true)
    }

    private func updateConnectedDeviceLogoEndpoint(from devices: [DiscoveredESP32]) {
        guard
            let connectedEndpointDescription,
            let updatedDevice = devices.first(where: { $0.stableEndpointDescription == connectedEndpointDescription })
        else {
            return
        }

        connectedDiscoveredDevice = updatedDevice
        if let logoUploadEndpoint = updatedDevice.logoUploadEndpoint {
            updateLastConnectedDeviceLogoCache(with: logoUploadEndpoint)
        }
    }

    private func updateLastConnectedDeviceLogoCache(from endpoints: [DiscoveredLogoUploadEndpoint]) {
        guard
            let boardID = connectedProtocolBoardID,
            let endpoint = discoveredLogoUploadEndpoint(for: boardID, record: lastConnectedDevice)
                ?? endpoints.first(where: { $0.boardID == boardID })
        else {
            return
        }

        updateLastConnectedDeviceLogoCache(with: endpoint)
    }

    private func updateLastConnectedDeviceLogoCache(with endpoint: DiscoveredLogoUploadEndpoint) {
        guard
            let boardID = connectedProtocolBoardID,
            endpoint.boardID == boardID,
            let record = lastConnectedDevice,
            record.boardID == boardID
        else {
            return
        }

        let updated = record.withLogoUploadEndpoint(endpoint)
        guard updated != record else {
            return
        }

        lastConnectedDevice = updated
        Self.saveLastConnectedDevice(updated, to: userDefaults)
    }

    private func handleReceivedFrame(_ bytes: [UInt8]) {
        if consumeTimeSyncACKIfExpected(bytes) {
            return
        }

        if consumeDisplayModeResponseIfExpected(bytes) {
            return
        }

        if consumeDefaultLogoRestoreResponseIfExpected(bytes) {
            return
        }

        appendLog(direction: .incoming, bytes: bytes)
    }

    private func consumeTimeSyncACKIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            timeSyncState == .sending || timeSyncState == .waitingForConfirmation,
            pendingTimeSyncOperationID != nil,
            pendingTimeSyncConnectionGeneration == activeConnectionGeneration,
            let boardID = connectedProtocolBoardID,
            Self.isTimeSyncACK(bytes, boardID: boardID)
        else {
            return false
        }

        cancelTimeSyncConfirmationTimeout()
        pendingTimeSyncOperationID = nil
        pendingTimeSyncConnectionGeneration = nil
        timeSyncState = .succeeded
        isTimeSyncSuccessAlertPresented = true
        commandStatusMessage = "Time synchronized successfully"
        appendLog(direction: .incoming, bytes: bytes, message: "UC Sync Time Confirmed")
        return true
    }

    private static func isTimeSyncACK(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes == [0x2F, 0x74, 0x61, boardID, 0x75, 0x63, ESP32TCPClient.frameDelimiter]
    }

    private func consumeDisplayModeResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            displayModeChangeState == .sending || displayModeChangeState == .waitingForConfirmation,
            pendingDisplayModeOperationID != nil,
            pendingDisplayModeConnectionGeneration == activeConnectionGeneration,
            let boardID = connectedProtocolBoardID,
            let mode = Self.displayModeResponseMode(bytes, boardID: boardID)
        else {
            return false
        }

        cancelDisplayModeConfirmationTimeout()
        pendingDisplayModeOperationID = nil
        pendingDisplayModeConnectionGeneration = nil
        confirmedDisplayMode = mode
        displayModeChangeState = .succeeded(mode: mode)
        isDisplayModeSuccessAlertPresented = true
        commandStatusMessage = "Display mode changed to Mode \(mode)"
        appendLog(direction: .incoming, bytes: bytes, message: "NM Display Mode Confirmed")
        return true
    }

    private static func displayModeResponseMode(_ bytes: [UInt8], boardID: UInt8) -> UInt8? {
        guard
            bytes.count == 8,
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID,
            bytes[4] == 0x6E,
            bytes[5] == 0x6D,
            (1...4).contains(bytes[6]),
            bytes[7] == ESP32TCPClient.frameDelimiter
        else {
            return nil
        }

        return bytes[6]
    }

    private func consumeDefaultLogoRestoreResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            defaultLogoRestoreState == .sending || defaultLogoRestoreState == .waitingForConfirmation,
            pendingDefaultLogoRestoreOperationID != nil,
            pendingDefaultLogoRestoreConnectionGeneration == activeConnectionGeneration,
            let boardID = pendingDefaultLogoRestoreBoardID,
            let result = Self.defaultLogoRestoreResponseResult(bytes, boardID: boardID)
        else {
            return false
        }

        cancelDefaultLogoRestoreConfirmationTimeout()
        logPendingDefaultLogoRestoreRequestIfNeeded()
        clearPendingDefaultLogoRestoreOperation()

        switch result {
        case .restored:
            defaultLogoRestoreState = .succeeded
            isDefaultLogoRestoreSuccessAlertPresented = true
            commandStatusMessage = "Default logo restored"
            appendLog(direction: .incoming, bytes: bytes, message: "DL Restore Default Logo Confirmed")
        case .busy:
            let message = "A logo update is already in progress."
            defaultLogoRestoreState = .failed(message)
            commandStatusMessage = message
            appendLog(direction: .incoming, bytes: bytes, message: "DL Restore Default Logo Busy")
        case .storageFailure:
            let message = "The ESP32 could not remove the SD-card logo."
            defaultLogoRestoreState = .failed(message)
            commandStatusMessage = message
            appendLog(direction: .incoming, bytes: bytes, message: "DL Restore Default Logo Failed")
        }

        return true
    }

    private static func defaultLogoRestoreResponseResult(_ bytes: [UInt8], boardID: UInt8) -> DefaultLogoRestoreResult? {
        guard
            bytes.count == 8,
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID,
            bytes[4] == 0x64,
            bytes[5] == 0x6C,
            bytes[7] == ESP32TCPClient.frameDelimiter
        else {
            return nil
        }

        return DefaultLogoRestoreResult(rawValue: bytes[6])
    }

    nonisolated static func compensatedTimeSyncDate(from date: Date) -> Date {
        date.addingTimeInterval(timeSyncCompensation)
    }

    private func scheduleTimeSyncConfirmationTimeout(operationID: UUID, connectionGeneration: UUID?) {
        cancelTimeSyncConfirmationTimeout()
        timeSyncConfirmationTimeoutTask = timeSyncScheduler(Self.timeSyncConfirmationTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingTimeSyncOperationID == operationID,
                    self.pendingTimeSyncConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.timeSyncState == .waitingForConfirmation
                else {
                    return
                }

                self.timeSyncConfirmationTimeoutTask = nil
                self.pendingTimeSyncOperationID = nil
                self.pendingTimeSyncConnectionGeneration = nil
                self.timeSyncState = .failed("Time synchronization not confirmed")
                self.commandStatusMessage = "Time synchronization not confirmed"
                self.appendEvent("Time synchronization not confirmed")
            }
        }
    }

    private func cancelTimeSyncConfirmationTimeout() {
        timeSyncConfirmationTimeoutTask?.cancel()
        timeSyncConfirmationTimeoutTask = nil
    }

    private func cancelTimeSyncTasks() {
        timeSyncConfirmationTimeoutTask?.cancel()
        timeSyncConfirmationTimeoutTask = nil
    }

    private func scheduleDisplayModeConfirmationTimeout(operationID: UUID, connectionGeneration: UUID?) {
        cancelDisplayModeConfirmationTimeout()
        displayModeConfirmationTimeoutTask = timeSyncScheduler(Self.timeSyncConfirmationTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingDisplayModeOperationID == operationID,
                    self.pendingDisplayModeConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.displayModeChangeState == .waitingForConfirmation
                else {
                    return
                }

                self.displayModeConfirmationTimeoutTask = nil
                self.pendingDisplayModeOperationID = nil
                self.pendingDisplayModeConnectionGeneration = nil
                self.confirmedDisplayMode = nil
                self.displayModeChangeState = .failed("Display mode change not confirmed")
                self.commandStatusMessage = "Display mode change not confirmed"
                self.appendEvent("Display mode change not confirmed")
            }
        }
    }

    private func cancelDisplayModeConfirmationTimeout() {
        displayModeConfirmationTimeoutTask?.cancel()
        displayModeConfirmationTimeoutTask = nil
    }

    private func cancelDisplayModeTasks() {
        displayModeConfirmationTimeoutTask?.cancel()
        displayModeConfirmationTimeoutTask = nil
    }

    private func scheduleDefaultLogoRestoreConfirmationTimeout(operationID: UUID, connectionGeneration: UUID?) {
        cancelDefaultLogoRestoreConfirmationTimeout()
        defaultLogoRestoreConfirmationTimeoutTask = timeSyncScheduler(Self.defaultLogoRestoreConfirmationTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingDefaultLogoRestoreOperationID == operationID,
                    self.pendingDefaultLogoRestoreConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.defaultLogoRestoreState == .waitingForConfirmation
                else {
                    return
                }

                self.defaultLogoRestoreConfirmationTimeoutTask = nil
                self.clearPendingDefaultLogoRestoreOperation()
                self.defaultLogoRestoreState = .failed(Self.defaultLogoRestoreTimeoutMessage)
                self.commandStatusMessage = Self.defaultLogoRestoreTimeoutMessage
                self.appendEvent(Self.defaultLogoRestoreTimeoutMessage)
            }
        }
    }

    private func cancelDefaultLogoRestoreConfirmationTimeout() {
        defaultLogoRestoreConfirmationTimeoutTask?.cancel()
        defaultLogoRestoreConfirmationTimeoutTask = nil
    }

    private func cancelDefaultLogoRestoreTasks() {
        defaultLogoRestoreConfirmationTimeoutTask?.cancel()
        defaultLogoRestoreConfirmationTimeoutTask = nil
    }

    private func clearPendingDefaultLogoRestoreOperation() {
        pendingDefaultLogoRestoreOperationID = nil
        pendingDefaultLogoRestoreConnectionGeneration = nil
        pendingDefaultLogoRestoreBoardID = nil
        pendingDefaultLogoRestoreRequestBytes = nil
        hasLoggedPendingDefaultLogoRestoreRequest = false
    }

    private func logPendingDefaultLogoRestoreRequestIfNeeded() {
        guard
            !hasLoggedPendingDefaultLogoRestoreRequest,
            let bytes = pendingDefaultLogoRestoreRequestBytes
        else {
            return
        }

        hasLoggedPendingDefaultLogoRestoreRequest = true
        appendLog(direction: .outgoing, bytes: bytes, message: ClockProtocolCommand.restoreDefaultLogo.logLabel)
    }

    private func failDefaultLogoRestoreBeforeSend(_ message: String) {
        cancelDefaultLogoRestoreTasks()
        clearPendingDefaultLogoRestoreOperation()
        isDefaultLogoRestoreSuccessAlertPresented = false
        defaultLogoRestoreState = .failed(message)
        commandStatusMessage = message
        appendEvent(message)
    }

    private func clearTimeSyncStateForConnectionChange() {
        cancelTimeSyncTasks()
        pendingTimeSyncOperationID = nil
        pendingTimeSyncConnectionGeneration = nil
        isTimeSyncSuccessAlertPresented = false
        timeSyncState = .idle
    }

    private func clearDisplayModeStateForConnectionChange() {
        cancelDisplayModeTasks()
        pendingDisplayModeOperationID = nil
        pendingDisplayModeConnectionGeneration = nil
        isDisplayModeSuccessAlertPresented = false
        confirmedDisplayMode = nil
        displayModeChangeState = .idle
    }

    private func clearDefaultLogoRestoreStateForConnectionChange() {
        cancelDefaultLogoRestoreTasks()
        clearPendingDefaultLogoRestoreOperation()
        isDefaultLogoRestoreSuccessAlertPresented = false
        isRestoreDefaultLogoConfirmationPresented = false
        defaultLogoRestoreState = .idle
        isDeviceDefaultConfigurationSendPending = false
    }

    private func clearClockConfigurationCacheForConnectionChange() {
        lastRequestedClockConfiguration = nil
    }

    private func appendEvent(_ message: String) {
        appendLog(direction: .event, bytes: [], message: message)
    }

    private func beginConnectionAttempt(_ target: ConnectionTarget) {
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        activeConnectionGeneration = UUID()
        connectionAttempt = .starting(target)
        isExpectingInitialDisconnect = true
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        connectedProtocolBoardID = nil
        discoveryService.updateConnectedEndpointDescription(nil)

        switch target {
        case .manual:
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingAutomaticReconnectRecord = nil
            pendingSelectedEndpointDescription = nil
            scannerConnectionErrorText = nil
        case let .discovered(endpointDescription):
            pendingConnectionEndpointDescription = endpointDescription
            pendingAutomaticReconnectRecord = nil
        case let .automaticReconnect(record):
            pendingConnectionEndpointDescription = record.endpointDescription
        }
    }

    private func handleConnectionStateChange(_ newState: TCPConnectionState) {
        switch newState {
        case .connecting:
            if case let .starting(target) = connectionAttempt {
                connectionAttempt = .connecting(target)
            }
        case .connected:
            switch connectionAttempt {
            case let .starting(target), let .connecting(target):
                completeConnection(to: target)
            case .idle, .connected, .explicitDisconnect:
                break
            }
        case .failed:
            cancelForegroundValidation()
            clearTimeSyncStateForConnectionChange()
            clearDisplayModeStateForConnectionChange()
            clearDefaultLogoRestoreStateForConnectionChange()
            clearLogoUploadStateForConnectionChange()
            clearClockConfigurationCacheForConnectionChange()
            activeConnectionGeneration = nil
            isExpectingInitialDisconnect = false
            connectionAttempt = .idle
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingAutomaticReconnectRecord = nil
            pendingSelectedEndpointDescription = nil
            scannerConnectionErrorText = newState.detail ?? newState.title
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
            connectedProtocolBoardID = nil
            pendingProtocolBoardID = nil
            discoveryService.updateConnectedEndpointDescription(nil)
            finishAutomaticReconnectIfLastAttemptFailed()
        case .disconnected:
            if isBackgroundDisconnectInProgress {
                isBackgroundDisconnectInProgress = false
            }

            if isExpectingInitialDisconnect {
                isExpectingInitialDisconnect = false
                return
            }

            cancelForegroundValidation()
            clearTimeSyncStateForConnectionChange()
            clearDisplayModeStateForConnectionChange()
            clearDefaultLogoRestoreStateForConnectionChange()
            clearLogoUploadStateForConnectionChange()
            clearClockConfigurationCacheForConnectionChange()
            activeConnectionGeneration = nil
            connectionAttempt = .idle
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingAutomaticReconnectRecord = nil
            pendingSelectedEndpointDescription = nil
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
            connectedProtocolBoardID = nil
            pendingProtocolBoardID = nil
            discoveryService.updateConnectedEndpointDescription(nil)
            finishAutomaticReconnectIfLastAttemptFailed()
        }
    }

    private func completeConnection(to target: ConnectionTarget) {
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        foregroundReconnectRequired = false
        didValidateActiveConnectionGeneration = nil

        switch target {
        case .manual:
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
        case let .discovered(endpointDescription):
            connectedEndpointDescription = endpointDescription
            connectedDiscoveredDevice = pendingConnectionDevice
            isScannerPresented = false
            discoveryService.stopScan()
        case let .automaticReconnect(record):
            connectedEndpointDescription = pendingConnectionEndpointDescription ?? record.endpointDescription
            connectedDiscoveredDevice = pendingConnectionDevice
            resumeActionDiagnosticsText = "Connected"
            foregroundValidationDiagnosticsText = "Idle"
        }

        connectedProtocolBoardID = pendingProtocolBoardID
        persistLastConnectedDeviceIfPossible(for: target, boardID: pendingProtocolBoardID)
        pendingSelectedEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingManualHost = nil
        pendingManualPort = nil
        pendingProtocolBoardID = nil
        scannerConnectionErrorText = nil
        discoveryService.updateConnectedEndpointDescription(connectedEndpointDescription)
        connectionAttempt = .connected(target)
        cancelAutomaticReconnect(resetDiagnostics: false)
    }

    private var shouldShowAutomaticReconnectStatus: Bool {
        automaticReconnectGeneration != nil && state != .connected
    }

    private func validateForegroundConnectionIfNeeded() {
        guard
            isAppActive,
            foregroundValidationGeneration == nil,
            let connectionGeneration = activeConnectionGeneration,
            connectedProtocolBoardID != nil
        else {
            return
        }

        guard didValidateActiveConnectionGeneration != connectionGeneration || foregroundReconnectRequired else {
            return
        }

        let validationID = UUID()
        foregroundValidationGeneration = validationID
        foregroundValidationConnectionGeneration = connectionGeneration
        resumeActionDiagnosticsText = "Validating connection"
        foregroundValidationDiagnosticsText = "Waiting for heartbeat"

        client.validateActiveConnectionWithHeartbeat(timeout: Self.foregroundHeartbeatValidationTimeout) { [weak self] isHealthy in
            DispatchQueue.main.async {
                guard
                    let self,
                    self.foregroundValidationGeneration == validationID,
                    self.foregroundValidationConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration
                else {
                    return
                }

                self.foregroundValidationGeneration = nil
                self.foregroundValidationConnectionGeneration = nil

                if isHealthy {
                    self.foregroundReconnectRequired = false
                    self.didValidateActiveConnectionGeneration = connectionGeneration
                    self.resumeActionDiagnosticsText = "Connected"
                    self.foregroundValidationDiagnosticsText = "Confirmed"
                } else {
                    self.foregroundReconnectRequired = true
                    self.didValidateActiveConnectionGeneration = nil
                    self.resumeActionDiagnosticsText = "Reconnecting"
                    self.foregroundValidationDiagnosticsText = "Failed"
                    self.state = .disconnected
                    self.client.disconnect()
                    self.startAutomaticReconnectIfPossible(replacingCurrentConnection: true)
                }
            }
        }
    }

    private func startAutomaticReconnectIfPossible(replacingCurrentConnection: Bool = false) {
        guard
            isAppActive,
            automaticReconnectEnabled,
            !userRequestedDisconnect,
            automaticReconnectGeneration == nil,
            let record = lastConnectedDevice,
            record.boardID != ESP32TCPClient.reservedBoardID
        else {
            return
        }

        if state == .connected, !replacingCurrentConnection {
            return
        }

        let generation = UUID()
        automaticReconnectGeneration = generation
        foregroundReconnectRequired = false
        resumeActionDiagnosticsText = "Reconnecting"
        foregroundValidationDiagnosticsText = "Idle"
        reconnectAttemptDiagnosticsText = "0 of \(Self.automaticReconnectDelays.count)"
        endpointSourceDiagnosticsText = "None"
        automaticReconnectLastStartedAttemptIndex = nil

        for (index, delay) in Self.automaticReconnectDelays.enumerated() {
            if delay == 0 {
                performAutomaticReconnectAttempt(index: index, generation: generation, record: record)
            } else {
                let task = reconnectScheduler(delay) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.performAutomaticReconnectAttempt(index: index, generation: generation, record: record)
                    }
                }
                automaticReconnectTasks.append(task)
            }
        }
    }

    private func performAutomaticReconnectAttempt(
        index: Int,
        generation: UUID,
        record: LastConnectedDevice
    ) {
        guard
            automaticReconnectGeneration == generation,
            isAppActive,
            automaticReconnectEnabled,
            !userRequestedDisconnect
        else {
            return
        }

        if state == .connected {
            cancelAutomaticReconnect(resetDiagnostics: false)
            return
        }

        guard let candidate = automaticReconnectCandidate(for: record, attemptIndex: index) else {
            if Self.automaticReconnectDelays.indices.last == index {
                finishAutomaticReconnectAttempts(generation: generation)
            }
            return
        }

        pendingAutomaticReconnectRecord = record
        pendingConnectionDevice = candidate.device
        pendingProtocolBoardID = record.boardID
        pendingConnectionEndpointDescription = candidate.endpointDescription
        reconnectAttemptDiagnosticsText = "\(index + 1) of \(Self.automaticReconnectDelays.count)"
        endpointSourceDiagnosticsText = candidate.source.diagnosticsText
        automaticReconnectLastStartedAttemptIndex = index

        beginConnectionAttempt(.automaticReconnect(record))
        client.connect(to: candidate.endpoint, boardID: record.boardID)
    }

    private func finishAutomaticReconnectIfLastAttemptFailed() {
        guard
            let generation = automaticReconnectGeneration,
            automaticReconnectLastStartedAttemptIndex == Self.automaticReconnectDelays.indices.last
        else {
            return
        }

        finishAutomaticReconnectAttempts(generation: generation)
    }

    private func finishAutomaticReconnectAttempts(generation: UUID) {
        guard automaticReconnectGeneration == generation else {
            return
        }

        cancelAutomaticReconnect(resetDiagnostics: false)
        resumeActionDiagnosticsText = "Idle"
        endpointSourceDiagnosticsText = "None"
    }

    private func cancelAutomaticReconnect(resetDiagnostics: Bool) {
        automaticReconnectTasks.forEach { $0.cancel() }
        automaticReconnectTasks.removeAll()
        automaticReconnectGeneration = nil
        automaticReconnectLastStartedAttemptIndex = nil
        pendingAutomaticReconnectRecord = nil

        if resetDiagnostics {
            resumeActionDiagnosticsText = "Idle"
            reconnectAttemptDiagnosticsText = "None"
            endpointSourceDiagnosticsText = "None"
        }
    }

    private func cancelForegroundValidation() {
        foregroundValidationGeneration = nil
        foregroundValidationConnectionGeneration = nil
    }

    private func automaticReconnectCandidate(
        for record: LastConnectedDevice,
        attemptIndex: Int
    ) -> AutomaticReconnectCandidate? {
        switch record.source {
        case .bonjour:
            if attemptIndex == 0, let device = discoveredDevice(matching: record) {
                return AutomaticReconnectCandidate(
                    endpoint: device.endpoint,
                    endpointDescription: device.stableEndpointDescription,
                    source: .discoveredBonjour,
                    device: device
                )
            }

            let serviceCandidate = serviceEndpointCandidate(for: record)
            let hostnameCandidate = hostnameEndpointCandidate(for: record, source: .cachedHostname)

            if attemptIndex == 1 {
                return hostnameCandidate ?? serviceCandidate
            }

            if attemptIndex == 3 {
                return hostnameCandidate ?? serviceCandidate
            }

            return serviceCandidate ?? hostnameCandidate
        case .manual:
            return hostnameEndpointCandidate(for: record, source: .cachedManualHost)
        }
    }

    private func discoveredDevice(matching record: LastConnectedDevice) -> DiscoveredESP32? {
        discoveredDevices.first { device in
            guard ESP32DiscoveryService.strictTXTBoardIDByte(from: device.boardID) == record.boardID else {
                return false
            }

            if let serviceInstanceName = record.serviceInstanceName, device.serviceName != serviceInstanceName {
                return false
            }

            if let serviceType = record.serviceType, let deviceServiceType = device.serviceType, serviceType != deviceServiceType {
                return false
            }

            if let serviceDomain = record.serviceDomain, let deviceServiceDomain = device.serviceDomain, serviceDomain != deviceServiceDomain {
                return false
            }

            return true
        }
    }

    private func serviceEndpointCandidate(for record: LastConnectedDevice) -> AutomaticReconnectCandidate? {
        guard
            let serviceInstanceName = record.serviceInstanceName,
            let serviceType = record.serviceType,
            let serviceDomain = record.serviceDomain
        else {
            return nil
        }

        let endpoint = NWEndpoint.service(
            name: serviceInstanceName,
            type: serviceType,
            domain: serviceDomain,
            interface: nil
        )
        return AutomaticReconnectCandidate(
            endpoint: endpoint,
            endpointDescription: String(describing: endpoint),
            source: .cachedBonjour,
            device: nil
        )
    }

    private func hostnameEndpointCandidate(
        for record: LastConnectedDevice,
        source: AutomaticReconnectEndpointSource
    ) -> AutomaticReconnectCandidate? {
        let host: String?
        switch record.source {
        case .bonjour:
            host = record.hostname
        case .manual:
            host = record.manualHost ?? record.hostname
        }

        guard
            let host,
            let endpoint = Self.hostPortEndpoint(host: host, port: record.controlPort)
        else {
            return nil
        }

        return AutomaticReconnectCandidate(
            endpoint: endpoint,
            endpointDescription: String(describing: endpoint),
            source: source,
            device: nil
        )
    }

    private func persistLastConnectedDeviceIfPossible(for target: ConnectionTarget, boardID: UInt8?) {
        guard let boardID, boardID != ESP32TCPClient.reservedBoardID else {
            return
        }

        let record: LastConnectedDevice?
        switch target {
        case .manual:
            guard let host = pendingManualHost, let port = pendingManualPort else {
                record = nil
                break
            }

            record = LastConnectedDevice(
                boardID: boardID,
                displayName: host,
                serviceInstanceName: nil,
                serviceType: nil,
                serviceDomain: nil,
                hostname: host,
                controlPort: port,
                source: .manual,
                manualHost: host,
                logoServiceName: nil,
                logoServiceType: nil,
                logoServiceDomain: nil,
                logoHostname: host,
                logoPort: LogoFileFormat.logoUploadPort
            )
        case .discovered:
            if let device = pendingConnectionDevice {
                record = Self.lastConnectedDevice(from: device, boardID: boardID)
            } else {
                record = nil
            }
        case let .automaticReconnect(existingRecord):
            record = existingRecord.withDefaultLogoFallback()
        }

        guard let record else {
            return
        }

        lastConnectedDevice = record
        Self.saveLastConnectedDevice(record, to: userDefaults)
    }

    private static func lastConnectedDevice(from device: DiscoveredESP32, boardID: UInt8) -> LastConnectedDevice {
        let serviceMetadata = ESP32DiscoveryService.serviceEndpointMetadata(from: device.endpoint)
        return LastConnectedDevice(
            boardID: boardID,
            displayName: device.serviceName,
            serviceInstanceName: serviceMetadata?.name ?? device.serviceName,
            serviceType: device.serviceType ?? serviceMetadata?.type ?? ESP32DiscoveryService.serviceType,
            serviceDomain: device.serviceDomain ?? serviceMetadata?.domain ?? "local",
            hostname: device.hostname ?? defaultBonjourHostname(boardID: boardID),
            controlPort: device.controlPort ?? ESP32TCPClient.defaultPort,
            source: .bonjour,
            manualHost: nil,
            logoServiceName: nil,
            logoServiceType: nil,
            logoServiceDomain: nil,
            logoHostname: device.hostname ?? defaultBonjourHostname(boardID: boardID),
            logoPort: LogoFileFormat.logoUploadPort
        ).withLogoUploadEndpoint(device.logoUploadEndpoint)
    }

    private static func defaultBonjourHostname(boardID: UInt8) -> String {
        "esp32-clock-\(boardID).local"
    }

    private static func hostPortEndpoint(host: String, port: UInt16) -> NWEndpoint? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }

        if let address = IPv4Address(host) {
            return .hostPort(host: .ipv4(address), port: nwPort)
        }

        return .hostPort(host: .name(host, nil), port: nwPort)
    }

    private static func loadLastConnectedDevice(from userDefaults: UserDefaults) -> LastConnectedDevice? {
        guard
            let data = userDefaults.data(forKey: lastConnectedDeviceDefaultsKey),
            let record = try? JSONDecoder().decode(LastConnectedDevice.self, from: data),
            record.boardID != ESP32TCPClient.reservedBoardID
        else {
            return nil
        }

        return record.withDefaultLogoFallback()
    }

    private static func saveLastConnectedDevice(_ record: LastConnectedDevice, to userDefaults: UserDefaults) {
        guard
            record.boardID != ESP32TCPClient.reservedBoardID,
            let data = try? JSONEncoder().encode(record)
        else {
            return
        }

        userDefaults.set(data, forKey: lastConnectedDeviceDefaultsKey)
    }

    private func appendLog(
        direction: CommunicationLogEntry.Direction,
        bytes: [UInt8],
        message: String? = nil
    ) {
        logEntries.append(
            CommunicationLogEntry(
                timestamp: Date(),
                direction: direction,
                bytes: bytes,
                message: message
            )
        )

        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    private static func parseHexBytes(_ text: String) throws -> [UInt8] {
        let compact = text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let tokens = compact
            .split(separator: " ")
            .map(String.init)

        guard !tokens.isEmpty else {
            throw HexInputError.empty
        }

        return try tokens.map { token in
            guard token.count <= 2, let byte = UInt8(token, radix: 16) else {
                throw HexInputError.invalidToken(token)
            }

            return byte
        }
    }

    static func boardIDByte(from boardID: String?) -> UInt8? {
        guard let boardID else {
            return nil
        }

        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let byte = UInt8(trimmed, radix: 10), byte != ESP32TCPClient.reservedBoardID else {
            return nil
        }

        return byte
    }

    static func manualBoardIDByte(from boardID: String) -> ManualBoardIDParseResult {
        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .valid(nil)
        }

        guard let byte = boardIDByte(from: trimmed) else {
            if isReservedBoardIDText(trimmed) {
                return .invalid(reservedBoardIDMessage)
            }

            return .invalid("Board ID must be a decimal value from 0 through 255")
        }

        return .valid(byte)
    }

    private static func isReservedBoardIDText(_ boardID: String?) -> Bool {
        guard let boardID else {
            return false
        }

        let trimmed = boardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            return false
        }

        return UInt8(trimmed, radix: 10) == ESP32TCPClient.reservedBoardID
    }
}

enum ManualBoardIDParseResult: Equatable {
    case valid(UInt8?)
    case invalid(String)
}

enum TimeSyncState: Equatable {
    case idle
    case sending
    case waitingForConfirmation
    case succeeded
    case failed(String)

    var isConfirmationPending: Bool {
        switch self {
        case .sending, .waitingForConfirmation:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }
}

enum DisplayModeChangeState: Equatable {
    case idle
    case sending
    case waitingForConfirmation
    case succeeded(mode: UInt8)
    case failed(String)

    var isConfirmationPending: Bool {
        switch self {
        case .sending, .waitingForConfirmation:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }
}

enum DefaultLogoRestoreState: Equatable {
    case idle
    case sending
    case waitingForConfirmation
    case succeeded
    case failed(String)

    var isConfirmationPending: Bool {
        switch self {
        case .sending, .waitingForConfirmation:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    var diagnosticsText: String {
        switch self {
        case .idle:
            "Idle"
        case .sending:
            "Sending command"
        case .waitingForConfirmation:
            "Waiting for ESP32 confirmation"
        case .succeeded:
            "Succeeded"
        case let .failed(message):
            "Failed — \(message)"
        }
    }
}

private enum DefaultLogoRestoreResult: UInt8 {
    case restored = 0x00
    case busy = 0x01
    case storageFailure = 0x02
}

struct LastConnectedDevice: Codable, Equatable {
    enum Source: String, Codable {
        case bonjour
        case manual
    }

    let boardID: UInt8
    let displayName: String
    let serviceInstanceName: String?
    let serviceType: String?
    let serviceDomain: String?
    let hostname: String?
    let controlPort: UInt16
    let source: Source
    let manualHost: String?
    let logoServiceName: String?
    let logoServiceType: String?
    let logoServiceDomain: String?
    let logoHostname: String?
    let logoPort: UInt16?

    init(
        boardID: UInt8,
        displayName: String,
        serviceInstanceName: String?,
        serviceType: String?,
        serviceDomain: String?,
        hostname: String?,
        controlPort: UInt16,
        source: Source,
        manualHost: String?,
        logoServiceName: String? = nil,
        logoServiceType: String? = nil,
        logoServiceDomain: String? = nil,
        logoHostname: String? = nil,
        logoPort: UInt16? = nil
    ) {
        self.boardID = boardID
        self.displayName = displayName
        self.serviceInstanceName = serviceInstanceName
        self.serviceType = serviceType
        self.serviceDomain = serviceDomain
        self.hostname = hostname
        self.controlPort = controlPort
        self.source = source
        self.manualHost = manualHost
        self.logoServiceName = logoServiceName
        self.logoServiceType = logoServiceType
        self.logoServiceDomain = logoServiceDomain
        self.logoHostname = logoHostname
        self.logoPort = logoPort
    }

    var endpointDescription: String {
        if
            let serviceInstanceName,
            let serviceType,
            let serviceDomain
        {
            return String(describing: NWEndpoint.service(
                name: serviceInstanceName,
                type: serviceType,
                domain: serviceDomain,
                interface: nil
            ))
        }

        if let manualHost {
            return "\(manualHost):\(controlPort)"
        }

        if let hostname {
            return "\(hostname):\(controlPort)"
        }

        return displayName
    }

    func withLogoUploadEndpoint(_ endpoint: DiscoveredLogoUploadEndpoint?) -> LastConnectedDevice {
        guard let endpoint, endpoint.boardID == boardID else {
            return withDefaultLogoFallback()
        }

        return LastConnectedDevice(
            boardID: boardID,
            displayName: displayName,
            serviceInstanceName: serviceInstanceName,
            serviceType: serviceType,
            serviceDomain: serviceDomain,
            hostname: hostname,
            controlPort: controlPort,
            source: source,
            manualHost: manualHost,
            logoServiceName: endpoint.serviceName ?? logoServiceName,
            logoServiceType: endpoint.serviceType ?? logoServiceType ?? ESP32DiscoveryService.logoServiceType,
            logoServiceDomain: endpoint.serviceDomain ?? logoServiceDomain ?? serviceDomain,
            logoHostname: endpoint.hostname ?? logoHostname ?? hostname ?? manualHost,
            logoPort: endpoint.port ?? logoPort ?? LogoFileFormat.logoUploadPort
        )
    }

    func withDefaultLogoFallback() -> LastConnectedDevice {
        LastConnectedDevice(
            boardID: boardID,
            displayName: displayName,
            serviceInstanceName: serviceInstanceName,
            serviceType: serviceType,
            serviceDomain: serviceDomain,
            hostname: hostname,
            controlPort: controlPort,
            source: source,
            manualHost: manualHost,
            logoServiceName: logoServiceName,
            logoServiceType: logoServiceType,
            logoServiceDomain: logoServiceDomain,
            logoHostname: logoHostname ?? hostname ?? manualHost,
            logoPort: logoPort ?? LogoFileFormat.logoUploadPort
        )
    }
}

private enum AutomaticReconnectEndpointSource {
    case discoveredBonjour
    case cachedBonjour
    case cachedHostname
    case cachedManualHost

    var diagnosticsText: String {
        switch self {
        case .discoveredBonjour:
            "Discovered Bonjour"
        case .cachedBonjour:
            "Cached Bonjour"
        case .cachedHostname:
            "Cached Hostname"
        case .cachedManualHost:
            "Cached Manual Host"
        }
    }
}

private struct AutomaticReconnectCandidate {
    let endpoint: NWEndpoint
    let endpointDescription: String
    let source: AutomaticReconnectEndpointSource
    let device: DiscoveredESP32?
}

private enum LogoUploadEndpointSource {
    case discoveredBonjour
    case cachedBonjour
    case cachedHostname
    case cachedManualHost

    var diagnosticsText: String {
        switch self {
        case .discoveredBonjour:
            "Discovered Bonjour"
        case .cachedBonjour:
            "Cached Bonjour"
        case .cachedHostname:
            "Cached hostname"
        case .cachedManualHost:
            "Cached manual host"
        }
    }
}

private struct LogoUploadTarget {
    let endpoint: NWEndpoint
    let source: LogoUploadEndpointSource
    let destinationDescription: String
}

private enum ConnectionTarget: Equatable {
    case manual
    case discovered(String)
    case automaticReconnect(LastConnectedDevice)
}

private enum ConnectionAttempt: Equatable {
    case idle
    case starting(ConnectionTarget)
    case connecting(ConnectionTarget)
    case connected(ConnectionTarget)
    case explicitDisconnect
}

private struct ClockConfiguration: Equatable {
    let is24HourFormat: Bool
    let brightnessLevel: UInt8
}

private enum ClockConfigurationChangeReason {
    case timeFormat
    case brightness
    case currentSettings

    var logLabel: String {
        switch self {
        case .timeFormat:
            "CT Time Format"
        case .brightness:
            "CT Brightness"
        case .currentSettings:
            "CT Send Current Settings"
        }
    }

    var statusMessage: String {
        switch self {
        case .timeFormat:
            "Time format command sent"
        case .brightness:
            "Brightness command sent"
        case .currentSettings:
            "Current settings command sent"
        }
    }
}

private struct ViewModelDispatchWorkItemCancellable: CancellableTask {
    let workItem: DispatchWorkItem

    func cancel() {
        workItem.cancel()
    }
}

enum HexInputError: LocalizedError {
    case empty
    case invalidToken(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter at least one hex byte"
        case let .invalidToken(token):
            "Invalid hex byte: \(token)"
        }
    }
}
