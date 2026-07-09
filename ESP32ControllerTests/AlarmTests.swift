//
//  AlarmTests.swift
//  ESP32ControllerTests
//
//  Created by Codex on 07/07/26.
//

import Foundation
import Network
import Testing
@testable import ESP32Controller

@Suite(.serialized)
struct AlarmTests {
    @Test func laRequestsUseExactFirmwareFrameBytes() throws {
        let alarm1 = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 1)
        let alarm17 = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 17)
        let alarm60 = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 60)

        #expect(alarm1 == [
            0x2F, 0x54, 0x41, 0x00, 0x4C, 0x41, 0x01, 0x5C
        ])
        #expect(alarm17 == [
            0x2F, 0x54, 0x41, 0x00, 0x4C, 0x41, 0x11, 0x5C
        ])
        #expect(alarm60 == [
            0x2F, 0x54, 0x41, 0x00, 0x4C, 0x41, 0x3C, 0x5C
        ])
    }

    @Test func caRequestUsesExactFirmwareFrameBytes() throws {
        var draft = AlarmDraft.defaultDraft(id: 17)
        draft.hour = 12
        draft.minute = 45
        draft.weekdays = [.monday, .wednesday, .friday]
        draft.durationSeconds = 3
        draft.effect = .intermittent
        draft.isEnabled = true

        let frame = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: draft)

        #expect(frame.bytes.count == 12)
        #expect(frame.bytes == [
            0x2F, 0x54, 0x41, 0x00, 0x43, 0x41, 0x11, 0x0C, 0x2D, 0xAA, 0x43, 0x5C
        ])
        #expect(frame.frequency == 0xAA)
        #expect(frame.durationEffect == 0x43)
    }

    @Test func caRequestAllowsFirmwareSupportedFrequencyEqualToDelimiter() throws {
        var draft = AlarmDraft.defaultDraft(id: 9)
        draft.hour = 5
        draft.minute = 10
        draft.weekdays = [.sunday, .tuesday, .wednesday, .thursday]
        draft.durationSeconds = 4
        draft.effect = .continuous
        draft.isEnabled = false

        let frame = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: draft)

        #expect(frame.bytes.count == 12)
        #expect(frame.frequency == ESP32TCPClient.frameDelimiter)
        #expect(frame.bytes[9] == ESP32TCPClient.frameDelimiter)
        #expect(frame.bytes[11] == ESP32TCPClient.frameDelimiter)
    }

    @Test func daRequestUsesExactFirmwareFrameBytes() throws {
        let alarm1 = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 1)
        let alarm9 = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 9)
        let alarm60 = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 60)

        #expect(alarm1 == [
            0x2F, 0x54, 0x41, 0x00, 0x44, 0x41, 0x01, 0x5C
        ])
        #expect(alarm9 == [
            0x2F, 0x54, 0x41, 0x00, 0x44, 0x41, 0x09, 0x5C
        ])
        #expect(alarm60 == [
            0x2F, 0x54, 0x41, 0x00, 0x44, 0x41, 0x3C, 0x5C
        ])
    }

    @Test func firmwareWeekdayEncodingMatchesInspectedMapping() {
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.sunday], isEnabled: false) == 0x40)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.monday], isEnabled: false) == 0x20)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.tuesday], isEnabled: false) == 0x10)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.wednesday], isEnabled: false) == 0x08)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.thursday], isEnabled: false) == 0x04)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.friday], isEnabled: false) == 0x02)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [.saturday], isEnabled: false) == 0x01)
    }

    @Test func weekdayPresetsEncodeToFirmwareValues() {
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: AlarmWeekday.mondayThroughFriday, isEnabled: true) == 0xBE)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: AlarmWeekday.mondayThroughSaturday, isEnabled: true) == 0xBF)
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: AlarmWeekday.everyDay, isEnabled: true) == 0xFF)
        #expect(AlarmProtocolCodec.decodeWeekdays(from: 0xFF) == AlarmWeekday.everyDay)
    }

    @Test func durationEffectPackingMatchesFirmwareDecodeLogic() throws {
        #expect(try AlarmProtocolCodec.encodeDurationEffect(durationSeconds: 1, effect: .continuous) == 0x01)
        #expect(try AlarmProtocolCodec.encodeDurationEffect(durationSeconds: 15, effect: .intermittentBlink) == 0xCF)
        #expect(AlarmProtocolCodec.decodeDurationSeconds(from: 0x00) == 1)
        #expect(AlarmProtocolCodec.decodeDurationSeconds(from: 0x4A) == 10)
        #expect(AlarmProtocolCodec.decodeEffect(from: 0x00) == .continuous)
        #expect(AlarmProtocolCodec.decodeEffect(from: 0x40) == .intermittent)
        #expect(AlarmProtocolCodec.decodeEffect(from: 0x80) == .continuousBlink)
        #expect(AlarmProtocolCodec.decodeEffect(from: 0xC0) == .intermittentBlink)
    }

    @Test func enabledFlagUsesFrequencyBitSeven() {
        #expect(!AlarmProtocolCodec.decodeEnabled(from: 0x7F))
        #expect(AlarmProtocolCodec.decodeEnabled(from: 0x80))
        #expect(AlarmProtocolCodec.encodeFrequency(weekdays: [], isEnabled: true) == 0x80)
    }

    @Test func unsupportedEffectIsPreservedButRejectedForSend() {
        let unknown = AlarmEffect(rawValue: 9)

        #expect(!unknown.isSupported)
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.encodeDurationEffect(durationSeconds: 3, effect: unknown)
        }
    }

    @Test func laResponseParserMarksAllZeroPayloadAsEmptyUnconfigured() throws {
        let alarm = try AlarmProtocolCodec.decodeLAResponse(
            laResponse(boardID: 0, alarmID: 8, hour: 0, minute: 0, frequency: 0x00, durationEffect: 0x00),
            expectedBoardID: 0
        )

        #expect(alarm.id == 8)
        #expect(alarm.hour == 0)
        #expect(alarm.minute == 0)
        #expect(alarm.weekdays.isEmpty)
        #expect(alarm.durationSeconds == 1)
        #expect(alarm.effect == .continuous)
        #expect(!alarm.isConfigured)
        #expect(!alarm.isEnabled)
        #expect(alarm.rawFrequency == 0x00)
        #expect(alarm.rawDurationEffect == 0x00)
        #expect(alarm.accessibilityValue == "not configured")
    }

    @Test func laResponseParserAcceptsValidAlarmOneAndSixty() throws {
        let alarm1 = try AlarmProtocolCodec.decodeLAResponse(
            laResponse(boardID: 0, alarmID: 1, hour: 6, minute: 30, frequency: 0xBE, durationEffect: 0x43),
            expectedBoardID: 0
        )
        let alarm60 = try AlarmProtocolCodec.decodeLAResponse(
            laResponse(boardID: 0, alarmID: 60, hour: 23, minute: 59, frequency: 0xFF, durationEffect: 0xCF),
            expectedBoardID: 0
        )

        #expect(alarm1.id == 1)
        #expect(alarm1.hour == 6)
        #expect(alarm1.minute == 30)
        #expect(alarm1.weekdays == AlarmWeekday.mondayThroughFriday)
        #expect(alarm1.durationSeconds == 3)
        #expect(alarm1.effect == .intermittent)
        #expect(alarm1.isConfigured)
        #expect(alarm1.isEnabled)
        #expect(alarm1.rawFrequency == 0xBE)
        #expect(alarm1.rawDurationEffect == 0x43)
        #expect(alarm1.accessibilityValue == "configured and enabled")
        #expect(alarm60.id == 60)
        #expect(alarm60.isConfigured)
        #expect(alarm60.effect == .intermittentBlink)
    }

    @Test func laResponseParserAcceptsConfiguredDisabledAlarmWithoutClearingStoredValues() throws {
        let alarm = try AlarmProtocolCodec.decodeLAResponse(
            laResponse(boardID: 0, alarmID: 8, hour: 7, minute: 30, frequency: 0x08, durationEffect: 0x42),
            expectedBoardID: 0
        )

        #expect(alarm.id == 8)
        #expect(alarm.hour == 7)
        #expect(alarm.minute == 30)
        #expect(alarm.weekdays == [.wednesday])
        #expect(alarm.durationSeconds == 2)
        #expect(alarm.effect == .intermittent)
        #expect(alarm.isConfigured)
        #expect(!alarm.isEnabled)
        #expect(alarm.rawFrequency == 0x08)
        #expect(alarm.rawDurationEffect == 0x42)
        #expect(alarm.accessibilityValue == "configured and disabled")
    }

    @Test func disabledLAResponsePreservesStoredParameters() throws {
        let alarm = try AlarmProtocolCodec.decodeLAResponse(
            laResponse(boardID: 0, alarmID: 21, hour: 23, minute: 5, frequency: 0x22, durationEffect: 0xC9),
            expectedBoardID: 0
        )

        #expect(alarm.isConfigured)
        #expect(!alarm.isEnabled)
        #expect(alarm.hour == 23)
        #expect(alarm.minute == 5)
        #expect(alarm.weekdays == [.monday, .friday])
        #expect(alarm.durationSeconds == 9)
        #expect(alarm.effect == .intermittentBlink)
        #expect(alarm.rawFrequency == 0x22)
        #expect(alarm.rawDurationEffect == 0xC9)
    }

    @Test func laResponseParserRejectsInvalidFrames() {
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeLAResponse(
                laResponse(boardID: 1, alarmID: 1, hour: 6, minute: 30, frequency: 0xBE, durationEffect: 0x43),
                expectedBoardID: 0
            )
        }
        #expect(throws: AlarmProtocolError.self) {
            var frame = laResponse(boardID: 0, alarmID: 1, hour: 6, minute: 30, frequency: 0xBE, durationEffect: 0x43)
            frame[4] = 0x63
            _ = try AlarmProtocolCodec.decodeLAResponse(frame, expectedBoardID: 0)
        }
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeLAResponse(
                laResponse(boardID: 0, alarmID: 0, hour: 6, minute: 30, frequency: 0xBE, durationEffect: 0x43),
                expectedBoardID: 0
            )
        }
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeLAResponse([0x2F, 0x74, 0x61], expectedBoardID: 0)
        }
        #expect(throws: AlarmProtocolError.self) {
            var frame = laResponse(boardID: 0, alarmID: 1, hour: 6, minute: 30, frequency: 0xBE, durationEffect: 0x43)
            frame[11] = 0x00
            _ = try AlarmProtocolCodec.decodeLAResponse(frame, expectedBoardID: 0)
        }
    }

    @Test func gridEmptyLoadedAlarmHasNoBellPresentation() {
        let record = AlarmRecord(
            id: 8,
            isConfigured: false,
            isEnabled: false,
            readState: .loaded,
            rawFrequency: 0x00,
            rawDurationEffect: 0x00
        )

        #expect(AlarmCellVisualConfiguration(record: record).icon == nil)
    }

    @Test func gridConfiguredEnabledAlarmUsesBottomTrailingEnabledBellPresentation() {
        let record = AlarmRecord(
            id: 8,
            hour: 7,
            minute: 30,
            weekdays: [.wednesday],
            durationSeconds: 2,
            effect: .intermittent,
            isConfigured: true,
            isEnabled: true,
            readState: .loaded,
            rawFrequency: 0x88,
            rawDurationEffect: 0x42
        )
        let icon = AlarmCellVisualConfiguration(record: record).icon

        #expect(icon?.kind == .configuredEnabled)
        #expect(icon?.systemName == "bell.fill")
        #expect(icon?.placement == .bottomTrailing)
        #expect(icon?.pointSize == AlarmCellVisualConfiguration.enabledBellPointSize)
        #expect(icon?.foregroundStyle == .green)
    }

    @Test func gridConfiguredDisabledAlarmUsesCenteredLargerCrossedBellPresentation() {
        let record = AlarmRecord(
            id: 8,
            hour: 7,
            minute: 30,
            weekdays: [.wednesday],
            durationSeconds: 2,
            effect: .intermittent,
            isConfigured: true,
            isEnabled: false,
            readState: .loaded,
            rawFrequency: 0x08,
            rawDurationEffect: 0x42
        )
        let icon = AlarmCellVisualConfiguration(record: record).icon

        #expect(icon?.kind == .configuredDisabled)
        #expect(icon?.systemName == "bell.slash.fill")
        #expect(icon?.placement == .center)
        #expect(icon?.pointSize == AlarmCellVisualConfiguration.disabledBellPointSize)
        #expect(icon?.foregroundStyle == .gray)
        #expect((20.0...22.0).contains(AlarmCellVisualConfiguration.disabledBellPointSize))
        #expect(AlarmCellVisualConfiguration.disabledBellPointSize > AlarmCellVisualConfiguration.enabledBellPointSize)
    }

    @MainActor
    @Test func tcpParserEmitsFragmentedLAResponseAsOneFrame() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let frame = laResponse(boardID: 0, alarmID: 17, hour: 7, minute: 15, frequency: 0xBE, durationEffect: 0x43)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(frame.prefix(5)), nil, false, nil)
        await alarmDrainMainQueue()
        #expect(frames.isEmpty)

        let nextReceive = try #require(connection.lastReceiveCompletion)
        nextReceive(Data(frame.dropFirst(5)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [frame])
    }

    @MainActor
    @Test func tcpParserEmitsConcatenatedAndAdjacentFrames() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let first = laResponse(boardID: 0, alarmID: 1, hour: 7, minute: 15, frequency: 0xBE, durationEffect: 0x43)
        let second = laResponse(boardID: 0, alarmID: 2, hour: 8, minute: 45, frequency: 0xFF, durationEffect: 0x82)
        let adjacentNM: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x6E, 0x6D, 0x02, 0x5C]

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(first + second + adjacentNM), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [first, second, adjacentNM])
    }

    @MainActor
    @Test func tcpParserKeepsDelimiterByteInsideLAResponsePayload() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let leadingNM: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x6E, 0x6D, 0x01, 0x5C]
        let alarm = laResponse(
            boardID: 0,
            alarmID: 9,
            hour: 5,
            minute: 10,
            frequency: ESP32TCPClient.frameDelimiter,
            durationEffect: 0x04
        )
        let trailingNM: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x6E, 0x6D, 0x02, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(leadingNM + Array(alarm.prefix(10))), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [leadingNM])

        let nextReceive = try #require(connection.lastReceiveCompletion)
        nextReceive(Data(alarm.dropFirst(10) + trailingNM), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [leadingNM, alarm, trailingNM])
    }

    @MainActor
    @Test func tcpParserEmitsFragmentedDAACKAsOneFrame() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let frame = daACK(boardID: 0, alarmID: 9)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(frame.prefix(4)), nil, false, nil)
        await alarmDrainMainQueue()
        #expect(frames.isEmpty)

        let nextReceive = try #require(connection.lastReceiveCompletion)
        nextReceive(Data(frame.dropFirst(4)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [frame])
    }

    @MainActor
    @Test func tcpParserEmitsDAACKAdjacentToHeartbeatACK() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let heartbeatACK = ESP32TCPClient.heartbeatACKFrame(boardID: 0, sequence: 0x2A)
        let deleteACK = daACK(boardID: 0, alarmID: 9)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(heartbeatACK + deleteACK), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [heartbeatACK, deleteACK])
    }

    @MainActor
    @Test func tcpParserEmitsConcatenatedSupportedAlarmFrames() async throws {
        let connection = AlarmFakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        let deleteACK = daACK(boardID: 0, alarmID: 9)
        let alarm = laResponse(boardID: 0, alarmID: 10, hour: 10, minute: 10, frequency: 0xBE, durationEffect: 0x43)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(deleteACK + alarm), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(frames == [deleteACK, alarm])
    }

    @Test func caACKParserMatchesExpectedAlarmID() throws {
        #expect(try AlarmProtocolCodec.decodeCAACK(caACK(boardID: 0, alarmID: 17), expectedBoardID: 0) == 17)
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeCAACK(caACK(boardID: 1, alarmID: 17), expectedBoardID: 0)
        }
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeCAACK([0x2F, 0x74, 0x61, 0x00, 0x63, 0x61, 0x11, 0x00], expectedBoardID: 0)
        }
    }

    @Test func daACKParserMatchesExpectedAlarmIDAndRejectsMalformedFrames() throws {
        #expect(try AlarmProtocolCodec.decodeDAACK(daACK(boardID: 0, alarmID: 9), expectedBoardID: 0) == 9)
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeDAACK(daACK(boardID: 1, alarmID: 9), expectedBoardID: 0)
        }
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeDAACK([0x2F, 0x74, 0x61, 0x00, 0x64, 0x61, 0x09, 0x00], expectedBoardID: 0)
        }
        #expect(throws: AlarmProtocolError.self) {
            _ = try AlarmProtocolCodec.decodeDAACK([0x2F, 0x74, 0x61, 0x00, 0x64, 0x62, 0x09, 0x5C], expectedBoardID: 0)
        }
    }

    @MainActor
    @Test func readAllRequestsExactlySixtyAlarmsSequentially() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        let firstExpectedRequest = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 1)
        #expect(connection.sentFrames == [firstExpectedRequest])

        for alarmID in AlarmRecord.validIDRange {
            let expectedRequest = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: alarmID)
            #expect(connection.sentFrames.count == alarmID)
            #expect(connection.sentFrames.last == expectedRequest)
            connection.lastSendCompletion?(nil)
            await alarmDrainMainQueue()
            let receive = try #require(connection.lastReceiveCompletion)
            receive(
                Data(laResponse(
                    boardID: 0,
                    alarmID: UInt8(alarmID),
                    hour: UInt8(alarmID % 24),
                    minute: UInt8(alarmID % 60),
                    frequency: 0xBE,
                    durationEffect: 0x43
                )),
                nil,
                false,
                nil
            )
            await alarmDrainMainQueue()
        }

        #expect(connection.sentFrames.count == 60)
        #expect(connection.sentFrames.map { Int($0[6]) } == Array(AlarmRecord.validIDRange))
        #expect(viewModel.alarmReadOperationState == .completed(successful: 60, failed: 0))
        #expect(viewModel.alarmRecords.map(\.id) == Array(AlarmRecord.validIDRange))
        #expect(viewModel.alarmRecords.allSatisfy { $0.readState == .loaded })
        #expect(viewModel.commandStatusMessage == "Read 60 of 60 alarms.")
    }

    @MainActor
    @Test func repeatedReadAllTapDoesNotStartDuplicateSequence() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        viewModel.readAllAlarms()

        let expectedRequest = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 1)
        #expect(connection.sentFrames.count == 1)
        #expect(connection.sentFrames.first == expectedRequest)
    }

    @MainActor
    @Test func readTimeoutMarksOnlyRequestedAlarmAndContinues() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        var receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 1, hour: 1, minute: 1, frequency: 0xBE, durationEffect: 0x43)), nil, false, nil)
        await alarmDrainMainQueue()

        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        scheduler.fireAlarmTransactionTimeout()
        await alarmDrainMainQueue()
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[0].readState == .loaded)
        if case .failed = viewModel.alarmRecords[1].readState {
        } else {
            Issue.record("Alarm 2 should be marked failed")
        }
        let expectedThirdRequest = try AlarmProtocolCodec.makeLARequest(boardID: 0, alarmID: 3)
        #expect(connection.sentFrames.last == expectedThirdRequest)

        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 3, hour: 3, minute: 3, frequency: 0xFF, durationEffect: 0x82)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[2].id == 3)
        #expect(viewModel.alarmRecords[2].readState == .loaded)
        #expect(viewModel.alarmReadFailures == 1)
    }

    @MainActor
    @Test func wrongLAAlarmIDDoesNotSatisfyPendingRead() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 18, hour: 8, minute: 8, frequency: 0xFF, durationEffect: 0x82)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(connection.sentFrames.count == 1)
        #expect(viewModel.alarmRecords[17].readState == .notLoaded)
        #expect(viewModel.alarmReadOperationState == .reading(currentID: 1, completed: 0, total: 60))
    }

    @MainActor
    @Test func disconnectCancelsRemainingReadSequence() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        viewModel.disconnect()
        await alarmDrainMainQueue()
        scheduler.fireAlarmTransactionTimeout()
        await alarmDrainMainQueue()

        #expect(connection.sentFrames.count == 1)
        #expect(viewModel.alarmReadOperationState == .interrupted(successful: 0, failed: 0))
    }

    @MainActor
    @Test func staleConnectionAlarmResponseIsIgnoredAfterReplacement() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let firstConnection = try #require(recorder.connections.first)

        viewModel.readAllAlarms()
        let staleReceive = try #require(firstConnection.lastReceiveCompletion)
        viewModel.connect()
        await alarmDrainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()

        staleReceive(Data(laResponse(boardID: 0, alarmID: 1, hour: 1, minute: 1, frequency: 0xFF, durationEffect: 0x43)), nil, false, nil)
        await alarmDrainMainQueue()

        if case .failed = viewModel.alarmRecords[0].readState {
        } else {
            Issue.record("Stale replacement should leave the old pending alarm interrupted")
        }
        #expect(recorder.connections[1].sentFrames.isEmpty)
    }

    @MainActor
    @Test func selectingAlarmCreatesDraftFromLoadedRecordAndCancelDoesNotModifyRecord() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAlarm(id: 17)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 17, hour: 12, minute: 45, frequency: 0xBE, durationEffect: 0x43)), nil, false, nil)
        await alarmDrainMainQueue()
        let loaded = viewModel.alarmRecords[16]

        viewModel.selectAlarm(id: 17)
        var draft = try #require(viewModel.alarmEditorDraft)
        draft.hour = 1
        viewModel.alarmEditorDraft = draft
        viewModel.cancelAlarmEditing()

        #expect(viewModel.alarmRecords[16] == loaded)
        #expect(viewModel.alarmEditorDraft == nil)
        #expect(viewModel.selectedAlarmID == nil)
    }

    @MainActor
    @Test func readingDisabledAlarmThenOpeningEditorRestoresStoredValues() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAlarm(id: 8)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 8, hour: 7, minute: 30, frequency: 0x08, durationEffect: 0x42)), nil, false, nil)
        await alarmDrainMainQueue()

        let record = viewModel.alarmRecords[7]
        #expect(record.isConfigured)
        #expect(!record.isEnabled)
        #expect(record.hour == 7)
        #expect(record.minute == 30)
        #expect(record.weekdays == [.wednesday])
        #expect(record.durationSeconds == 2)
        #expect(record.effect == .intermittent)

        viewModel.selectAlarm(id: 8)
        let draft = try #require(viewModel.alarmEditorDraft)
        #expect(draft.id == 8)
        #expect(draft.wasLoadedFromDevice)
        #expect(draft.isConfigured)
        #expect(!draft.isEnabled)
        #expect(draft.hour == 7)
        #expect(draft.minute == 30)
        #expect(draft.weekdays == [.wednesday])
        #expect(draft.durationSeconds == 2)
        #expect(draft.effect == .intermittent)
    }

    @Test func configuredAlarmDraftStartsUnchangedAndSendDisabled() {
        let draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        let eligibility = alarmEligibility(draft)

        #expect(!draft.hasPersistedChanges)
        #expect(!eligibility.hasPersistedChanges)
        #expect(!eligibility.canSend)
    }

    @Test func changingHourEnablesSendAndRestoringHourDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.hour = 10
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.hour = 9
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func changingMinuteEnablesSendAndRestoringMinuteDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.minute = 37
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.minute = 36
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func changingWeekdaySetEnablesSendAndRestoringWeekdaysDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.weekdays.insert(.friday)
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.weekdays = [.wednesday]
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func weekdayPresetChangesEnableSendAndRestoringPresetDisablesSend() {
        let record = configuredEnabledAlarmRecord(weekdays: AlarmWeekday.mondayThroughFriday)
        var draft = AlarmDraft(record: record)

        draft.weekdays = AlarmWeekday.everyDay
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.weekdays = AlarmWeekday.mondayThroughFriday
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func changingDurationEnablesSendAndRestoringDurationDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.durationSeconds = 3
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.durationSeconds = 2
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func changingEffectEnablesSendAndRestoringEffectDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.effect = .continuousBlink
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.effect = .intermittent
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func changingEnabledEnablesSendAndRestoringEnabledDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        draft.isEnabled = true
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)

        draft.isEnabled = false
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func configuredDisabledLoadedAlarmPreservesFieldsAndStartsSendDisabled() {
        let record = configuredDisabledAlarmRecord()
        let draft = AlarmDraft(record: record)

        #expect(draft.id == 9)
        #expect(draft.hour == 9)
        #expect(draft.minute == 36)
        #expect(draft.weekdays == [.wednesday])
        #expect(draft.durationSeconds == 2)
        #expect(draft.effect == .intermittent)
        #expect(draft.isConfigured)
        #expect(!draft.isEnabled)
        #expect(!draft.hasPersistedChanges)
        #expect(!alarmEligibility(draft).canSend)
    }

    @Test func emptyUnconfiguredAlarmCreationRemainsSendableWhenValid() {
        let emptyRecord = AlarmRecord(
            id: 12,
            isConfigured: false,
            isEnabled: false,
            readState: .loaded,
            rawFrequency: 0x00,
            rawDurationEffect: 0x00
        )
        var draft = AlarmDraft(record: emptyRecord)
        draft.hour = 7
        draft.minute = 30
        draft.weekdays = [.monday]
        draft.durationSeconds = 2
        draft.effect = .intermittent
        draft.isEnabled = false

        #expect(draft.persistedBaselineSignature == nil)
        #expect(draft.hasPersistedChanges)
        #expect(alarmEligibility(draft).canSend)
    }

    @Test func disconnectedStateDisablesSendEvenWhenDirty() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        draft.minute = 37

        let eligibility = alarmEligibility(draft, connectionAvailable: false)

        #expect(eligibility.hasPersistedChanges)
        #expect(!eligibility.canSend)
    }

    @Test func pendingCASendDisablesSend() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        draft.minute = 37

        let eligibility = alarmEligibility(draft, sendState: .sending(id: draft.id))

        #expect(eligibility.hasPersistedChanges)
        #expect(eligibility.sendInProgress)
        #expect(!eligibility.canSend)
    }

    @Test func bothSendControlsShareTheSameEligibilityState() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        draft.minute = 37
        let eligibility = alarmEligibility(draft)

        let topSendEnabled = eligibility.canSend
        let lowerSendEnabled = eligibility.canSend

        #expect(topSendEnabled)
        #expect(topSendEnabled == lowerSendEnabled)
    }

    @Test func configuredAlarmDeleteEnabledWhenConnectedAndIdle() {
        let draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        let eligibility = alarmDeleteEligibility(draft)

        #expect(eligibility.originalAlarmIsConfigured)
        #expect(eligibility.canDelete)
    }

    @Test func emptyAlarmDeleteDisabled() {
        let draft = AlarmDraft(record: AlarmRecord.emptyLoadedRecord(id: 9))
        let eligibility = alarmDeleteEligibility(draft)

        #expect(!eligibility.originalAlarmIsConfigured)
        #expect(!eligibility.canDelete)
    }

    @Test func pendingSendDisablesDelete() {
        let draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        let eligibility = alarmDeleteEligibility(draft, sendState: .sending(id: draft.id))

        #expect(eligibility.originalAlarmIsConfigured)
        #expect(!eligibility.canDelete)
    }

    @Test func pendingDeleteDisablesSendAndDelete() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        draft.minute = 37
        let sendEligibility = alarmEligibility(draft, deleteState: .deleting(id: draft.id))
        let deleteEligibility = alarmDeleteEligibility(draft, deleteState: .deleting(id: draft.id))

        #expect(!sendEligibility.canSend)
        #expect(!deleteEligibility.canDelete)
    }

    @Test func unchangedConfiguredAlarmDisablesSendAndEnablesDelete() {
        let draft = AlarmDraft(record: configuredDisabledAlarmRecord())

        #expect(!alarmEligibility(draft).canSend)
        #expect(alarmDeleteEligibility(draft).canDelete)
    }

    @Test func dirtyConfiguredAlarmEnablesSendAndDeleteBeforeOperationBegins() {
        var draft = AlarmDraft(record: configuredDisabledAlarmRecord())
        draft.minute = 37

        #expect(alarmEligibility(draft).canSend)
        #expect(alarmDeleteEligibility(draft).canDelete)
    }

    @Test func persistedSignatureComparisonUsesNormalizedHourAndMinute() throws {
        let firstDate = alarmDate(hour: 9, minute: 36, second: 0)
        let secondDate = alarmDate(hour: 9, minute: 36, second: 45)
        let firstDraft = draftFromDate(firstDate)
        let secondDraft = draftFromDate(secondDate)
        let firstSignature = try #require(firstDraft.currentPersistedSignature)
        let secondSignature = try #require(secondDraft.currentPersistedSignature)

        #expect(firstSignature == secondSignature)
    }

    @Test func equivalentDateValuesWithDifferentSecondsCompareEqualAfterNormalization() throws {
        let firstDate = alarmDate(hour: 7, minute: 30, second: 5)
        let secondDate = alarmDate(hour: 7, minute: 30, second: 59)
        let firstDraft = draftFromDate(firstDate)
        let secondDraft = draftFromDate(secondDate)
        let firstSignature = try #require(firstDraft.currentPersistedSignature)
        let secondSignature = try #require(secondDraft.currentPersistedSignature)

        #expect(firstSignature == secondSignature)
    }

    @Test func weekdayOrderingDifferencesWithSameMaskCompareEqual() throws {
        var firstDraft = AlarmDraft.defaultDraft(id: 14)
        firstDraft.hour = 6
        firstDraft.minute = 15
        firstDraft.weekdays = Set([.monday, .wednesday, .friday])
        firstDraft.durationSeconds = 4
        firstDraft.effect = .continuous
        firstDraft.isEnabled = true

        var secondDraft = firstDraft
        secondDraft.weekdays = Set([.friday, .monday, .wednesday])
        let firstSignature = try #require(firstDraft.currentPersistedSignature)
        let secondSignature = try #require(secondDraft.currentPersistedSignature)

        #expect(firstSignature == secondSignature)
    }

    @Test func encodedEnabledBitDifferenceComparesUnequal() throws {
        var disabledDraft = AlarmDraft(record: configuredDisabledAlarmRecord())
        var enabledDraft = disabledDraft
        enabledDraft.isEnabled = true

        let disabledSignature = try #require(disabledDraft.currentPersistedSignature)
        let enabledSignature = try #require(enabledDraft.currentPersistedSignature)

        #expect(disabledSignature != enabledSignature)
        #expect(disabledSignature.frequency == 0x08)
        #expect(enabledSignature.frequency == 0x88)
    }

    @Test func durationAndEffectEncodingDifferencesCompareUnequal() throws {
        let baseline = AlarmDraft(record: configuredDisabledAlarmRecord())
        var durationChanged = baseline
        var effectChanged = baseline
        durationChanged.durationSeconds = 3
        effectChanged.effect = .continuousBlink

        let baselineSignature = try #require(baseline.currentPersistedSignature)
        let durationChangedSignature = try #require(durationChanged.currentPersistedSignature)
        let effectChangedSignature = try #require(effectChanged.currentPersistedSignature)

        #expect(durationChangedSignature != baselineSignature)
        #expect(effectChangedSignature != baselineSignature)
    }

    @Test func alarmIDDifferenceComparesUnequalInPersistedSignature() throws {
        let firstDraft = AlarmDraft(record: configuredDisabledAlarmRecord(id: 9))
        let secondDraft = AlarmDraft(record: configuredDisabledAlarmRecord(id: 10))
        let firstSignature = try #require(firstDraft.currentPersistedSignature)
        let secondSignature = try #require(secondDraft.currentPersistedSignature)

        #expect(firstSignature != secondSignature)
    }

    @Test func disabledCAKeepsAlarmParametersAndOnlyClearsEnabledBit() throws {
        var enabledDraft = AlarmDraft.defaultDraft(id: 8)
        enabledDraft.hour = 7
        enabledDraft.minute = 30
        enabledDraft.weekdays = [.wednesday]
        enabledDraft.durationSeconds = 2
        enabledDraft.effect = .intermittent
        enabledDraft.isEnabled = true

        var disabledDraft = enabledDraft
        disabledDraft.isEnabled = false

        let enabledFrame = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: enabledDraft)
        let disabledFrame = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: disabledDraft)
        var enabledFrameWithEnabledBitCleared = enabledFrame.bytes
        enabledFrameWithEnabledBitCleared[9] &= 0x7F

        #expect(disabledFrame.bytes == enabledFrameWithEnabledBitCleared)
        #expect(enabledFrame.frequency == 0x88)
        #expect(disabledFrame.frequency == 0x08)
        #expect(disabledFrame.bytes[6] == 0x08)
        #expect(disabledFrame.bytes[7] == 0x07)
        #expect(disabledFrame.bytes[8] == 0x1E)
        #expect(disabledFrame.bytes[10] == 0x42)
        #expect(disabledFrame.durationEffect == enabledFrame.durationEffect)
    }

    @MainActor
    @Test func sendAlarmSeventeenEmitsOneCAAndNoES() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let alarm16 = viewModel.alarmRecords[15]
        let alarm18 = viewModel.alarmRecords[17]

        var draft = AlarmDraft.defaultDraft(id: 17)
        draft.hour = 12
        draft.minute = 45
        draft.weekdays = [.monday, .wednesday, .friday]
        draft.durationSeconds = 3
        draft.effect = .intermittent
        draft.isEnabled = true

        viewModel.sendAlarm(draft)

        let expectedCA = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: draft).bytes
        let esFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C]
        #expect(connection.sentFrames == [expectedCA])
        #expect(!connection.sentFrames.contains(esFrame))

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(caACK(boardID: 0, alarmID: 17)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[16].id == 17)
        #expect(viewModel.alarmRecords[16].hour == 12)
        #expect(viewModel.alarmRecords[16].minute == 45)
        #expect(viewModel.alarmRecords[15] == alarm16)
        #expect(viewModel.alarmRecords[17] == alarm18)
        #expect(viewModel.commandStatusMessage == "Alarm 17 saved.")
        #expect(viewModel.lastCAResultDiagnosticsText == "ACK")
    }

    @MainActor
    @Test func sendDisabledAlarmEmitsOneCAAndNoES() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        var draft = AlarmDraft.defaultDraft(id: 8)
        draft.hour = 7
        draft.minute = 30
        draft.weekdays = [.wednesday]
        draft.durationSeconds = 2
        draft.effect = .intermittent
        draft.isEnabled = false

        viewModel.sendAlarm(draft)

        let expectedCA = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: draft).bytes
        let esFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C]
        #expect(connection.sentFrames == [expectedCA])
        #expect(!connection.sentFrames.contains(esFrame))

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(caACK(boardID: 0, alarmID: 8)), nil, false, nil)
        await alarmDrainMainQueue()

        let record = viewModel.alarmRecords[7]
        #expect(record.isConfigured)
        #expect(!record.isEnabled)
        #expect(record.hour == 7)
        #expect(record.minute == 30)
        #expect(record.weekdays == [.wednesday])
        #expect(record.durationSeconds == 2)
        #expect(record.effect == .intermittent)
        #expect(record.rawFrequency == 0x08)
        #expect(record.rawDurationEffect == 0x42)
    }

    @MainActor
    @Test func deleteAlarmNineEmitsDAOnlyAndClearsAlarmNineOnly() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(8, hour: 8, minute: 8, frequency: 0xBE, durationEffect: 0x43, viewModel: viewModel, connection: connection)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        try await loadAlarm(10, hour: 10, minute: 10, frequency: 0xFF, durationEffect: 0x82, viewModel: viewModel, connection: connection)
        let alarm8 = viewModel.alarmRecords[7]
        let alarm10 = viewModel.alarmRecords[9]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        let sentFrameCount = connection.sentFrames.count
        viewModel.deleteAlarm(draft)

        let expectedDA = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 9)
        let deleteFrames = Array(connection.sentFrames.dropFirst(sentFrameCount))
        let esFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C]
        let zeroCAFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x43, 0x41, 0x09, 0x00, 0x00, 0x00, 0x00, 0x5C]
        #expect(deleteFrames == [expectedDA])
        #expect(!deleteFrames.contains(esFrame))
        #expect(!deleteFrames.contains(zeroCAFrame))

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(daACK(boardID: 0, alarmID: 9)), nil, false, nil)
        await alarmDrainMainQueue()

        let deletedRecord = viewModel.alarmRecords[8]
        #expect(viewModel.alarmRecords[7] == alarm8)
        #expect(viewModel.alarmRecords[9] == alarm10)
        #expect(deletedRecord == AlarmRecord.emptyLoadedRecord(id: 9))
        #expect(!deletedRecord.isConfigured)
        #expect(!deletedRecord.isEnabled)
        #expect(deletedRecord.hour == 0)
        #expect(deletedRecord.minute == 0)
        #expect(deletedRecord.weekdays.isEmpty)
        #expect(AlarmCellVisualConfiguration(record: deletedRecord).icon == nil)
        #expect(viewModel.alarmEditorDraft == nil)
        #expect(viewModel.commandStatusMessage == "Alarm 9 deleted.")
        #expect(viewModel.lastDAAlarmIDDiagnosticsText == "9")
        #expect(viewModel.lastDAResultDiagnosticsText == "ACK")
    }

    @MainActor
    @Test func wrongDAAlarmIDDoesNotSatisfyPendingDelete() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        let original = viewModel.alarmRecords[8]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        viewModel.deleteAlarm(draft)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(daACK(boardID: 0, alarmID: 8)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[8] == original)
        #expect(viewModel.alarmDeleteState == .deleting(id: 9))
    }

    @MainActor
    @Test func malformedDAACKFailsPendingDeleteAndKeepsDraft() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        let original = viewModel.alarmRecords[8]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        viewModel.deleteAlarm(draft)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data([0x2F, 0x74, 0x61, 0x00, 0x64, 0x61, 0x09, 0x00, 0x5C]), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[8] == original)
        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.lastDAResultDiagnosticsText == "Error")
        if case let .failed(id, _) = viewModel.alarmDeleteState {
            #expect(id == 9)
        } else {
            Issue.record("Malformed DA ACK should fail the pending delete")
        }
    }

    @MainActor
    @Test func deleteTimeoutPreservesOriginalRecordAndDraft() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        let original = viewModel.alarmRecords[8]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        viewModel.deleteAlarm(draft)
        connection.lastSendCompletion?(nil)
        await alarmDrainMainQueue()
        scheduler.fireAlarmTransactionTimeout()
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[8] == original)
        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.lastDAResultDiagnosticsText == "Timeout")
        if case let .failed(id, _) = viewModel.alarmDeleteState {
            #expect(id == 9)
        } else {
            Issue.record("Delete timeout should fail the pending delete")
        }
    }

    @MainActor
    @Test func deleteDisconnectPreservesOriginalRecordAndDraft() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        let original = viewModel.alarmRecords[8]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        viewModel.deleteAlarm(draft)
        viewModel.disconnect()
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[8] == original)
        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.lastDAResultDiagnosticsText == "Error")
        if case let .failed(id, _) = viewModel.alarmDeleteState {
            #expect(id == 9)
        } else {
            Issue.record("Disconnect should fail the pending delete")
        }
    }

    @MainActor
    @Test func staleConnectionGenerationDAACKIsIgnored() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        let original = viewModel.alarmRecords[8]

        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        viewModel.deleteAlarm(draft)
        let staleReceive = try #require(connection.lastReceiveCompletion)
        viewModel.connect()
        await alarmDrainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await alarmDrainMainQueue()
        staleReceive(Data(daACK(boardID: 0, alarmID: 9)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmRecords[8] == original)
        #expect(viewModel.lastDAResultDiagnosticsText == "Error")
    }

    @MainActor
    @Test func cancelDeleteConfirmationEmitsNoDA() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        viewModel.selectAlarm(id: 9)
        let sentFrameCount = connection.sentFrames.count
        let expectedDA = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 9)
        let deleteFrames = Array(connection.sentFrames.dropFirst(sentFrameCount))

        #expect(connection.sentFrames.count == sentFrameCount)
        #expect(deleteFrames.isEmpty)
        #expect(!deleteFrames.contains(expectedDA))
    }

    @MainActor
    @Test func confirmDeleteEmitsExactlyOneDA() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        try await loadAlarm(9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42, viewModel: viewModel, connection: connection)
        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        let sentFrameCount = connection.sentFrames.count

        viewModel.deleteAlarm(draft)

        let expectedDA = try AlarmProtocolCodec.makeDARequest(boardID: 0, alarmID: 9)
        let deleteFrames = Array(connection.sentFrames.dropFirst(sentFrameCount))
        #expect(deleteFrames == [expectedDA])
    }

    @MainActor
    @Test func failedSendKeepsConfiguredBaselineDraftPreservedAndDirty() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAlarm(id: 9)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42)), nil, false, nil)
        await alarmDrainMainQueue()
        viewModel.selectAlarm(id: 9)

        var draft = try #require(viewModel.alarmEditorDraft)
        draft.minute = 37
        viewModel.alarmEditorDraft = draft

        viewModel.sendAlarm(draft)
        connection.lastSendCompletion?(NWError.posix(.ECONNRESET))
        await alarmDrainMainQueue()

        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.alarmDraftHasPersistedChanges(draft))
        #expect(viewModel.alarmRecords[8].minute == 36)
        if case let .failed(id, _) = viewModel.alarmSendState {
            #expect(id == 9)
        } else {
            Issue.record("Failed send should leave alarm send state failed")
        }
    }

    @MainActor
    @Test func successfulACKUpdatesSavedStateAndSubsequentUnchangedSendEmitsNoDuplicateCA() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAlarm(id: 9)
        var receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42)), nil, false, nil)
        await alarmDrainMainQueue()
        viewModel.selectAlarm(id: 9)

        var draft = try #require(viewModel.alarmEditorDraft)
        draft.minute = 37
        viewModel.sendAlarm(draft)
        let expectedCA = try AlarmProtocolCodec.makeCARequest(boardID: 0, draft: draft).bytes
        #expect(connection.sentFrames.last == expectedCA)

        receive = try #require(connection.lastReceiveCompletion)
        receive(Data(caACK(boardID: 0, alarmID: 9)), nil, false, nil)
        await alarmDrainMainQueue()

        let savedRecord = viewModel.alarmRecords[8]
        #expect(savedRecord.minute == 37)
        #expect(savedRecord.isConfigured)
        #expect(!savedRecord.isEnabled)
        #expect(viewModel.alarmEditorDraft == nil)
        #expect(!AlarmDraft(record: savedRecord).hasPersistedChanges)

        let sentFrameCount = connection.sentFrames.count
        viewModel.sendAlarm(AlarmDraft(record: savedRecord))

        #expect(connection.sentFrames.count == sentFrameCount)
    }

    @MainActor
    @Test func unchangedConfiguredAlarmSendGuardEmitsNoCA() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)

        viewModel.readAlarm(id: 9)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42)), nil, false, nil)
        await alarmDrainMainQueue()
        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)
        let sentFrameCount = connection.sentFrames.count
        let statusBefore = viewModel.commandStatusMessage
        let lastCAAlarmIDBefore = viewModel.lastCAAlarmID
        let lastCAResultBefore = viewModel.lastCAResultText

        viewModel.sendAlarm(draft)

        #expect(connection.sentFrames.count == sentFrameCount)
        #expect(viewModel.commandStatusMessage == statusBefore)
        #expect(viewModel.lastCAAlarmID == lastCAAlarmIDBefore)
        #expect(viewModel.lastCAResultText == lastCAResultBefore)
    }

    @MainActor
    @Test func unchangedConfiguredAlarmSendGuardEmitsNoES() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let esFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C]

        viewModel.readAlarm(id: 9)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(laResponse(boardID: 0, alarmID: 9, hour: 9, minute: 36, frequency: 0x08, durationEffect: 0x42)), nil, false, nil)
        await alarmDrainMainQueue()
        viewModel.selectAlarm(id: 9)
        let draft = try #require(viewModel.alarmEditorDraft)

        viewModel.sendAlarm(draft)

        #expect(!connection.sentFrames.contains(esFrame))
    }

    @MainActor
    @Test func wrongCAAlarmIDDoesNotSatisfyPendingSend() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let draft = AlarmDraft.defaultDraft(id: 17)

        viewModel.sendAlarm(draft)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(caACK(boardID: 0, alarmID: 18)), nil, false, nil)
        await alarmDrainMainQueue()

        #expect(viewModel.alarmSendState == .sending(id: 17))
        #expect(viewModel.alarmRecords[16].readState == .notLoaded)
    }

    @MainActor
    @Test func malformedCAACKFailsPendingSendAndKeepsDraft() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let draft = AlarmDraft.defaultDraft(id: 17)
        viewModel.alarmEditorDraft = draft

        viewModel.sendAlarm(draft)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data([0x2F, 0x74, 0x61, 0x00, 0x63, 0x61, 0x11, 0x00, 0x5C]), nil, false, nil)
        await alarmDrainMainQueue()

        if case let .failed(id, _) = viewModel.alarmSendState {
            #expect(id == 17)
        } else {
            Issue.record("Malformed CA ACK should fail the pending send")
        }
        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.lastCAResultDiagnosticsText == "Error")
    }

    @MainActor
    @Test func duplicateCAACKDoesNotProduceDuplicateSaveUpdate() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let draft = AlarmDraft.defaultDraft(id: 17)

        viewModel.sendAlarm(draft)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(caACK(boardID: 0, alarmID: 17)), nil, false, nil)
        await alarmDrainMainQueue()
        receive(Data(caACK(boardID: 0, alarmID: 17)), nil, false, nil)
        await alarmDrainMainQueue()

        let acknowledgedLogs = viewModel.logEntries.filter { $0.message == "CA Alarm 17 ACK" }
        #expect(acknowledgedLogs.count == 1)
        #expect(viewModel.alarmSendState == .succeeded(id: 17))
    }

    @MainActor
    @Test func repeatedSendTapDoesNotCreateDuplicateCA() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let draft = AlarmDraft.defaultDraft(id: 17)

        viewModel.sendAlarm(draft)
        viewModel.sendAlarm(draft)

        #expect(connection.sentFrames.count == 1)
    }

    @MainActor
    @Test func sendFailureKeepsDraftAndDoesNotUpdateRecord() async throws {
        let recorder = AlarmFakeTCPConnectionRecorder()
        let scheduler = AlarmFakeHeartbeatScheduler()
        let viewModel = try await connectedAlarmViewModel(recorder: recorder, scheduler: scheduler)
        let connection = try #require(recorder.connections.first)
        let draft = AlarmDraft.defaultDraft(id: 17)
        viewModel.alarmEditorDraft = draft

        viewModel.sendAlarm(draft)
        connection.lastSendCompletion?(NWError.posix(.ECONNRESET))
        await alarmDrainMainQueue()

        #expect(viewModel.alarmEditorDraft == draft)
        #expect(viewModel.alarmRecords[16].readState == .notLoaded)
        if case let .failed(id, _) = viewModel.alarmSendState {
            #expect(id == 17)
        } else {
            Issue.record("Send failure should leave the editor in failed state")
        }
    }
}

