//
//  ESP32ControllerTests.swift
//  ESP32ControllerTests
//
//  Created by Marlon Pérez on 22/06/26.
//

import Testing
import Foundation
import ImageIO
import Network
import Combine
import UniformTypeIdentifiers
import UIKit
@testable import ESP32Controller

@Suite(.serialized)
struct ESP32ControllerTests {

    @Test func txtRecordParsingExtractsBonjourValues() {
        let metadata = NWBrowser.Result.Metadata.bonjour(NWTXTRecord([
            "id": "board-0",
            "model": "clock",
            "protocol": "1",
            "firmware": "2.3.4"
        ]))

        let values = ESP32DiscoveryService.txtValues(from: metadata)

        #expect(values["id"] == "board-0")
        #expect(values["model"] == "clock")
        #expect(values["protocol"] == "1")
        #expect(values["firmware"] == "2.3.4")
    }

    @Test func serviceInstanceNameIsExtractedFromServiceEndpoint() {
        let endpoint = NWEndpoint.service(
            name: "ESP32 Clock 0",
            type: "_espclock._tcp",
            domain: "local",
            interface: nil
        )

        #expect(ESP32DiscoveryService.serviceInstanceName(from: endpoint) == "ESP32 Clock 0")
        #expect(ESP32DiscoveryService.serviceInstanceName(from: .hostPort(host: "192.168.4.1", port: 5000)) == nil)
    }

    @Test func deterministicSortingUsesBoardIDThenServiceNameThenEndpoint() {
        let unsorted = [
            makeDevice(id: "service-c", serviceName: "Clock C", boardID: nil),
            makeDevice(id: "service-b", serviceName: "Clock B", boardID: "board-2"),
            makeDevice(id: "service-a", serviceName: "Clock A", boardID: "board-1"),
            makeDevice(id: "service-d", serviceName: "Clock D", boardID: nil)
        ]

        let sorted = ESP32DiscoveryService.sortDevices(unsorted)

        #expect(sorted.map(\.id) == ["service-a", "service-b", "service-c", "service-d"])
    }

    @MainActor
    @Test func removedServicesDisappearAndChangedTXTUpdates() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)
        service.beginDeviceScan()

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock 0", id: "board-0", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock 1", id: "board-1", firmware: "1.0.0")
        ], browser: browser)
        probes.connections[0].stateUpdateHandler?(.ready)
        probes.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.map(\.boardID) == ["board-0", "board-1"])

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock 1", id: "board-1", firmware: "1.0.1")
        ], browser: browser)

        #expect(service.devices.count == 1)
        #expect(service.devices[0].serviceName == "ESP32 Clock 1")
        #expect(service.devices[0].firmwareVersion == "1.0.1")
    }

    @MainActor
    @Test func viewModelInitializationDoesNotStartScan() {
        var browserCount = 0
        var logoBrowserCount = 0
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() }
        )
        let discoveryService = ESP32DiscoveryService(
            browserFactory: {
                browserCount += 1
                return FakeESP32Browser()
            },
            logoBrowserFactory: {
                logoBrowserCount += 1
                return FakeESP32Browser()
            }
        )

        let viewModel = ESP32ControllerViewModel(client: client, discoveryService: discoveryService)

        #expect(browserCount == 0)
        #expect(logoBrowserCount == 0)
        #expect(viewModel.scannerState == .idle)
        #expect(!viewModel.isRefreshingDevices)
    }

    @MainActor
    @Test func zeitBadgeAssetNameIsStableAndAvailable() {
        #expect(ZeitBrandAssets.badgeImageName == "ZeitBadge")
        #expect(UIImage(named: ZeitBrandAssets.badgeImageName) != nil)
    }

    @MainActor
    @Test func zeitBadgeDoesNotModifyControllerNetworkingState() {
        let viewModel = ESP32ControllerViewModel()

        _ = ZeitBrandBadge(size: .controller)

        #expect(!viewModel.isNetworkingAuthorized)
        #expect(viewModel.scannerState == .idle)
        #expect(viewModel.connectionStatusText == "Disconnected")
    }

#if LOGIN_ENABLED
    @MainActor
    @Test func localMasterAuthenticationAcceptsCorrectCredentials() async throws {
        let service = makeLocalAuthenticationService(username: "master", password: "correct horse")

        let user = try await service.authenticate(username: "master", password: "correct horse")

        #expect(user.username == "master")
        #expect(user.role == .master)
    }

    @MainActor
    @Test func localMasterAuthenticationRejectsWrongUsername() async {
        let service = makeLocalAuthenticationService(username: "master", password: "correct horse")

        await expectAuthenticationFailure {
            _ = try await service.authenticate(username: "operator", password: "correct horse")
        }
    }

    @MainActor
    @Test func localMasterAuthenticationRejectsWrongPassword() async {
        let service = makeLocalAuthenticationService(username: "master", password: "correct horse")

        await expectAuthenticationFailure {
            _ = try await service.authenticate(username: "master", password: "wrong horse")
        }
    }

    @MainActor
    @Test func localMasterAuthenticationRejectsEmptyCredentials() async {
        let service = makeLocalAuthenticationService(username: "master", password: "correct horse")

        await expectAuthenticationFailure {
            _ = try await service.authenticate(username: "", password: "")
        }
    }

    @MainActor
    @Test func localMasterAuthenticationTrimsUsernameWhitespace() async throws {
        let service = makeLocalAuthenticationService(username: "master", password: "correct horse")

        let user = try await service.authenticate(username: "  master\n", password: "correct horse")

        #expect(user.username == "master")
    }

    @MainActor
    @Test func localMasterAuthenticationPreservesPasswordWhitespace() async throws {
        let service = makeLocalAuthenticationService(username: "master", password: " correct horse ")

        _ = try await service.authenticate(username: "master", password: " correct horse ")
        await expectAuthenticationFailure {
            _ = try await service.authenticate(username: "master", password: "correct horse")
        }
    }

    @MainActor
    @Test func authenticatedUserDoesNotExposeSubmittedPassword() async throws {
        let password = "correct horse"
        let service = makeLocalAuthenticationService(username: "master", password: password)

        let user = try await service.authenticate(username: "master", password: password)

        #expect(user.id != password)
        #expect(user.username != password)
        #expect(user.displayName != password)
    }

    @MainActor
    @Test func authenticationSessionStartsLoggedOut() {
        let session = AuthenticationSession(authenticationService: SucceedingAuthenticationService())

        #expect(session.state == .loggedOut)
    }

    @MainActor
    @Test func authenticationSessionBecomesAuthenticatedAfterSuccess() async {
        let session = AuthenticationSession(authenticationService: SucceedingAuthenticationService())

        await session.authenticate(username: "master", password: "correct horse")

        #expect(session.authenticatedUser?.role == .master)
    }

    @MainActor
    @Test func authenticationSessionBecomesFailedAfterFailure() async {
        let session = AuthenticationSession(authenticationService: FailingAuthenticationService())

        await session.authenticate(username: "master", password: "wrong horse")

        #expect(session.state == .failed(AuthenticationSession.genericFailureMessage))
    }

    @MainActor
    @Test func duplicateSignInAttemptsPerformOneAuthenticationAttempt() async {
        let service = SuspendedAuthenticationService()
        let session = AuthenticationSession(authenticationService: service)

        let firstAttempt = Task {
            await session.authenticate(username: "master", password: "correct horse")
        }
        await drainMainQueue()
        let secondAttempt = Task {
            await session.authenticate(username: "master", password: "correct horse")
        }
        await drainMainQueue()

        #expect(service.attemptCount == 1)

        service.succeed()
        await firstAttempt.value
        await secondAttempt.value
        #expect(session.isAuthenticated)
    }

    @MainActor
    @Test func authenticationSessionLogoutReturnsToLoggedOut() async {
        let session = AuthenticationSession(authenticationService: SucceedingAuthenticationService())

        await session.authenticate(username: "master", password: "correct horse")
        await session.logOut()

        #expect(session.state == .loggedOut)
    }

    @MainActor
    @Test func authenticationSessionBackgroundAndForegroundDoNotLogOut() async {
        let session = AuthenticationSession(authenticationService: SucceedingAuthenticationService())

        await session.authenticate(username: "master", password: "correct horse")
        session.handleAppEnteredBackground()
        session.handleAppBecameActive()

        #expect(session.isAuthenticated)
    }

    @MainActor
    @Test func loginFormInitialFocusIsNil() {
        let form = LoginFormPresentationState()

        #expect(form.focusedField == nil)
    }

    @MainActor
    @Test func loginFormDisablesEmptyUsernameOrPasswordAndAuthenticatingSubmission() {
        var form = LoginFormPresentationState(username: "", password: "password")
        #expect(!form.canSubmit)

        form.username = "master"
        form.password = ""
        #expect(!form.canSubmit)

        form.password = "password"
        #expect(form.canSubmit)

        form.isAuthenticating = true
        #expect(!form.canSubmit)
    }

    @MainActor
    @Test func loginFormFailureShowsGenericErrorClearsPasswordAndRetainsUsername() {
        var form = LoginFormPresentationState(username: "master", password: "wrong horse")
        form.focusedField = .password

        form.applyFailedAuthentication(message: AuthenticationSession.genericFailureMessage)

        #expect(form.failureMessage == "Invalid username or password.")
        #expect(form.password.isEmpty)
        #expect(form.username == "master")
        #expect(form.focusedField == nil)
    }

    @MainActor
    @Test func sessionRestorationFailureDoesNotRequestLoginFocus() {
        var form = LoginFormPresentationState(username: "master", password: "stored entry")

        form.applyAuthenticationState(.failed(AuthenticationSession.serverUnavailableMessage))

        #expect(form.focusedField == nil)
    }

    @MainActor
    @Test func logoutClearsLoginFocus() {
        var form = LoginFormPresentationState(username: "master", password: "stored entry")
        form.focusedField = .password

        form.applyAuthenticationState(.loggedOut)

        #expect(form.focusedField == nil)
    }

    @MainActor
    @Test func usernameSubmitAdvancesToPasswordOnlyAfterUserInteraction() {
        var form = LoginFormPresentationState(username: "master", password: "stored entry")

        form.submitUsername(userInitiated: false)
        #expect(form.focusedField == nil)

        form.submitUsername(userInitiated: true)
        #expect(form.focusedField == .password)
    }

    @MainActor
    @Test func passwordSubmitIsAllowedOnlyWhenLoginCanSubmit() {
        var form = LoginFormPresentationState(username: "master", password: "stored entry")

        #expect(form.shouldSubmitPassword(sessionIsAuthenticating: false, sessionIsRestoring: false))
        #expect(!form.shouldSubmitPassword(sessionIsAuthenticating: true, sessionIsRestoring: false))
        #expect(!form.shouldSubmitPassword(sessionIsAuthenticating: false, sessionIsRestoring: true))

        form.password = ""
        #expect(!form.shouldSubmitPassword(sessionIsAuthenticating: false, sessionIsRestoring: false))
    }

    @MainActor
    @Test func loginBuildBeginsWithNetworkingUnauthorized() {
        let viewModel = ESP32ControllerViewModel()

        #expect(ESP32ControllerBuildConfiguration.isLoginEnabled)
        #expect(!ESP32ControllerBuildConfiguration.authorizesNetworkingAtLaunch)
        #expect(!viewModel.isNetworkingAuthorized)
    }

    @MainActor
    @Test func zeitBadgeDoesNotModifyAuthenticationState() {
        let session = AuthenticationSession(authenticationService: SucceedingAuthenticationService())

        _ = ZeitBrandBadge(size: .login)

        #expect(session.state == .loggedOut)
    }

    @Test func authenticationAPIClientPostsLoginRequestWithExpectedURLBodyAndContentType() async throws {
        var capturedRequest: URLRequest?
        let client = makeMockedAuthenticationAPIClient { request in
            capturedRequest = request
            return makeHTTPResponse(
                url: try #require(request.url),
                statusCode: 200,
                body: loginResponseData(token: "token-1")
            )
        }

        _ = try await client.login(
            baseURL: testAuthBaseURL,
            username: "example",
            password: "Exact Password"
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.absoluteString == "http://auth.example:8080/api/login")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try requestBodyJSON(request)
        #expect(body["username"] as? String == "example")
        #expect(body["password"] as? String == "Exact Password")
    }

    @Test func authenticationAPIClientDecodesCamelCaseLoginResponse() async throws {
        let client = makeMockedAuthenticationAPIClient { request in
            makeHTTPResponse(
                url: try #require(request.url),
                statusCode: 200,
                body: loginResponseData(token: "token-2", username: "example")
            )
        }

        let response = try await client.login(
            baseURL: testAuthBaseURL,
            username: "example",
            password: "Exact Password"
        )

        #expect(response.token == "token-2")
        #expect(response.expiresAt.timeIntervalSince1970 > 0)
        #expect(response.user.id == 1)
        #expect(response.user.username == "example")
        #expect(response.user.displayName == "Example User")
        #expect(response.user.role == "master")
    }

    @Test func authenticationAPIClientMapsHTTPFailuresAndMalformedJSON() async throws {
        let unauthorized = makeMockedAuthenticationAPIClient(statusCode: 401, body: Data())
        await expectAPIError(.unauthorized) {
            _ = try await unauthorized.login(baseURL: testAuthBaseURL, username: "u", password: "p")
        }

        let rateLimited = makeMockedAuthenticationAPIClient(statusCode: 429, body: Data())
        await expectAPIError(.rateLimited) {
            _ = try await rateLimited.login(baseURL: testAuthBaseURL, username: "u", password: "p")
        }

        let serverFailure = makeMockedAuthenticationAPIClient(statusCode: 500, body: Data())
        await expectAPIError(.serverError(statusCode: 500)) {
            _ = try await serverFailure.login(baseURL: testAuthBaseURL, username: "u", password: "p")
        }

        let malformed = makeMockedAuthenticationAPIClient(statusCode: 200, body: Data("{".utf8))
        await expectAPIError(.malformedResponse) {
            _ = try await malformed.login(baseURL: testAuthBaseURL, username: "u", password: "p")
        }
    }

    @Test func authenticationAPIClientMapsNetworkTimeoutToServerUnavailable() async {
        let client = makeMockedAuthenticationAPIClient { _ in
            throw URLError(.timedOut)
        }

        await expectAPIError(.serverUnavailable) {
            _ = try await client.login(baseURL: testAuthBaseURL, username: "u", password: "p")
        }
    }

    @Test func authenticationAPIClientUsesBearerHeaderForSessionAndLogout() async throws {
        var capturedRequests: [URLRequest] = []
        let client = makeMockedAuthenticationAPIClient { request in
            capturedRequests.append(request)
            let body: Data
            if request.url?.path == "/api/logout" {
                body = Data(#"{"status":"ok"}"#.utf8)
            } else {
                body = sessionResponseData()
            }
            return makeHTTPResponse(url: try #require(request.url), statusCode: 200, body: body)
        }

        _ = try await client.session(baseURL: testAuthBaseURL, token: "session-token")
        try await client.logout(baseURL: testAuthBaseURL, token: "session-token")

        #expect(capturedRequests.map { $0.url?.path } == ["/api/session", "/api/logout"])
        #expect(capturedRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer session-token",
            "Bearer session-token"
        ])
    }

    @Test func authenticationAPIClientHealthUsesConfiguredBaseURL() async throws {
        var capturedURL: URL?
        let client = makeMockedAuthenticationAPIClient { request in
            capturedURL = request.url
            return makeHTTPResponse(
                url: try #require(request.url),
                statusCode: 200,
                body: Data(#"{"status":"ok"}"#.utf8)
            )
        }

        try await client.health(baseURL: URL(string: "http://configured.example:9000")!)

        #expect(capturedURL?.absoluteString == "http://configured.example:9000/api/health")
    }

    @MainActor
    @Test func keychainSessionTokenStoreSavesLoadsReplacesAndDeletesToken() throws {
        let store = KeychainSessionTokenStore(service: "ESP32ControllerTests.\(UUID().uuidString)")
        try store.deleteToken()

        try store.saveToken("first-token")
        #expect(try store.loadToken() == "first-token")

        try store.saveToken("replacement-token")
        #expect(try store.loadToken() == "replacement-token")

        try store.deleteToken()
        #expect(try store.loadToken() == nil)
    }

    @MainActor
    @Test func keychainSessionTokenStoreDoesNotWriteTokenToUserDefaults() throws {
        let defaults = makeIsolatedUserDefaults()
        let store = KeychainSessionTokenStore(service: "ESP32ControllerTests.\(UUID().uuidString)")
        try store.deleteToken()

        try store.saveToken("keychain-only-token")

        let persistedText = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined(separator: "\n")
        #expect(!persistedText.contains("keychain-only-token"))
        try store.deleteToken()
    }

    @MainActor
    @Test func databaseAuthenticationSuccessSavesTokenAndAuthenticates() async {
        let tokenStore = InMemorySessionTokenStore()
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient(statusCode: 200, body: loginResponseData(token: "saved-token"))
        )

        await session.authenticate(username: " Example ", password: "Exact Password")

        #expect(session.authenticatedUser?.username == "example")
        #expect(session.authenticatedUser?.role == .master)
        #expect(tokenStore.token == "saved-token")
    }

    @MainActor
    @Test func databaseAuthenticationStorageFailureDoesNotAuthenticate() async {
        let tokenStore = InMemorySessionTokenStore()
        tokenStore.saveError = SessionTokenStoreError.unexpectedStatus(errSecAuthFailed)
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient(statusCode: 200, body: loginResponseData(token: "unsaved-token"))
        )

        await session.authenticate(username: "example", password: "Exact Password")

        #expect(!session.isAuthenticated)
        #expect(session.failureMessage == AuthenticationSession.genericServerFailureMessage)
    }

    @MainActor
    @Test func databaseAuthenticationFailureMessagesAreNonSensitive() async {
        enum MockFailure {
            case status(Int, Data)
            case timeout
        }

        let cases: [(MockFailure, String)] = [
            (.status(401, Data()), "Invalid username or password."),
            (.status(429, Data()), "Too many login attempts. Please wait and try again."),
            (.timeout, "Authentication server unavailable."),
            (.status(500, Data()), "Authentication failed. Please try again."),
            (.status(200, Data("{".utf8)), "Authentication failed. Please try again.")
        ]

        for (failure, expectedMessage) in cases {
            let client: AuthenticationAPIClient
            switch failure {
            case let .status(statusCode, body):
                client = makeMockedAuthenticationAPIClient(statusCode: statusCode, body: body)
            case .timeout:
                client = makeMockedAuthenticationAPIClient { _ in throw URLError(.timedOut) }
            }
            let session = makeDatabaseAuthenticationSession(apiClient: client)
            await session.authenticate(username: "example", password: "Exact Password")
            #expect(session.failureMessage == expectedMessage)
        }
    }

    @MainActor
    @Test func databaseAuthenticationRejectsUnknownRoles() async {
        let session = makeDatabaseAuthenticationSession(
            apiClient: makeMockedAuthenticationAPIClient(
                statusCode: 200,
                body: loginResponseData(token: "token", role: "operator")
            )
        )

        await session.authenticate(username: "example", password: "Exact Password")

        #expect(!session.isAuthenticated)
        #expect(session.failureMessage == AuthenticationSession.genericServerFailureMessage)
    }

    @MainActor
    @Test func sessionRestoreWithoutTokenShowsLogin() async {
        let session = makeDatabaseAuthenticationSession(tokenStore: InMemorySessionTokenStore())

        await session.restoreStoredSession()

        #expect(session.state == .loggedOut)
    }

    @MainActor
    @Test func sessionRestoreWithValidTokenAuthenticates() async {
        let tokenStore = InMemorySessionTokenStore(token: "stored-token")
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient(statusCode: 200, body: sessionResponseData())
        )

        await session.restoreStoredSession()

        #expect(session.authenticatedUser?.username == "example")
        #expect(session.diagnostics?.provider == "Server")
        #expect(session.diagnostics?.sessionStatus == "Valid")
    }

    @MainActor
    @Test func sessionRestoreWithUnauthorizedTokenDeletesTokenAndShowsLogin() async {
        let tokenStore = InMemorySessionTokenStore(token: "expired-token")
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient(statusCode: 401, body: Data())
        )

        await session.restoreStoredSession()

        #expect(session.state == .loggedOut)
        #expect(tokenStore.token == nil)
    }

    @MainActor
    @Test func sessionRestoreNetworkFailurePreservesTokenAndCanRetry() async {
        let tokenStore = InMemorySessionTokenStore(token: "preserved-token")
        var attempt = 0
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient { request in
                attempt += 1
                if attempt == 1 {
                    throw URLError(.timedOut)
                }
                return makeHTTPResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    body: sessionResponseData()
                )
            }
        )

        await session.restoreStoredSession()
        #expect(!session.isAuthenticated)
        #expect(session.failureMessage == "Authentication server unavailable.")
        #expect(tokenStore.token == "preserved-token")
        #expect(session.canRetrySessionRestore)

        await session.retrySessionRestore()
        #expect(session.isAuthenticated)
        #expect(attempt == 2)
    }

    @MainActor
    @Test func staleRestoreCallbackCannotAuthenticateAfterLogout() async {
        let service = SuspendedRestoreAuthenticationService()
        let session = AuthenticationSession(authenticationService: service)

        let restoreTask = Task {
            await session.restoreStoredSession()
        }
        await drainMainQueue()
        await session.logOut()
        service.succeed()
        await restoreTask.value

        #expect(session.state == .loggedOut)
    }

    @MainActor
    @Test func databaseLogoutDeletesTokenWhenServerIsUnavailable() async {
        let tokenStore = InMemorySessionTokenStore(token: "logout-token")
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            apiClient: makeMockedAuthenticationAPIClient { _ in
                throw URLError(.cannotConnectToHost)
            }
        )

        await session.logOut()

        #expect(session.state == .loggedOut)
        #expect(tokenStore.token == nil)
    }

    @MainActor
    @Test func changingServerConfigurationInvalidatesExistingSession() async {
        let tokenStore = InMemorySessionTokenStore()
        let defaults = makeIsolatedUserDefaults()
        let session = makeDatabaseAuthenticationSession(
            tokenStore: tokenStore,
            userDefaults: defaults,
            apiClient: makeMockedAuthenticationAPIClient { request in
                if request.url?.path == "/api/logout" {
                    return makeHTTPResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        body: Data(#"{"status":"ok"}"#.utf8)
                    )
                }
                return makeHTTPResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    body: loginResponseData(token: "server-change-token")
                )
            }
        )

        await session.authenticate(username: "example", password: "Exact Password")
        session.serverURLText = "https://new-auth.example:9443/"
        try? await session.saveServerConfigurationIfNeeded()

        #expect(session.state == .loggedOut)
        #expect(tokenStore.token == nil)
        #expect(session.serverURLText == "https://new-auth.example:9443")
    }

    @Test func authServerConfigurationValidationAcceptsAndNormalizesValidURLs() throws {
        #expect(try AuthServerConfiguration.normalizedBaseURL(from: "http://auth.example:8080/").absoluteString == "http://auth.example:8080")
        #expect(try AuthServerConfiguration.normalizedBaseURL(from: "https://auth.example").absoluteString == "https://auth.example")
    }

    @Test func authServerConfigurationValidationRejectsUnsafeOrMalformedURLs() {
        for value in [
            "",
            "ftp://auth.example",
            "http://",
            "http://auth.example:70000",
            "http://user:pass@auth.example",
            "http://auth.example?query=1",
            "http://auth.example#fragment"
        ] {
            #expect(throws: AuthServerConfigurationError.self) {
                _ = try AuthServerConfiguration.normalizedBaseURL(from: value)
            }
        }
    }
