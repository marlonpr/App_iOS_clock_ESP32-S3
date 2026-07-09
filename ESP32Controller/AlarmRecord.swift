//
//  AlarmRecord.swift
//  ESP32Controller
//
//  Created by Codex on 07/07/26.
//

import Foundation

enum AlarmWeekday: Int, CaseIterable, Identifiable, Comparable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    var id: Int { rawValue }

    var frequencyMask: UInt8 {
        switch self {
        case .sunday:
            0x40
        case .monday:
            0x20
        case .tuesday:
            0x10
        case .wednesday:
            0x08
        case .thursday:
            0x04
        case .friday:
            0x02
        case .saturday:
            0x01
        }
    }

    var compactLabel: String {
        switch self {
        case .monday:
            "L"
        case .tuesday:
            "M"
        case .wednesday:
            "X"
        case .thursday:
            "J"
        case .friday:
            "V"
        case .saturday:
            "S"
        case .sunday:
            "D"
        }
    }

    var accessibilityName: String {
        switch self {
        case .monday:
            "Lunes"
        case .tuesday:
            "Martes"
        case .wednesday:
            "Miércoles"
        case .thursday:
            "Jueves"
        case .friday:
            "Viernes"
        case .saturday:
            "Sábado"
        case .sunday:
            "Domingo"
        }
    }

    static let mondayThroughFriday: Set<AlarmWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let mondayThroughSaturday: Set<AlarmWeekday> = mondayThroughFriday.union([.saturday])
    static let everyDay: Set<AlarmWeekday> = Set(allCases)

    static func < (lhs: AlarmWeekday, rhs: AlarmWeekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AlarmEffect: RawRepresentable, Hashable, Identifiable {
    enum Known: UInt8, CaseIterable {
        case continuous = 0
        case intermittent = 1
        case continuousBlink = 2
        case intermittentBlink = 3

        var displayName: String {
            switch self {
            case .continuous:
                "Continuo"
            case .intermittent:
                "Intermitente"
            case .continuousBlink:
                "Parpadeo continuo"
            case .intermittentBlink:
                "Parpadeo intermitente"
            }
        }
    }

    let rawValue: UInt8

    var id: UInt8 { rawValue }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ known: Known) {
        self.rawValue = known.rawValue
    }

    var known: Known? {
        Known(rawValue: rawValue)
    }

    var isSupported: Bool {
        known != nil
    }

    var displayName: String {
        known?.displayName ?? "Unknown effect \(rawValue)"
    }

    static let continuous = AlarmEffect(.continuous)
    static let intermittent = AlarmEffect(.intermittent)
    static let continuousBlink = AlarmEffect(.continuousBlink)
    static let intermittentBlink = AlarmEffect(.intermittentBlink)
    static let supported: [AlarmEffect] = Known.allCases.map(AlarmEffect.init)
}

enum AlarmReadState: Equatable {
    case notLoaded
    case loading
    case loaded
    case failed(String)

    var accessibilityValue: String {
        switch self {
        case .notLoaded:
            "not loaded"
        case .loading:
            "loading"
        case .loaded:
            "loaded"
        case .failed:
            "read failed"
        }
    }
}

struct AlarmRecord: Identifiable, Equatable {
    static let maximumAlarmCount = 60
    static let validIDRange = 1...maximumAlarmCount

    let id: Int
    var hour: Int
    var minute: Int
    var weekdays: Set<AlarmWeekday>
    var durationSeconds: Int
    var effect: AlarmEffect
    var isConfigured: Bool
    var isEnabled: Bool
    var readState: AlarmReadState
    var rawFrequency: UInt8
    var rawDurationEffect: UInt8

    init(
        id: Int,
        hour: Int = 0,
        minute: Int = 0,
        weekdays: Set<AlarmWeekday> = [],
        durationSeconds: Int = 1,
        effect: AlarmEffect = .continuous,
        isConfigured: Bool = false,
        isEnabled: Bool = false,
        readState: AlarmReadState = .notLoaded,
        rawFrequency: UInt8 = 0,
        rawDurationEffect: UInt8 = 0
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.durationSeconds = durationSeconds
        self.effect = effect
        self.isConfigured = isConfigured
        self.isEnabled = isEnabled
        self.readState = readState
        self.rawFrequency = rawFrequency
        self.rawDurationEffect = rawDurationEffect
    }

