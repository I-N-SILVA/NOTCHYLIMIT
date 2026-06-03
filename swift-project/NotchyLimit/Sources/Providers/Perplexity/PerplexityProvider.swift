import Foundation

// MARK: - API-key credential (Keychain) — connected-only fallback

/// Perplexity API key credential. Stored in Keychain — never in logs.
///
/// The public Perplexity API (`api.perplexity.ai`) is OpenAI-compatible but
/// exposes no usage/billing read endpoint, so the API-key path can only verify
/// the key works and surface a "Connected" status. The richer path is the
/// desktop-app token (see `PerplexityAppCredential`).
public struct PerplexityCredential: Codable, Hashable {
    public var apiKey: String
    public var storedAt: Date
    public var lastValidatedAt: Date?

    public init(apiKey: String, storedAt: Date = Date(), lastValidatedAt: Date? = nil) {
        self.apiKey = apiKey
        self.storedAt = storedAt
        self.lastValidatedAt = lastValidatedAt
    }
}

// MARK: - Desktop-app credential — real usage

/// Reads the short-lived bearer token the **Perplexity macOS app** caches when
/// it calls its own backend. There is no public usage API, but the app's web
/// endpoints (`perplexity.ai/rest/...`) return real rate-limit + spend data, and
/// the same token authenticates them.
///
/// The token lives inside the app's URL cache (a SQLite DB), embedded in the
/// cached `/api/user` request's `Authorization` header. It expires roughly
/// hourly, so it's only fresh when the app has been used recently — the provider
/// gates on a live `/api/user` check before trusting any numbers and otherwise
/// falls back to the connected-only status. This mirrors how openusage and
/// similar menu-bar tools read Perplexity.
struct PerplexityAppCredential {
    let bearer: String

    /// Known cache DB locations across app variants (sandboxed `.mac`, `.macv3`).
    private static func cacheDBPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let containers = ["ai.perplexity.mac", "ai.perplexity.macv3"]
        return containers.map {
            home.appendingPathComponent("Library/Containers/\($0)/Data/Library/Caches/\($0)/Cache.db").path
        }
    }

    static func isAvailable() -> Bool {
        cacheDBPaths().contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Pulls the bearer from the cached `/api/user` request blob.
    static func readFromDisk() -> PerplexityAppCredential? {
        for path in cacheDBPaths() {
            // Join the response (which holds the request URL) to its blob (which
            // holds the serialized request, including the Authorization header).
            let sql = """
            SELECT b.request_object
            FROM cfurl_cache_response r
            JOIN cfurl_cache_blob_data b ON r.entry_ID = b.entry_ID
            WHERE r.request_key LIKE '%perplexity.ai/api/user%'
            """
            guard let rows = SQLiteReader.query(path, sql) else { continue }
            for row in rows {
                guard let blob = row.first as? Data,
                      let token = parseBearer(from: blob) else { continue }
                return PerplexityAppCredential(bearer: token)
            }
        }
        return nil
    }

    /// The request blob is a binary plist/archive; the bearer is plain ASCII
    /// inside it, so a scoped scan for `Bearer <token>` is enough.
    static func parseBearer(from blob: Data) -> String? {
        guard let text = String(data: blob, encoding: .isoLatin1) else { return nil }
        guard let range = text.range(of: "Bearer ") else { return nil }
        let after = text[range.upperBound...]
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let token = String(after.prefix { allowed.contains($0) })
        return token.count >= 20 ? token : nil
    }
}

// MARK: - Endpoints

enum PerplexityEndpoint {
    // API-key validation path.
    static let chatCompletionsURL = URL(string: "https://api.perplexity.ai/chat/completions")!
    static func apiKeyHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Accept": "application/json", "Content-Type": "application/json"]
    }
    /// Authenticates without producing a billable completion.
    static let validationBody: Data = {
        let payload: [String: Any] = ["model": "sonar", "messages": []]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }()

    // Desktop-app (real usage) path.
    static let userURL = URL(string: "https://www.perplexity.ai/api/user")!
    static let rateLimitURL = URL(string: "https://www.perplexity.ai/rest/rate-limit/all")!
    static let groupsURL = URL(string: "https://www.perplexity.ai/rest/pplx-api/v2/groups")!
    static func usageAnalyticsURL(groupId: String) -> URL {
        URL(string: "https://www.perplexity.ai/rest/pplx-api/v2/groups/\(groupId)/usage-analytics")!
    }
    static func appHeaders(bearer: String) -> [String: String] {
        [
            "Authorization": "Bearer \(bearer)",
            "Accept": "application/json",
            "X-Client-Name": "Perplexity-Mac",
            "X-App-ApiVersion": "2.17"
        ]
    }
}

