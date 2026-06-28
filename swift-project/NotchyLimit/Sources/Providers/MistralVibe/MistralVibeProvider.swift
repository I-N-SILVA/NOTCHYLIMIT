import Foundation

// MARK: - Local Vibe credential

/// Reads the Mistral Vibe CLI key from the same local setup Vibe uses.
///
/// Vibe stores `MISTRAL_API_KEY` in `~/.vibe/.env` after `vibe --setup`.
/// This is intentionally not stored again in Notchy's Keychain; Notchy only
/// detects and validates the local Vibe configuration.
struct MistralVibeCredential {
    let apiKey: String

    static func isAvailable() -> Bool {
        readFromDisk() != nil
    }

    static func readFromDisk() -> MistralVibeCredential? {
        guard let env = try? String(contentsOf: envPath(), encoding: .utf8),
              let key = parseEnvValue(named: "MISTRAL_API_KEY", from: env),
              !key.isEmpty
        else {
            return nil
        }
        return MistralVibeCredential(apiKey: key)
    }

    private static func envPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/.env")
    }

    private static func parseEnvValue(named name: String, from env: String) -> String? {
        for rawLine in env.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let prefix = "\(name)="
            guard line.hasPrefix(prefix) else { continue }
            var value = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}

// MARK: - Endpoint

enum MistralVibeEndpoint {
    static let modelsURL = URL(string: "https://api.mistral.ai/v1/models")!

    static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Accept":        "application/json"
        ]
    }
}

// MARK: - Provider

/// Mistral Vibe provider — connected-status only.
///
/// Vibe currently does not expose a stable local quota or usage endpoint that
/// Notchy can safely consume. We validate the local Vibe key against Mistral's
/// models endpoint and show a healthy Connected state when it works.
final class MistralVibeProvider: UsageProvider {
    let id: ProviderId = .mistralVibe
    let displayName: String = "Mistral Vibe"
    let requiresCookie: Bool = false
    let isAvailable: Bool = true

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateCredentials() async throws {
        try await probeKey()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        try await probeKey()
        return .connected(providerId: .mistralVibe)
    }

    private func probeKey() async throws {
        let apiKey = try currentAPIKey()
        var request = URLRequest(
            url: MistralVibeEndpoint.modelsURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        for (k, v) in MistralVibeEndpoint.headers(apiKey: apiKey) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unknown("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403:  throw ProviderError.unauthorized
        case 429:       throw ProviderError.rateLimited
        case 500...:    throw ProviderError.server(http.statusCode)
        default:        throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }

    private func currentAPIKey() throws -> String {
        guard let cred = MistralVibeCredential.readFromDisk(),
              !cred.apiKey.isEmpty else {
            throw ProviderError.missingCredentials
        }
        return cred.apiKey
    }
}