#endif

    @MainActor
    @Test func loggedOutStartupDoesNotStartDiscoveryOrConnect() {
        var browserCount = 0
        var logoBrowserCount = 0
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() }
        )
        let discoveryService = ESP32DiscoveryService(
            browserFactory: {
                browserCount += 1
                return FakeESP32Browser()
            },
            logoBrowserFactory: {
                logoBrowserCount += 1
                return FakeESP32Browser()
            }
        )
        let viewModel = ESP32ControllerViewModel(client: client, discoveryService: discoveryService)

        viewModel.startDiscovery()
        viewModel.connect()

        #expect(!viewModel.isNetworkingAuthorized)
        #expect(browserCount == 0)
        #expect(logoBrowserCount == 0)
        #expect(recorder.connections.isEmpty)
    }

    @MainActor
    @Test func loggedOutActiveEventDoesNotReconnect() async {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = unauthorizedViewModel(recorder: recorder, userDefaults: defaults)

        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(recorder.connections.isEmpty)
    }

    @MainActor
    @Test func authorizingNetworkingStartsForegroundRecoveryOnce() async {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = unauthorizedViewModel(recorder: recorder, userDefaults: defaults)

        viewModel.authorizeNetworking()
        viewModel.handleAppBecameActive()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(viewModel.isNetworkingAuthorized)
        #expect(recorder.connections.count == 1)
        #expect(viewModel.connectionStatusText.contains("Clock 0"))
    }

    @MainActor
    @Test func logoutStopsHeartbeatAndCancelsControlConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let heartbeatScheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: heartbeatScheduler,
            ackTimeouts: ackTimeouts,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        let connection = try #require(recorder.connections.first)
        connection.stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.revokeNetworkingAuthorization()
        await drainMainQueue()

        #expect(!viewModel.isNetworkingAuthorized)
        #expect(heartbeatScheduler.tasks.first?.isCancelled == true)
        #expect(connection.cancelCallCount >= 1)
    }

    @MainActor
    @Test func logoutCancelsReconnectRetries() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        viewModel.revokeNetworkingAuthorization()

        let allRetriesCancelled = reconnectScheduler.tasks.allSatisfy(\.isCancelled)
        #expect(allRetriesCancelled)
    }

    @MainActor
    @Test func logoutPreventsStaleCallbacksFromRestoringConnectionState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        let connection = try #require(recorder.connections.first)
        let staleHandler = connection.stateUpdateHandler

        viewModel.revokeNetworkingAuthorization()
        staleHandler?(.ready)
        await drainMainQueue()

        #expect(!viewModel.isNetworkingAuthorized)
        #expect(viewModel.state == .disconnected)
    }

    @MainActor
    @Test func loginAfterLogoutPermitsCachedReconnectAgain() async {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            userDefaults: defaults
        )

        viewModel.revokeNetworkingAuthorization()
        viewModel.authorizeNetworking()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(viewModel.isNetworkingAuthorized)
        #expect(recorder.connections.count == 1)
    }

    @MainActor
    @Test func cachedDeviceIdentitySurvivesLogout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        let connection = try #require(recorder.connections.first)
        connection.stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.revokeNetworkingAuthorization()

        #expect(viewModel.lastConnectedDevice?.boardID == 0)
    }

#if LOGIN_ENABLED
    @MainActor
    @Test func authenticationIsNotRestoredAfterSessionRecreation() async {
        let service = SucceedingAuthenticationService()
        let session = AuthenticationSession(authenticationService: service)

        await session.authenticate(username: "master", password: "correct horse")
        let recreated = AuthenticationSession(authenticationService: service)

        #expect(recreated.state == .loggedOut)
    }

    @MainActor
    @Test func authenticationDoesNotWritePlaintextPasswordOrAutoLoginFlagToUserDefaults() async {
        let defaults = makeIsolatedUserDefaults()
        let password = "test credential only"
        let session = AuthenticationSession(
            authenticationService: makeLocalAuthenticationService(
                username: "master",
                password: password
            )
        )

        await session.authenticate(username: "master", password: password)

        let persistedValues = defaults.dictionaryRepresentation()
        #expect(!persistedValues.values.contains { "\($0)".contains(password) })
        #expect(persistedValues.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("authenticated") })
    }
#endif

#if DIRECT_BUILD
    @MainActor
    @Test func directBuildAuthorizesNetworkingImmediatelyByConfiguration() {
        let viewModel = ESP32ControllerViewModel()

        if ESP32ControllerBuildConfiguration.authorizesNetworkingAtLaunch {
            viewModel.authorizeNetworking()
        }

        #expect(!ESP32ControllerBuildConfiguration.isLoginEnabled)
        #expect(viewModel.isNetworkingAuthorized)
    }

    @Test func directBuildHasNoRuntimeLoginBypassState() {
        let defaults = makeIsolatedUserDefaults()

        #expect(!ESP32ControllerBuildConfiguration.isLoginEnabled)
        #expect(ESP32ControllerBuildConfiguration.authorizesNetworkingAtLaunch)
        #expect(defaults.object(forKey: "LOGIN_ENABLED") == nil)
        #expect(defaults.object(forKey: "ESP32Controller.AuthenticationBypass") == nil)
    }
