import SwiftUI

@MainActor
struct ESP32ControllerRootView: View {
    @StateObject private var viewModel: ESP32ControllerViewModel
    @Environment(\.scenePhase) private var scenePhase

#if LOGIN_ENABLED
    @StateObject private var authenticationSession: AuthenticationSession
    @State private var didStartSessionRestore = false

    init() {
        _viewModel = StateObject(wrappedValue: ESP32ControllerViewModel())
        _authenticationSession = StateObject(wrappedValue: Self.makeProductionAuthenticationSession())
    }

    init(viewModel: ESP32ControllerViewModel, authenticationSession: AuthenticationSession) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _authenticationSession = StateObject(wrappedValue: authenticationSession)
    }
#else
    init() {
        _viewModel = StateObject(wrappedValue: ESP32ControllerViewModel())
    }

    init(viewModel: ESP32ControllerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
#endif

    var body: some View {
        rootContent
            .onAppear {
                applyInitialAuthorizationState()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
#if LOGIN_ENABLED
            .onChange(of: authenticationSession.isAuthenticated) { _, isAuthenticated in
                handleAuthenticationChange(isAuthenticated: isAuthenticated)
            }
#endif
    }

    @ViewBuilder
    private var rootContent: some View {
#if LOGIN_ENABLED
        if authenticationSession.isAuthenticated {
            ContentView(
                viewModel: viewModel,
                authenticationDiagnostics: authenticationSession.diagnostics
            ) {
                logOut()
            }
        } else {
            LoginView(session: authenticationSession)
        }
#else
        ContentView(viewModel: viewModel)
#endif
    }

    private func applyInitialAuthorizationState() {
#if LOGIN_ENABLED
        if authenticationSession.isAuthenticated {
            authorizeNetworkingForCurrentScene()
        } else {
            viewModel.revokeNetworkingAuthorization()
            guard !didStartSessionRestore else {
                return
            }

            didStartSessionRestore = true
            Task {
                await authenticationSession.restoreStoredSession()
            }
        }
#else
        authorizeNetworkingForCurrentScene()
#endif
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
#if LOGIN_ENABLED
        guard authenticationSession.isAuthenticated else {
            return
        }
#endif

        switch newPhase {
        case .active:
            viewModel.handleAppBecameActive()
        case .inactive:
            viewModel.handleAppBecameInactive()
        case .background:
            viewModel.handleAppEnteredBackground()
        @unknown default:
            viewModel.handleAppBecameInactive()
        }
    }

    private func authorizeNetworkingForCurrentScene() {
        viewModel.authorizeNetworking()
        if scenePhase == .active {
            viewModel.handleAppBecameActive()
        }
    }

#if LOGIN_ENABLED
    private func handleAuthenticationChange(isAuthenticated: Bool) {
        if isAuthenticated {
            authorizeNetworkingForCurrentScene()
        } else {
            viewModel.revokeNetworkingAuthorization()
        }
    }

    private func logOut() {
        viewModel.revokeNetworkingAuthorization()
        Task {
            await authenticationSession.logOut()
        }
    }

    private static func makeProductionAuthenticationSession() -> AuthenticationSession {
        do {
            let configurationStore = try AuthServerConfigurationStore()
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSessionConfiguration.timeoutIntervalForRequest = 10
            urlSessionConfiguration.timeoutIntervalForResource = 15
            let urlSession = URLSession(configuration: urlSessionConfiguration)
            let service = DatabaseAuthenticationService(
                urlSession: urlSession,
                configurationStore: configurationStore
            )
            return AuthenticationSession(authenticationService: service)
        } catch {
            preconditionFailure("Missing or invalid authentication server configuration.")
        }
    }
#endif
}
