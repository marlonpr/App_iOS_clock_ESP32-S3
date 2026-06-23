//
//  ESP32ControllerTests.swift
//  ESP32ControllerTests
//
//  Created by Marlon Pérez on 22/06/26.
//

import Testing
import Foundation
import Network
@testable import ESP32Controller

@Suite(.serialized)
struct ESP32ControllerTests {

    @Test func txtRecordParsingExtractsBonjourValues() {
        let metadata = NWBrowser.Result.Metadata.bonjour(NWTXTRecord([
            "id": "board-0",
            "model": "clock",
            "protocol": "1",
            "firmware": "2.3.4"
        ]))

        let values = ESP32DiscoveryService.txtValues(from: metadata)

        #expect(values["id"] == "board-0")
        #expect(values["model"] == "clock")
        #expect(values["protocol"] == "1")
        #expect(values["firmware"] == "2.3.4")
    }

    @Test func serviceInstanceNameIsExtractedFromServiceEndpoint() {
        let endpoint = NWEndpoint.service(
            name: "ESP32 Clock 0",
            type: "_espclock._tcp",
            domain: "local",
            interface: nil
        )

        #expect(ESP32DiscoveryService.serviceInstanceName(from: endpoint) == "ESP32 Clock 0")
        #expect(ESP32DiscoveryService.serviceInstanceName(from: .hostPort(host: "192.168.4.1", port: 5000)) == nil)
    }

    @Test func deterministicSortingUsesBoardIDThenServiceNameThenEndpoint() {
        let unsorted = [
            makeDevice(id: "service-c", serviceName: "Clock C", boardID: nil),
            makeDevice(id: "service-b", serviceName: "Clock B", boardID: "board-2"),
            makeDevice(id: "service-a", serviceName: "Clock A", boardID: "board-1"),
            makeDevice(id: "service-d", serviceName: "Clock D", boardID: nil)
        ]

        let sorted = ESP32DiscoveryService.sortDevices(unsorted)

        #expect(sorted.map(\.id) == ["service-a", "service-b", "service-c", "service-d"])
    }