#endif

    @Test func clockProtocolEncodesConnectionTestForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.connectionTest, boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x45, 0x53, 0x5C])
    }

    @Test func clockProtocolEncodesReadConfigurationForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.readConfiguration, boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x52, 0x43, 0x5C])
    }

    @Test func clockProtocolEncodesNextDisplayModeForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.nextDisplayMode, boardID: 0)

        #expect(frame == expectedNMFrame(boardID: 0))
    }

    @Test func clockProtocolEncodesRestoreDefaultLogoForBoardZero() throws {
        let frame = try ClockProtocolEncoder.encode(.restoreDefaultLogo, boardID: 0)

        #expect(frame == expectedDLFrame(boardID: 0))
        #expect(frame.count == 7)
    }

    @Test func clockProtocolEncodesRestoreDefaultLogoWithRawBoardID() throws {
        let frame = try ClockProtocolEncoder.encode(.restoreDefaultLogo, boardID: 0x2A)

        #expect(frame == expectedDLFrame(boardID: 0x2A))
    }

    @Test func clockProtocolEncodesSetConfiguration12HourLevelOne() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: false, brightnessLevel: 1),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x00, 0x19, 0x5C])
    }

    @Test func clockProtocolEncodesSetConfiguration24HourLevelTen() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: true, brightnessLevel: 10),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x01, 0xFF, 0x5C])
    }

    @Test func clockProtocolBrightnessLevelFiveConvertsTo127() throws {
        let frame = try ClockProtocolEncoder.encode(
            .setConfiguration(format24Hour: true, brightnessLevel: 5),
            boardID: 0
        )

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x43, 0x54, 0x01, 0x7F, 0x5C])
    }

    @Test func clockProtocolRejectsBrightnessZero() {
        do {
            _ = try ClockProtocolEncoder.encode(.setConfiguration(format24Hour: true, brightnessLevel: 0), boardID: 0)
            Issue.record("Brightness 0 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidBrightnessLevel)
        }
    }

    @Test func clockProtocolRejectsBrightnessEleven() {
        do {
            _ = try ClockProtocolEncoder.encode(.setConfiguration(format24Hour: true, brightnessLevel: 11), boardID: 0)
            Issue.record("Brightness 11 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidBrightnessLevel)
        }
    }

    @Test func clockProtocolRejectsReservedBoardIDForEveryCommand() {
        let commands: [ClockProtocolCommand] = [
            .connectionTest,
            .readConfiguration,
            .setConfiguration(format24Hour: true, brightnessLevel: 5),
            .syncTime(Date()),
            .nextDisplayMode,
            .reset(resetID: 0),
            .restoreDefaultLogo
        ]

        for command in commands {
            do {
                _ = try ClockProtocolEncoder.encode(command, boardID: 0x5C)
                Issue.record("Board ID 92 should be rejected for \(command)")
            } catch {
                #expect(error as? ClockProtocolEncodingError == .reservedBoardID)
            }
        }
    }

    @Test func clockProtocolEncodesResetFrame() throws {
        let frame = try ClockProtocolEncoder.encode(.reset(resetID: 0x03), boardID: 0)

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x52, 0x54, 0x03, 0x5C])
    }

    @Test func clockProtocolRejectsResetIDDelimiterConflict() {
        do {
            _ = try ClockProtocolEncoder.encode(.reset(resetID: 0x5C), boardID: 0)
            Issue.record("Reset ID 0x5C should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .delimiterConflict)
        }
    }

    @Test func clockProtocolEncodesSyncTimeFrameForFixedGregorianUTCDate() throws {
        let date = try #require(makeUTCDate(year: 2026, month: 6, day: 25, hour: 10, minute: 3, second: 45))
        let frame = try ClockProtocolEncoder.encode(.syncTime(date), boardID: 0, calendar: gregorianUTCCalendar())

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43, 0x45, 0x03, 0x10, 0x05, 0x25, 0x06, 0x26, 0x5C])
        #expect(frame.count == 14)
    }

    @Test func clockProtocolSyncTimeEncodesPackedBCDBoundaries() throws {
        let payload = try ClockProtocolEncoder.encodeSyncTimePayload(
            year: 2099,
            month: 12,
            day: 31,
            weekday: 7,
            hour: 23,
            minute: 59,
            second: 0
        )

        #expect(payload == [0x55, 0x43, 0x00, 0x59, 0x23, 0x07, 0x31, 0x12, 0x99])
    }

    @Test func clockProtocolSyncTimeRejectsInvalidYear() {
        do {
            _ = try ClockProtocolEncoder.encodeSyncTimePayload(
                year: 2024,
                month: 12,
                day: 31,
                weekday: 7,
                hour: 23,
                minute: 59,
                second: 0
            )
            Issue.record("Year 2024 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidDateTime)
        }
    }

    @Test func clockProtocolSyncTimeRejectsInvalidDateComponents() {
        do {
            _ = try ClockProtocolEncoder.encodeSyncTimePayload(
                year: 2026,
                month: 2,
                day: 29,
                weekday: 1,
                hour: 0,
                minute: 0,
                second: 0
            )
            Issue.record("February 29, 2026 should be rejected")
        } catch {
            #expect(error as? ClockProtocolEncodingError == .invalidDateTime)
        }
    }

    @Test func timeSyncCompensationAddsExactlyOneSecondBeforeEncoding() throws {
        let capturedDate = try #require(makeUTCDate(year: 2026, month: 6, day: 25, hour: 10, minute: 3, second: 45))
        let compensatedDate = ESP32ControllerViewModel.compensatedTimeSyncDate(from: capturedDate)
        let frame = try ClockProtocolEncoder.encode(.syncTime(compensatedDate), boardID: 0, calendar: gregorianUTCCalendar())

        #expect(ESP32ControllerViewModel.timeSyncCompensation == 1.0)
        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43, 0x46, 0x03, 0x10, 0x05, 0x25, 0x06, 0x26, 0x5C])
    }

    @Test func timeSyncCompensationRollsSecondsIntoNextMinute() throws {
        let capturedDate = try #require(makeUTCDate(year: 2026, month: 6, day: 25, hour: 10, minute: 3, second: 59))
        let compensatedDate = ESP32ControllerViewModel.compensatedTimeSyncDate(from: capturedDate)
        let frame = try ClockProtocolEncoder.encode(.syncTime(compensatedDate), boardID: 0, calendar: gregorianUTCCalendar())

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43, 0x00, 0x04, 0x10, 0x05, 0x25, 0x06, 0x26, 0x5C])
    }

    @Test func timeSyncCompensationRollsEndOfDayIntoFollowingDate() throws {
        let capturedDate = try #require(makeUTCDate(year: 2026, month: 6, day: 25, hour: 23, minute: 59, second: 59))
        let compensatedDate = ESP32ControllerViewModel.compensatedTimeSyncDate(from: capturedDate)
        let frame = try ClockProtocolEncoder.encode(.syncTime(compensatedDate), boardID: 0, calendar: gregorianUTCCalendar())

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43, 0x00, 0x00, 0x00, 0x06, 0x26, 0x06, 0x26, 0x5C])
    }

    @Test func timeSyncCompensationRollsYearBoundary() throws {
        let capturedDate = try #require(makeUTCDate(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        let compensatedDate = ESP32ControllerViewModel.compensatedTimeSyncDate(from: capturedDate)
        let frame = try ClockProtocolEncoder.encode(.syncTime(compensatedDate), boardID: 0, calendar: gregorianUTCCalendar())

        #expect(frame == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43, 0x00, 0x00, 0x00, 0x06, 0x01, 0x01, 0x27, 0x5C])
    }

    @MainActor
    @Test func guiClockCommandMethodsDoNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.sendConnectionTest()
        viewModel.userSelectedTimeFormat(false)
        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)
        viewModel.syncDeviceTime()
        viewModel.requestClockConfiguration()
        viewModel.requestDeviceReset(resetID: 0)

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.state == .disconnected)
    }

    @MainActor
    @Test func guiClockCommandMethodsDoNotSendWithoutValidBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.manualBoardID = " "
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.sendConnectionTest()
        viewModel.userSelectedTimeFormat(false)
        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)
        viewModel.syncDeviceTime()
        viewModel.requestClockConfiguration()
        viewModel.requestDeviceReset(resetID: 0)

        #expect(viewModel.state == .connected)
        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func userSelecting24HourFrom12HourSendsOneCT() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func userSelecting12HourFrom24HourSendsOneCT() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = true
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(false)

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: false, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func selectingCurrentTimeFormatSendsNothing() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = true

        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func formatSelectionCTIncludesCurrentBrightness() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 10

        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 10)
        ])
    }

    @MainActor
    @Test func movingBrightnessSliderDuringEditingSendsNothing() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessLevel = 7
        viewModel.brightnessLevel = 8

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func releasingChangedBrightnessSliderSendsExactlyOneCTWithFinalValue() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = true
        viewModel.brightnessLevel = 5

        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessLevel = 7
        viewModel.brightnessLevel = 8
        viewModel.brightnessEditingChanged(false)

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 8)
        ])
    }

    @MainActor
    @Test func releasingUnchangedBrightnessSliderSendsNothing() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.brightnessLevel = 5

        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 5
        viewModel.brightnessEditingChanged(false)

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func programmaticClockSettingUpdatesSendNothing() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 9

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func duplicateAutomaticClockConfigurationRequestsAreSuppressed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.userSelectedTimeFormat(true)
        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func explicitDisconnectResetsClockConfigurationDuplicateCache() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.disconnect()
        await drainMainQueue()
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func replacementConnectionResetsClockConfigurationDuplicateCache() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func remoteDisconnectResetsClockConfigurationDuplicateCache() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await drainMainQueue()

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func heartbeatTimeoutResetsClockConfigurationDuplicateCache() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        for _ in 1...3 {
            try fireLatestActiveHeartbeatTask(scheduler)
            await drainMainQueue()
            try fireLatestActiveHeartbeatTask(ackTimeouts)
            await drainMainQueue()
        }

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func staleDisconnectCallbackDoesNotClearClockConfigurationCacheForReplacementConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let staleReceive = try #require(recorder.connections[0].lastReceiveCompletion)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleReceive(nil, nil, true, nil)
        await drainMainQueue()

        viewModel.is24HourFormat = false
        viewModel.userSelectedTimeFormat(true)

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func automaticClockConfigurationLogsReasonAndStatus() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.commandStatusMessage == "Time format command sent")
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "CT Time Format" &&
            $0.bytes == expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        })

        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.commandStatusMessage == "Brightness command sent")
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "CT Brightness" &&
            $0.bytes == expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 6)
        })
    }

    @MainActor
    @Test func explicitSendCurrentSettingsSendsOneCTFrameWithCurrentValues() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 8

        viewModel.sendCurrentClockConfiguration()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(recorder.connections[0].sendCallCount == 1)
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: false, brightnessLevel: 8)
        ])
        #expect(viewModel.commandStatusMessage == "Current settings command sent")
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "CT Send Current Settings" &&
            $0.bytes == expectedCTFrame(boardID: 0, is24Hour: false, brightnessLevel: 8)
        })
    }

    @MainActor
    @Test func explicitSendCurrentSettingsBypassesDuplicateSuppression() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections[0].sendCallCount == 2)
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5),
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func failedAutomaticClockConfigurationCanBeRetriedWithExplicitSend() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.userSelectedTimeFormat(true)
        recorder.connections[0].lastSendCompletion?(NWError.posix(.ECONNRESET))
        await drainMainQueue()

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections[0].sendCallCount == 2)
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5),
            expectedCTFrame(boardID: 0, is24Hour: true, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func explicitSendCurrentSettingsDoesNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections.isEmpty)
    }

    @MainActor
    @Test func explicitSendCurrentSettingsDoesNotSendWithoutValidBoardID() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: " ")

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func explicitSendCurrentSettingsDoesNotSendForReservedBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-reserved-current", serviceName: "ESP32 Reserved Current", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func explicitSendCurrentSettingsKeepsCacheIsolatedAfterConnectionReplacement() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")
        viewModel.is24HourFormat = false
        viewModel.brightnessLevel = 5

        viewModel.sendCurrentClockConfiguration()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.sendCurrentClockConfiguration()

        #expect(recorder.connections[1].sendCallCount == 1)
        #expect(recorder.connections[1].sentContents.map { $0.map(Array.init) } == [
            expectedCTFrame(boardID: 0, is24Hour: false, brightnessLevel: 5)
        ])
    }

    @MainActor
    @Test func automaticClockConfigurationInteractionsDoNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.userSelectedTimeFormat(false)
        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)

        #expect(recorder.connections.isEmpty)
    }

    @MainActor
    @Test func automaticClockConfigurationInteractionsDoNotSendWithoutValidBoardID() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: " ")

        viewModel.userSelectedTimeFormat(false)
        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func automaticClockConfigurationInteractionsDoNotSendForReservedDiscoveredBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-reserved", serviceName: "ESP32 Reserved", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.userSelectedTimeFormat(false)
        viewModel.brightnessEditingChanged(true)
        viewModel.brightnessLevel = 6
        viewModel.brightnessEditingChanged(false)

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func syncDeviceTimeSendsExactlyOneCompensatedUCFrameAndLogsTransmission() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let fixedDate = try #require(makeUTCDate(year: 2026, month: 6, day: 25, hour: 10, minute: 3, second: 45))
        let timeSyncScheduler = FakeHeartbeatScheduler()
        var dateProviderCallCount = 0
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            currentDateProvider: {
                dateProviderCallCount += 1
                return fixedDate
            },
            timeSyncScheduler: timeSyncScheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.syncDeviceTime()

        let connection = recorder.connections[0]
        #expect(dateProviderCallCount == 1)
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.count == 1)
        let sentFrame = try #require(connection.sentContents[0].map(Array.init))
        #expect(sentFrame.count == 14)
        #expect(Array(sentFrame.prefix(6)) == [0x2F, 0x54, 0x41, 0x00, 0x55, 0x43])
        #expect(sentFrame.last == 0x5C)
        #expect(viewModel.timeSyncState == .sending)
        #expect(timeSyncScheduler.tasks.isEmpty)

        connection.lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.commandStatusMessage == "Time synchronization command sent")
        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(timeSyncScheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.timeSyncConfirmationTimeout])
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "UC Sync Time" &&
            $0.bytes == sentFrame
        })
    }

    @MainActor
    @Test func timeSyncTimeoutIsNotScheduledBeforeSendCompletionSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()

        #expect(viewModel.timeSyncState == .sending)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func delayedTimeSyncSendDoesNotTimeoutBeforeCompletion() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.timeSyncState == .sending)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func successfulTimeSyncSendCompletionStartsConfirmationTimeout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(scheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.timeSyncConfirmationTimeout])
    }

    @MainActor
    @Test func timeSyncSendFailureDoesNotStartConfirmationTimeout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(NWError.posix(.ECONNRESET))
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.timeSyncState == .failed("Unable to send time synchronization command"))
        #expect(viewModel.commandStatusMessage == "Unable to send time synchronization command")
    }

    @MainActor
    @Test func matchingUCAcknowledgementSetsTimeSyncSucceeded() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .succeeded)
        #expect(viewModel.commandStatusMessage == "Time synchronized successfully")
        #expect(viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.logEntries.contains {
            $0.direction == .incoming &&
            $0.message == "UC Sync Time Confirmed" &&
            $0.bytes == expectedUCAcknowledgement(boardID: 0)
        })
    }

    @MainActor
    @Test func oneValidUCAcknowledgementPresentsExactlyOneSuccessAlert() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))
        var alertPresentationCount = 0
        var cancellables: Set<AnyCancellable> = []
        viewModel.$isTimeSyncSuccessAlertPresented
            .dropFirst()
            .filter { $0 }
            .sink { _ in alertPresentationCount += 1 }
            .store(in: &cancellables)

        viewModel.syncDeviceTime()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(alertPresentationCount == 1)
        #expect(viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func validUCAcknowledgementBeforeSendCompletionStillSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .succeeded)
        #expect(viewModel.isTimeSyncSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func lateSendCompletionAfterEarlyUCAcknowledgementDoesNotStartTimeout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .succeeded)
        #expect(viewModel.isTimeSyncSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func staleTimeSyncSendCompletionCannotAffectNewerOperation() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()
        let staleSendCompletion = try #require(recorder.connections[0].lastSendCompletion)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()

        staleSendCompletion(nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .sending)
        #expect(scheduler.tasks.isEmpty)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func staleTimeSyncTimeoutCannotAffectNewerOperation() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let staleTimeout = try #require(scheduler.tasks.first)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleTimeout.fireIgnoringCancellationForTesting()
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(viewModel.commandStatusMessage == "Time synchronization command sent")
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func dismissingTimeSyncSuccessAlertClearsPresentationState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        viewModel.dismissTimeSyncSuccessAlert()

        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.timeSyncState == .idle)
    }

    @MainActor
    @Test func duplicateUCAcknowledgementDoesNotReopenSuccessAlert() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()
        viewModel.dismissTimeSyncSuccessAlert()

        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.timeSyncState == .idle)
    }

    @MainActor
    @Test func wrongBoardUCAcknowledgementDoesNotSetSucceeded() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 1)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.logEntries.contains {
            $0.direction == .incoming &&
            $0.bytes == expectedUCAcknowledgement(boardID: 1)
        })
    }

    @MainActor
    @Test func unrelatedAcknowledgementDoesNotSetTimeSyncSucceeded() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let unrelatedACK: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x63, 0x74, 0x5C]
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(unrelatedACK), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == unrelatedACK })
    }

    @MainActor
    @Test func malformedUCAcknowledgementDoesNotSetTimeSyncSucceeded() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let malformedACK: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x75, 0x63, 0x00, 0x5C]
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(malformedACK), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == malformedACK })
    }

    @MainActor
    @Test func staleUCAcknowledgementDoesNotAffectActiveConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()
        let staleReceive = try #require(recorder.connections[0].lastReceiveCompletion)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.syncDeviceTime()
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleReceive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .waitingForConfirmation)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(recorder.connections[1].cancelCallCount == 0)
    }

    @MainActor
    @Test func timeSyncTimeoutReportsNotConfirmed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        #expect(scheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.timeSyncConfirmationTimeout])
        scheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .failed("Time synchronization not confirmed"))
        #expect(viewModel.commandStatusMessage == "Time synchronization not confirmed")
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func matchingUCAcknowledgementCancelsTimeout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(scheduler.tasks[0].isCancelled)
        scheduler.tasks[0].fire()
        await drainMainQueue()
        #expect(viewModel.timeSyncState == .succeeded)
        #expect(viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func disconnectClearsPendingTimeSyncSuccessAlert() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedUCAcknowledgement(boardID: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .succeeded)
        #expect(viewModel.isTimeSyncSuccessAlertPresented)

        viewModel.disconnect()
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .idle)
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
    }

    @MainActor
    @Test func timeSyncSendFailureReportsUnableToSend() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.syncDeviceTime()
        recorder.connections[0].lastSendCompletion?(NWError.posix(.ECONNRESET))
        await drainMainQueue()

        #expect(viewModel.timeSyncState == .failed("Unable to send time synchronization command"))
        #expect(viewModel.commandStatusMessage == "Unable to send time synchronization command")
        #expect(!viewModel.isTimeSyncSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func nextDisplayModeDoesNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.requestNextDisplayMode()

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.displayModeChangeState == .failed("Connect to an ESP32 before sending clock commands."))
    }

    @MainActor
    @Test func nextDisplayModeDoesNotSendWithoutValidBoardID() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: " ")

        viewModel.requestNextDisplayMode()

        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.displayModeChangeState == .failed(ClockProtocolEncodingError.missingBoardID.localizedDescription))
    }

    @MainActor
    @Test func nextDisplayModeDoesNotSendForReservedBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-reserved-nm", serviceName: "ESP32 Reserved NM", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.requestNextDisplayMode()

        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.displayModeChangeState == .failed(ClockProtocolEncodingError.missingBoardID.localizedDescription))
    }

    @MainActor
    @Test func nextDisplayModeSendsExactlyOneNMFrameAndLogsRequest() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [expectedNMFrame(boardID: 0)])
        #expect(viewModel.displayModeChangeState == .sending)
        #expect(scheduler.tasks.isEmpty)

        connection.lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.commandStatusMessage == "Display mode command sent")
        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(scheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.timeSyncConfirmationTimeout])
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "NM Next Display Mode" &&
            $0.bytes == expectedNMFrame(boardID: 0)
        })
    }

    @MainActor
    @Test func nextDisplayModeSendCompletionAloneDoesNotPresentSuccess() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.confirmedDisplayMode == nil)
    }

    @MainActor
    @Test func nextDisplayModeSendFailureDoesNotStartTimeoutAndReportsFailure() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(NWError.posix(.ECONNRESET))
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.displayModeChangeState == .failed("Unable to send display mode command"))
        #expect(viewModel.commandStatusMessage == "Unable to send display mode command")
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
    }

    @MainActor
    @Test func validNextDisplayModeResponseWithModeOneSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedNMResponse(boardID: 0, mode: 1)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .succeeded(mode: 1))
        #expect(viewModel.confirmedDisplayMode == 1)
        #expect(viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.commandStatusMessage == "Display mode changed to Mode 1")
        #expect(viewModel.logEntries.contains {
            $0.direction == .incoming &&
            $0.message == "NM Display Mode Confirmed" &&
            $0.bytes == expectedNMResponse(boardID: 0, mode: 1)
        })
    }

    @MainActor
    @Test func validNextDisplayModeResponseWithModeFourSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedNMResponse(boardID: 0, mode: 4)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .succeeded(mode: 4))
        #expect(viewModel.confirmedDisplayMode == 4)
        #expect(viewModel.isDisplayModeSuccessAlertPresented)
    }

    @MainActor
    @Test func invalidNextDisplayModeValuesDoNotSucceed() async throws {
        for invalidMode in [UInt8(0), UInt8(5)] {
            let recorder = FakeTCPConnectionRecorder()
            let scheduler = FakeHeartbeatScheduler()
            let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

            viewModel.requestNextDisplayMode()
            recorder.connections[0].lastSendCompletion?(nil)
            await drainMainQueue()
            let receive = try #require(recorder.connections[0].lastReceiveCompletion)
            let response = expectedNMResponse(boardID: 0, mode: invalidMode)
            receive(Data(response), nil, false, nil)
            await drainMainQueue()

            #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
            #expect(!viewModel.isDisplayModeSuccessAlertPresented)
            #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == response })
        }
    }

    @MainActor
    @Test func wrongBoardNextDisplayModeResponseDoesNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let response = expectedNMResponse(boardID: 1, mode: 1)
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(response), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == response })
    }

    @MainActor
    @Test func malformedNextDisplayModeResponseDoesNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let malformedResponse: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x6E, 0x6D, 0x01, 0x02, 0x5C]
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(malformedResponse), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == malformedResponse })
    }

    @MainActor
    @Test func unrelatedResponseDuringNextDisplayModeIsForwardedNormally() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let unrelatedResponse = expectedUCAcknowledgement(boardID: 0)
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(unrelatedResponse), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == unrelatedResponse })
    }

    @MainActor
    @Test func validNextDisplayModeResponseBeforeSendCompletionStillSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedNMResponse(boardID: 0, mode: 2)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .succeeded(mode: 2))
        #expect(viewModel.confirmedDisplayMode == 2)
        #expect(viewModel.isDisplayModeSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func lateSendCompletionAfterEarlyNextDisplayModeResponseIsIgnored() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedNMResponse(boardID: 0, mode: 2)), nil, false, nil)
        await drainMainQueue()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .succeeded(mode: 2))
        #expect(viewModel.isDisplayModeSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func duplicateNextDisplayModeResponseDoesNotReopenAlert() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedNMResponse(boardID: 0, mode: 3)), nil, false, nil)
        await drainMainQueue()
        viewModel.dismissDisplayModeSuccessAlert()

        receive(Data(expectedNMResponse(boardID: 0, mode: 3)), nil, false, nil)
        await drainMainQueue()

        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.displayModeChangeState == .idle)
    }

    @MainActor
    @Test func staleNextDisplayModeResponseDoesNotAffectActiveConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.requestNextDisplayMode()
        let staleReceive = try #require(recorder.connections[0].lastReceiveCompletion)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.requestNextDisplayMode()
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleReceive(Data(expectedNMResponse(boardID: 0, mode: 1)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .waitingForConfirmation)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.confirmedDisplayMode == nil)
    }

    @MainActor
    @Test func nextDisplayModeTimeoutReportsNotConfirmed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .failed("Display mode change not confirmed"))
        #expect(viewModel.commandStatusMessage == "Display mode change not confirmed")
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
    }

    @MainActor
    @Test func disconnectClearsPendingNextDisplayModeState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.requestNextDisplayMode()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.disconnect()
        await drainMainQueue()

        #expect(viewModel.displayModeChangeState == .idle)
        #expect(!viewModel.isDisplayModeSuccessAlertPresented)
        #expect(viewModel.confirmedDisplayMode == nil)
        #expect(scheduler.tasks[0].isCancelled)
    }

    @MainActor
    @Test func restoreDefaultLogoDoesNotSendWhileDisconnected() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)

        viewModel.restoreDefaultLogo()

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.defaultLogoRestoreState == .failed("Connect to an ESP32 before sending clock commands."))
    }

    @MainActor
    @Test func restoreDefaultLogoDoesNotSendWithoutValidBoardID() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: " ")

        viewModel.restoreDefaultLogo()

        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.defaultLogoRestoreState == .failed(ClockProtocolEncodingError.missingBoardID.localizedDescription))
        #expect(!viewModel.canRestoreDefaultLogo)
    }

    @MainActor
    @Test func restoreDefaultLogoDoesNotSendForReservedBoardID() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-reserved-dl", serviceName: "ESP32 Reserved DL", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.restoreDefaultLogo()

        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(!viewModel.canRestoreDefaultLogo)
    }

    @MainActor
    @Test func cancellingRestoreDefaultLogoConfirmationSendsNothing() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.presentRestoreDefaultLogoConfirmation()
        viewModel.isRestoreDefaultLogoConfirmationPresented = false

        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func confirmingRestoreDefaultLogoSendsExactlyOneDLFrameAndLogsRequest() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()

        let connection = recorder.connections[0]
        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents.map { $0.map(Array.init) } == [expectedDLFrame(boardID: 0)])
        #expect(viewModel.defaultLogoRestoreState == .sending)
        #expect(scheduler.tasks.isEmpty)

        connection.lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(viewModel.commandStatusMessage == "Default-logo restore command sent")
        #expect(scheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.defaultLogoRestoreConfirmationTimeout])
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "DL Restore Default Logo" &&
            $0.bytes == expectedDLFrame(boardID: 0)
        })
    }

    @MainActor
    @Test func repeatedRestoreDefaultLogoConfirmationCannotSendDuplicateFrames() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.restoreDefaultLogo()
        viewModel.restoreDefaultLogo()

        #expect(recorder.connections[0].sendCallCount == 1)
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [expectedDLFrame(boardID: 0)])
    }

    @MainActor
    @Test func restoreDefaultLogoSendCompletionAloneDoesNotPresentSuccess() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func successfulRestoreDefaultLogoSendCompletionStartsConfirmationTimeout() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(scheduler.tasks.map(\.delay) == [ESP32ControllerViewModel.defaultLogoRestoreConfirmationTimeout])
    }

    @MainActor
    @Test func restoreDefaultLogoResultZeroPresentsSuccess() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .succeeded)
        #expect(viewModel.commandStatusMessage == "Default logo restored")
        #expect(viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains {
            $0.direction == .incoming &&
            $0.message == "DL Restore Default Logo Confirmed" &&
            $0.bytes == expectedDLResponse(boardID: 0, result: 0x00)
        })
    }

    @MainActor
    @Test func restoreDefaultLogoResultOneReportsBusy() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x01)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .failed("A logo update is already in progress."))
        #expect(viewModel.commandStatusMessage == "A logo update is already in progress.")
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func restoreDefaultLogoResultTwoReportsStorageFailure() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x02)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .failed("The ESP32 could not remove the SD-card logo."))
        #expect(viewModel.commandStatusMessage == "The ESP32 could not remove the SD-card logo.")
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func wrongBoardRestoreDefaultLogoResponseDoesNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let response = expectedDLResponse(boardID: 1, result: 0x00)
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(response), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == response })
    }

    @MainActor
    @Test func malformedRestoreDefaultLogoResponseDoesNotSucceedOrCorruptPendingOperation() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let malformedResponse: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x64, 0x6C, 0x00, 0x00, 0x5C]
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(malformedResponse), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == malformedResponse })

        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .succeeded)
        #expect(viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func invalidRestoreDefaultLogoResultByteDoesNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let response = expectedDLResponse(boardID: 0, result: 0x03)
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(response), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == response })
    }

    @MainActor
    @Test func missingRestoreDefaultLogoDelimiterDoesNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data([0x2F, 0x74, 0x61, 0x00, 0x64, 0x6C, 0x00]), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func extraBytesInRestoreDefaultLogoResponseDoNotSucceed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let response: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x64, 0x6C, 0x00, 0x99, 0x5C]
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(response), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == response })
    }

    @MainActor
    @Test func unrelatedResponseDuringRestoreDefaultLogoIsForwardedNormally() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let unrelatedResponse = expectedUCAcknowledgement(boardID: 0)
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(unrelatedResponse), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.logEntries.contains { $0.direction == .incoming && $0.bytes == unrelatedResponse })
    }

    @MainActor
    @Test func validRestoreDefaultLogoAcknowledgementBeforeSendCompletionSucceeds() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .succeeded)
        #expect(viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.logEntries.contains {
            $0.direction == .outgoing &&
            $0.message == "DL Restore Default Logo" &&
            $0.bytes == expectedDLFrame(boardID: 0)
        })
    }

    @MainActor
    @Test func lateSendCompletionAfterEarlyRestoreDefaultLogoAcknowledgementIsIgnored() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .succeeded)
        #expect(viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(scheduler.tasks.isEmpty)
    }

    @MainActor
    @Test func duplicateRestoreDefaultLogoAcknowledgementDoesNotReopenAlert() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))
        var alertPresentationCount = 0
        var cancellables: Set<AnyCancellable> = []
        viewModel.$isDefaultLogoRestoreSuccessAlertPresented
            .dropFirst()
            .filter { $0 }
            .sink { _ in alertPresentationCount += 1 }
            .store(in: &cancellables)

        viewModel.restoreDefaultLogo()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()
        viewModel.dismissDefaultLogoRestoreSuccessAlert()

        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(alertPresentationCount == 1)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(viewModel.defaultLogoRestoreState == .idle)
    }

    @MainActor
    @Test func staleRestoreDefaultLogoAcknowledgementDoesNotAffectActiveConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.restoreDefaultLogo()
        let staleReceive = try #require(recorder.connections[0].lastReceiveCompletion)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.restoreDefaultLogo()
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleReceive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func restoreDefaultLogoTimeoutReportsNotConfirmed() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .failed(ESP32ControllerViewModel.defaultLogoRestoreTimeoutMessage))
        #expect(viewModel.commandStatusMessage == ESP32ControllerViewModel.defaultLogoRestoreTimeoutMessage)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func disconnectClearsPendingRestoreDefaultLogoState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0", timeSyncScheduler: scheduler.schedule(_:_:))

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        viewModel.disconnect()
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .idle)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
        #expect(scheduler.tasks[0].isCancelled)
    }

    @MainActor
    @Test func staleRestoreDefaultLogoTimeoutCannotAffectNewerOperation() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            timeSyncScheduler: scheduler.schedule(_:_:)
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let staleTimeout = try #require(scheduler.tasks.first)

        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()
        viewModel.restoreDefaultLogo()
        recorder.connections[1].lastSendCompletion?(nil)
        await drainMainQueue()

        staleTimeout.fireIgnoringCancellationForTesting()
        await drainMainQueue()

        #expect(viewModel.defaultLogoRestoreState == .waitingForConfirmation)
        #expect(viewModel.commandStatusMessage == "Default-logo restore command sent")
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @MainActor
    @Test func successfulRestoreDefaultLogoRetainsConvertedLogoState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let payload = makeLogoPayload(red: 21, green: 22, blue: 23)
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            timeSyncScheduler: scheduler.schedule(_:_:)
        )
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)
        let previewWidth = viewModel.processedLogoPreview?.width
        let previewHeight = viewModel.processedLogoPreview?.height

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x00)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == payload)
        #expect(viewModel.processedLogoPreview?.width == previewWidth)
        #expect(viewModel.processedLogoPreview?.height == previewHeight)
        #expect(viewModel.logoUploadState == .ready)
        #expect(viewModel.canUploadLogo)
    }

    @MainActor
    @Test func failedRestoreDefaultLogoRetainsConvertedLogoState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let scheduler = FakeHeartbeatScheduler()
        let payload = makeLogoPayload(red: 31, green: 32, blue: 33)
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            timeSyncScheduler: scheduler.schedule(_:_:)
        )
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)
        let previewWidth = viewModel.processedLogoPreview?.width
        let previewHeight = viewModel.processedLogoPreview?.height

        viewModel.restoreDefaultLogo()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(expectedDLResponse(boardID: 0, result: 0x01)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == payload)
        #expect(viewModel.processedLogoPreview?.width == previewWidth)
        #expect(viewModel.processedLogoPreview?.height == previewHeight)
        #expect(viewModel.logoUploadState == .ready)
    }

    @MainActor
    @Test func deviceDefaultConfigurationStillSendsExactlyOneRTRequest() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.requestDeviceReset(resetID: 0x00)

        #expect(recorder.connections[0].sendCallCount == 1)
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [
            [0x2F, 0x54, 0x41, 0x00, 0x52, 0x54, 0x00, 0x5C]
        ])
    }

    @MainActor
    @Test func deviceDefaultConfigurationSendsNoAdditionalDLRequest() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(recorder: recorder, boardID: "0")

        viewModel.requestDeviceReset(resetID: 0x00)
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()

        let sentFrames = recorder.connections[0].sentContents.compactMap { $0.map(Array.init) }
        #expect(sentFrames.count == 1)
        #expect(!sentFrames.contains(expectedDLFrame(boardID: 0)))
        #expect(viewModel.defaultLogoRestoreState == .idle)
        #expect(!viewModel.isDefaultLogoRestoreSuccessAlertPresented)
    }

    @Test func deviceDefaultConfigurationWordingMentionsCompiledDefaultLogo() {
        #expect(ESP32ControllerViewModel.deviceDefaultConfigurationConfirmationMessage.contains("compiled default logo"))
    }

    @MainActor
    @Test func inactiveDoesNotDisconnectHealthyConnection() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(
            recorder: recorder,
            boardID: "0",
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.handleAppBecameInactive()
        await drainMainQueue()

        #expect(viewModel.state == .connected)
        #expect(recorder.connections[0].cancelCallCount == 0)
        #expect(viewModel.appPhaseDiagnosticsText == "Inactive")
    }

    @MainActor
    @Test func backgroundStopsHeartbeatAndPreservesLastDeviceAndLogoData() async throws {
        let controlRecorder = FakeTCPConnectionRecorder()
        let heartbeatScheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let payload = makeLogoPayload(red: 3, green: 4, blue: 5)
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in controlRecorder.makeConnection() },
            endpointConnectionFactory: { _ in controlRecorder.makeConnection() },
            heartbeatScheduler: heartbeatScheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            ),
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            userDefaults: makeIsolatedUserDefaults()
        )
        viewModel.authorizeNetworking()

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        viewModel.handleAppEnteredBackground()
        await drainMainQueue()

        #expect(heartbeatScheduler.tasks.first?.isCancelled == true)
        #expect(viewModel.lastConnectedDevice?.boardID == 0)
        #expect(viewModel.resumeActionDiagnosticsText == "Backgrounded")
        #expect(viewModel.convertedLogoPayload == payload)
        #expect(viewModel.processedLogoPreview != nil)
        #expect(controlRecorder.connections[0].cancelCallCount >= 1)
    }

    @MainActor
    @Test func activeWithNoCachedDeviceDoesNotConnect() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.appPhaseDiagnosticsText == "Active")
    }

    @MainActor
    @Test func repeatedActiveEventsDoNotCreateDuplicateReconnectConnections() async {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(
            LastConnectedDevice(
                boardID: 0,
                displayName: "Clock 0",
                serviceInstanceName: "Clock 0",
                serviceType: ESP32DiscoveryService.serviceType,
                serviceDomain: "local",
                hostname: "esp32-clock-0.local",
                controlPort: ESP32TCPClient.defaultPort,
                source: .bonjour,
                manualHost: nil
            ),
            to: defaults
        )
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: FakeHeartbeatScheduler().schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(recorder.connections.count == 1)
        #expect(viewModel.connectionStatusText == "Reconnecting to Clock 0…")
    }

    @MainActor
    @Test func inactiveDuringReconnectDoesNotDropScheduledRetries() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        viewModel.handleAppBecameInactive()
        reconnectScheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.appPhaseDiagnosticsText == "Inactive")
        #expect(recorder.connections.count == 2)
    }

    @MainActor
    @Test func successfulManualConnectionStoresManualLastDeviceAndSurvivesRecreation() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder, userDefaults: defaults)

        viewModel.host = "192.168.4.1"
        viewModel.port = "5000"
        viewModel.manualBoardID = "7"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.lastConnectedDevice?.boardID == 7)
        #expect(viewModel.lastConnectedDevice?.source == .manual)
        #expect(viewModel.lastConnectedDevice?.manualHost == "192.168.4.1")

        let recreated = makeViewModelForConnectionIndicatorTests(
            recorder: FakeTCPConnectionRecorder(),
            userDefaults: defaults
        )
        #expect(recreated.lastConnectedDevice == viewModel.lastConnectedDevice)
    }

    @MainActor
    @Test func successfulBonjourConnectionStoresDeviceIdentity() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder, userDefaults: defaults)
        let device = makeDevice(id: "service-clock-0", serviceName: "Clock 0", boardID: "0")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.lastConnectedDevice?.boardID == 0)
        #expect(viewModel.lastConnectedDevice?.displayName == "Clock 0")
        #expect(viewModel.lastConnectedDevice?.serviceInstanceName == "Clock 0")
        #expect(viewModel.lastConnectedDevice?.serviceType == ESP32DiscoveryService.serviceType)
        #expect(viewModel.lastConnectedDevice?.hostname == "esp32-clock-0.local")
    }

    @MainActor
    @Test func failedConnectionDoesNotReplaceLastSuccessfulDevice() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let defaults = makeIsolatedUserDefaults()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder, userDefaults: defaults)

        viewModel.manualBoardID = "1"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let originalRecord = viewModel.lastConnectedDevice

        viewModel.manualBoardID = "2"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.lastConnectedDevice == originalRecord)
    }

    @MainActor
    @Test func boardIDNinetyTwoIsNotPersistedAsLastDevice() {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.manualBoardID = "92"
        viewModel.connect()

        #expect(recorder.connections.isEmpty)
        #expect(viewModel.lastConnectedDevice == nil)
    }

    @MainActor
    @Test func explicitDisconnectPreventsForegroundAutoReconnect() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(
            recorder: recorder,
            boardID: "0",
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.disconnect()
        await drainMainQueue()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(recorder.connections.count == 1)
        #expect(viewModel.autoReconnectDiagnosticsText == "Disabled")
    }

    @MainActor
    @Test func explicitConnectEnablesAutoReconnectAgain() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(
            recorder: recorder,
            boardID: "0",
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.disconnect()
        await drainMainQueue()
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()

        #expect(viewModel.autoReconnectDiagnosticsText == "Enabled")
    }

    @MainActor
    @Test func activeHealthyConnectionValidatesWithNewHeartbeat() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let heartbeatScheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: heartbeatScheduler,
            ackTimeouts: ackTimeouts,
            userDefaults: makeIsolatedUserDefaults()
        )
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.handleAppBecameActive()
        await drainMainQueue()

        let expected = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0, sequence: 0))
        #expect(recorder.connections[0].sentContents.map { $0.map(Array.init) } == [expected])
        #expect(ackTimeouts.tasks.map(\.delay).contains(ESP32ControllerViewModel.foregroundHeartbeatValidationTimeout))
        #expect(viewModel.foregroundValidationDiagnosticsText == "Waiting for heartbeat")

        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        #expect(viewModel.foregroundValidationDiagnosticsText == "Waiting for heartbeat")

        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0, sequence: 0)), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.state == .connected)
        #expect(viewModel.foregroundValidationDiagnosticsText == "Confirmed")
        #expect(heartbeatScheduler.tasks.last?.delay == 1)
    }

    @MainActor
    @Test func wrongForegroundHeartbeatSequenceTimesOutAndStartsReconnect() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let heartbeatScheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: heartbeatScheduler,
            ackTimeouts: ackTimeouts,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: makeIsolatedUserDefaults()
        )
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        let receive = try #require(recorder.connections[0].lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0, sequence: 1)), nil, false, nil)
        await drainMainQueue()
        ackTimeouts.tasks.last?.fire()
        await drainMainQueue()

        #expect(recorder.connections.count == 2)
        #expect(recorder.connections[0].cancelCallCount >= 1)
        #expect(viewModel.endpointSourceDiagnosticsText == "Cached Manual Host")
    }

    @MainActor
    @Test func cachedBonjourServiceIsUsedWithoutRequiringScan() async {
        let recorder = FakeTCPConnectionRecorder()
        var requestedEndpoints: [NWEndpoint] = []
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { endpoint in
                requestedEndpoints.append(endpoint)
                return recorder.makeConnection()
            }
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            ),
            userDefaults: defaults
        )
        viewModel.authorizeNetworking()

        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(requestedEndpoints.first == NWEndpoint.service(
            name: "Clock 0",
            type: ESP32DiscoveryService.serviceType,
            domain: "local",
            interface: nil
        ))
        #expect(viewModel.endpointSourceDiagnosticsText == "Cached Bonjour")
    }

    @MainActor
    @Test func cachedHostnameIsUsedAfterCachedBonjourAttempt() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        var requestedEndpoints: [NWEndpoint] = []
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { endpoint in
                requestedEndpoints.append(endpoint)
                return recorder.makeConnection()
            }
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            ),
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )
        viewModel.authorizeNetworking()

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        reconnectScheduler.tasks.first?.fire()
        await drainMainQueue()

        #expect(requestedEndpoints.count == 2)
        #expect(String(describing: requestedEndpoints[1]).contains("esp32-clock-0.local"))
        #expect(viewModel.endpointSourceDiagnosticsText == "Cached Hostname")
    }

    @MainActor
    @Test func cachedManualHostIsUsedForPreviousManualConnection() async {
        let recorder = FakeTCPConnectionRecorder()
        var requestedEndpoints: [NWEndpoint] = []
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(
            LastConnectedDevice(
                boardID: 5,
                displayName: "192.168.4.55",
                serviceInstanceName: nil,
                serviceType: nil,
                serviceDomain: nil,
                hostname: "192.168.4.55",
                controlPort: 5000,
                source: .manual,
                manualHost: "192.168.4.55"
            ),
            to: defaults
        )
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { endpoint in
                requestedEndpoints.append(endpoint)
                return recorder.makeConnection()
            }
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            ),
            userDefaults: defaults
        )
        viewModel.authorizeNetworking()

        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(String(describing: requestedEndpoints.first).contains("192.168.4.55"))
        #expect(viewModel.endpointSourceDiagnosticsText == "Cached Manual Host")
    }

    @MainActor
    @Test func reconnectRetriesAreBoundedAndSuccessCancelsRemainingRetries() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        #expect(reconnectScheduler.tasks.map(\.delay) == [0.5, 1, 2])

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let successCancelledRemainingRetries = reconnectScheduler.tasks.allSatisfy { $0.isCancelled }
        #expect(successCancelledRemainingRetries)

        let boundedRecorder = FakeTCPConnectionRecorder()
        let boundedScheduler = FakeHeartbeatScheduler()
        let boundedViewModel = makeViewModelForConnectionIndicatorTests(
            recorder: boundedRecorder,
            reconnectScheduler: boundedScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        boundedViewModel.handleAppBecameActive()
        await drainMainQueue()
        boundedScheduler.tasks[0].fire()
        boundedScheduler.tasks[1].fire()
        boundedScheduler.tasks[2].fire()
        await drainMainQueue()
        #expect(boundedRecorder.connections.count == 4)
    }

    @MainActor
    @Test func reconnectSettlesAfterFinalAutomaticAttemptFails() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        reconnectScheduler.tasks[0].fire()
        reconnectScheduler.tasks[1].fire()
        reconnectScheduler.tasks[2].fire()
        await drainMainQueue()

        recorder.connections[3].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.connectionStatusText != "Reconnecting to Clock 0…")
        #expect(viewModel.resumeActionDiagnosticsText == "Idle")
        #expect(viewModel.endpointSourceDiagnosticsText == "None")
    }

    @MainActor
    @Test func backgroundAndDeviceSelectionCancelScheduledReconnectRetries() async {
        let recorder = FakeTCPConnectionRecorder()
        let reconnectScheduler = FakeHeartbeatScheduler()
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForConnectionIndicatorTests(
            recorder: recorder,
            reconnectScheduler: reconnectScheduler.schedule(_:_:),
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        viewModel.handleAppEnteredBackground()
        await drainMainQueue()
        let backgroundCancelledRetries = reconnectScheduler.tasks.allSatisfy { $0.isCancelled }
        #expect(backgroundCancelledRetries)

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        viewModel.connect(to: makeDevice(id: "other", serviceName: "Other Clock", boardID: "1"))
        let selectionCancelledRetries = reconnectScheduler.tasks.allSatisfy { $0.isCancelled }
        #expect(selectionCancelledRetries)
    }

    @MainActor
    @Test func foregroundReconnectDoesNotReplayCommands() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = try await connectedViewModel(
            recorder: recorder,
            boardID: "0",
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.sendConnectionTest()
        recorder.connections[0].lastSendCompletion?(nil)
        await drainMainQueue()
        viewModel.handleAppEnteredBackground()
        await drainMainQueue()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(recorder.connections.count == 2)
        #expect(recorder.connections[1].sendCallCount == 0)
    }

    @MainActor
    @Test func cachedBonjourReconnectRestoresLogoServiceTarget() async throws {
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(connectionFactory: { endpoint in
            capturedEndpoint = endpoint
            return logoRecorder.makeConnection()
        })
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(
            LastConnectedDevice(
                boardID: 0,
                displayName: "Clock 0",
                serviceInstanceName: "Clock 0",
                serviceType: ESP32DiscoveryService.serviceType,
                serviceDomain: "local",
                hostname: "esp32-clock-0.local",
                controlPort: ESP32TCPClient.defaultPort,
                source: .bonjour,
                manualHost: nil,
                logoServiceName: "Clock 0 Logo",
                logoServiceType: ESP32DiscoveryService.logoServiceType,
                logoServiceDomain: "local",
                logoHostname: "esp32-clock-0.local",
                logoPort: LogoFileFormat.logoUploadPort
            ),
            to: defaults
        )
        let payload = makeLogoPayload()
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            logoUploadClient: logoClient,
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.canUploadLogo)
        #expect(viewModel.logoEndpointSourceDiagnosticsText == "Cached Bonjour")
        viewModel.uploadLogo()

        #expect(capturedEndpoint == NWEndpoint.service(
            name: "Clock 0 Logo",
            type: ESP32DiscoveryService.logoServiceType,
            domain: "local",
            interface: nil
        ))
        #expect(logoRecorder.connections.count == 1)
    }

    @MainActor
    @Test func cachedHostnameReconnectDerivesLogoPort5001() async throws {
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(connectionFactory: { endpoint in
            capturedEndpoint = endpoint
            return logoRecorder.makeConnection()
        })
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(
            LastConnectedDevice(
                boardID: 0,
                displayName: "Clock 0",
                serviceInstanceName: nil,
                serviceType: nil,
                serviceDomain: nil,
                hostname: "esp32-clock-0.local",
                controlPort: ESP32TCPClient.defaultPort,
                source: .bonjour,
                manualHost: nil
            ),
            to: defaults
        )
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            logoUploadClient: logoClient,
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.canUploadLogo)
        #expect(viewModel.logoEndpointSourceDiagnosticsText == "Cached hostname")
        #expect(viewModel.logoDestinationDiagnosticsText == "esp32-clock-0.local:5001")
        viewModel.uploadLogo()

        if case let .hostPort(_, port) = capturedEndpoint {
            #expect(port.rawValue == LogoFileFormat.logoUploadPort)
            #expect(port.rawValue != ESP32TCPClient.defaultPort)
        } else {
            Issue.record("Cached hostname upload should use a host-port endpoint")
        }
    }

    @MainActor
    @Test func cachedManualHostReconnectDerivesLogoPort5001() async throws {
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(connectionFactory: { endpoint in
            capturedEndpoint = endpoint
            return logoRecorder.makeConnection()
        })
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(
            LastConnectedDevice(
                boardID: 5,
                displayName: "192.168.5.118",
                serviceInstanceName: nil,
                serviceType: nil,
                serviceDomain: nil,
                hostname: "192.168.5.118",
                controlPort: 5000,
                source: .manual,
                manualHost: "192.168.5.118"
            ),
            to: defaults
        )
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            logoUploadClient: logoClient,
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.canUploadLogo)
        #expect(viewModel.logoEndpointSourceDiagnosticsText == "Cached manual host")
        #expect(viewModel.logoDestinationDiagnosticsText == "192.168.5.118:5001")
        viewModel.uploadLogo()

        if case let .hostPort(_, port) = capturedEndpoint {
            #expect(port.rawValue == LogoFileFormat.logoUploadPort)
        } else {
            Issue.record("Manual-host upload should use a host-port endpoint")
        }
    }

    @MainActor
    @Test func logoServiceMatchingBoardIDIsPreferredAfterAutomaticReconnect() async throws {
        let controlBrowser = FakeESP32Browser()
        let logoBrowser = FakeESP32Browser()
        let discoveryService = ESP32DiscoveryService(
            browserFactory: { controlBrowser },
            logoBrowserFactory: { logoBrowser }
        )
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(connectionFactory: { endpoint in
            capturedEndpoint = endpoint
            return logoRecorder.makeConnection()
        })
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            logoUploadClient: logoClient,
            discoveryService: discoveryService,
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        discoveryService.applyLogoBrowseResultsForTesting([
            makeLogoBrowseResult(serviceName: "Other Clock Logo", id: "1"),
            makeLogoBrowseResult(serviceName: "Clock 0 Logo", id: "0")
        ], browser: logoBrowser)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.logoEndpointSourceDiagnosticsText == "Discovered Bonjour")
        viewModel.uploadLogo()

        #expect(capturedEndpoint == NWEndpoint.service(
            name: "Clock 0 Logo",
            type: ESP32DiscoveryService.logoServiceType,
            domain: "local",
            interface: nil
        ))
    }

    @MainActor
    @Test func malformedLogoTXTDoesNotReplaceFallbackTarget() async throws {
        let controlBrowser = FakeESP32Browser()
        let logoBrowser = FakeESP32Browser()
        let discoveryService = ESP32DiscoveryService(
            browserFactory: { controlBrowser },
            logoBrowserFactory: { logoBrowser }
        )
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(connectionFactory: { endpoint in
            capturedEndpoint = endpoint
            return logoRecorder.makeConnection()
        })
        let defaults = makeIsolatedUserDefaults()
        saveLastConnectedDevice(makeBonjourLastDevice(), to: defaults)
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            logoUploadClient: logoClient,
            discoveryService: discoveryService,
            userDefaults: defaults
        )

        viewModel.handleAppBecameActive()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        discoveryService.applyLogoBrowseResultsForTesting([
            makeLogoBrowseResult(serviceName: "Malformed Logo", id: "0x00")
        ], browser: logoBrowser)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.logoEndpointSourceDiagnosticsText == "Cached hostname")
        viewModel.uploadLogo()

        if case let .hostPort(_, port) = capturedEndpoint {
            #expect(port.rawValue == LogoFileFormat.logoUploadPort)
        } else {
            Issue.record("Malformed logo TXT should leave hostname fallback in use")
        }
    }

    @MainActor
    @Test func backgroundPreservesPrimitiveLogoServiceCache() async throws {
        let controlBrowser = FakeESP32Browser()
        let logoBrowser = FakeESP32Browser()
        let discoveryService = ESP32DiscoveryService(
            browserFactory: { controlBrowser },
            logoBrowserFactory: { logoBrowser }
        )
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            discoveryService: discoveryService,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.handleAppBecameActive()
        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        discoveryService.applyLogoBrowseResultsForTesting([
            makeLogoBrowseResult(serviceName: "Clock 0 Logo", id: "0", hostname: "esp32-clock-0.local")
        ], browser: logoBrowser)
        await drainMainQueue()
        viewModel.handleAppEnteredBackground()
        await drainMainQueue()

        #expect(viewModel.lastConnectedDevice?.logoServiceName == "Clock 0 Logo")
        #expect(viewModel.lastConnectedDevice?.logoPort == LogoFileFormat.logoUploadPort)
    }

    @MainActor
    @Test func foregroundRestartsLogoResolutionWithoutDuplicateActiveBrowsers() async {
        let controlBrowsers = FakeBrowserRecorder()
        let logoBrowsers = FakeBrowserRecorder()
        let discoveryService = ESP32DiscoveryService(
            browserFactory: controlBrowsers.makeBrowser,
            logoBrowserFactory: logoBrowsers.makeBrowser
        )
        let viewModel = ESP32ControllerViewModel(
            client: ESP32TCPClient(
                connectionFactory: { _, _ in FakeTCPConnection() },
                endpointConnectionFactory: { _ in FakeTCPConnection() }
            ),
            discoveryService: discoveryService,
            userDefaults: makeIsolatedUserDefaults()
        )
        viewModel.authorizeNetworking()

        viewModel.handleAppBecameActive()
        viewModel.handleAppBecameActive()
        await drainMainQueue()
        #expect(controlBrowsers.browsers.count == 1)
        #expect(logoBrowsers.browsers.count == 1)

        viewModel.handleAppEnteredBackground()
        await drainMainQueue()
        viewModel.handleAppBecameActive()
        await drainMainQueue()
        #expect(controlBrowsers.browsers.count == 2)
        #expect(logoBrowsers.browsers.count == 2)
    }

    @MainActor
    @Test func logoUploadIsNotReplayedAfterForegroundReconnect() async throws {
        let controlRecorder = FakeTCPConnectionRecorder()
        let logoRecorder = FakeTCPConnectionRecorder()
        let logoClient = ESP32LogoUploadClient(connectionFactory: { _ in logoRecorder.makeConnection() })
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: makeLogoPayload()) },
            logoUploadClient: logoClient,
            userDefaults: makeIsolatedUserDefaults()
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)
        viewModel.uploadLogo()
        #expect(logoRecorder.connections.count == 1)

        viewModel.handleAppEnteredBackground()
        await drainMainQueue()
        viewModel.handleAppBecameActive()
        await drainMainQueue()

        #expect(controlRecorder.connections.count == 2)
        #expect(logoRecorder.connections.count == 1)
    }

    @MainActor
    @Test func openingScannerStartsExactlyOneBrowser() async {
        var browserCount = 0
        var logoBrowserCount = 0
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() }
        )
        let discoveryService = ESP32DiscoveryService(
            browserFactory: {
                browserCount += 1
                return FakeESP32Browser()
            },
            logoBrowserFactory: {
                logoBrowserCount += 1
                return FakeESP32Browser()
            }
        )
        let viewModel = ESP32ControllerViewModel(client: client, discoveryService: discoveryService)
        viewModel.authorizeNetworking()

        viewModel.presentDeviceScanner()
        #expect(browserCount == 0)

        viewModel.beginDeviceScan()
        await drainMainQueue()

        #expect(browserCount == 1)
        #expect(logoBrowserCount == 1)
        #expect(viewModel.isScannerPresented)
        #expect(viewModel.scannerState == .scanning)
    }

    @MainActor
    @Test func newScanClearsOldVisibleResults() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.beginDeviceScan()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])
        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.count == 1)

        service.beginDeviceScan()

        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
        #expect(browsers.browsers.count == 2)
    }

    @MainActor
    @Test func closingScannerCancelsDiscoveryResources() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.beginDeviceScan()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.stopScan()

        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .idle)
    }

    @MainActor
    @Test func staleScanCallbacksCannotAddDevices() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.beginDeviceScan()
        let staleBrowser = browsers.browsers[0]

        service.beginDeviceScan()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: staleBrowser)
        await drainMainQueue()

        #expect(probes.connections.isEmpty)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func selectingOneDeviceDisablesOtherConnectActions() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceA)
        await drainMainQueue()

        #expect(viewModel.pendingSelectedEndpointDescription == deviceA.stableEndpointDescription)
        #expect(!viewModel.canSelectScannedDevice(deviceA))
        #expect(!viewModel.canSelectScannedDevice(deviceB))
        #expect(recorder.connections.count == 1)

        viewModel.connect(to: deviceB)

        #expect(recorder.connections.count == 1)
    }

    @MainActor
    @Test func successfulConnectionDismissesScannerState() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.connect(to: device)
        await drainMainQueue()

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        await drainMainQueue()

        #expect(!viewModel.isScannerPresented)
        #expect(viewModel.scannerState == .idle)
        #expect(viewModel.connectedDiscoveredDevice?.stableEndpointDescription == device.stableEndpointDescription)
        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)
    }

    @MainActor
    @Test func failedConnectionKeepsScannerAvailable() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.connect(to: device)
        await drainMainQueue()

        recorder.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.isScannerPresented)
        #expect(viewModel.pendingSelectedEndpointDescription == nil)
        #expect(viewModel.connectedDiscoveredDevice == nil)
        #expect(viewModel.scannerConnectionErrorText != nil)
        #expect(viewModel.canSelectScannedDevice(device))
    }

    @MainActor
    @Test func establishedConnectionRemainsActiveWhenScannerCloses() async {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        viewModel.presentDeviceScanner()
        viewModel.beginDeviceScan()
        viewModel.closeDeviceScanner()
        await drainMainQueue()

        #expect(viewModel.state == .connected)
        #expect(viewModel.connectedDiscoveredDevice?.stableEndpointDescription == device.stableEndpointDescription)
        #expect(recorder.connections[0].cancelCallCount == 0)
    }

    @MainActor
    @Test func staleBrowserCallbacksAreIgnoredAfterRefresh() async throws {
        var browsers: [FakeESP32Browser] = []
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = ESP32DiscoveryService(
            browserFactory: {
                let browser = FakeESP32Browser()
                browsers.append(browser)
                return browser
            },
            logoBrowserFactory: {
                FakeESP32Browser()
            },
            probeConnectionFactory: probes.makeConnection(endpoint:),
            timeoutScheduler: timeouts.schedule(_:)
        )

        service.beginDeviceScan()
        let staleStateHandler = try #require(browsers[0].stateUpdateHandler)

        service.beginDeviceScan()
        staleStateHandler(.failed(.posix(.ECONNRESET)))
        await Task.yield()

        #expect(browsers[0].cancelCallCount == 1)
        #expect(service.state == .refreshing)
        #expect(service.errorText == nil)

        service.applyBrowseResultsForTesting([], browser: browsers[1])
        browsers[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(service.state == .ready)
    }

    @MainActor
    @Test func browserReadyWithZeroResultsCompletesRefreshAfterSettle() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.isRefreshing)
        #expect(settles.tasks.count == 1)

        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(service.state == .ready)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func resultsBeforeSettleTimeoutCancelEmptyResultTask() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(probes.connections.count == 1)
        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func staleSettleCallbackCannotFinishNewerRefresh() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(settles.tasks.count == 1)

        service.refreshDevices()
        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(service.state == .refreshing)
        #expect(service.isRefreshing)
        #expect(service.devices.isEmpty)
    }

    @MainActor
    @Test func repeatedRefreshAfterEmptyResultWorksNormally() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browsers.browsers[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        settles.tasks[0].fire()
        await drainMainQueue()

        #expect(!service.isRefreshing)
        #expect(service.devices.isEmpty)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[1])

        #expect(browsers.browsers.count == 2)
        #expect(probes.connections.count == 1)
        #expect(service.devices.isEmpty)
        #expect(service.isRefreshing)
    }

    @MainActor
    @Test func refreshCancelsOlderBrowserAndProbes() {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.refreshDevices()

        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(service.isRefreshing)
    }

    @MainActor
    @Test func callbacksFromOlderRefreshAreIgnored() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        let oldProbe = probes.connections[0]
        service.refreshDevices()
        oldProbe.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(service.scannerState == .scanning)
    }

    @MainActor
    @Test func successfulOneShotProbeMarksOnline() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices[0].livenessState == .online)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func failedOneShotProbeDoesNotAppearInSelectableList() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        probes.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(service.devices.isEmpty)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
        #expect(service.scannerState == .completed)
    }

    @MainActor
    @Test func noRecurringProbeIsScheduled() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)

        #expect(timeouts.tasks.count == 1)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(timeouts.tasks.count == 1)
    }

    @MainActor
    @Test func connectedDeviceIsNotProbed() {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)
        let result = makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        let connectedEndpointDescription = String(describing: result.endpoint)

        service.refreshDevices(connectedEndpointDescription: connectedEndpointDescription)
        service.applyBrowseResultsForTesting([result], browser: browser)

        #expect(probes.connections.isEmpty)
        #expect(service.devices[0].livenessState == .connected)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func browserRemovalRemovesDeviceAndCancelsProbe() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browser)
        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(service.devices.count == 1)

        service.applyBrowseResultsForTesting([], browser: browser)

        #expect(service.devices.isEmpty)
        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func repeatedRefreshCallsDoNotLeaveDuplicateBrowsersOrProbes() {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browsers: browsers, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        #expect(probes.connections.count == 1)

        service.refreshDevices()

        #expect(browsers.browsers.count == 2)
        #expect(browsers.browsers[0].cancelCallCount == 1)
        #expect(probes.connections[0].cancelCallCount == 1)
    }

    @MainActor
    @Test func browserFailureCancelsActiveProbeConnectionsTimeoutsAndPendingProbes() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock B", id: "board-b", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock C", id: "board-c", firmware: "1.0.0")
        ], browser: browser)

        #expect(probes.connections.count == 2)
        #expect(timeouts.tasks.count == 2)

        browser.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        await drainMainQueue()

        #expect(probes.connections[0].cancelCallCount == 1)
        #expect(probes.connections[1].cancelCallCount == 1)
        #expect(timeouts.tasks[0].cancelCallCount == 1)
        #expect(timeouts.tasks[1].cancelCallCount == 1)
        #expect(service.state == .failed("POSIXErrorCode(rawValue: 54): Connection reset by peer"))
        #expect(!service.isRefreshing)

        probes.connections[0].stateUpdateHandler?(.ready)
        probes.connections[1].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(probes.connections.count == 2)
    }

    @MainActor
    @Test func browserFailureCancelsSettleTask() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browser: browser,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        browser.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(settles.tasks.count == 1)

        browser.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        await drainMainQueue()

        #expect(settles.tasks[0].cancelCallCount == 1)
        #expect(!service.isRefreshing)
    }

    @MainActor
    @Test func staleProbeCallbacksCleanLocalResourcesWithoutMutatingCurrentRefresh() async {
        let browsers = FakeBrowserRecorder()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let settles = FakeTimeoutScheduler()
        let service = makeDiscoveryService(
            browsers: browsers,
            probes: probes,
            timeouts: timeouts,
            settles: settles
        )

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0")
        ], browser: browsers.browsers[0])

        let staleProbe = probes.connections[0]
        let staleHandler = staleProbe.stateUpdateHandler
        service.refreshDevices()
        let cancelCountAfterRefresh = staleProbe.cancelCallCount

        staleHandler?(.ready)
        await drainMainQueue()

        #expect(staleProbe.cancelCallCount == cancelCountAfterRefresh + 1)
        #expect(timeouts.tasks[0].cancelCallCount == 2)
        #expect(service.state == .refreshing)
        #expect(service.devices.isEmpty)
    }

    @MainActor
    @Test func refreshCompletesAfterAllProbesFinishOrTimeout() async {
        let browser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = makeDiscoveryService(browser: browser, probes: probes, timeouts: timeouts)

        service.refreshDevices()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock A", id: "board-a", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock B", id: "board-b", firmware: "1.0.0"),
            makeBrowseResult(serviceName: "ESP32 Clock C", id: "board-c", firmware: "1.0.0")
        ], browser: browser)

        #expect(probes.connections.count == 2)
        #expect(service.isRefreshing)

        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(probes.connections.count == 3)
        #expect(service.isRefreshing)

        timeouts.tasks[1].fire()
        timeouts.tasks[2].fire()
        await drainMainQueue()

        #expect(!service.isRefreshing)
        #expect(service.devices.map(\.livenessState) == [.online])
    }

    @MainActor
    @Test func endpointConnectionUsesSharedLifecycle() async throws {
        let manualConnection = FakeTCPConnection()
        let endpointConnection = FakeTCPConnection()
        let endpoint = NWEndpoint.service(
            name: "ESP32 Clock 0",
            type: "_espclock._tcp",
            domain: "local",
            interface: nil
        )
        var endpointFactoryEndpoint: NWEndpoint?
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in manualConnection },
            endpointConnectionFactory: { requestedEndpoint in
                endpointFactoryEndpoint = requestedEndpoint
                return endpointConnection
            }
        )
        var states: [TCPConnectionState] = []
        var frames: [[UInt8]] = []
        client.onStateChange = { states.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(to: endpoint, boardID: nil)
        endpointConnection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(endpointFactoryEndpoint == endpoint)
        #expect(states.last == .connected)
        #expect(endpointConnection.receiveCallCount == 1)

        let receive = try #require(endpointConnection.lastReceiveCompletion)
        receive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x01, ESP32TCPClient.frameDelimiter]])

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        receive(Data([0x02, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x01, ESP32TCPClient.frameDelimiter]])
        #expect(endpointConnection.cancelCallCount == 1)
        #expect(manualConnection.receiveCallCount == 0)

        manualConnection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(manualConnection.receiveCallCount == 1)
    }

    @MainActor
    @Test func initialInternalDisconnectDoesNotErasePendingDiscoveredEndpoint() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)
    }

    @MainActor
    @Test func successfulDiscoveredConnectionMarksCorrectRowConnected() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceB)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription != deviceA.stableEndpointDescription)
        #expect(viewModel.connectedEndpointDescription == deviceB.stableEndpointDescription)
    }

    @MainActor
    @Test func explicitDisconnectClearsConnectedAndPendingEndpointState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)

        viewModel.disconnect()
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func connectionFailureClearsPendingDiscoveredEndpointState() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func switchingDiscoveredDevicesUpdatesConnectedIndicatorAfterReady() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let deviceA = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")
        let deviceB = makeDevice(id: "service-b", serviceName: "ESP32 Clock B", boardID: "board-b")

        viewModel.connect(to: deviceA)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == deviceA.stableEndpointDescription)

        viewModel.connect(to: deviceB)
        #expect(viewModel.connectedEndpointDescription == nil)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)

        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == deviceB.stableEndpointDescription)
    }

    @MainActor
    @Test func manualIPConnectionDoesNotMarkDiscoveredRowConnected() async throws {
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForConnectionIndicatorTests(recorder: recorder)
        let device = makeDevice(id: "service-a", serviceName: "ESP32 Clock A", boardID: "board-a")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == device.stableEndpointDescription)

        viewModel.connect()
        #expect(viewModel.connectedEndpointDescription == nil)
        await drainMainQueue()

        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(viewModel.connectedEndpointDescription == nil)
    }

    @MainActor
    @Test func staleFailedStateDoesNotOverwriteActiveConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        staleStateHandler(.failed(.posix(.ECONNRESET)))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .connecting)
        #expect(!states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleCancelledStateDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        staleStateHandler(.cancelled)
        await Task.yield()

        #expect(states.last == .connecting)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleReceiveDoesNotEmitFramesOrContinueReceiveLoop() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let staleReceive = try #require(connections[0].lastReceiveCompletion)
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)

        staleReceive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[0].receiveCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()
        let firstActiveReceive = try #require(connections[1].lastReceiveCompletion)
        firstActiveReceive(Data([0x02]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[1].receiveCallCount == 2)

        let secondActiveReceive = try #require(connections[1].lastReceiveCompletion)
        secondActiveReceive(Data([0x03, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x02, 0x03, ESP32TCPClient.frameDelimiter]])
        #expect(connections[1].receiveCallCount == 3)
    }

    @MainActor
    @Test func staleSendCompletionIsIgnored() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var sendResults: [Error?] = []

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        client.send(Data([0x01])) { sendResults.append($0) }
        let staleSendCompletion = try #require(connections[0].lastSendCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        staleSendCompletion(.posix(.ECONNRESET))
        await Task.yield()

        #expect(sendResults.isEmpty)

        client.send(Data([0x02])) { sendResults.append($0) }
        let activeSendCompletion = try #require(connections[1].lastSendCompletion)
        activeSendCompletion(nil)
        await Task.yield()

        #expect(sendResults.count == 1)
        #expect(sendResults[0] == nil)
    }

    @MainActor
    @Test func activeReceiveErrorClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        var frames: [[UInt8]] = []
        client.onStateChange = { states.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(Data([0xAA]), nil, false, .posix(.ECONNRESET))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(frames.isEmpty)
        #expect(states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        let nextReceive = try #require(connections[1].lastReceiveCompletion)
        nextReceive(Data([ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[ESP32TCPClient.frameDelimiter]])
    }

    @MainActor
    @Test func activeReceiveCompletionClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .disconnected)

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func staleReceiveTerminationDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        staleReceive(nil, nil, true, nil)
        await Task.yield()

        #expect(states.last == .connecting)
        #expect(connections[0].cancelCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func sendAfterReceiveTerminationReportsNotConnected() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func heartbeatStartsOnlyAfterReadyAndSendsFirstHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x7A)

        #expect(scheduler.tasks.isEmpty)
        #expect(connection.sendCallCount == 0)

        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.map(\.delay) == [1])
        scheduler.tasks[0].fire()
        await Task.yield()

        let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x7A, sequence: 0))
        #expect(connection.sentContents.map { $0.map(Array.init) } == [expectedFrame])
        #expect(ackTimeouts.tasks.map(\.delay) == [4])
    }

    @MainActor
    @Test func boardIDParserAcceptsOnlyDecimalUInt8Values() {
        #expect(ESP32ControllerViewModel.boardIDByte(from: "0") == 0x00)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "7") == 0x07)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "10") == 0x0A)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "91") == 0x5B)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "93") == 0x5D)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "255") == 0xFF)
        #expect(ESP32ControllerViewModel.boardIDByte(from: " 7 ") == 0x07)
    }

    @MainActor
    @Test func boardIDParserRejectsHexLookingAndOutOfRangeValues() {
        #expect(ESP32ControllerViewModel.boardIDByte(from: "A") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "0A") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "FF") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "-1") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "92") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "256") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: "   ") == nil)
        #expect(ESP32ControllerViewModel.boardIDByte(from: nil) == nil)
    }

    @MainActor
    @Test func manualConnectionWithBlankBoardIDDisablesHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "   "
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
    }

    @MainActor
    @Test func waitingForHeartbeatACKDisplaysConnectedStatus() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "7"
        viewModel.connect()
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await drainMainQueue()

        #expect(viewModel.connectionHealth == .waitingForACK)
        #expect(viewModel.connectionStatusText == "Connected")
        #expect(viewModel.connectionHealthAccessibilityValue == "Heartbeat awaiting acknowledgement")
    }

    @MainActor
    @Test func manualBoardIDDecimalValuesUseExpectedHeartbeatByte() async throws {
        let cases: [(String, UInt8)] = [
            ("0", 0x00),
            ("7", 0x07),
            ("10", 0x0A),
            ("255", 0xFF)
        ]

        for (boardIDText, expectedByte) in cases {
            let scheduler = FakeHeartbeatScheduler()
            let ackTimeouts = FakeHeartbeatScheduler()
            let recorder = FakeTCPConnectionRecorder()
            let viewModel = makeViewModelForManualHeartbeatTests(
                recorder: recorder,
                heartbeatScheduler: scheduler,
                ackTimeouts: ackTimeouts
            )

            viewModel.manualBoardID = boardIDText
            viewModel.connect()
            await drainMainQueue()
            recorder.connections[0].stateUpdateHandler?(.ready)
            await Task.yield()
            scheduler.tasks[0].fire()
            await Task.yield()

            let frame = try #require(recorder.connections[0].sentContents.first??.map { $0 })
            #expect(frame[3] == expectedByte)
            let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: expectedByte, sequence: 0))
            #expect(frame == expectedFrame)
        }
    }

    @MainActor
    @Test func invalidNonemptyManualBoardIDPreventsConnection() {
        for invalidBoardID in ["-1", "256", "0A", "A"] {
            let scheduler = FakeHeartbeatScheduler()
            let ackTimeouts = FakeHeartbeatScheduler()
            let recorder = FakeTCPConnectionRecorder()
            let viewModel = makeViewModelForManualHeartbeatTests(
                recorder: recorder,
                heartbeatScheduler: scheduler,
                ackTimeouts: ackTimeouts
            )

            viewModel.manualBoardID = invalidBoardID
            viewModel.connect()

            #expect(recorder.connections.isEmpty)
            #expect(scheduler.tasks.isEmpty)
            #expect(viewModel.state == .failed("Board ID must be a decimal value from 0 through 255"))
        }
    }

    @MainActor
    @Test func manualBoardIDNinetyTwoPreventsConnectionWithReservedMessage() {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForManualHeartbeatTests(
            recorder: recorder,
            heartbeatScheduler: scheduler,
            ackTimeouts: ackTimeouts
        )

        viewModel.manualBoardID = "92"
        viewModel.connect()

        #expect(recorder.connections.isEmpty)
        #expect(scheduler.tasks.isEmpty)
        #expect(viewModel.state == .failed(ESP32ControllerViewModel.reservedBoardIDMessage))
    }

    @MainActor
    @Test func discoveredDecimalBoardIDIsUsedAsHeartbeatFrameByteThree() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            )
        )
        viewModel.authorizeNetworking()
        let device = makeDevice(id: "service-decimal", serviceName: "ESP32 Decimal", boardID: "10")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await Task.yield()

        let frame = try #require(recorder.connections[0].sentContents.first??.map { $0 })
        #expect(frame[3] == 0x0A)
        let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x0A, sequence: 0))
        #expect(frame == expectedFrame)
    }

    @MainActor
    @Test func invalidDiscoveredBoardIDDoesNotInventHeartbeatBoardByte() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            )
        )
        viewModel.authorizeNetworking()
        let device = makeDevice(id: "service-invalid", serviceName: "ESP32 Invalid", boardID: "0A")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func discoveredReservedBoardIDConnectsWithoutHeartbeatAndLogsDiagnostic() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            )
        )
        viewModel.authorizeNetworking()
        let device = makeDevice(id: "service-reserved", serviceName: "ESP32 Reserved", boardID: "92")

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
        let loggedReservedBoardIDDiagnostic = viewModel.logEntries.contains {
            $0.message == "Heartbeat unavailable: \(ESP32ControllerViewModel.reservedBoardIDMessage)"
        }
        #expect(loggedReservedBoardIDDiagnostic)
    }

    @MainActor
    @Test func discoveredMissingBoardIDConnectsWithoutHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            )
        )
        viewModel.authorizeNetworking()
        let device = makeDevice(id: "service-missing", serviceName: "ESP32 Missing", boardID: nil)

        viewModel.connect(to: device)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(scheduler.tasks.isEmpty)
        #expect(recorder.connections[0].sendCallCount == 0)
        #expect(viewModel.connectionStatusText == "Connected")
    }

    @MainActor
    @Test func heartbeatDisabledConnectionForwardsACKShapedFrame() async throws {
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0x2A)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ackShapedFrame])
    }

    @MainActor
    @Test func heartbeatDisabledConnectionForwardsValidNineByteACKShape() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame: [UInt8] = [0x2F, 0x74, 0x61, 0x00, 0x68, 0x62, 0x41, 0x46, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(frames == [ackShapedFrame])
    }

    @MainActor
    @Test func heartbeatFrameEncodingUsesUppercaseHex() throws {
        let expectedRequestFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x41, sequence: 0xAF))
        #expect(expectedRequestFrame == [
            0x2F, 0x54, 0x41, 0x41, 0x48, 0x42, 0x41, 0x46, 0x5C
        ])
        #expect(ESP32TCPClient.heartbeatACKFrame(boardID: 0x41, sequence: 0xAF) == [
            0x2F, 0x74, 0x61, 0x41, 0x68, 0x62, 0x41, 0x46, 0x5C
        ])
        #expect(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x5C, sequence: 0xAF) == nil)
    }

    @MainActor
    @Test func heartbeatSequenceRollsOverFromFFTo00() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x22)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        for sequence in 0...256 {
            try fireLatestActiveHeartbeatTask(scheduler)
            await Task.yield()
            let expectedSequence = UInt8(truncatingIfNeeded: sequence)
            let expectedFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: expectedSequence))
            #expect(connection.sentContents.last??.map { $0 } == expectedFrame)

            let receive = try #require(connection.lastReceiveCompletion)
            receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x22, sequence: expectedSequence)), nil, false, nil)
            await Task.yield()
        }

        let expectedFFFrame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: 0xFF))
        let expected00Frame = try #require(ESP32TCPClient.heartbeatRequestFrame(boardID: 0x22, sequence: 0x00))
        #expect(connection.sentContents[255].map(Array.init) == expectedFFFrame)
        #expect(connection.sentContents[256].map(Array.init) == expected00Frame)
    }

    @MainActor
    @Test func matchingACKResetsMissedCountAndIsNotForwarded() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x01)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x01, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(health.suffix(2) == [.waitingForACK, .healthy])
    }

    @MainActor
    @Test func wrongSequenceOrBoardACKDoesNotResetMissedCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        let wrongSequenceFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x02, sequence: 1)
        let wrongBoardFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x03, sequence: 0)
        receive(Data(wrongSequenceFrame), nil, false, nil)
        receive(Data(wrongBoardFrame), nil, false, nil)
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(frames == [wrongSequenceFrame, wrongBoardFrame])
        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func matchingACKForDecimalBoardIDSevenResetsMissedCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(ackTimeouts.tasks[0].isCancelled)
    }

    @MainActor
    @Test func wrongBoardByteForDecimalBoardIDSevenIsRejected() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        let wrongBoardFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x37, sequence: 0)
        receive(Data(wrongBoardFrame), nil, false, nil)
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(frames == [wrongBoardFrame])
        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func ackShapedFrameWithNoPendingHeartbeatIsForwarded() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        var health: [ConnectionHealthState] = []
        client.onFrameReceived = { frames.append($0) }
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ackShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ackShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ackShapedFrame])
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(health.last == .healthy)
    }

    @MainActor
    @Test func malformedACKIsForwardedAsNormalFrame() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let malformed: [UInt8] = [0x2F, 0x74, 0x61, 0x02, 0x68, 0x62, 0x47, 0x47, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(malformed), nil, false, nil)
        await Task.yield()

        #expect(frames == [malformed])
    }

    @MainActor
    @Test func ordinaryNonHeartbeatFrameIsForwarded() async throws {
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(connectionFactory: { _, _ in connection })
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x02)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        let ordinaryFrame: [UInt8] = [0x2F, 0x54, 0x41, 0x02, 0x4F, 0x4B, 0x5C]
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ordinaryFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [ordinaryFrame])
    }

    @MainActor
    @Test func timeoutIncrementsMissCountAndThreeTimeoutsDisconnect() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var states: [TCPConnectionState] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        for missed in 1...3 {
            try fireLatestActiveHeartbeatTask(scheduler)
            await Task.yield()
            try fireLatestActiveHeartbeatTask(ackTimeouts)
            await Task.yield()

            if missed < 3 {
                #expect(health.last == .degraded(missedCount: missed))
                #expect(connection.cancelCallCount == 0)
            }
        }

        #expect(health.contains(.timedOut))
        #expect(states.last == .failed("Heartbeat timed out"))
        #expect(connection.cancelCallCount == 1)
    }

    @MainActor
    @Test func successfulACKAfterOneMissResetsCount() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x05)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        try fireLatestActiveHeartbeatTask(ackTimeouts)
        await Task.yield()

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x05, sequence: 1)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()
        try fireLatestActiveHeartbeatTask(ackTimeouts)
        await Task.yield()

        #expect(health.last == .degraded(missedCount: 1))
        #expect(connection.cancelCallCount == 0)
    }

    @MainActor
    @Test func onlyOneHeartbeatMayBeOutstanding() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatConfiguration: HeartbeatConfiguration(interval: 12, ackTimeout: 30, maximumConsecutiveMisses: 3),
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(connection.sendCallCount == 1)

        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()

        #expect(connection.sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)
    }

    @MainActor
    @Test func connectionWithoutHeartbeatSendsNoHeartbeatFrames() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func lowLevelHostConnectWithReservedBoardIDDoesNotEnableHeartbeatOrSendMalformedFrame() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x5C)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func lowLevelEndpointConnectWithReservedBoardIDDoesNotEnableHeartbeat() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            endpointConnectionFactory: { _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(
            to: .service(name: "ESP32 Reserved", type: ESP32DiscoveryService.serviceType, domain: "local", interface: nil),
            boardID: 0x5C
        )
        connection.stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(scheduler.tasks.isEmpty)
        #expect(ackTimeouts.tasks.isEmpty)
        #expect(connection.sentContents.isEmpty)
    }

    @MainActor
    @Test func previousHeartbeatEnabledConnectionDoesNotLeakIntoDisabledConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        var frames: [[UInt8]] = []
        client.onConnectionHealthChange = { health.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x07)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(connections[0].sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(health.last == .idle)
        #expect(connections[1].sendCallCount == 0)
        let replacementHeartbeatTasksCancelled = scheduler.tasks.dropFirst().allSatisfy { $0.isCancelled }
        #expect(replacementHeartbeatTasksCancelled)

        let staleACKShapedFrame = ESP32TCPClient.heartbeatACKFrame(boardID: 0x07, sequence: 0)
        let receive = try #require(connections[1].lastReceiveCompletion)
        receive(Data(staleACKShapedFrame), nil, false, nil)
        await Task.yield()

        #expect(frames == [staleACKShapedFrame])
        #expect(health.last == .idle)
    }

    @MainActor
    @Test func previousDiscoveredHeartbeatBoardIDDoesNotLeakIntoReservedDiscoveredConnection() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let recorder = FakeTCPConnectionRecorder()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in recorder.makeConnection() },
            endpointConnectionFactory: { _ in recorder.makeConnection() },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        let viewModel = ESP32ControllerViewModel(
            client: client,
            discoveryService: ESP32DiscoveryService(
                browserFactory: { FakeESP32Browser() },
                logoBrowserFactory: { FakeESP32Browser() }
            )
        )
        viewModel.authorizeNetworking()
        let validDevice = makeDevice(id: "service-valid", serviceName: "ESP32 Valid", boardID: "7")
        let reservedDevice = makeDevice(id: "service-reserved", serviceName: "ESP32 Reserved", boardID: "92")

        viewModel.connect(to: validDevice)
        await drainMainQueue()
        recorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        scheduler.tasks[0].fire()
        await Task.yield()

        #expect(recorder.connections[0].sendCallCount == 1)
        #expect(ackTimeouts.tasks.count == 1)

        viewModel.connect(to: reservedDevice)
        await drainMainQueue()
        recorder.connections[1].stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(recorder.connections[1].sendCallCount == 0)
        let replacementHeartbeatTasksCancelled = scheduler.tasks.dropFirst().allSatisfy { $0.isCancelled }
        #expect(replacementHeartbeatTasksCancelled)
        #expect(viewModel.connectionStatusText == "Connected")
        let loggedReservedBoardIDDiagnostic = viewModel.logEntries.contains {
            $0.message == "Heartbeat unavailable: \(ESP32ControllerViewModel.reservedBoardIDMessage)"
        }
        #expect(loggedReservedBoardIDDiagnostic)
    }

    @MainActor
    @Test func staleHeartbeatTimeoutCannotCancelNewerConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x04)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        let staleTimeout = ackTimeouts.tasks[0]

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: nil)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        staleTimeout.fireIgnoringCancellationForTesting()
        await Task.yield()

        #expect(connections[1].cancelCallCount == 0)
        #expect(connections[0].cancelCallCount == 1)
    }

    @MainActor
    @Test func staleACKCannotAffectNewerConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x09)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x09)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        staleReceive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x09, sequence: 0)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(connections[1].cancelCallCount == 0)
    }

    @MainActor
    @Test func disconnectCancelsHeartbeatLoopAndACKTimeout() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        client.disconnect()

        #expect(scheduler.tasks.contains { $0.isCancelled })
        #expect(ackTimeouts.tasks[0].isCancelled)
    }

    @MainActor
    @Test func remoteDisconnectCancelsHeartbeatResources() async throws {
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let connection = FakeTCPConnection()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in connection },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x00)
        connection.stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()

        let receive = try #require(connection.lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        #expect(ackTimeouts.tasks[0].isCancelled)
        #expect(connection.cancelCallCount == 1)
    }

    @MainActor
    @Test func replacementConnectionReceivesIndependentHeartbeatState() async throws {
        var connections: [FakeTCPConnection] = []
        let scheduler = FakeHeartbeatScheduler()
        let ackTimeouts = FakeHeartbeatScheduler()
        let client = ESP32TCPClient(
            connectionFactory: { _, _ in
                let connection = FakeTCPConnection()
                connections.append(connection)
                return connection
            },
            heartbeatScheduler: scheduler.schedule(_:_:),
            heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
        )
        var health: [ConnectionHealthState] = []
        client.onConnectionHealthChange = { health.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x0A)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        scheduler.tasks[0].fire()
        await Task.yield()
        ackTimeouts.tasks[0].fire()
        await Task.yield()

        #expect(health.last == .degraded(missedCount: 1))

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort, boardID: 0x0A)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(health.last == .healthy)
        try fireLatestActiveHeartbeatTask(scheduler)
        await Task.yield()

        let receive = try #require(connections[1].lastReceiveCompletion)
        receive(Data(ESP32TCPClient.heartbeatACKFrame(boardID: 0x0A, sequence: 1)), nil, false, nil)
        await Task.yield()

        #expect(health.last == .healthy)
        #expect(connections[1].cancelCallCount == 0)
    }

    @Test func logoFileHeaderAndCRCMatchFirmwareContract() throws {
        let payload = Data(repeating: 0xA5, count: LogoFileFormat.payloadLength)
        let header = try LogoFileFormat.makeHeader(payload: payload)
        let crc = LogoFileFormat.crc32(payload)

        #expect(header.count == 20)
        #expect(Array(header[0..<4]) == [0x4C, 0x47, 0x4F, 0x31])
        #expect(Array(header[4..<6]) == [0x40, 0x00])
        #expect(Array(header[6..<8]) == [0x20, 0x00])
        #expect(header[8] == 0x01)
        #expect(header[9] == 0x00)
        #expect(Array(header[10..<12]) == [0x00, 0x00])
        #expect(Array(header[12..<16]) == [0x00, 0x18, 0x00, 0x00])
        #expect(Array(header[16..<20]) == [
            UInt8(crc & 0x0000_00FF),
            UInt8((crc >> 8) & 0x0000_00FF),
            UInt8((crc >> 16) & 0x0000_00FF),
            UInt8((crc >> 24) & 0x0000_00FF)
        ])
        #expect(LogoFileFormat.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func logoImageConverterProducesExpectedPayloadLengthAndPixelRules() throws {
        let converter = LogoImageConverter()
        let result = try converter.convert(data: makeSolidPNG(red: 255, green: 0, blue: 0, alpha: 255))

        #expect(result.payload.count == 64 * 32 * 3)
        #expect(result.previewImage.width == 64)
        #expect(result.previewImage.height == 32)

        let black = LogoImageConverter.applyPixelRules(r: 12, g: 12, b: 12)
        #expect(black.r == 0)
        #expect(black.g == 0)
        #expect(black.b == 0)

        let value13 = LogoImageConverter.applyPixelRules(r: 13, g: 13, b: 13)
        #expect(value13.r == 24)
        #expect(value13.g == 24)
        #expect(value13.b == 24)

        let nearGray = LogoImageConverter.applyPixelRules(r: 21, g: 23, b: 20)
        #expect(nearGray.r == 24)
        #expect(nearGray.g == 24)
        #expect(nearGray.b == 24)

        let coloredDark = LogoImageConverter.applyPixelRules(r: 23, g: 10, b: 10)
        #expect(coloredDark.r == 23)
        #expect(coloredDark.g == 10)
        #expect(coloredDark.b == 10)
    }

    @Test func nativeLogoSizeSourceRemainsExactOutputSize() throws {
        let result = try LogoImageConverter().convert(data: makeLogoResizeProbePNG(width: 64, height: 32))

        try assertLogoResizeProbeOutput(result)
    }

    @Test func nativeSizeLogoPreservesHardEdgesWithoutColoredShadows() throws {
        let fixture = try makeNativeShadowTestImage()
        let result = try LogoImageConverter().convert(data: fixture.data)

        #expect(result.payload.count == 64 * 32 * 3)
        try assertNativeShadowOutputMatchesSource(sourcePixels: fixture.pixels, payload: result.payload)
        #expect(try rgbPayload(from: result.previewImage) == result.payload)
    }

    @Test func nativeSizeLogoBlackPixelBleedDiagnostic() throws {
        let fixture = try makeNativeShadowTestImage()
        let result = try LogoImageConverter().convert(data: fixture.data)
        let changedBlackPixels = try nativeBlackPixelBleedDiagnostics(
            sourcePixels: fixture.pixels,
            payload: result.payload
        )

        if !changedBlackPixels.isEmpty {
            Issue.record("Black source pixels changed to nonzero RGB output:\n\(changedBlackPixels.joined(separator: "\n"))")
        }
        #expect(changedBlackPixels.isEmpty)
    }

    @Test func nativeLosslessPNGFixtureUsesOriginalImageIODataWithoutBlackBleed() throws {
        let fixture = try makeNativeShadowTestImage(pngEncoder: makeRGBPNG)
        let diagnostics = try LogoImageConverter.sourceDiagnostics(from: fixture.data)

        #expect(diagnostics.typeIdentifier == UTType.png.identifier)
        #expect(diagnostics.pixelWidth == 64)
        #expect(diagnostics.pixelHeight == 32)
        #expect(diagnostics.orientation == .up)
        #expect(diagnostics.nativePath)

        let decodedPixels = try decodedPixels(fromImageData: fixture.data)
        #expect(decodedPixels == fixture.pixels)

        let result = try LogoImageConverter().convert(data: fixture.data)
        let blackToNonBlackCount = try nativeBlackToNonBlackPixelCount(
            sourcePixels: decodedPixels,
            payload: result.payload
        )

        #expect(result.payload.count == LogoFileFormat.payloadLength)
        #expect(blackToNonBlackCount == 0)
        try assertNativeShadowOutputMatchesSource(sourcePixels: decodedPixels, payload: result.payload)
    }

    @Test func fileImportedPNGBytesRemainPNGAndUseNativePixelPath() throws {
        let fixture = try makeNativeShadowTestImage(pngEncoder: makeRGBPNG)
        let diagnostics = try LogoImageConverter.validateLosslessPNGData(fixture.data)

        #expect(diagnostics.typeIdentifier == UTType.png.identifier)
        #expect(diagnostics.pixelWidth == 64)
        #expect(diagnostics.pixelHeight == 32)
        #expect(diagnostics.nativePath)
        #expect(diagnostics.sourceDisplayName == "PNG")
        #expect(diagnostics.conversionDisplayName == "Native pixel path")

        let decodedPixels = try decodedPixels(fromImageData: fixture.data)
        let result = try LogoImageConverter().convert(data: fixture.data, source: .files)
        let blackToNonBlackCount = try nativeBlackToNonBlackPixelCount(
            sourcePixels: decodedPixels,
            payload: result.payload
        )

        #expect(result.payload.count == LogoFileFormat.payloadLength)
        #expect(blackToNonBlackCount == 0)
        try assertNativeShadowOutputMatchesSource(sourcePixels: decodedPixels, payload: result.payload)
    }

    @Test func jpegLogoSourceIsIdentifiedAsLossyAndRejectedForPNGFileImport() throws {
        let fixture = try makeNativeShadowTestImage()
        let jpegData = try makeJPEG(width: 64, height: 32, pixels: fixture.pixels)
        let diagnostics = try LogoImageConverter.sourceDiagnostics(from: jpegData)

        #expect(diagnostics.typeIdentifier == UTType.jpeg.identifier)
        #expect(diagnostics.pixelWidth == 64)
        #expect(diagnostics.pixelHeight == 32)
        #expect(diagnostics.nativePath)
        #expect(diagnostics.sourceDisplayName == "JPEG")
        #expect(diagnostics.conversionDisplayName == "Native dimensions, lossy source")
        #expect(diagnostics.compressionWarning == LogoImageSourceDiagnostics.lossyCompressionWarning)

        do {
            _ = try LogoImageConverter.validateLosslessPNGData(jpegData)
            Issue.record("JPEG data should be rejected by PNG file-import validation")
        } catch let error as LogoImageConversionError {
            #expect(error == .notLosslessPNG)
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }
    }

    @Test func logoSourceDiagnosticsWarningVisibilityMatchesLossyFormats() {
        let jpegDiagnostics = LogoImageSourceDiagnostics(
            byteCount: 100,
            typeIdentifier: UTType.jpeg.identifier,
            pixelWidth: 64,
            pixelHeight: 32,
            orientation: .up,
            nativePath: true
        )
        let heicDiagnostics = LogoImageSourceDiagnostics(
            byteCount: 100,
            typeIdentifier: "public.heic",
            pixelWidth: 64,
            pixelHeight: 32,
            orientation: .up,
            nativePath: true
        )
        let pngDiagnostics = LogoImageSourceDiagnostics(
            byteCount: 100,
            typeIdentifier: UTType.png.identifier,
            pixelWidth: 64,
            pixelHeight: 32,
            orientation: .up,
            nativePath: true
        )

        #expect(jpegDiagnostics.compressionWarning == LogoImageSourceDiagnostics.lossyCompressionWarning)
        #expect(heicDiagnostics.compressionWarning == LogoImageSourceDiagnostics.lossyCompressionWarning)
        #expect(pngDiagnostics.compressionWarning == nil)
    }

    @Test func squareLogoSourceStretchesToExactOutputSizeWithoutPadding() throws {
        let result = try LogoImageConverter().convert(data: makeLogoResizeProbePNG(width: 100, height: 100))

        try assertLogoResizeProbeOutput(result)
    }

    @Test func portraitLogoSourceStretchesToExactOutputSizeWithoutPadding() throws {
        let result = try LogoImageConverter().convert(data: makeLogoResizeProbePNG(width: 32, height: 100))

        try assertLogoResizeProbeOutput(result)
    }

    @Test func wideLogoSourceStretchesToExactOutputSizeWithoutPadding() throws {
        let result = try LogoImageConverter().convert(data: makeLogoResizeProbePNG(width: 160, height: 40))

        try assertLogoResizeProbeOutput(result)
    }

    @Test func transparentPixelCompositesToBlack() throws {
        let result = try LogoImageConverter().convert(
            data: makeSolidPNG(red: 255, green: 255, blue: 255, alpha: 0)
        )

        #expect(Array(result.payload.prefix(3)) == [0, 0, 0])
    }

    @Test func logoPayloadUsesRowMajorRGBOrderingAndPreviewUsesFinalPayload() throws {
        var pixels = [RGBA](repeating: RGBA(0, 0, 0, 255), count: LogoFileFormat.payloadLength / 3)
        pixels[0] = RGBA(255, 0, 0, 255)
        pixels[1] = RGBA(0, 255, 0, 255)
        pixels[2] = RGBA(0, 0, 255, 255)

        let result = try LogoImageConverter().convert(
            data: makePNG(width: 64, height: 32, pixels: pixels)
        )

        #expect(Array(result.payload.prefix(9)) == [
            255, 0, 0,
            0, 255, 0,
            0, 0, 255
        ])

        let previewPayload = makeLogoPayload(red: 7, green: 8, blue: 9)
        let preview = try LogoImageConverter.makePreviewImage(from: previewPayload)
        #expect(Array(try rgbaBytes(from: preview).prefix(4)) == [7, 8, 9, 255])
    }

    @Test func logoConverterHonorsImageOrientationBeforeResizing() throws {
        let imageData = try makeOrientedJPEG()
        let result = try LogoImageConverter().convert(data: imageData)

        #expect(result.payload.count == LogoFileFormat.payloadLength)
        #expect(result.previewImage.width == 64)
        #expect(result.previewImage.height == 32)
    }

    @MainActor
    @Test func logoUploadWaitsForFragmentedReadyBeforeSendingPayload() async throws {
        let connection = FakeTCPConnection()
        let scheduler = FakeHeartbeatScheduler()
        let client = ESP32LogoUploadClient(
            connectionFactory: { _ in connection },
            timeoutScheduler: scheduler.schedule(_:_:)
        )
        let file = try LogoFileFormat.makeFile(payload: makeLogoPayload())
        var completedSuccessfully = false

        client.upload(
            file: file,
            to: .hostPort(host: .ipv4(try #require(IPv4Address("192.168.4.1"))), port: try #require(NWEndpoint.Port(rawValue: 5001))),
            operationID: UUID(),
            onStateChange: { _, _ in },
            onCompletion: { _, result in
                if case .success = result {
                    completedSuccessfully = true
                }
            }
        )
        connection.stateUpdateHandler?(.ready)
        await drainMainQueue()

        #expect(connection.sendCallCount == 1)
        #expect(connection.sentContents[0] == file.header)

        connection.lastSendCompletion?(nil)
        await drainMainQueue()
        let firstReceive = try #require(connection.lastReceiveCompletion)
        firstReceive(Data("REA".utf8), nil, false, nil)
        await drainMainQueue()

        #expect(connection.sendCallCount == 1)

        let secondReceive = try #require(connection.lastReceiveCompletion)
        secondReceive(Data("DY\n".utf8), nil, false, nil)
        await drainMainQueue()

        #expect(connection.sendCallCount == 2)
        #expect(connection.sentContents[1]?.count == ESP32LogoUploadClient.payloadChunkLength)
        #expect(!completedSuccessfully)
    }

    @MainActor
    @Test func logoUploadDoesNotSucceedUntilFragmentedOKArrives() async throws {
        let connection = FakeTCPConnection()
        let scheduler = FakeHeartbeatScheduler()
        let client = ESP32LogoUploadClient(
            connectionFactory: { _ in connection },
            timeoutScheduler: scheduler.schedule(_:_:)
        )
        let file = try LogoFileFormat.makeFile(payload: makeLogoPayload())
        var successCount = 0

        client.upload(
            file: file,
            to: .hostPort(host: .ipv4(try #require(IPv4Address("192.168.4.1"))), port: try #require(NWEndpoint.Port(rawValue: 5001))),
            operationID: UUID(),
            onStateChange: { _, _ in },
            onCompletion: { _, result in
                if case .success = result {
                    successCount += 1
                }
            }
        )

        try await driveLogoUploadToConfirmationWait(connection)
        #expect(successCount == 0)

        let firstOKReceive = try #require(connection.lastReceiveCompletion)
        firstOKReceive(Data("O".utf8), nil, false, nil)
        await drainMainQueue()
        #expect(successCount == 0)

        let secondOKReceive = try #require(connection.lastReceiveCompletion)
        secondOKReceive(Data("K\n".utf8), nil, false, nil)
        await drainMainQueue()

        #expect(successCount == 1)
    }

    @MainActor
    @Test func logoUploadRejectsNonExactSuccessLinesAndOversizedLines() async throws {
        try await assertLogoUploadFails(responseLine: "READY EXTRA\n", expectedMessagePart: "Expected READY")
        try await assertLogoUploadFails(responseLine: "OKAY\n", expectedMessagePart: "Expected OK", afterReady: true)

        let connection = FakeTCPConnection()
        let scheduler = FakeHeartbeatScheduler()
        let client = ESP32LogoUploadClient(
            connectionFactory: { _ in connection },
            timeoutScheduler: scheduler.schedule(_:_:)
        )
        let file = try LogoFileFormat.makeFile(payload: makeLogoPayload())
        var failureMessage: String?
        client.upload(
            file: file,
            to: .hostPort(host: .ipv4(try #require(IPv4Address("192.168.4.1"))), port: try #require(NWEndpoint.Port(rawValue: 5001))),
            operationID: UUID(),
            onStateChange: { _, _ in },
            onCompletion: { _, result in
                if case let .failure(error) = result {
                    failureMessage = error.localizedDescription
                }
            }
        )
        connection.stateUpdateHandler?(.ready)
        await drainMainQueue()
        connection.lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(repeating: 0x41, count: ESP32LogoUploadClient.responseLineLimit + 1), nil, false, nil)
        await drainMainQueue()

        #expect(failureMessage?.contains("exceeded 128 bytes") == true)
    }

    @MainActor
    @Test func logoUploadMapsFirmwareCRCFailure() async throws {
        var failureMessage: String?
        try await runLogoUpload(responseLine: "ERR CRC\n") { result in
            if case let .failure(error) = result {
                failureMessage = error.localizedDescription
            }
        }

        #expect(failureMessage?.contains("checksum mismatch") == true)
    }

    @MainActor
    @Test func wrongTXTBoardIDEndpointIsNotUsedAndRemovalClearsOnlyMatchingLogoEndpoint() async {
        let controlBrowser = FakeESP32Browser()
        let logoBrowser = FakeESP32Browser()
        let probes = FakeProbeConnectionRecorder()
        let timeouts = FakeTimeoutScheduler()
        let service = ESP32DiscoveryService(
            browserFactory: { controlBrowser },
            logoBrowserFactory: { logoBrowser },
            probeConnectionFactory: probes.makeConnection(endpoint:),
            timeoutScheduler: timeouts.schedule(_:)
        )

        service.beginDeviceScan()
        service.applyBrowseResultsForTesting([
            makeBrowseResult(serviceName: "ESP32 Clock 7", id: "7", firmware: "1.0.0")
        ], browser: controlBrowser)
        probes.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        let wrongLogo = makeLogoBrowseResult(serviceName: "ESP32 Clock 8 Logo", id: "8")
        service.applyLogoBrowseResultsForTesting([wrongLogo], browser: logoBrowser)
        #expect(service.devices[0].logoEndpoint == nil)

        let matchingLogo = makeLogoBrowseResult(serviceName: "ESP32 Clock 7 Logo", id: "7")
        service.applyLogoBrowseResultsForTesting([wrongLogo, matchingLogo], browser: logoBrowser)
        #expect(service.devices[0].logoEndpoint == matchingLogo.endpoint)

        service.applyLogoBrowseResultsForTesting([wrongLogo], browser: logoBrowser)
        #expect(service.devices[0].logoEndpoint == nil)
    }

    @MainActor
    @Test func strictTXTBoardIDParsingRejectsInvalidLogoIDs() {
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "0") == 0)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "255") == 255)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "92") == nil)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: " 7") == nil)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "7 ") == nil)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "+7") == nil)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "0x07") == nil)
        #expect(ESP32DiscoveryService.strictTXTBoardIDByte(from: "256") == nil)
    }

    @MainActor
    @Test func staleLogoConversionCannotReplaceNewerSelection() async throws {
        let firstPayload = makeLogoPayload(red: 1, green: 2, blue: 3)
        let secondPayload = makeLogoPayload(red: 4, green: 5, blue: 6)
        let releaseFirstConversion = DispatchSemaphore(value: 0)
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { data, _ in
                if data == Data([1]) {
                    releaseFirstConversion.wait()
                    return try makeLogoConversionResult(payload: firstPayload)
                }

                return try makeLogoConversionResult(payload: secondPayload)
            }
        )

        let firstSelection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([1]), selectionID: firstSelection)
        await drainMainQueue()

        let secondSelection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([2]), selectionID: secondSelection)
        await waitForLogoPayload(viewModel)

        releaseFirstConversion.signal()
        await drainMainQueue()
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == secondPayload)
    }

    @MainActor
    @Test func selectingPNGFileInvalidatesOlderPhotosPickerConversion() async throws {
        let photoPayload = makeLogoPayload(red: 1, green: 2, blue: 3)
        let filePayload = makeLogoPayload(red: 4, green: 5, blue: 6)
        let releasePhotoConversion = DispatchSemaphore(value: 0)
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { _, source in
                if source == .photos {
                    releasePhotoConversion.wait()
                    return try makeLogoConversionResult(payload: photoPayload)
                }

                return try makeLogoConversionResult(payload: filePayload)
            }
        )

        let photoSelection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([1]), selectionID: photoSelection, source: .photos)
        await drainMainQueue()

        let fileSelection = viewModel.beginLogoFileSelection()
        viewModel.convertSelectedLogoImage(Data([2]), selectionID: fileSelection, source: .files)
        await waitForLogoPayload(viewModel)

        releasePhotoConversion.signal()
        await drainMainQueue()
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == filePayload)
    }

    @MainActor
    @Test func selectingPhotoInvalidatesOlderPNGFileConversion() async throws {
        let filePayload = makeLogoPayload(red: 7, green: 8, blue: 9)
        let photoPayload = makeLogoPayload(red: 10, green: 11, blue: 12)
        let releaseFileConversion = DispatchSemaphore(value: 0)
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { _, source in
                if source == .files {
                    releaseFileConversion.wait()
                    return try makeLogoConversionResult(payload: filePayload)
                }

                return try makeLogoConversionResult(payload: photoPayload)
            }
        )

        let fileSelection = viewModel.beginLogoFileSelection()
        viewModel.convertSelectedLogoImage(Data([1]), selectionID: fileSelection, source: .files)
        await drainMainQueue()

        let photoSelection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([2]), selectionID: photoSelection, source: .photos)
        await waitForLogoPayload(viewModel)

        releaseFileConversion.signal()
        await drainMainQueue()
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == photoPayload)
    }

    @MainActor
    @Test func photoJPEGConversionPublishesLossySourceWarning() async throws {
        let fixture = try makeNativeShadowTestImage()
        let jpegData = try makeJPEG(width: 64, height: 32, pixels: fixture.pixels)
        let recorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: recorder,
            logoImageConverter: { data, source in
                try LogoImageConverter().convert(data: data, source: source)
            }
        )

        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(jpegData, selectionID: selection, source: .photos)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.convertedLogoPayload?.count == LogoFileFormat.payloadLength)
        #expect(viewModel.logoSourceDiagnostics?.typeIdentifier == UTType.jpeg.identifier)
        #expect(viewModel.logoSourceDiagnostics?.sourceDisplayName == "JPEG")
        #expect(viewModel.logoSourceDiagnostics?.dimensionsDisplayText == "64 × 32")
        #expect(viewModel.logoSourceDiagnostics?.conversionDisplayName == "Native dimensions, lossy source")
        #expect(viewModel.logoSourceCompressionWarning == LogoImageSourceDiagnostics.lossyCompressionWarning)
    }

    @MainActor
    @Test func uploadFailureLeavesConvertedPayloadAvailableForRetry() async throws {
        let payload = makeLogoPayload(red: 9, green: 10, blue: 11)
        let logoRecorder = FakeTCPConnectionRecorder()
        let logoScheduler = FakeHeartbeatScheduler()
        var capturedEndpoint: NWEndpoint?
        let logoClient = ESP32LogoUploadClient(
            connectionFactory: { endpoint in
                capturedEndpoint = endpoint
                return logoRecorder.makeConnection()
            },
            timeoutScheduler: logoScheduler.schedule(_:_:)
        )
        let controlRecorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            logoUploadClient: logoClient
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()

        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        #expect(viewModel.canUploadLogo)
        viewModel.uploadLogo()
        let logoConnection = try #require(logoRecorder.connections.first)
        try await driveLogoUploadToConfirmationWait(logoConnection)
        let receive = try #require(logoConnection.lastReceiveCompletion)
        receive(Data("ERR CRC\n".utf8), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.convertedLogoPayload == payload)
        #expect(viewModel.canUploadLogo)
        #expect(controlRecorder.connections[0].cancelCallCount == 0)
        if case let .hostPort(_, port) = capturedEndpoint {
            #expect(port.rawValue == LogoFileFormat.logoUploadPort)
        } else {
            Issue.record("Manual logo upload should use a host-port endpoint")
        }
    }

    @MainActor
    @Test func logoOKPresentsSuccessAlertAndDismissReturnsReady() async throws {
        let payload = makeLogoPayload(red: 12, green: 13, blue: 14)
        let logoRecorder = FakeTCPConnectionRecorder()
        let logoClient = ESP32LogoUploadClient(connectionFactory: { _ in logoRecorder.makeConnection() })
        let controlRecorder = FakeTCPConnectionRecorder()
        let viewModel = makeViewModelForLogoTests(
            recorder: controlRecorder,
            logoImageConverter: { _, _ in try makeLogoConversionResult(payload: payload) },
            logoUploadClient: logoClient
        )

        viewModel.manualBoardID = "0"
        viewModel.connect()
        await drainMainQueue()
        controlRecorder.connections[0].stateUpdateHandler?(.ready)
        await drainMainQueue()
        let selection = viewModel.beginLogoPhotoSelection()
        viewModel.convertSelectedLogoImage(Data([0]), selectionID: selection)
        await waitForLogoPayload(viewModel)

        viewModel.uploadLogo()
        let logoConnection = try #require(logoRecorder.connections.first)
        try await driveLogoUploadToConfirmationWait(logoConnection)
        let receive = try #require(logoConnection.lastReceiveCompletion)
        receive(Data("OK\n".utf8), nil, false, nil)
        await drainMainQueue()

        #expect(viewModel.logoUploadState == .succeeded)
        #expect(viewModel.isLogoUploadSuccessAlertPresented)

        viewModel.dismissLogoUploadSuccessAlert()

        #expect(viewModel.logoUploadState == .ready)
        #expect(viewModel.processedLogoPreview != nil)
    }
}

