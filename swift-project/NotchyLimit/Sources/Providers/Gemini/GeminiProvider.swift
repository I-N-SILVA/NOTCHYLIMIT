import Foundation

// MARK: - API-key credential (Keychain) — connected-only fallback

/// Google Gemini API key credential (AI Studio). Stored in Keychain.
/// Google's API key exposes no usage endpoint, so this path is connected-only.
/// The richer path is Code Assist OAuth (see `GeminiOAuthCredential`).
public struct GeminiCredential: Codable, Hashable {
    public var apiKey: String
    public var storedAt: Date
    public var lastValidatedAt: Date?
    public init(apiKey: String, storedAt: Date = Date(), lastValidatedAt: Date? = nil) {
        self.apiKey = apiKey
        self.storedAt = storedAt
        self.lastValidatedAt = lastValidatedAt
    }
}

// MARK: - OAuth credential (Gemini CLI / Code Assist) — real quota

/// Reads Gemini CLI OAuth credentials (`gemini` login → Code Assist).
/// This unlocks real per-model quota via cloudcode-pa, the closest Gemini has
/// to Claude's session/weekly windows. File: `~/.gemini/oauth_creds.json`.
struct GeminiOAuthCredential {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiryDateMs: Double?

    private static var credsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
    }
    private static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }

    /// Available when creds exist and the CLI isn't in api-key / vertex-ai mode.
    static func isAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: credsPath.path) else { return false }
        return supportedAuthType()
    }

    /// Lenient auth-type check across the few shapes the CLI has used.
    static func supportedAuthType() -> Bool {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true   // no settings → assume default oauth-personal
        }
        let raw = (json["authType"] as? String)
            ?? (json["selectedAuthType"] as? String)
            ?? ((json["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
        guard let raw = raw?.lowercased() else { return true }
        return !(raw.contains("api-key") || raw.contains("vertex"))
    }

    static func readFromDisk() -> GeminiOAuthCredential? {
        guard let data = try? Data(contentsOf: credsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        return GeminiOAuthCredential(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            idToken: json["id_token"] as? String,
            expiryDateMs: (json["expiry_date"] as? Double) ?? (json["expiry_date"] as? NSNumber)?.doubleValue
        )
    }

    var isLikelyExpired: Bool {
        guard let ms = expiryDateMs else { return false }
        let seconds = ms > 10_000_000_000 ? ms / 1000 : ms
        return Date(timeIntervalSince1970: seconds) < Date().addingTimeInterval(60)
    }

    func writeBack(accessToken newAccess: String, expiresIn: Double?) {
        guard let data = try? Data(contentsOf: GeminiOAuthCredential.credsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["access_token"] = newAccess
        if let expiresIn { json["expiry_date"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000 }
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: GeminiOAuthCredential.credsPath, options: .atomic)
        }
    }
}

// MARK: - Antigravity credential (successor to Gemini CLI Code Assist)

/// Reads the Google OAuth access token that **Antigravity** (Google's successor
/// to Gemini CLI / Code Assist) stores in its VS Code-style state database.
///
/// Google is sunsetting Gemini CLI / Code Assist for individuals on 2026-06-18;
/// Antigravity is the replacement and keeps using the same `cloudcode-pa` quota
/// surface. This lets Notchy keep showing Gemini quota after that date when the
/// user has moved to Antigravity.
///
/// Caveat: the stored token is a short-lived `ya29.` access token with no
/// refresh token exposed on disk (the app refreshes it internally), so it's only
/// usable while Antigravity has been running recently. The provider treats a
/// rejection as "fall back" rather than an error, so a stale token never
/// regresses the UI.
struct GeminiAntigravityCredential {
    static func stateDBPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb").path
    }

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: stateDBPath())
    }

    /// Returns the `ya29.` access token from `antigravityAuthStatus`, or nil.
    static func readAccessToken() -> String? {
        guard let rows = SQLiteReader.query(stateDBPath(),
              "SELECT value FROM ItemTable WHERE key = 'antigravityAuthStatus'"),
              let first = rows.first?.first else { return nil }
        let data: Data?
        if let s = first as? String { data = s.data(using: .utf8) }
        else if let d = first as? Data { data = d }
        else { data = nil }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["apiKey"] as? String, token.hasPrefix("ya29.") else { return nil }
        return token
    }
}