    @MainActor
    @Test func removedServicesDisappearAndChangedTXTUpdates() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)
        service.beginDeviceScan()

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock 0", id: "board-0", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock 1", id: "board-1", firmware: "1.0.0")
        ], browser: browser)
        probes.connections[0].stateUpdateHandler?(.ready)
        probes.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.map(\.boardID) == ["board-0", "board-1"])

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock 1", id: "board-1", firmware: "1.0.1")
        ], browser: browser)

        #expect(service.devices.count == 1)
        #expect(service.devices[0].serviceName == "ESP32 Clock 1")
        #expect(service.devices[0].firmwareVersion == "1.0.1")
    }

    @MainActor
    @Test func viewModelInitializationDoesNotStartScan() {
        var browserCount = 0
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() }
        )
        let discoveryService = ESP32DiscoveryService(
            browserFactory: {
                browserCount += 1
                return FakeESP32Browser()
            }
        )

        let viewModel = ESP32ControllerViewModel(client: client, discoveryService: discoveryService)

        #expect(browserCount == 0)
        #expect(viewModel.scannerState == .idle)
        #expect(!viewModel.isRefreshingDevices)
    }

    @MainActor
    @Test func openingScannerStartsExactlyOneBrowser() async {
        var browserCount = 0
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() }
        )
        let discoveryService = ESP32DiscoveryService(
            browserFactory: {
                browserCount += 1
                return FakeESP32Browser()
            }
        )
        let viewModel = ESP32ControllerViewModel(client: client, discoveryService: discoveryService)

        viewModel.presentDeviceScanner()
        #expect(browserCount == 0)

        viewModel.beginDeviceScan()
        await drainMainQueue()

        #expect(browserCount == 1)
        #expect(viewModel.isScannerPresented)
        #expect(viewModel.scannerState == .scanning)
    }

    @MainActor
    @Test func newScanClearsOldVisibleResults() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.beginDeviceScan()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])
        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.count == 1)

        service.beginDeviceScan()

        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
        #expect(browsers.browsers.count == 2)
    }

    @MainActor
    @Test func closingScannerCancelsDiscoveryResources() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.beginDeviceScan()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.stopScan()

        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .idle)
    }

    @MainActor
    @Test func staleScanCallbacksCannotAddDevices() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.beginDeviceScan()
        let staleBrowser = browsers.browsers[0]

        service.beginDeviceScan()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: staleBrowser)
        await drainMainQueue()

        #expect(probes.connections.isEmpty)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func selectingOneDeviceDisablesOtherConnectActions() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceA)
        await drainMainQueue()

        #expect(viewModel.pendingSelectedEndpointDescription == deviceA.stableEndpointDescription)
        #expect(!viewModel.canSelectScannedDevice(deviceA))
        #expect(!viewModel.canSelectScannedDevice(deviceB))
        #expect(recorder.connections.count == 1)

        viewModel.connect(to: deviceB)

        #expect(recorder.connections.count == 1)
    }

    @MainActor
    @Test func successfulConnectionDismissesScannerState() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.connect(to: device)
        await drainMainQueue()

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        await drainMainQueue()

        #expect(!viewModel.isScannerPresented)
        #expect(viewModel.scannerState == .idle)
        #expect(viewModel.connectedDiscoveredDevice?.stableEndpointDescription == device.stableEndpointDescription)
        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)
    }

    @MainActor
    @Test func failedConnectionKeepsScannerAvailable() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.connect(to: device)
        await drainMainQueue()

        recorder.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.isScannerPresented)
        #expect(viewModel.pendingSelectedEndpointDescription == nil)
        #expect(viewModel.connectedDiscoveredDevice == nil)
        #expect(viewModel.scannerConnectionErrorText != nil)
        #expect(viewModel.canSelectScannedDevice(device))
    }

    @MainActor
    @Test func establishedConnectionRemainsActiveWhenScannerCloses() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.closeDeviceScanner()
        await drainMainQueue()

        #expect(viewModel.state == .connected)
        #expect(viewModel.connectedDiscoveredDevice?.stableEndpointDescription == device.stableEndpointDescription)
        #expect(recorder.connections[0].cancelCallCount == 0)
    }

    @MainActor
    @Test func staleBrowserCallbacksAreIgnoredAfterRefresh() async throws {
        var browsers: [FakeESP32Browser] = []
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = ESP32DiscoveryService(
            browserFactory: {
                let browser = FakeESP32Browser()
                browsers.append(browser)
                return browser
            },
            probeConnectionFactory: probes.makeConnection(endpoint:),
            timeoutScheduler: timeouts.schedule(_:)
        )

        service.beginDeviceScan()
        let staleStateHandler = try #require(browsers[0].stateUpdateHandler)

        service.beginDeviceScan()
        staleStateHandler(.failed(.posix(.ECONNRESET)))
        await Task.yield()

        #expect(browsers[0].cancelCallCount == 1)
        #expect(service.state == .refreshing)
        #expect(service.errorText == nil)

        service.applyBrowseResultsForTesting([], browser: browsers[1])
        browsers[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(service.state == .ready)
    }

    @MainActor
    @Test func browserReadyWithZeroResultsCompletesRefreshAfterSettle() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.isRefreshing)
        #expect(settles.tasks.count == 1)

        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(service.state == .ready)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func resultsBeforeSettleTimeoutCancelEmptyResultTask() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(probes.connections.count == 1)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func staleSettleCallbackCannotFinishNewerRefresh() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(settles.tasks.count == 1)

        service.refreshDevices()
        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(service.state == .refreshing)
        #expect(service.isRefreshing)
        #expect(service.devices.isEmpty)
    }

    @MainActor
    @Test func repeatedRefreshAfterEmptyResultWorksNormally() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(!service.isRefreshing)
        #expect(service.devices.isEmpty)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[1])

        #expect(browsers.browsers.count == 2)
        #expect(probes.connections.count == 1)
        #expect(service.devices.isEmpty)
        #expect(service.isRefreshing)
    }

    @MainActor
    @Test func refreshCancelsOlderBrowserAndProbes() {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.refreshDevices()

        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(service.isRefreshing)
    }

    @MainActor
    @Test func callbacksFromOlderRefreshAreIgnored() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        let oldProbe = probes.connections[0]
        service.refreshDevices()
        oldProbe.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func successfulOneShotProbeMarksOnline() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices[0].livenessState == .online)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func failedOneShotProbeDoesNotAppearInSelectableList() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        probes.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
        #expect(service.scannerState == .completed)
    }

    @MainActor
    @Test func noRecurringProbeIsScheduled() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        #expect(timeouts.tasks.count == 1)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(timeouts.tasks.count == 1)
    }

    @MainActor
    @Test func connectedDeviceIsNotProbed() {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)
        let result = makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        let connectedEndpointDescription = String(describing: result.endpoint)

        service.refreshDevices(connectedEndpointDescription: connectedEndpointDescription)
        service.applyBrowseResultsForTesting([result], browser: browser)

        #expect(probes.connections.isEmpty)
        #expect(service.devices[0].livenessState == .connected)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func browserRemovalRemovesDeviceAndCancelsProbe() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)
        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.count == 1)

        service.applyBrowseResultsForTesting([], browser: browser)

        #expect(service.devices.isEmpty)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func repeatedRefreshCallsDoNotLeaveDuplicateBrowsersOrProbes() {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.refreshDevices()

        #expect(browsers.browsers.count == 2)
        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
    }

    @MainActor
    @Test func browserFailureCancelsActiveProbeConnectionsTimeoutsAndPendingProbes() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock B", id: "board-b", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock C", id: "board-c", firmware: "1.0.0")
        ], browser: browser)

        #expect(probes.connections.count == 2)
        #expect(timeouts.tasks.count == 2)

        browser.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        await drainMainQueue()

        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(probes.connections[1].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(timeouts.tasks[1].cancelCallCount == 1)
        #expect(service.state == .failed("POSIXErrorCode(rawValue: 54): Connection reset by peer"))
        #expect(!service.isRefreshing)

        probes.connections[0].stateUpdateHandler?(.ready)
        probes.connections[1].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(probes.connections.count == 2)
    }

    @MainActor
    @Test func browserFailureCancelsSettleTask() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(settles.tasks.count == 1)

        browser.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        await drainMainQueue()

        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func staleProbeCallbacksCleanLocalResourcesWithoutMutatingCurrentRefresh() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        let staleProbe = probes.connections[0]
        let staleHandler = staleProbe.stateUpdateHandler
        service.refreshDevices()
        let cancelCountAfterRefresh = staleProbe.cancelCallCount

        staleHandler?(.ready)
        await drainMainQueue()

        #expect(staleProbe.cancelCallCount == cancelCountAfterRefresh + 1)
        #expect(timeouts.tasks[0].cancelCallCount == 2)
        #expect(service.state == .refreshing)
        #expect(service.devices.isEmpty)
    }

    @MainActor
    @Test func refreshCompletesAfterAllProbesFinishOrTimeout() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock B", id: "board-b", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock C", id: "board-c", firmware: "1.0.0")
        ], browser: browser)

        #expect(probes.connections.count == 2)
        #expect(service.isRefreshing)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(probes.connections.count == 3)
        #expect(service.isRefreshing)

        timeouts.tasks[1].fire()
        timeouts.tasks[2].fire()
        await drainMainQueue()

        #expect(!service.isRefreshing)
        #expect(service.devices.map(\.livenessState) == [.online])
    }

    @MainActor
    @Test func endpointConnectionUsesSharedLifecycle() async throws {
        let manualConnection = FakeTCPConnection()
        let endpointConnection = FakeTCPConnection()
        let endpoint = NWEndpoint.service(
            name: "ESP32 Clock 0",
            type: "_espclock._tcp",
            domain: "local",
            interface: nil
        )
        var endpointFactoryEndpoint: NWEndpoint?
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in manualConnection },
            endpointConnectionFactory: { requestedEndpoint in
                endpointFactoryEndpoint = requestedEndpoint
                return endpointConnection
            }
        )
        var states: [TCPConnectionState] = []
        var frames: [[UInt8]] = []
        client.onStateChange = { states.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(to: endpoint)
        endpointConnection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(endpointFactoryEndpoint == endpoint)
        #expect(states.last == .connected)
        #expect(endpointConnection.receiveCallCount == 1)

        let receive = try #require(endpointConnection.lastReceiveCompletion)
        receive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x01, ESP32TCPClient.frameDelimiter]])

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        receive(Data([0x02, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x01, ESP32TCPClient.frameDelimiter]])
        #expect(endpointConnection.cancelCallCount == 1)
        #expect(manualConnection.receiveCallCount == 0)

        manualConnection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(manualConnection.receiveCallCount == 1)
    }

    @MainActor
    @Test func initialInternalDisconnectDoesNotErasePendingDiscoveredEndpoint() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)
    }

    @MainActor
    @Test func successfulDiscoveredConnectionMarksCorrectRowConnected() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceB)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription != deviceA.stableEndpointDescription)
        #expect(viewModel.connectedEndpointDescription == deviceB.stableEndpointDescription)
    }

    @MainActor
    @Test func explicitDisconnectClearsConnectedAndPendingEndpointState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)

        viewModel.disconnect()
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func connectionFailureClearsPendingDiscoveredEndpointState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func switchingDiscoveredDevicesUpdatesConnectedIndicatorAfterReady() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceA)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == deviceA.stableEndpointDescription)

        viewModel.connect(to: deviceB)
        #expect(viewModel.connectedEndpointDescription == nil)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == deviceB.stableEndpointDescription)
    }

    @MainActor
    @Test func manualIPConnectionDoesNotMarkDiscoveredRowConnected() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)

        viewModel.connect()
        #expect(viewModel.connectedEndpointDescription == nil)
        await drainMainQueue()

        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func staleFailedStateDoesNotOverwriteActiveConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleStateHandler(.failed(.posix(.ECONNRESET)))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .connecting)
        #expect(!states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleCancelledStateDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleStateHandler(.cancelled)
        await Task.yield()

        #expect(states.last == .connecting)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleReceiveDoesNotEmitFramesOrContinueReceiveLoop() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let staleReceive = try #require(connections[0].lastReceiveCompletion)
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)

        staleReceive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[0].receiveCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()
        let firstActiveReceive = try #require(connections[1].lastReceiveCompletion)
        firstActiveReceive(Data([0x02]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[1].receiveCallCount == 2)

        let secondActiveReceive = try #require(connections[1].lastReceiveCompletion)
        secondActiveReceive(Data([0x03, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x02, 0x03, ESP32TCPClient.frameDelimiter]])
        #expect(connections[1].receiveCallCount == 3)
    }

    @MainActor
    @Test func staleSendCompletionIsIgnored() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var sendResults: [Error?] = []

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        client.send(Data([0x01])) { sendResults.append($0) }
        let staleSendCompletion = try #require(connections[0].lastSendCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleSendCompletion(.posix(.ECONNRESET))
        await Task.yield()

        #expect(sendResults.isEmpty)

        client.send(Data([0x02])) { sendResults.append($0) }
        let activeSendCompletion = try #require(connections[1].lastSendCompletion)
        activeSendCompletion(nil)
        await Task.yield()

        #expect(sendResults.count == 1)
        #expect(sendResults[0] == nil)
    }

    @MainActor
    @Test func activeReceiveErrorClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        var frames: [[UInt8]] = []
        client.onStateChange = { states.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(Data([0xAA]), nil, false, .posix(.ECONNRESET))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(frames.isEmpty)
        #expect(states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        let nextReceive = try #require(connections[1].lastReceiveCompletion)
        nextReceive(Data([ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[ESP32TCPClient.frameDelimiter]])
    }

    @MainActor
    @Test func activeReceiveCompletionClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .disconnected)

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func staleReceiveTerminationDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleReceive(nil, nil, true, nil)
        await Task.yield()

        #expect(states.last == .connecting)
        #expect(connections[0].cancelCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func sendAfterReceiveTerminationReportsNotConnected() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }
}