// MARK: - Provider

/// Perplexity provider.
///
/// Resolution order on every fetch:
///   1. Desktop-app token (real usage) — only when a live `/api/user` check
///      confirms the cached token is still fresh. Shows API spend ($ used vs
///      balance) when the account has API credits, otherwise the consumer
///      rate-limit remaining counts (Queries / Deep Research / Labs / Agentic).
///   2. API key (`pplx-…`) — connected-only "Active".
final class PerplexityProvider: UsageProvider {
    let id: ProviderId = .perplexity
    let displayName: String = "Perplexity"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func validateCredentials() async throws {
        // Valid if either the desktop app is signed in or an API key works.
        if PerplexityAppCredential.isAvailable() { return }
        try await probeAPIKey()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        if let snapshot = try await fetchAppUsage() { return snapshot }
        // Fallback: API key → connected-only.
        try await probeAPIKey()
        return .connected(providerId: .perplexity)
    }

    // MARK: - Desktop-app usage

    /// Returns a real-usage snapshot, or nil if the app token is absent/stale
    /// (caller then falls back to the API-key path).
    private func fetchAppUsage() async throws -> ServiceUsageSnapshot? {
        guard let cred = PerplexityAppCredential.readFromDisk() else { return nil }

        // Freshness gate: the cache token expires ~hourly. A 200 here means the
        // numbers we read next are trustworthy; a 401 means the app hasn't been
        // used recently, so we bail to "Active" rather than show stale zeros.
        let userJSON: Any?
        switch await getJSON(PerplexityEndpoint.userURL, bearer: cred.bearer) {
        case .ok(let json): userJSON = json
        case .unauthorized, .failed: return nil
        }

        let tier = subscriptionTier(from: userJSON)

        // Tier A: API spend ($ used vs balance) → a real percentage bar.
        if let spend = try await fetchSpend(bearer: cred.bearer) {
            let pct = spend.limit > 0 ? max(0, min(1.2, spend.used / spend.limit)) : 0
            let label = "\(money(spend.used)) of \(money(spend.limit))" + (tier.map { " · \($0)" } ?? "")
            let window = UsageWindow(
                type: .monthly,
                percentUsed: pct,
                usedAmount: spend.used,
                limitAmount: spend.limit,
                lastUpdated: Date(),
                label: label,
                amountKind: .spend
            )
            return ServiceUsageSnapshot(providerId: .perplexity, primaryWindow: window, capturedAt: Date())
        }

        // Tier B: consumer rate-limit remaining counts → a label.
        if let label = try await fetchRateLimitLabel(bearer: cred.bearer, tier: tier) {
            return .balance(providerId: .perplexity, label: label)
        }

        // Authenticated but nothing useful to show.
        return .connected(providerId: .perplexity)
    }

    // MARK: API spend (Tier A)

    private struct Spend { let used: Double; let limit: Double }

    private func fetchSpend(bearer: String) async throws -> Spend? {
        guard case .ok(let groupsJSON) = await getJSON(PerplexityEndpoint.groupsURL, bearer: bearer) else { return nil }
        guard let groupId = firstString(in: groupsJSON, keys: ["api_org_id", "apiOrgId", "org_id", "orgId", "group_id", "groupId", "id"]),
              let balance = firstNumber(in: groupsJSON, keys: ["balance_usd", "balanceUsd", "balance"]),
              balance > 0 else { return nil }

        guard case .ok(let usageJSON) = await getJSON(PerplexityEndpoint.usageAnalyticsURL(groupId: groupId), bearer: bearer) else { return nil }
        let used = sumNumbers(in: usageJSON, key: "cost")
        return Spend(used: used, limit: balance)
    }

    // MARK: Rate limits (Tier B)