#if LOGIN_ENABLED
private func makeAuthenticatedUser(username: String = "master") -> AuthenticatedUser {
    AuthenticatedUser(
        id: "test-user",
        username: username,
        displayName: "Test Master",
        role: .master
    )
}

@MainActor
private func makeLocalAuthenticationService(
    username: String,
    password: String,
    salt: String = "test-salt"
) -> LocalMasterAuthenticationService {
    LocalMasterAuthenticationService(
        username: username,
        salt: salt,
        passwordHashHex: LocalMasterAuthenticationService.passwordHashHex(
            salt: salt,
            password: password
        )
    )
}

private func expectAuthenticationFailure(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Authentication should have failed")
    } catch {
        #expect(error as? AuthenticationFailure == .invalidCredentials)
    }
}

private struct SucceedingAuthenticationService: AuthenticationService {
    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        makeAuthenticatedUser(username: username)
    }
}

private struct FailingAuthenticationService: AuthenticationService {
    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        throw AuthenticationFailure.invalidCredentials
    }
}

private final class SuspendedAuthenticationService: AuthenticationService {
    private(set) var attemptCount = 0
    private var continuation: CheckedContinuation<AuthenticatedUser, any Error>?

    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        attemptCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        continuation?.resume(returning: makeAuthenticatedUser())
        continuation = nil
    }
}