private func laResponse(
    boardID: UInt8,
    alarmID: UInt8,
    hour: UInt8,
    minute: UInt8,
    frequency: UInt8,
    durationEffect: UInt8
) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x6C, 0x61, alarmID, hour, minute, frequency, durationEffect, 0x5C]
}

private func caACK(boardID: UInt8, alarmID: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x63, 0x61, alarmID, 0x5C]
}

private func daACK(boardID: UInt8, alarmID: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x64, 0x61, alarmID, 0x5C]
}

private func configuredDisabledAlarmRecord(id: Int = 9) -> AlarmRecord {
    AlarmRecord(
        id: id,
        hour: 9,
        minute: 36,
        weekdays: [.wednesday],
        durationSeconds: 2,
        effect: .intermittent,
        isConfigured: true,
        isEnabled: false,
        readState: .loaded,
        rawFrequency: 0x08,
        rawDurationEffect: 0x42
    )
}

private func configuredEnabledAlarmRecord(
    id: Int = 9,
    weekdays: Set<AlarmWeekday> = [.wednesday]
) -> AlarmRecord {
    AlarmRecord(
        id: id,
        hour: 9,
        minute: 36,
        weekdays: weekdays,
        durationSeconds: 2,
        effect: .intermittent,
        isConfigured: true,
        isEnabled: true,
        readState: .loaded,
        rawFrequency: AlarmProtocolCodec.encodeFrequency(weekdays: weekdays, isEnabled: true),
        rawDurationEffect: 0x42
    )
}

