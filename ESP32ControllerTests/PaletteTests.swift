//
//  PaletteTests.swift
//  ESP32ControllerTests
//
//  Created by Codex on 13/07/26.
//

import Foundation
import Network
import Testing
@testable import ESP32Controller

@Suite(.serialized)
struct PaletteTests {
    @Test func rgb888ParsesUppercaseAndLowercaseAndEncodesUppercase() throws {
        #expect(try RGB888(hex: "A1B2C3") == RGB888(r: 0xA1, g: 0xB2, b: 0xC3))
        #expect(try RGB888(hex: "a1b2c3") == RGB888(r: 0xA1, g: 0xB2, b: 0xC3))
        #expect(try RGB888(hex: "a1b2c3").uppercaseHex == "A1B2C3")
    }

    @Test func rgb888RejectsInvalidLengthAndNonHex() {
        #expect(throws: RGB888Error.invalidLength) {
            _ = try RGB888(hex: "FFFFF")
        }
        #expect(throws: RGB888Error.invalidHex) {
            _ = try RGB888(hex: "GG0000")
        }
    }

    @Test func delimiterSafeColorIsAlwaysASCIIInsideFullFrame() throws {
        var draft = try #require(PaletteFactoryDefaults.draft(for: .mode1))
        draft.roleValues[.date] = try RGB888(hex: "005CFF")
        let frame = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: draft)

        #expect(try RGB888(hex: "005CFF").uppercaseHexASCII == [0x30, 0x30, 0x35, 0x43, 0x46, 0x46])
        #expect(frame.filter { $0 == 0x5C }.count == 1)
        #expect(frame.last == 0x5C)
    }

    @Test func paletteRolesHaveStableLabelsSortOrderAndModeSupport() {
        #expect(PaletteRole.allCases.sorted().map(\.label) == [
            "Time", "Date", "Weekday", "Temperature Cold", "Temperature Cool",
            "Temperature Warm", "Temperature Hot"
        ])
        #expect(PaletteRole.requiredRoles(for: .mode1) == [
            .time, .date, .temperatureCold, .temperatureCool, .temperatureWarm, .temperatureHot
        ])
        #expect(PaletteRole.requiredRoles(for: .mode3).contains(.weekday))
        #expect(PaletteRole.requiredRoles(for: .rotation).isEmpty)
    }

    @Test func factoryDefaultsMatchFirmwareForAllEditableModes() throws {
        let mode1 = try #require(PaletteFactoryDefaults.record(for: .mode1))
        let mode2 = try #require(PaletteFactoryDefaults.record(for: .mode2))
        let mode3 = try #require(PaletteFactoryDefaults.record(for: .mode3))

        #expect(mode1.roleValues[.date]?.uppercaseHex == "00FF00")
        #expect(mode2.roleValues[.date]?.uppercaseHex == "0000FF")
        #expect(mode3.roleValues[.weekday]?.uppercaseHex == "00FF00")
        for record in [mode1, mode2, mode3] {
            #expect(record.roleValues[.time]?.uppercaseHex == "FFFFFF")
            #expect(record.roleValues[.temperatureCold]?.uppercaseHex == "FFFFFF")
            #expect(record.roleValues[.temperatureCool]?.uppercaseHex == "00FFFF")
            #expect(record.roleValues[.temperatureWarm]?.uppercaseHex == "FF4100")
            #expect(record.roleValues[.temperatureHot]?.uppercaseHex == "FF0000")
        }
        #expect(PaletteFactoryDefaults.record(for: .rotation) == nil)
    }

    @Test func colorPalettePresentationExposesOnlyEditableModesAndExpectedRoles() {
        #expect(ColorPalettePresentation.editableModes == [.mode1, .mode2, .mode3])
        #expect(!ColorPalettePresentation.editableModes.contains(.rotation))
        #expect(ColorPalettePresentation.editableModes.map(ColorPalettePresentation.modeTitle) == [
            "Mode 1", "Mode 2", "Mode 3"
        ])

        let mode1Labels = ColorPalettePresentation.roles(for: .mode1).map(\.label)
        #expect(mode1Labels == [
            "Time", "Date", "Temperature Cold", "Temperature Cool",
            "Temperature Warm", "Temperature Hot"
        ])
        #expect(ColorPalettePresentation.roles(for: .mode2).map(\.label) == mode1Labels)
        #expect(ColorPalettePresentation.roles(for: .mode3).map(\.label) == [
            "Time", "Date", "Weekday", "Temperature Cold", "Temperature Cool",
            "Temperature Warm", "Temperature Hot"
        ])
    }

    @Test func colorPalettePresentationProvidesDisconnectedUnsupportedAndLoadingCopy() {
        let disconnected = ColorPalettePresentation.contentState(
            canUseClockControls: false,
            availability: .available,
            hasDraft: true,
            errorMessage: nil
        )
        #expect(disconnected == .disconnected)
        #expect(disconnected.message == "Connect to a CLOCK device to edit colors.")

        let unsupported = ColorPalettePresentation.contentState(
            canUseClockControls: true,
            availability: .unsupported("ignored internal copy"),
            hasDraft: false,
            errorMessage: nil
        )
        #expect(unsupported == .unsupported)
        #expect(unsupported.message == "Color Palette requires newer CLOCK firmware.")

        let loading = ColorPalettePresentation.contentState(
            canUseClockControls: true,
            availability: .unknown,
            hasDraft: false,
            errorMessage: nil
        )
        #expect(loading == .loading)
        #expect(loading.message == "Loading colors...")
        #expect(ColorPalettePresentation.restoreMessage(for: .mode3) ==
            "This will restore the default colors for Mode 3.")
    }

    @Test func rgb888SwiftUIColorRoundTripsCommonSRGBColorsExactly() throws {
        for hex in ["FFFFFF", "000000", "FF0000", "00FF00", "0000FF", "005CFF", "FF4100"] {
            let expected = try RGB888(hex: hex)
            #expect(RGB888(sRGBColor: expected.swiftUIColor) == expected)
        }
    }

    @Test func smRequestsUseExactUppercaseASCIIBytesForAllFirmwareModes() throws {
        #expect(try SetModeProtocolCodec.makeRequest(boardID: 0, mode: .mode1) == requestFrame("SM01"))
        #expect(try SetModeProtocolCodec.makeRequest(boardID: 0, mode: .mode2) == requestFrame("SM02"))
        #expect(try SetModeProtocolCodec.makeRequest(boardID: 0, mode: .mode3) == requestFrame("SM03"))
        #expect(try SetModeProtocolCodec.makeRequest(boardID: 0, mode: .rotation) == requestFrame("SM04"))
        #expect(try ClockProtocolEncoder.encode(.setDisplayMode(.mode1), boardID: 0) == [
            0x2F, 0x54, 0x41, 0x00, 0x53, 0x4D, 0x30, 0x31, 0x5C
        ])
    }

    @Test func smDecodesSuccessForModesOneThroughFour() throws {
        for mode in PaletteMode.allCases {
            let acknowledgement = try SetModeProtocolCodec.decodeResponse(
                responseFrame(command: "sm", payload: "\(mode.uppercaseHex)00"),
                expectedBoardID: 0
            )
            #expect(acknowledgement.mode == mode)
            #expect(acknowledgement.status == .success)
        }
    }

    @Test func smDecodesFailureModesAndStatusMapping() throws {
        let unsupported = try SetModeProtocolCodec.decodeResponse(
            responseFrame(command: "sm", payload: "0501"),
            expectedBoardID: 0
        )
        let invalidHexMode = try SetModeProtocolCodec.decodeResponse(
            responseFrame(command: "sm", payload: "0003"),
            expectedBoardID: 0
        )
        let saveFailure = try SetModeProtocolCodec.decodeResponse(
            responseFrame(command: "sm", payload: "0104"),
            expectedBoardID: 0
        )

        #expect(unsupported == SetModeAcknowledgement(modeValue: 0x05, status: .unsupportedMode))
        #expect(invalidHexMode == SetModeAcknowledgement(modeValue: 0x00, status: .invalidHex))
        #expect(saveFailure.status == .settingsSaveFailure)
        #expect(SetModeStatus.allCases.map(\.rawValue) == [0x00, 0x01, 0x02, 0x03, 0x04, 0x0A])
        for status in SetModeStatus.allCases {
            let acknowledgement = try SetModeProtocolCodec.decodeResponse(
                responseFrame(command: "sm", payload: "01\(status.uppercaseHex)"),
                expectedBoardID: 0
            )
            #expect(acknowledgement.status == status)
            #expect(!status.message.isEmpty)
        }
    }

    @Test func smRejectsMalformedLengthWrongCommandAndInvalidHex() {
        #expect(throws: SetModeProtocolError.invalidLength) {
            _ = try SetModeProtocolCodec.decodeResponse(
                Array(responseFrame(command: "sm", payload: "0100").dropLast()),
                expectedBoardID: 0
            )
        }
        #expect(throws: SetModeProtocolError.unexpectedCommand) {
            _ = try SetModeProtocolCodec.decodeResponse(
                responseFrame(command: "nm", payload: "0100"),
                expectedBoardID: 0
            )
        }
        #expect(throws: SetModeProtocolError.invalidHex) {
            _ = try SetModeProtocolCodec.decodeResponse(
                responseFrame(command: "sm", payload: "0G00"),
                expectedBoardID: 0
            )
        }
    }

    @Test func rmRequestUsesExactBytesAndEncoderPath() throws {
        let expected: [UInt8] = [0x2F, 0x54, 0x41, 0x00, 0x52, 0x4D, 0x5C]
        #expect(try ReadModeProtocolCodec.makeRequest(boardID: 0) == expected)
        #expect(try ClockProtocolEncoder.encode(.readDisplayMode, boardID: 0) == expected)
    }

    @Test func rmDecodesSuccessForModesOneThroughFourAndInternalFailure() throws {
        for mode in PaletteMode.allCases {
            let acknowledgement = try ReadModeProtocolCodec.decodeResponse(
                responseFrame(command: "rm", payload: "\(mode.uppercaseHex)00"),
                expectedBoardID: 0
            )
            #expect(acknowledgement.mode == mode)
            #expect(acknowledgement.status == .success)
        }

        let failure = try ReadModeProtocolCodec.decodeResponse(
            responseFrame(command: "rm", payload: "000A"),
            expectedBoardID: 0
        )
        #expect(failure == ReadModeAcknowledgement(modeValue: 0, status: .internalFailure))
    }

    @Test func rmRejectsMalformedLengthWrongCommandAndInvalidHex() {
        #expect(throws: ReadModeProtocolError.invalidLength) {
            _ = try ReadModeProtocolCodec.decodeResponse(
                Array(responseFrame(command: "rm", payload: "0100").dropLast()),
                expectedBoardID: 0
            )
        }
        #expect(throws: ReadModeProtocolError.unexpectedCommand) {
            _ = try ReadModeProtocolCodec.decodeResponse(
                responseFrame(command: "sm", payload: "0100"),
                expectedBoardID: 0
            )
        }
        #expect(throws: ReadModeProtocolError.invalidHex) {
            _ = try ReadModeProtocolCodec.decodeResponse(
                responseFrame(command: "rm", payload: "0G00"),
                expectedBoardID: 0
            )
        }
    }

    @Test func lpRequestsUseExactUppercaseASCIIBytes() throws {
        #expect(try PaletteProtocolCodec.makeLPRequest(boardID: 0, mode: .mode1) == requestFrame("LP01"))
        #expect(try PaletteProtocolCodec.makeLPRequest(boardID: 0, mode: .mode2) == requestFrame("LP02"))
        #expect(try PaletteProtocolCodec.makeLPRequest(boardID: 0, mode: .mode3) == requestFrame("LP03"))
        #expect(try ClockProtocolEncoder.encode(.loadPalette(.mode1), boardID: 0) == requestFrame("LP01"))
    }

    @Test func mode4CannotEncodeEditableReadSaveOrDefaultRestore() throws {
        #expect(throws: PaletteProtocolError.unsupportedEditableMode) {
            _ = try PaletteProtocolCodec.makeLPRequest(boardID: 0, mode: .rotation)
        }
        #expect(throws: PaletteProtocolError.unsupportedEditableMode) {
            _ = try PaletteProtocolCodec.makeDPRequest(boardID: 0, mode: .rotation)
        }
        let draft = ModePaletteDraft(mode: .rotation, roleValues: [:])
        #expect(throws: PaletteProtocolError.unsupportedEditableMode) {
            _ = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: draft)
        }
    }

    @Test func lpDecodesAllFactoryPalettes() throws {
        for mode in PaletteMode.editableCases {
            let response = try PaletteProtocolCodec.decodeLPResponse(
                factoryLPResponse(mode: mode),
                expectedBoardID: 0
            )
            guard case let .success(record) = response else {
                Issue.record("Expected LP success for Mode \(mode.rawValue)")
                continue
            }
            #expect(record == PaletteFactoryDefaults.record(for: mode))
        }
    }

    @Test func lpDecodesMode4UnsupportedAndErrorZeroVersionCount() throws {
        let mode4 = try PaletteProtocolCodec.decodeLPResponse(
            responseFrame(command: "lp", payload: "04010000"),
            expectedBoardID: 0
        )
        let nvsFailure = try PaletteProtocolCodec.decodeLPResponse(
            responseFrame(command: "lp", payload: "01080000"),
            expectedBoardID: 0
        )

        #expect(mode4 == .failure(mode: .rotation, status: .unsupportedMode))
        #expect(nvsFailure == .failure(mode: .mode1, status: .nvsFailure))
    }

    @Test func lpRejectsMalformedLengthDuplicateRoleInvalidHexAndUnsupportedVersion() throws {
        var malformed = factoryLPResponse(mode: .mode1)
        malformed.remove(at: malformed.count - 2)
        #expect(throws: PaletteProtocolError.invalidCountOrLength) {
            _ = try PaletteProtocolCodec.decodeLPResponse(malformed, expectedBoardID: 0)
        }

        let duplicate = responseFrame(
            command: "lp",
            payload: "0100010701FFFFFF0200FF0010FFFFFF1100FFFF12FF410013FF000001000000"
        )
        #expect(throws: PaletteProtocolError.duplicateRole(0x01)) {
            _ = try PaletteProtocolCodec.decodeLPResponse(duplicate, expectedBoardID: 0)
        }

        var invalidHex = factoryLPResponse(mode: .mode1)
        invalidHex[16] = 0x47
        #expect(throws: PaletteProtocolError.invalidHex) {
            _ = try PaletteProtocolCodec.decodeLPResponse(invalidHex, expectedBoardID: 0)
        }

        var unsupportedVersion = factoryLPResponse(mode: .mode1)
        unsupportedVersion[11] = 0x32
        #expect(throws: PaletteProtocolError.unsupportedVersion(0x02)) {
            _ = try PaletteProtocolCodec.decodeLPResponse(unsupportedVersion, expectedBoardID: 0)
        }
    }

    @Test func lpPreservesUnknownRolesWithoutShowingThemAsKnown() throws {
        let response = responseFrame(
            command: "lp",
            payload: "0100010701FFFFFF0200FF0010FFFFFF1100FFFF12FF410013FF000020123456"
        )
        guard case let .success(record) = try PaletteProtocolCodec.decodeLPResponse(response, expectedBoardID: 0) else {
            Issue.record("Expected LP success")
            return
        }

        #expect(record.roleValues.count == 6)
        #expect(record.unknownRoleValues == [0x20: try RGB888(hex: "123456")])
        let roundTrip = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: record.draft)
        #expect(String(bytes: roundTrip.dropFirst(6).dropLast(), encoding: .ascii)?.hasSuffix("20123456") == true)
    }

    @Test func cpFactoryFramesUseExactCompleteRoleSortedPayloads() throws {
        let mode1 = try #require(PaletteFactoryDefaults.draft(for: .mode1))
        let mode2 = try #require(PaletteFactoryDefaults.draft(for: .mode2))
        let mode3 = try #require(PaletteFactoryDefaults.draft(for: .mode3))

        #expect(try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: mode1) == requestFrame(
            "CP01010601FFFFFF0200FF0010FFFFFF1100FFFF12FF410013FF0000"
        ))
        #expect(try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: mode2) == requestFrame(
            "CP02010601FFFFFF020000FF10FFFFFF1100FFFF12FF410013FF0000"
        ))
        #expect(try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: mode3) == requestFrame(
            "CP03010701FFFFFF020000FF0300FF0010FFFFFF1100FFFF12FF410013FF0000"
        ))
    }

    @Test func cpChangedDateStillEncodesCompletePaletteForMagentaAndDelimiterSafeBlue() throws {
        var draft = try #require(PaletteFactoryDefaults.draft(for: .mode1))
        draft.roleValues[.date] = try RGB888(hex: "FF00FF")
        let magenta = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: draft)
        #expect(magenta == requestFrame(
            "CP01010601FFFFFF02FF00FF10FFFFFF1100FFFF12FF410013FF0000"
        ))
        #expect(String(bytes: magenta.dropFirst(6).dropLast(), encoding: .ascii)?.contains("005CFF") == false)

        draft.roleValues[.date] = try RGB888(hex: "005CFF")
        let blue = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: draft)
        #expect(blue == requestFrame(
            "CP01010601FFFFFF02005CFF10FFFFFF1100FFFF12FF410013FF0000"
        ))
        #expect(blue.filter { $0 == 0x5C }.count == 1)
    }

    @Test func cpRefusesIncompleteAndKnownUnsupportedRoleSets() throws {
        var incomplete = try #require(PaletteFactoryDefaults.draft(for: .mode1))
        incomplete.roleValues.removeValue(forKey: .temperatureHot)
        #expect(throws: PaletteProtocolError.incompleteRequiredRoles(.mode1)) {
            _ = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: incomplete)
        }

        var unsupported = try #require(PaletteFactoryDefaults.draft(for: .mode1))
        unsupported.roleValues[.weekday] = try RGB888(hex: "00FF00")
        #expect(throws: PaletteProtocolError.unsupportedRole(0x03, .mode1)) {
            _ = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: unsupported)
        }
    }

    @Test func cpAcknowledgementsDecodeSuccessNVSAndEveryDefinedStatus() throws {
        #expect(try PaletteProtocolCodec.decodeCPACK(
            responseFrame(command: "cp", payload: "0100"), expectedBoardID: 0
        ) == PaletteAcknowledgement(mode: .mode1, status: .success))
        #expect(try PaletteProtocolCodec.decodeCPACK(
            responseFrame(command: "cp", payload: "0108"), expectedBoardID: 0
        ) == PaletteAcknowledgement(mode: .mode1, status: .nvsFailure))

        for status in PaletteStatus.allCases {
            let acknowledgement = try PaletteProtocolCodec.decodeCPACK(
                responseFrame(command: "cp", payload: "01\(status.uppercaseHex)"),
                expectedBoardID: 0
            )
            #expect(acknowledgement.status == status)
            #expect(!status.message.isEmpty)
        }
    }

    @Test func dpRequestsAndAcknowledgementsUseExactBytes() throws {
        #expect(try PaletteProtocolCodec.makeDPRequest(boardID: 0, mode: .mode1) == requestFrame("DP01"))
        #expect(try PaletteProtocolCodec.makeDPRequest(boardID: 0, mode: .mode2) == requestFrame("DP02"))
        #expect(try PaletteProtocolCodec.makeDPRequest(boardID: 0, mode: .mode3) == requestFrame("DP03"))
        #expect(try ClockProtocolEncoder.encode(.restoreDefaultPalette(.mode3), boardID: 0) == requestFrame("DP03"))
        #expect(try PaletteProtocolCodec.decodeDPACK(
            responseFrame(command: "dp", payload: "0100"), expectedBoardID: 0
        ) == PaletteAcknowledgement(mode: .mode1, status: .success))
        #expect(try PaletteProtocolCodec.decodeDPACK(
            responseFrame(command: "dp", payload: "0401"), expectedBoardID: 0
        ) == PaletteAcknowledgement(mode: .rotation, status: .unsupportedMode))
        #expect(throws: PaletteProtocolError.unsupportedEditableMode) {
            _ = try PaletteProtocolCodec.decodeDPACK(
                responseFrame(command: "dp", payload: "0400"), expectedBoardID: 0
            )
        }
    }

    @Test func signaturesTrackDirtyRevertUnknownRolesAndIgnoreDictionaryOrder() throws {
        let record = try #require(PaletteFactoryDefaults.record(for: .mode1))
        var draft = record.draft
        let baseline = try PalettePersistedSignature(record: record)
        #expect(try PalettePersistedSignature(draft: draft) == baseline)

        draft.roleValues[.date] = try RGB888(hex: "FF00FF")
        #expect(try PalettePersistedSignature(draft: draft) != baseline)
        draft.roleValues[.date] = record.roleValues[.date]
        #expect(try PalettePersistedSignature(draft: draft) == baseline)

        let valuesInReverseOrder = Dictionary(uniqueKeysWithValues: record.roleValues.sorted { $0.key > $1.key })
        let reordered = ModePaletteDraft(mode: .mode1, roleValues: valuesInReverseOrder)
        #expect(try PalettePersistedSignature(draft: reordered) == baseline)

        var unknownRecord = record
        unknownRecord = ModePaletteRecord(
            mode: unknownRecord.mode,
            roleValues: unknownRecord.roleValues,
            unknownRoleValues: [0x20: try RGB888(hex: "123456")]
        )
        #expect(try PalettePersistedSignature(record: unknownRecord).entries.last?.roleID == 0x20)
        #expect(try PalettePersistedSignature(draft: unknownRecord.draft) == PalettePersistedSignature(record: unknownRecord))
    }

    @MainActor
    @Test func newConnectionReadsModesSequentiallyAndPopulatesBaselines() async throws {
        let context = try await connectedPaletteContext()
        #expect(context.connection.sentFrames == [requestFrame("LP01")])
        #expect(context.viewModel.paletteReadState == .reading(mode: .mode1))

        await context.receive(factoryLPResponse(mode: .mode1))
        #expect(context.connection.sentFrames.last == requestFrame("LP02"))
        await context.receive(factoryLPResponse(mode: .mode2))
        #expect(context.connection.sentFrames.last == requestFrame("LP03"))
        await context.receive(factoryLPResponse(mode: .mode3))

        #expect(context.connection.sentFrames == [requestFrame("LP01"), requestFrame("LP02"), requestFrame("LP03")])
        #expect(context.viewModel.paletteRecords.count == 3)
        #expect(context.viewModel.paletteDrafts.count == 3)
        #expect(context.viewModel.paletteFeatureAvailability == .available)
        #expect(!context.viewModel.paletteDraftIsDirty(mode: .mode1))
    }

    @MainActor
    @Test func stalePaletteResponseFromReplacedConnectionIsIgnored() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let scheduler = PaletteFakeScheduler()
        let context = try await connectedPaletteContext(recorder: recorder, scheduler: scheduler)
        let staleReceive = try #require(context.connection.lastReceiveCompletion)

        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()

        staleReceive(Data(factoryLPResponse(mode: .mode1)), nil, false, nil)
        await paletteDrainMainQueue()
        #expect(context.viewModel.paletteRecords.isEmpty)
        #expect(replacement.sentFrames == [requestFrame("LP01")])

        let replacementReceive = try #require(replacement.lastReceiveCompletion)
        replacementReceive(Data(factoryLPResponse(mode: .mode1)), nil, false, nil)
        await paletteDrainMainQueue()
        #expect(context.viewModel.paletteRecords[.mode1] != nil)
    }

    @MainActor
    @Test func unsupportedPaletteFirmwareDoesNotDisconnectClock() async throws {
        let context = try await connectedPaletteContext()
        await context.receive(responseFrame(command: "lp", payload: "01010000"))

        #expect(context.viewModel.state == .connected)
        #expect(context.viewModel.isPaletteFeatureUnsupported)
        #expect(context.viewModel.paletteFeatureAvailability == .unsupported(
            ESP32ControllerViewModel.paletteUnsupportedFirmwareMessage
        ))
        #expect(context.connection.sentFrames == [requestFrame("LP01")])
        #expect(context.viewModel.lastPaletteError?.status == .unsupportedMode)
    }

    @MainActor
    @Test func paletteTimeoutMarksFeatureUnavailableWithoutDisconnecting() async throws {
        let scheduler = PaletteFakeScheduler()
        let context = try await connectedPaletteContext(scheduler: scheduler)
        context.connection.lastSendCompletion?(nil)
        await paletteDrainMainQueue()
        scheduler.firePaletteTimeout()
        await paletteDrainMainQueue()

        #expect(context.viewModel.state == .connected)
        #expect(context.viewModel.isPaletteFeatureUnsupported)
        #expect(context.viewModel.paletteReadState == .failed(mode: .mode1, message: "Palette read timed out."))
    }

    @MainActor
    @Test func saveOnlySendsDirtyCompletePaletteAndRereadsOnSuccess() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count
        let clean = try #require(context.viewModel.paletteDrafts[.mode1])
        #expect(!context.viewModel.canSaveSelectedPalette)
        context.viewModel.requestPaletteSave(.mode1, draft: clean)
        #expect(context.connection.sentFrames.count == startingCount)

        var changed = clean
        changed.roleValues[.date] = try RGB888(hex: "005CFF")
        context.viewModel.updatePaletteDraft(changed)
        #expect(context.viewModel.canSaveSelectedPalette)
        context.viewModel.requestPaletteSave(.mode1, draft: changed)
        let cpFrame = try PaletteProtocolCodec.makeCPRequest(boardID: 0, draft: changed)
        #expect(context.connection.sentFrames.last == cpFrame)
        #expect(context.viewModel.paletteSaveState == .saving(mode: .mode1))
        #expect(context.viewModel.isPaletteOperationPending)
        #expect(!context.viewModel.canSaveSelectedPalette)
        #expect(!context.viewModel.canRestoreSelectedPaletteDefaults)

        await context.receive(responseFrame(command: "cp", payload: "0100"))
        #expect(context.connection.sentFrames.last == requestFrame("LP01"))
        #expect(context.viewModel.paletteSaveState == .succeeded(mode: .mode1))

        await context.receive(factoryLPResponse(mode: .mode1, date: "005CFF"))
        #expect(context.viewModel.paletteRecords[.mode1]?.roleValues[.date]?.uppercaseHex == "005CFF")
        #expect(!context.viewModel.paletteDraftIsDirty(mode: .mode1))
    }

    @MainActor
    @Test func modeSwitchingPreservesIndependentUnsavedDraftsAndSendsNothing() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count
        var mode1Draft = try #require(context.viewModel.paletteDrafts[.mode1])
        mode1Draft.roleValues[.date] = try RGB888(hex: "FF00FF")
        context.viewModel.updatePaletteDraft(mode1Draft)

        context.viewModel.selectedPaletteMode = .mode2
        var mode2Draft = try #require(context.viewModel.paletteDrafts[.mode2])
        mode2Draft.roleValues[.time] = try RGB888(hex: "005CFF")
        context.viewModel.updatePaletteDraft(mode2Draft)
        context.viewModel.selectedPaletteMode = .mode1

        #expect(context.viewModel.paletteDrafts[.mode1] == mode1Draft)
        #expect(context.viewModel.paletteDrafts[.mode2] == mode2Draft)
        #expect(context.viewModel.paletteDraftIsDirty(mode: .mode1))
        #expect(context.viewModel.paletteDraftIsDirty(mode: .mode2))
        #expect(context.connection.sentFrames.count == startingCount)

        context.viewModel.updatePaletteDraft(try #require(context.viewModel.paletteRecords[.mode1]).draft)
        #expect(!context.viewModel.paletteDraftIsDirty(mode: .mode1))
        #expect(context.viewModel.paletteDraftIsDirty(mode: .mode2))
    }

    @MainActor
    @Test func requestSetDisplayModeSendsDirectSMAndConfirmsEachEditableMode() async throws {
        let context = try await loadedPaletteContext()

        for mode in PaletteMode.editableCases {
            context.viewModel.requestSetDisplayMode(mode)
            #expect(context.connection.sentFrames.last == requestFrame("SM\(mode.uppercaseHex)"))
            #expect(context.viewModel.setDisplayModeState == .sending(mode: mode))

            await context.receive(responseFrame(command: "sm", payload: "\(mode.uppercaseHex)00"))
            #expect(context.viewModel.setDisplayModeState == .succeeded(mode: mode))
            #expect(context.viewModel.confirmedDisplayMode == mode.rawValue)
            #expect(!context.viewModel.isDisplayModeSuccessAlertPresented)
        }
    }

    @MainActor
    @Test func paletteUserSelectionSendsOneDirectSMPerChangedModeAndNeverNMCPOrDP() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count

        context.viewModel.userSelectedPaletteMode(.mode2)
        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.connection.sentFrames.last == requestFrame("SM02"))
        await context.receive(responseFrame(command: "sm", payload: "0200"))

        context.viewModel.userSelectedPaletteMode(.mode3)
        #expect(context.viewModel.selectedPaletteMode == .mode3)
        #expect(context.connection.sentFrames.last == requestFrame("SM03"))
        await context.receive(responseFrame(command: "sm", payload: "0300"))

        context.viewModel.userSelectedPaletteMode(.mode1)
        #expect(context.viewModel.selectedPaletteMode == .mode1)
        #expect(context.connection.sentFrames.last == requestFrame("SM01"))
        await context.receive(responseFrame(command: "sm", payload: "0100"))

        let selectorFrames = Array(context.connection.sentFrames.dropFirst(startingCount))
        #expect(selectorFrames == [requestFrame("SM02"), requestFrame("SM03"), requestFrame("SM01")])
        #expect(selectorFrames.allSatisfy { String(bytes: $0[4...5], encoding: .ascii) == "SM" })
        #expect(!selectorFrames.contains(requestFrame("SM04")))
    }

    @MainActor
    @Test func sameOrProgrammaticPaletteModeSelectionDoesNotSendSM() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count

        _ = ColorPaletteSection(viewModel: context.viewModel)
        context.viewModel.userSelectedPaletteMode(.mode1)
        context.viewModel.selectedPaletteMode = .mode2

        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.connection.sentFrames.count == startingCount)
    }

    @MainActor
    @Test func pendingSMKeepsLatestLocalSelectionWithoutQueueingAnotherCommand() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count

        context.viewModel.userSelectedPaletteMode(.mode2)
        context.viewModel.userSelectedPaletteMode(.mode3)

        #expect(context.viewModel.selectedPaletteMode == .mode3)
        #expect(Array(context.connection.sentFrames.dropFirst(startingCount)) == [requestFrame("SM02")])
        #expect(context.viewModel.setDisplayModeState == .sending(mode: .mode2))

        await context.receive(responseFrame(command: "sm", payload: "0200"))
        #expect(context.viewModel.selectedPaletteMode == .mode3)
        #expect(context.viewModel.confirmedDisplayMode == PaletteMode.mode2.rawValue)
    }

    @MainActor
    @Test func disconnectedPaletteSelectionChangesEditingModeWithoutSendingSM() async throws {
        let context = try await loadedPaletteContext()
        context.viewModel.disconnect()
        let sentCount = context.connection.sentFrames.count

        context.viewModel.userSelectedPaletteMode(.mode2)

        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.connection.sentFrames.count == sentCount)
        #expect(context.viewModel.setDisplayModeState == .idle)
    }

    @MainActor
    @Test func smFailureIsNonDisconnectingAndPreservesPaletteDraftAndSelection() async throws {
        let context = try await loadedPaletteContext()
        var draft = try #require(context.viewModel.paletteDrafts[.mode2])
        draft.roleValues[.date] = try RGB888(hex: "005CFF")
        context.viewModel.updatePaletteDraft(draft)

        context.viewModel.userSelectedPaletteMode(.mode2)
        await context.receive(responseFrame(command: "sm", payload: "0204"))

        #expect(context.viewModel.state == .connected)
        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.viewModel.paletteDrafts[.mode2] == draft)
        #expect(context.viewModel.setDisplayModeState == .failed(
            mode: .mode2,
            message: "Could not change display mode. \(SetModeStatus.settingsSaveFailure.message)"
        ))
    }

    @MainActor
    @Test func smTimeoutFailsSafelyClearsPendingAndAllowsAnotherBoundedRequest() async throws {
        let context = try await loadedPaletteContext()
        context.viewModel.requestSetDisplayMode(.mode2)
        context.connection.lastSendCompletion?(nil)
        await paletteDrainMainQueue()
        #expect(context.viewModel.setDisplayModeState == .waitingForConfirmation(mode: .mode2))

        context.scheduler.fireSetModeTimeout()
        await paletteDrainMainQueue()
        #expect(context.viewModel.state == .connected)
        #expect(context.viewModel.setDisplayModeState == .failed(
            mode: .mode2,
            message: "Display mode change not confirmed."
        ))

        context.viewModel.requestSetDisplayMode(.mode3)
        #expect(context.connection.sentFrames.last == requestFrame("SM03"))
        #expect(context.viewModel.setDisplayModeState == .sending(mode: .mode3))
    }

    @MainActor
    @Test func staleSMResponseIsIgnoredAndDisconnectOrAuthorizationLossClearsPendingSM() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let context = try await loadedPaletteContext(recorder: recorder)
        context.viewModel.requestSetDisplayMode(.mode2)
        let staleReceive = try #require(context.connection.lastReceiveCompletion)

        context.viewModel.disconnect()
        #expect(context.viewModel.setDisplayModeState == .idle)
        staleReceive(Data(responseFrame(command: "sm", payload: "0200")), nil, false, nil)
        await paletteDrainMainQueue()
        #expect(context.viewModel.confirmedDisplayMode == nil)

        context.viewModel.authorizeNetworking()
        context.viewModel.manualBoardID = "0"
        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()
        for mode in PaletteMode.editableCases {
            guard let receive = replacement.lastReceiveCompletion else {
                Issue.record("Missing replacement receive callback")
                return
            }
            receive(Data(factoryLPResponse(mode: mode)), nil, false, nil)
            await paletteDrainMainQueue()
        }
        context.viewModel.requestSetDisplayMode(.mode3)
        #expect(context.viewModel.setDisplayModeState == .sending(mode: .mode3))
        context.viewModel.revokeNetworkingAuthorization()
        #expect(context.viewModel.setDisplayModeState == .idle)
    }

    @MainActor
    @Test func rmLoadsEditableSelectorWithoutSendingSMAndKeepsModeFourInternal() async throws {
        let context = try await loadedPaletteContext()
        let startingCount = context.connection.sentFrames.count

        context.viewModel.requestCurrentDisplayMode()
        #expect(context.connection.sentFrames.last == requestFrame("RM"))
        await context.receive(responseFrame(command: "rm", payload: "0200"))

        #expect(context.viewModel.confirmedDisplayMode == 2)
        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.viewModel.readDisplayModeState == .loaded(mode: 2))
        #expect(context.connection.sentFrames.count == startingCount + 1)
        #expect(context.connection.sentFrames.allSatisfy { frameCommand($0) != "SM" })

        context.viewModel.requestCurrentDisplayMode()
        await context.receive(responseFrame(command: "rm", payload: "0400"))
        #expect(context.viewModel.confirmedDisplayMode == 4)
        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.connection.sentFrames.allSatisfy { frameCommand($0) != "SM" })
    }

    @MainActor
    @Test func rmFailureDoesNotDisconnectAndDisconnectClearsPendingRead() async throws {
        let context = try await loadedPaletteContext()
        context.viewModel.requestCurrentDisplayMode()
        await context.receive(responseFrame(command: "rm", payload: "000A"))

        #expect(context.viewModel.state == .connected)
        if case .failed = context.viewModel.readDisplayModeState {
        } else {
            Issue.record("RM failure should remain a non-disconnecting operation error")
        }

        context.viewModel.requestCurrentDisplayMode()
        #expect(context.viewModel.readDisplayModeState == .loading)
        context.viewModel.disconnect()
        await paletteDrainMainQueue()
        #expect(context.viewModel.readDisplayModeState == .idle)
    }

    @MainActor
    @Test func staleRMResponseIsIgnoredAndAuthorizationLossClearsPendingRead() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let context = try await loadedPaletteContext(recorder: recorder)
        context.viewModel.requestCurrentDisplayMode()
        let staleReceive = try #require(context.connection.lastReceiveCompletion)

        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()

        staleReceive(Data(responseFrame(command: "rm", payload: "0300")), nil, false, nil)
        await paletteDrainMainQueue()
        #expect(context.viewModel.confirmedDisplayMode == nil)
        #expect(context.viewModel.selectedPaletteMode == .mode1)
        #expect(replacement.sentFrames == [requestFrame("LP01")])

        context.viewModel.requestCurrentDisplayMode()
        #expect(context.viewModel.readDisplayModeState == .loading)
        context.viewModel.revokeNetworkingAuthorization()
        await paletteDrainMainQueue()
        #expect(context.viewModel.readDisplayModeState == .idle)
        #expect(context.viewModel.state == .disconnected)
    }

    @MainActor
    @Test func saveFailurePreservesDraftAndRecordsMeaningfulStatus() async throws {
        let context = try await loadedPaletteContext()
        var changed = try #require(context.viewModel.paletteDrafts[.mode1])
        changed.roleValues[.date] = try RGB888(hex: "FF00FF")
        context.viewModel.requestPaletteSave(changed)
        await context.receive(responseFrame(command: "cp", payload: "0108"))

        #expect(context.viewModel.paletteDrafts[.mode1] == changed)
        #expect(context.viewModel.paletteRecords[.mode1]?.roleValues[.date]?.uppercaseHex == "00FF00")
        #expect(context.viewModel.paletteSaveState == .failed(mode: .mode1, message: PaletteStatus.nvsFailure.message))
        #expect(context.viewModel.lastPaletteError?.status == .nvsFailure)
    }

    @MainActor
    @Test func restoreDefaultsRereadsOnSuccessAndPreservesStateOnFailure() async throws {
        let context = try await loadedPaletteContext()
        let baseline = context.viewModel.paletteRecords[.mode1]
        context.viewModel.requestPaletteRestoreDefaults(.mode1)
        #expect(context.connection.sentFrames.last == requestFrame("DP01"))
        await context.receive(responseFrame(command: "dp", payload: "0108"))
        #expect(context.viewModel.paletteRecords[.mode1] == baseline)
        #expect(context.viewModel.paletteDefaultRestoreState == .failed(
            mode: .mode1,
            message: PaletteStatus.nvsFailure.message
        ))

        context.viewModel.requestPaletteRestoreDefaults(.mode1)
        await context.receive(responseFrame(command: "dp", payload: "0100"))
        #expect(context.connection.sentFrames.last == requestFrame("LP01"))
        await context.receive(factoryLPResponse(mode: .mode1))
        #expect(context.viewModel.paletteRecords[.mode1] == PaletteFactoryDefaults.record(for: .mode1))
    }

    @MainActor
    @Test func disconnectAndAuthorizationLossClearPaletteTransactions() async throws {
        let first = try await connectedPaletteContext()
        first.viewModel.disconnect()
        await paletteDrainMainQueue()
        #expect(first.viewModel.paletteReadState == .idle)
        #expect(first.viewModel.paletteRecords.isEmpty)
        first.scheduler.firePaletteTimeout()
        await paletteDrainMainQueue()
        #expect(first.viewModel.paletteReadState == .idle)

        let second = try await connectedPaletteContext()
        second.viewModel.revokeNetworkingAuthorization()
        await paletteDrainMainQueue()
        #expect(second.viewModel.paletteReadState == .idle)
        #expect(second.viewModel.paletteRecords.isEmpty)
        #expect(second.viewModel.state == .disconnected)
    }

    @MainActor
    @Test func factoryResetInvalidatesPaletteBaselineWithoutRacingImmediateRead() async throws {
        let context = try await loadedPaletteContext()
        let countBeforeReset = context.connection.sentFrames.count
        context.viewModel.requestDeviceReset(resetID: 0x00)
        #expect(context.connection.sentFrames.last == [0x2F, 0x54, 0x41, 0x00, 0x52, 0x54, 0x00, 0x5C])
        context.connection.lastSendCompletion?(nil)
        await paletteDrainMainQueue()

        #expect(context.viewModel.paletteRecords.isEmpty)
        #expect(context.viewModel.paletteDrafts.isEmpty)
        #expect(context.viewModel.paletteFeatureAvailability == .unknown)
        #expect(context.connection.sentFrames.count == countBeforeReset + 1)
    }

    @Test func rcCodecDecodesFormatAndFirmwareCompatibleBrightnessLevels() throws {
        let twelveHour = try ClockConfigurationProtocolCodec.decodeRCResponse(
            rcResponse(is24Hour: false, intensity: 0x7F),
            expectedBoardID: 0
        )
        let twentyFourHour = try ClockConfigurationProtocolCodec.decodeRCResponse(
            rcResponse(is24Hour: true, intensity: 0xFF),
            expectedBoardID: 0
        )

        #expect(!twelveHour.is24HourFormat)
        #expect(twelveHour.brightnessLevel == 5)
        #expect(twentyFourHour.is24HourFormat)
        #expect(twentyFourHour.brightnessLevel == 10)
        #expect(ClockConfigurationReadback.brightnessLevel(forProtocolIntensity: 0) == 1)
        for level in UInt8(1)...UInt8(10) {
            let intensity = UInt8((Int(level) * 255) / 10)
            #expect(ClockConfigurationReadback.brightnessLevel(forProtocolIntensity: intensity) == level)
        }
    }

    @Test func rcCodecRejectsMalformedEnvelopeAndFormat() {
        #expect(throws: ClockConfigurationProtocolError.invalidLength) {
            _ = try ClockConfigurationProtocolCodec.decodeRCResponse(
                Array(rcResponse().dropLast()),
                expectedBoardID: 0
            )
        }

        var wrongCommand = rcResponse()
        wrongCommand[5] = 0x78
        #expect(throws: ClockConfigurationProtocolError.invalidCommand) {
            _ = try ClockConfigurationProtocolCodec.decodeRCResponse(wrongCommand, expectedBoardID: 0)
        }

        var invalidFormat = rcResponse()
        invalidFormat[7] = 0x02
        #expect(throws: ClockConfigurationProtocolError.invalidTimeFormat) {
            _ = try ClockConfigurationProtocolCodec.decodeRCResponse(invalidFormat, expectedBoardID: 0)
        }
    }

    @Test func alarmSectionDoesNotExposeManualReadButton() {
        #expect(!AlarmSectionPresentation.showsManualReadButton)
    }

    @MainActor
    @Test func connectionAutoLoadsPalettesThenModeSettingsAndAllAlarmsSequentially() async throws {
        let context = try await connectedPaletteContext(automaticallyLoadsClockStateOnConnect: true)
        #expect(context.connection.sentFrames == [requestFrame("LP01")])

        for mode in PaletteMode.editableCases {
            await context.receive(factoryLPResponse(mode: mode))
        }

        #expect(context.connection.sentFrames == [
            requestFrame("LP01"), requestFrame("LP02"), requestFrame("LP03"), requestFrame("RM")
        ])
        #expect(context.viewModel.readDisplayModeState == .loading)

        await context.receive(responseFrame(command: "rm", payload: "0200"))
        #expect(context.viewModel.confirmedDisplayMode == 2)
        #expect(context.viewModel.selectedPaletteMode == .mode2)
        #expect(context.connection.sentFrames.last == requestFrame("RC"))
        #expect(context.viewModel.clockConfigurationReadState == .loading)

        await context.receive(rcResponse(is24Hour: false, intensity: 0x7F))
        #expect(!context.viewModel.is24HourFormat)
        #expect(context.viewModel.brightnessLevel == 5)
        #expect(context.viewModel.clockConfigurationReadState == .loaded)
        #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: 1))

        for alarmID in AlarmRecord.validIDRange {
            #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: UInt8(alarmID)))
            await context.receive(automaticLAResponse(alarmID: UInt8(alarmID)))
        }

        #expect(context.viewModel.alarmReadOperationState == .completed(successful: 60, failed: 0))
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)
        #expect(context.viewModel.alarmRecords.allSatisfy { $0.readState == .loaded })
        #expect(context.connection.sentFrames.filter { frameCommand($0) == "LA" }.count == 60)
        #expect(context.connection.sentFrames.filter {
            ["ES", "CA", "DA", "CT", "SM", "NM"].contains(frameCommand($0))
        }.isEmpty)
    }

    @MainActor
    @Test func sameDeviceReconnectPreservesAlarmGridAndSkipsAutomaticLA() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let context = try await automaticAlarmLoadedContext(recorder: recorder)
        let loadedRecords = context.viewModel.alarmRecords
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)

        context.viewModel.handleAppEnteredBackground()
        context.connection.stateUpdateHandler?(.cancelled)
        await paletteDrainMainQueue()
        #expect(context.viewModel.alarmRecords == loadedRecords)
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)

        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()
        for mode in PaletteMode.editableCases {
            await receive(factoryLPResponse(mode: mode), on: replacement)
        }
        await receive(responseFrame(command: "rm", payload: "0300"), on: replacement)
        await receive(rcResponse(), on: replacement)

        #expect(context.viewModel.alarmRecords == loadedRecords)
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)
        #expect(replacement.sentFrames.filter { frameCommand($0) == "LA" }.isEmpty)
    }

    @MainActor
    @Test func differentDeviceInvalidatesAlarmCacheAndStartsFreshAutomaticLA() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let context = try await automaticAlarmLoadedContext(recorder: recorder)
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)

        context.viewModel.disconnect()
        context.connection.stateUpdateHandler?(.cancelled)
        await paletteDrainMainQueue()
        context.viewModel.host = "192.168.4.2"
        context.viewModel.manualBoardID = "1"
        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()

        #expect(!context.viewModel.hasLoadedAlarmsForCurrentDevice)
        #expect(context.viewModel.alarmRecords.allSatisfy { $0.readState == .notLoaded })
        for mode in PaletteMode.editableCases {
            await receive(factoryLPResponse(mode: mode, boardID: 1), on: replacement)
        }
        await receive(responseFrame(command: "rm", payload: "0100", boardID: 1), on: replacement)
        await receive(rcResponse(boardID: 1), on: replacement)

        #expect(replacement.sentFrames.last == alarmRequestFrame(alarmID: 1, boardID: 1))
        #expect(!context.viewModel.hasLoadedAlarmsForCurrentDevice)
    }

    @MainActor
    @Test func partialAutomaticAlarmReadNeverMarksCacheValid() async throws {
        let context = try await automaticRCReadContext()
        await context.receive(rcResponse())
        #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: 1))

        context.connection.lastSendCompletion?(.posix(.EIO))
        await paletteDrainMainQueue()
        #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: 2))
        for alarmID in 2...AlarmRecord.maximumAlarmCount {
            await context.receive(automaticLAResponse(alarmID: UInt8(alarmID)))
        }

        #expect(context.viewModel.alarmReadOperationState == .completed(successful: 59, failed: 1))
        #expect(!context.viewModel.hasLoadedAlarmsForCurrentDevice)
    }

    @MainActor
    @Test func factoryResetInvalidatesLoadedAlarmCacheWithoutImmediateLARead() async throws {
        let context = try await automaticAlarmLoadedContext()
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)
        let alarmsBeforeReset = context.viewModel.alarmRecords
        let alarmReadsBeforeReset = context.connection.sentFrames.filter { frameCommand($0) == "LA" }.count

        context.viewModel.requestDeviceReset(resetID: 0x00)
        context.connection.lastSendCompletion?(nil)
        await paletteDrainMainQueue()

        #expect(!context.viewModel.hasLoadedAlarmsForCurrentDevice)
        #expect(context.viewModel.alarmRecords == alarmsBeforeReset)
        #expect(context.connection.sentFrames.filter { frameCommand($0) == "LA" }.count == alarmReadsBeforeReset)
    }

    @MainActor
    @Test func successfulAlarmSaveAndDeleteKeepLoadedCacheValid() async throws {
        let context = try await automaticAlarmLoadedContext()
        var draft = AlarmDraft(record: context.viewModel.alarmRecords[0])
        draft.minute = (draft.minute + 1) % 60
        context.viewModel.sendAlarm(draft)
        await context.receive([0x2F, 0x74, 0x61, 0x00, 0x63, 0x61, 0x01, 0x5C])
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)

        context.viewModel.selectAlarm(id: 1)
        let deleteDraft = try #require(context.viewModel.alarmEditorDraft)
        context.viewModel.deleteAlarm(deleteDraft)
        await context.receive([0x2F, 0x74, 0x61, 0x00, 0x64, 0x61, 0x01, 0x5C])
        #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)
        #expect(context.viewModel.alarmRecords[0] == AlarmRecord.emptyLoadedRecord(id: 1))
    }

    @MainActor
    @Test func rcAutoLoadDoesNotWriteCTBackToClock() async throws {
        let context = try await automaticRCReadContext()
        let beforeResponse = context.connection.sentFrames.count

        await context.receive(rcResponse(is24Hour: false, intensity: 0xCC))

        #expect(!context.viewModel.is24HourFormat)
        #expect(context.viewModel.brightnessLevel == 8)
        #expect(context.connection.sentFrames.dropFirst(beforeResponse).first == alarmRequestFrame(alarmID: 1))
        #expect(context.connection.sentFrames.allSatisfy { frameCommand($0) != "CT" })
    }

    @MainActor
    @Test func malformedRCAutoLoadContinuesToAlarmsWithoutDisconnecting() async throws {
        let context = try await automaticRCReadContext()
        var malformed = rcResponse()
        malformed[7] = 0x02

        await context.receive(malformed)

        #expect(context.viewModel.state == .connected)
        if case .failed = context.viewModel.clockConfigurationReadState {
        } else {
            Issue.record("Malformed RC should expose a non-disconnecting read failure")
        }
        #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: 1))
    }

    @MainActor
    @Test func userClockControlEditsWinOverPendingRCAutoLoad() async throws {
        let context = try await automaticRCReadContext()
        context.viewModel.userSelectedTimeFormat(false)
        context.viewModel.brightnessEditingChanged(true)
        context.viewModel.brightnessLevel = 9
        context.viewModel.brightnessEditingChanged(false)

        await context.receive(rcResponse(is24Hour: true, intensity: 0x19))

        #expect(!context.viewModel.is24HourFormat)
        #expect(context.viewModel.brightnessLevel == 9)
        #expect(context.connection.sentFrames.filter { frameCommand($0) == "CT" }.count == 2)
    }

    @MainActor
    @Test func rcTimeoutContinuesToAlarmsWithoutDisconnecting() async throws {
        let scheduler = PaletteFakeScheduler()
        let context = try await automaticRCReadContext(scheduler: scheduler)
        context.connection.lastSendCompletion?(nil)
        await paletteDrainMainQueue()
        scheduler.fireClockConfigurationTimeout()
        await paletteDrainMainQueue()

        #expect(context.viewModel.state == .connected)
        if case .failed = context.viewModel.clockConfigurationReadState {
        } else {
            Issue.record("RC timeout should expose a non-disconnecting read failure")
        }
        #expect(context.connection.sentFrames.last == alarmRequestFrame(alarmID: 1))
    }

    @MainActor
    @Test func staleRCAutoLoadResponseIsIgnoredAfterConnectionReplacement() async throws {
        let recorder = PaletteFakeTCPConnectionRecorder()
        let scheduler = PaletteFakeScheduler()
        let context = try await automaticRCReadContext(recorder: recorder, scheduler: scheduler)
        let staleReceive = try #require(context.connection.lastReceiveCompletion)

        context.viewModel.connect()
        await paletteDrainMainQueue()
        let replacement = try #require(recorder.connections.last)
        replacement.stateUpdateHandler?(.ready)
        await paletteDrainMainQueue()

        staleReceive(Data(rcResponse(is24Hour: false, intensity: 0xFF)), nil, false, nil)
        await paletteDrainMainQueue()

        #expect(context.viewModel.is24HourFormat)
        #expect(context.viewModel.brightnessLevel == 5)
        #expect(replacement.sentFrames == [requestFrame("LP01")])
    }

    @MainActor
    @Test func disconnectClearsPendingAutomaticRCAndAlarmReads() async throws {
        let rcContext = try await automaticRCReadContext()
        rcContext.viewModel.disconnect()
        await paletteDrainMainQueue()
        #expect(rcContext.viewModel.clockConfigurationReadState == .idle)

        let alarmContext = try await automaticRCReadContext()
        await alarmContext.receive(rcResponse())
        #expect(alarmContext.viewModel.alarmReadOperationState.isReading)
        alarmContext.viewModel.disconnect()
        await paletteDrainMainQueue()
        #expect(alarmContext.viewModel.alarmReadOperationState == .interrupted(successful: 0, failed: 0))

        let unauthorizedContext = try await automaticRCReadContext()
        unauthorizedContext.viewModel.revokeNetworkingAuthorization()
        await paletteDrainMainQueue()
        #expect(unauthorizedContext.viewModel.clockConfigurationReadState == .idle)
        #expect(unauthorizedContext.viewModel.state == .disconnected)
    }
}