    var isLoaded: Bool {
        readState == .loaded
    }

    var weekdaySummary: String {
        let ordered = weekdays.sorted()
        guard !ordered.isEmpty else {
            return "No days"
        }

        if weekdays == AlarmWeekday.everyDay {
            return "L-D"
        }

        if weekdays == AlarmWeekday.mondayThroughFriday {
            return "L-V"
        }

        if weekdays == AlarmWeekday.mondayThroughSaturday {
            return "L-S"
        }

        return ordered.map(\.compactLabel).joined(separator: " ")
    }

    var accessibilityValue: String {
        switch readState {
        case .notLoaded:
            "not loaded"
        case .loading:
            "loading"
        case .loaded:
            if !isConfigured {
                "not configured"
            } else {
                isEnabled ? "configured and enabled" : "configured and disabled"
            }
        case .failed:
            "read failed"
        }
    }

    static func makeDefaultRecords() -> [AlarmRecord] {
        validIDRange.map { AlarmRecord(id: $0) }
    }

    static func emptyLoadedRecord(id: Int) -> AlarmRecord {
        AlarmRecord(
            id: id,
            hour: 0,
            minute: 0,
            weekdays: [],
            durationSeconds: 1,
            effect: .continuous,
            isConfigured: false,
            isEnabled: false,
            readState: .loaded,
            rawFrequency: 0,
            rawDurationEffect: 0
        )
    }
}

struct AlarmDraft: Identifiable, Equatable {
    let id: Int
    var hour: Int
    var minute: Int
    var weekdays: Set<AlarmWeekday>
    var durationSeconds: Int
    var effect: AlarmEffect
    var isConfigured: Bool
    var isEnabled: Bool
    var wasLoadedFromDevice: Bool
    var sourceRawFrequency: UInt8?
    var sourceRawDurationEffect: UInt8?
    var persistedBaselineSignature: AlarmPersistedSignature?

    init(record: AlarmRecord) {
        id = record.id
        hour = record.hour
        minute = record.minute
        weekdays = record.weekdays
        durationSeconds = record.durationSeconds
        effect = record.effect
        isConfigured = record.isConfigured
        isEnabled = record.isEnabled
        wasLoadedFromDevice = record.readState == .loaded
        sourceRawFrequency = record.readState == .loaded ? record.rawFrequency : nil
        sourceRawDurationEffect = record.readState == .loaded ? record.rawDurationEffect : nil
        if record.readState == .loaded && record.isConfigured {
            persistedBaselineSignature = try? AlarmProtocolCodec.persistedSignature(for: record)
        } else {
            persistedBaselineSignature = nil
        }

        if !wasLoadedFromDevice || !isConfigured {
            durationSeconds = 3
            effect = .continuous
        }
    }

    static func defaultDraft(id: Int) -> AlarmDraft {
        AlarmDraft(record: AlarmRecord(id: id))
    }

    func acknowledgedRecord(rawFrequency: UInt8, rawDurationEffect: UInt8) -> AlarmRecord {
        AlarmRecord(
            id: id,
            hour: hour,
            minute: minute,
            weekdays: weekdays,
            durationSeconds: durationSeconds,
            effect: effect,
            isConfigured: true,
            isEnabled: isEnabled,
            readState: .loaded,
            rawFrequency: rawFrequency,
            rawDurationEffect: rawDurationEffect
        )
    }

    var isValidForSend: Bool {
        AlarmRecord.validIDRange.contains(id) &&
            (0...23).contains(hour) &&
            (0...59).contains(minute) &&
            AlarmProtocolCodec.supportedDurationRange.contains(durationSeconds) &&
            effect.isSupported
    }

