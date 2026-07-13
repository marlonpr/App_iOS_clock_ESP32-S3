//
//  ColorPaletteSection.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import SwiftUI

enum ColorPalettePresentation {
    static let editableModes = PaletteMode.editableCases
    static let disconnectedMessage = "Connect to a CLOCK device to edit colors."
    static let unsupportedMessage = "Color Palette requires newer CLOCK firmware."
    static let loadingMessage = "Loading colors..."

    static func modeTitle(_ mode: PaletteMode) -> String {
        "Mode \(mode.rawValue)"
    }

    static func roles(for mode: PaletteMode) -> [PaletteRole] {
        PaletteRole.requiredRoles(for: mode)
    }

    static func restoreMessage(for mode: PaletteMode) -> String {
        "This will restore the default colors for \(modeTitle(mode))."
    }

    static func contentState(
        canUseClockControls: Bool,
        availability: PaletteFeatureAvailability,
        hasDraft: Bool,
        errorMessage: String?
    ) -> ColorPaletteContentState {
        guard canUseClockControls else {
            return .disconnected
        }
        if case .unsupported = availability {
            return .unsupported
        }
        if hasDraft {
            return .ready
        }
        if let errorMessage {
            return .error(errorMessage)
        }
        return .loading
    }
}

enum ColorPaletteContentState: Equatable {
    case disconnected
    case unsupported
    case loading
    case ready
    case error(String)

    var message: String? {
        switch self {
        case .disconnected:
            ColorPalettePresentation.disconnectedMessage
        case .unsupported:
            ColorPalettePresentation.unsupportedMessage
        case .loading:
            ColorPalettePresentation.loadingMessage
        case .ready:
            nil
        case let .error(message):
            message
        }
    }

    var showsProgress: Bool {
        self == .loading
    }
}

struct ColorPaletteSection: View {
    @ObservedObject var viewModel: ESP32ControllerViewModel
    @Environment(\.self) private var environment
    @State private var pendingRestoreMode: PaletteMode?

    private var selectedMode: PaletteMode {
        viewModel.selectedPaletteMode
    }

    private var selectedDraft: ModePaletteDraft? {
        viewModel.paletteDrafts[selectedMode]
    }

    private var contentState: ColorPaletteContentState {
        ColorPalettePresentation.contentState(
            canUseClockControls: viewModel.canUseClockControls,
            availability: viewModel.paletteFeatureAvailability,
            hasDraft: selectedDraft != nil,
            errorMessage: selectedModeErrorMessage
        )
    }

    private var selectedModeErrorMessage: String? {
        if
            let failure = viewModel.lastPaletteError,
            failure.mode == nil || failure.mode == selectedMode
        {
            let action = switch failure.operation {
            case .read:
                "load"
            case .save:
                "save"
            case .restoreDefaults:
                "restore default"
            }
            return "Could not \(action) colors. \(failure.message)"
        }

        if case let .failed(mode, message) = viewModel.setDisplayModeState, mode == selectedMode {
            return message
        }

        return nil
    }

    private var pendingMessage: String? {
        if viewModel.paletteSaveState.isSaving {
            return "Saving Colors..."
        }
        if viewModel.paletteDefaultRestoreState.isRestoring {
            return "Restoring Defaults..."
        }
        if viewModel.paletteReadState.isReading {
            return "Loading Colors..."
        }
        if let mode = viewModel.setDisplayModeState.pendingMode {
            return "Switching CLOCK to \(ColorPalettePresentation.modeTitle(mode))..."
        }
        return nil
    }

    private var selectedModeBinding: Binding<PaletteMode> {
        Binding(
            get: { viewModel.selectedPaletteMode },
            set: { viewModel.userSelectedPaletteMode($0) }
        )
    }

    private var isRestoreConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingRestoreMode != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRestoreMode = nil
                }
            }
        )
    }

    var body: some View {
        Section("Color Palette") {
            Picker("Display Mode", selection: selectedModeBinding) {
                ForEach(ColorPalettePresentation.editableModes, id: \.self) { mode in
                    Text(ColorPalettePresentation.modeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isPaletteOperationPending)

            switch contentState {
            case .ready:
                paletteEditor
            case .disconnected, .unsupported, .loading, .error:
                if let message = contentState.message {
                    ColorPaletteStatusRow(
                        message: message,
                        showsProgress: contentState.showsProgress,
                        isError: contentState.isError
                    )
                }
            }
        }
        .confirmationDialog(
            "Restore Default Colors?",
            isPresented: isRestoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                guard let mode = pendingRestoreMode else {
                    return
                }
                pendingRestoreMode = nil
                viewModel.requestPaletteRestoreDefaults(mode)
            }
            Button("Cancel", role: .cancel) {
                pendingRestoreMode = nil
            }
        } message: {
            if let mode = pendingRestoreMode {
                Text(ColorPalettePresentation.restoreMessage(for: mode))
            }
        }
    }

    @ViewBuilder
    private var paletteEditor: some View {
        ForEach(ColorPalettePresentation.roles(for: selectedMode), id: \.self) { role in
            ColorPicker(
                role.label,
                selection: colorBinding(for: role, mode: selectedMode),
                supportsOpacity: false
            )
            .disabled(!viewModel.canEditSelectedPalette)
        }

        if let pendingMessage {
            ColorPaletteStatusRow(message: pendingMessage, showsProgress: true, isError: false)
        } else if let selectedModeErrorMessage {
            ColorPaletteStatusRow(message: selectedModeErrorMessage, showsProgress: false, isError: true)
        }

        Button("Save Colors") {
            guard let draft = selectedDraft else {
                return
            }
            viewModel.requestPaletteSave(draft)
        }
        .disabled(!viewModel.canSaveSelectedPalette)

        Button("Restore Default Colors", role: .destructive) {
            pendingRestoreMode = selectedMode
        }
        .disabled(!viewModel.canRestoreSelectedPaletteDefaults)
    }

    private func colorBinding(for role: PaletteRole, mode: PaletteMode) -> Binding<Color> {
        Binding(
            get: {
                viewModel.paletteDrafts[mode]?.roleValues[role]?.swiftUIColor ?? .black
            },
            set: { newColor in
                guard var draft = viewModel.paletteDrafts[mode] else {
                    return
                }
                draft.roleValues[role] = RGB888(sRGBColor: newColor, environment: environment)
                viewModel.updatePaletteDraft(draft)
            }
        )
    }
}

private extension ColorPaletteContentState {
    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}

private struct ColorPaletteStatusRow: View {
    let message: String
    let showsProgress: Bool
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .frame(minHeight: 20, alignment: .leading)
    }
}