private final class SuspendedRestoreAuthenticationService: AuthenticationService {
    private var continuation: CheckedContinuation<AuthenticatedUser?, any Error>?

    func restoreSession() async throws -> AuthenticatedUser? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        makeAuthenticatedUser(username: username)
    }

    func succeed() {
        continuation?.resume(returning: makeAuthenticatedUser())
        continuation = nil
    }
}

private final class InMemorySessionTokenStore: SessionTokenStore {
    var token: String?
    var saveError: Error?
    var loadError: Error?
    var deleteError: Error?

    init(token: String? = nil) {
        self.token = token
    }

    func saveToken(_ token: String) throws {
        if let saveError {
            throw saveError
        }
        self.token = token
    }

    func loadToken() throws -> String? {
        if let loadError {
            throw loadError
        }
        return token
    }

    func deleteToken() throws {
        if let deleteError {
            throw deleteError
        }
        token = nil
    }
}

private let testAuthBaseURL = URL(string: "http://auth.example:8080")!

@MainActor
private func makeDatabaseAuthenticationSession(
    tokenStore: InMemorySessionTokenStore = InMemorySessionTokenStore(),
    userDefaults: UserDefaults = makeIsolatedUserDefaults(),
    apiClient: AuthenticationAPIClient = makeMockedAuthenticationAPIClient(
        statusCode: 200,
        body: loginResponseData(token: "default-token")
    ),
    dateProvider: @escaping () -> Date = { Date(timeIntervalSince1970: 1_783_000_000) }
) -> AuthenticationSession {
    let configurationStore = AuthServerConfigurationStore(
        defaultBaseURL: testAuthBaseURL,
        userDefaults: userDefaults,
        userDefaultsKey: "ESP32ControllerTests.AuthServer.\(UUID().uuidString)"
    )
    let service = DatabaseAuthenticationService(
        apiClient: apiClient,
        tokenStore: tokenStore,
        configurationStore: configurationStore,
        dateProvider: dateProvider
    )
    return AuthenticationSession(authenticationService: service)
}

