import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings")
                        .font(Theme.displayFont)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("Done") { appState.showSettings = false }.keyboardShortcut(.return)
                }

                TabView {
                    providersTab.tabItem { Label("Providers", systemImage: "square.grid.2x2") }
                    displayTab.tabItem   { Label("Display",   systemImage: "macwindow") }
                    notificationsTab.tabItem { Label("Alerts", systemImage: "bell") }
                    advancedTab.tabItem  { Label("Advanced",  systemImage: "slider.horizontal.3") }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Providers tab

    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ProviderId.allCases.filter { $0.isAvailable }, id: \.self) { p in
                    providerRow(p)
                }

                Divider().background(Theme.stroke)

                ForEach(ProviderId.allCases.filter { !$0.isAvailable }, id: \.self) { p in
                    HStack {
                        Image(systemName: p.iconSymbol)
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 22)
                        Text(p.displayName).foregroundColor(Theme.textSecondary)
                        Spacer()
                        Text("Coming soon").font(Theme.captionFont).foregroundColor(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .opacity(0.5)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderId) -> some View {
        let hasCredential = AuthService.shared.hasCredential(for: p)
        let claudeCredential: ClaudeCredential? = p == .claude ? AuthService.shared.loadCredential(for: .claude) : nil
        let hasClaudeSetupToken = claudeCredential?.isBearerToken == true
        let hasClaudeCookie = p == .claude && hasCredential && !hasClaudeSetupToken
        let hasOAuth      = AuthService.shared.cliOAuthAvailable(for: p)
        let hasExpiredClaudeOAuth = p == .claude && !hasCredential && ClaudeOAuthCredential.hasExpiredCredential()
        let isDisabled    = appState.disabledProviders.contains(p)
        let isConfigured  = (hasOAuth || hasCredential) && !isDisabled

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: p.iconSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accentWarm)
                    .frame(width: 22)
                Text(p.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Theme.textPrimary)

                if isDisabled {
                    Text("Disabled")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.textSecondary.opacity(0.12)))
                } else if hasClaudeSetupToken {
                    Text("Token")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.statusHealthy)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusHealthy.opacity(0.12)))
                } else if hasExpiredClaudeOAuth {
                    Text("CLI expired")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.statusWarning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusWarning.opacity(0.12)))
                } else if hasOAuth {
                    Text("OAuth")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.statusHealthy)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.statusHealthy.opacity(0.12)))
                } else if hasCredential {
                    Text("Configured")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.accentWarm)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentWarm.opacity(0.12)))
                }

                Spacer()

                if isConfigured {
                    if hasCredential {
                        Button(p == .claude ? "Replace token" : "Replace key") {
                            appState.activeProviderId = p
                            appState.showOnboarding = true
                        }
                        .buttonStyle(.bordered)
                        .font(Theme.captionFont)
                    }

                    Button(hasOAuth && !hasCredential ? "Disable" : "Remove") {
                        AuthService.shared.clearCredential(for: p)
                        (NSApp.delegate as? AppDelegate)?.coordinator?.disableProvider(p)
                        if p == appState.activeProviderId {
                            appState.authStatus = .notConfigured
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.statusCritical)
                    .font(Theme.captionFont)
                } else {
                    Button(isDisabled ? "Enable" : "Set up") {
                        appState.activeProviderId = p
                        appState.showOnboarding = true
                    }
                    .buttonStyle(.borderedProminent)
                    .font(Theme.captionFont)
                }
            }

            // Auth tier info for Claude
            if p == .claude {
                if isDisabled {
                    Text("Claude CLI credentials are available, but Notchy is not using them.")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 30)
                } else if hasClaudeSetupToken {
                    Text("Using Claude setup token from Notchy Keychain. This is preferred over the volatile CLI access token.")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 30)
                } else if hasOAuth {
                    Text("Using Claude CLI OAuth from Keychain or ~/.claude/credentials.json — scoped, short-lived token.")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 30)
                } else if hasExpiredClaudeOAuth {
                    Text("Claude CLI token expired. Run `claude setup-token`, then paste the token in Notchy.")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.statusWarning)
                        .padding(.leading, 30)
                } else if hasClaudeCookie {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.statusWarning)
                        Text("Using full session cookie. Replace it with a `claude setup-token` token for a safer setup.")
                            .font(Theme.captionFont)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.leading, 26)
                }
            }

            // OpenAI billing context
            if p == .openai && hasCredential {
                Text("Reads monthly spend vs. hard limit from the billing dashboard.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }

    // MARK: - Display tab

    private var hasHardwareNotch: Bool { NotchDetector.hasHardwareNotch() }

    private var showNotchBinding: Binding<Bool> {
        Binding(
            get: { appState.displayMode.shouldShowNotch() },
            set: { applyDisplay(notch: $0, menu: appState.displayMode.shouldShowMenuBar()) }
        )
    }

    private var showMenuBarBinding: Binding<Bool> {
        Binding(
            get: { appState.displayMode.shouldShowMenuBar() },
            set: { applyDisplay(notch: appState.displayMode.shouldShowNotch(), menu: $0) }
        )
    }

    /// Maps the two toggles to a concrete DisplayMode, guaranteeing at least one
    /// surface stays visible and never enabling the notch on hardware without one.
    private func applyDisplay(notch: Bool, menu: Bool) {
        var n = notch, m = menu
        if !hasHardwareNotch { n = false; m = true }   // no notch → menu bar only
        if !n && !m { m = true }                        // never leave Notchy invisible
        appState.displayMode = (n && m) ? .both : (n ? .notch : .menubar)
    }

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where Notchy lives")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Theme.textPrimary)

            VStack(spacing: 8) {
                displayToggleRow(
                    icon: "macbook",
                    title: "Notch pill",
                    subtitle: hasHardwareNotch
                        ? "A glowing pill in the MacBook notch"
                        : "Needs a MacBook with a notch",
                    binding: showNotchBinding,
                    enabled: hasHardwareNotch
                )
                if hasHardwareNotch && showNotchBinding.wrappedValue {
                    notchOpenBehaviorRow
                }
                displayToggleRow(
                    icon: "menubar.rectangle",
                    title: "Menu bar",
                    subtitle: "An icon + popover in the macOS menu bar",
                    binding: showMenuBarBinding,
                    enabled: true
                )
            }

            Text(displayFootnote)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var notchOpenBehaviorRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 34, height: 34)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.accentWarm)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Open notch pill")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                Text("Choose how the expanded panel appears")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            Picker("Open notch pill", selection: $appState.notchOpenBehavior) {
                ForEach(NotchOpenBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.75)
                )
        )
    }

    private var displayFootnote: String {
        if !hasHardwareNotch {
            return "This Mac has no notch, so Notchy lives in the menu bar."
        }
        switch appState.displayMode {
        case .both:    return "Showing in both the notch and the menu bar."
        case .menubar: return "Showing in the menu bar only."
        default:       return "Showing in the notch only. Turn on Menu bar to show both."
        }
    }

    @ViewBuilder
    private func displayToggleRow(icon: String, title: String, subtitle: String,
                                  binding: Binding<Bool>, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(binding.wrappedValue ? Theme.accentWarm.opacity(0.18) : Theme.surface)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(binding.wrappedValue ? Theme.accentWarm : Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accentWarm)
                .disabled(!enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.75)
                )
        )
        .opacity(enabled ? 1 : 0.55)
    }

    // MARK: - Notifications tab

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable threshold notifications", isOn: $appState.notificationsEnabled)
                .toggleStyle(.switch)
                .foregroundColor(Theme.textPrimary)
            Text("Thresholds (percent of session)")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: 8) {
                ForEach([0.25, 0.5, 0.75, 0.9, 1.0], id: \.self) { t in
                    let on = appState.thresholds.contains(t)
                    Button("\(Int(t * 100))%") {
                        if on { appState.thresholds.removeAll { $0 == t } }
                        else  { appState.thresholds.append(t) }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? Theme.accentWarm : Theme.textSecondary)
                }
            }
            Button("Send test notification") { NotificationService.shared.sendTest() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Poll every").foregroundColor(Theme.textPrimary)
                Spacer()
                Picker("Poll every", selection: $appState.pollIntervalSeconds) {
                    Text("1 min").tag(TimeInterval(60))
                    Text("5 min").tag(TimeInterval(300))
                    Text("15 min").tag(TimeInterval(900))
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .onChange(of: appState.pollIntervalSeconds) { newValue in
                UsageService.shared.updateInterval(newValue)
            }

            if #available(macOS 13.0, *) {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
                    .toggleStyle(.switch)
                    .foregroundColor(Theme.textPrimary)
            }

            Button("Open Diagnostics") { appState.showDiagnostics = true }
                .buttonStyle(.bordered)

            Divider().background(Theme.stroke)

            Button("Quit Notchy") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .foregroundColor(Theme.statusCritical)

            Spacer()
        }
        .padding(.vertical, 8)
    }
}
