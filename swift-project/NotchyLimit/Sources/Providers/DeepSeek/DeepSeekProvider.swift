import Foundation

// MARK: - Credential

/// DeepSeek API key credential. Stored in Keychain — never in logs.
public struct DeepSeekCredential: Codable, Hashable {
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

/// DeepSeek balance endpoint. `GET /user/balance` returns the remaining credit
/// balance per currency. DeepSeek exposes no spend-vs-limit %, so Notchy shows
/// the remaining balance as a tile. Auth is `Authorization: Bearer sk-…`.
enum DeepSeekEndpoint {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Accept":        "application/json"
        ]
    }
}

// MARK: - DTO + Mapper

struct DeepSeekBalanceDTO: Decodable {
    struct Info: Decodable {
        let currency: String?
        let totalBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance    = "total_balance"
            case grantedBalance  = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
        let grantedBalance: String?
        let toppedUpBalance: String?
    }
    let isAvailable: Bool?
    let balanceInfos: [Info]?

    enum CodingKeys: String, CodingKey {
        case isAvailable  = "is_available"
        case balanceInfos = "balance_infos"
    }
}

enum DeepSeekUsageMapper {
    static func snapshot(_ dto: DeepSeekBalanceDTO, capturedAt: Date = Date()) -> ServiceUsageSnapshot {
        let info = dto.balanceInfos?.first
        let amount = info?.totalBalance ?? "0"
        let symbol: String
        switch info?.currency?.uppercased() {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        case let other?: symbol = "\(other) "
        default:    symbol = "$"
        }

        // Total is the headline. When DeepSeek splits it into free "granted"
        // credits vs. "topped-up" (paid) credits, surface that — it's the
        // difference between burning trial credit and your own money.
        var label = "\(symbol)\(amount)"
        let granted = num(info?.grantedBalance)
        let paid    = num(info?.toppedUpBalance)
        if granted > 0 && paid > 0 {
            label += " (\(symbol)\(fmt(granted)) free + \(symbol)\(fmt(paid)) paid)"
        } else if granted > 0 {
            label += " (\(symbol)\(fmt(granted)) free)"
        } else if paid > 0 {
            label += " (\(symbol)\(fmt(paid)) paid)"
        }

        return .balance(providerId: .deepseek, label: label, amount: num(info?.totalBalance), amountKind: .remaining, capturedAt: capturedAt)
    }

    private static func num(_ s: String?) -> Double { s.flatMap { Double($0) } ?? 0 }
    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}

// MARK: - Provider

/// DeepSeek provider. Surfaces the remaining credit balance (no usage %).
final class DeepSeekProvider: UsageProvider {
    let id: ProviderId = .deepseek
    let displayName: String = "DeepSeek"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateCredentials() async throws {
        _ = try await fetchBalance()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        let dto = try await fetchBalance()
        return DeepSeekUsageMapper.snapshot(dto)
    }

    private func fetchBalance() async throws -> DeepSeekBalanceDTO {
        let data = try await get(url: DeepSeekEndpoint.balanceURL)
        do {
            return try JSONDecoder().decode(DeepSeekBalanceDTO.self, from: data)
        } catch {
            throw ProviderError.decoding("balance parse: \(error.localizedDescription)")
        }
    }

    private func get(url: URL) async throws -> Data {
        let apiKey = try currentAPIKey()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (k, v) in DeepSeekEndpoint.headers(apiKey: apiKey) {
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
        guard let cred: DeepSeekCredential = AuthService.shared.loadCredential(for: .deepseek),
              !cred.apiKey.isEmpty else {
            throw ProviderError.missingCredentials
        }
        return cred.apiKey
    }
}