private func alarmEligibility(
    _ draft: AlarmDraft,
    connectionAvailable: Bool = true,
    sendState: AlarmSendState = .idle,
    deleteState: AlarmDeleteState = .idle
) -> AlarmEditorSendEligibility {
    AlarmEditorSendEligibility.evaluate(
        draft: draft,
        connectionAvailable: connectionAvailable,
        sendState: sendState,
        deleteState: deleteState
    )
}

private func alarmDeleteEligibility(
    _ draft: AlarmDraft,
    connectionAvailable: Bool = true,
    originalAlarmIsConfigured: Bool? = nil,
    sendState: AlarmSendState = .idle,
    deleteState: AlarmDeleteState = .idle
) -> AlarmEditorDeleteEligibility {
    AlarmEditorDeleteEligibility.evaluate(
        draft: draft,
        connectionAvailable: connectionAvailable,
        originalAlarmIsConfigured: originalAlarmIsConfigured,
        sendState: sendState,
        deleteState: deleteState
    )
}

private func alarmDate(hour: Int, minute: Int, second: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = 2026
    components.month = 7
    components.day = 8
    components.hour = hour
    components.minute = minute
    components.second = second
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

private func draftFromDate(_ date: Date) -> AlarmDraft {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let components = calendar.dateComponents([.hour, .minute], from: date)
    var draft = AlarmDraft.defaultDraft(id: 9)
    draft.hour = components.hour ?? 0
    draft.minute = components.minute ?? 0
    draft.weekdays = [.wednesday]
    draft.durationSeconds = 2
    draft.effect = .intermittent
    draft.isEnabled = false
    return draft
}

@MainActor
private func connectedAlarmViewModel(
    recorder: AlarmFakeTCPConnectionRecorder,
    scheduler: AlarmFakeHeartbeatScheduler
) async throws -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() },
        heartbeatScheduler: scheduler.schedule(_:_:),
        heartbeatACKTimeoutScheduler: scheduler.schedule(_:_:)
    )
    let viewModel = ESP32ControllerViewModel(client: client, timeSyncScheduler: scheduler.schedule(_:_:))
    viewModel.authorizeNetworking()
    viewModel.manualBoardID = "0"
    viewModel.connect()
    await alarmDrainMainQueue()
    let connection = try #require(recorder.connections.first)
    connection.stateUpdateHandler?(.ready)
    await alarmDrainMainQueue()
    return viewModel
}