private func makeMockedAuthenticationAPIClient(
    statusCode: Int,
    body: Data
) -> AuthenticationAPIClient {
    makeMockedAuthenticationAPIClient { request in
        makeHTTPResponse(url: try #require(request.url), statusCode: statusCode, body: body)
    }
}

private func makeMockedAuthenticationAPIClient(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> AuthenticationAPIClient {
    MockAuthenticationURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockAuthenticationURLProtocol.self]
    return AuthenticationAPIClient(
        session: URLSession(configuration: configuration),
        timeout: 0.1
    )
}

private final class MockAuthenticationURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeHTTPResponse(
    url: URL,
    statusCode: Int,
    body: Data
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!,
        body
    )
}

private func loginResponseData(
    token: String,
    username: String = "example",
    role: String = "master"
) -> Data {
    Data("""
    {
      "token": "\(token)",
      "expiresAt": "2026-07-02T18:30:00Z",
      "user": {
        "id": 1,
        "username": "\(username)",
        "displayName": "Example User",
        "role": "\(role)"
      }
    }
    """.utf8)
}

private func sessionResponseData(
    username: String = "example",
    role: String = "master"
) -> Data {
    Data("""
    {
      "expiresAt": "2026-07-02T18:30:00Z",
      "user": {
        "id": 1,
        "username": "\(username)",
        "displayName": "Example User",
        "role": "\(role)"
      }
    }
    """.utf8)
}