private func makeBrowseResult(
    serviceName: String,
    id: String,
    model: String = "clock",
    protocolVersion: String = "1",
    firmware: String
) -> ESP32BrowseResult {
    ESP32BrowseResult(
        endpoint: .service(
            name: serviceName,
            type: ESP32DiscoveryService.serviceType,
            domain: "local",
            interface: nil
        ),
        metadata: .bonjour(NWTXTRecord([
            "id": id,
            "model": model,
            "protocol": protocolVersion,
            "firmware": firmware
        ]))
    )
}

private func makeDevice(id: String, serviceName: String, boardID: String?) -> DiscoveredESP32 {
    DiscoveredESP32(
        id: id,
        serviceName: serviceName,
        endpoint: .service(
            name: serviceName,
            type: ESP32DiscoveryService.serviceType,
            domain: "local",
            interface: nil
        ),
        boardID: boardID,
        model: nil,
        protocolVersion: nil,
        firmwareVersion: nil
    )
}

@MainActor
private func makeViewModelForConnectionIndicatorTests(
    recorder: FakeTCPConnectionRecorder
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in
            recorder.makeConnection()
        },
        endpointConnectionFactory: { _ in
            recorder.makeConnection()
        }
    )
    let browser = FakeESP32Browser()
    let discoveryService = ESP32DiscoveryService {
        browser
    }

    return ESP32ControllerViewModel(client: client, discoveryService: discoveryService)
}

