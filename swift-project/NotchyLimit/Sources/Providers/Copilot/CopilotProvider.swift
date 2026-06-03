import Foundation

// MARK: - Credential

/// GitHub Copilot credential — a GitHub personal access token (classic `ghp_…`
/// or fine-grained `github_pat_…`) with the **Plan** (read-only) permission, so
/// Notchy can read your personal Copilot billing usage. Stored in Keychain.
public struct CopilotCredential: Codable, Hashable {
    public var apiKey: String          // a GitHub PAT, reusing the generic field name
    public var storedAt: Date
    public var lastValidatedAt: Date?
    public init(apiKey: String, storedAt: Date = Date(), lastValidatedAt: Date? = nil) {
        self.apiKey = apiKey
        self.storedAt = storedAt
        self.lastValidatedAt = lastValidatedAt
    }
}

// MARK: - Endpoint

/// GitHub billing endpoints. GitHub moved Copilot to usage-based "AI credits"
/// billing on 2026-06-01, so the universally-readable signal is **spend this
/// period** from the enhanced billing usage report (the per-plan included
/// allowance isn't exposed to the API). We sum the Copilot line items.
enum CopilotEndpoint {
    static let apiVersion = "2026-03-10"
    static let userURL = URL(string: "https://api.github.com/user")!

    static func usageURL(login: String) -> URL {
        URL(string: "https://api.github.com/users/\(login)/settings/billing/usage")!
    }

    static func headers(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": apiVersion,
            "User-Agent": "NotchyLimit"
        ]
    }
}

// MARK: - DTOs

private struct GitHubUserDTO: Decodable { let login: String }

private struct BillingUsageDTO: Decodable {
    struct Item: Decodable {
        let product: String?
        let sku: String?
        let quantity: Double?
        let netAmount: Double?
        enum CodingKeys: String, CodingKey {
            case product, sku, quantity
            case netAmount = "netAmount"
        }
    }
    let usageItems: [Item]?
}

// MARK: - Provider

/// GitHub Copilot provider. Shows your Copilot **spend this billing period**
/// (USD) from the GitHub billing usage API. Authenticated-but-no-usage (e.g. a
/// license billed through an org, so nothing lands on your personal account)
/// degrades to a Connected status rather than a misleading $0.
final class CopilotProvider: UsageProvider {
    let id: ProviderId = .copilot
    let displayName: String = "GitHub Copilot"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func validateCredentials() async throws {
        _ = try await login()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        let login = try await login()
        let data = try await get(CopilotEndpoint.usageURL(login: login))
        guard let dto = try? JSONDecoder().decode(BillingUsageDTO.self, from: data),
              let items = dto.usageItems else {
            return .connected(providerId: .copilot)
        }
        // Sum the Copilot line items' net (post-discount) USD amount.
        let copilotItems = items.filter { ($0.product ?? "").lowercased().contains("copilot") }
        guard !copilotItems.isEmpty else {
            // Authenticated, but no Copilot usage on this personal account.
            return .connected(providerId: .copilot)
        }
        let spend = copilotItems.reduce(0.0) { $0 + ($1.netAmount ?? 0) }
        let label = String(format: "$%.2f used", spend)
        return .balance(providerId: .copilot, label: label, amount: spend, amountKind: .spend)
    }

    // MARK: - HTTP

    private func login() async throws -> String {
        let data = try await get(CopilotEndpoint.userURL)
        guard let dto = try? JSONDecoder().decode(GitHubUserDTO.self, from: data) else {
            throw ProviderError.decoding("github /user parse")
        }
        return dto.login
    }

    private func get(_ url: URL) async throws -> Data {
        let token = try currentToken()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (k, v) in CopilotEndpoint.headers(token: token) { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unknown("non-HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw ProviderError.unauthorized
        case 404:       throw ProviderError.unauthorized   // token lacks Plan scope / no billing access
        case 429:       throw ProviderError.rateLimited
        case 500...:    throw ProviderError.server(http.statusCode)
        default:        throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }

    private func currentToken() throws -> String {
        guard let cred: CopilotCredential = AuthService.shared.loadCredential(for: .copilot),
              !cred.apiKey.isEmpty else {
            throw ProviderError.missingCredentials
        }
        return cred.apiKey
    }
}
