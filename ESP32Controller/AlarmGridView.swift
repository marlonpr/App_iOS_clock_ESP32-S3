//
//  AlarmGridView.swift
//  ESP32Controller
//
//  Created by Codex on 07/07/26.
//

import SwiftUI

enum AlarmSectionPresentation {
    static let showsManualReadButton = false
}

struct AlarmSectionView: View {
    @ObservedObject var viewModel: ESP32ControllerViewModel

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 34), spacing: 5),
        count: 6
    )

    var body: some View {
        Section("Alarms") {
            VStack(alignment: .leading, spacing: 10) {
                alarmReadStatus
                    .padding(.bottom, 8)

                if case let .reading(_, completed, total) = viewModel.alarmReadOperationState {
                    ProgressView(value: Double(completed), total: Double(total))
                        .accessibilityLabel("Alarm read progress")
                        .accessibilityValue("\(completed) of \(total)")
                }

                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(viewModel.alarmRecords) { record in
                        AlarmCellView(
                            record: record,
                            isSelected: record.id == viewModel.selectedAlarmID
                        ) {
                            viewModel.selectAlarm(id: record.id)
                        }
                    }
                }
                .accessibilityElement(children: .contain)

                if let selectedAlarmID = viewModel.selectedAlarmID {
                    AlarmSelectedSummary(record: viewModel.alarmRecords[selectedAlarmID - 1])
                }

                if let unavailableMessage = viewModel.clockControlsUnavailableMessage {
                    Text(unavailableMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var alarmReadStatus: some View {
        switch viewModel.alarmReadOperationState {
        case .idle:
            Text("Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .reading(currentID, completed, total):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading \(currentID ?? completed) / \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case let .completed(successful, failed):
            if failed == 0 {
                Text("Read \(successful) of 60 alarms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Read \(successful) of 60. \(failed) failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case let .interrupted(successful, failed):
            Label("Interrupted after \(successful + failed) of 60.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct AlarmCellView: View {
    let record: AlarmRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let visualConfiguration = AlarmCellVisualConfiguration(record: record)

        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundStyle)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(borderStyle, style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, dash: borderDash))
                    }

                if let icon = visualConfiguration.icon, icon.placement == .center {
                    stateIcon(icon)
                }

                VStack {
                    HStack {
                        Spacer()
                        Text("\(record.id)")
                            .font(.caption.monospacedDigit())
                            .fontWeight(isSelected ? .bold : .semibold)
                            .foregroundStyle(foregroundStyle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        if let icon = visualConfiguration.icon, icon.placement == .bottomTrailing {
                            stateIcon(icon)
                        }
                    }
                }
                .padding(4)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Alarm \(record.id)")
        .accessibilityValue(record.accessibilityValue)
        .accessibilityHint("Opens alarm configuration")
    }

    private var backgroundStyle: Color {
        switch record.readState {
        case .notLoaded:
            Color(.secondarySystemGroupedBackground)
        case .loading:
            Color.accentColor.opacity(0.10)
        case .loaded:
            record.isConfigured ? Color.green.opacity(0.18) : Color(.tertiarySystemGroupedBackground)
        case .failed:
            Color.orange.opacity(0.16)
        }
    }

    private var foregroundStyle: Color {
        switch record.readState {
        case .loaded where !record.isConfigured:
            .secondary
        case .failed:
            .primary
        default:
            .primary
        }
    }

    private var borderStyle: Color {
        if isSelected {
            return .accentColor
        }

        switch record.readState {
        case .notLoaded:
            return .secondary.opacity(0.45)
        case .loading:
            return .accentColor.opacity(0.6)
        case .loaded:
            return record.isConfigured ? .green : .secondary.opacity(0.5)
        case .failed:
            return .orange
        }
    }

    private var borderDash: [CGFloat] {
        switch record.readState {
        case .notLoaded:
            [3, 3]
        default:
            []
        }
    }

    private func stateIcon(_ icon: AlarmCellIconPresentation) -> some View {
        Image(systemName: icon.systemName)
            .font(.system(size: CGFloat(icon.pointSize), weight: .bold))
            .foregroundStyle(iconForegroundStyle(icon))
    }

    private func iconForegroundStyle(_ icon: AlarmCellIconPresentation) -> Color {
        switch icon.foregroundStyle {
        case .accent:
            Color.accentColor
        case .green:
            .green
        case .gray:
            .gray
        case .orange:
            .orange
        }
    }
}

enum AlarmCellIconPlacement: Equatable {
    case center
    case bottomTrailing
}

enum AlarmCellIconKind: Equatable {
    case loading
    case configuredEnabled
    case configuredDisabled
    case failed
}

enum AlarmCellIconForegroundStyle: Equatable {
    case accent
    case green
    case gray
    case orange
}

struct AlarmCellIconPresentation: Equatable {
    let kind: AlarmCellIconKind
    let systemName: String
    let placement: AlarmCellIconPlacement
    let pointSize: Double
    let foregroundStyle: AlarmCellIconForegroundStyle
}

struct AlarmCellVisualConfiguration: Equatable {
    static let enabledBellPointSize = 10.0
    static let disabledBellPointSize = 22.0

    let icon: AlarmCellIconPresentation?

    init(record: AlarmRecord) {
        switch record.readState {
        case .notLoaded:
            icon = nil
        case .loading:
            icon = AlarmCellIconPresentation(
                kind: .loading,
                systemName: "hourglass",
                placement: .bottomTrailing,
                pointSize: Self.enabledBellPointSize,
                foregroundStyle: .accent
            )
        case .loaded where !record.isConfigured:
            icon = nil
        case .loaded where record.isEnabled:
            icon = AlarmCellIconPresentation(
                kind: .configuredEnabled,
                systemName: "bell.fill",
                placement: .bottomTrailing,
                pointSize: Self.enabledBellPointSize,
                foregroundStyle: .green
            )
        case .loaded:
            icon = AlarmCellIconPresentation(
                kind: .configuredDisabled,
                systemName: "bell.slash.fill",
                placement: .center,
                pointSize: Self.disabledBellPointSize,
                foregroundStyle: .gray
            )
        case .failed:
            icon = AlarmCellIconPresentation(
                kind: .failed,
                systemName: "exclamationmark.triangle.fill",
                placement: .bottomTrailing,
                pointSize: Self.enabledBellPointSize,
                foregroundStyle: .orange
            )
        }
    }
}

private struct AlarmSelectedSummary: View {
    let record: AlarmRecord

    var body: some View {
        HStack(spacing: 8) {
            Text("Alarm \(record.id)")
                .fontWeight(.semibold)
            Text(timeText)
                .font(.body.monospacedDigit())
            Text(record.weekdaySummary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(record.accessibilityValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var timeText: String {
        String(format: "%02d:%02d", record.hour, record.minute)
    }
}
