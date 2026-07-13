import Foundation

// MARK: - Credential (OAuth file, like Claude — no Keychain)

/// Reads OpenAI Codex CLI OAuth credentials, written by `codex login`.
/// This is the ChatGPT-plan token (Plus/Pro/Team), so its usage mirrors the
/// 5-hour + weekly windows Codex enforces — the OpenAI analog of Claude's
/// session/weekly. Same low-blast-radius approach as `ClaudeOAuthCredential`.
struct CodexOAuthCredential {
    var accessToken: String
    var refreshToken: String?
    var accountId: String?
    /// The file these came from, so a refresh can be written back in place.
    let path: URL

    static func isAvailable() -> Bool {
        credentialPath() != nil
    }

    /// First existing auth.json across the known Codex locations.
    static func credentialPath() -> URL? {
        var candidates: [URL] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
        }
        let h = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(h.appendingPathComponent(".config/codex/auth.json"))
        candidates.append(h.appendingPathComponent(".codex/auth.json"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func readFromDisk() -> CodexOAuthCredential? {
        guard let path = credentialPath(),
              let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tokens = json["tokens"] as? [String: Any] ?? json
        guard let access = (tokens["access_token"] as? String) ?? (json["access_token"] as? String),
              !access.isEmpty else { return nil }

        let refresh = (tokens["refresh_token"] as? String) ?? (json["refresh_token"] as? String)
        let account = (tokens["account_id"] as? String) ?? (json["account_id"] as? String)
        return CodexOAuthCredential(accessToken: access, refreshToken: refresh, accountId: account, path: path)
    }

    /// Persists refreshed tokens back into the same file, preserving other keys.
    func writeBack(accessToken newAccess: String, refreshToken newRefresh: String?) {
        guard let data = try? Data(contentsOf: path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var tokens = json["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = newAccess
        if let newRefresh { tokens["refresh_token"] = newRefresh }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: path, options: .atomic)
        }
    }
}

// MARK: - Endpoint

enum CodexEndpoint {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public Codex CLI OAuth client id (same value the CLI ships with).
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func usageHeaders(token: String, accountId: String?) -> [String: String] {
        var h = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if let accountId, !accountId.isEmpty { h["ChatGPT-Account-Id"] = accountId }
        return h
    }
}

// MARK: - DTO + Mapper

private struct CodexUsageDTO: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let resetAt: TimeInterval?
        let limitWindowSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

// MARK: - Provider

/// OpenAI Codex provider — real session (5h) + weekly (7d) usage from the
/// ChatGPT plan, via the Codex CLI OAuth token. Requires `codex login`.
final class CodexProvider: UsageProvider {
    let id: ProviderId = .codex
    let displayName: String = "Codex"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func validateCredentials() async throws {
        _ = try await fetchRaw()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        let dto = try await fetchRaw()
        guard let rl = dto.rateLimit else {
            // Authenticated but no windows yet — show "connected" rather than fail.
            return .connected(providerId: .codex)
        }
        let primary = window(rl.primaryWindow, fallbackType: .session)
        let secondary = window(rl.secondaryWindow, fallbackType: .weekly)
        guard let primary else { return .connected(providerId: .codex) }
        return ServiceUsageSnapshot(
            providerId: .codex,
            primaryWindow: primary,
            secondaryWindow: secondary,
            capturedAt: Date()
        )
    }

    private func window(_ w: CodexUsageDTO.Window?, fallbackType: UsageWindowType) -> UsageWindow? {
        guard let w, let pct = w.usedPercent else { return nil }
        // 18000s (5h) → session, 604800s (7d) → weekly, else the fallback.
        let type: UsageWindowType
        switch w.limitWindowSeconds {
        case .some(let s) where s <= 21_600: type = .session
        case .some(let s) where s >= 86_400: type = .weekly
        default: type = fallbackType
        }
        return UsageWindow(
            type: type,
            percentUsed: pct / 100.0,
            resetAt: w.resetAt.map { Date(timeIntervalSince1970: $0) },
            lastUpdated: Date()
        )
    }

    // MARK: - HTTP + refresh

    private func fetchRaw() async throws -> CodexUsageDTO {
        guard var cred = CodexOAuthCredential.readFromDisk() else {
            throw ProviderError.missingCredentials
        }
        do {
            return try await getUsage(cred)
        } catch ProviderError.unauthorized {
            // Access token likely expired — refresh once and retry.
            guard let refreshed = try await refresh(cred) else { throw ProviderError.unauthorized }
            cred.accessToken = refreshed
            return try await getUsage(cred)
        }
    }

    private func getUsage(_ cred: CodexOAuthCredential) async throws -> CodexUsageDTO {
        var request = URLRequest(url: CodexEndpoint.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (k, v) in CodexEndpoint.usageHeaders(token: cred.accessToken, accountId: cred.accountId) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unknown("non-HTTP response") }
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(CodexUsageDTO.self, from: data) }
            catch { throw ProviderError.decoding("wham/usage parse: \(error.localizedDescription)") }
        case 401, 403: throw ProviderError.unauthorized
        case 429:      throw ProviderError.rateLimited
        case 500...:   throw ProviderError.server(http.statusCode)
        default:       throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }

    /// Refreshes the access token and writes it back to auth.json. Returns the
    /// new access token, or nil if refresh isn't possible.
    private func refresh(_ cred: CodexOAuthCredential) async throws -> String? {
        guard let refreshToken = cred.refreshToken else { return nil }
        var request = URLRequest(url: CodexEndpoint.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&client_id=\(CodexEndpoint.clientID)&refresh_token=\(refreshToken.formURLEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { return nil }

        let newRefresh = json["refresh_token"] as? String
        cred.writeBack(accessToken: newAccess, refreshToken: newRefresh)
        return newAccess
    }
}