// MARK: - Endpoints

enum GeminiEndpoint {
    // API-key path (connected-only validation).
    static func modelsURL(apiKey: String) -> URL {
        var c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return c.url!
    }
    // Code Assist (OAuth) path.
    static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let retrieveUserQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// The Gemini CLI's OAuth client id/secret are needed only to refresh an
    /// expired token. They're public values the CLI ships with, but rather than
    /// hardcode them we read them from the installed CLI at runtime (and survive
    /// any future rotation). Returns nil if the CLI isn't found — in which case
    /// we skip refresh and use the on-disk access token as-is.
    static func clientCreds() -> (id: String, secret: String)? {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var roots = [
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules",
            "\(home)/.npm-global/lib/node_modules"
        ]
        for vroot in ["\(home)/.nvm/versions/node", "\(home)/.volta/tools/image/node"] {
            if let kids = try? fm.contentsOfDirectory(atPath: vroot) {
                roots += kids.map { "\(vroot)/\($0)/lib/node_modules" }
            }
        }
        let rels = [
            "@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        ]
        for base in roots {
            for rel in rels {
                guard let text = try? String(contentsOfFile: "\(base)/\(rel)", encoding: .utf8),
                      let creds = parseClientCreds(text) else { continue }
                return creds
            }
        }
        return nil
    }

    static func parseClientCreds(_ text: String) -> (id: String, secret: String)? {
        func capture(_ key: String) -> String? {
            let pattern = "\(key)\\s*=\\s*['\"]([^'\"]+)['\"]"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        guard let id = capture("OAUTH_CLIENT_ID"), let secret = capture("OAUTH_CLIENT_SECRET") else { return nil }
        return (id, secret)
    }
}

// MARK: - Provider

/// Gemini provider. Since the 2026-06-18 Code Assist sunset, it prefers the
/// Antigravity token (real per-model quota via cloudcode-pa), then falls back to
/// legacy Gemini CLI Code Assist, then to a connected-only API-key status.
final class GeminiProvider: UsageProvider {
    let id: ProviderId = .gemini
    let displayName: String = "Gemini"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func validateCredentials() async throws {
        _ = try await fetchUsage()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        // 1) Antigravity — the PRIMARY source since Google retired Gemini CLI /
        //    Code Assist for individuals on 2026-06-18. Reuses the same
        //    cloudcode-pa flow with the token Antigravity stores; no refresh
        //    token on disk, so a stale token just falls through rather than erroring.
        if let token = GeminiAntigravityCredential.readAccessToken() {
            let cred = GeminiOAuthCredential(accessToken: token, refreshToken: nil, idToken: nil, expiryDateMs: nil)
            do { return try await fetchCodeAssistUsage(cred) }
            catch ProviderError.unauthorized { /* stale Antigravity token — try legacy Code Assist next */ }
        }
        // 2) Legacy Gemini CLI / Code Assist — kept as a fallback for users who
        //    still have working credentials on disk after the sunset.
        if GeminiOAuthCredential.isAvailable(), let cred = GeminiOAuthCredential.readFromDisk() {
            do { return try await fetchCodeAssistUsage(cred) }
            catch ProviderError.unauthorized { /* token dead — fall through */ }
        }
        // 3) API-key fallback → connected-only.
        if let apiCred: GeminiCredential = AuthService.shared.loadCredential(for: .gemini), !apiCred.apiKey.isEmpty {
            try await validateAPIKey(apiCred.apiKey)
            return .connected(providerId: .gemini)
        }
        throw ProviderError.missingCredentials
    }

    // MARK: - Code Assist (OAuth) usage

    private func fetchCodeAssistUsage(_ credential: GeminiOAuthCredential) async throws -> ServiceUsageSnapshot {
        var cred = credential
        if cred.isLikelyExpired, let token = try await refresh(cred) { cred.accessToken = token }

        // 1) loadCodeAssist → discover the project (needed by retrieveUserQuota).
        let loadBody: [String: Any] = ["metadata": [
            "ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI", "duetProject": "default"
        ]]
        let loadData = try await postJSON(GeminiEndpoint.loadCodeAssistURL, body: loadBody, cred: &cred, allow401Refresh: true)
        let project = firstString(in: try? JSONSerialization.jsonObject(with: loadData), key: "cloudaicompanionProject")

        // 2) retrieveUserQuota → buckets with remainingFraction.
        let quotaBody: [String: Any] = project.map { ["project": $0] } ?? [:]
        let quotaData = try await postJSON(GeminiEndpoint.retrieveUserQuotaURL, body: quotaBody, cred: &cred, allow401Refresh: true)
        guard let quotaJSON = try? JSONSerialization.jsonObject(with: quotaData) else {
            return .connected(providerId: .gemini)
        }

        var buckets: [(model: String, remaining: Double, reset: Date?)] = []
        collectBuckets(quotaJSON, into: &buckets)
        guard let binding = buckets.min(by: { $0.remaining < $1.remaining }) else {
            return .connected(providerId: .gemini)   // authenticated, but no quota buckets
        }

        let window = UsageWindow(
            type: .daily,
            percentUsed: max(0, min(1, 1 - binding.remaining)),
            resetAt: binding.reset,
            lastUpdated: Date(),
            label: binding.model
        )
        return ServiceUsageSnapshot(providerId: .gemini, primaryWindow: window, capturedAt: Date())
    }

    /// Recursively gathers every object exposing a numeric `remainingFraction`.
    private func collectBuckets(_ value: Any, into out: inout [(model: String, remaining: Double, reset: Date?)]) {
        if let arr = value as? [Any] {
            for v in arr { collectBuckets(v, into: &out) }
            return
        }
        guard let dict = value as? [String: Any] else { return }
        if let frac = (dict["remainingFraction"] as? Double) ?? (dict["remainingFraction"] as? NSNumber)?.doubleValue {
            let model = (dict["modelId"] as? String) ?? (dict["model_id"] as? String) ?? "Gemini"
            let reset = parseReset(dict["resetTime"] ?? dict["reset_time"])
            out.append((model: model, remaining: frac, reset: reset))
        }
        for v in dict.values { collectBuckets(v, into: &out) }
    }

    private func parseReset(_ value: Any?) -> Date? {
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        if let n = (value as? Double) ?? (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        return nil
    }

    private func firstString(in value: Any?, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
            for v in dict.values { if let f = firstString(in: v, key: key) { return f } }
        } else if let arr = value as? [Any] {
            for v in arr { if let f = firstString(in: v, key: key) { return f } }
        }
        return nil
    }

    // MARK: - HTTP helpers

    private func postJSON(_ url: URL, body: [String: Any], cred: inout GeminiOAuthCredential, allow401Refresh: Bool) async throws -> Data {
        func attempt(_ token: String) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch { throw ProviderError.transport(error.localizedDescription) }
            guard let http = response as? HTTPURLResponse else { throw ProviderError.unknown("non-HTTP response") }
            return (data, http)
        }

        var (data, http) = try await attempt(cred.accessToken)
        if (http.statusCode == 401 || http.statusCode == 403), allow401Refresh, let token = try await refresh(cred) {
            cred.accessToken = token
            (data, http) = try await attempt(token)
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw ProviderError.unauthorized
        case 429:       throw ProviderError.rateLimited
        case 500...:    throw ProviderError.server(http.statusCode)
        default:        throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }

    private func refresh(_ cred: GeminiOAuthCredential) async throws -> String? {
        // Refresh needs the gemini-cli's OAuth client creds (read from the
        // installed CLI). Without them, use the on-disk token as-is.
        guard let refreshToken = cred.refreshToken,
              let client = GeminiEndpoint.clientCreds() else { return nil }
        var request = URLRequest(url: GeminiEndpoint.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(client.id)&client_secret=\(client.secret)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty else { return nil }
        cred.writeBack(accessToken: newAccess, expiresIn: json["expires_in"] as? Double)
        return newAccess
    }

    private func validateAPIKey(_ key: String) async throws {
        var request = URLRequest(url: GeminiEndpoint.modelsURL(apiKey: key), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response): (Data, URLResponse)
        do { (_, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unknown("non-HTTP response") }
        switch http.statusCode {
        case 200..<300: return
        case 400, 401, 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited
        case 500...: throw ProviderError.server(http.statusCode)
        default: throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }
}
