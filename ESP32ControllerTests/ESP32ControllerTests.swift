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

    @Test func clockProtocolEncodesConnectionTestForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.connectionTest, boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C])
    }

    @Test func clockProtocolEncodesReadConfigurationForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.readConfiguration, boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x52, 0x43, 0x5C])
    }

    @Test func clockProtocolEncodesSetConfiguration12HourLevelOne() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: false, brightnessLevel: 1),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x00, 0x19, 0x5C])
    }

    @Test func clockProtocolEncodesSetConfiguration24HourLevelTen() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: true, brightnessLevel: 10),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x01, 0xFF, 0x5C])
    }

    @Test func clockProtocolBrightnessLevelFiveConvertsTo127() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: true, brightnessLevel: 5),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x01, 0x7F, 0x5C])
    }

    @Test func clockProtocolRejectsBrightnessZero() {
        do {
            _ = try ClockProtocolEncoder.encode(.setConfiguration(format24Hour: true, brightnessLevel: 0), boardID: 0)
            Issue.record("Brightness 0 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidBrightnessLevel)
        }
    }

    @Test func clockProtocolRejectsBrightnessEleven() {
        do {
            _ = try ClockProtocolEncoder.encode(.setConfiguration(format24Hour: true, brightnessLevel: 11), boardID: 0)
            Issue.record("Brightness 11 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidBrightnessLevel)
        }
    }

    @Test func clockProtocolRejectsReservedBoardIDForEveryCommand() {
        let commands: [ClockProtocolCommand] = [
            .connectionTest,
            .readConfiguration,
            .setConfiguration(format24Hour: true, brightnessLevel: 5),
            .reset(resetID: 0)
        ]

        for command in commands {
            do {
                _ = try ClockProtocolEncoder.encode(command, boardID: 0x5C)
                Issue.record("Board ID 92 should be rejected for \(command)")
            } catch {
                #expect(error as? ClockProtocolEncodingError == .reservedBoardID)
            }
        }
    }

    @Test func clockProtocolEncodesResetFrame() throws {
        let frame = try ClockProtocolEncoder.encode(.reset(resetID: 0x03), boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x52, 0x54, 0x03, 0x5C])
    }

    @Test func clockProtocolRejectsResetIDDelimiterConflict() {
        do {
            _ = try ClockProtocolEncoder.encode(.reset(resetID: 0x5C), boardID: 0)
            Issue.record("Reset ID 0x5C should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .delimiterConflict)
        }
    }

    @MainActor
    @Test func guiClockCommandMethodsDoNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.sendConnectionTest()
        viewModel.applyClockConfiguration()
        viewModel.requestClockConfiguration()
        viewModel.requestDeviceReset(resetID: 0)

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.state == .disconnected)
    }

    @MainActor
    @Test func guiClockCommandMethodsDoNotSendWithoutValidBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.manualBoardID = " "
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.sendConnectionTest()
        viewModel.applyClockConfiguration()
        viewModel.requestClockConfiguration()
        viewModel.requestDeviceReset(resetID: 0)

        #expect(viewModel.state == .connected)
        #expect(recorder.connections[0].sendCallCount == 0)
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

        client.connect(to: endpoint, boardID: nil)
        endpointConnection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(endpointFactoryEndpoint == endpoint)
        #expect(states.last == .connected)
        #expect(endpointConnection.receiveCallCount == 1)

        let receive = try #require(endpointConnection.lastReceiveCompletion)
        receive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x01, ESP32TCPClient.frameDelimiter]])

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let staleReceive = try #require(connections[0].lastReceiveCompletion)
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)

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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        client.send(Data([0x01])) { sendResults.append($0) }
        let staleSendCompletion = try #require(connections[0].lastSendCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
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

    @MainActor
    @Test func heartbeatStartsOnlyAfterReadyAndSendsFirstHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x7A)

        #expect(scheduler.tasks.isEmpty)
        #expect(connection.sendCallCount == 0)

        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.map(\.delay) == [1])
        scheduler.tasks[0].fire()
        await Task.yield()

        let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x7A, sequence: 0))
        #expect(connection.sentContents.map { $0.map(Array.init) } == [expectedFrame])
        #expect(ackTimeouts.tasks.map(\.delay) == [4])
    }

    @MainActor
    @Test func boardIDParserAcceptsOnlyDecimalUInt8Values() {
        #expect(ESP32ControllerViewModel.boardIDByte(from: "0") == 0x00)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "7") == 0x07)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "10") == 0x0A)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "91") == 0x5B)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "93") == 0x5D)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "255") == 0xFF)
        #expect(ESP32ControllerViewModel.boardIDByte(from: " 7 ") == 0x07)
    }

    @MainActor
    @Test func boardIDParserRejectsHexLookingAndOutOfRangeValues() {
        #expect(ESP32ControllerViewModel.boardIDByte(from: "A") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "0A") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "FF") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "-1") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "92") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "256") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "   ") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: nil) == nil)
    }

    @MainActor
    @Test func manualConnectionWithBlankBoardIDDisablesHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "   "
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
    }

    @MainActor
    @Test func waitingForHeartbeatACKDisplaysConnectedStatus() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "7"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.connectionHealth == .waitingForACK)
        #expect(viewModel.connectionStatusText == "Connected")
        #expect(viewModel.connectionHealthAccessibilityValue == "Heartbeat awaiting acknowledgement")
    }

    @MainActor
    @Test func manualBoardIDDecimalValuesUseExpectedHeartbeatByte() async throws {
        let cases: [(String, UInt8)] = [
            ("0", 0x00),
            ("7", 0x07),
            ("10", 0x0A),
            ("255", 0xFF)
        ]

        for (boardIDText, expectedByte) in cases {
            let scheduler = FakeHeartbeatScheduler()
            let ackTimeouts = FakeHeartbeatScheduler()
            let recorder = FakeTCPConnectionRecorder()
            let viewModel = makeViewModelForManualHeartbeatTests(
                recorder: recorder,
                heartbeatScheduler: scheduler,
                ackTimeouts: ackTimeouts
            )

            viewModel.manualBoardID = boardIDText
            viewModel.connect()
            await drainMainQueue()
            recorder.connections[0].stateUpdateHandler?(.ready)
            await Task.yield()
            scheduler.tasks[0].fire()
            await Task.yield()

            let frame = try #require(recorder.connections[0].sentContents.first??.map { $0 })
            #expect(frame[3] == expectedByte)
            let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: expectedByte, sequence: 0))
            #expect(frame == expectedFrame)
        }
    }

    @MainActor
    @Test func invalidNonemptyManualBoardIDPreventsConnection() {
        for invalidBoardID in ["-1", "256", "0A", "A"] {
            let scheduler = FakeHeartbeatScheduler()
            let ackTimeouts = FakeHeartbeatScheduler()
            let recorder = FakeTCPConnectionRecorder()
            let viewModel = makeViewModelForManualHeartbeatTests(
                recorder: recorder,
                heartbeatScheduler: scheduler,
                ackTimeouts: ackTimeouts
            )

            viewModel.manualBoardID = invalidBoardID
            viewModel.connect()

            #expect(recorder.connections.isEmpty)
            #expect(scheduler.tasks.isEmpty)
            #expect(viewModel.state == .failed("Board ID must be a decimal value from 0 through 255"))
        }
    }

    @MainActor
    @Test func manualBoardIDNinetyTwoPreventsConnectionWithReservedMessage() {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "92"
        viewModel.connect()

        #expect(recorder.connections.isEmpty)
        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.state == .failed(ESP32ControllerViewModel.reservedBoardIDMessage))
    }

    @MainActor
    @Test func discoveredDecimalBoardIDIsUsedAsHeartbeatFrameByteThree() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
        )
        let device = makeDevice(id: "service-decimal", serviceName: "ESP32 Decimal", boardID: "10")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await Task.yield()

        let frame = try #require(recorder.connections[0].sentContents.first??.map { $0 })
        #expect(frame[3] == 0x0A)
        let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x0A, sequence: 0))
        #expect(frame == expectedFrame)
    }

    @MainActor
    @Test func invalidDiscoveredBoardIDDoesNotInventHeartbeatBoardByte() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
        )
        let device = makeDevice(id: "service-invalid", serviceName: "ESP32 Invalid", boardID: "0A")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func discoveredReservedBoardIDConnectsWithoutHeartbeatAndLogsDiagnostic() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
        )
        let device = makeDevice(id: "service-reserved", serviceName: "ESP32 Reserved", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
        let loggedReservedBoardIDDiagnostic = viewModel.logEntries.contains {
            $0.message == "Heartbeat unavailable: \(ESP32ControllerViewModel.reservedBoardIDMessage)"
        }
        #expect(loggedReservedBoardIDDiagnostic)
    }

    @MainActor
    @Test func discoveredMissingBoardIDConnectsWithoutHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
        )
        let device = makeDevice(id: "service-missing", serviceName: "ESP32 Missing", boardID: nil)

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
    }

    @MainActor
    @Test func heartbeatDisabledConnectionForwardsACKShapedFrame() async throws {
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0x2A)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ackShapedFrame])
    }

    @MainActor
    @Test func heartbeatDisabledConnectionForwardsValidNineByteACKShape() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x68, 0x62, 0x41, 0x46, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(frames == [ackShapedFrame])
    }

    @MainActor
    @Test func heartbeatFrameEncodingUsesUppercaseHex() throws {
        let expectedRequestFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x41, sequence: 0xAF))
        #expect(expectedRequestFrame == [
            0x2F, 0x54, 0x41, 0x41, 0x48, 0x42, 0x41, 0x46, 0x5C
        ])
        #expect(ESP32TCPClient.heartbeatACKFrame(boardID: 0x41, sequence: 0xAF) == [
            0x2F, 0x74, 0x61, 0x41, 0x68, 0x62, 0x41, 0x46, 0x5C
        ])
        #expect(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x5C, sequence: 0xAF) == nil)
    }

    @MainActor
    @Test func heartbeatSequenceRollsOverFromFFTo00() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x22)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        for sequence in 0...256 {
            try fireLatestActiveHeartbeatTask(scheduler)
            await Task.yield()
            let expectedSequence = UInt8(truncatingIfNeeded: sequence)
            let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: expectedSequence))
            #expect(connection.sentContents.last??.map { $0 } == expectedFrame)

            let receive = try #require(connection.lastReceiveCompletion)
            receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x22, sequence: expectedSequence)), nil, false, nil)
            await Task.yield()
        }

        let expectedFFFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: 0xFF))
        let expected00Frame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: 0x00))
        #expect(connection.sentContents[255].map(Array.init) == expectedFFFrame)
        #expect(connection.sentContents[256].map(Array.init) == expected00Frame)
    }

    @MainActor
    @Test func matchingACKResetsMissedCountAndIsNotForwarded() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x01)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x01, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(health.suffix(2) == [.waitingForACK, .healthy])
    }

    @MainActor
    @Test func wrongSequenceOrBoardACKDoesNotResetMissedCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        let wrongSequenceFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x02, sequence: 1)
        let wrongBoardFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x03, sequence: 0)
        receive(Data(wrongSequenceFrame), nil, false, nil)
        receive(Data(wrongBoardFrame), nil, false, nil)
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(frames == [wrongSequenceFrame, wrongBoardFrame])
        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func matchingACKForDecimalBoardIDSevenResetsMissedCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(ackTimeouts.tasks[0].isCancelled)
    }

    @MainActor
    @Test func wrongBoardByteForDecimalBoardIDSevenIsRejected() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        let wrongBoardFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x37, sequence: 0)
        receive(Data(wrongBoardFrame), nil, false, nil)
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(frames == [wrongBoardFrame])
        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func ackShapedFrameWithNoPendingHeartbeatIsForwarded() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        var health: [ConnectionHealthState] = []
        client.onFrameReceived = { frames.append($0) }
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ackShapedFrame])
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(health.last == .healthy)
    }

    @MainActor
    @Test func malformedACKIsForwardedAsNormalFrame() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let malformed: [UInt8] = [0x2F, 0x74, 0x61, 0x02, 0x68, 0x62, 0x47, 0x47, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(malformed), nil, false, nil)
        await Task.yield()

        #expect(frames == [malformed])
    }

    @MainActor
    @Test func ordinaryNonHeartbeatFrameIsForwarded() async throws {
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ordinaryFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x02, 0x4F, 0x4B, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ordinaryFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ordinaryFrame])
    }

    @MainActor
    @Test func timeoutIncrementsMissCountAndThreeTimeoutsDisconnect() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var states: [TCPConnectionState] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        for missed in 1...3 {
            try fireLatestActiveHeartbeatTask(scheduler)
            await Task.yield()
            try fireLatestActiveHeartbeatTask(ackTimeouts)
            await Task.yield()

            if missed < 3 {
                #expect(health.last == .degraded(missedCount: missed))
                #expect(connection.cancelCallCount == 0)
            }
        }

        #expect(health.contains(.timedOut))
        #expect(states.last == .failed("Heartbeat timed out"))
        #expect(connection.cancelCallCount == 1)
    }

    @MainActor
    @Test func successfulACKAfterOneMissResetsCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x05)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        try fireLatestActiveHeartbeatTask(ackTimeouts)
        await Task.yield()

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x05, sequence: 1)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        try fireLatestActiveHeartbeatTask(ackTimeouts)
        await Task.yield()

        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func onlyOneHeartbeatMayBeOutstanding() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatConfiguration: HeartbeatConfiguration(interval: 12, ackTimeout: 30, maximumConsecutiveMisses: 3),
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(connection.sendCallCount == 1)

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()

        #expect(connection.sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)
    }

    @MainActor
    @Test func connectionWithoutHeartbeatSendsNoHeartbeatFrames() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func lowLevelHostConnectWithReservedBoardIDDoesNotEnableHeartbeatOrSendMalformedFrame() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x5C)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func lowLevelEndpointConnectWithReservedBoardIDDoesNotEnableHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            endpointConnectionFactory: { _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(
            to: .service(name: "ESP32 Reserved", type: ESP32DiscoveryService.serviceType, domain: "local", interface: nil),
            boardID: 0x5C
        )
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func previousHeartbeatEnabledConnectionDoesNotLeakIntoDisabledConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(connections[0].sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(health.last == .idle)
        #expect(connections[1].sendCallCount == 0)
        let replacementHeartbeatTasksCancelled = scheduler.tasks.dropFirst().allSatisfy { $0.isCancelled }
        #expect(replacementHeartbeatTasksCancelled)

        let staleACKShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)
        let receive = try #require(connections[1].lastReceiveCompletion)
        receive(Data(staleACKShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [staleACKShapedFrame])
        #expect(health.last == .idle)
    }

    @MainActor
    @Test func previousDiscoveredHeartbeatBoardIDDoesNotLeakIntoReservedDiscoveredConnection() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
        )
        let validDevice = makeDevice(id: "service-valid", serviceName: "ESP32 Valid", boardID: "7")
        let reservedDevice = makeDevice(id: "service-reserved", serviceName: "ESP32 Reserved", boardID: "92")

        viewModel.connect(to: validDevice)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(recorder.connections[0].sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)

        viewModel.connect(to: reservedDevice)
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(recorder.connections[1].sendCallCount == 0)
        let replacementHeartbeatTasksCancelled = scheduler.tasks.dropFirst().allSatisfy { $0.isCancelled }
        #expect(replacementHeartbeatTasksCancelled)
        #expect(viewModel.connectionStatusText == "Connected")
        let loggedReservedBoardIDDiagnostic = viewModel.logEntries.contains {
            $0.message == "Heartbeat unavailable: \(ESP32ControllerViewModel.reservedBoardIDMessage)"
        }
        #expect(loggedReservedBoardIDDiagnostic)
    }

    @MainActor
    @Test func staleHeartbeatTimeoutCannotCancelNewerConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        let staleTimeout = ackTimeouts.tasks[0]

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        staleTimeout.fireIgnoringCancellationForTesting()
        await Task.yield()

        #expect(connections[1].cancelCallCount == 0)
        #expect(connections[0].cancelCallCount == 1)
    }

    @MainActor
    @Test func staleACKCannotAffectNewerConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x09)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x09)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        staleReceive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x09, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(connections[1].cancelCallCount == 0)
    }

    @MainActor
    @Test func disconnectCancelsHeartbeatLoopAndACKTimeout() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        client.disconnect()

        #expect(scheduler.tasks.contains { $0.isCancelled })
        #expect(ackTimeouts.tasks[0].isCancelled)
    }

    @MainActor
    @Test func remoteDisconnectCancelsHeartbeatResources() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(connection.cancelCallCount == 1)
    }

    @MainActor
    @Test func replacementConnectionReceivesIndependentHeartbeatState() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x0A)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(health.last == .degraded(missedCount: 1))

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x0A)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(health.last == .healthy)
        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()

        let receive = try #require(connections[1].lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x0A, sequence: 1)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(connections[1].cancelCallCount == 0)
    }
}

