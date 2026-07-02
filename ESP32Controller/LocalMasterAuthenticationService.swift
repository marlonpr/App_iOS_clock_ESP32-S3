#if LOGIN_ENABLED
import CryptoKit
import Foundation

struct LocalMasterAuthenticationService: AuthenticationService {
    private struct StoredCredential {
        let username: String
        let salt: String
        let passwordHashHex: String
    }

    private static let productionCredential = StoredCredential(
        username: "[MASTER_USERNAME]",
        salt: "ESP32Controller.LocalMasterAuthentication.v1",
        passwordHashHex: "2f37c6f0911da9aaa654a8555508c185291b521b1e87524746e7dbefb31d53d8"
    )

    private let credential: StoredCredential

    var providerName: String {
        "Local"
    }

    init() {
        self.credential = Self.productionCredential
    }

    init(username: String, salt: String, passwordHashHex: String) {
        self.credential = StoredCredential(
            username: username,
            salt: salt,
            passwordHashHex: passwordHashHex
        )
    }

    func authenticate(username: String, password: String) async throws -> AuthenticatedUser {
        let normalizedUsername = Self.normalizedUsername(username)
        guard normalizedUsername == credential.username else {
            throw AuthenticationFailure.invalidCredentials
        }

        let attemptedHash = Self.passwordHashHex(salt: credential.salt, password: password)
        guard Self.constantTimeEqual(attemptedHash, credential.passwordHashHex) else {
            throw AuthenticationFailure.invalidCredentials
        }

        return AuthenticatedUser(
            id: "local-master",
            username: credential.username,
            displayName: "Master",
            role: .master
        )
    }

    static func normalizedUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func passwordHashHex(salt: String, password: String) -> String {
        let bytes = Data("\(salt):\(password)".utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }

        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}
#endif