private func requestFrame(_ commandAndPayload: String, boardID: UInt8 = 0) -> [UInt8] {
    [0x2F, 0x54, 0x41, boardID] + Array(commandAndPayload.utf8) + [0x5C]
}

private func responseFrame(command: String, payload: String, boardID: UInt8 = 0) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID] + Array(command.utf8) + Array(payload.utf8) + [0x5C]
}

private func alarmRequestFrame(alarmID: UInt8, boardID: UInt8 = 0) -> [UInt8] {
    [0x2F, 0x54, 0x41, boardID, 0x4C, 0x41, alarmID, 0x5C]
}

private func frameCommand(_ frame: [UInt8]) -> String {
    guard frame.count >= 6 else {
        return ""
    }
    return String(bytes: frame[4...5], encoding: .ascii) ?? ""
}

private func rcResponse(
    boardID: UInt8 = 0,
    is24Hour: Bool = true,
    intensity: UInt8 = 0x7F
) -> [UInt8] {
    [
        0x2F, 0x74, 0x61, boardID, 0x72, 0x63,
        0x01, is24Hour ? 0x01 : 0x00, intensity,
        0x05, 0x04, 0x03, 0x02, 0x01, 0x07, 0x1A,
        0x5C
    ]
}

private func automaticLAResponse(boardID: UInt8 = 0, alarmID: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x6C, 0x61, alarmID, 0x07, 0x1E, 0xBE, 0x43, 0x5C]
}

