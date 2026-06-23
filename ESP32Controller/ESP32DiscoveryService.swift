//
//  ESP32DiscoveryService.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 23/06/26.
//

import Foundation
import Network

enum ESP32DiscoveryState: Equatable {
    case stopped
    case starting
    case refreshing
    case ready
    case waiting(String)
    case failed(String)

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .refreshing:
            "Refreshing"
        case .ready:
            "Ready"
        case .waiting:
            "Waiting"
        case .failed:
            "Failed"
        }
    }

    var detail: String? {
        switch self {
        case let .waiting(error), let .failed(error):
            error
        case .stopped, .starting, .refreshing, .ready:
            nil
        }
    }
}

enum ESP32ScannerState: Equatable {
    case idle
    case scanning
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .scanning:
            "Scanning"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        }
    }

    var errorText: String? {
        switch self {
        case let .failed(error):
            error
        case .idle, .scanning, .completed:
            nil
        }
    }
}

protocol ESP32Browsing: AnyObject {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)? { get set }
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

extension NWBrowser: ESP32Browsing {}

protocol ESP32ProbeConnection: AnyObject {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

extension NWConnection: ESP32ProbeConnection {}

struct ESP32BrowseResult {
    let endpoint: NWEndpoint
    let metadata: NWBrowser.Result.Metadata
}

@MainActor
final class ESP32DiscoveryService: ObservableObject {
    typealias BrowserFactory = () -> ESP32Browsing
    typealias ProbeConnectionFactory = (NWEndpoint) -> ESP32ProbeConnection
    typealias TimeoutScheduler = (@escaping @Sendable () -> Void) -> CancellableTask
    typealias InitialResultSettleScheduler = (@escaping @Sendable () -> Void) -> CancellableTask

    nonisolated static let serviceType = "_espclock._tcp"
    nonisolated static let probeTimeoutSeconds = 2.0
    nonisolated static let initialResultSettleSeconds = 0.5
    private static let maxConcurrentProbes = 2

    @Published private(set) var state: ESP32DiscoveryState = .stopped
    @Published private(set) var scannerState: ESP32ScannerState = .idle
    @Published private(set) var devices: [DiscoveredESP32] = []
    @Published private(set) var errorText: String?
    @Published private(set) var isRefreshing = false

    private let queue = DispatchQueue(label: "ESP32Controller.Discovery")
    private let browserFactory: BrowserFactory
    private let probeConnectionFactory: ProbeConnectionFactory
    private let timeoutScheduler: TimeoutScheduler
    private let initialResultSettleScheduler: InitialResultSettleScheduler
    private var browser: ESP32Browsing?
    private var activeRefreshID: UUID?
    private var connectedEndpointDescription: String?
    private var browsedDevicesByEndpoint: [String: DiscoveredESP32] = [:]
    private var probesByEndpoint: [String: ActiveProbe] = [:]
    private var pendingProbeEndpointDescriptions: [String] = []
    private var probeEndpointsByDescription: [String: NWEndpoint] = [:]
    private var probedEndpointDescriptions: Set<String> = []
    private var hasProcessedBrowseResultsForRefresh = false
    private var initialResultSettleTask: CancellableTask?

    init(
        browserFactory: @escaping BrowserFactory = {
            NWBrowser(
                for: .bonjourWithTXTRecord(
                    type: ESP32DiscoveryService.serviceType,
                    domain: nil
                ),
                using: .tcp
            )
        },
        probeConnectionFactory: @escaping ProbeConnectionFactory = { endpoint in
            NWConnection(to: endpoint, using: .tcp)
        },
        timeoutScheduler: @escaping TimeoutScheduler = { timeout in
            let workItem = DispatchWorkItem(block: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + ESP32DiscoveryService.probeTimeoutSeconds, execute: workItem)
            return DispatchWorkItemCancellable(workItem: workItem)
        },
        initialResultSettleScheduler: @escaping InitialResultSettleScheduler = { timeout in
            let workItem = DispatchWorkItem(block: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + ESP32DiscoveryService.initialResultSettleSeconds, execute: workItem)
            return DispatchWorkItemCancellable(workItem: workItem)
        }
    ) {
        self.browserFactory = browserFactory
        self.probeConnectionFactory = probeConnectionFactory
        self.timeoutScheduler = timeoutScheduler
        self.initialResultSettleScheduler = initialResultSettleScheduler
    }