private func requestBodyJSON(_ request: URLRequest) throws -> [String: Any] {
    let body: Data
    if let httpBody = request.httpBody {
        body = httpBody
    } else if let stream = request.httpBodyStream {
        body = Data(reading: stream)
    } else {
        body = Data()
    }

    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func expectAPIError(
    _ expectedError: AuthenticationAPIError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("API operation should have failed")
    } catch {
        #expect(error as? AuthenticationAPIError == expectedError)
    }
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer {
            stream.close()
        }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                append(buffer, count: count)
            } else {
                break
            }
        }
    }
}
#endif

@MainActor
private func unauthorizedViewModel(
    recorder: FakeTCPConnectionRecorder,
    reconnectScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    userDefaults: UserDefaults = .standard
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() }
    )
    return ESP32ControllerViewModel(
        client: client,
        discoveryService: ESP32DiscoveryService(
            browserFactory: { FakeESP32Browser() },
            logoBrowserFactory: { FakeESP32Browser() }
        ),
        reconnectScheduler: reconnectScheduler,
        userDefaults: userDefaults
    )
}

private func fireLatestActiveHeartbeatTask(_ scheduler: FakeHeartbeatScheduler) throws {
    let task = try #require(scheduler.tasks.last { !$0.isCancelled })
    task.fire()
}

@MainActor
private func makeViewModelForManualHeartbeatTests(
    recorder: FakeTCPConnectionRecorder,
    heartbeatScheduler: FakeHeartbeatScheduler,
    ackTimeouts: FakeHeartbeatScheduler,
    reconnectScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    userDefaults: UserDefaults = .standard
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() },
        heartbeatScheduler: heartbeatScheduler.schedule(_:_:),
        heartbeatACKTimeoutScheduler: ackTimeouts.schedule(_:_:)
    )

    let viewModel = ESP32ControllerViewModel(
        client: client,
        discoveryService: ESP32DiscoveryService(
            browserFactory: { FakeESP32Browser() },
            logoBrowserFactory: { FakeESP32Browser() }
        ),
        reconnectScheduler: reconnectScheduler,
        userDefaults: userDefaults
    )
    viewModel.authorizeNetworking()
    return viewModel
}

private func makeBrowseResult(
    serviceName: String,
    id: String,
    model: String = "clock",
    protocolVersion: String = "1",
    firmware: String
) -> ESP32BrowseResult {
    return ESP32BrowseResult(
        endpoint: .service(
            name: serviceName,
            type: ESP32DiscoveryService.serviceType,
            domain: "local",
            interface: nil
        ),
        metadata: .bonjour(NWTXTRecord([
            "id": id,
            "model": model,
            "protocol": protocolVersion,
            "firmware": firmware
        ]))
    )
}

private func makeLogoBrowseResult(
    serviceName: String,
    id: String,
    hostname: String? = nil
) -> ESP32BrowseResult {
    var txt = ["id": id]
    if let hostname {
        txt["hostname"] = hostname
    }

    return ESP32BrowseResult(
        endpoint: .service(
            name: serviceName,
            type: ESP32DiscoveryService.logoServiceType,
            domain: "local",
            interface: nil
        ),
        metadata: .bonjour(NWTXTRecord(txt))
    )
}

private func makeDevice(id: String, serviceName: String, boardID: String?) -> DiscoveredESP32 {
    DiscoveredESP32(
        id: id,
        serviceName: serviceName,
        endpoint: .service(
            name: serviceName,
            type: ESP32DiscoveryService.serviceType,
            domain: "local",
            interface: nil
        ),
        boardID: boardID,
        model: nil,
        protocolVersion: nil,
        firmwareVersion: nil
    )
}

private struct RGBA: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var isBlack: Bool {
        red == 0 && green == 0 && blue == 0
    }
}

private struct NativeShadowTestImage {
    let data: Data
    let pixels: [RGBA]
}

private let logoResizeTopLeft = RGBA(255, 32, 32, 255)
private let logoResizeTopRight = RGBA(32, 255, 32, 255)
private let logoResizeBottomLeft = RGBA(32, 32, 255, 255)
private let logoResizeBottomRight = RGBA(255, 255, 32, 255)
private let logoResizeTopEdge = RGBA(255, 32, 255, 255)
private let logoResizeBottomEdge = RGBA(32, 255, 255, 255)
private let logoResizeLeftEdge = RGBA(255, 128, 32, 255)
private let logoResizeRightEdge = RGBA(128, 255, 32, 255)
private let logoResizeFill = RGBA(96, 144, 192, 255)

private func makeLogoPayload(red: UInt8 = 1, green: UInt8 = 2, blue: UInt8 = 3) -> Data {
    var payload = Data()
    payload.reserveCapacity(LogoFileFormat.payloadLength)
    for _ in 0..<(LogoFileFormat.payloadLength / 3) {
        payload.append(red)
        payload.append(green)
        payload.append(blue)
    }
    return payload
}

private func makeLogoConversionResult(payload: Data) throws -> LogoImageConversionResult {
    LogoImageConversionResult(
        payload: payload,
        previewImage: try LogoImageConverter.makePreviewImage(from: payload)
    )
}

private func makeSolidPNG(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) throws -> Data {
    try makePNG(width: 1, height: 1, pixels: [RGBA(red, green, blue, alpha)])
}

private func makeNativeShadowTestImage(
    pngEncoder: (Int, Int, [RGBA]) throws -> Data = makePNG
) throws -> NativeShadowTestImage {
    let width = Int(LogoFileFormat.width)
    let height = Int(LogoFileFormat.height)
    var pixels = [RGBA](repeating: RGBA(0, 0, 0, 255), count: width * height)

    for x in 8..<56 {
        pixels[nativePixelIndex(x: x, y: 16)] = RGBA(255, 128, 0, 255)
    }

    fillNativeSquare(in: &pixels, xRange: 2..<8, yRange: 2..<8, color: RGBA(255, 0, 0, 255))
    fillNativeSquare(in: &pixels, xRange: 56..<62, yRange: 2..<8, color: RGBA(0, 255, 0, 255))
    fillNativeSquare(in: &pixels, xRange: 2..<8, yRange: 24..<30, color: RGBA(0, 0, 255, 255))
    fillNativeSquare(in: &pixels, xRange: 56..<62, yRange: 24..<30, color: RGBA(255, 255, 0, 255))

    return NativeShadowTestImage(
        data: try pngEncoder(width, height, pixels),
        pixels: pixels
    )
}

private func fillNativeSquare(
    in pixels: inout [RGBA],
    xRange: Range<Int>,
    yRange: Range<Int>,
    color: RGBA
) {
    for y in yRange {
        for x in xRange {
            pixels[nativePixelIndex(x: x, y: y)] = color
        }
    }
}

private func assertNativeShadowOutputMatchesSource(sourcePixels: [RGBA], payload: Data) throws {
    let width = Int(LogoFileFormat.width)
    let height = Int(LogoFileFormat.height)
    #expect(sourcePixels.count == width * height)
    #expect(payload.count == LogoFileFormat.payloadLength)

    var sourceNonBlack = Set<Int>()
    var outputNonBlack = Set<Int>()
    for y in 0..<height {
        for x in 0..<width {
            let index = nativePixelIndex(x: x, y: y)
            let sourcePixel = sourcePixels[index]
            let outputPixel = try payloadRGB(payload, x: x, y: y)

            if sourcePixel.isBlack {
                assertRGB(outputPixel, equals: RGBA(0, 0, 0, 255), x: x, y: y)
            } else {
                sourceNonBlack.insert(index)
                assertRGB(outputPixel, equals: sourcePixel, x: x, y: y)
            }

            if outputPixel.r != 0 || outputPixel.g != 0 || outputPixel.b != 0 {
                outputNonBlack.insert(index)
            }
        }
    }

    #expect(outputNonBlack == sourceNonBlack)

    for x in 8..<56 {
        assertRGB(try payloadRGB(payload, x: x, y: 16), equals: RGBA(255, 128, 0, 255), x: x, y: 16)
        assertRGB(try payloadRGB(payload, x: x, y: 15), equals: RGBA(0, 0, 0, 255), x: x, y: 15)
        assertRGB(try payloadRGB(payload, x: x, y: 17), equals: RGBA(0, 0, 0, 255), x: x, y: 17)
    }

    try assertBlackBorderBesideSquare(payload, xRange: 2..<8, yRange: 2..<8)
    try assertBlackBorderBesideSquare(payload, xRange: 56..<62, yRange: 2..<8)
    try assertBlackBorderBesideSquare(payload, xRange: 2..<8, yRange: 24..<30)
    try assertBlackBorderBesideSquare(payload, xRange: 56..<62, yRange: 24..<30)
}

private func nativeBlackPixelBleedDiagnostics(sourcePixels: [RGBA], payload: Data) throws -> [String] {
    let width = Int(LogoFileFormat.width)
    let height = Int(LogoFileFormat.height)
    var changedPixels: [String] = []

    for y in 0..<height {
        for x in 0..<width {
            let sourcePixel = sourcePixels[nativePixelIndex(x: x, y: y)]
            let outputPixel = try payloadRGB(payload, x: x, y: y)
            if sourcePixel.isBlack, outputPixel.r != 0 || outputPixel.g != 0 || outputPixel.b != 0 {
                changedPixels.append("x=\(x), y=\(y), rgb=(\(outputPixel.r), \(outputPixel.g), \(outputPixel.b))")
            }
        }
    }

    return changedPixels
}

private func nativeBlackToNonBlackPixelCount(sourcePixels: [RGBA], payload: Data) throws -> Int {
    try nativeBlackPixelBleedDiagnostics(sourcePixels: sourcePixels, payload: payload).count
}

