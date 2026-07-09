//
//  AlarmEditorView.swift
//  ESP32Controller
//
//  Created by Codex on 07/07/26.
//

import SwiftUI

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AlarmDraft
    @State private var isDeleteConfirmationPresented = false

    let sendState: AlarmSendState
    let deleteState: AlarmDeleteState
    let canSend: Bool
    let canDelete: Bool
    let onSend: (AlarmDraft) -> Void
    let onDelete: (AlarmDraft) -> Void
    let onCancel: () -> Void

    init(
        initialDraft: AlarmDraft,
        sendState: AlarmSendState,
        deleteState: AlarmDeleteState,
        canSend: Bool,
        canDelete: Bool,
        onSend: @escaping (AlarmDraft) -> Void,
        onDelete: @escaping (AlarmDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: initialDraft)
        self.sendState = sendState
        self.deleteState = deleteState
        self.canSend = canSend
        self.canDelete = canDelete
        self.onSend = onSend
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                if !draft.wasLoadedFromDevice {
                    Section {
                        Label("This alarm has not been loaded from the CLOCK.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Time") {
                    DatePicker(
                        "Alarm Time",
                        selection: timeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.compact)
                }

                Section("Days") {
                    AlarmWeekdaySelector(weekdays: $draft.weekdays)
                }

                Section("Alarm") {
                    Toggle("Enabled", isOn: $draft.isEnabled)

                    Stepper(value: $draft.durationSeconds, in: AlarmProtocolCodec.supportedDurationRange) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(draft.durationSeconds) seconds")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Picker("Effect", selection: $draft.effect) {
                        if !draft.effect.isSupported {
                            Text(draft.effect.displayName).tag(draft.effect)
                        }

                        ForEach(AlarmEffect.supported) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                }

                Section {
                    AlarmEditorSendStatusView(
                        sendState: sendState,
                        deleteState: deleteState,
                        alarmID: draft.id,
                        sendEligibility: sendEligibility,
                        deleteEligibility: deleteEligibility
                    )

                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if sendState == .sending(id: draft.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Send")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)

                    Divider()
                        .padding(.vertical, 4)

                    Button(role: .destructive) {
                        requestDeleteConfirmation()
                    } label: {
                        HStack {
                            Spacer()
                            if deleteState == .deleting(id: draft.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Delete Alarm")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canDeleteAlarm)
                }
            }
            .navigationTitle("Configure Alarm \(draft.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .disabled(isCurrentOperationPending)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        submit()
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isCurrentOperationPending)
            .alert("Delete Alarm \(draft.id)?", isPresented: $isDeleteConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    confirmDelete()
                }
            } message: {
                Text("This will permanently remove the stored alarm configuration from the CLOCK.")
            }
        }
    }

    private var canSubmit: Bool {
        sendEligibility.canSend
    }

    private var canDeleteAlarm: Bool {
        deleteEligibility.canDelete
    }

    private var isCurrentOperationPending: Bool {
        sendState == .sending(id: draft.id) ||
            deleteState == .deleting(id: draft.id)
    }

    private var sendEligibility: AlarmEditorSendEligibility {
        AlarmEditorSendEligibility.evaluate(
            draft: draft,
            connectionAvailable: canSend,
            sendState: sendState,
            deleteState: deleteState
        )
    }

    private var deleteEligibility: AlarmEditorDeleteEligibility {
        AlarmEditorDeleteEligibility.evaluate(
            draft: draft,
            connectionAvailable: canDelete,
            sendState: sendState,
            deleteState: deleteState
        )
    }

    private func submit() {
        guard canSubmit else {
            return
        }

        onSend(draft)
    }

    private func requestDeleteConfirmation() {
        guard canDeleteAlarm else {
            return
        }

        isDeleteConfirmationPresented = true
    }

    private func confirmDelete() {
        guard canDeleteAlarm else {
            return
        }

        onDelete(draft)
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Self.date(hour: draft.hour, minute: draft.minute)
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.hour = components.hour ?? 0
            draft.minute = components.minute ?? 0
        }
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date()
    }
}

private struct AlarmEditorSendStatusView: View {
    let sendState: AlarmSendState
    let deleteState: AlarmDeleteState
    let alarmID: Int
    let sendEligibility: AlarmEditorSendEligibility
    let deleteEligibility: AlarmEditorDeleteEligibility

    var body: some View {
        HStack(spacing: 8) {
            switch (sendState, deleteState) {
            case let (_, .deleting(id)) where id == alarmID:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for alarm \(alarmID) delete acknowledgement...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let (_, .succeeded(id)) where id == alarmID:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Alarm \(alarmID) deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let (_, .failed(id, message)) where id == alarmID:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case (.idle, _):
                Text(idleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let (.sending(id), _) where id == alarmID:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for alarm \(alarmID) acknowledgement...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let (.succeeded(id), _) where id == alarmID:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Alarm \(alarmID) saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let (.failed(id, message), _) where id == alarmID:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .frame(minHeight: 20, alignment: .leading)
    }

    private var idleText: String {
        if !sendEligibility.connectionAvailable {
            return "Connect to a CLOCK before sending."
        }

        if !deleteEligibility.originalAlarmIsConfigured {
            return sendEligibility.hasPersistedChanges ? "Ready" : "No changes to send."
        }

        if !sendEligibility.hasPersistedChanges {
            return "No changes to send."
        }

        if !sendEligibility.draftIsValid {
            return "Complete valid alarm settings."
        }

        return "Ready"
    }
}
