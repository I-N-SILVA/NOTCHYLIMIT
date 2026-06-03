import Foundation

// MARK: - Credential

/// OpenRouter API key credential. Stored in Keychain — never in logs.
public struct OpenRouterCredential: Codable, Hashable {
    public var apiKey: String
    public var storedAt: Date
    public var lastValidatedAt: Date?

    public init(apiKey: String, storedAt: Date = Date(), lastValidatedAt: Date? = nil) {
        self.apiKey = apiKey
        self.storedAt = storedAt
        self.lastValidatedAt = lastValidatedAt
    }
}

// MARK: - Endpoint

/// OpenRouter credits endpoint. `GET /api/v1/credits` returns total purchased
/// credits and total usage for the account behind the key — a real, reliable
/// usage percentage. Auth is `Authorization: Bearer sk-or-…`.
enum OpenRouterEndpoint {
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Accept":        "application/json"
        ]
    }
}

// MARK: - DTO + Mapper

struct OpenRouterCreditsDTO: Decodable {
    struct Data: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?

        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage   = "total_usage"
        }
    }
    let data: Data
}

enum OpenRouterUsageMapper {
    static func snapshot(_ dto: OpenRouterCreditsDTO, capturedAt: Date = Date()) -> ServiceUsageSnapshot {
        let credits = dto.data.totalCredits ?? 0
        let usage   = dto.data.totalUsage ?? 0

        // No credits purchased (free tier) → no percentage to chart.
        guard credits > 0 else {
            return .connected(providerId: .openrouter, capturedAt: capturedAt)
        }

        let window = UsageWindow(
            type: .monthly,                 // prepaid credit pool — no calendar reset
            percentUsed: usage / credits,
            usedAmount: usage,
            limitAmount: credits,
            resetAt: nil,
            lastUpdated: capturedAt,
            amountKind: .spend
        )
        return ServiceUsageSnapshot(
            providerId: .openrouter,
            primaryWindow: window,
            capturedAt: capturedAt
        )
    }
}

// MARK: - Provider

/// OpenRouter provider. Shows credits used as a percentage of credits purchased.
final class OpenRouterProvider: UsageProvider {
    let id: ProviderId = .openrouter
    let displayName: String = "OpenRouter"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateCredentials() async throws {
        _ = try await fetchCredits()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        let dto = try await fetchCredits()
        return OpenRouterUsageMapper.snapshot(dto)
    }

    private func fetchCredits() async throws -> OpenRouterCreditsDTO {
        let data = try await get(url: OpenRouterEndpoint.creditsURL)
        do {
            return try JSONDecoder().decode(OpenRouterCreditsDTO.self, from: data)
        } catch {
            throw ProviderError.decoding("credits parse: \(error.localizedDescription)")
        }
    }

    private func get(url: URL) async throws -> Data {
        let apiKey = try currentAPIKey()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (k, v) in OpenRouterEndpoint.headers(apiKey: apiKey) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unknown("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw ProviderError.unauthorized
        case 429:       throw ProviderError.rateLimited
        case 500...:    throw ProviderError.server(http.statusCode)
        default:        throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }

    private func currentAPIKey() throws -> String {
        guard let cred: OpenRouterCredential = AuthService.shared.loadCredential(for: .openrouter),
              !cred.apiKey.isEmpty else {
            throw ProviderError.missingCredentials
        }
        return cred.apiKey
    }
}
