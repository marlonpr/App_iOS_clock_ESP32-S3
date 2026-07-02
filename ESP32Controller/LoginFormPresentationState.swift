#if LOGIN_ENABLED
import Foundation

enum LoginField: Hashable {
    case username
    case password
}

struct LoginFormPresentationState: Equatable {
    var username = ""
    var password = ""
    var isAuthenticating = false
    var failureMessage: String?
    var focusedField: LoginField?

    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        !normalizedUsername.isEmpty &&
            !password.isEmpty &&
            !isAuthenticating
    }

    func canSubmit(
        sessionIsAuthenticating: Bool,
        sessionIsRestoring: Bool
    ) -> Bool {
        canSubmit && !sessionIsAuthenticating && !sessionIsRestoring
    }

    func shouldSubmitPassword(
        sessionIsAuthenticating: Bool,
        sessionIsRestoring: Bool
    ) -> Bool {
        canSubmit(
            sessionIsAuthenticating: sessionIsAuthenticating,
            sessionIsRestoring: sessionIsRestoring
        )
    }

    mutating func clearFocus() {
        focusedField = nil
    }

    mutating func submitUsername(userInitiated: Bool) {
        guard userInitiated else {
            return
        }

        focusedField = .password
    }

    mutating func applyFailedAuthentication(message: String) {
        failureMessage = message
        password = ""
        clearFocus()
    }

    mutating func applyAuthenticationState(_ state: AuthenticationSession.State) {
        isAuthenticating = state == .authenticating
        switch state {
        case let .failed(message):
            applyFailedAuthentication(message: message)
        case .loggedOut, .restoring, .authenticated:
            failureMessage = nil
            clearFocus()
        case .authenticating:
            failureMessage = nil
        }
    }
}
#endif