private func factoryLPResponse(
    mode: PaletteMode,
    date: String? = nil,
    boardID: UInt8 = 0
) -> [UInt8] {
    let date = date ?? (mode == .mode1 ? "00FF00" : "0000FF")
    let weekday = mode == .mode3 ? "0300FF00" : ""
    let count = mode == .mode3 ? "07" : "06"
    let entries = "01FFFFFF02\(date)\(weekday)10FFFFFF1100FFFF12FF410013FF0000"
    return responseFrame(
        command: "lp",
        payload: "\(mode.uppercaseHex)00" + "01\(count)\(entries)",
        boardID: boardID
    )
}

@MainActor
private struct PaletteTestContext {
    let viewModel: ESP32ControllerViewModel
    let connection: PaletteFakeTCPConnection
    let scheduler: PaletteFakeScheduler

    func receive(_ frame: [UInt8]) async {
        guard let receive = connection.lastReceiveCompletion else {
            Issue.record("Missing TCP receive callback")
            return
        }
        receive(Data(frame), nil, false, nil)
        await paletteDrainMainQueue()
    }
}

@MainActor
private func connectedPaletteContext(
    recorder: PaletteFakeTCPConnectionRecorder = PaletteFakeTCPConnectionRecorder(),
    scheduler: PaletteFakeScheduler = PaletteFakeScheduler(),
    automaticallyLoadsClockStateOnConnect: Bool = false
) async throws -> PaletteTestContext {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() },
        heartbeatScheduler: scheduler.schedule(_:_:),
        heartbeatACKTimeoutScheduler: scheduler.schedule(_:_:)
    )
    let viewModel = ESP32ControllerViewModel(
        client: client,
        timeSyncScheduler: scheduler.schedule(_:_:),
        automaticallyReadsPalettesOnConnect: true,
        automaticallyLoadsClockStateOnConnect: automaticallyLoadsClockStateOnConnect
    )
    viewModel.authorizeNetworking()
    viewModel.manualBoardID = "0"
    viewModel.connect()
    await paletteDrainMainQueue()
    let connection = try #require(recorder.connections.first)
    connection.stateUpdateHandler?(.ready)
    await paletteDrainMainQueue()
    return PaletteTestContext(viewModel: viewModel, connection: connection, scheduler: scheduler)
}

