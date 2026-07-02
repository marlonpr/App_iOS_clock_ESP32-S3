#if LOGIN_ENABLED
import Foundation

@MainActor
final class DatabaseAuthenticationService: ServerConfiguredAuthenticationService {
    private let apiClient: AuthenticationAPIClient
    private let tokenStore: SessionTokenStore
    private let configurationStore: AuthServerConfigurationStore
    private let dateProvider: () -> Date

    private var currentToken: String?
    private(set) var currentSessionMetadata: AuthenticatedSessionMetadata?

    var providerName: String {
        "Server"
    }

    var serverBaseURLString: String {
        configurationStore.baseURLString
    }

    var serverDisplayHostAndPort: String {
        configurationStore.configuration.displayHostAndPort
    }

    init(
        apiClient: AuthenticationAPIClient,
        tokenStore: SessionTokenStore,
        configurationStore: AuthServerConfigurationStore,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.tokenStore = tokenStore
        self.configurationStore = configurationStore
        self.dateProvider = dateProvider
    }

    convenience init(
        urlSession: URLSessioning,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore(),
        configurationStore: AuthServerConfigurationStore,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            apiClient: AuthenticationAPIClient(session: urlSession),
            tokenStore: tokenStore,
            configurationStore: configurationStore,
            dateProvider: dateProvider
        )
    }

    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        let normalizedUsername = Self.normalizedUsername(username)
        do {
            let response = try await apiClient.login(
                baseURL: configurationStore.baseURL,
                username: normalizedUsername,
                password: password
            )
            guard !isExpired(response.expiresAt) else {
                throw AuthenticationFailure.invalidSession
            }

            let user = try Self.authenticatedUser(from: response.user)
            try tokenStore.saveToken(response.token)
            currentToken = response.token
            currentSessionMetadata = AuthenticatedSessionMetadata(
                user: user,
                expiresAt: response.expiresAt,
                serverBaseURL: configurationStore.baseURL
            )
            return user
        } catch let error as AuthenticationAPIError {
            throw Self.authenticationFailure(from: error)
        } catch let error as SessionTokenStoreError {
            throw Self.authenticationFailure(from: error)
        }
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        let token: String?
        do {
            token = try tokenStore.loadToken()
        } catch {
            throw AuthenticationFailure.storageFailure
        }

        guard let token else {
            currentToken = nil
            currentSessionMetadata = nil
            return nil
        }

        do {
            let response = try await apiClient.session(baseURL: configurationStore.baseURL, token: token)
            guard !isExpired(response.expiresAt) else {
                try? tokenStore.deleteToken()
                currentToken = nil
                currentSessionMetadata = nil
                throw AuthenticationFailure.invalidSession
            }

            let user = try Self.authenticatedUser(from: response.user)
            currentToken = token
            currentSessionMetadata = AuthenticatedSessionMetadata(
                user: user,
                expiresAt: response.expiresAt,
                serverBaseURL: configurationStore.baseURL
            )
            return user
        } catch AuthenticationAPIError.unauthorized {
            try? tokenStore.deleteToken()
            currentToken = nil
            currentSessionMetadata = nil
            throw AuthenticationFailure.invalidSession
        } catch let error as AuthenticationAPIError {
            throw Self.authenticationFailure(from: error)
        } catch {
            throw AuthenticationFailure.unknown
        }
    }

    func logOut() async {
        let token = currentToken ?? (try? tokenStore.loadToken())
        if let token {
            try? await apiClient.logout(baseURL: configurationStore.baseURL, token: token)
        }

        try? tokenStore.deleteToken()
        currentToken = nil
        currentSessionMetadata = nil
    }

    func invalidateLocalSession() async {
        try? tokenStore.deleteToken()
        currentToken = nil
        currentSessionMetadata = nil
    }

    func updateServerBaseURL(from value: String) async throws {
        try configurationStore.updateBaseURL(from: value)
    }

    func testServer() async throws {
        do {
            try await apiClient.health(baseURL: configurationStore.baseURL)
        } catch {
            throw AuthenticationFailure.serverUnavailable
        }
    }

    static func normalizedUsername(_ username: String) -> String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func authenticatedUser(from apiUser: APIAuthenticatedUser) throws -> AuthenticatedUser {
        guard let role = AuthenticatedUser.Role(rawValue: apiUser.role) else {
            throw AuthenticationFailure.insufficientRole
        }

        return AuthenticatedUser(
            id: String(apiUser.id),
            username: apiUser.username,
            displayName: apiUser.displayName,
            role: role
        )
    }

    private static func authenticationFailure(from error: AuthenticationAPIError) -> AuthenticationFailure {
        switch error {
        case .unauthorized:
            return .invalidCredentials
        case .rateLimited:
            return .rateLimited
        case .serverUnavailable:
            return .serverUnavailable
        case .serverError, .malformedResponse:
            return .invalidServerResponse
        }
    }

    private static func authenticationFailure(from error: SessionTokenStoreError) -> AuthenticationFailure {
        switch error {
        case .unexpectedStatus, .invalidTokenData:
            return .storageFailure
        }
    }

    private func isExpired(_ expiresAt: Date) -> Bool {
        expiresAt <= dateProvider()
    }
}
#endif
