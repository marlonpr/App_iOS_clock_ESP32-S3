#if LOGIN_ENABLED
import SwiftUI

struct LoginView: View {
    @ObservedObject var session: AuthenticationSession

    @State private var formState = LoginFormPresentationState()
    @State private var isServerSettingsExpanded = false
    @FocusState private var focusedField: LoginField?

    private var normalizedUsername: String {
        formState.normalizedUsername
    }

    private var canSubmit: Bool {
        formState.canSubmit(
            sessionIsAuthenticating: session.isAuthenticating,
            sessionIsRestoring: session.isRestoringSession
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZeitBrandBadge(size: .login)
                        Spacer()
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                }

                if session.isRestoringSession {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Restoring session...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("Username", text: $formState.username)
                        .textContentType(.username)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .accessibilityLabel("Username")
                        .onSubmit {
                            formState.focusedField = focusedField
                            formState.submitUsername(userInitiated: focusedField == .username)
                            focusedField = formState.focusedField
                        }

                    SecureField("Password", text: $formState.password)
                        .textContentType(.password)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("Password")
                        .onSubmit {
                            submitIfPossible()
                        }

                    if formState.isAuthenticating {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Signing in...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let failureMessage = formState.failureMessage {
                        Text(failureMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Sign in failed")
                    }

                    if session.canRetrySessionRestore {
                        Button("Retry") {
                            Task {
                                await session.retrySessionRestore()
                            }
                        }
                    }
                }

                Section {
                    Button("Sign In") {
                        submitIfPossible()
                    }
                    .disabled(!canSubmit)
                }

                DisclosureGroup("Server Settings", isExpanded: $isServerSettingsExpanded) {
                    TextField("Authentication Server", text: $session.serverURLText)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("Authentication Server")

                    if !session.serverDisplayHostAndPort.isEmpty {
                        LabeledContent("Current Server", value: session.serverDisplayHostAndPort)
                    }

                    if let message = session.serverHealthState.message {
                        HStack(spacing: 12) {
                            if session.serverHealthState == .testing {
                                ProgressView()
                            }
                            Text(message)
                                .foregroundColor(session.serverHealthState == .reachable ? .secondary : .red)
                        }
                    }

                    Button("Test Server") {
                        Task {
                            await session.testServer()
                        }
                    }
                    .disabled(session.serverHealthState == .testing)
                }
            }
            .navigationTitle("CLOCK TCP")
            .onAppear {
                formState.clearFocus()
                focusedField = nil
            }
            .onChange(of: session.state) { _, state in
                formState.applyAuthenticationState(state)
                focusedField = formState.focusedField
            }
        }
    }

    private func submitIfPossible() {
        guard canSubmit else {
            return
        }

        let submittedUsername = normalizedUsername
        let submittedPassword = formState.password
        Task {
            await session.authenticate(
                username: submittedUsername,
                password: submittedPassword
            )
        }
    }
}
#endif