@MainActor
private func makeDiscoveryService(
    browser: FakeESP32Browser,
    probes: FakeProbeConnectionRecorder,
    timeouts: FakeTimeoutScheduler,
    settles: FakeTimeoutScheduler? = nil
) -> ESP32DiscoveryService {
    ESP32DiscoveryService(
        browserFactory: {
            browser
        },
        probeConnectionFactory: probes.makeConnection(endpoint:),
        timeoutScheduler: timeouts.schedule(_:),
        initialResultSettleScheduler: (settles ?? FakeTimeoutScheduler()).schedule(_:)
    )
}

@MainActor
private func makeDiscoveryService(
    browsers: FakeBrowserRecorder,
    probes: FakeProbeConnectionRecorder,
    timeouts: FakeTimeoutScheduler,
    settles: FakeTimeoutScheduler? = nil
) -> ESP32DiscoveryService {
    ESP32DiscoveryService(
        browserFactory: browsers.makeBrowser,
        probeConnectionFactory: probes.makeConnection(endpoint:),
        timeoutScheduler: timeouts.schedule(_:),
        initialResultSettleScheduler: (settles ?? FakeTimeoutScheduler()).schedule(_:)
    )
}

private final class FakeTCPConnectionRecorder {
    var connections: [FakeTCPConnection] = []

