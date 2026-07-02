#if LOGIN_ENABLED
import Foundation

protocol URLSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessioning {}

enum AuthenticationAPIError: Error, Equatable {
    case unauthorized
    case rateLimited
    case serverUnavailable
    case serverError(statusCode: Int)
    case malformedResponse
}

struct LoginRequest: Encodable, Equatable {
    let username: String
    let password: String
}

struct APIAuthenticatedUser: Decodable, Equatable {
    let id: Int
    let username: String
    let displayName: String
    let role: String
}

struct LoginResponse: Decodable, Equatable {
    let token: String
    let expiresAt: Date
    let user: APIAuthenticatedUser
}

struct SessionResponse: Decodable, Equatable {
    let expiresAt: Date
    let user: APIAuthenticatedUser
}

private struct HealthResponse: Decodable {
    let status: String
}

private struct StatusResponse: Decodable {
    let status: String
}

struct AuthenticationAPIClient {
    private let session: URLSessioning
    private let timeout: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        session: URLSessioning,
        timeout: TimeInterval = 10
    ) {
        self.session = session
        self.timeout = timeout
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder.authServerDecoder()
    }

    func health(baseURL: URL) async throws {
        let request = makeRequest(baseURL: baseURL, path: "api/health", method: "GET")
        let response: HealthResponse = try await perform(request)
        guard response.status == "ok" else {
            throw AuthenticationAPIError.malformedResponse
        }
    }

    func login(
        baseURL: URL,
        username: String,
        password: String
    ) async throws -> LoginResponse {
        var request = makeRequest(baseURL: baseURL, path: "api/login", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(LoginRequest(username: username, password: password))
        return try await perform(request)
    }

    func session(baseURL: URL, token: String) async throws -> SessionResponse {
        var request = makeRequest(baseURL: baseURL, path: "api/session", method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    func logout(baseURL: URL, token: String) async throws {
        var request = makeRequest(baseURL: baseURL, path: "api/logout", method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response: StatusResponse = try await perform(request)
        guard response.status == "ok" else {
            throw AuthenticationAPIError.malformedResponse
        }
    }

    private func makeRequest(baseURL: URL, path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthenticationAPIError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationAPIError.malformedResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw AuthenticationAPIError.malformedResponse
            }
        case 401:
            throw AuthenticationAPIError.unauthorized
        case 429:
            throw AuthenticationAPIError.rateLimited
        case 500..<600:
            throw AuthenticationAPIError.serverError(statusCode: httpResponse.statusCode)
        default:
            throw AuthenticationAPIError.serverError(statusCode: httpResponse.statusCode)
        }
    }
}

private extension JSONDecoder {
    static func authServerDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = ISO8601DateFormatter.authServerWithFractionalSeconds.date(from: value) {
                return date
            }

            if let date = ISO8601DateFormatter.authServer.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date."
            )
        }
        return decoder
    }
}

private extension ISO8601DateFormatter {
    static let authServer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let authServerWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
