enum ESP32ControllerBuildConfiguration {
#if LOGIN_ENABLED
    static let isLoginEnabled = true
    static let authorizesNetworkingAtLaunch = false
#else
    static let isLoginEnabled = false
    static let authorizesNetworkingAtLaunch = true
#endif
}