    func startDiscovery() {
        beginDeviceScan(connectedEndpointDescription: connectedEndpointDescription)
    }

    func stopDiscovery() {
        stopScan()
        devices = []
        errorText = nil
        isRefreshing = false
        state = .stopped
        scannerState = .idle
    }

    func refreshDiscovery() {
        beginDeviceScan(connectedEndpointDescription: connectedEndpointDescription)
    }

    func refreshDevices(connectedEndpointDescription: String? = nil) {
        beginDeviceScan(connectedEndpointDescription: connectedEndpointDescription)
    }

    func beginDeviceScan(connectedEndpointDescription: String? = nil) {
        cancelActiveRefresh()

        let refreshID = UUID()
        let browser = browserFactory()
        activeRefreshID = refreshID
        self.browser = browser
        self.connectedEndpointDescription = connectedEndpointDescription
        browsedDevicesByEndpoint.removeAll()
        hasProcessedBrowseResultsForRefresh = false
        errorText = nil
        isRefreshing = true
        state = .refreshing
        scannerState = .scanning
        devices = []

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor [weak self, weak browser] in
                guard let browser else {
                    return
                }

                self?.handleBrowserState(state, refreshID: refreshID, browser: browser)
            }
        }

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let browseResults = results.map {
                ESP32BrowseResult(endpoint: $0.endpoint, metadata: $0.metadata)
            }