    func makeConnection() -> FakeTCPConnection {
        let connection = FakeTCPConnection()
        connections.append(connection)
        return connection
    }
}

private final class FakeBrowserRecorder {
    var browsers: [FakeESP32Browser] = []

    func makeBrowser() -> FakeESP32Browser {
        let browser = FakeESP32Browser()
        browsers.append(browser)
        return browser
    }
}

private final class FakeProbeConnectionRecorder {
    var connections: [FakeProbeConnection] = []

    func makeConnection(endpoint: NWEndpoint) -> FakeProbeConnection {
        let connection = FakeProbeConnection(endpoint: endpoint)
        connections.append(connection)
        return connection
    }
}

private final class FakeProbeConnection: ESP32ProbeConnection {
    let endpoint: NWEndpoint
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var startCallCount = 0
    var cancelCallCount = 0

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start(queue: DispatchQueue) {
        startCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeTimeoutScheduler {
    var tasks: [FakeCancellableTask] = []

    func schedule(_ timeout: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = FakeCancellableTask(timeout: timeout)
        tasks.append(task)
        return task
    }
}

private final class FakeCancellableTask: CancellableTask {
    private let timeout: @Sendable () -> Void
    var cancelCallCount = 0
    var isCancelled = false

    init(timeout: @escaping @Sendable () -> Void) {
        self.timeout = timeout
    }

    func cancel() {
        cancelCallCount += 1
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else {
            return
        }

        timeout()
    }
}

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private final class FakeESP32Browser: ESP32Browsing {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
    var startCallCount = 0
    var cancelCallCount = 0

    func start(queue: DispatchQueue) {
        startCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeTCPConnection: TCPConnection {
    typealias ReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var cancelCallCount = 0
    var receiveCallCount = 0
    var sendCallCount = 0
    var lastReceiveCompletion: ReceiveCompletion?
    var lastSendCompletion: ((NWError?) -> Void)?

    func start(queue: DispatchQueue) {}

    func cancel() {
        cancelCallCount += 1
    }

    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    ) {
        sendCallCount += 1

        guard case let .contentProcessed(sendCompletion) = completion else {
            return
        }

        lastSendCompletion = sendCompletion
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping ReceiveCompletion
    ) {
        receiveCallCount += 1
        lastReceiveCompletion = completion
    }
}
