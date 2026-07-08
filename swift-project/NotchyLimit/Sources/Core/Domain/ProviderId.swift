import Foundation

/// Stable, machine-readable identifier for a usage provider.
/// Used for keychain keys, settings storage, and analytics-free debug logs.
public enum ProviderId: String, Codable, Hashable, CaseIterable {
    case claude
    case codex       // OpenAI Codex / ChatGPT plan — real session (5h) + weekly (7d)
    case openai      // OpenAI API (billing-based usage monitoring)
    case openrouter  // OpenRouter — credits used vs. credits purchased (%)
    case gemini      // Google Gemini — Code Assist quota (%) or connected-only
    case perplexity  // Perplexity — real usage via desktop-app token, else connected-only
    case deepseek    // DeepSeek — remaining credit balance (no %)
    case elevenlabs  // ElevenLabs — character usage vs. monthly limit (%)
    case copilot     // GitHub Copilot — scaffolded, usage endpoint not yet wired (#23)
    case cursor      // Cursor — scaffolded, usage endpoint not yet wired (#23)

    public var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .openai:      return "OpenAI"
        case .openrouter:  return "OpenRouter"
        case .gemini:      return "Gemini"
        case .perplexity:  return "Perplexity"
        case .deepseek:    return "DeepSeek"
        case .elevenlabs:  return "ElevenLabs"
        case .copilot:     return "GitHub Copilot"
        case .cursor:      return "Cursor"
        }
    }

    public var iconSymbol: String {
        switch self {
        case .claude:      return "sparkle"
        case .codex:       return "chevron.left.forwardslash.chevron.right"
        case .openai:      return "circle.hexagongrid"
        case .openrouter:  return "arrow.triangle.branch"
        case .gemini:      return "sparkles"   // NOTE: "star.four.pointed" is not a valid SF Symbol on macOS 12–15, so it rendered blank (issue #11)
        case .perplexity:  return "magnifyingglass.circle"
        case .deepseek:    return "water.waves"
        case .elevenlabs:  return "waveform"
        case .copilot:     return "chevron.left.forwardslash.chevron.right"
        case .cursor:      return "cursorarrow.rays"
        }
    }

    /// True if the provider is implemented and selectable in onboarding.
    /// Copilot / Cursor are scaffolded but disabled until their (undocumented)
    /// usage endpoints are reverse-engineered and verified against a live account.
    public var isAvailable: Bool {
        switch self {
        case .claude, .codex, .openai, .openrouter, .gemini, .perplexity, .deepseek, .elevenlabs:
            return true
        case .copilot, .cursor:
            return false
        }
    }

    /// True if the provider reports a real usage/quota percentage. When false,
    /// the provider shows either a credit balance or just connectivity, and the
    /// UI shows that instead of a percentage.
    public var reportsQuota: Bool {
        switch self {
        case .claude, .codex, .openai, .openrouter, .gemini, .elevenlabs, .copilot, .cursor:  return true
        case .perplexity, .deepseek:                                                           return false
        }
    }

    /// True for providers authenticated via a CLI-written OAuth token file on
    /// disk (no key to paste) — detected automatically in onboarding.
    public var usesCLIOAuth: Bool {
        switch self {
        case .claude, .codex, .gemini: return true
        default: return false
        }
    }

    /// statuspage.io-backed status page, used for outage badges. Nil for
    /// providers whose status page isn't a statuspage.io instance (or unknown).
    public var statusPageBaseURL: URL? {
        switch self {
        case .claude:      return URL(string: "https://status.anthropic.com")
        case .codex, .openai: return URL(string: "https://status.openai.com")
        case .perplexity:  return URL(string: "https://status.perplexity.com")
        case .elevenlabs:  return URL(string: "https://status.elevenlabs.io")
        case .copilot:     return URL(string: "https://www.githubstatus.com")
        case .cursor:      return URL(string: "https://status.cursor.com")
        case .openrouter, .gemini, .deepseek:
            return nil   // no known statuspage.io instance
        }
    }

    /// The provider's real usage/account page, opened via click-through so the
    /// pill is the start of the workflow, not a dead end (#19). Nil if unknown.
    public var dashboardURL: URL? {
        switch self {
        case .claude:      return URL(string: "https://claude.ai/settings/usage")
        case .codex:       return URL(string: "https://chatgpt.com")
        case .openai:      return URL(string: "https://platform.openai.com/usage")
        case .openrouter:  return URL(string: "https://openrouter.ai/credits")
        case .gemini:      return URL(string: "https://aistudio.google.com")
        case .perplexity:  return URL(string: "https://www.perplexity.ai/settings/api")
        case .deepseek:    return URL(string: "https://platform.deepseek.com/usage")
        case .elevenlabs:  return URL(string: "https://elevenlabs.io/app/usage")
        case .copilot:     return URL(string: "https://github.com/settings/copilot")
        case .cursor:      return URL(string: "https://www.cursor.com/settings")
        }
    }
}