private func fireLatestActiveHeartbeatTask(_ scheduler: FakeHeartbeatScheduler) throws {
    let task = try #require(scheduler.tasks.last { !$0.isCancelled })
    task.fire()
}

@MainActor
private func makeViewModelForManualHeartbeatTests(
    recorder: FakeTCPConnectionRecorder,
    heartbeatScheduler: FakeHeartbeatScheduler,
    ackTimeouts: FakeHeartbeatScheduler
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() },
        heartbeatScheduler: heartbeatScheduler.schedule(_:_:),
        heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
    )

    return ESP32ControllerViewModel(
        client: client,
        discoveryService: ESP32DiscoveryService { FakeESP32Browser() }
    )
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

private final class FakeHeartbeatScheduler {
    var tasks: [FakeScheduledHeartbeatTask] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = FakeScheduledHeartbeatTask(delay: delay, callback: callback)
        tasks.append(task)
        return task
    }
}

private final class FakeScheduledHeartbeatTask: CancellableTask {
    let delay: TimeInterval
    private let callback: @Sendable () -> Void
    var cancelCallCount = 0
    var isCancelled = false

    init(delay: TimeInterval, callback: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.callback = callback
    }

    func cancel() {
        cancelCallCount += 1
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else {
            return
        }

        callback()
    }

    func fireIgnoringCancellationForTesting() {
        callback()
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
    var sentContents: [Data?] = []

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
        sentContents.append(content)

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
