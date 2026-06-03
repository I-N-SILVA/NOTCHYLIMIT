import Foundation

/// Provider-credential storage. Backed by macOS Keychain.
public final class AuthService {
    public static let shared = AuthService()
    private init() {}

    private let store = KeychainStore(service: "com.notchylimit.NotchyLimit")

    // MARK: - Generic

    public func hasCredential(for providerId: ProviderId) -> Bool {
        store.get(account: providerId.rawValue) != nil
    }

    /// Returns true if any credential exists OR a CLI OAuth token is on disk.
    public func hasAnyConfiguredProvider() -> Bool {
        if ProviderId.allCases.contains(where: { cliOAuthAvailable(for: $0) }) { return true }
        return ProviderId.allCases.contains { hasCredential(for: $0) }
    }

    /// True when a provider can authenticate from a token another tool already
    /// wrote to disk (no key to paste): Claude (`~/.claude` / Keychain), Codex
    /// (`~/.codex`), Gemini (`~/.gemini` or Antigravity), Perplexity (the macOS
    /// app's cache).
    public func cliOAuthAvailable(for providerId: ProviderId) -> Bool {
        switch providerId {
        case .claude:     return ClaudeOAuthCredential.isAvailable()
        case .codex:      return CodexOAuthCredential.isAvailable()
        case .gemini:     return GeminiOAuthCredential.isAvailable() || GeminiAntigravityCredential.isAvailable()
        case .perplexity: return PerplexityAppCredential.isAvailable()
        default:          return false
        }
    }

    /// Providers Notchy can light up with zero typing because a token is already
    /// on this machine. Powers the onboarding "Scan my machine" button.
    /// (GitHub Copilot is intentionally excluded — a `gh` token usually lacks
    /// the billing/Plan scope, so it needs a purpose-made PAT.)
    public func detectInstalledProviders() -> [ProviderId] {
        ProviderId.allCases.filter { cliOAuthAvailable(for: $0) }
    }

    public func clearCredential(for providerId: ProviderId) {
        store.delete(account: providerId.rawValue)
    }

    // MARK: - Claude

    /// Returns true if Claude can authenticate without requiring the user to paste a cookie.
    /// This is the case when Claude CLI credentials are present on disk.
    public var claudeHasOAuthAvailable: Bool {
        ClaudeOAuthCredential.isAvailable()
    }

    /// Sanitizes, validates, then stores the Claude session cookie.
    /// Returns a user-facing error string if validation fails, nil on success.
    @discardableResult
    public func saveClaudeCredential(_ credential: ClaudeCredential) -> String? {
        let trimmed = credential.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Cookie cannot be empty." }
        guard trimmed.count >= 32 else {
            return "Cookie looks too short. Paste the full Cookie header from DevTools."
        }
        guard trimmed.count <= 65_536 else {
            return "That doesn't look right — it's too long. Copy only the Cookie header value."
        }
        let sanitized = ClaudeCredential(
            cookie: trimmed,
            storedAt: credential.storedAt,
            lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.claude.rawValue, data: data)
        return nil
    }

    // MARK: - OpenAI

    /// Validates and stores an OpenAI API key.
    /// Returns a user-facing error string on failure, nil on success.
    @discardableResult
    public func saveOpenAICredential(_ credential: OpenAICredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.hasPrefix("sk-") else {
            return "OpenAI API keys start with 'sk-'. Check that you copied the right value."
        }
        guard trimmed.count >= 20 else {
            return "API key looks too short."
        }
        let sanitized = OpenAICredential(
            apiKey: trimmed,
            storedAt: credential.storedAt,
            lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.openai.rawValue, data: data)
        return nil
    }

    // MARK: - Gemini

    /// Validates and stores a Google Gemini API key.
    /// Returns a user-facing error string on failure, nil on success.
    @discardableResult
    public func saveGeminiCredential(_ credential: GeminiCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.hasPrefix("AIza") else {
            return "Gemini API keys start with 'AIza'. Grab one from Google AI Studio."
        }
        guard trimmed.count >= 30 else {
            return "API key looks too short."
        }
        let sanitized = GeminiCredential(
            apiKey: trimmed,
            storedAt: credential.storedAt,
            lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.gemini.rawValue, data: data)
        return nil
    }

    // MARK: - Perplexity

    /// Validates and stores a Perplexity API key.
    /// Returns a user-facing error string on failure, nil on success.
    @discardableResult
    public func savePerplexityCredential(_ credential: PerplexityCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.hasPrefix("pplx-") else {
            return "Perplexity API keys start with 'pplx-'. Find it at perplexity.ai → Settings → API."
        }
        guard trimmed.count >= 20 else {
            return "API key looks too short."
        }
        let sanitized = PerplexityCredential(
            apiKey: trimmed,
            storedAt: credential.storedAt,
            lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.perplexity.rawValue, data: data)
        return nil
    }

    // MARK: - OpenRouter

    @discardableResult
    public func saveOpenRouterCredential(_ credential: OpenRouterCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.hasPrefix("sk-or-") else {
            return "OpenRouter keys start with 'sk-or-'. Find it at openrouter.ai → Keys."
        }
        guard trimmed.count >= 20 else { return "API key looks too short." }
        let sanitized = OpenRouterCredential(
            apiKey: trimmed, storedAt: credential.storedAt, lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.openrouter.rawValue, data: data)
        return nil
    }

    // MARK: - DeepSeek

    @discardableResult
    public func saveDeepSeekCredential(_ credential: DeepSeekCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.hasPrefix("sk-") else {
            return "DeepSeek keys start with 'sk-'. Find it at platform.deepseek.com → API keys."
        }
        guard trimmed.count >= 20 else { return "API key looks too short." }
        let sanitized = DeepSeekCredential(
            apiKey: trimmed, storedAt: credential.storedAt, lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.deepseek.rawValue, data: data)
        return nil
    }

    // MARK: - ElevenLabs

    @discardableResult
    public func saveElevenLabsCredential(_ credential: ElevenLabsCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "API key cannot be empty." }
        guard trimmed.count >= 20 else {
            return "API key looks too short. Copy the full key from elevenlabs.io → Profile."
        }
        let sanitized = ElevenLabsCredential(
            apiKey: trimmed, storedAt: credential.storedAt, lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.elevenlabs.rawValue, data: data)
        return nil
    }

    // MARK: - GitHub Copilot

    @discardableResult
    public func saveCopilotCredential(_ credential: CopilotCredential) -> String? {
        let trimmed = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Token cannot be empty." }
        let prefixes = ["ghp_", "github_pat_", "gho_", "ghu_", "ghs_"]
        guard prefixes.contains(where: { trimmed.hasPrefix($0) }) else {
            return "That doesn't look like a GitHub token. Create one at github.com → Settings → Developer settings → Personal access tokens, with the Plan (read-only) permission."
        }
        guard trimmed.count >= 20 else { return "Token looks too short." }
        let sanitized = CopilotCredential(
            apiKey: trimmed, storedAt: credential.storedAt, lastValidatedAt: credential.lastValidatedAt
        )
        guard let data = try? JSONEncoder().encode(sanitized) else {
            return "Failed to encode credential."
        }
        store.set(account: ProviderId.copilot.rawValue, data: data)
        return nil
    }

    // MARK: - Generic load

    /// Generic load. Returns the decoded credential of type `T` if present.
    public func loadCredential<T: Decodable>(for providerId: ProviderId) -> T? {
        guard let data = store.get(account: providerId.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