private func assertBlackBorderBesideSquare(
    _ payload: Data,
    xRange: Range<Int>,
    yRange: Range<Int>
) throws {
    let leftX = xRange.lowerBound - 1
    let rightX = xRange.upperBound
    let topY = yRange.lowerBound - 1
    let bottomY = yRange.upperBound

    for y in yRange {
        try assertBlackNativePixel(payload, x: leftX, y: y)
        try assertBlackNativePixel(payload, x: rightX, y: y)
    }

    for x in xRange {
        try assertBlackNativePixel(payload, x: x, y: topY)
        try assertBlackNativePixel(payload, x: x, y: bottomY)
    }
}

private func assertBlackNativePixel(_ payload: Data, x: Int, y: Int) throws {
    assertRGB(try payloadRGB(payload, x: x, y: y), equals: RGBA(0, 0, 0, 255), x: x, y: y)
}

private func assertRGB(
    _ actual: (r: UInt8, g: UInt8, b: UInt8),
    equals expected: RGBA,
    x: Int,
    y: Int
) {
    #expect(actual.r == expected.red, "Red mismatch at x=\(x), y=\(y)")
    #expect(actual.g == expected.green, "Green mismatch at x=\(x), y=\(y)")
    #expect(actual.b == expected.blue, "Blue mismatch at x=\(x), y=\(y)")
}

private func payloadRGB(_ payload: Data, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    let index = nativePixelIndex(x: x, y: y) * 3
    try #require(index + 2 < payload.count)
    return (payload[index], payload[index + 1], payload[index + 2])
}

private func nativePixelIndex(x: Int, y: Int) -> Int {
    y * Int(LogoFileFormat.width) + x
}

private func rgbPayload(from image: CGImage) throws -> Data {
    let rgba = try rgbaBytes(from: image)
    var payload = Data()
    payload.reserveCapacity(image.width * image.height * 3)

    for pixelOffset in stride(from: 0, to: rgba.count, by: 4) {
        payload.append(rgba[pixelOffset])
        payload.append(rgba[pixelOffset + 1])
        payload.append(rgba[pixelOffset + 2])
    }

    return payload
}

private func decodedPixels(fromImageData data: Data) throws -> [RGBA] {
    guard
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        throw TestImageError.creationFailed
    }

    let rgba = try rgbaBytes(from: image)
    var pixels: [RGBA] = []
    pixels.reserveCapacity(image.width * image.height)

    for pixelOffset in stride(from: 0, to: rgba.count, by: 4) {
        pixels.append(
            RGBA(
                rgba[pixelOffset],
                rgba[pixelOffset + 1],
                rgba[pixelOffset + 2],
                rgba[pixelOffset + 3]
            )
        )
    }

    return pixels
}

private func makeLogoResizeProbePNG(width: Int, height: Int) throws -> Data {
    let band = max(6, min(width, height) / 5)
    var pixels: [RGBA] = []
    pixels.reserveCapacity(width * height)

    for y in 0..<height {
        for x in 0..<width {
            pixels.append(logoResizeProbePixel(x: x, y: y, width: width, height: height, band: band))
        }
    }

    return try makePNG(width: width, height: height, pixels: pixels)
}

private func logoResizeProbePixel(x: Int, y: Int, width: Int, height: Int, band: Int) -> RGBA {
    if x < band, y < band {
        return logoResizeTopLeft
    } else if x >= width - band, y < band {
        return logoResizeTopRight
    } else if x < band, y >= height - band {
        return logoResizeBottomLeft
    } else if x >= width - band, y >= height - band {
        return logoResizeBottomRight
    } else if y < band {
        return logoResizeTopEdge
    } else if y >= height - band {
        return logoResizeBottomEdge
    } else if x < band {
        return logoResizeLeftEdge
    } else if x >= width - band {
        return logoResizeRightEdge
    } else {
        return logoResizeFill
    }
}

private func assertLogoResizeProbeOutput(_ result: LogoImageConversionResult) throws {
    let width = Int(LogoFileFormat.width)
    let height = Int(LogoFileFormat.height)

    #expect(result.payload.count == 64 * 32 * 3)
    #expect(result.payload.count == LogoFileFormat.payloadLength)
    #expect(result.previewImage.width == width)
    #expect(result.previewImage.height == height)

    try assertLogoPixel(result.payload, x: 0, y: 0, matches: logoResizeTopLeft)
    try assertLogoPixel(result.payload, x: width - 1, y: 0, matches: logoResizeTopRight)
    try assertLogoPixel(result.payload, x: 0, y: height - 1, matches: logoResizeBottomLeft)
    try assertLogoPixel(result.payload, x: width - 1, y: height - 1, matches: logoResizeBottomRight)

    try assertLogoPixel(result.payload, x: width / 2, y: 0, matches: logoResizeTopEdge)
    try assertLogoPixel(result.payload, x: width / 2, y: height - 1, matches: logoResizeBottomEdge)
    try assertLogoPixel(result.payload, x: 0, y: height / 2, matches: logoResizeLeftEdge)
    try assertLogoPixel(result.payload, x: width - 1, y: height / 2, matches: logoResizeRightEdge)
}

private func assertLogoPixel(
    _ payload: Data,
    x: Int,
    y: Int,
    matches expected: RGBA,
    tolerance: Int = 72
) throws {
    let width = Int(LogoFileFormat.width)
    let index = ((y * width) + x) * 3
    try #require(index + 2 < payload.count)
    let red = payload[index]
    let green = payload[index + 1]
    let blue = payload[index + 2]

    #expect(abs(Int(red) - Int(expected.red)) <= tolerance)
    #expect(abs(Int(green) - Int(expected.green)) <= tolerance)
    #expect(abs(Int(blue) - Int(expected.blue)) <= tolerance)
}

private func makePNG(width: Int, height: Int, pixels: [RGBA]) throws -> Data {
    let expectedPixelCount = width * height
    #expect(pixels.count == expectedPixelCount)

    var rgba = Data()
    rgba.reserveCapacity(expectedPixelCount * 4)
    for pixel in pixels {
        rgba.append(pixel.red)
        rgba.append(pixel.green)
        rgba.append(pixel.blue)
        rgba.append(pixel.alpha)
    }

    return try makePNGData(
        width: width,
        height: height,
        rgba: rgba,
        alphaInfo: .last
    )
}

private func makeRGBPNG(width: Int, height: Int, pixels: [RGBA]) throws -> Data {
    let expectedPixelCount = width * height
    #expect(pixels.count == expectedPixelCount)

    var rgba = Data()
    rgba.reserveCapacity(expectedPixelCount * 4)
    for pixel in pixels {
        rgba.append(pixel.red)
        rgba.append(pixel.green)
        rgba.append(pixel.blue)
        rgba.append(0xFF)
    }

    return try makePNGData(
        width: width,
        height: height,
        rgba: rgba,
        alphaInfo: .noneSkipLast
    )
}

private func makeJPEG(
    width: Int,
    height: Int,
    pixels: [RGBA],
    compressionQuality: CGFloat = 0.75
) throws -> Data {
    let expectedPixelCount = width * height
    #expect(pixels.count == expectedPixelCount)

    var rgba = Data()
    rgba.reserveCapacity(expectedPixelCount * 4)
    for pixel in pixels {
        rgba.append(pixel.red)
        rgba.append(pixel.green)
        rgba.append(pixel.blue)
        rgba.append(0xFF)
    }

    guard
        let provider = CGDataProvider(data: rgba as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let mutableData = CFDataCreateMutable(nil, 0),
        let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else {
        throw TestImageError.creationFailed
    }

    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.creationFailed
    }

    return mutableData as Data
}

private func makePNGData(
    width: Int,
    height: Int,
    rgba: Data,
    alphaInfo: CGImageAlphaInfo
) throws -> Data {
    let expectedByteCount = width * height * 4
    #expect(rgba.count == expectedByteCount)

    guard
        let provider = CGDataProvider(data: rgba as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: alphaInfo.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let mutableData = CFDataCreateMutable(nil, 0),
        let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw TestImageError.creationFailed
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.creationFailed
    }

    return mutableData as Data
}

private func makeOrientedJPEG() throws -> Data {
    var pixels = [RGBA](repeating: RGBA(0, 0, 0, 255), count: 32 * 64)
    pixels[0] = RGBA(255, 0, 0, 255)
    let pngData = try makePNG(width: 32, height: 64, pixels: pixels)
    guard
        let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
        let mutableData = CFDataCreateMutable(nil, 0),
        let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else {
        throw TestImageError.creationFailed
    }

    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.creationFailed
    }

    return mutableData as Data
}

private func rgbaBytes(from image: CGImage) throws -> Data {
    var data = Data(repeating: 0, count: image.width * image.height * 4)
    let result = data.withUnsafeMutableBytes { buffer in
        guard
            let baseAddress = buffer.baseAddress,
            let context = CGContext(
                data: baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }

    guard result else {
        throw TestImageError.creationFailed
    }

    return data
}

private enum TestImageError: Error {
    case creationFailed
}

@MainActor
private func driveLogoUploadToConfirmationWait(_ connection: FakeTCPConnection) async throws {
    connection.stateUpdateHandler?(.ready)
    await drainMainQueue()
    connection.lastSendCompletion?(nil)
    await drainMainQueue()
    let readyReceive = try #require(connection.lastReceiveCompletion)
    readyReceive(Data("READY\n".utf8), nil, false, nil)
    await drainMainQueue()

    while connection.sentContents.count < 1 + (LogoFileFormat.payloadLength / ESP32LogoUploadClient.payloadChunkLength) {
        connection.lastSendCompletion?(nil)
        await drainMainQueue()
    }

    #expect(connection.sentContents.count == 7)
    connection.lastSendCompletion?(nil)
    await drainMainQueue()
}

@MainActor
private func runLogoUpload(
    responseLine: String,
    completion: @escaping (Result<Void, ESP32LogoUploadError>) -> Void
) async throws {
    let connection = FakeTCPConnection()
    let client = ESP32LogoUploadClient(connectionFactory: { _ in connection })
    let file = try LogoFileFormat.makeFile(payload: makeLogoPayload())
    client.upload(
        file: file,
        to: .hostPort(host: .ipv4(try #require(IPv4Address("192.168.4.1"))), port: try #require(NWEndpoint.Port(rawValue: 5001))),
        operationID: UUID(),
        onStateChange: { _, _ in },
        onCompletion: { _, result in completion(result) }
    )

    try await driveLogoUploadToConfirmationWait(connection)
    let receive = try #require(connection.lastReceiveCompletion)
    receive(Data(responseLine.utf8), nil, false, nil)
    await drainMainQueue()
}

@MainActor
private func assertLogoUploadFails(
    responseLine: String,
    expectedMessagePart: String,
    afterReady: Bool = false
) async throws {
    var failureMessage: String?
    if afterReady {
        try await runLogoUpload(responseLine: responseLine) { result in
            if case let .failure(error) = result {
                failureMessage = error.localizedDescription
            }
        }
    } else {
        let connection = FakeTCPConnection()
        let client = ESP32LogoUploadClient(connectionFactory: { _ in connection })
        let file = try LogoFileFormat.makeFile(payload: makeLogoPayload())
        client.upload(
            file: file,
            to: .hostPort(host: .ipv4(try #require(IPv4Address("192.168.4.1"))), port: try #require(NWEndpoint.Port(rawValue: 5001))),
            operationID: UUID(),
            onStateChange: { _, _ in },
            onCompletion: { _, result in
                if case let .failure(error) = result {
                    failureMessage = error.localizedDescription
                }
            }
        )
        connection.stateUpdateHandler?(.ready)
        await drainMainQueue()
        connection.lastSendCompletion?(nil)
        await drainMainQueue()
        let receive = try #require(connection.lastReceiveCompletion)
        receive(Data(responseLine.utf8), nil, false, nil)
        await drainMainQueue()
    }

    #expect(failureMessage?.contains(expectedMessagePart) == true)
}

@MainActor
private func makeViewModelForConnectionIndicatorTests(
    recorder: FakeTCPConnectionRecorder,
    currentDateProvider: @escaping () -> Date = Date.init,
    timeSyncScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    reconnectScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    userDefaults: UserDefaults = .standard
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in
            recorder.makeConnection()
        },
        endpointConnectionFactory: { _ in
            recorder.makeConnection()
        }
    )
    let browser = FakeESP32Browser()
    let logoBrowser = FakeESP32Browser()
    let discoveryService = ESP32DiscoveryService(
        browserFactory: { browser },
        logoBrowserFactory: { logoBrowser }
    )

    let viewModel = ESP32ControllerViewModel(
        client: client,
        discoveryService: discoveryService,
        currentDateProvider: currentDateProvider,
        timeSyncScheduler: timeSyncScheduler,
        reconnectScheduler: reconnectScheduler,
        userDefaults: userDefaults
    )
    viewModel.authorizeNetworking()
    return viewModel
}

@MainActor
private func makeViewModelForLogoTests(
    recorder: FakeTCPConnectionRecorder,
    logoImageConverter: @escaping ESP32ControllerViewModel.LogoConversion,
    logoUploadClient: ESP32LogoUploadClient? = nil,
    discoveryService: ESP32DiscoveryService? = nil,
    timeSyncScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    reconnectScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    userDefaults: UserDefaults = .standard
) -> ESP32ControllerViewModel {
    let client = ESP32TCPClient(
        connectionFactory: { _, _ in recorder.makeConnection() },
        endpointConnectionFactory: { _ in recorder.makeConnection() }
    )
    let defaultDiscoveryService = ESP32DiscoveryService(
        browserFactory: { FakeESP32Browser() },
        logoBrowserFactory: { FakeESP32Browser() }
    )

    let viewModel = ESP32ControllerViewModel(
        client: client,
        discoveryService: discoveryService ?? defaultDiscoveryService,
        timeSyncScheduler: timeSyncScheduler,
        reconnectScheduler: reconnectScheduler,
        logoImageConverter: logoImageConverter,
        logoUploadClient: logoUploadClient ?? ESP32LogoUploadClient(),
        userDefaults: userDefaults
    )
    viewModel.authorizeNetworking()
    return viewModel
}

private func gregorianUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func makeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int
) -> Date? {
    var components = DateComponents()
    components.calendar = gregorianUTCCalendar()
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return gregorianUTCCalendar().date(from: components)
}

@MainActor
private func connectedViewModel(
    recorder: FakeTCPConnectionRecorder,
    boardID: String,
    currentDateProvider: @escaping () -> Date = Date.init,
    timeSyncScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    reconnectScheduler: @escaping ESP32ControllerViewModel.TimeSyncScheduler = { delay, callback in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return TestDispatchWorkItemCancellable(workItem: workItem)
    },
    userDefaults: UserDefaults = .standard
) async throws -> ESP32ControllerViewModel {
    let viewModel = makeViewModelForConnectionIndicatorTests(
        recorder: recorder,
        currentDateProvider: currentDateProvider,
        timeSyncScheduler: timeSyncScheduler,
        reconnectScheduler: reconnectScheduler,
        userDefaults: userDefaults
    )
    viewModel.manualBoardID = boardID
    viewModel.connect()
    await drainMainQueue()
    let connection = try #require(recorder.connections.first)
    connection.stateUpdateHandler?(.ready)
    await drainMainQueue()
    return viewModel
}

private func expectedCTFrame(
    boardID: UInt8,
    is24Hour: Bool,
    brightnessLevel: UInt8
) -> [UInt8] {
    let format: UInt8 = is24Hour ? 0x01 : 0x00
    let intensity = UInt8((Int(brightnessLevel) * 255) / 10)
    return [0x2F, 0x54, 0x41, boardID, 0x43, 0x54, format, intensity, 0x5C]
}

private func expectedUCAcknowledgement(boardID: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x75, 0x63, 0x5C]
}

private func expectedNMFrame(boardID: UInt8) -> [UInt8] {
    [0x2F, 0x54, 0x41, boardID, 0x4E, 0x4D, 0x5C]
}

private func expectedNMResponse(boardID: UInt8, mode: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x6E, 0x6D, mode, 0x5C]
}

private func expectedDLFrame(boardID: UInt8) -> [UInt8] {
    [0x2F, 0x54, 0x41, boardID, 0x44, 0x4C, 0x5C]
}

private func expectedDLResponse(boardID: UInt8, result: UInt8) -> [UInt8] {
    [0x2F, 0x74, 0x61, boardID, 0x64, 0x6C, result, 0x5C]
}

private func makeIsolatedUserDefaults() -> UserDefaults {
    let suiteName = "ESP32ControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func saveLastConnectedDevice(_ record: LastConnectedDevice, to defaults: UserDefaults) {
    let data = try! JSONEncoder().encode(record)
    defaults.set(data, forKey: ESP32ControllerViewModel.lastConnectedDeviceDefaultsKey)
}

private func makeBonjourLastDevice(
    boardID: UInt8 = 0,
    displayName: String = "Clock 0",
    serviceInstanceName: String = "Clock 0",
    hostname: String = "esp32-clock-0.local"
) -> LastConnectedDevice {
    LastConnectedDevice(
        boardID: boardID,
        displayName: displayName,
        serviceInstanceName: serviceInstanceName,
        serviceType: ESP32DiscoveryService.serviceType,
        serviceDomain: "local",
        hostname: hostname,
        controlPort: ESP32TCPClient.defaultPort,
        source: .bonjour,
        manualHost: nil
    )
}

@MainActor
private func makeDiscoveryService(
    browser: FakeESP32Browser,
    probes: FakeProbeConnectionRecorder,
    timeouts: FakeTimeoutScheduler,
    settles: FakeTimeoutScheduler? = nil
) -> ESP32DiscoveryService {
    ESP32DiscoveryService(
        browserFactory: {
            browser
        },
        logoBrowserFactory: {
            FakeESP32Browser()
        },
        probeConnectionFactory: probes.makeConnection(endpoint:),
        timeoutScheduler: timeouts.schedule(_:),
        initialResultSettleScheduler: (settles ?? FakeTimeoutScheduler()).schedule(_:)
    )
}

@MainActor
private func makeDiscoveryService(
    browsers: FakeBrowserRecorder,
    probes: FakeProbeConnectionRecorder,
    timeouts: FakeTimeoutScheduler,
    settles: FakeTimeoutScheduler? = nil
) -> ESP32DiscoveryService {
    ESP32DiscoveryService(
        browserFactory: browsers.makeBrowser,
        logoBrowserFactory: {
            FakeESP32Browser()
        },
        probeConnectionFactory: probes.makeConnection(endpoint:),
        timeoutScheduler: timeouts.schedule(_:),
        initialResultSettleScheduler: (settles ?? FakeTimeoutScheduler()).schedule(_:)
    )
}

private final class FakeTCPConnectionRecorder {
    var connections: [FakeTCPConnection] = []

    func makeConnection() -> FakeTCPConnection {
        let connection = FakeTCPConnection()
        connections.append(connection)
        return connection
    }
}

private final class FakeBrowserRecorder {
    var browsers: [FakeESP32Browser] = []

    func makeBrowser() -> FakeESP32Browser {
        let browser = FakeESP32Browser()
        browsers.append(browser)
        return browser
    }
}

private final class FakeProbeConnectionRecorder {
    var connections: [FakeProbeConnection] = []

    func makeConnection(endpoint: NWEndpoint) -> FakeProbeConnection {
        let connection = FakeProbeConnection(endpoint: endpoint)
        connections.append(connection)
        return connection
    }
}

private final class FakeProbeConnection: ESP32ProbeConnection {
    let endpoint: NWEndpoint
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var startCallCount = 0
    var cancelCallCount = 0

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start(queue: DispatchQueue) {
        startCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeTimeoutScheduler {
    var tasks: [FakeCancellableTask] = []

    func schedule(_ timeout: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = FakeCancellableTask(timeout: timeout)
        tasks.append(task)
        return task
    }
}

private final class FakeCancellableTask: CancellableTask {
    private let timeout: @Sendable () -> Void
    var cancelCallCount = 0
    var isCancelled = false

    init(timeout: @escaping @Sendable () -> Void) {
        self.timeout = timeout
    }

    func cancel() {
        cancelCallCount += 1
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else {
            return
        }

        timeout()
    }
}

private struct TestDispatchWorkItemCancellable: CancellableTask {
    let workItem: DispatchWorkItem

    func cancel() {
        workItem.cancel()
    }
}

private final class FakeHeartbeatScheduler {
    var tasks: [FakeScheduledHeartbeatTask] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) -> CancellableTask {
        let task = FakeScheduledHeartbeatTask(delay: delay, callback: callback)
        tasks.append(task)
        return task
    }
}

private final class FakeScheduledHeartbeatTask: CancellableTask {
    let delay: TimeInterval
    private let callback: @Sendable () -> Void
    var cancelCallCount = 0
    var isCancelled = false

    init(delay: TimeInterval, callback: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.callback = callback
    }

    func cancel() {
        cancelCallCount += 1
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else {
            return
        }

        callback()
    }

    func fireIgnoringCancellationForTesting() {
        callback()
    }
}

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
private func waitForLogoPayload(_ viewModel: ESP32ControllerViewModel) async {
    for _ in 0..<5_000 {
        if viewModel.convertedLogoPayload != nil {
            return
        }

        await Task.yield()
        await drainMainQueue()
    }
}

private final class FakeESP32Browser: ESP32Browsing {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
    var startCallCount = 0
    var cancelCallCount = 0

    func start(queue: DispatchQueue) {
        startCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeTCPConnection: TCPConnection {
    typealias ReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var cancelCallCount = 0
    var receiveCallCount = 0
    var sendCallCount = 0
    var lastReceiveCompletion: ReceiveCompletion?
    var lastSendCompletion: ((NWError?) -> Void)?
    var sentContents: [Data?] = []

    func start(queue: DispatchQueue) {}

    func cancel() {
        cancelCallCount += 1
    }

    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    ) {
        sendCallCount += 1
        sentContents.append(content)

        guard case let .contentProcessed(sendCompletion) = completion else {
            return
        }

        lastSendCompletion = sendCompletion
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping ReceiveCompletion
    ) {
        receiveCallCount += 1
        lastReceiveCompletion = completion
    }
}
