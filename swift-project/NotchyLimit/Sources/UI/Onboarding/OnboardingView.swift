import SwiftUI
import AppKit

/// Multi-step onboarding.
///
/// Flow adapts based on what's available:
///   - Claude CLI credentials detected → skips cookie step, uses OAuth automatically.
///   - User selects OpenAI → asks for API key instead of cookie.
///   - User selects Claude without CLI → asks for session cookie (same as v0.1).
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    private func close() { appState.showOnboarding = false }

    @State private var step: Step = .welcome
    @State private var selectedProvider: ProviderId = .claude
    @State private var credentialInput: String = ""
    @State private var validating: Bool = false
    @State private var validateError: String?

    enum Step: Int, CaseIterable {
        case welcome, provider, credential, validate, notifications
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    RetroMascot(size: 32)
                    Text("Welcome to Notchy")
                        .font(Theme.displayFont)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("Skip") { close() }
                        .buttonStyle(.borderless)
                        .foregroundColor(Theme.textSecondary)
                }
                progressDots
                Group {
                    switch step {
                    case .welcome:       welcomeStep
                    case .provider:      providerStep
                    case .credential:    credentialStep
                    case .validate:      validateStep
                    case .notifications: notificationsStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                navButtons
            }
            .padding(20)
        }
        .onAppear {
            selectedProvider = appState.activeProviderId
        }
    }

    // MARK: - Step views

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Theme.accentWarm : Theme.stroke)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("See your AI limits at a glance.")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("A tiny pill lives in your notch or menu bar. Hover for details. Everything stays on your Mac.")
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.textSecondary)
            }
            pillPreviewCard
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a provider")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        providerRow(p)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderId) -> some View {
        let isSelected = selectedProvider == p
        let hasExpiredClaudeOAuth = p == .claude && ClaudeOAuthCredential.hasExpiredCredential()
        Button {
            if p.isAvailable { selectedProvider = p }
        } label: {
            HStack {
                Image(systemName: p.iconSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.accentWarm : Theme.textSecondary)
                    .frame(width: 22)
                Text(p.displayName)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if usesDetectedOAuth(p) {
                    Text("CLI detected")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.statusHealthy)
                } else if hasExpiredClaudeOAuth {
                    Text("CLI expired")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.statusWarning)
                } else {
                    Text(p.isAvailable ? (isSelected ? "Selected" : "") : "Coming soon")
                        .font(Theme.captionFont)
                        .foregroundColor(p.isAvailable ? Theme.textSecondary : Theme.textSecondary.opacity(0.5))
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.accentWarm)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.surfaceElevated : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Theme.accentWarm.opacity(0.35) : Theme.stroke, lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.borderless)
        .opacity(p.isAvailable ? 1.0 : 0.5)
        .disabled(!p.isAvailable)
    }

    /// True when the provider is authenticated from a CLI-written OAuth file
    /// that's present on disk — no credential entry needed.
    private func usesDetectedOAuth(_ p: ProviderId) -> Bool {
        p.usesCLIOAuth && AuthService.shared.cliOAuthAvailable(for: p)
    }

    /// True when this step shows a key/cookie text field the user must fill.
    private func needsTextInput(_ p: ProviderId) -> Bool {
        if usesDetectedOAuth(p) { return false }
        if p == .claude && ClaudeOAuthCredential.hasExpiredCredential() { return false }
        if p == .codex || p == .mistralVibe { return false }   // login-only, no manual entry
        return true
    }

    @ViewBuilder
    private var credentialStep: some View {
        switch selectedProvider {
        case .claude:
            if usesDetectedOAuth(.claude) { oauthDetectedStep(.claude) }
            else if ClaudeOAuthCredential.hasExpiredCredential() { claudeCLIExpiredStep }
            else { claudeCookieStep }
        case .codex:
            if usesDetectedOAuth(.codex) { oauthDetectedStep(.codex) }
            else { codexLoginStep }
        case .gemini:
            if usesDetectedOAuth(.gemini) { oauthDetectedStep(.gemini) }
            else { geminiKeyStep }
        case .mistralVibe:
            if usesDetectedOAuth(.mistralVibe) { oauthDetectedStep(.mistralVibe) }
            else { mistralVibeSetupStep }
        case .openai:
            openAIKeyStep
        case .openrouter:
            apiKeyStep(
                title: "Paste your OpenRouter API key",
                hint: "Find it at openrouter.ai → Keys.",
                note: "Notchy reads your credits used vs. credits purchased. The key is stored in the macOS Keychain and only ever sent to openrouter.ai.",
                placeholder: "sk-or-..."
            )
        case .perplexity:
            perplexityKeyStep
        case .deepseek:
            apiKeyStep(
                title: "Paste your DeepSeek API key",
                hint: "Find it at platform.deepseek.com → API keys.",
                note: "DeepSeek reports a remaining credit balance (not a usage %), so Notchy shows your balance. The key is stored in the macOS Keychain and only ever sent to api.deepseek.com.",
                placeholder: "sk-..."
            )
        case .elevenlabs:
            apiKeyStep(
                title: "Paste your ElevenLabs API key",
                hint: "Find it at elevenlabs.io → Profile → API key.",
                note: "Notchy reads your monthly character usage vs. your plan limit. The key is stored in the macOS Keychain and only ever sent to api.elevenlabs.io.",
                placeholder: "your-xi-api-key"
            )
        }
    }

    /// Detected-CLI-credential confirmation, shared by Claude / Codex / Gemini.
    @ViewBuilder
    private func oauthDetectedStep(_ p: ProviderId) -> some View {
        let info: (tool: String, path: String, scope: String) = {
            switch p {
            case .codex:  return ("Codex CLI", "~/.codex/auth.json", "Reads your ChatGPT-plan session (5h) + weekly limits")
            case .gemini: return ("Gemini CLI", "~/.gemini/oauth_creds.json", "Reads your Code Assist per-model quota")
            case .mistralVibe: return ("Mistral Vibe CLI", "~/.vibe/.env", "Validates your local Vibe API key")
            default:      return ("Claude CLI", "Claude Code Keychain or ~/.claude/credentials.json", "Scoped OAuth token — not your full session cookie")
            }
        }()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.statusHealthy)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(info.tool) detected")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Notchy will use your existing CLI credentials.")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.statusHealthy.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.statusHealthy.opacity(0.25)))
            )

            VStack(alignment: .leading, spacing: 6) {
                featureRow("shield.fill", info.scope, Theme.statusHealthy)
                featureRow("key.fill", "Token lives in \(info.path)", Theme.textSecondary)
                featureRow("arrow.clockwise", "Auto-refreshed — no action needed", Theme.textSecondary)
            }
        }
    }

    /// Shown when Codex isn't logged in yet — there's no key to paste.
    private var codexLoginStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with the Codex CLI")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Notchy reads your ChatGPT-plan usage (5-hour + weekly windows) from the token the Codex CLI stores locally — no key to paste.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                featureRow("1.circle.fill", "Install: npm i -g @openai/codex", Theme.textSecondary)
                featureRow("2.circle.fill", "Run: codex login (sign in with ChatGPT)", Theme.textSecondary)
                featureRow("3.circle.fill", "Come back and continue", Theme.statusHealthy)
            }
            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    /// Shown when Claude Code credentials exist but their access token has expired.
    private var claudeCLIExpiredStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refresh Claude CLI login")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Notchy found your Claude Code credentials, but the local OAuth token is expired. This is safer than a browser cookie, but Claude Code must refresh it first.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                featureRow("1.circle.fill", "Open Claude Code or Claude Desktop", Theme.textSecondary)
                featureRow("2.circle.fill", "Sign in again if prompted, or start a Claude session once", Theme.textSecondary)
                featureRow("3.circle.fill", "Come back and retry Notchy", Theme.statusHealthy)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.statusWarning)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                Text("Only use the session-cookie fallback if the Claude CLI route still cannot be refreshed.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.statusWarning.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.statusWarning.opacity(0.20)))
            )

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    /// Shown when Mistral Vibe is not configured locally yet.
    private var mistralVibeSetupStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Mistral Vibe CLI")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Notchy reads the Vibe API key from the local Vibe CLI setup. There is no key to paste here.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                featureRow("1.circle.fill", "Install Vibe CLI from mistral.ai/vibe", Theme.textSecondary)
                featureRow("2.circle.fill", "Run: vibe --setup", Theme.textSecondary)
                featureRow("3.circle.fill", "Come back and continue", Theme.statusHealthy)
            }
            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    private var claudeCookieStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your claude.ai session cookie")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)

            // Security disclosure — honest about the tradeoff
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.statusWarning)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                Text("This is a full browser session cookie with complete account access. It stays device-only in the macOS Keychain and is never sent anywhere except directly to claude.ai for usage requests. Install Claude CLI to use a safer, scoped token instead.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.statusWarning.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.statusWarning.opacity(0.20)))
            )

            Text("In claude.ai, open DevTools (⌘⌥I) → Network → find 'usage' request → copy the Cookie header.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            SecureCookieEditor(text: $credentialInput)
                .frame(height: 90)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    private var openAIKeyStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your OpenAI API key")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Find it at platform.openai.com → API keys.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            statusOnlyNote("OpenAI no longer exposes per-key spend to API keys, so Notchy shows a Connected status — not a quota %. The key is stored in the macOS Keychain and only ever sent to api.openai.com.")

            SecureCookieEditor(text: $credentialInput, placeholder: "sk-...")
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    private var geminiKeyStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your Gemini API key")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Get one free at aistudio.google.com → API keys.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            statusOnlyNote("Google's Gemini API exposes no usage endpoint, so Notchy shows a Connected status — not a quota %. The key is stored in the macOS Keychain and only ever sent to Google.")

            SecureCookieEditor(text: $credentialInput, placeholder: "AIza...")
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    private var perplexityKeyStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your Perplexity API key")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Find it at perplexity.ai → Settings → API.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            statusOnlyNote("Perplexity has no usage endpoint, so Notchy shows a Connected status — not a spend %. The key is stored in the macOS Keychain and only ever sent to api.perplexity.ai.")

            SecureCookieEditor(text: $credentialInput, placeholder: "pplx-...")
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    /// Generic API-key entry step for straightforward Bearer/header-key providers.
    @ViewBuilder
    private func apiKeyStep(title: String, hint: String, note: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text(hint)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            statusOnlyNote(note)

            SecureCookieEditor(text: $credentialInput, placeholder: placeholder)
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))

            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    /// Honest disclosure used by providers that can only report connectivity.
    @ViewBuilder
    private func statusOnlyNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(Theme.accentCool)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accentCool.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accentCool.opacity(0.20)))
        )
    }

    private var validateHeadline: String {
        if validating { return "Validating…" }
        if validateError != nil { return "Couldn't validate" }
        return "Credentials validated ✓"
    }

    private var validateStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(validateHeadline)
                .font(.title3.weight(.semibold))
                .foregroundColor(validateError == nil ? Theme.textPrimary : Theme.statusCritical)
            Text("Checking that the credentials can reach \(selectedProvider.displayName)'s usage endpoint.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
            if let err = validateError {
                Text(err).font(Theme.captionFont).foregroundColor(Theme.statusCritical)
            }
        }
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Toggle("Alert me at 25/50/75/90% usage", isOn: $appState.notificationsEnabled)
                .toggleStyle(.switch)
                .foregroundColor(Theme.textPrimary)
            Text("You can change this any time from Settings.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: - Navigation

    private var navButtons: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }.buttonStyle(.bordered)
            }
            Spacer()
            Button(primaryLabel) { goNext() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(nextDisabled)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:        return "Get started"
        case .provider:       return "Continue"
        case .credential:
            if selectedProvider == .claude && ClaudeOAuthCredential.hasExpiredCredential() { return "Retry" }
            return usesDetectedOAuth(selectedProvider) ? "Continue" : "Validate"
        case .validate:       return validating ? "…" : "Continue"
        case .notifications:  return "Finish"
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case .credential:
            return needsTextInput(selectedProvider) && credentialInput.trimmingCharacters(in: .whitespaces).isEmpty
        case .validate:
            return validating
        default:
            return false
        }
    }

    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    private func goNext() {
        switch step {
        case .credential:
            startValidation()
        case .validate:
            if !validating && validateError == nil { step = .notifications }
        case .notifications:
            close()
        default:
            if let next = Step(rawValue: step.rawValue + 1) { step = next }
        }
    }

    private func startValidation() {
        validateError = nil
        validating = true

        // Save credential before validating (only providers with a text field).
        if needsTextInput(selectedProvider) {
            if let saveError = saveCredential() {
                validateError = saveError
                validating = false
                return
            }
        }

        step = .validate

        Task {
            do {
                guard let provider = ProviderRegistry.shared.provider(for: selectedProvider) else {
                    await MainActor.run {
                        validateError = "Provider not available. Restart the app."
                        validating = false
                    }
                    return
                }
                try await provider.validateCredentials()
                let snapshot = try await provider.fetchUsage()
                await MainActor.run {
                    appState.snapshots[selectedProvider] = snapshot
                    if selectedProvider == appState.activeProviderId || appState.latestSnapshot == nil {
                        appState.latestSnapshot = snapshot
                    }
                    appState.authStatus = .valid
                    (NSApp.delegate as? AppDelegate)?.coordinator?.onCredentialsSaved(for: selectedProvider)
                    validating = false
                }
            } catch let err as ProviderError {
                await MainActor.run {
                    validateError = err.description
                    validating = false
                }
            } catch {
                await MainActor.run {
                    validateError = error.localizedDescription
                    validating = false
                }
            }
        }
    }

    private func saveCredential() -> String? {
        let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch selectedProvider {
        case .codex:
            return nil   // CLI OAuth — nothing to save
        case .mistralVibe:
            return nil   // Vibe CLI key — nothing to save
        case .claude:
            return AuthService.shared.saveClaudeCredential(
                ClaudeCredential(cookie: trimmed)
            )
        case .openai:
            return AuthService.shared.saveOpenAICredential(
                OpenAICredential(apiKey: trimmed)
            )
        case .openrouter:
            return AuthService.shared.saveOpenRouterCredential(
                OpenRouterCredential(apiKey: trimmed)
            )
        case .gemini:
            return AuthService.shared.saveGeminiCredential(
                GeminiCredential(apiKey: trimmed)
            )
        case .perplexity:
            return AuthService.shared.savePerplexityCredential(
                PerplexityCredential(apiKey: trimmed)
            )
        case .deepseek:
            return AuthService.shared.saveDeepSeekCredential(
                DeepSeekCredential(apiKey: trimmed)
            )
        case .elevenlabs:
            return AuthService.shared.saveElevenLabsCredential(
                ElevenLabsCredential(apiKey: trimmed)
            )
        }
    }

    // MARK: - Helper sub-views

    @ViewBuilder
    private func featureRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 18)
            Text(text)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var pillPreviewCard: some View {
        VStack(spacing: 8) {
            Text("This will live in your notch or menu bar:")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 130, height: 22)
                        .overlay(
                            Text("camera")
                                .font(.system(size: 7))
                                .foregroundColor(Color.white.opacity(0.15))
                        )
                    OnboardingPillPreview()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Text("Hover to expand. Click to pin.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.stroke))
        )
    }
}

