import Foundation

/// Process-wide registry of available providers.
public final class ProviderRegistry {
    public static let shared = ProviderRegistry()
    private init() {}

    private var providers: [ProviderId: UsageProvider] = [:]

    public func bootstrap() {
        register(ClaudeProvider())
        register(CodexProvider())
        register(OpenAIProvider())
        register(OpenRouterProvider())
        register(GeminiProvider())
        register(MistralVibeProvider())
        register(PerplexityProvider())
        register(DeepSeekProvider())
        register(ElevenLabsProvider())
    }

    public func register(_ provider: UsageProvider) {
        providers[provider.id] = provider
    }

    public func provider(for id: ProviderId) -> UsageProvider? {
        providers[id]
    }

    public func availableProviders() -> [UsageProvider] {
        ProviderId.allCases.compactMap { providers[$0] }.filter { $0.isAvailable }
    }
}
