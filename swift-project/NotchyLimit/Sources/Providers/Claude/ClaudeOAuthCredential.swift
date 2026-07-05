import Foundation
import Security

/// Reads Claude OAuth credentials, preferring the Claude CLI / Claude Code login.
///
/// Two sources, in order:
///   1. `~/.claude/credentials.json` (older Claude CLI file format)
///   2. macOS Keychain item `Claude Code-credentials` (current Claude Code) —
///      a JSON blob with `claudeAiOauth.accessToken` + top-level `organizationUuid`.
///
/// Using this scoped, auto-refreshed OAuth token avoids the full browser session
/// cookie. When the org id is known (Keychain case) the provider can skip the
/// bootstrap round-trip entirely.
struct ClaudeOAuthCredential {
    let accessToken: String
    let expiresAt: Date?
    let orgId: String?

    var isLikelyExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp < Date().addingTimeInterval(30)
    }

    // MARK: - Reading

    static func readFromDisk() -> ClaudeOAuthCredential? {
        if let data = fileData(), let cred = parse(from: data) { return cred }
        if let data = keychainData(), let cred = parse(from: data) { return cred }
        return nil
    }

    /// Returns true only when Notchy can actually read and parse a usable OAuth
    /// credential. A Keychain item that exists but is not readable by this app
    /// should not be shown as "detected" in onboarding.
    static func isAvailable() -> Bool {
        guard let cred = readFromDisk() else { return false }
        return !cred.isLikelyExpired
    }

    static func hasExpiredCredential() -> Bool {
        guard let cred = readFromDisk() else { return false }
        return cred.isLikelyExpired
    }

    // MARK: - Parsing

    static func parse(from data: Data) -> ClaudeOAuthCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Claude Code Keychain shape: { "claudeAiOauth": {...}, "organizationUuid": "..." }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        let token = (oauth["accessToken"] as? String)
                 ?? (json["claudeAiOauthToken"] as? String)
                 ?? (json["accessToken"] as? String)
                 ?? (json["oauth_token"] as? String)
                 ?? (json["token"] as? String)
        guard let token, !token.isEmpty else { return nil }

        let org = (json["organizationUuid"] as? String)
               ?? (oauth["organizationUuid"] as? String)
        return ClaudeOAuthCredential(
            accessToken: token,
            expiresAt: parseExpiry(from: oauth) ?? parseExpiry(from: json),
            orgId: (org.flatMap { UUID(uuidString: $0) != nil ? $0 : nil })
        )
    }

    static func parseExpiry(from json: [String: Any]) -> Date? {
        if let ms = json["expiresAt"] as? TimeInterval {
            return ms > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ms / 1000)
                : Date(timeIntervalSince1970: ms)
        }
        if let str = json["expiresAt"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        }
        return nil
    }

    // MARK: - Sources

    private static func filePath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/credentials.json")
    }

    private static func fileData() -> Data? {
        try? Data(contentsOf: filePath())
    }

    private static let keychainService = "Claude Code-credentials"

    /// Decrypts the Keychain blob (may prompt for access on first read).
    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: "Notchy wants to read your Claude Code OAuth token from Keychain."
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}