// MARK: - Secure text editor (handles both cookie and API key)

private struct SecureCookieEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    private static let maxLength = 65_536

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        tv.isAutomaticSpellingCorrectionEnabled  = false
        tv.isAutomaticDataDetectionEnabled       = false
        tv.isAutomaticLinkDetectionEnabled       = false
        tv.isAutomaticTextReplacementEnabled     = false
        tv.isAutomaticQuoteSubstitutionEnabled   = false
        tv.isAutomaticDashSubstitutionEnabled    = false
        tv.isContinuousSpellCheckingEnabled      = false
        tv.isGrammarCheckingEnabled              = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = NSColor.white.withAlphaComponent(0.88)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SecureCookieEditor
        init(_ parent: SecureCookieEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if tv.string.count > SecureCookieEditor.maxLength {
                tv.string = String(tv.string.prefix(SecureCookieEditor.maxLength))
            }
            parent.text = tv.string
        }
    }
}

// MARK: - Animated pill preview (same as original)

private struct OnboardingPillPreview: View {
    @State private var demoPercent: Double = 0.42
    @State private var glowPulse = false
    private let demoValues: [Double] = [0.42, 0.71, 0.88, 0.42]
    @State private var demoIndex = 0

    var body: some View {
        let status: UsageStatus = demoPercent >= 0.9 ? .critical : demoPercent >= 0.7 ? .warning : .healthy
        let color = status.color

        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(color.opacity(glowPulse ? 0.32 : 0.12))
                    .frame(width: 12, height: 12)
                    .blur(radius: 3)
                Circle().fill(color).frame(width: 5, height: 5)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, CGFloat(demoPercent) * 80))
            }
            .frame(width: 80, height: 3)
            Text("\(Int((demoPercent * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .frame(minWidth: 25, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 22)
        .background(NotchPillShape(topRadius: 0, bottomRadius: 12).fill(Color.black))
        .shadow(color: color.opacity(0.4), radius: 8, y: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                demoIndex = (demoIndex + 1) % demoValues.count
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                    demoPercent = demoValues[demoIndex]
                }
            }
        }
    }
}
