#if LOGIN_ENABLED
import Foundation

struct AuthenticatedUser: Equatable, Identifiable {
    enum Role: String, Equatable {
        case master
    }

    let id: String
    let username: String
    let displayName: String
    let role: Role
}

struct AuthenticatedSessionMetadata: Equatable {
    let user: AuthenticatedUser
    let expiresAt: Date?
    let serverBaseURL: URL?
}

struct AuthenticationDiagnostics: Equatable {
    let provider: String
    let username: String
    let role: AuthenticatedUser.Role
    let server: String
    let sessionStatus: String
    let expiresAt: Date?
}

@MainActor
protocol AuthenticationService {
    var providerName: String { get }
    var currentSessionMetadata: AuthenticatedSessionMetadata? { get }

    func authenticate(
        username: String,
        password: String
    ) async throws -> AuthenticatedUser

    func restoreSession() async throws -> AuthenticatedUser?

    func logOut() async

    func invalidateLocalSession() async
}

@MainActor
protocol ServerConfiguredAuthenticationService: AuthenticationService {
    var serverBaseURLString: String { get }
    var serverDisplayHostAndPort: String { get }

    func updateServerBaseURL(from value: String) async throws
    func testServer() async throws
}

enum AuthenticationFailure: Error, Equatable {
    case invalidCredentials
    case rateLimited
    case serverUnavailable
    case storageFailure
    case invalidSession
    case invalidServerResponse
    case insufficientRole
    case unknown
}

extension AuthenticationService {
    var providerName: String {
        "Unknown"
    }

    var currentSessionMetadata: AuthenticatedSessionMetadata? {
        nil
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        nil
    }

    func logOut() async {}

    func invalidateLocalSession() async {}
}
#endif
