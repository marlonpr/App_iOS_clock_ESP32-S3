//
//  AlarmWeekdaySelector.swift
//  ESP32Controller
//
//  Created by Codex on 07/07/26.
//

import SwiftUI

struct AlarmWeekdaySelector: View {
    @Binding var weekdays: Set<AlarmWeekday>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AlarmWeekday.allCases) { weekday in
                    Button {
                        toggle(weekday)
                    } label: {
                        Text(weekday.compactLabel)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(dayBackground(for: weekday), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(dayBorder(for: weekday), lineWidth: weekdays.contains(weekday) ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(weekday.accessibilityName)
                    .accessibilityValue(weekdays.contains(weekday) ? "Selected" : "Not selected")
                }
            }

            HStack(spacing: 8) {
                presetButton("L-V", weekdays: AlarmWeekday.mondayThroughFriday)
                presetButton("L-S", weekdays: AlarmWeekday.mondayThroughSaturday)
                presetButton("L-D", weekdays: AlarmWeekday.everyDay)
            }
        }
    }

    private func presetButton(_ title: String, weekdays preset: Set<AlarmWeekday>) -> some View {
        Button(title) {
            weekdays = preset
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }

    private func toggle(_ weekday: AlarmWeekday) {
        if weekdays.contains(weekday) {
            weekdays.remove(weekday)
        } else {
            weekdays.insert(weekday)
        }
    }

    private func dayBackground(for weekday: AlarmWeekday) -> Color {
        weekdays.contains(weekday) ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground)
    }

    private func dayBorder(for weekday: AlarmWeekday) -> Color {
        weekdays.contains(weekday) ? .accentColor : .secondary.opacity(0.35)
    }
}