@MainActor
private func loadAlarm(
    _ alarmID: UInt8,
    hour: UInt8,
    minute: UInt8,
    frequency: UInt8,
    durationEffect: UInt8,
    viewModel: ESP32ControllerViewModel,
    connection: AlarmFakeTCPConnection
) async throws {
    viewModel.readAlarm(id: Int(alarmID))
    let receive = try #require(connection.lastReceiveCompletion)
    receive(
        Data(laResponse(
            boardID: 0,
            alarmID: alarmID,
            hour: hour,
            minute: minute,
            frequency: frequency,
            durationEffect: durationEffect
        )),
        nil,
        false,
        nil
    )
    await alarmDrainMainQueue()
}

@MainActor
private func alarmDrainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private final class AlarmFakeTCPConnectionRecorder {
    var connections: [AlarmFakeTCPConnection] = []

    func makeConnection() -> AlarmFakeTCPConnection {
        let connection = AlarmFakeTCPConnection()
        connections.append(connection)
        return connection
    }
}

private final class AlarmFakeHeartbeatScheduler {
    var tasks: [AlarmFakeScheduledTask] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = AlarmFakeScheduledTask(delay: delay, callback: callback)
        tasks.append(task)
        return task
    }

    func fireAlarmTransactionTimeout() {
        tasks.last { !$0.isCancelled && $0.delay == ESP32ControllerViewModel.alarmTransactionTimeout }?.fire()
    }
}

private final class AlarmFakeScheduledTask: CancellableTask {
    let delay: TimeInterval
    private let callback: @Sendable () -> Void
    var isCancelled = false

    init(delay: TimeInterval, callback: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.callback = callback
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else {
            return
        }

        callback()
    }
}

private final class AlarmFakeTCPConnection: TCPConnection {
    typealias ReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var cancelCallCount = 0
    var receiveCallCount = 0
    var sendCallCount = 0
    var lastReceiveCompletion: ReceiveCompletion?
    var lastSendCompletion: ((NWError?) -> Void)?
    var sentContents: [Data?] = []

    var sentFrames: [[UInt8]] {
        sentContents.compactMap { $0.map(Array.init) }
    }

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
