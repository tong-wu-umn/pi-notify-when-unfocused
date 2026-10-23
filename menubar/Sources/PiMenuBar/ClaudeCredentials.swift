import Foundation
import PiMenuBarCore
import Security

/// Reads the OAuth access token Claude Code keeps in the login keychain.
///
/// The item is a generic password written by the CLI: service `Claude Code-credentials`,
/// value `{"claudeAiOauth":{"accessToken":"…","expiresAt":<ms epoch>,…}}`. Only the access
/// token and its expiry are read; the refresh token is never touched, because it is
/// single-use and consuming it could log the CLI out.
enum ClaudeCredential {
    struct Value: Equatable {
        let token: String
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    enum Failure: Equatable, Error {
        case notFound
        case malformed
        case unreadable(OSStatus)
    }

    static func load() -> Result<Value, Failure> {
        // The account attribute is deliberately left unset: a renamed local account still
        // resolves, and the CLI only writes one item for this service.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .failure(.notFound) }
        guard status == errSecSuccess else { return .failure(.unreadable(status)) }
        guard let data = item as? Data else { return .failure(.malformed) }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return .failure(.malformed) }

        var expiresAt: Date?
        if let millis = number(oauth["expiresAt"]) {
            expiresAt = Date(millis: Int64(millis))
        }
        return .success(Value(token: token, expiresAt: expiresAt))
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }
}
