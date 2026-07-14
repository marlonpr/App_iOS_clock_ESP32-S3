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
    @Published private(set) var clockConfigurationReadState: ClockConfigurationReadState = .idle
    @Published var isResetConfirmationPresented = false
    @Published var isRestoreDefaultLogoConfirmationPresented = false
    @Published private(set) var timeSyncState: TimeSyncState = .idle
    @Published private(set) var isTimeSyncSuccessAlertPresented = false
    @Published private(set) var displayModeChangeState: DisplayModeChangeState = .idle
    @Published private(set) var confirmedDisplayMode: UInt8?
    @Published private(set) var lastNormalDisplayMode: PaletteMode = .mode1
    @Published private(set) var isShowingAllDisplayModes = false
    @Published private(set) var isDisplayModeSuccessAlertPresented = false
    @Published private(set) var setDisplayModeState: SetDisplayModeState = .idle
    @Published private(set) var readDisplayModeState: ReadDisplayModeState = .idle
    @Published private(set) var defaultLogoRestoreState: DefaultLogoRestoreState = .idle
    @Published private(set) var isDefaultLogoRestoreSuccessAlertPresented = false
    @Published private(set) var logoUploadState: LogoUploadState = .idle
    @Published private(set) var convertedLogoPayload: Data?
    @Published private(set) var processedLogoPreview: CGImage?
    @Published private(set) var logoSourceDiagnostics: LogoImageSourceDiagnostics?
    @Published private(set) var isLogoUploadSuccessAlertPresented = false
    @Published private(set) var rememberedDeviceConnectionFailureAlert: DeviceConnectionFailureAlert?
    @Published private(set) var alarmRecords: [AlarmRecord] = AlarmRecord.makeDefaultRecords()
    @Published private(set) var selectedAlarmID: Int?
    @Published var alarmEditorDraft: AlarmDraft?
    @Published private(set) var alarmReadOperationState: AlarmReadOperationState = .idle
    @Published private(set) var alarmSendState: AlarmSendState = .idle
    @Published private(set) var alarmDeleteState: AlarmDeleteState = .idle
    @Published private(set) var lastAlarmReadID: Int?
    @Published private(set) var alarmReadFailures = 0
    @Published private(set) var lastCAAlarmID: Int?
    @Published private(set) var lastCAResultText = "None"
    @Published private(set) var lastDAAlarmID: Int?
    @Published private(set) var lastDAResultText = "None"
    @Published private(set) var paletteRecords: [PaletteMode: ModePaletteRecord] = [:]
    @Published private(set) var paletteDrafts: [PaletteMode: ModePaletteDraft] = [:]
    @Published var selectedPaletteMode: PaletteMode = .mode1
    @Published private(set) var paletteReadState: PaletteReadState = .idle
    @Published private(set) var paletteSaveState: PaletteSaveState = .idle
    @Published private(set) var paletteDefaultRestoreState: PaletteDefaultRestoreState = .idle
    @Published private(set) var paletteFeatureAvailability: PaletteFeatureAvailability = .unknown
    @Published private(set) var lastPaletteError: PaletteOperationFailure?
    @Published private(set) var lastConnectedDevice: LastConnectedDevice?
    @Published private(set) var discoveredLogoUploadEndpoints: [DiscoveredLogoUploadEndpoint] = []
    @Published private(set) var appPhaseDiagnosticsText = "Inactive"
    @Published private(set) var resumeActionDiagnosticsText = "Idle"
    @Published private(set) var reconnectAttemptDiagnosticsText = "None"
    @Published private(set) var endpointSourceDiagnosticsText = "None"
    @Published private(set) var foregroundValidationDiagnosticsText = "Idle"
    @Published private(set) var isNetworkingAuthorized = false

    nonisolated static let reservedBoardIDMessage = "Board ID 92 is reserved because it equals the protocol frame delimiter 0x5C."
    nonisolated static let defaultLogoRestoreConfirmationMessage = "This removes the uploaded logo from the SD card and activates the logo built into the CLOCK."
    nonisolated static let defaultLogoRestoreSuccessMessage = "The logo built into the CLOCK is now active."
    nonisolated static let defaultLogoRestoreTimeoutMessage = "Default-logo restore was not confirmed by the CLOCK."
    nonisolated static let deviceDefaultConfigurationConfirmationMessage = "This sends only the device default-configuration command to the connected CLOCK. The CLOCK also restores the compiled default logo built into its firmware."
    nonisolated static let timeSyncCompensation: TimeInterval = 1.0
    nonisolated static let timeSyncConfirmationTimeout: TimeInterval = 4
    nonisolated static let setDisplayModeConfirmationTimeout: TimeInterval = 4
    nonisolated static let readDisplayModeTimeout: TimeInterval = 4
    nonisolated static let defaultLogoRestoreConfirmationTimeout: TimeInterval = 4
    nonisolated static let alarmTransactionTimeout: TimeInterval = 4
    nonisolated static let clockConfigurationReadTimeout: TimeInterval = 4
    nonisolated static let paletteTransactionTimeout: TimeInterval = 4
    nonisolated static let paletteUnsupportedFirmwareMessage = "Color Palette requires newer CLOCK firmware"
    nonisolated static let foregroundHeartbeatValidationTimeout: TimeInterval = 1.75
    nonisolated static let automaticReconnectDelays: [TimeInterval] = [0, 0.5, 1, 2]
    nonisolated static let automaticReconnectDeadline: TimeInterval = 12
    nonisolated static let startupAutomaticReconnectMaxAttempts = 2
    nonisolated static let manualRememberedConnectionDeadline: TimeInterval = 12
    nonisolated static let manualRememberedConnectionMaxAttempts = 2

    private let client: ESP32TCPClient
    private let discoveryService: ESP32DiscoveryService
    private let currentDateProvider: () -> Date
    private let timeSyncScheduler: TimeSyncScheduler
    private let reconnectScheduler: TimeSyncScheduler
    private let manualConnectScheduler: TimeSyncScheduler
    private let logoImageConverter: LogoConversion
    private let logoUploadClient: ESP32LogoUploadClient
    private let userDefaults: UserDefaults
    private let automaticallyReadsPalettesOnConnect: Bool
    private let automaticallyLoadsClockStateOnConnect: Bool
    private let maxLogEntries = 200
    nonisolated static let lastConnectedDeviceDefaultsKey = "ESP32Controller.LastConnectedDevice.v1"
    nonisolated static let lastNormalDisplayModeDefaultsKey = "ESP32Controller.LastNormalDisplayMode.v1"
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
    private var automaticReconnectIntent: AutomaticReconnectIntent?
    private var automaticReconnectTasks: [CancellableTask] = []
    private var automaticReconnectDeadlineTask: CancellableTask?
    private var automaticReconnectLastStartedAttemptIndex: Int?
    private var automaticReconnectLastScheduledAttemptIndex: Int?
    private var automaticReconnectAttemptLimit = 0
    private var didEvaluateStartupReconnectForAuthorization = false
    private var suppressAutomaticReconnectUntilInactive = false
    private var manualRememberedConnectionOperation: ManualRememberedConnectionOperation?
    private var foregroundValidationGeneration: UUID?
    private var foregroundValidationConnectionGeneration: UUID?
    private var didValidateActiveConnectionGeneration: UUID?
    private var brightnessLevelAtEditingStart: UInt8?
    private var lastRequestedClockConfiguration: ClockConfiguration?
    private var timeFormatUserEditRevision = 0
    private var brightnessUserEditRevision = 0
    private var pendingClockConfigurationRead: PendingClockConfigurationRead?
    private var clockConfigurationReadTimeoutTask: CancellableTask?
    private var automaticStartupLoadConnectionGeneration: UUID?
    private var automaticStartupLoadPhase: AutomaticStartupLoadPhase = .idle
    private var pendingTimeSyncOperationID: UUID?
    private var pendingTimeSyncConnectionGeneration: UUID?
    private var timeSyncConfirmationTimeoutTask: CancellableTask?
    private var pendingDisplayModeOperationID: UUID?
    private var pendingDisplayModeConnectionGeneration: UUID?
    private var displayModeConfirmationTimeoutTask: CancellableTask?
    private var pendingSetDisplayModeOperationID: UUID?
    private var pendingSetDisplayModeConnectionGeneration: UUID?
    private var pendingSetDisplayModeBoardID: UInt8?
    private var pendingSetDisplayModeTarget: PaletteMode?
    private var setDisplayModeConfirmationTimeoutTask: CancellableTask?
    private var pendingReadDisplayModeOperation: PendingReadDisplayModeOperation?
    private var deferredReadDisplayModeRefreshConnectionGeneration: UUID?
    private var readDisplayModeTimeoutTask: CancellableTask?
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
    private var pendingAlarmReadOperationID: UUID?
    private var pendingAlarmReadConnectionGeneration: UUID?
    private var pendingAlarmReadBoardID: UInt8?
    private var pendingAlarmReadID: Int?
    private var pendingAlarmReadQueue: [Int] = []
    private var pendingAlarmReadTotal = 0
    private var alarmReadSuccesses = 0
    private var pendingAlarmReadIsFullSnapshot = false
    private var alarmReadTimeoutTask: CancellableTask?
    private var activeAlarmCacheDeviceIdentity: AlarmCacheDeviceIdentity?
    private var loadedAlarmCacheDeviceIdentity: AlarmCacheDeviceIdentity?
    private var alarmRecordsDeviceIdentity: AlarmCacheDeviceIdentity?
    private var pendingAlarmWriteOperationID: UUID?
    private var pendingAlarmWriteConnectionGeneration: UUID?
    private var pendingAlarmWriteBoardID: UInt8?
    private var pendingAlarmWriteDraft: AlarmDraft?
    private var pendingAlarmWriteFrame: AlarmCAFrame?
    private var alarmWriteTimeoutTask: CancellableTask?
    private var pendingAlarmDeleteOperationID: UUID?
    private var pendingAlarmDeleteConnectionGeneration: UUID?
    private var pendingAlarmDeleteBoardID: UInt8?
    private var pendingAlarmDeleteID: Int?
    private var alarmDeleteTimeoutTask: CancellableTask?
    private var pendingPaletteOperation: PendingPaletteOperation?
    private var pendingPaletteReadQueue: [PaletteMode] = []
    private var paletteTransactionTimeoutTask: CancellableTask?
    private var paletteBootstrapConnectionGeneration: UUID?
    private var cancellables: Set<AnyCancellable> = []

    var canConnect: Bool {
        guard isNetworkingAuthorized else {
            return false
        }

        return switch state {
        case .disconnected, .failed:
            true
        case .connecting, .connected:
            false
        }
    }

    var canDisconnect: Bool {
        guard isNetworkingAuthorized else {
            return false
        }

        return switch state {
        case .connecting, .connected, .failed:
            true
        case .disconnected:
            false
        }
    }

    var canSend: Bool {
        isNetworkingAuthorized && state == .connected
    }

    var canUseClockControls: Bool {
        isNetworkingAuthorized && state == .connected && connectedProtocolBoardID != nil
    }

    var hasLoadedAlarmsForCurrentDevice: Bool {
        let currentIdentity = activeAlarmCacheDeviceIdentity ?? lastConnectedDevice.map(Self.alarmCacheIdentity)
        return currentIdentity != nil && currentIdentity == loadedAlarmCacheDeviceIdentity
    }

    var canSyncTime: Bool {
        canUseClockControls && !timeSyncState.isConfirmationPending
    }

    var canSelectDisplayMode: Bool {
        canUseClockControls &&
            !setDisplayModeState.isPending &&
            !displayModeChangeState.isConfirmationPending &&
            !isPaletteOperationPending
    }

    var canToggleShowAllDisplayModes: Bool {
        canUseClockControls &&
            !setDisplayModeState.isPending &&
            !displayModeChangeState.isConfirmationPending &&
            !isPaletteOperationPending
    }

    var normalDisplayModeIndicatorMode: PaletteMode {
        guard
            let confirmedDisplayMode,
            let confirmedMode = PaletteMode(rawValue: confirmedDisplayMode),
            confirmedMode.isEditable
        else {
            return lastNormalDisplayMode
        }

        return confirmedMode
    }

    var highlightedDisplayModes: Set<PaletteMode> {
        if isShowingAllDisplayModes || confirmedDisplayMode == PaletteMode.rotation.rawValue {
            return Set(PaletteMode.editableCases)
        }

        return [normalDisplayModeIndicatorMode]
    }

    var canUploadLogo: Bool {
        guard
            isNetworkingAuthorized,
            state == .connected,
            convertedLogoPayload?.count == LogoFileFormat.payloadLength,
            resolvedLogoUploadTargetForActiveDevice() != nil,
            !logoUploadState.isUploadInProgress
        else {
            return false
        }

        return true
    }

    var canReadAlarms: Bool {
        canUseClockControls &&
            !alarmReadOperationState.isReading &&
            !alarmSendState.isSending &&
            !alarmDeleteState.isDeleting
    }

    var canSendAlarm: Bool {
        canUseClockControls &&
            !alarmSendState.isSending &&
            !alarmDeleteState.isDeleting &&
            !alarmReadOperationState.isReading
    }

    var canDeleteAlarm: Bool {
        canUseClockControls &&
            !alarmSendState.isSending &&
            !alarmDeleteState.isDeleting &&
            !alarmReadOperationState.isReading
    }

    var isPaletteFeatureUnsupported: Bool {
        if case .unsupported = paletteFeatureAvailability {
            return true
        }
        return false
    }

    var canSaveSelectedPalette: Bool {
        canSavePalette(mode: selectedPaletteMode)
    }

    var isPaletteOperationPending: Bool {
        paletteReadState.isReading || paletteSaveState.isSaving || paletteDefaultRestoreState.isRestoring
    }

    var isPaletteEditingLockedByShowAllModes: Bool {
        isShowingAllDisplayModes || confirmedDisplayMode == PaletteMode.rotation.rawValue
    }

    var canSelectPaletteMode: Bool {
        !isPaletteEditingLockedByShowAllModes && !isPaletteOperationPending
    }

    var canEditSelectedPalette: Bool {
        !isPaletteEditingLockedByShowAllModes &&
            canUseClockControls &&
            paletteFeatureAvailability.isAvailable &&
            paletteRecords[selectedPaletteMode] != nil &&
            paletteDrafts[selectedPaletteMode] != nil &&
            !isPaletteOperationPending
    }

    var canRestoreSelectedPaletteDefaults: Bool {
        canEditSelectedPalette
    }

    var alarmReadDiagnosticsText: String {
        alarmReadOperationState.diagnosticsText
    }

    var alarmReadProgressDiagnosticsText: String {
        alarmReadOperationState.progressText
    }

    var lastAlarmReadDiagnosticsText: String {
        lastAlarmReadID.map(String.init) ?? "None"
    }

    var alarmReadFailuresDiagnosticsText: String {
        "\(alarmReadFailures)"
    }

    var lastCAAlarmIDDiagnosticsText: String {
        lastCAAlarmID.map(String.init) ?? "None"
    }

    var lastCAResultDiagnosticsText: String {
        lastCAResultText
    }

    var lastDAAlarmIDDiagnosticsText: String {
        lastDAAlarmID.map(String.init) ?? "None"
    }

    var lastDAResultDiagnosticsText: String {
        lastDAResultText
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
        lastConnectedDevice?.presentedDisplayName ?? "None"
    }

    var connectedDevicePresentedName: String? {
        connectedDiscoveredDevice?.presentedServiceName ?? lastConnectedDevice?.presentedDisplayName
    }

    var clockDevicesSectionPresentation: ClockDevicesSectionPresentation {
        let action: ClockDevicesAction?
        if isRememberedDeviceConnectionPending || automaticReconnectGeneration != nil {
            action = .connecting
        } else if state == .connected, canDisconnect {
            action = .disconnect
        } else if canConnectRememberedDevice {
            action = .connect
        } else {
            action = nil
        }

        return ClockDevicesSectionPresentation(
            deviceName: connectedDevicePresentedName,
            deviceNameStyle: .primary,
            stateText: connectionStatusText,
            stateStyle: ClockDevicesStateStyle(connectionState: state),
            action: action
        )
    }

    var canConnectRememberedDevice: Bool {
        guard
            isNetworkingAuthorized,
            lastConnectedDevice != nil,
            automaticReconnectGeneration == nil,
            !isConnectionAttemptPending
        else {
            return false
        }

        switch state {
        case .disconnected, .failed:
            return true
        case .connecting, .connected:
            return false
        }
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
            return "Connect to a CLOCK before using clock controls."
        }

        guard connectedProtocolBoardID != nil else {
            return "Clock controls require a valid protocol Board ID. Enter a manual decimal Board ID from 0 through 255 except 92, or connect to a discovered device that advertises one."
        }

        return nil
    }

    var connectionStatusText: String {
        if shouldShowAutomaticReconnectStatus, let lastConnectedDevice {
            return "Reconnecting to \(lastConnectedDevice.presentedDisplayName)…"
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
        manualConnectScheduler: @escaping TimeSyncScheduler = { delay, callback in
            let workItem = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return ViewModelDispatchWorkItemCancellable(workItem: workItem)
        },
        logoImageConverter: @escaping LogoConversion = { data, source in
            try LogoImageConverter().convert(data: data, source: source)
        },
        logoUploadClient: ESP32LogoUploadClient? = nil,
        automaticallyReadsPalettesOnConnect: Bool = true,
        automaticallyLoadsClockStateOnConnect: Bool = true,
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client ?? ESP32TCPClient()
        self.discoveryService = discoveryService ?? ESP32DiscoveryService()
        self.currentDateProvider = currentDateProvider
        self.timeSyncScheduler = timeSyncScheduler
        self.reconnectScheduler = reconnectScheduler
        self.manualConnectScheduler = manualConnectScheduler
        self.logoImageConverter = logoImageConverter
        self.logoUploadClient = logoUploadClient ?? ESP32LogoUploadClient()
        self.automaticallyReadsPalettesOnConnect = automaticallyReadsPalettesOnConnect
        self.automaticallyLoadsClockStateOnConnect = automaticallyLoadsClockStateOnConnect
        self.userDefaults = userDefaults
        self.lastConnectedDevice = Self.loadLastConnectedDevice(from: userDefaults)
        self.lastNormalDisplayMode = Self.loadLastNormalDisplayMode(from: userDefaults)

        self.client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                guard self.isNetworkingAuthorized || state == .disconnected else {
                    return
                }

                let presentationState = self.handleConnectionStateChange(state)

                self.state = presentationState
                self.appendEvent(state.title)
                if presentationState == .connected {
                    self.startPaletteBootstrapIfNeeded()
                    self.startAutomaticStartupLoadIfNeeded()
                }
            }
        }

        self.client.onFrameReceived = { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self, self.isNetworkingAuthorized else {
                    return
                }

                self.handleReceivedFrame(bytes)
            }
        }

        self.client.onConnectionHealthChange = { [weak self] health in
            DispatchQueue.main.async {
                guard let self, self.isNetworkingAuthorized || health == .idle else {
                    return
                }

                self.connectionHealth = health
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
        automaticReconnectDeadlineTask?.cancel()
        manualRememberedConnectionOperation?.deadlineTask?.cancel()
        logoConversionTask?.cancel()
        alarmReadTimeoutTask?.cancel()
        alarmWriteTimeoutTask?.cancel()
        alarmDeleteTimeoutTask?.cancel()
        paletteTransactionTimeoutTask?.cancel()
        setDisplayModeConfirmationTimeoutTask?.cancel()
        clockConfigurationReadTimeoutTask?.cancel()
    }

    func authorizeNetworking() {
        guard !isNetworkingAuthorized else {
            return
        }

        isNetworkingAuthorized = true
        automaticReconnectEnabled = true
        userRequestedDisconnect = false
        didEvaluateStartupReconnectForAuthorization = false
        suppressAutomaticReconnectUntilInactive = false
    }

    func revokeNetworkingAuthorization() {
        guard isNetworkingAuthorized else {
            return
        }

        isNetworkingAuthorized = false
        suspendNetworkingForAuthorizationLoss()
    }

    func startDiscovery() {
        guard isNetworkingAuthorized else {
            return
        }

        beginDeviceScan()
    }

    func stopDiscovery() {
        discoveryService.stopDiscovery()
    }

    func handleAppBecameActive() {
        guard isNetworkingAuthorized else {
            return
        }

        let wasActive = isAppActive
        isAppActive = true
        appPhaseDiagnosticsText = "Active"

        if !wasActive {
            discoveryService.resumeDiscoveryPreservingCache(connectedEndpointDescription: connectedEndpointDescription)
        }

        if wasActive, automaticReconnectGeneration != nil || foregroundValidationGeneration != nil {
            return
        }

        let reconnectIntent = nextAutomaticReconnectIntentForActiveScene()

        if state == .connected {
            validateForegroundConnectionIfNeeded()
        } else {
            startAutomaticReconnectIfPossible(intent: reconnectIntent)
        }
    }

    func handleAppBecameInactive() {
        guard isNetworkingAuthorized else {
            return
        }

        appPhaseDiagnosticsText = "Inactive"
    }

    func handleAppEnteredBackground() {
        guard isNetworkingAuthorized else {
            return
        }

        isAppActive = false
        suppressAutomaticReconnectUntilInactive = false
        appPhaseDiagnosticsText = "Background"
        foregroundReconnectRequired = true
        foregroundValidationDiagnosticsText = "Idle"
        cancelForegroundValidation()
        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelManualRememberedConnectionOperation()
        resumeActionDiagnosticsText = "Backgrounded"
        discoveryService.pauseDiscoveryPreservingCache()

        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
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
        guard isNetworkingAuthorized else {
            return
        }

        refreshDevices()
    }

    func refreshDevices() {
        guard isNetworkingAuthorized else {
            return
        }

        beginDeviceScan()
    }

    func presentDeviceScanner() {
        guard isNetworkingAuthorized else {
            return
        }

        isScannerPresented = true
    }

    func beginDeviceScan() {
        guard isNetworkingAuthorized else {
            return
        }

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
        guard isNetworkingAuthorized else {
            return
        }

        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelManualRememberedConnectionOperation()
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
        guard isNetworkingAuthorized else {
            return
        }

        guard canSelectScannedDevice(device) else {
            return
        }

        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelManualRememberedConnectionOperation()
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

    func connectToRememberedDevice() {
        guard
            isNetworkingAuthorized,
            canConnectRememberedDevice,
            let record = lastConnectedDevice
        else {
            return
        }

        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelForegroundValidation()
        userRequestedDisconnect = false
        automaticReconnectEnabled = true
        foregroundReconnectRequired = false
        rememberedDeviceConnectionFailureAlert = nil

        startManualRememberedConnection(to: record)
    }

    func dismissRememberedDeviceConnectionFailureAlert() {
        rememberedDeviceConnectionFailureAlert = nil
    }

    func canSelectScannedDevice(_ device: DiscoveredESP32) -> Bool {
        guard isNetworkingAuthorized else {
            return false
        }

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
        guard isNetworkingAuthorized else {
            return
        }

        userRequestedDisconnect = true
        automaticReconnectEnabled = false
        foregroundReconnectRequired = false
        cancelForegroundValidation()
        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelManualRememberedConnectionOperation()
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
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
        guard isNetworkingAuthorized else {
            return
        }

        guard state == .connected else {
            logoUploadState = .failed("Connect to a CLOCK before uploading a logo.")
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
        guard isNetworkingAuthorized else {
            return
        }

        guard canRestoreDefaultLogo else {
            return
        }

        isRestoreDefaultLogoConfirmationPresented = true
    }

    func restoreDefaultLogo() {
        guard isNetworkingAuthorized else {
            return
        }

        guard !defaultLogoRestoreState.isConfirmationPending else {
            return
        }

        guard state == .connected else {
            failDefaultLogoRestoreBeforeSend("Connect to a CLOCK before sending clock commands.")
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
        guard isNetworkingAuthorized else {
            return
        }

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

        timeFormatUserEditRevision += 1
        is24HourFormat = is24Hour
        sendCurrentClockConfiguration(
            reason: .timeFormat,
            skipIfLastRequestedMatches: true
        )
    }

    func brightnessEditingChanged(_ isEditing: Bool) {
        if isEditing {
            brightnessUserEditRevision += 1
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
        guard isNetworkingAuthorized else {
            return
        }

        guard state == .connected else {
            let message = "Connect to a CLOCK before sending clock commands."
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
        guard isNetworkingAuthorized else {
            return
        }

        beginClockConfigurationRead(isAutomatic: false)
    }

    func requestNextDisplayMode() {
        guard canSelectDisplayMode, !isShowingAllDisplayModes else {
            return
        }

        let currentNormalMode: PaletteMode
        if let confirmedDisplayMode,
           let confirmedMode = PaletteMode(rawValue: confirmedDisplayMode),
           confirmedMode.isEditable {
            currentNormalMode = confirmedMode
        } else {
            currentNormalMode = lastNormalDisplayMode
        }

        let nextMode: PaletteMode = switch currentNormalMode {
        case .mode1:
            .mode2
        case .mode2:
            .mode3
        case .mode3, .rotation:
            .mode1
        }

        requestSetDisplayMode(nextMode)
    }

    func userSelectedDisplayMode(_ mode: PaletteMode) {
        guard mode.isEditable, canSelectDisplayMode else {
            return
        }
        guard isShowingAllDisplayModes || confirmedDisplayMode != mode.rawValue else {
            return
        }

        requestSetDisplayMode(mode)
    }

    func userSetShowAllDisplayModes(_ showAllModes: Bool) {
        guard showAllModes != isShowingAllDisplayModes else {
            return
        }
        guard canToggleShowAllDisplayModes else {
            return
        }

        if showAllModes {
            if let confirmedDisplayMode,
               let confirmedMode = PaletteMode(rawValue: confirmedDisplayMode),
               confirmedMode.isEditable {
                updateLastNormalDisplayMode(confirmedMode)
            }
            isShowingAllDisplayModes = true
            requestSetDisplayMode(.rotation)
        } else {
            isShowingAllDisplayModes = false
            requestSetDisplayMode(lastNormalDisplayMode)
        }
    }

    func requestFirmwareNextDisplayMode() {
        guard isNetworkingAuthorized else {
            return
        }

        guard state == .connected else {
            let message = "Connect to a CLOCK before sending clock commands."
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

    func userSelectedPaletteMode(_ mode: PaletteMode) {
        guard
            !isPaletteEditingLockedByShowAllModes,
            mode.isEditable,
            mode != selectedPaletteMode
        else {
            return
        }

        selectedPaletteMode = mode
        guard canUseClockControls else {
            return
        }

        requestSetDisplayMode(mode)
    }

    func requestSetDisplayMode(_ mode: PaletteMode) {
        guard isNetworkingAuthorized else {
            return
        }
        guard canUseClockControls else {
            setDisplayModeState = .failed(
                mode: mode,
                message: "Connect to a CLOCK before changing display mode."
            )
            return
        }
        guard pendingSetDisplayModeOperationID == nil else {
            return
        }
        guard let boardID = connectedProtocolBoardID else {
            return
        }

        let operationID = UUID()
        let connectionGeneration = activeConnectionGeneration

        do {
            let command = ClockProtocolCommand.setDisplayMode(mode)
            let bytes = try ClockProtocolEncoder.encode(command, boardID: boardID)
            pendingSetDisplayModeOperationID = operationID
            pendingSetDisplayModeConnectionGeneration = connectionGeneration
            pendingSetDisplayModeBoardID = boardID
            pendingSetDisplayModeTarget = mode
            setDisplayModeState = .sending(mode: mode)

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingSetDisplayModeOperationID == operationID,
                        self.pendingSetDisplayModeConnectionGeneration == connectionGeneration,
                        self.activeConnectionGeneration == connectionGeneration,
                        self.pendingSetDisplayModeTarget == mode
                    else {
                        return
                    }

                    if let error {
                        self.cancelSetDisplayModeConfirmationTimeout()
                        self.clearPendingSetDisplayModeOperation()
                        let message = "Unable to send Set Mode command."
                        self.setDisplayModeState = .failed(mode: mode, message: message)
                        self.reconcileShowAllDisplayModesWithConfirmedMode()
                        self.commandStatusMessage = message
                        self.appendEvent("\(message) \(error.localizedDescription)")
                    } else {
                        guard self.setDisplayModeState == .sending(mode: mode) else {
                            return
                        }

                        self.setDisplayModeState = .waitingForConfirmation(mode: mode)
                        self.scheduleSetDisplayModeConfirmationTimeout(
                            operationID: operationID,
                            connectionGeneration: connectionGeneration,
                            mode: mode
                        )
                        self.commandStatusMessage = command.sentStatusMessage
                        self.appendLog(direction: .outgoing, bytes: bytes, message: command.logLabel)
                    }
                }
            }
        } catch {
            clearPendingSetDisplayModeOperation()
            setDisplayModeState = .failed(mode: mode, message: error.localizedDescription)
            reconcileShowAllDisplayModesWithConfirmedMode()
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
        }
    }

    func requestCurrentDisplayMode() {
        beginReadDisplayMode(isAutomatic: false)
    }

    func sendCurrentClockConfiguration() {
        guard isNetworkingAuthorized else {
            return
        }

        sendCurrentClockConfiguration(
            reason: .currentSettings,
            skipIfLastRequestedMatches: false
        )
    }

    func readAllAlarms() {
        beginAlarmRead(ids: Array(AlarmRecord.validIDRange), total: AlarmRecord.maximumAlarmCount)
    }

    func readAlarm(id: Int) {
        beginAlarmRead(ids: [id], total: 1)
    }

    func cancelAlarmRead() {
        guard alarmReadOperationState.isReading else {
            return
        }

        clearPendingAlarmRead(markInterrupted: true)
    }

    func selectAlarm(id: Int) {
        guard AlarmRecord.validIDRange.contains(id) else {
            return
        }

        selectedAlarmID = id
        alarmSendState = .idle
        alarmDeleteState = .idle
        alarmEditorDraft = AlarmDraft(record: alarmRecords[id - 1])
    }

    func cancelAlarmEditing() {
        guard !alarmSendState.isSending, !alarmDeleteState.isDeleting else {
            return
        }

        selectedAlarmID = nil
        alarmEditorDraft = nil
        if case .succeeded = alarmSendState {
            alarmSendState = .idle
        }
        if case .succeeded = alarmDeleteState {
            alarmDeleteState = .idle
        }
    }

    func alarmSendEligibility(for draft: AlarmDraft) -> AlarmEditorSendEligibility {
        AlarmEditorSendEligibility.evaluate(
            draft: draft,
            connectionAvailable: canSendAlarm,
            sendState: alarmSendState,
            deleteState: alarmDeleteState,
            hasPersistedChanges: alarmDraftHasPersistedChanges(draft)
        )
    }

    func alarmDeleteEligibility(for draft: AlarmDraft) -> AlarmEditorDeleteEligibility {
        AlarmEditorDeleteEligibility.evaluate(
            draft: draft,
            connectionAvailable: canDeleteAlarm,
            originalAlarmIsConfigured: alarmDraftHasStoredAlarm(draft),
            sendState: alarmSendState,
            deleteState: alarmDeleteState
        )
    }

    func alarmDraftHasPersistedChanges(_ draft: AlarmDraft) -> Bool {
        guard let currentSignature = draft.currentPersistedSignature else {
            return true
        }

        if let baselineSignature = draft.persistedBaselineSignature {
            return currentSignature != baselineSignature
        }

        guard AlarmRecord.validIDRange.contains(draft.id) else {
            return true
        }

        let record = alarmRecords[draft.id - 1]
        guard
            record.readState == .loaded,
            record.isConfigured,
            let baselineSignature = try? AlarmProtocolCodec.persistedSignature(for: record)
        else {
            return true
        }

        return currentSignature != baselineSignature
    }

    func alarmDraftHasStoredAlarm(_ draft: AlarmDraft) -> Bool {
        if draft.persistedBaselineSignature != nil {
            return true
        }

        guard AlarmRecord.validIDRange.contains(draft.id) else {
            return false
        }

        let record = alarmRecords[draft.id - 1]
        return record.readState == .loaded && record.isConfigured
    }

    func sendAlarm(_ draft: AlarmDraft) {
        guard isNetworkingAuthorized else {
            return
        }

        guard !alarmDeleteState.isDeleting else {
            return
        }

        guard alarmDraftHasPersistedChanges(draft) else {
            return
        }

        guard !alarmSendState.isSending else {
            return
        }

        guard state == .connected else {
            let message = "Connect to a CLOCK before sending alarm commands."
            alarmSendState = .failed(id: draft.id, message: message)
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        cancelAlarmWriteTimeout()

        let operationID = UUID()
        let connectionGeneration = activeConnectionGeneration
        let boardID = connectedProtocolBoardID

        do {
            let frame = try AlarmProtocolCodec.makeCARequest(boardID: boardID, draft: draft)
            pendingAlarmWriteOperationID = operationID
            pendingAlarmWriteConnectionGeneration = connectionGeneration
            pendingAlarmWriteBoardID = boardID
            pendingAlarmWriteDraft = draft
            pendingAlarmWriteFrame = frame
            alarmSendState = .sending(id: draft.id)
            lastCAAlarmID = draft.id
            lastCAResultText = "Pending"

            client.send(Data(frame.bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingAlarmWriteOperationID == operationID,
                        self.pendingAlarmWriteConnectionGeneration == connectionGeneration,
                        self.activeConnectionGeneration == connectionGeneration,
                        self.pendingAlarmWriteDraft?.id == draft.id
                    else {
                        return
                    }

                    if let error {
                        self.cancelAlarmWriteTimeout()
                        self.clearPendingAlarmWrite()
                        let message = "Unable to send Alarm \(draft.id)"
                        self.alarmSendState = .failed(id: draft.id, message: message)
                        self.lastCAResultText = "Error"
                        self.commandStatusMessage = message
                        self.appendEvent("\(message): \(error.localizedDescription)")
                    } else {
                        guard self.alarmSendState == .sending(id: draft.id) else {
                            return
                        }

                        self.appendLog(direction: .outgoing, bytes: frame.bytes, message: "CA Alarm \(draft.id)")
                        self.scheduleAlarmWriteTimeout(
                            operationID: operationID,
                            connectionGeneration: connectionGeneration,
                            alarmID: draft.id
                        )
                    }
                }
            }
        } catch {
            clearPendingAlarmWrite()
            let message = error.localizedDescription
            alarmSendState = .failed(id: draft.id, message: message)
            lastCAAlarmID = draft.id
            lastCAResultText = "Error"
            commandStatusMessage = message
            appendEvent(message)
        }
    }

    func deleteAlarm(_ draft: AlarmDraft) {
        guard isNetworkingAuthorized else {
            return
        }

        guard alarmDeleteEligibility(for: draft).canDelete else {
            return
        }

        guard state == .connected else {
            let message = "Connect to a CLOCK before deleting alarm configurations."
            alarmDeleteState = .failed(id: draft.id, message: message)
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        cancelAlarmDeleteTimeout()

        let operationID = UUID()
        let connectionGeneration = activeConnectionGeneration
        let boardID = connectedProtocolBoardID

        do {
            let bytes = try AlarmProtocolCodec.makeDARequest(boardID: boardID, alarmID: draft.id)
            pendingAlarmDeleteOperationID = operationID
            pendingAlarmDeleteConnectionGeneration = connectionGeneration
            pendingAlarmDeleteBoardID = boardID
            pendingAlarmDeleteID = draft.id
            alarmDeleteState = .deleting(id: draft.id)
            lastDAAlarmID = draft.id
            lastDAResultText = "Pending"

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingAlarmDeleteOperationID == operationID,
                        self.pendingAlarmDeleteConnectionGeneration == connectionGeneration,
                        self.activeConnectionGeneration == connectionGeneration,
                        self.pendingAlarmDeleteID == draft.id
                    else {
                        return
                    }

                    if let error {
                        self.cancelAlarmDeleteTimeout()
                        self.clearPendingAlarmDelete()
                        let message = "Unable to delete Alarm \(draft.id)"
                        self.alarmDeleteState = .failed(id: draft.id, message: message)
                        self.lastDAResultText = "Error"
                        self.commandStatusMessage = message
                        self.appendEvent("\(message): \(error.localizedDescription)")
                    } else {
                        guard self.alarmDeleteState == .deleting(id: draft.id) else {
                            return
                        }

                        self.appendLog(direction: .outgoing, bytes: bytes, message: "DA Alarm \(draft.id)")
                        self.scheduleAlarmDeleteTimeout(
                            operationID: operationID,
                            connectionGeneration: connectionGeneration,
                            alarmID: draft.id
                        )
                    }
                }
            }
        } catch {
            clearPendingAlarmDelete()
            let message = error.localizedDescription
            alarmDeleteState = .failed(id: draft.id, message: message)
            lastDAAlarmID = draft.id
            lastDAResultText = "Error"
            commandStatusMessage = message
            appendEvent(message)
        }
    }

    func updatePaletteDraft(_ draft: ModePaletteDraft) {
        guard !isPaletteEditingLockedByShowAllModes, draft.mode.isEditable else {
            return
        }
        paletteDrafts[draft.mode] = draft
    }

    func paletteDraftIsDirty(mode: PaletteMode) -> Bool {
        guard
            let record = paletteRecords[mode],
            let draft = paletteDrafts[mode],
            let baseline = try? PaletteProtocolCodec.persistedSignature(for: record),
            let candidate = try? PaletteProtocolCodec.persistedSignature(for: draft)
        else {
            return false
        }

        return baseline != candidate
    }

    func canSavePalette(mode: PaletteMode) -> Bool {
        guard
            !isPaletteEditingLockedByShowAllModes,
            canUseClockControls,
            paletteFeatureAvailability.isAvailable,
            pendingPaletteOperation == nil,
            let draft = paletteDrafts[mode],
            paletteDraftIsDirty(mode: mode),
            (try? PaletteProtocolCodec.validateCompleteDraft(draft)) != nil
        else {
            return false
        }

        return true
    }

    func requestPaletteRead(_ mode: PaletteMode) {
        guard isNetworkingAuthorized else {
            return
        }
        guard mode.isEditable else {
            failPaletteRead(mode: mode, error: PaletteProtocolError.unsupportedEditableMode)
            return
        }
        guard canUseClockControls else {
            failPaletteRead(mode: mode, message: "Connect to a CLOCK before reading palettes.")
            return
        }
        guard pendingPaletteOperation == nil else {
            return
        }

        pendingPaletteReadQueue = [mode]
        sendNextPaletteRead()
    }

    func requestPaletteSave(_ mode: PaletteMode, draft: ModePaletteDraft) {
        guard isNetworkingAuthorized else {
            return
        }
        guard !isPaletteEditingLockedByShowAllModes else {
            return
        }

        if draft.mode == mode, mode.isEditable {
            paletteDrafts[mode] = draft
        }

        guard draft.mode == mode else {
            failPaletteSave(mode: mode, message: "Palette draft mode does not match the requested mode.")
            return
        }
        guard mode.isEditable else {
            failPaletteSave(mode: mode, error: PaletteProtocolError.unsupportedEditableMode)
            return
        }
        guard canUseClockControls else {
            failPaletteSave(mode: mode, message: "Connect to a CLOCK before saving palettes.")
            return
        }
        guard paletteFeatureAvailability.isAvailable else {
            failPaletteSave(mode: mode, message: Self.paletteUnsupportedFirmwareMessage)
            return
        }
        guard pendingPaletteOperation == nil else {
            return
        }
        guard paletteDraftIsDirty(mode: mode) else {
            return
        }

        do {
            try PaletteProtocolCodec.validateCompleteDraft(draft)
            try beginPaletteOperation(kind: .save, mode: mode, draft: draft)
        } catch {
            failPaletteSave(mode: mode, error: error)
        }
    }

    func requestPaletteSave(_ draft: ModePaletteDraft) {
        requestPaletteSave(draft.mode, draft: draft)
    }

    func requestPaletteRestoreDefaults(_ mode: PaletteMode) {
        guard isNetworkingAuthorized else {
            return
        }
        guard !isPaletteEditingLockedByShowAllModes else {
            return
        }
        guard mode.isEditable else {
            failPaletteDefaultRestore(mode: mode, error: PaletteProtocolError.unsupportedEditableMode)
            return
        }
        guard canUseClockControls else {
            failPaletteDefaultRestore(mode: mode, message: "Connect to a CLOCK before restoring palette defaults.")
            return
        }
        guard paletteFeatureAvailability.isAvailable else {
            failPaletteDefaultRestore(mode: mode, message: Self.paletteUnsupportedFirmwareMessage)
            return
        }
        guard pendingPaletteOperation == nil else {
            return
        }

        do {
            try beginPaletteOperation(kind: .restoreDefaults, mode: mode, draft: nil)
        } catch {
            failPaletteDefaultRestore(mode: mode, error: error)
        }
    }

    func requestDeviceReset(resetID: UInt8) {
        guard isNetworkingAuthorized else {
            return
        }

        let tracksDeviceDefaultConfiguration = resetID == 0x00
        if tracksDeviceDefaultConfiguration {
            isDeviceDefaultConfigurationSendPending = true
        }

        let command = ClockProtocolCommand.reset(resetID: resetID)
        sendClockCommand(
            command,
            logLabel: command.logLabel,
            statusMessage: command.sentStatusMessage,
            onSendSucceeded: { [weak self] in
                if tracksDeviceDefaultConfiguration {
                    self?.invalidatePaletteStateAfterFactoryReset()
                    self?.invalidateAlarmCacheAfterFactoryReset()
                }
            },
            onSendFinished: { [weak self] in
                if tracksDeviceDefaultConfiguration {
                    self?.isDeviceDefaultConfigurationSendPending = false
                }
            }
        )
    }

    func sendClockCommand(_ command: ClockProtocolCommand) {
        guard isNetworkingAuthorized else {
            return
        }

        sendClockCommand(command, logLabel: command.logLabel, statusMessage: command.sentStatusMessage)
    }

    private func sendClockCommand(
        _ command: ClockProtocolCommand,
        logLabel: String,
        statusMessage: String,
        onSendSucceeded: (() -> Void)? = nil,
        onSendFinished: (() -> Void)? = nil
    ) {
        guard isNetworkingAuthorized else {
            onSendFinished?()
            return
        }

        guard state == .connected else {
            commandStatusMessage = "Connect to a CLOCK before sending clock commands."
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

    private func startPaletteBootstrapIfNeeded() {
        guard
            automaticallyReadsPalettesOnConnect,
            state == .connected,
            let connectionGeneration = activeConnectionGeneration,
            connectedProtocolBoardID != nil,
            paletteBootstrapConnectionGeneration != connectionGeneration
        else {
            return
        }

        clearPendingPaletteTransaction()
        paletteBootstrapConnectionGeneration = connectionGeneration
        paletteRecords.removeAll()
        paletteDrafts.removeAll()
        paletteFeatureAvailability = .unknown
        paletteReadState = .idle
        paletteSaveState = .idle
        paletteDefaultRestoreState = .idle
        lastPaletteError = nil
        pendingPaletteReadQueue = PaletteMode.editableCases
        sendNextPaletteRead()
    }

    private func startAutomaticStartupLoadIfNeeded() {
        guard
            automaticallyLoadsClockStateOnConnect,
            isNetworkingAuthorized,
            state == .connected,
            let connectionGeneration = activeConnectionGeneration,
            connectedProtocolBoardID != nil,
            automaticStartupLoadConnectionGeneration != connectionGeneration
        else {
            return
        }

        automaticStartupLoadConnectionGeneration = connectionGeneration
        automaticStartupLoadPhase = .waitingForPalettes
        continueAutomaticStartupLoadAfterPalettesIfNeeded()
    }

    private func continueAutomaticStartupLoadAfterPalettesIfNeeded() {
        guard
            automaticallyLoadsClockStateOnConnect,
            automaticStartupLoadPhase == .waitingForPalettes,
            let connectionGeneration = automaticStartupLoadConnectionGeneration,
            connectionGeneration == activeConnectionGeneration,
            state == .connected,
            isNetworkingAuthorized
        else {
            return
        }

        if paletteBootstrapConnectionGeneration == connectionGeneration,
           pendingPaletteOperation != nil || !pendingPaletteReadQueue.isEmpty {
            return
        }

        automaticStartupLoadPhase = .readingDisplayMode
        beginReadDisplayMode(isAutomatic: true)
    }

    private func continueAutomaticStartupLoadAfterDisplayModeIfNeeded(
        connectionGeneration: UUID
    ) {
        guard
            automaticallyLoadsClockStateOnConnect,
            automaticStartupLoadPhase == .readingDisplayMode,
            automaticStartupLoadConnectionGeneration == connectionGeneration,
            activeConnectionGeneration == connectionGeneration,
            state == .connected,
            isNetworkingAuthorized
        else {
            return
        }

        automaticStartupLoadPhase = .readingConfiguration
        beginClockConfigurationRead(isAutomatic: true)
    }

    private func continueAutomaticStartupLoadAfterConfigurationIfNeeded(
        connectionGeneration: UUID
    ) {
        guard
            automaticallyLoadsClockStateOnConnect,
            automaticStartupLoadPhase == .readingConfiguration,
            automaticStartupLoadConnectionGeneration == connectionGeneration,
            activeConnectionGeneration == connectionGeneration,
            state == .connected,
            isNetworkingAuthorized
        else {
            return
        }

        guard !alarmCacheIsValidForActiveDevice else {
            automaticStartupLoadPhase = .complete
            return
        }

        automaticStartupLoadPhase = .readingAlarms
        beginAlarmRead(ids: Array(AlarmRecord.validIDRange), total: AlarmRecord.maximumAlarmCount)
    }

    private func sendNextPaletteRead() {
        guard pendingPaletteOperation == nil else {
            return
        }
        guard !pendingPaletteReadQueue.isEmpty else {
            continueAutomaticStartupLoadAfterPalettesIfNeeded()
            return
        }

        let mode = pendingPaletteReadQueue.removeFirst()
        do {
            try beginPaletteOperation(kind: .read, mode: mode, draft: nil)
        } catch {
            pendingPaletteReadQueue.removeAll()
            failPaletteRead(mode: mode, error: error)
            continueAutomaticStartupLoadAfterPalettesIfNeeded()
        }
    }

    private func beginPaletteOperation(
        kind: PaletteOperationKind,
        mode: PaletteMode,
        draft: ModePaletteDraft?
    ) throws {
        guard
            pendingPaletteOperation == nil,
            state == .connected,
            let connectionGeneration = activeConnectionGeneration,
            let boardID = connectedProtocolBoardID
        else {
            throw PaletteViewModelTransactionError.notConnected
        }

        let command: ClockProtocolCommand
        switch kind {
        case .read:
            command = .loadPalette(mode)
        case .save:
            guard let draft else {
                throw PaletteViewModelTransactionError.missingDraft
            }
            command = .savePalette(draft)
        case .restoreDefaults:
            command = .restoreDefaultPalette(mode)
        }

        let bytes = try ClockProtocolEncoder.encode(command, boardID: boardID)
        let operation = PendingPaletteOperation(
            id: UUID(),
            connectionGeneration: connectionGeneration,
            boardID: boardID,
            kind: kind,
            mode: mode,
            draft: draft
        )
        pendingPaletteOperation = operation
        lastPaletteError = nil

        switch kind {
        case .read:
            paletteReadState = .reading(mode: mode)
        case .save:
            paletteSaveState = .saving(mode: mode)
        case .restoreDefaults:
            paletteDefaultRestoreState = .restoring(mode: mode)
        }

        client.send(Data(bytes)) { [weak self] error in
            DispatchQueue.main.async {
                guard
                    let self,
                    self.isCurrentPaletteOperation(operation)
                else {
                    return
                }

                if let error {
                    self.handlePaletteTransportFailure(
                        operation,
                        message: "Unable to send palette \(operation.kind.rawValue) request: \(error.localizedDescription)",
                        markUnsupported: false
                    )
                } else {
                    self.appendLog(direction: .outgoing, bytes: bytes, message: command.logLabel)
                    self.schedulePaletteTimeout(for: operation)
                }
            }
        }
    }

    private func consumePaletteResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            let operation = pendingPaletteOperation,
            isCurrentPaletteOperation(operation),
            isPaletteResponseCandidate(bytes, boardID: operation.boardID, kind: operation.kind)
        else {
            return false
        }

        do {
            switch operation.kind {
            case .read:
                let response = try PaletteProtocolCodec.decodeLPResponse(bytes, expectedBoardID: operation.boardID)
                switch response {
                case let .success(record):
                    guard record.mode == operation.mode else {
                        return false
                    }
                    finishPendingPaletteOperation(operation)
                    paletteRecords[record.mode] = record
                    paletteDrafts[record.mode] = record.draft
                    paletteFeatureAvailability = .available
                    paletteReadState = .succeeded(mode: record.mode)
                    appendLog(
                        direction: .incoming,
                        bytes: bytes,
                        message: "LP Palette Mode \(record.mode.rawValue) Loaded"
                    )
                    sendNextPaletteRead()
                case let .failure(mode, status):
                    guard mode == operation.mode else {
                        return false
                    }
                    finishPendingPaletteOperation(operation)
                    failPaletteRead(mode: mode, status: status)
                    appendLog(
                        direction: .incoming,
                        bytes: bytes,
                        message: "LP Palette Mode \(mode.rawValue) Status \(status.uppercaseHex)"
                    )
                    if status.indicatesUnsupportedFirmware {
                        pendingPaletteReadQueue.removeAll()
                        markPaletteFeatureUnsupported()
                        continueAutomaticStartupLoadAfterPalettesIfNeeded()
                    } else {
                        sendNextPaletteRead()
                    }
                }
            case .save:
                let acknowledgement = try PaletteProtocolCodec.decodeCPACK(bytes, expectedBoardID: operation.boardID)
                guard acknowledgement.mode == operation.mode else {
                    return false
                }
                finishPendingPaletteOperation(operation)
                appendLog(
                    direction: .incoming,
                    bytes: bytes,
                    message: "CP Palette Mode \(operation.mode.rawValue) Status \(acknowledgement.status.uppercaseHex)"
                )
                if acknowledgement.status.isSuccess {
                    paletteSaveState = .succeeded(mode: operation.mode)
                    lastPaletteError = nil
                    requestPaletteRead(operation.mode)
                } else {
                    failPaletteSave(mode: operation.mode, status: acknowledgement.status)
                    if acknowledgement.status.indicatesUnsupportedFirmware {
                        markPaletteFeatureUnsupported()
                    }
                }
            case .restoreDefaults:
                let acknowledgement = try PaletteProtocolCodec.decodeDPACK(bytes, expectedBoardID: operation.boardID)
                guard acknowledgement.mode == operation.mode else {
                    return false
                }
                finishPendingPaletteOperation(operation)
                appendLog(
                    direction: .incoming,
                    bytes: bytes,
                    message: "DP Palette Mode \(operation.mode.rawValue) Status \(acknowledgement.status.uppercaseHex)"
                )
                if acknowledgement.status.isSuccess {
                    paletteDefaultRestoreState = .succeeded(mode: operation.mode)
                    lastPaletteError = nil
                    requestPaletteRead(operation.mode)
                } else {
                    failPaletteDefaultRestore(mode: operation.mode, status: acknowledgement.status)
                    if acknowledgement.status.indicatesUnsupportedFirmware {
                        markPaletteFeatureUnsupported()
                    }
                }
            }
        } catch {
            handlePaletteTransportFailure(
                operation,
                message: error.localizedDescription,
                markUnsupported: true
            )
            appendLog(
                direction: .incoming,
                bytes: bytes,
                message: "Malformed \(operation.kind.rawValue) palette response"
            )
        }

        return true
    }

    private func schedulePaletteTimeout(for operation: PendingPaletteOperation) {
        cancelPaletteTransactionTimeout()
        paletteTransactionTimeoutTask = timeSyncScheduler(Self.paletteTransactionTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.isCurrentPaletteOperation(operation)
                else {
                    return
                }

                self.paletteTransactionTimeoutTask = nil
                self.handlePaletteTransportFailure(
                    operation,
                    message: "Palette \(operation.kind.rawValue) timed out.",
                    markUnsupported: true
                )
            }
        }
    }

    private func handlePaletteTransportFailure(
        _ operation: PendingPaletteOperation,
        message: String,
        markUnsupported: Bool
    ) {
        finishPendingPaletteOperation(operation)
        pendingPaletteReadQueue.removeAll()
        switch operation.kind {
        case .read:
            failPaletteRead(mode: operation.mode, message: message)
        case .save:
            failPaletteSave(mode: operation.mode, message: message)
        case .restoreDefaults:
            failPaletteDefaultRestore(mode: operation.mode, message: message)
        }
        if markUnsupported {
            markPaletteFeatureUnsupported()
        }
        if operation.kind == .read {
            continueAutomaticStartupLoadAfterPalettesIfNeeded()
        }
    }

    private func isCurrentPaletteOperation(_ operation: PendingPaletteOperation) -> Bool {
        pendingPaletteOperation?.id == operation.id &&
            pendingPaletteOperation?.connectionGeneration == operation.connectionGeneration &&
            activeConnectionGeneration == operation.connectionGeneration &&
            connectedProtocolBoardID == operation.boardID &&
            state == .connected
    }

    private func isPaletteResponseCandidate(
        _ bytes: [UInt8],
        boardID: UInt8,
        kind: PaletteOperationKind
    ) -> Bool {
        guard
            bytes.count >= 6,
            bytes[0] == 0x2F,
            bytes[1] == 0x74,
            bytes[2] == 0x61,
            bytes[3] == boardID
        else {
            return false
        }

        let command: [UInt8]
        switch kind {
        case .read:
            command = [0x6C, 0x70]
        case .save:
            command = [0x63, 0x70]
        case .restoreDefaults:
            command = [0x64, 0x70]
        }
        return bytes[4] == command[0] && bytes[5] == command[1]
    }

    private func finishPendingPaletteOperation(_ operation: PendingPaletteOperation) {
        guard pendingPaletteOperation?.id == operation.id else {
            return
        }
        cancelPaletteTransactionTimeout()
        pendingPaletteOperation = nil
    }

    private func clearPendingPaletteTransaction() {
        cancelPaletteTransactionTimeout()
        pendingPaletteOperation = nil
        pendingPaletteReadQueue.removeAll()
    }

    private func cancelPaletteTransactionTimeout() {
        paletteTransactionTimeoutTask?.cancel()
        paletteTransactionTimeoutTask = nil
    }

    private func failPaletteRead(mode: PaletteMode?, status: PaletteStatus? = nil, message: String? = nil) {
        let message = message ?? status?.message ?? "Palette read failed."
        paletteReadState = .failed(mode: mode, message: message)
        lastPaletteError = PaletteOperationFailure(operation: .read, mode: mode, status: status, message: message)
    }

    private func failPaletteRead(mode: PaletteMode?, error: Error) {
        failPaletteRead(mode: mode, message: error.localizedDescription)
    }

    private func failPaletteSave(mode: PaletteMode, status: PaletteStatus? = nil, message: String? = nil) {
        let message = message ?? status?.message ?? "Palette save failed."
        paletteSaveState = .failed(mode: mode, message: message)
        lastPaletteError = PaletteOperationFailure(operation: .save, mode: mode, status: status, message: message)
    }

    private func failPaletteSave(mode: PaletteMode, error: Error) {
        failPaletteSave(mode: mode, message: error.localizedDescription)
    }

    private func failPaletteDefaultRestore(
        mode: PaletteMode,
        status: PaletteStatus? = nil,
        message: String? = nil
    ) {
        let message = message ?? status?.message ?? "Palette default restore failed."
        paletteDefaultRestoreState = .failed(mode: mode, message: message)
        lastPaletteError = PaletteOperationFailure(
            operation: .restoreDefaults,
            mode: mode,
            status: status,
            message: message
        )
    }

    private func failPaletteDefaultRestore(mode: PaletteMode, error: Error) {
        failPaletteDefaultRestore(mode: mode, message: error.localizedDescription)
    }

    private func markPaletteFeatureUnsupported() {
        paletteFeatureAvailability = .unsupported(Self.paletteUnsupportedFirmwareMessage)
    }

    private func invalidatePaletteStateAfterFactoryReset() {
        clearPendingPaletteTransaction()
        paletteRecords.removeAll()
        paletteDrafts.removeAll()
        paletteFeatureAvailability = .unknown
        paletteReadState = .idle
        paletteSaveState = .idle
        paletteDefaultRestoreState = .idle
        lastPaletteError = nil
    }

    private func clearPaletteOperationsForConnectionChange(invalidateRecords: Bool) {
        clearPendingPaletteTransaction()
        paletteBootstrapConnectionGeneration = nil
        paletteReadState = .idle
        paletteSaveState = .idle
        paletteDefaultRestoreState = .idle
        lastPaletteError = nil
        if invalidateRecords {
            paletteRecords.removeAll()
            paletteDrafts.removeAll()
            paletteFeatureAvailability = .unknown
        }
    }

    private func beginReadDisplayMode(isAutomatic: Bool) {
        guard isNetworkingAuthorized else {
            return
        }
        guard pendingReadDisplayModeOperation == nil else {
            return
        }
        guard
            state == .connected,
            let connectionGeneration = activeConnectionGeneration,
            let boardID = connectedProtocolBoardID
        else {
            if !isAutomatic {
                let message = "Connect to a CLOCK before reading display mode."
                readDisplayModeState = .failed(message)
                commandStatusMessage = message
                appendEvent(message)
            }
            return
        }

        let operation = PendingReadDisplayModeOperation(
            id: UUID(),
            connectionGeneration: connectionGeneration,
            boardID: boardID,
            isAutomatic: isAutomatic
        )

        do {
            let command = ClockProtocolCommand.readDisplayMode
            let bytes = try ClockProtocolEncoder.encode(command, boardID: boardID)
            pendingReadDisplayModeOperation = operation
            readDisplayModeState = .loading

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.isCurrentReadDisplayModeOperation(operation) else {
                        return
                    }

                    if let error {
                        self.finishReadDisplayMode(
                            operation,
                            failureMessage: "Could not load display mode. \(error.localizedDescription)"
                        )
                    } else {
                        self.appendLog(direction: .outgoing, bytes: bytes, message: command.logLabel)
                        self.scheduleReadDisplayModeTimeout(for: operation)
                    }
                }
            }
        } catch {
            readDisplayModeState = .failed(error.localizedDescription)
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
            if isAutomatic {
                continueAutomaticStartupLoadAfterDisplayModeIfNeeded(
                    connectionGeneration: connectionGeneration
                )
            }
        }
    }

    private func consumeReadDisplayModeResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            let operation = pendingReadDisplayModeOperation,
            isCurrentReadDisplayModeOperation(operation),
            isReadDisplayModeResponseCandidate(bytes, boardID: operation.boardID)
        else {
            return false
        }

        do {
            let acknowledgement = try ReadModeProtocolCodec.decodeResponse(
                bytes,
                expectedBoardID: operation.boardID
            )
            guard acknowledgement.status == .success, let mode = acknowledgement.mode else {
                finishReadDisplayMode(
                    operation,
                    failureMessage: "Could not load display mode. \(acknowledgement.status.message)"
                )
                appendLog(
                    direction: .incoming,
                    bytes: bytes,
                    message: "RM Read Display Mode Failed \(acknowledgement.status.uppercaseHex)"
                )
                return true
            }

            cancelReadDisplayModeTimeout()
            pendingReadDisplayModeOperation = nil
            applyConfirmedDisplayMode(mode)
            readDisplayModeState = .loaded(mode: mode.rawValue)
            commandStatusMessage = "Display mode loaded."
            appendLog(direction: .incoming, bytes: bytes, message: "RM Display Mode \(mode.rawValue) Loaded")
            if startDeferredReadDisplayModeRefreshIfNeeded(after: operation) {
                return true
            }
            if operation.isAutomatic {
                continueAutomaticStartupLoadAfterDisplayModeIfNeeded(
                    connectionGeneration: operation.connectionGeneration
                )
            }
        } catch {
            finishReadDisplayMode(
                operation,
                failureMessage: "Could not load display mode. \(error.localizedDescription)"
            )
            appendLog(direction: .incoming, bytes: bytes, message: "RM Read Display Mode Invalid Response")
        }

        return true
    }

    private func isReadDisplayModeResponseCandidate(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == 0x2F &&
            bytes[1] == 0x74 &&
            bytes[2] == 0x61 &&
            bytes[3] == boardID &&
            bytes[4] == 0x72 &&
            bytes[5] == 0x6D
    }

    private func isCurrentReadDisplayModeOperation(_ operation: PendingReadDisplayModeOperation) -> Bool {
        pendingReadDisplayModeOperation?.id == operation.id &&
            activeConnectionGeneration == operation.connectionGeneration &&
            connectedProtocolBoardID == operation.boardID &&
            state == .connected &&
            isNetworkingAuthorized
    }

    private func scheduleReadDisplayModeTimeout(for operation: PendingReadDisplayModeOperation) {
        cancelReadDisplayModeTimeout()
        readDisplayModeTimeoutTask = timeSyncScheduler(Self.readDisplayModeTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentReadDisplayModeOperation(operation) else {
                    return
                }

                self.readDisplayModeTimeoutTask = nil
                self.finishReadDisplayMode(
                    operation,
                    failureMessage: "Could not load display mode. Read timed out."
                )
            }
        }
    }

    private func finishReadDisplayMode(
        _ operation: PendingReadDisplayModeOperation,
        failureMessage: String
    ) {
        guard pendingReadDisplayModeOperation?.id == operation.id else {
            return
        }

        cancelReadDisplayModeTimeout()
        pendingReadDisplayModeOperation = nil
        readDisplayModeState = .failed(failureMessage)
        commandStatusMessage = failureMessage
        appendEvent(failureMessage)
        if startDeferredReadDisplayModeRefreshIfNeeded(after: operation) {
            return
        }
        if operation.isAutomatic {
            continueAutomaticStartupLoadAfterDisplayModeIfNeeded(
                connectionGeneration: operation.connectionGeneration
            )
        }
    }

    private func cancelReadDisplayModeTimeout() {
        readDisplayModeTimeoutTask?.cancel()
        readDisplayModeTimeoutTask = nil
    }

    private func refreshDisplayModeAfterNextModeSuccess(connectionGeneration: UUID) {
        guard
            activeConnectionGeneration == connectionGeneration,
            state == .connected,
            isNetworkingAuthorized
        else {
            return
        }

        guard pendingReadDisplayModeOperation == nil else {
            deferredReadDisplayModeRefreshConnectionGeneration = connectionGeneration
            return
        }

        beginReadDisplayMode(isAutomatic: false)
    }

    private func startDeferredReadDisplayModeRefreshIfNeeded(
        after operation: PendingReadDisplayModeOperation
    ) -> Bool {
        guard deferredReadDisplayModeRefreshConnectionGeneration == operation.connectionGeneration else {
            if deferredReadDisplayModeRefreshConnectionGeneration != activeConnectionGeneration {
                deferredReadDisplayModeRefreshConnectionGeneration = nil
            }
            return false
        }

        deferredReadDisplayModeRefreshConnectionGeneration = nil
        beginReadDisplayMode(isAutomatic: operation.isAutomatic)
        return true
    }

    private func beginClockConfigurationRead(isAutomatic: Bool) {
        guard isNetworkingAuthorized else {
            return
        }
        guard pendingClockConfigurationRead == nil else {
            return
        }
        guard
            state == .connected,
            let connectionGeneration = activeConnectionGeneration,
            let boardID = connectedProtocolBoardID
        else {
            if !isAutomatic {
                let message = "Connect to a CLOCK before reading clock settings."
                clockConfigurationReadState = .failed(message)
                commandStatusMessage = message
                appendEvent(message)
            }
            return
        }

        let operation = PendingClockConfigurationRead(
            id: UUID(),
            connectionGeneration: connectionGeneration,
            boardID: boardID,
            isAutomatic: isAutomatic,
            timeFormatUserEditRevision: timeFormatUserEditRevision,
            brightnessUserEditRevision: brightnessUserEditRevision
        )

        do {
            let command = ClockProtocolCommand.readConfiguration
            let bytes = try ClockProtocolEncoder.encode(command, boardID: boardID)
            pendingClockConfigurationRead = operation
            clockConfigurationReadState = .loading

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.isCurrentClockConfigurationRead(operation) else {
                        return
                    }

                    if let error {
                        self.finishClockConfigurationRead(
                            operation,
                            failureMessage: "Could not load clock settings. \(error.localizedDescription)"
                        )
                    } else {
                        self.appendLog(direction: .outgoing, bytes: bytes, message: command.logLabel)
                        self.scheduleClockConfigurationReadTimeout(for: operation)
                    }
                }
            }
        } catch {
            clockConfigurationReadState = .failed(error.localizedDescription)
            commandStatusMessage = error.localizedDescription
            appendEvent(error.localizedDescription)
            if isAutomatic {
                continueAutomaticStartupLoadAfterConfigurationIfNeeded(
                    connectionGeneration: connectionGeneration
                )
            }
        }
    }

    private func consumeClockConfigurationResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            let operation = pendingClockConfigurationRead,
            isCurrentClockConfigurationRead(operation),
            isClockConfigurationResponseCandidate(bytes, boardID: operation.boardID)
        else {
            return false
        }

        do {
            let readback = try ClockConfigurationProtocolCodec.decodeRCResponse(
                bytes,
                expectedBoardID: operation.boardID
            )
            cancelClockConfigurationReadTimeout()
            pendingClockConfigurationRead = nil

            if timeFormatUserEditRevision == operation.timeFormatUserEditRevision {
                is24HourFormat = readback.is24HourFormat
            }
            if brightnessUserEditRevision == operation.brightnessUserEditRevision {
                brightnessLevel = Double(readback.brightnessLevel)
            }

            clockConfigurationReadState = .loaded
            commandStatusMessage = "Clock settings loaded."
            appendLog(direction: .incoming, bytes: bytes, message: "RC Clock Settings Loaded")
            if operation.isAutomatic {
                continueAutomaticStartupLoadAfterConfigurationIfNeeded(
                    connectionGeneration: operation.connectionGeneration
                )
            }
        } catch {
            finishClockConfigurationRead(
                operation,
                failureMessage: "Could not load clock settings. \(error.localizedDescription)"
            )
        }

        return true
    }

    private func isClockConfigurationResponseCandidate(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == 0x2F &&
            bytes[1] == 0x74 &&
            bytes[2] == 0x61 &&
            bytes[3] == boardID &&
            bytes[4] == 0x72 &&
            bytes[5] == 0x63
    }

    private func isCurrentClockConfigurationRead(_ operation: PendingClockConfigurationRead) -> Bool {
        pendingClockConfigurationRead?.id == operation.id &&
            pendingClockConfigurationRead?.connectionGeneration == operation.connectionGeneration &&
            activeConnectionGeneration == operation.connectionGeneration &&
            connectedProtocolBoardID == operation.boardID &&
            state == .connected &&
            isNetworkingAuthorized
    }

    private func scheduleClockConfigurationReadTimeout(for operation: PendingClockConfigurationRead) {
        cancelClockConfigurationReadTimeout()
        clockConfigurationReadTimeoutTask = timeSyncScheduler(Self.clockConfigurationReadTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentClockConfigurationRead(operation) else {
                    return
                }

                self.clockConfigurationReadTimeoutTask = nil
                self.finishClockConfigurationRead(
                    operation,
                    failureMessage: "Could not load clock settings. Read timed out."
                )
            }
        }
    }

    private func finishClockConfigurationRead(
        _ operation: PendingClockConfigurationRead,
        failureMessage: String
    ) {
        guard pendingClockConfigurationRead?.id == operation.id else {
            return
        }

        cancelClockConfigurationReadTimeout()
        pendingClockConfigurationRead = nil
        clockConfigurationReadState = .failed(failureMessage)
        commandStatusMessage = failureMessage
        appendEvent(failureMessage)
        if operation.isAutomatic {
            continueAutomaticStartupLoadAfterConfigurationIfNeeded(
                connectionGeneration: operation.connectionGeneration
            )
        }
    }

    private func cancelClockConfigurationReadTimeout() {
        clockConfigurationReadTimeoutTask?.cancel()
        clockConfigurationReadTimeoutTask = nil
    }

    private func handleReceivedFrame(_ bytes: [UInt8]) {
        if consumePaletteResponseIfExpected(bytes) {
            return
        }

        if consumeReadDisplayModeResponseIfExpected(bytes) {
            return
        }

        if consumeClockConfigurationResponseIfExpected(bytes) {
            return
        }

        if consumeSetDisplayModeResponseIfExpected(bytes) {
            return
        }

        if consumeTimeSyncACKIfExpected(bytes) {
            return
        }

        if consumeDisplayModeResponseIfExpected(bytes) {
            return
        }

        if consumeDefaultLogoRestoreResponseIfExpected(bytes) {
            return
        }

        if consumeAlarmReadResponseIfExpected(bytes) {
            return
        }

        if consumeAlarmWriteACKIfExpected(bytes) {
            return
        }

        if consumeAlarmDeleteACKIfExpected(bytes) {
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
            let connectionGeneration = pendingDisplayModeConnectionGeneration,
            connectionGeneration == activeConnectionGeneration,
            let boardID = connectedProtocolBoardID,
            let mode = Self.displayModeResponseMode(bytes, boardID: boardID)
        else {
            return false
        }

        cancelDisplayModeConfirmationTimeout()
        pendingDisplayModeOperationID = nil
        pendingDisplayModeConnectionGeneration = nil
        if let confirmedMode = PaletteMode(rawValue: mode) {
            applyConfirmedDisplayMode(confirmedMode)
        }
        displayModeChangeState = .succeeded(mode: mode)
        isDisplayModeSuccessAlertPresented = true
        commandStatusMessage = "Display mode changed to Mode \(mode)"
        appendLog(direction: .incoming, bytes: bytes, message: "NM Display Mode Confirmed")
        refreshDisplayModeAfterNextModeSuccess(connectionGeneration: connectionGeneration)
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

    private func consumeSetDisplayModeResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            let operationID = pendingSetDisplayModeOperationID,
            pendingSetDisplayModeConnectionGeneration == activeConnectionGeneration,
            let boardID = pendingSetDisplayModeBoardID,
            let target = pendingSetDisplayModeTarget,
            isSetDisplayModeResponseCandidate(bytes, boardID: boardID)
        else {
            return false
        }

        let acknowledgement: SetModeAcknowledgement
        do {
            acknowledgement = try SetModeProtocolCodec.decodeResponse(bytes, expectedBoardID: boardID)
        } catch {
            cancelSetDisplayModeConfirmationTimeout()
            clearPendingSetDisplayModeOperation()
            let message = "Could not change display mode. \(error.localizedDescription)"
            setDisplayModeState = .failed(mode: target, message: message)
            reconcileShowAllDisplayModesWithConfirmedMode()
            commandStatusMessage = message
            appendLog(direction: .incoming, bytes: bytes, message: "SM Set Display Mode Invalid Response")
            return true
        }

        guard pendingSetDisplayModeOperationID == operationID else {
            return true
        }

        cancelSetDisplayModeConfirmationTimeout()
        clearPendingSetDisplayModeOperation()

        guard acknowledgement.modeValue == target.rawValue else {
            let message = "Could not change display mode. The CLOCK confirmed a different mode."
            setDisplayModeState = .failed(mode: target, message: message)
            reconcileShowAllDisplayModesWithConfirmedMode()
            commandStatusMessage = message
            appendLog(direction: .incoming, bytes: bytes, message: "SM Set Display Mode Mismatched Response")
            return true
        }

        guard acknowledgement.status == .success else {
            let message = "Could not change display mode. \(acknowledgement.status.message)"
            setDisplayModeState = .failed(mode: target, message: message)
            reconcileShowAllDisplayModesWithConfirmedMode()
            commandStatusMessage = message
            appendLog(
                direction: .incoming,
                bytes: bytes,
                message: "SM Set Display Mode Failed \(acknowledgement.status.uppercaseHex)"
            )
            return true
        }

        applyConfirmedDisplayMode(target)
        setDisplayModeState = .succeeded(mode: target)
        commandStatusMessage = "Display mode changed to Mode \(target.rawValue)"
        appendLog(direction: .incoming, bytes: bytes, message: "SM Set Display Mode Confirmed")
        return true
    }

    private func isSetDisplayModeResponseCandidate(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == 0x2F &&
            bytes[1] == 0x74 &&
            bytes[2] == 0x61 &&
            bytes[3] == boardID &&
            bytes[4] == 0x73 &&
            bytes[5] == 0x6D
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
            let message = "The CLOCK could not remove the SD-card logo."
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

    private func scheduleSetDisplayModeConfirmationTimeout(
        operationID: UUID,
        connectionGeneration: UUID?,
        mode: PaletteMode
    ) {
        cancelSetDisplayModeConfirmationTimeout()
        setDisplayModeConfirmationTimeoutTask = timeSyncScheduler(Self.setDisplayModeConfirmationTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingSetDisplayModeOperationID == operationID,
                    self.pendingSetDisplayModeConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.pendingSetDisplayModeTarget == mode,
                    self.setDisplayModeState == .waitingForConfirmation(mode: mode)
                else {
                    return
                }

                self.setDisplayModeConfirmationTimeoutTask = nil
                self.clearPendingSetDisplayModeOperation()
                let message = "Display mode change not confirmed."
                self.setDisplayModeState = .failed(mode: mode, message: message)
                self.reconcileShowAllDisplayModesWithConfirmedMode()
                self.commandStatusMessage = message
                self.appendEvent(message)
            }
        }
    }

    private func cancelSetDisplayModeConfirmationTimeout() {
        setDisplayModeConfirmationTimeoutTask?.cancel()
        setDisplayModeConfirmationTimeoutTask = nil
    }

    private func clearPendingSetDisplayModeOperation() {
        pendingSetDisplayModeOperationID = nil
        pendingSetDisplayModeConnectionGeneration = nil
        pendingSetDisplayModeBoardID = nil
        pendingSetDisplayModeTarget = nil
    }

    private func clearSetDisplayModeStateForConnectionChange() {
        cancelSetDisplayModeConfirmationTimeout()
        clearPendingSetDisplayModeOperation()
        setDisplayModeState = .idle
    }

    private func applyConfirmedDisplayMode(_ mode: PaletteMode) {
        confirmedDisplayMode = mode.rawValue

        if mode.isEditable {
            updateLastNormalDisplayMode(mode)
            isShowingAllDisplayModes = false
            selectedPaletteMode = mode
        } else {
            isShowingAllDisplayModes = true
        }
    }

    private func updateLastNormalDisplayMode(_ mode: PaletteMode) {
        guard mode.isEditable else {
            return
        }

        lastNormalDisplayMode = mode
        userDefaults.set(Int(mode.rawValue), forKey: Self.lastNormalDisplayModeDefaultsKey)
    }

    private func reconcileShowAllDisplayModesWithConfirmedMode() {
        isShowingAllDisplayModes = confirmedDisplayMode == PaletteMode.rotation.rawValue
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

    private func beginAlarmRead(ids: [Int], total: Int) {
        guard isNetworkingAuthorized else {
            return
        }

        guard !alarmReadOperationState.isReading else {
            return
        }

        guard !alarmSendState.isSending, !alarmDeleteState.isDeleting else {
            return
        }

        guard canUseClockControls else {
            let message = "Connect to a CLOCK with a valid Board ID before reading alarms."
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        guard !ids.isEmpty, ids.allSatisfy({ AlarmRecord.validIDRange.contains($0) }) else {
            let message = AlarmProtocolError.invalidAlarmID.localizedDescription
            commandStatusMessage = message
            appendEvent(message)
            return
        }

        cancelAlarmReadTimeout()
        let operationID = UUID()
        pendingAlarmReadOperationID = operationID
        pendingAlarmReadConnectionGeneration = activeConnectionGeneration
        pendingAlarmReadBoardID = connectedProtocolBoardID
        pendingAlarmReadID = nil
        pendingAlarmReadQueue = ids
        pendingAlarmReadTotal = total
        pendingAlarmReadIsFullSnapshot = ids == Array(AlarmRecord.validIDRange) &&
            total == AlarmRecord.maximumAlarmCount
        alarmReadSuccesses = 0
        alarmReadFailures = 0
        lastAlarmReadID = nil
        alarmReadOperationState = .reading(currentID: nil, completed: 0, total: total)
        sendNextAlarmRead()
    }

    private func sendNextAlarmRead() {
        guard
            let operationID = pendingAlarmReadOperationID,
            let connectionGeneration = pendingAlarmReadConnectionGeneration,
            activeConnectionGeneration == connectionGeneration,
            state == .connected,
            pendingAlarmReadBoardID == connectedProtocolBoardID
        else {
            clearPendingAlarmRead(markInterrupted: true)
            return
        }

        guard !pendingAlarmReadQueue.isEmpty else {
            completeAlarmRead()
            return
        }

        let alarmID = pendingAlarmReadQueue.removeFirst()
        pendingAlarmReadID = alarmID
        updateAlarmRecord(id: alarmID) { record in
            record.readState = .loading
        }

        alarmReadOperationState = .reading(
            currentID: alarmID,
            completed: alarmReadSuccesses + alarmReadFailures,
            total: pendingAlarmReadTotal
        )

        do {
            let bytes = try AlarmProtocolCodec.makeLARequest(
                boardID: pendingAlarmReadBoardID,
                alarmID: alarmID
            )

            client.send(Data(bytes)) { [weak self] error in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.pendingAlarmReadOperationID == operationID,
                        self.pendingAlarmReadConnectionGeneration == connectionGeneration,
                        self.activeConnectionGeneration == connectionGeneration,
                        self.pendingAlarmReadID == alarmID
                    else {
                        return
                    }

                    if let error {
                        self.markPendingAlarmReadFailed(
                            alarmID: alarmID,
                            message: "Send failed: \(error.localizedDescription)"
                        )
                        self.sendNextAlarmRead()
                    } else {
                        self.appendLog(direction: .outgoing, bytes: bytes, message: "LA Alarm \(alarmID)")
                        self.scheduleAlarmReadTimeout(
                            operationID: operationID,
                            connectionGeneration: connectionGeneration,
                            alarmID: alarmID
                        )
                    }
                }
            }
        } catch {
            markPendingAlarmReadFailed(alarmID: alarmID, message: error.localizedDescription)
            sendNextAlarmRead()
        }
    }

    private func consumeAlarmReadResponseIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            alarmReadOperationState.isReading,
            pendingAlarmReadOperationID != nil,
            pendingAlarmReadConnectionGeneration == activeConnectionGeneration,
            let boardID = pendingAlarmReadBoardID,
            let expectedAlarmID = pendingAlarmReadID,
            let record = try? AlarmProtocolCodec.decodeLAResponse(bytes, expectedBoardID: boardID),
            record.id == expectedAlarmID
        else {
            return false
        }

        cancelAlarmReadTimeout()
        alarmReadSuccesses += 1
        lastAlarmReadID = record.id
        alarmRecords[record.id - 1] = record
        pendingAlarmReadID = nil
        alarmReadOperationState = .reading(
            currentID: nil,
            completed: alarmReadSuccesses + alarmReadFailures,
            total: pendingAlarmReadTotal
        )
        appendLog(direction: .incoming, bytes: bytes, message: "LA Alarm \(record.id)")
        sendNextAlarmRead()
        return true
    }

    private func scheduleAlarmReadTimeout(
        operationID: UUID,
        connectionGeneration: UUID?,
        alarmID: Int
    ) {
        cancelAlarmReadTimeout()
        alarmReadTimeoutTask = timeSyncScheduler(Self.alarmTransactionTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingAlarmReadOperationID == operationID,
                    self.pendingAlarmReadConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.pendingAlarmReadID == alarmID,
                    self.alarmReadOperationState.isReading
                else {
                    return
                }

                self.alarmReadTimeoutTask = nil
                self.markPendingAlarmReadFailed(alarmID: alarmID, message: "Read timed out")
                self.sendNextAlarmRead()
            }
        }
    }

    private func markPendingAlarmReadFailed(alarmID: Int, message: String) {
        cancelAlarmReadTimeout()
        pendingAlarmReadID = nil
        alarmReadFailures += 1
        lastAlarmReadID = alarmID
        updateAlarmRecord(id: alarmID) { record in
            record.readState = .failed(message)
        }
        alarmReadOperationState = .reading(
            currentID: nil,
            completed: alarmReadSuccesses + alarmReadFailures,
            total: pendingAlarmReadTotal
        )
    }

    private func completeAlarmRead() {
        let successful = alarmReadSuccesses
        let failed = alarmReadFailures
        let total = pendingAlarmReadTotal
        let completedFullSnapshot = pendingAlarmReadIsFullSnapshot
        let completedDeviceIdentity = activeAlarmCacheDeviceIdentity
        alarmReadOperationState = .completed(successful: successful, failed: failed)
        pendingAlarmReadOperationID = nil
        pendingAlarmReadConnectionGeneration = nil
        pendingAlarmReadBoardID = nil
        pendingAlarmReadID = nil
        pendingAlarmReadQueue.removeAll()
        pendingAlarmReadTotal = 0
        pendingAlarmReadIsFullSnapshot = false
        cancelAlarmReadTimeout()

        if completedFullSnapshot,
           successful == AlarmRecord.maximumAlarmCount,
           failed == 0,
           total == AlarmRecord.maximumAlarmCount,
           let completedDeviceIdentity {
            loadedAlarmCacheDeviceIdentity = completedDeviceIdentity
            alarmRecordsDeviceIdentity = completedDeviceIdentity
        }

        let summary: String
        if failed == 0 {
            summary = "Read \(successful) of \(total) alarms."
        } else {
            summary = "Read \(successful) of \(total) alarms. \(failed) alarms could not be read."
        }
        commandStatusMessage = summary
        appendEvent(summary)
        if automaticStartupLoadPhase == .readingAlarms,
           automaticStartupLoadConnectionGeneration == activeConnectionGeneration {
            automaticStartupLoadPhase = .complete
        }
    }

    private func cancelAlarmReadTimeout() {
        alarmReadTimeoutTask?.cancel()
        alarmReadTimeoutTask = nil
    }

    private func clearPendingAlarmRead(markInterrupted: Bool) {
        let wasReading = alarmReadOperationState.isReading
        let interruptedAlarmID = pendingAlarmReadID
        cancelAlarmReadTimeout()
        pendingAlarmReadOperationID = nil
        pendingAlarmReadConnectionGeneration = nil
        pendingAlarmReadBoardID = nil
        pendingAlarmReadID = nil
        pendingAlarmReadQueue.removeAll()
        pendingAlarmReadTotal = 0
        pendingAlarmReadIsFullSnapshot = false

        guard markInterrupted, wasReading else {
            if !markInterrupted {
                alarmReadOperationState = .idle
            }
            return
        }

        if let interruptedAlarmID {
            updateAlarmRecord(id: interruptedAlarmID) { record in
                record.readState = .failed("Read interrupted")
            }
        }

        alarmReadOperationState = .interrupted(
            successful: alarmReadSuccesses,
            failed: alarmReadFailures
        )
        commandStatusMessage = "Alarm read interrupted."
        appendEvent("Alarm read interrupted.")
    }

    private func consumeAlarmWriteACKIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            pendingAlarmWriteOperationID != nil,
            pendingAlarmWriteConnectionGeneration == activeConnectionGeneration,
            let boardID = pendingAlarmWriteBoardID,
            let draft = pendingAlarmWriteDraft
        else {
            return false
        }

        do {
            let alarmID = try AlarmProtocolCodec.decodeCAACK(bytes, expectedBoardID: boardID)
            guard alarmID == draft.id else {
                return false
            }

            guard let frame = pendingAlarmWriteFrame else {
                return false
            }

            cancelAlarmWriteTimeout()
            alarmRecords[alarmID - 1] = draft.acknowledgedRecord(
                rawFrequency: frame.frequency,
                rawDurationEffect: frame.durationEffect
            )
            clearPendingAlarmWrite()
            alarmSendState = .succeeded(id: alarmID)
            lastCAAlarmID = alarmID
            lastCAResultText = "ACK"
            commandStatusMessage = "Alarm \(alarmID) saved."
            selectedAlarmID = nil
            alarmEditorDraft = nil
            appendLog(direction: .incoming, bytes: bytes, message: "CA Alarm \(alarmID) ACK")
            return true
        } catch {
            guard isMalformedAlarmWriteACKCandidate(bytes, boardID: boardID) else {
                return false
            }

            failPendingAlarmWrite(id: draft.id, message: AlarmProtocolError.malformedCAACK.localizedDescription, resultText: "Error")
            appendLog(direction: .incoming, bytes: bytes, message: "Malformed CA Alarm \(draft.id) ACK")
            return true
        }
    }

    private func scheduleAlarmWriteTimeout(
        operationID: UUID,
        connectionGeneration: UUID?,
        alarmID: Int
    ) {
        cancelAlarmWriteTimeout()
        alarmWriteTimeoutTask = timeSyncScheduler(Self.alarmTransactionTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingAlarmWriteOperationID == operationID,
                    self.pendingAlarmWriteConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.pendingAlarmWriteDraft?.id == alarmID,
                    self.alarmSendState == .sending(id: alarmID)
                else {
                    return
                }

                self.alarmWriteTimeoutTask = nil
                self.failPendingAlarmWrite(
                    id: alarmID,
                    message: "Alarm \(alarmID) save not confirmed.",
                    resultText: "Timeout"
                )
            }
        }
    }

    private func failPendingAlarmWrite(id: Int, message: String, resultText: String) {
        cancelAlarmWriteTimeout()
        clearPendingAlarmWrite()
        alarmSendState = .failed(id: id, message: message)
        lastCAAlarmID = id
        lastCAResultText = resultText
        commandStatusMessage = message
        appendEvent(message)
    }

    private func cancelAlarmWriteTimeout() {
        alarmWriteTimeoutTask?.cancel()
        alarmWriteTimeoutTask = nil
    }

    private func clearPendingAlarmWrite() {
        pendingAlarmWriteOperationID = nil
        pendingAlarmWriteConnectionGeneration = nil
        pendingAlarmWriteBoardID = nil
        pendingAlarmWriteDraft = nil
        pendingAlarmWriteFrame = nil
    }

    private func consumeAlarmDeleteACKIfExpected(_ bytes: [UInt8]) -> Bool {
        guard
            pendingAlarmDeleteOperationID != nil,
            pendingAlarmDeleteConnectionGeneration == activeConnectionGeneration,
            let boardID = pendingAlarmDeleteBoardID,
            let pendingAlarmDeleteID
        else {
            return false
        }

        do {
            let alarmID = try AlarmProtocolCodec.decodeDAACK(bytes, expectedBoardID: boardID)
            guard alarmID == pendingAlarmDeleteID else {
                return false
            }

            cancelAlarmDeleteTimeout()
            alarmRecords[alarmID - 1] = AlarmRecord.emptyLoadedRecord(id: alarmID)
            clearPendingAlarmDelete()
            alarmDeleteState = .succeeded(id: alarmID)
            lastDAAlarmID = alarmID
            lastDAResultText = "ACK"
            commandStatusMessage = "Alarm \(alarmID) deleted."
            selectedAlarmID = nil
            alarmEditorDraft = nil
            appendLog(direction: .incoming, bytes: bytes, message: "DA Alarm \(alarmID) ACK")
            return true
        } catch {
            guard isMalformedAlarmDeleteACKCandidate(bytes, boardID: boardID) else {
                return false
            }

            failPendingAlarmDelete(
                id: pendingAlarmDeleteID,
                message: AlarmProtocolError.malformedDAACK.localizedDescription,
                resultText: "Error"
            )
            appendLog(direction: .incoming, bytes: bytes, message: "Malformed DA Alarm \(pendingAlarmDeleteID) ACK")
            return true
        }
    }

    private func scheduleAlarmDeleteTimeout(
        operationID: UUID,
        connectionGeneration: UUID?,
        alarmID: Int
    ) {
        cancelAlarmDeleteTimeout()
        alarmDeleteTimeoutTask = timeSyncScheduler(Self.alarmTransactionTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.pendingAlarmDeleteOperationID == operationID,
                    self.pendingAlarmDeleteConnectionGeneration == connectionGeneration,
                    self.activeConnectionGeneration == connectionGeneration,
                    self.pendingAlarmDeleteID == alarmID,
                    self.alarmDeleteState == .deleting(id: alarmID)
                else {
                    return
                }

                self.alarmDeleteTimeoutTask = nil
                self.failPendingAlarmDelete(
                    id: alarmID,
                    message: "Alarm \(alarmID) delete not confirmed.",
                    resultText: "Timeout"
                )
            }
        }
    }

    private func failPendingAlarmDelete(id: Int, message: String, resultText: String) {
        cancelAlarmDeleteTimeout()
        clearPendingAlarmDelete()
        alarmDeleteState = .failed(id: id, message: message)
        lastDAAlarmID = id
        lastDAResultText = resultText
        commandStatusMessage = message
        appendEvent(message)
    }

    private func cancelAlarmDeleteTimeout() {
        alarmDeleteTimeoutTask?.cancel()
        alarmDeleteTimeoutTask = nil
    }

    private func clearPendingAlarmDelete() {
        pendingAlarmDeleteOperationID = nil
        pendingAlarmDeleteConnectionGeneration = nil
        pendingAlarmDeleteBoardID = nil
        pendingAlarmDeleteID = nil
    }

    private func clearAlarmOperationsForConnectionChange(markInterrupted: Bool) {
        clearPendingAlarmRead(markInterrupted: markInterrupted)
        activeAlarmCacheDeviceIdentity = nil

        if case let .sending(id) = alarmSendState {
            cancelAlarmWriteTimeout()
            clearPendingAlarmWrite()
            let message = "Alarm \(id) save interrupted."
            alarmSendState = .failed(id: id, message: message)
            lastCAAlarmID = id
            lastCAResultText = "Error"
            commandStatusMessage = message
        } else {
            cancelAlarmWriteTimeout()
            clearPendingAlarmWrite()
        }

        if case let .deleting(id) = alarmDeleteState {
            cancelAlarmDeleteTimeout()
            clearPendingAlarmDelete()
            let message = "Alarm \(id) delete interrupted."
            alarmDeleteState = .failed(id: id, message: message)
            lastDAAlarmID = id
            lastDAResultText = "Error"
            commandStatusMessage = message
        } else {
            cancelAlarmDeleteTimeout()
            clearPendingAlarmDelete()
        }
    }

    private func updateAlarmRecord(id: Int, update: (inout AlarmRecord) -> Void) {
        guard AlarmRecord.validIDRange.contains(id) else {
            return
        }

        update(&alarmRecords[id - 1])
    }

    private func isMalformedAlarmWriteACKCandidate(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == 0x2F &&
            bytes[1] == 0x74 &&
            bytes[2] == 0x61 &&
            bytes[3] == boardID &&
            bytes[4] == 0x63 &&
            bytes[5] == 0x61
    }

    private func isMalformedAlarmDeleteACKCandidate(_ bytes: [UInt8], boardID: UInt8) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == 0x2F &&
            bytes[1] == 0x74 &&
            bytes[2] == 0x61 &&
            bytes[3] == boardID &&
            bytes[4] == 0x64 &&
            bytes[5] == 0x61
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
        cancelReadDisplayModeTimeout()
        pendingReadDisplayModeOperation = nil
        deferredReadDisplayModeRefreshConnectionGeneration = nil
        pendingDisplayModeOperationID = nil
        pendingDisplayModeConnectionGeneration = nil
        isDisplayModeSuccessAlertPresented = false
        confirmedDisplayMode = nil
        isShowingAllDisplayModes = false
        displayModeChangeState = .idle
        readDisplayModeState = .idle
        clearSetDisplayModeStateForConnectionChange()
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
        cancelClockConfigurationReadTimeout()
        pendingClockConfigurationRead = nil
        clockConfigurationReadState = .idle
        automaticStartupLoadConnectionGeneration = nil
        automaticStartupLoadPhase = .idle
        lastRequestedClockConfiguration = nil
    }

    private func appendEvent(_ message: String) {
        appendLog(direction: .event, bytes: [], message: message)
    }

    private func suspendNetworkingForAuthorizationLoss() {
        isAppActive = false
        appPhaseDiagnosticsText = "Inactive"
        foregroundReconnectRequired = false
        automaticReconnectEnabled = false
        userRequestedDisconnect = true
        didEvaluateStartupReconnectForAuthorization = false
        suppressAutomaticReconnectUntilInactive = false
        isScannerPresented = false
        scannerConnectionErrorText = nil
        rememberedDeviceConnectionFailureAlert = nil
        pendingSelectedEndpointDescription = nil
        cancelForegroundValidation()
        cancelAutomaticReconnect(resetDiagnostics: true)
        cancelManualRememberedConnectionOperation()
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
        activeConnectionGeneration = nil
        connectionAttempt = .explicitDisconnect
        isExpectingInitialDisconnect = false
        isBackgroundDisconnectInProgress = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingManualHost = nil
        pendingManualPort = nil
        pendingProtocolBoardID = nil
        connectedProtocolBoardID = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        connectionHealth = .idle
        discoveryService.updateConnectedEndpointDescription(nil)
        discoveryService.stopDiscovery()
        client.disconnect()
    }

    private func beginConnectionAttempt(_ target: ConnectionTarget) {
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
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
        case let .rememberedDevice(record):
            pendingConnectionEndpointDescription = record.endpointDescription
        }
    }

    private func handleConnectionStateChange(_ newState: TCPConnectionState) -> TCPConnectionState {
        var presentationState = newState

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
            let failedTarget = connectionAttempt.pendingTarget
            let automaticReconnectRecord = failedTarget?.automaticReconnectRecord ?? activeAutomaticReconnectRecord
            cancelForegroundValidation()
            clearTimeSyncStateForConnectionChange()
            clearDisplayModeStateForConnectionChange()
            clearDefaultLogoRestoreStateForConnectionChange()
            clearLogoUploadStateForConnectionChange()
            clearClockConfigurationCacheForConnectionChange()
            clearAlarmOperationsForConnectionChange(markInterrupted: true)
            clearPaletteOperationsForConnectionChange(invalidateRecords: true)
            activeConnectionGeneration = nil
            isExpectingInitialDisconnect = false
            connectionAttempt = .idle
            pendingConnectionEndpointDescription = nil
            pendingConnectionDevice = nil
            pendingAutomaticReconnectRecord = nil
            pendingSelectedEndpointDescription = nil
            scannerConnectionErrorText = failedTarget?.rememberedDeviceRecord == nil ? newState.detail ?? newState.title : nil
            connectedEndpointDescription = nil
            connectedDiscoveredDevice = nil
            connectedProtocolBoardID = nil
            pendingProtocolBoardID = nil
            discoveryService.updateConnectedEndpointDescription(nil)
            if let record = failedTarget?.rememberedDeviceRecord {
                if retryManualRememberedConnectionAfterFailure(for: record) {
                    presentationState = .connecting
                } else {
                    finishManualRememberedConnectionWithFailure(for: record, cancelActiveConnection: false)
                    presentationState = .disconnected
                }
            }
            if let automaticReconnectRecord {
                if finishAutomaticReconnectIfLastAttemptFailed(record: automaticReconnectRecord) {
                    presentationState = .disconnected
                } else {
                    presentationState = .connecting
                }
            }
        case .disconnected:
            if isBackgroundDisconnectInProgress {
                isBackgroundDisconnectInProgress = false
            }

            if isExpectingInitialDisconnect {
                isExpectingInitialDisconnect = false
                return presentationState
            }

            let disconnectedTarget = connectionAttempt.pendingTarget
            let automaticReconnectRecord = disconnectedTarget?.automaticReconnectRecord ?? activeAutomaticReconnectRecord
            cancelForegroundValidation()
            clearTimeSyncStateForConnectionChange()
            clearDisplayModeStateForConnectionChange()
            clearDefaultLogoRestoreStateForConnectionChange()
            clearLogoUploadStateForConnectionChange()
            clearClockConfigurationCacheForConnectionChange()
            clearAlarmOperationsForConnectionChange(markInterrupted: true)
            clearPaletteOperationsForConnectionChange(invalidateRecords: true)
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
            if let record = disconnectedTarget?.rememberedDeviceRecord {
                if retryManualRememberedConnectionAfterFailure(for: record) {
                    presentationState = .connecting
                } else {
                    finishManualRememberedConnectionWithFailure(for: record, cancelActiveConnection: false)
                    presentationState = .disconnected
                }
            }
            if let automaticReconnectRecord {
                if finishAutomaticReconnectIfLastAttemptFailed(record: automaticReconnectRecord) {
                    presentationState = .disconnected
                } else {
                    presentationState = .connecting
                }
            }
        }

        return presentationState
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
            if automaticReconnectIntent == .startupAutomatic {
                appendEvent("Startup reconnect succeeded")
            }
        case .rememberedDevice:
            connectedEndpointDescription = pendingConnectionEndpointDescription
            connectedDiscoveredDevice = pendingConnectionDevice
        }

        connectedProtocolBoardID = pendingProtocolBoardID
        persistLastConnectedDeviceIfPossible(for: target, boardID: pendingProtocolBoardID)
        prepareAlarmCacheForConnectedDevice(target: target)
        rememberedDeviceConnectionFailureAlert = nil
        pendingSelectedEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingManualHost = nil
        pendingManualPort = nil
        pendingProtocolBoardID = nil
        scannerConnectionErrorText = nil
        discoveryService.updateConnectedEndpointDescription(connectedEndpointDescription)
        connectionAttempt = .connected(target)
        suppressAutomaticReconnectUntilInactive = false
        if case .rememberedDevice = target {
            appendEvent("Manual connect succeeded")
            cancelManualRememberedConnectionOperation()
        }
        cancelAutomaticReconnect(resetDiagnostics: false)
    }

    private var shouldShowAutomaticReconnectStatus: Bool {
        automaticReconnectGeneration != nil && state != .connected
    }

    private func nextAutomaticReconnectIntentForActiveScene() -> AutomaticReconnectIntent {
        guard didEvaluateStartupReconnectForAuthorization else {
            didEvaluateStartupReconnectForAuthorization = true
            return .startupAutomatic
        }

        return .backgroundAutomatic
    }

    private var isConnectionAttemptPending: Bool {
        connectionAttempt.pendingTarget != nil
    }

    private var isRememberedDeviceConnectionPending: Bool {
        connectionAttempt.pendingTarget?.rememberedDeviceRecord != nil
    }

    private var activeAutomaticReconnectRecord: LastConnectedDevice? {
        guard automaticReconnectGeneration != nil else {
            return nil
        }

        return pendingAutomaticReconnectRecord ?? lastConnectedDevice
    }

    private func startManualRememberedConnection(to record: LastConnectedDevice) {
        cancelManualRememberedConnectionOperation()

        let operationID = UUID()
        manualRememberedConnectionOperation = ManualRememberedConnectionOperation(
            id: operationID,
            record: record
        )
        appendEvent("Manual connect started: \(record.presentedDisplayName)")
        manualRememberedConnectionOperation?.deadlineTask = manualConnectScheduler(Self.manualRememberedConnectionDeadline) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleManualRememberedConnectionDeadline(operationID: operationID)
            }
        }

        guard startNextManualRememberedConnectionAttempt(operationID: operationID, isRetry: false) else {
            finishManualRememberedConnectionWithFailure(for: record, cancelActiveConnection: false)
            return
        }
    }

    private func retryManualRememberedConnectionAfterFailure(for record: LastConnectedDevice) -> Bool {
        guard
            let operation = manualRememberedConnectionOperation,
            operation.record == record
        else {
            return false
        }

        appendEvent("Manual connect attempt \(operation.startedAttemptCount) failed")
        return startNextManualRememberedConnectionAttempt(operationID: operation.id, isRetry: true)
    }

    private func startNextManualRememberedConnectionAttempt(operationID: UUID, isRetry: Bool) -> Bool {
        guard
            var operation = manualRememberedConnectionOperation,
            operation.id == operationID
        else {
            return false
        }

        guard let attempt = nextManualRememberedConnectionAttempt(for: &operation) else {
            manualRememberedConnectionOperation = operation
            return false
        }

        manualRememberedConnectionOperation = operation

        if isRetry {
            appendEvent("Manual connect retry using refreshed endpoint")
        }

        beginConnectionAttempt(.rememberedDevice(operation.record))
        pendingConnectionDevice = attempt.candidate.device
        pendingProtocolBoardID = operation.record.boardID
        pendingConnectionEndpointDescription = attempt.candidate.endpointDescription
        endpointSourceDiagnosticsText = attempt.candidate.source.diagnosticsText
        client.connect(to: attempt.candidate.endpoint, boardID: operation.record.boardID)
        return true
    }

    private func nextManualRememberedConnectionAttempt(
        for operation: inout ManualRememberedConnectionOperation
    ) -> ManualRememberedConnectionAttempt? {
        while
            operation.startedAttemptCount < Self.manualRememberedConnectionMaxAttempts,
            operation.nextCandidateIndex < Self.automaticReconnectDelays.count
        {
            let candidateIndex = operation.nextCandidateIndex
            operation.nextCandidateIndex += 1

            guard let candidate = automaticReconnectCandidate(
                for: operation.record,
                attemptIndex: candidateIndex
            ) else {
                continue
            }

            let candidateKey = "\(candidate.source.diagnosticsText)|\(candidate.endpointDescription)"
            guard !operation.attemptedCandidateKeys.contains(candidateKey) else {
                continue
            }

            operation.attemptedCandidateKeys.insert(candidateKey)
            operation.startedAttemptCount += 1
            return ManualRememberedConnectionAttempt(candidate: candidate)
        }

        return nil
    }

    private func handleManualRememberedConnectionDeadline(operationID: UUID) {
        guard
            let operation = manualRememberedConnectionOperation,
            operation.id == operationID
        else {
            return
        }

        appendEvent("Manual connect deadline expired")
        finishManualRememberedConnectionWithFailure(for: operation.record, cancelActiveConnection: true)
    }

    private func finishManualRememberedConnectionWithFailure(
        for record: LastConnectedDevice,
        cancelActiveConnection: Bool
    ) {
        cancelManualRememberedConnectionOperation()
        cancelForegroundValidation()
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
        activeConnectionGeneration = nil
        connectionAttempt = .idle
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingSelectedEndpointDescription = nil
        pendingProtocolBoardID = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        connectedProtocolBoardID = nil
        scannerConnectionErrorText = nil
        discoveryService.updateConnectedEndpointDescription(nil)
        rememberedDeviceConnectionFailureAlert = DeviceConnectionFailureAlert(
            deviceName: record.presentedDisplayName
        )
        state = .disconnected
        appendEvent("Manual connect failed: Device Not Found")

        if cancelActiveConnection {
            client.disconnect()
        }
    }

    private func cancelManualRememberedConnectionOperation() {
        manualRememberedConnectionOperation?.deadlineTask?.cancel()
        manualRememberedConnectionOperation = nil
    }

    private func validateForegroundConnectionIfNeeded() {
        guard
            isNetworkingAuthorized,
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
                    self.startAutomaticReconnectIfPossible(
                        replacingCurrentConnection: true,
                        intent: .backgroundAutomatic
                    )
                }
            }
        }
    }

    private func startAutomaticReconnectIfPossible(
        replacingCurrentConnection: Bool = false,
        intent: AutomaticReconnectIntent
    ) {
        guard
            isNetworkingAuthorized,
            isAppActive,
            !suppressAutomaticReconnectUntilInactive,
            automaticReconnectEnabled,
            !userRequestedDisconnect,
            automaticReconnectGeneration == nil,
            !isConnectionAttemptPending,
            let record = lastConnectedDevice,
            record.boardID != ESP32TCPClient.reservedBoardID
        else {
            return
        }

        if state == .connected, !replacingCurrentConnection {
            return
        }

        let generation = UUID()
        let attemptLimit = min(intent.maximumAttemptCount, Self.automaticReconnectDelays.count)
        guard attemptLimit > 0 else {
            return
        }

        let attemptIndices = Array(Self.automaticReconnectDelays.indices.prefix(attemptLimit))
        automaticReconnectGeneration = generation
        automaticReconnectIntent = intent
        foregroundReconnectRequired = false
        resumeActionDiagnosticsText = "Reconnecting"
        foregroundValidationDiagnosticsText = "Idle"
        reconnectAttemptDiagnosticsText = "0 of \(attemptLimit)"
        endpointSourceDiagnosticsText = "None"
        automaticReconnectLastStartedAttemptIndex = nil
        automaticReconnectLastScheduledAttemptIndex = attemptIndices.last
        automaticReconnectAttemptLimit = attemptLimit

        if intent == .startupAutomatic {
            appendEvent("Startup reconnect started: \(record.presentedDisplayName)")
        }

        for index in attemptIndices {
            let delay = Self.automaticReconnectDelays[index]
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

        automaticReconnectDeadlineTask = reconnectScheduler(Self.automaticReconnectDeadline) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleAutomaticReconnectDeadline(generation: generation, record: record)
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
            isNetworkingAuthorized,
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
            if automaticReconnectLastScheduledAttemptIndex == index {
                finishAutomaticReconnectAttempts(
                    generation: generation,
                    finalRecord: record,
                    cancelActiveConnection: true
                )
            }
            return
        }

        pendingAutomaticReconnectRecord = record
        pendingConnectionDevice = candidate.device
        pendingProtocolBoardID = record.boardID
        pendingConnectionEndpointDescription = candidate.endpointDescription
        reconnectAttemptDiagnosticsText = "\(index + 1) of \(automaticReconnectAttemptLimit)"
        endpointSourceDiagnosticsText = candidate.source.diagnosticsText
        automaticReconnectLastStartedAttemptIndex = index

        beginConnectionAttempt(.automaticReconnect(record))
        client.connect(to: candidate.endpoint, boardID: record.boardID)
    }

    @discardableResult
    private func finishAutomaticReconnectIfLastAttemptFailed(record: LastConnectedDevice?) -> Bool {
        guard
            let generation = automaticReconnectGeneration,
            let lastScheduledAttemptIndex = automaticReconnectLastScheduledAttemptIndex,
            automaticReconnectLastStartedAttemptIndex == lastScheduledAttemptIndex
        else {
            return false
        }

        finishAutomaticReconnectAttempts(
            generation: generation,
            finalRecord: record,
            cancelActiveConnection: false
        )
        return true
    }

    private func handleAutomaticReconnectDeadline(generation: UUID, record: LastConnectedDevice) {
        guard automaticReconnectGeneration == generation else {
            return
        }

        if automaticReconnectIntent == .startupAutomatic {
            appendEvent("Startup reconnect deadline expired")
        }

        finishAutomaticReconnectAttempts(
            generation: generation,
            finalRecord: record,
            cancelActiveConnection: true
        )
    }

    private func finishAutomaticReconnectAttempts(
        generation: UUID,
        finalRecord: LastConnectedDevice?,
        cancelActiveConnection: Bool
    ) {
        guard automaticReconnectGeneration == generation else {
            return
        }

        let intent = automaticReconnectIntent
        let record = finalRecord ?? pendingAutomaticReconnectRecord ?? lastConnectedDevice

        cancelAutomaticReconnect(resetDiagnostics: false)
        cancelForegroundValidation()
        clearTimeSyncStateForConnectionChange()
        clearDisplayModeStateForConnectionChange()
        clearDefaultLogoRestoreStateForConnectionChange()
        clearLogoUploadStateForConnectionChange()
        clearClockConfigurationCacheForConnectionChange()
        clearAlarmOperationsForConnectionChange(markInterrupted: true)
        clearPaletteOperationsForConnectionChange(invalidateRecords: true)
        activeConnectionGeneration = nil
        connectionAttempt = .idle
        isExpectingInitialDisconnect = false
        pendingConnectionEndpointDescription = nil
        pendingConnectionDevice = nil
        pendingAutomaticReconnectRecord = nil
        pendingSelectedEndpointDescription = nil
        pendingProtocolBoardID = nil
        connectedEndpointDescription = nil
        connectedDiscoveredDevice = nil
        connectedProtocolBoardID = nil
        scannerConnectionErrorText = nil
        discoveryService.updateConnectedEndpointDescription(nil)
        resumeActionDiagnosticsText = "Idle"
        endpointSourceDiagnosticsText = "None"
        state = .disconnected

        if intent == .startupAutomatic, let record {
            suppressAutomaticReconnectUntilInactive = true
            rememberedDeviceConnectionFailureAlert = DeviceConnectionFailureAlert(
                deviceName: record.presentedDisplayName
            )
            appendEvent("Startup reconnect failed: Device Not Found")
        }

        if cancelActiveConnection {
            client.disconnect()
        }
    }

    private func cancelAutomaticReconnect(resetDiagnostics: Bool) {
        automaticReconnectTasks.forEach { $0.cancel() }
        automaticReconnectTasks.removeAll()
        automaticReconnectDeadlineTask?.cancel()
        automaticReconnectDeadlineTask = nil
        automaticReconnectGeneration = nil
        automaticReconnectIntent = nil
        automaticReconnectLastStartedAttemptIndex = nil
        automaticReconnectLastScheduledAttemptIndex = nil
        automaticReconnectAttemptLimit = 0
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
        case let .rememberedDevice(existingRecord):
            record = existingRecord.withDefaultLogoFallback()
        }

        guard let record else {
            return
        }

        lastConnectedDevice = record
        Self.saveLastConnectedDevice(record, to: userDefaults)
    }

    private var alarmCacheIsValidForActiveDevice: Bool {
        activeAlarmCacheDeviceIdentity != nil &&
            activeAlarmCacheDeviceIdentity == loadedAlarmCacheDeviceIdentity
    }

    private func prepareAlarmCacheForConnectedDevice(target: ConnectionTarget) {
        guard let boardID = connectedProtocolBoardID else {
            activeAlarmCacheDeviceIdentity = nil
            return
        }

        let identity: AlarmCacheDeviceIdentity
        switch target {
        case .manual:
            let host = pendingManualHost ?? self.host
            let port = pendingManualPort ?? UInt16(self.port) ?? ESP32TCPClient.defaultPort
            identity = AlarmCacheDeviceIdentity(
                boardID: boardID,
                stableEndpoint: "manual|\(host.lowercased()):\(port)"
            )
        case .discovered:
            if let record = lastConnectedDevice, record.boardID == boardID {
                identity = Self.alarmCacheIdentity(record)
            } else {
                identity = AlarmCacheDeviceIdentity(
                    boardID: boardID,
                    stableEndpoint: "bonjour|\((connectedEndpointDescription ?? "unknown").lowercased())"
                )
            }
        case let .automaticReconnect(record), let .rememberedDevice(record):
            identity = Self.alarmCacheIdentity(record)
        }

        if let alarmRecordsDeviceIdentity, alarmRecordsDeviceIdentity != identity {
            alarmRecords = AlarmRecord.makeDefaultRecords()
            selectedAlarmID = nil
            alarmEditorDraft = nil
            alarmReadOperationState = .idle
        }
        if let loadedAlarmCacheDeviceIdentity, loadedAlarmCacheDeviceIdentity != identity {
            self.loadedAlarmCacheDeviceIdentity = nil
        }

        activeAlarmCacheDeviceIdentity = identity
        alarmRecordsDeviceIdentity = identity
    }

    private static func alarmCacheIdentity(_ record: LastConnectedDevice) -> AlarmCacheDeviceIdentity {
        AlarmCacheDeviceIdentity(
            boardID: record.boardID,
            stableEndpoint: "\(record.source.rawValue)|\(record.endpointDescription.lowercased())"
        )
    }

    private func invalidateAlarmCacheAfterFactoryReset() {
        loadedAlarmCacheDeviceIdentity = nil
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

    private static func loadLastNormalDisplayMode(from userDefaults: UserDefaults) -> PaletteMode {
        let rawValue = UInt8(clamping: userDefaults.integer(forKey: lastNormalDisplayModeDefaultsKey))
        guard let mode = PaletteMode(rawValue: rawValue), mode.isEditable else {
            return .mode1
        }

        return mode
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

enum SetDisplayModeState: Equatable {
    case idle
    case sending(mode: PaletteMode)
    case waitingForConfirmation(mode: PaletteMode)
    case succeeded(mode: PaletteMode)
    case failed(mode: PaletteMode, message: String)

    var isPending: Bool {
        switch self {
        case .sending, .waitingForConfirmation:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    var pendingMode: PaletteMode? {
        switch self {
        case let .sending(mode), let .waitingForConfirmation(mode):
            mode
        case .idle, .succeeded, .failed:
            nil
        }
    }

    var errorMessage: String? {
        guard case let .failed(_, message) = self else {
            return nil
        }
        return message
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
            "Waiting for CLOCK confirmation"
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

    var presentedDisplayName: String {
        displayName.removingESP32PresentationPrefix
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

private struct ManualRememberedConnectionOperation {
    let id: UUID
    let record: LastConnectedDevice
    var nextCandidateIndex = 0
    var startedAttemptCount = 0
    var attemptedCandidateKeys: Set<String> = []
    var deadlineTask: CancellableTask?
}

private struct ManualRememberedConnectionAttempt {
    let candidate: AutomaticReconnectCandidate
}

private enum AutomaticReconnectIntent {
    case startupAutomatic
    case backgroundAutomatic

    var maximumAttemptCount: Int {
        switch self {
        case .startupAutomatic:
            ESP32ControllerViewModel.startupAutomaticReconnectMaxAttempts
        case .backgroundAutomatic:
            ESP32ControllerViewModel.automaticReconnectDelays.count
        }
    }
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

struct DeviceConnectionFailureAlert: Equatable {
    let deviceName: String

    var title: String {
        "Device Not Found"
    }

    var message: String {
        "\(deviceName) was not found. Check that the device is powered on and connected to the network."
    }
}

struct ClockDevicesSectionPresentation: Equatable {
    let deviceLabel = "Device"
    let deviceName: String?
    let deviceNameStyle: ClockDevicesTextStyle
    let stateLabel = "State"
    let stateText: String
    let stateStyle: ClockDevicesStateStyle
    let action: ClockDevicesAction?
}

enum ClockDevicesTextStyle: Equatable {
    case primary
}

enum ClockDevicesStateStyle: Equatable {
    case connected
    case disconnected
    case connecting
    case failed

    init(connectionState: TCPConnectionState) {
        switch connectionState {
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .failed:
            self = .failed
        }
    }
}

enum ClockDevicesAction: Equatable {
    case connect
    case connecting
    case disconnect
}

private enum ConnectionTarget: Equatable {
    case manual
    case discovered(String)
    case automaticReconnect(LastConnectedDevice)
    case rememberedDevice(LastConnectedDevice)
}

private enum ConnectionAttempt: Equatable {
    case idle
    case starting(ConnectionTarget)
    case connecting(ConnectionTarget)
    case connected(ConnectionTarget)
    case explicitDisconnect
}

private extension ConnectionAttempt {
    var pendingTarget: ConnectionTarget? {
        switch self {
        case let .starting(target), let .connecting(target):
            target
        case .idle, .connected, .explicitDisconnect:
            nil
        }
    }
}

private extension ConnectionTarget {
    var rememberedDeviceRecord: LastConnectedDevice? {
        if case let .rememberedDevice(record) = self {
            return record
        }

        return nil
    }

    var automaticReconnectRecord: LastConnectedDevice? {
        if case let .automaticReconnect(record) = self {
            return record
        }

        return nil
    }
}

private struct ClockConfiguration: Equatable {
    let is24HourFormat: Bool
    let brightnessLevel: UInt8
}

private struct PendingClockConfigurationRead: Equatable {
    let id: UUID
    let connectionGeneration: UUID
    let boardID: UInt8
    let isAutomatic: Bool
    let timeFormatUserEditRevision: Int
    let brightnessUserEditRevision: Int
}

private struct PendingReadDisplayModeOperation: Equatable {
    let id: UUID
    let connectionGeneration: UUID
    let boardID: UInt8
    let isAutomatic: Bool
}

private struct AlarmCacheDeviceIdentity: Equatable {
    let boardID: UInt8
    let stableEndpoint: String
}

private enum AutomaticStartupLoadPhase: Equatable {
    case idle
    case waitingForPalettes
    case readingDisplayMode
    case readingConfiguration
    case readingAlarms
    case complete
}

private struct PendingPaletteOperation: Equatable {
    let id: UUID
    let connectionGeneration: UUID
    let boardID: UInt8
    let kind: PaletteOperationKind
    let mode: PaletteMode
    let draft: ModePaletteDraft?
}

private enum PaletteViewModelTransactionError: LocalizedError {
    case notConnected
    case missingDraft

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Connect to a CLOCK before starting a palette operation."
        case .missingDraft:
            "A complete palette draft is required for save."
        }
    }
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
