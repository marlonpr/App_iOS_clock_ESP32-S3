#if LOGIN_ENABLED
import Foundation

@MainActor
final class AuthenticationSession: ObservableObject {
    enum State: Equatable {
        case loggedOut
        case restoring
        case authenticating
        case authenticated(AuthenticatedUser)
        case failed(String)
    }

    enum ServerHealthState: Equatable {
        case notTested
        case testing
        case reachable
        case unavailable

        var message: String? {
            switch self {
            case .notTested:
                nil
            case .testing:
                "Testing server..."
            case .reachable:
                "Server reachable"
            case .unavailable:
                "Authentication server unavailable."
            }
        }
    }

    static let genericFailureMessage = "Invalid username or password."
    static let rateLimitedMessage = "Too many login attempts. Please wait and try again."
    static let serverUnavailableMessage = "Authentication server unavailable."
    static let genericServerFailureMessage = "Authentication failed. Please try again."

    @Published private(set) var state: State = .loggedOut
    @Published var serverURLText: String
    @Published private(set) var serverHealthState: ServerHealthState = .notTested

    private let authenticationService: AuthenticationService
    private let serverConfiguredAuthenticationService: ServerConfiguredAuthenticationService?
    private var activeOperationID: UUID?
    private var hasRecoverableStoredSession = false

    init(authenticationService: AuthenticationService) {
        self.authenticationService = authenticationService
        self.serverConfiguredAuthenticationService = authenticationService as? ServerConfiguredAuthenticationService
        self.serverURLText = serverConfiguredAuthenticationService?.serverBaseURLString ?? ""
    }

    var isAuthenticating: Bool {
        state == .authenticating
    }

    var isRestoringSession: Bool {
        state == .restoring
    }

    var authenticatedUser: AuthenticatedUser? {
        guard case let .authenticated(user) = state else {
            return nil
        }
        return user
    }

    var isAuthenticated: Bool {
        authenticatedUser != nil
    }

    var failureMessage: String? {
        guard case let .failed(message) = state else {
            return nil
        }
        return message
    }

    var canRetrySessionRestore: Bool {
        hasRecoverableStoredSession && !isAuthenticating && !isRestoringSession
    }

    var serverDisplayHostAndPort: String {
        serverConfiguredAuthenticationService?.serverDisplayHostAndPort ?? ""
    }

    var diagnostics: AuthenticationDiagnostics? {
        guard
            case let .authenticated(user) = state,
            let metadata = authenticationService.currentSessionMetadata
        else {
            return nil
        }

        return AuthenticationDiagnostics(
            provider: authenticationService.providerName,
            username: user.username,
            role: user.role,
            server: metadata.serverBaseURL?.hostAndPortDisplay ?? "Unavailable",
            sessionStatus: "Valid",
            expiresAt: metadata.expiresAt
        )
    }

    func restoreStoredSession() async {
        guard !isAuthenticated, !isAuthenticating, !isRestoringSession else {
            return
        }

        let operationID = beginOperation()
        state = .restoring
        do {
            let user = try await authenticationService.restoreSession()
            guard isCurrentOperation(operationID) else {
                return
            }

            if let user {
                hasRecoverableStoredSession = false
                state = .authenticated(user)
            } else {
                hasRecoverableStoredSession = false
                state = .loggedOut
            }
        } catch AuthenticationFailure.invalidSession {
            guard isCurrentOperation(operationID) else {
                return
            }

            hasRecoverableStoredSession = false
            state = .loggedOut
        } catch {
            guard isCurrentOperation(operationID) else {
                return
            }

            hasRecoverableStoredSession = true
            state = .failed(Self.message(for: error, context: .restore))
        }
    }

    func retrySessionRestore() async {
        await restoreStoredSession()
    }

    func authenticate(username: String, password: String) async {
        guard !isAuthenticating, !isRestoringSession else {
            return
        }

        do {
            try await saveServerConfigurationIfNeeded()
        } catch {
            state = .failed(Self.serverUnavailableMessage)
            return
        }

        let operationID = beginOperation()
        state = .authenticating
        do {
            let user = try await authenticationService.authenticate(
                username: username,
                password: password
            )
            guard isCurrentOperation(operationID) else {
                return
            }

            hasRecoverableStoredSession = false
            state = .authenticated(user)
        } catch {
            guard isCurrentOperation(operationID) else {
                return
            }

            state = .failed(Self.message(for: error, context: .login))
        }
    }

    func logOut() async {
        _ = beginOperation()
        state = .loggedOut
        hasRecoverableStoredSession = false
        await authenticationService.logOut()
    }

    func handleAppBecameActive() {}

    func handleAppEnteredBackground() {}

    func saveServerConfigurationIfNeeded() async throws {
        guard let serverConfiguredAuthenticationService else {
            return
        }

        let normalizedURL = try AuthServerConfiguration.normalizedBaseURL(from: serverURLText)
        if normalizedURL.absoluteString == serverConfiguredAuthenticationService.serverBaseURLString {
            serverURLText = normalizedURL.absoluteString
            return
        }

        if isAuthenticated {
            await logOut()
        } else {
            await authenticationService.invalidateLocalSession()
            hasRecoverableStoredSession = false
        }

        try await serverConfiguredAuthenticationService.updateServerBaseURL(from: normalizedURL.absoluteString)
        serverURLText = serverConfiguredAuthenticationService.serverBaseURLString
        serverHealthState = .notTested
    }

    func testServer() async {
        guard let serverConfiguredAuthenticationService else {
            serverHealthState = .unavailable
            return
        }

        do {
            try await saveServerConfigurationIfNeeded()
        } catch {
            serverHealthState = .unavailable
            return
        }

        serverHealthState = .testing
        do {
            try await serverConfiguredAuthenticationService.testServer()
            serverHealthState = .reachable
        } catch {
            serverHealthState = .unavailable
        }
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        return operationID
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private enum FailureContext {
        case login
        case restore
    }

    private static func message(for error: Error, context: FailureContext) -> String {
        guard let failure = error as? AuthenticationFailure else {
            return genericServerFailureMessage
        }

        switch failure {
        case .invalidCredentials:
            return genericFailureMessage
        case .rateLimited:
            return rateLimitedMessage
        case .serverUnavailable:
            return serverUnavailableMessage
        case .invalidSession:
            return context == .restore ? serverUnavailableMessage : genericFailureMessage
        case .storageFailure, .invalidServerResponse, .insufficientRole, .unknown:
            return genericServerFailureMessage
        }
    }
}

private extension URL {
    var hostAndPortDisplay: String {
        guard let host else {
            return absoluteString
        }

        if let port {
            return "\(host):\(port)"
        }

        return host
    }
}
#endif
