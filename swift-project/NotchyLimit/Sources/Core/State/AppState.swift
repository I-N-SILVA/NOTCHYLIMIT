import Foundation
import Combine
import SwiftUI

public enum NotchOpenBehavior: String, Codable, CaseIterable {
    case click
    case hover

    public var displayName: String {
        switch self {
        case .click: return "Click"
        case .hover: return "Hover"
        }
    }
}

/// Single source of truth for UI state. Backed by `@Published` properties so
/// any SwiftUI view bound to it reacts instantly.
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
    @Published public var notchOpenBehavior: NotchOpenBehavior = .click { didSet { persist() } }

    // ── UI state ──────────────────────────────────────────────────────────
    @Published public var notchState: NotchState = .compactIdle
    @Published public var showOnboarding: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showDiagnostics: Bool = false

    // ── Settings ──────────────────────────────────────────────────────────
    @Published public var pollIntervalSeconds: TimeInterval = 300 { didSet { persist() } }
    @Published public var notificationsEnabled: Bool = true { didSet { persist() } }
    @Published public var thresholds: [Double] = [0.25, 0.5, 0.75, 0.9, 1.0] { didSet { persist() } }
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
        static let notchOpenBehavior = "notchy.notchOpenBehavior"
        static let activeProvider   = "notchy.activeProvider"
        static let enabledProviders = "notchy.enabledProviders"
        static let pollInterval     = "notchy.pollIntervalSeconds"
        static let notifications    = "notchy.notificationsEnabled"
        static let thresholds       = "notchy.thresholds"
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        let d = UserDefaults.standard
        if let raw = d.string(forKey: Key.displayMode), let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
        }
        if let raw = d.string(forKey: Key.notchOpenBehavior),
           let behavior = NotchOpenBehavior(rawValue: raw) {
            notchOpenBehavior = behavior
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
    }

    private func persist() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(displayMode.rawValue, forKey: Key.displayMode)
        d.set(notchOpenBehavior.rawValue, forKey: Key.notchOpenBehavior)
        d.set(activeProviderId.rawValue, forKey: Key.activeProvider)
        d.set(enabledProviders.map(\.rawValue), forKey: Key.enabledProviders)
        d.set(pollIntervalSeconds, forKey: Key.pollInterval)
        d.set(notificationsEnabled, forKey: Key.notifications)
        d.set(thresholds, forKey: Key.thresholds)
    }
}
