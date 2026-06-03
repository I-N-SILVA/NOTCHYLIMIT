import SwiftUI
import AppKit

/// Loads the bundled brand logo (`brand-<id>.png`) for a provider.
///
/// Logos are sourced from the open-source lobehub icon set, rasterized to
/// transparent PNGs at build time. Colored marks (Claude, Gemini, Perplexity,
/// DeepSeek) keep their brand colors; monochrome marks (OpenAI, Codex,
/// ElevenLabs, OpenRouter) are baked white so they read on Notchy's dark UI.
extension ProviderId {
    /// Brand accent color, used to tint each provider's bar/glow so the UI's
    /// color language matches the logos. Monochrome marks get a recognizable
    /// brand-adjacent hue.
    var brandColor: Color {
        switch self {
        case .claude:     return Color(red: 0.85, green: 0.46, blue: 0.34) // peach
        case .codex:      return Color(red: 0.60, green: 0.85, blue: 0.80) // soft teal
        case .openai:     return Color(red: 0.06, green: 0.64, blue: 0.52) // OpenAI green
        case .openrouter: return Color(red: 0.45, green: 0.52, blue: 0.98) // indigo
        case .gemini:     return Color(red: 0.25, green: 0.55, blue: 1.00) // Google blue
        case .perplexity: return Color(red: 0.20, green: 0.72, blue: 0.78) // teal
        case .deepseek:   return Color(red: 0.30, green: 0.42, blue: 1.00) // DeepSeek blue
        case .elevenlabs: return Color(red: 0.80, green: 0.80, blue: 0.85) // light grey
        case .copilot:    return Color(red: 0.55, green: 0.78, blue: 0.62) // soft green
        }
    }
}

enum BrandIcon {
    private static var cache: [ProviderId: NSImage] = [:]

    static func image(for id: ProviderId) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let url = Bundle.main.url(forResource: "brand-\(id.rawValue)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[id] = image
        return image
    }
}

/// A provider's logo, falling back to its SF Symbol when the brand asset is
/// missing (e.g. an old build without bundled logos). Drop-in replacement for
/// `Image(systemName: id.iconSymbol)`.
struct ProviderIconView: View {
    let id: ProviderId
    var size: CGFloat = 16
    /// Tint applied only to the SF Symbol fallback; brand PNGs render as-is.
    var fallbackColor: Color? = nil

    var body: some View {
        if let ns = BrandIcon.image(for: id) {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            let symbol = Image(systemName: id.iconSymbol).font(.system(size: size * 0.9))
            if let c = fallbackColor { symbol.foregroundColor(c) } else { symbol }
        }
    }
}
