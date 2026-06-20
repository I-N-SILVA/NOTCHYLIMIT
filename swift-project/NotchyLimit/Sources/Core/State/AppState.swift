import Foundation
import Combine
import SwiftUI

/// Single source of truth for UI state. Backed by `@Published` properties so
/// any SwiftUI view bound to it reacts instantly.
/// What the menu-bar status item renders.
public enum MenuBarStyle: String, Codable, CaseIterable {
    case full      // mascot glyph + value
    case iconOnly  // mascot glyph only
    case valueOnly // value text only (%/$/Active)

    public var label: String {
        switch self {
        case .full:      return "Icon + value"
        case .iconOnly:  return "Icon only"
        case .valueOnly: return "Value only"
        }
    }
}

public final class AppState: ObservableObject {
    /// Set true while loading persisted values so `didSet` observers don't echo back to disk.
    private var isLoading = false

    // ── Single-provider (backward-compat) ─────────────────────────────────
    @Published public var activeProviderId: ProviderId = .claude { didSet { persist() } }
    @Published public var latestSnapshot: ServiceUsageSnapshot?
    @Published public var authStatus: AuthStatus = .notConfigured
    @Published public var syncStatus: SyncStatus = .idle

    // ── Multi-provider ─────────────────────────────────────────────────────
    /// All live snapshots keyed by provider. Updated alongside `latestSnapshot`.
    @Published public var snapshots: [ProviderId: ServiceUsageSnapshot] = [:]
    /// Providers the user has enabled (may be 1–3).
    @Published public var enabledProviders: [ProviderId] = [.claude] { didSet { persist() } }
    /// Latest service-status read per provider, from their status pages.
    @Published public var incidents: [ProviderId: ServiceIncident] = [:]
    /// Last fetch error per provider (cleared on a successful snapshot). Lets the
    /// UI show "Sign in again" for a configured-but-failing provider.
    @Published public var providerErrors: [ProviderId: ProviderError] = [:]

    // ── Display mode ───────────────────────────────────────────────────────
    @Published public var displayMode: DisplayMode = .auto { didSet { persist() } }

    // ── UI state ──────────────────────────────────────────────────────────
    @Published public var notchState: NotchState = .compactIdle
    @Published public var showOnboarding: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showDiagnostics: Bool = false

    // ── Settings ──────────────────────────────────────────────────────────
    @Published public var pollIntervalSeconds: TimeInterval = 300 { didSet { persist() } }
    @Published public var notificationsEnabled: Bool = true { didSet { persist() } }
    @Published public var thresholds: [Double] = [0.25, 0.5, 0.75, 0.9, 1.0] { didSet { persist() } }
    /// Warn when a balance-reporting provider (DeepSeek, etc.) drops below this
    /// many units of its currency. 0 disables low-balance alerts.
    @Published public var lowBalanceThreshold: Double = 5.0 { didSet { persist() } }
    /// What the menu-bar status item shows.
    @Published public var menuBarStyle: MenuBarStyle = .full { didSet { persist() } }
    @Published public var launchAtLogin: Bool = false

    // MARK: - Convenience (always reflects activeProviderId's snapshot)

    public var sessionPercent: Double {
        latestSnapshot?.primaryWindow.percentUsed ?? 0
    }

    public var sessionStatus: UsageStatus {
        latestSnapshot?.primaryWindow.status ?? .unknown
    }

    public var sessionResetString: String? {
        latestSnapshot?.primaryWindow.timeToResetString()
    }

    public var isAtSessionLimit: Bool { sessionPercent >= 1.0 }

    /// True when the active provider only reports connectivity (no quota %),
    /// so the UI shows an "Active" indicator instead of a percentage.
    public var activeIsStatusOnly: Bool {
        latestSnapshot?.isStatusOnly ?? false
    }

    /// True when the active provider reports a credit balance, not a percentage.
    public var activeIsBalance: Bool {
        latestSnapshot?.isBalance ?? false
    }

    /// True when the active provider has a chartable usage percentage.
    /// Defaults to true when no snapshot yet (shows the waiting bar).
    public var activeShowsPercentBar: Bool {
        latestSnapshot?.showsPercentBar ?? true
    }

    /// Compact label for the active provider: "42%", "$110.00", or "Active".
    public var activeShortLabel: String {
        latestSnapshot?.shortLabel ?? "—"
    }

    public var sessionResetShortString: String? {
        latestSnapshot?.primaryWindow.timeToResetShortString()
    }

    // MARK: - Forecast (burn-rate → time to limit)

    /// Projection of the active provider's usage to its limit, or nil when there
    /// isn't enough trend yet (or usage is flat/falling). Drives the pace row and
    /// the trajectory alert.
    public var sessionForecast: UsageForecast? {
        UsageForecaster.shared.forecast(for: activeProviderId, snapshot: latestSnapshot)
    }

    // MARK: - Staleness

    /// Age of the active provider's latest reading, or nil if none yet.
    public var activeSnapshotAge: TimeInterval? {
        guard let at = latestSnapshot?.capturedAt else { return nil }
        return max(0, Date().timeIntervalSince(at))
    }

    /// True when the active reading is older than 2.5× the poll interval, i.e. a
    /// refresh has been missed and the displayed number may be out of date. The
    /// UI surfaces this instead of presenting a stale value as current.
    public var isActiveStale: Bool {
        guard let age = activeSnapshotAge else { return false }
        return age > pollIntervalSeconds * 2.5
    }