@MainActor
private func automaticRCReadContext(
    recorder: PaletteFakeTCPConnectionRecorder = PaletteFakeTCPConnectionRecorder(),
    scheduler: PaletteFakeScheduler = PaletteFakeScheduler()
) async throws -> PaletteTestContext {
    let context = try await connectedPaletteContext(
        recorder: recorder,
        scheduler: scheduler,
        automaticallyLoadsClockStateOnConnect: true
    )
    for mode in PaletteMode.editableCases {
        await context.receive(factoryLPResponse(mode: mode))
    }
    #expect(context.connection.sentFrames.last == requestFrame("RM"))
    await context.receive(responseFrame(command: "rm", payload: "0100"))
    #expect(context.connection.sentFrames.last == requestFrame("RC"))
    return context
}

@MainActor
private func automaticAlarmLoadedContext(
    recorder: PaletteFakeTCPConnectionRecorder = PaletteFakeTCPConnectionRecorder(),
    scheduler: PaletteFakeScheduler = PaletteFakeScheduler()
) async throws -> PaletteTestContext {
    let context = try await automaticRCReadContext(recorder: recorder, scheduler: scheduler)
    await context.receive(rcResponse())
    for alarmID in AlarmRecord.validIDRange {
        await context.receive(automaticLAResponse(alarmID: UInt8(alarmID)))
    }
    #expect(context.viewModel.hasLoadedAlarmsForCurrentDevice)
    return context
}