            Task { @MainActor [weak self, weak browser] in
                guard let browser else {
                    return
                }

                self?.applyBrowseResults(browseResults, refreshID: refreshID, browser: browser)
            }
        }

        browser.start(queue: queue)
    }

    func stopScan() {
        cancelActiveRefresh()
        devices = []
        errorText = nil
        isRefreshing = false
        state = .stopped
        scannerState = .idle
    }

    func applyBrowseResults(
        _ results: [ESP32BrowseResult],
        refreshID: UUID,
        browser: ESP32Browsing
    ) {
        guard isActiveBrowser(refreshID, browser: browser) else {
            return
        }

        cancelInitialResultSettleTask()
        hasProcessedBrowseResultsForRefresh = true
        var devicesByID: [String: DiscoveredESP32] = [:]
        for result in results {
            var device = Self.device(from: result)
            updateLivenessForCurrentConnection(device: &device)
            devicesByID[device.id] = device
        }

        let resultIDs = Set(devicesByID.keys)
        cancelProbesForRemovedEndpoints(remainingEndpointDescriptions: resultIDs)
        browsedDevicesByEndpoint = devicesByID
        devices = devices.compactMap { existingDevice in
            guard var updatedDevice = devicesByID[existingDevice.stableEndpointDescription] else {
                return nil
            }

            updatedDevice.livenessState = existingDevice.livenessState
            return updatedDevice
        }
        devices = Self.sortDevices(devices)
        enqueueNeededProbes(for: Array(devicesByID.values), refreshID: refreshID)
        finishRefreshIfPossible(refreshID: refreshID)
    }

    func applyBrowseResultsForTesting(_ results: [ESP32BrowseResult], browser: ESP32Browsing) {
        guard let activeRefreshID else {
            return
        }

        applyBrowseResults(results, refreshID: activeRefreshID, browser: browser)
    }

    func updateConnectedEndpointDescription(_ endpointDescription: String?) {
        connectedEndpointDescription = endpointDescription

        for index in devices.indices {
            if devices[index].stableEndpointDescription == endpointDescription {
                devices[index].livenessState = .connected
                cancelProbe(endpointDescription: devices[index].stableEndpointDescription)
                removePendingProbe(endpointDescription: devices[index].stableEndpointDescription)
            } else if devices[index].livenessState == .connected {
                devices[index].livenessState = .unknown
            }
        }

        finishRefreshIfPossible(refreshID: activeRefreshID)
    }

    private func handleBrowserState(
        _ browserState: NWBrowser.State,
        refreshID: UUID,
        browser: ESP32Browsing
    ) {
        guard isActiveBrowser(refreshID, browser: browser) else {
            return
        }

        switch browserState {
        case .setup:
            state = .refreshing
            scannerState = .scanning
            errorText = nil
        case .ready:
            startInitialResultSettleTask(refreshID: refreshID)
            finishRefreshIfPossible(refreshID: refreshID)
            errorText = nil
        case let .waiting(error):
            let text = Self.fullErrorDescription(error)
            state = .waiting(text)
            errorText = text
        case let .failed(error):
            let text = Self.fullErrorDescription(error)
            cancelInitialResultSettleTask()
            cancelAllProbes()
            self.browser = nil
            activeRefreshID = nil
            isRefreshing = false
            state = .failed(text)
            scannerState = .failed(text)
            errorText = text
            browser.cancel()
        case .cancelled:
            if isActiveBrowser(refreshID, browser: browser) {
                cancelInitialResultSettleTask()
                cancelAllProbes()
                state = .stopped
                scannerState = .idle
                errorText = nil
                self.browser = nil
                activeRefreshID = nil
                isRefreshing = false
            }
        @unknown default:
            let text = "Unknown browser state"
            cancelInitialResultSettleTask()
            cancelAllProbes()
            self.browser = nil
            activeRefreshID = nil
            isRefreshing = false
            state = .failed(text)
            scannerState = .failed(text)
            errorText = text
        }
    }

    private func isActiveBrowser(_ refreshID: UUID, browser: ESP32Browsing) -> Bool {
        activeRefreshID == refreshID && self.browser === browser
    }

    private func isActiveRefresh(_ refreshID: UUID) -> Bool {
        activeRefreshID == refreshID
    }

    private func cancelActiveRefresh() {
        let browserToCancel = browser
        cancelInitialResultSettleTask()
        activeRefreshID = nil
        browser = nil
        browserToCancel?.stateUpdateHandler = nil
        browserToCancel?.browseResultsChangedHandler = nil
        browserToCancel?.cancel()
        cancelAllProbes()
        browsedDevicesByEndpoint.removeAll()
        hasProcessedBrowseResultsForRefresh = false
    }

    private func startInitialResultSettleTask(refreshID: UUID) {
        guard isActiveRefresh(refreshID), !hasProcessedBrowseResultsForRefresh else {
            return
        }

        guard initialResultSettleTask == nil else {
            return
        }

        initialResultSettleTask = initialResultSettleScheduler { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeEmptyRefreshIfNeeded(refreshID: refreshID)
            }
        }
    }

    private func completeEmptyRefreshIfNeeded(refreshID: UUID) {
        guard isActiveRefresh(refreshID), !hasProcessedBrowseResultsForRefresh else {
            return
        }

        cancelInitialResultSettleTask()
        hasProcessedBrowseResultsForRefresh = true
        devices = []
        browsedDevicesByEndpoint.removeAll()
        cancelAllProbes()
        finishRefreshIfPossible(refreshID: refreshID)
    }

    private func cancelInitialResultSettleTask() {
        initialResultSettleTask?.cancel()
        initialResultSettleTask = nil
    }

    private func updateLivenessForCurrentConnection(device: inout DiscoveredESP32) {
        if device.stableEndpointDescription == connectedEndpointDescription {
            device.livenessState = .connected
            addVisibleDevice(device)
            return
        }

        device.livenessState = .checking
    }

    private func enqueueNeededProbes(for devices: [DiscoveredESP32], refreshID: UUID) {
        guard isActiveRefresh(refreshID) else {
            return
        }

        for device in devices {
            let endpointDescription = device.stableEndpointDescription
            guard endpointDescription != connectedEndpointDescription else {
                continue
            }

            guard probesByEndpoint[endpointDescription] == nil else {
                continue
            }

            guard !pendingProbeEndpointDescriptions.contains(endpointDescription) else {
                continue
            }

            guard !probedEndpointDescriptions.contains(endpointDescription) else {
                continue
            }

            probeEndpointsByDescription[endpointDescription] = device.endpoint
            pendingProbeEndpointDescriptions.append(endpointDescription)
        }

        startNextProbes(refreshID: refreshID)
    }

    private func startNextProbes(refreshID: UUID) {
        guard isActiveRefresh(refreshID) else {
            return
        }

        while probesByEndpoint.count < Self.maxConcurrentProbes, !pendingProbeEndpointDescriptions.isEmpty {
            let endpointDescription = pendingProbeEndpointDescriptions.removeFirst()
            guard let endpoint = probeEndpointsByDescription[endpointDescription] else {
                continue
            }

            guard probesByEndpoint[endpointDescription] == nil else {
                continue
            }

            probedEndpointDescriptions.insert(endpointDescription)
            let connection = probeConnectionFactory(endpoint)
            var timeout: CancellableTask?
            timeout = timeoutScheduler { [weak self, weak connection] in
                if let connection {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }

                Task { @MainActor [weak self] in
                    self?.completeProbe(
                        endpointDescription: endpointDescription,
                        refreshID: refreshID,
                        livenessState: .offline,
                        alreadyCleanedUp: true
                    )
                }
            }

            guard let timeout else {
                continue
            }

            probesByEndpoint[endpointDescription] = ActiveProbe(connection: connection, timeout: timeout)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                let isTerminalState: Bool
                switch state {
                case .ready, .failed, .cancelled:
                    isTerminalState = true
                case .setup, .preparing, .waiting:
                    isTerminalState = false
                @unknown default:
                    isTerminalState = true
                }

                if isTerminalState {
                    connection?.stateUpdateHandler = nil
                    timeout.cancel()
                    connection?.cancel()
                }

                Task { @MainActor [weak self, weak connection] in
                    guard connection != nil else {
                        return
                    }

                    self?.handleProbeState(
                        state,
                        endpointDescription: endpointDescription,
                        refreshID: refreshID,
                        alreadyCleanedUp: isTerminalState
                    )
                }
            }

            connection.start(queue: queue)
        }
    }

    private func handleProbeState(
        _ state: NWConnection.State,
        endpointDescription: String,
        refreshID: UUID,
        alreadyCleanedUp: Bool = false
    ) {
        guard isActiveRefresh(refreshID) else {
            return
        }

        switch state {
        case .ready:
            completeProbe(
                endpointDescription: endpointDescription,
                refreshID: refreshID,
                livenessState: .online,
                alreadyCleanedUp: alreadyCleanedUp
            )
        case .failed, .cancelled:
            completeProbe(
                endpointDescription: endpointDescription,
                refreshID: refreshID,
                livenessState: .offline,
                alreadyCleanedUp: alreadyCleanedUp
            )
        case .setup, .preparing, .waiting:
            setLiveness(.checking, endpointDescription: endpointDescription)
        @unknown default:
            completeProbe(
                endpointDescription: endpointDescription,
                refreshID: refreshID,
                livenessState: .offline,
                alreadyCleanedUp: alreadyCleanedUp
            )
        }
    }

    private func completeProbe(
        endpointDescription: String,
        refreshID: UUID,
        livenessState: ESP32LivenessState,
        alreadyCleanedUp: Bool = false
    ) {
        guard isActiveRefresh(refreshID) else {
            return
        }

        guard let probe = probesByEndpoint.removeValue(forKey: endpointDescription) else {
            return
        }

        if !alreadyCleanedUp {
            probe.connection.stateUpdateHandler = nil
            probe.timeout.cancel()
            probe.connection.cancel()
        }

        if endpointDescription == connectedEndpointDescription {
            setLiveness(.connected, endpointDescription: endpointDescription)
        } else if livenessState == .online, var device = browsedDevicesByEndpoint[endpointDescription] {
            device.livenessState = .online
            addVisibleDevice(device)
        } else {
            devices.removeAll { $0.stableEndpointDescription == endpointDescription }
        }

        startNextProbes(refreshID: refreshID)
        finishRefreshIfPossible(refreshID: refreshID)
    }

    private func setLiveness(_ livenessState: ESP32LivenessState, endpointDescription: String) {
        guard let index = devices.firstIndex(where: { $0.stableEndpointDescription == endpointDescription }) else {
            return
        }

        devices[index].livenessState = livenessState
    }

    private func addVisibleDevice(_ device: DiscoveredESP32) {
        if let index = devices.firstIndex(where: { $0.stableEndpointDescription == device.stableEndpointDescription }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        devices = Self.sortDevices(devices)
    }

    private func cancelProbesForRemovedEndpoints(remainingEndpointDescriptions: Set<String>) {
        for endpointDescription in Array(probesByEndpoint.keys) where !remainingEndpointDescriptions.contains(endpointDescription) {
            cancelProbe(endpointDescription: endpointDescription)
        }

        pendingProbeEndpointDescriptions.removeAll { !remainingEndpointDescriptions.contains($0) }
        probeEndpointsByDescription = probeEndpointsByDescription.filter { remainingEndpointDescriptions.contains($0.key) }
        probedEndpointDescriptions = probedEndpointDescriptions.filter { remainingEndpointDescriptions.contains($0) }
    }

    private func cancelProbe(endpointDescription: String) {
        guard let probe = probesByEndpoint.removeValue(forKey: endpointDescription) else {
            return
        }

        probe.connection.stateUpdateHandler = nil
        probe.timeout.cancel()
        probe.connection.cancel()
    }

    private func cancelAllProbes() {
        for probe in probesByEndpoint.values {
            probe.connection.stateUpdateHandler = nil
            probe.timeout.cancel()
            probe.connection.cancel()
        }

        probesByEndpoint.removeAll()
        pendingProbeEndpointDescriptions.removeAll()
        probeEndpointsByDescription.removeAll()
        probedEndpointDescriptions.removeAll()
    }

    private func removePendingProbe(endpointDescription: String) {
        pendingProbeEndpointDescriptions.removeAll { $0 == endpointDescription }
        probeEndpointsByDescription.removeValue(forKey: endpointDescription)
    }

    private func finishRefreshIfPossible(refreshID: UUID?) {
        guard let refreshID, isActiveRefresh(refreshID) else {
            return
        }

        guard hasProcessedBrowseResultsForRefresh else {
            return
        }

        guard pendingProbeEndpointDescriptions.isEmpty, probesByEndpoint.isEmpty else {
            return
        }

        isRefreshing = false
        state = .ready
        scannerState = .completed
    }

    nonisolated static func device(from result: ESP32BrowseResult) -> DiscoveredESP32 {
        let txt = txtValues(from: result.metadata)
        let serviceName = serviceInstanceName(from: result.endpoint) ?? result.endpoint.debugDescription
        let stableEndpointDescription = String(describing: result.endpoint)

        return DiscoveredESP32(
            id: stableEndpointDescription,
            serviceName: serviceName,
            endpoint: result.endpoint,
            boardID: txt["id"],
            model: txt["model"],
            protocolVersion: txt["protocol"],
            firmwareVersion: txt["firmware"],
            livenessState: .unknown
        )
    }

    nonisolated static func txtValues(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else {
            return [:]
        }

        return record.dictionary
    }

    nonisolated static func serviceInstanceName(from endpoint: NWEndpoint) -> String? {
        guard case let .service(name: name, type: _, domain: _, interface: _) = endpoint else {
            return nil
        }

        return name
    }

    nonisolated static func sortDevices(_ devices: [DiscoveredESP32]) -> [DiscoveredESP32] {
        devices.sorted { lhs, rhs in
            switch (lhs.boardID, rhs.boardID) {
            case let (lhsBoardID?, rhsBoardID?):
                if lhsBoardID != rhsBoardID {
                    return lhsBoardID < rhsBoardID
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

            if lhs.serviceName != rhs.serviceName {
                return lhs.serviceName < rhs.serviceName
            }

            return lhs.stableEndpointDescription < rhs.stableEndpointDescription
        }
    }

    private nonisolated static func fullErrorDescription(_ error: NWError) -> String {
        String(describing: error)
    }
}

protocol CancellableTask {
    func cancel()
}

private struct DispatchWorkItemCancellable: CancellableTask {
    let workItem: DispatchWorkItem

    func cancel() {
        workItem.cancel()
    }
}

private struct ActiveProbe {
    let connection: ESP32ProbeConnection
    let timeout: CancellableTask
}