    /// Compact "12m"/"2h"/"3d" string for how old the active reading is.
    public var activeSnapshotAgeString: String? {
        guard let age = activeSnapshotAge else { return nil }
        let minutes = Int(age / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Worst status across ALL enabled providers — used for global pill colour.
    public var combinedStatus: UsageStatus {
        let statuses = snapshots.values.map { $0.combinedStatus }
        if statuses.contains(.critical) { return .critical }
        if statuses.contains(.warning)  { return .warning }
        if statuses.isEmpty             { return .unknown }
        return .healthy
    }

    /// True when 2+ providers are active with live snapshots — triggers constellation UI.
    public var isMultiProvider: Bool {
        snapshots.count >= 2
    }

    /// Highest session usage across percentage-reporting providers — drives the
    /// mascot's mood (calm → worried → alarmed).
    public var peakUsagePercent: Double {
        snapshots.values.filter { $0.showsPercentBar }.map { $0.primaryWindow.percentUsed }.max() ?? 0
    }

    /// True when no provider has reported yet — the mascot dozes.
    public var hasNoData: Bool { snapshots.isEmpty }

    // MARK: - Cross-provider dollar aggregates

    /// Total dollars spent this period across providers that report spend
    /// (OpenRouter, Perplexity, Copilot). Currencies are assumed USD.
    public var totalSpend: Double {
        snapshots.values.reduce(0) { acc, snap in
            let w = snap.primaryWindow
            return acc + (w.amountKind == .spend ? (w.usedAmount ?? 0) : 0)
        }
    }

    /// Total prepaid credit remaining across providers that report a balance
    /// (DeepSeek). Assumed USD.
    public var totalRemainingCredit: Double {
        snapshots.values.reduce(0) { acc, snap in
            let w = snap.primaryWindow
            return acc + (w.amountKind == .remaining ? (w.usedAmount ?? 0) : 0)
        }
    }

    /// Compact one-liner for the menu header, e.g. "$12.30 spent · $8 credit".
    /// Nil when no provider reports a dollar figure.
    public var dollarSummary: String? {
        var parts: [String] = []
        let spend = totalSpend
        let credit = totalRemainingCredit
        if spend > 0  { parts.append(String(format: "$%.2f spent", spend)) }
        if credit > 0 { parts.append(String(format: "$%@ credit", credit == credit.rounded() ? String(format: "%.0f", credit) : String(format: "%.2f", credit))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Active incident for the currently-selected provider, if any.
    public var activeIncident: ServiceIncident? {
        guard let incident = incidents[activeProviderId], incident.level.isActive else { return nil }
        return incident
    }

    /// Worst active incident across all enabled providers — for the global pill badge.
    public var worstIncident: ServiceIncident? {
        let active = enabledProviders.compactMap { incidents[$0] }.filter { $0.level.isActive }
        let order: [IncidentLevel] = [.critical, .major, .minor, .maintenance]
        for level in order {
            if let hit = active.first(where: { $0.level == level }) { return hit }
        }
        return nil
    }

    public init() {
        load()
    }

    // MARK: - Persistence

    private enum Key {
        static let displayMode      = "notchy.displayMode"
        static let activeProvider   = "notchy.activeProvider"
        static let enabledProviders = "notchy.enabledProviders"
        static let pollInterval     = "notchy.pollIntervalSeconds"
        static let notifications    = "notchy.notificationsEnabled"
        static let thresholds       = "notchy.thresholds"
        static let lowBalance       = "notchy.lowBalanceThreshold"
        static let menuBarStyle     = "notchy.menuBarStyle"
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        let d = UserDefaults.standard
        if let raw = d.string(forKey: Key.displayMode), let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
        }
        if let raw = d.string(forKey: Key.activeProvider), let p = ProviderId(rawValue: raw) {
            activeProviderId = p
        }
        if let raws = d.array(forKey: Key.enabledProviders) as? [String] {
            let restored = raws.compactMap { ProviderId(rawValue: $0) }
            if !restored.isEmpty { enabledProviders = restored }
        }
        if d.object(forKey: Key.pollInterval) != nil {
            let v = d.double(forKey: Key.pollInterval)
            if v >= 60 { pollIntervalSeconds = v }
        }
        if d.object(forKey: Key.notifications) != nil {
            notificationsEnabled = d.bool(forKey: Key.notifications)
        }
        if let t = d.array(forKey: Key.thresholds) as? [Double], !t.isEmpty {
            thresholds = t
        }
        if d.object(forKey: Key.lowBalance) != nil {
            lowBalanceThreshold = d.double(forKey: Key.lowBalance)
        }
        if let raw = d.string(forKey: Key.menuBarStyle), let s = MenuBarStyle(rawValue: raw) {
            menuBarStyle = s
        }
    }

    private func persist() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(displayMode.rawValue, forKey: Key.displayMode)
        d.set(activeProviderId.rawValue, forKey: Key.activeProvider)
        d.set(enabledProviders.map(\.rawValue), forKey: Key.enabledProviders)
        d.set(pollIntervalSeconds, forKey: Key.pollInterval)
        d.set(notificationsEnabled, forKey: Key.notifications)
        d.set(thresholds, forKey: Key.thresholds)
        d.set(lowBalanceThreshold, forKey: Key.lowBalance)
        d.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle)
    }
}