    private func fetchRateLimitLabel(bearer: String, tier: String?) async throws -> String? {
        guard case .ok(let json) = await getJSON(PerplexityEndpoint.rateLimitURL, bearer: bearer),
              let dict = json as? [String: Any] else { return nil }

        var parts: [String] = []
        if let t = tier { parts.append(t) }
        func add(_ label: String, _ key: String) {
            if let n = (dict[key] as? Int) ?? (dict[key] as? Double).map(Int.init) {
                parts.append("\(label) \(n)")
            }
        }
        add("Queries", "remaining_pro")
        add("Research", "remaining_research")
        add("Labs", "remaining_labs")
        add("Agentic", "remaining_agentic_research")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Parsing helpers

    private func subscriptionTier(from json: Any?) -> String? {
        if let s = firstString(in: json, keys: ["subscription_tier", "subscriptionTier"]) {
            if s.lowercased() == "max" { return "Max" }
            if s.lowercased() == "pro" { return "Pro" }
        }
        if firstBool(in: json, keys: ["is_max", "isMax"]) == true { return "Max" }
        if firstBool(in: json, keys: ["is_pro", "isPro"]) == true { return "Pro" }
        return nil
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    /// Depth-first search for the first string value under any of `keys`.
    private func firstString(in value: Any?, keys: [String]) -> String? {
        if let dict = value as? [String: Any] {
            for k in keys { if let s = dict[k] as? String, !s.isEmpty { return s } }
            for v in dict.values { if let f = firstString(in: v, keys: keys) { return f } }
        } else if let arr = value as? [Any] {
            for v in arr { if let f = firstString(in: v, keys: keys) { return f } }
        }
        return nil
    }

    private func firstNumber(in value: Any?, keys: [String]) -> Double? {
        if let dict = value as? [String: Any] {
            for k in keys {
                if let d = dict[k] as? Double { return d }
                if let i = dict[k] as? Int { return Double(i) }
                if let s = dict[k] as? String, let d = Double(s) { return d }
            }
            for v in dict.values { if let f = firstNumber(in: v, keys: keys) { return f } }
        } else if let arr = value as? [Any] {
            for v in arr { if let f = firstNumber(in: v, keys: keys) { return f } }
        }
        return nil
    }

    private func firstBool(in value: Any?, keys: [String]) -> Bool? {
        if let dict = value as? [String: Any] {
            for k in keys { if let b = dict[k] as? Bool { return b } }
            for v in dict.values { if let f = firstBool(in: v, keys: keys) { return f } }
        } else if let arr = value as? [Any] {
            for v in arr { if let f = firstBool(in: v, keys: keys) { return f } }
        }
        return nil
    }

    /// Sums every numeric `key` found anywhere in the tree (meter costs).
    private func sumNumbers(in value: Any?, key: String) -> Double {
        var total = 0.0
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                if k == key {
                    if let d = v as? Double { total += d }
                    else if let i = v as? Int { total += Double(i) }
                } else { total += sumNumbers(in: v, key: key) }
            }
        } else if let arr = value as? [Any] {
            for v in arr { total += sumNumbers(in: v, key: key) }
        }
        return total
    }

    // MARK: - HTTP

    private enum JSONResult { case ok(Any?); case unauthorized; case failed }

    private func getJSON(_ url: URL, bearer: String) async -> JSONResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (k, v) in PerplexityEndpoint.appHeaders(bearer: bearer) { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200..<300: return .ok(try? JSONSerialization.jsonObject(with: data))
        case 401, 403:  return .unauthorized
        default:        return .failed
        }
    }

    // MARK: - API-key probe (fallback)

    private func probeAPIKey() async throws {
        guard let cred: PerplexityCredential = AuthService.shared.loadCredential(for: .perplexity),
              !cred.apiKey.isEmpty else {
            throw ProviderError.missingCredentials
        }
        var request = URLRequest(url: PerplexityEndpoint.chatCompletionsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        for (k, v) in PerplexityEndpoint.apiKeyHeaders(apiKey: cred.apiKey) { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = PerplexityEndpoint.validationBody

        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unknown("non-HTTP response") }
        switch http.statusCode {
        case 401, 403: throw ProviderError.unauthorized
        case 429:      throw ProviderError.rateLimited
        case 500...:   throw ProviderError.server(http.statusCode)
        default:       return   // 200/400/422 — key authenticated
        }
    }
}
