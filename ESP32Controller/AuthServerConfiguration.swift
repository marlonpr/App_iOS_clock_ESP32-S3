#if LOGIN_ENABLED
import Foundation

enum AuthServerConfigurationError: Error, Equatable {
    case missingDefaultURL
    case invalidURL
}

struct AuthServerConfiguration: Equatable {
    let baseURL: URL

    var displayHostAndPort: String {
        guard let host = baseURL.host else {
            return baseURL.absoluteString
        }

        if let port = baseURL.port {
            return "\(host):\(port)"
        }

        return host
    }

    static func normalizedBaseURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw AuthServerConfigurationError.invalidURL
        }

        if trimmed.contains(":\(host):") {
            throw AuthServerConfigurationError.invalidURL
        }

        if let port = components.port, !(1...65535).contains(port) {
            throw AuthServerConfigurationError.invalidURL
        }

        components.scheme = scheme
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }

        guard let url = components.url else {
            throw AuthServerConfigurationError.invalidURL
        }
        return url
    }
}

final class AuthServerConfigurationStore {
    static let defaultInfoPlistKey = "AUTH_API_BASE_URL"
    static let defaultUserDefaultsKey = "ESP32Controller.Authentication.ServerBaseURL"

    private let userDefaults: UserDefaults
    private let userDefaultsKey: String
    private let defaultBaseURL: URL
    private var configuredBaseURL: URL

    init(
        defaultBaseURL: URL,
        userDefaults: UserDefaults = .standard,
        userDefaultsKey: String = AuthServerConfigurationStore.defaultUserDefaultsKey
    ) {
        self.defaultBaseURL = defaultBaseURL
        self.userDefaults = userDefaults
        self.userDefaultsKey = userDefaultsKey

        if
            let saved = userDefaults.string(forKey: userDefaultsKey),
            let savedURL = try? AuthServerConfiguration.normalizedBaseURL(from: saved)
        {
            self.configuredBaseURL = savedURL
        } else {
            self.configuredBaseURL = defaultBaseURL
            userDefaults.removeObject(forKey: userDefaultsKey)
        }
    }

    convenience init(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        userDefaultsKey: String = AuthServerConfigurationStore.defaultUserDefaultsKey
    ) throws {
        guard
            let rawDefaultURL = bundle.object(forInfoDictionaryKey: Self.defaultInfoPlistKey) as? String
        else {
            throw AuthServerConfigurationError.missingDefaultURL
        }

        let defaultBaseURL = try AuthServerConfiguration.normalizedBaseURL(from: rawDefaultURL)
        self.init(
            defaultBaseURL: defaultBaseURL,
            userDefaults: userDefaults,
            userDefaultsKey: userDefaultsKey
        )
    }

    var configuration: AuthServerConfiguration {
        AuthServerConfiguration(baseURL: configuredBaseURL)
    }

    var baseURL: URL {
        configuredBaseURL
    }

    var baseURLString: String {
        configuredBaseURL.absoluteString
    }

    func updateBaseURL(from value: String) throws {
        let url = try AuthServerConfiguration.normalizedBaseURL(from: value)
        configuredBaseURL = url
        userDefaults.set(url.absoluteString, forKey: userDefaultsKey)
    }
}
#endif