@MainActor
private func loadedPaletteContext(
    recorder: PaletteFakeTCPConnectionRecorder = PaletteFakeTCPConnectionRecorder(),
    scheduler: PaletteFakeScheduler = PaletteFakeScheduler()
) async throws -> PaletteTestContext {
    let context = try await connectedPaletteContext(recorder: recorder, scheduler: scheduler)
    for mode in PaletteMode.editableCases {
        await context.receive(factoryLPResponse(mode: mode))
    }
    return context
}

@MainActor
private func paletteDrainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
private func receive(_ frame: [UInt8], on connection: PaletteFakeTCPConnection) async {
    guard let callback = connection.lastReceiveCompletion else {
        Issue.record("Missing TCP receive callback")
        return
    }
    callback(Data(frame), nil, false, nil)
    await paletteDrainMainQueue()
}

private final class PaletteFakeTCPConnectionRecorder: @unchecked Sendable {
    var connections: [PaletteFakeTCPConnection] = []

    func makeConnection() -> PaletteFakeTCPConnection {
        let connection = PaletteFakeTCPConnection()
        connections.append(connection)
        return connection
    }
}

private final class PaletteFakeScheduler: @unchecked Sendable {
    var tasks: [PaletteFakeScheduledTask] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = PaletteFakeScheduledTask(delay: delay, callback: callback)
        tasks.append(task)
        return task
    }

    func firePaletteTimeout() {
        tasks.last {
            !$0.isCancelled && $0.delay == ESP32ControllerViewModel.paletteTransactionTimeout
        }?.fire()
    }

    func fireSetModeTimeout() {
        tasks.last {
            !$0.isCancelled && $0.delay == ESP32ControllerViewModel.setDisplayModeConfirmationTimeout
        }?.fire()
    }

    func fireClockConfigurationTimeout() {
        tasks.last {
            !$0.isCancelled && $0.delay == ESP32ControllerViewModel.clockConfigurationReadTimeout
        }?.fire()
    }

}

private final class PaletteFakeScheduledTask: CancellableTask, @unchecked Sendable {
    let delay: TimeInterval
    let callback: @Sendable () -> Void
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

private final class PaletteFakeTCPConnection: TCPConnection, @unchecked Sendable {
    typealias ReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var lastReceiveCompletion: ReceiveCompletion?
    var lastSendCompletion: ((NWError?) -> Void)?
    var sentContents: [Data?] = []

    var sentFrames: [[UInt8]] {
        sentContents.compactMap { $0.map(Array.init) }
    }

    func start(queue: DispatchQueue) {}

    func cancel() {}

    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    ) {
        sentContents.append(content)
        if case let .contentProcessed(sendCompletion) = completion {
            lastSendCompletion = sendCompletion
        }
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping ReceiveCompletion
    ) {
        lastReceiveCompletion = completion
    }
}