    var currentPersistedSignature: AlarmPersistedSignature? {
        try? AlarmProtocolCodec.persistedSignature(for: self)
    }

    var hasPersistedChanges: Bool {
        guard let persistedBaselineSignature else {
            return true
        }

        guard let currentPersistedSignature else {
            return true
        }

        return currentPersistedSignature != persistedBaselineSignature
    }
}

struct AlarmEditorSendEligibility: Equatable {
    let connectionAvailable: Bool
    let draftIsValid: Bool
    let hasPersistedChanges: Bool
    let sendInProgress: Bool
    let deleteInProgress: Bool

    var canSend: Bool {
        connectionAvailable &&
            draftIsValid &&
            hasPersistedChanges &&
            !sendInProgress &&
            !deleteInProgress
    }

    static func evaluate(
        draft: AlarmDraft,
        connectionAvailable: Bool,
        sendState: AlarmSendState,
        deleteState: AlarmDeleteState = .idle,
        hasPersistedChanges: Bool? = nil
    ) -> AlarmEditorSendEligibility {
        AlarmEditorSendEligibility(
            connectionAvailable: connectionAvailable,
            draftIsValid: draft.isValidForSend,
            hasPersistedChanges: hasPersistedChanges ?? draft.hasPersistedChanges,
            sendInProgress: sendState.isSending,
            deleteInProgress: deleteState.isDeleting
        )
    }
}

struct AlarmEditorDeleteEligibility: Equatable {
    let connectionAvailable: Bool
    let originalAlarmIsConfigured: Bool
    let sendInProgress: Bool
    let deleteInProgress: Bool

    var canDelete: Bool {
        connectionAvailable &&
            originalAlarmIsConfigured &&
            !sendInProgress &&
            !deleteInProgress
    }

    static func evaluate(
        draft: AlarmDraft,
        connectionAvailable: Bool,
        originalAlarmIsConfigured: Bool? = nil,
        sendState: AlarmSendState,
        deleteState: AlarmDeleteState
    ) -> AlarmEditorDeleteEligibility {
        AlarmEditorDeleteEligibility(
            connectionAvailable: connectionAvailable,
            originalAlarmIsConfigured: originalAlarmIsConfigured ?? (draft.wasLoadedFromDevice && draft.isConfigured),
            sendInProgress: sendState.isSending,
            deleteInProgress: deleteState.isDeleting
        )
    }
}

enum AlarmReadOperationState: Equatable {
    case idle
    case reading(currentID: Int?, completed: Int, total: Int)
    case completed(successful: Int, failed: Int)
    case interrupted(successful: Int, failed: Int)

    var isReading: Bool {
        if case .reading = self {
            return true
        }

        return false
    }

    var completedCount: Int {
        switch self {
        case .idle:
            0
        case let .reading(_, completed, _):
            completed
        case let .completed(successful, failed), let .interrupted(successful, failed):
            successful + failed
        }
    }

    var diagnosticsText: String {
        switch self {
        case .idle:
            "Idle"
        case .reading:
            "Reading"
        case .completed:
            "Complete"
        case .interrupted:
            "Interrupted"
        }
    }

    var progressText: String {
        switch self {
        case .idle:
            return "0/60"
        case let .reading(currentID, completed, total):
            if let currentID {
                return "Reading \(currentID) / \(total)"
            }

            return "Reading \(completed) / \(total)"
        case let .completed(successful, failed):
            return "\(successful + failed)/60"
        case let .interrupted(successful, failed):
            return "\(successful + failed)/60"
        }
    }
}

enum AlarmSendState: Equatable {
    case idle
    case sending(id: Int)
    case succeeded(id: Int)
    case failed(id: Int, message: String)

    var isSending: Bool {
        if case .sending = self {
            return true
        }

        return false
    }
}

enum AlarmDeleteState: Equatable {
    case idle
    case deleting(id: Int)
    case succeeded(id: Int)
    case failed(id: Int, message: String)

    var isDeleting: Bool {
        if case .deleting = self {
            return true
        }

        return false
    }
}
