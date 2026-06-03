import Foundation

/// A complete snapshot from a provider at a moment in time.
/// The notch UI consumes one of these and binds compact + expanded views to it.
public struct ServiceUsageSnapshot: Codable, Hashable {
    public let providerId: ProviderId
    public let primaryWindow: UsageWindow          // session
    public let secondaryWindow: UsageWindow?       // weekly
    public let tertiaryWindow: UsageWindow?        // weekly Sonnet (Pro only)
    public let capturedAt: Date

    public init(
        providerId: ProviderId,
        primaryWindow: UsageWindow,
        secondaryWindow: UsageWindow? = nil,
        tertiaryWindow: UsageWindow? = nil,
        capturedAt: Date = Date()
    ) {
        self.providerId = providerId
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.tertiaryWindow = tertiaryWindow
        self.capturedAt = capturedAt
    }

    /// True when the provider authenticated successfully but exposes no usable
    /// quota/usage endpoint (e.g. Gemini, Perplexity). The UI shows an "Active"
    /// indicator instead of a misleading 0% bar for these snapshots.
    public var isStatusOnly: Bool {
        primaryWindow.type == .connected
    }

    /// True when the provider reports a remaining credit balance instead of a
    /// percentage (e.g. DeepSeek). The UI shows the balance text, not a bar.
    public var isBalance: Bool {
        primaryWindow.type == .balance
    }

    /// True when this snapshot has a meaningful 0...1 usage percentage to chart.
    public var showsPercentBar: Bool {
        !isStatusOnly && !isBalance
    }

    /// Short text for compact spaces: "42%", a balance like "$110.00", or "Active".
    public var shortLabel: String {
        if isStatusOnly { return "Active" }
        if isBalance    { return primaryWindow.label ?? "—" }
        return "\(Int((primaryWindow.percentUsed * 100).rounded()))%"
    }

    /// Builds a status-only snapshot for a provider with no quota endpoint.
    /// Renders as a healthy "Active" indicator — never a percentage.
    public static func connected(
        providerId: ProviderId,
        capturedAt: Date = Date()
    ) -> ServiceUsageSnapshot {
        let window = UsageWindow(
            type: .connected,
            percentUsed: 0,
            lastUpdated: capturedAt
        )
        return ServiceUsageSnapshot(
            providerId: providerId,
            primaryWindow: window,
            capturedAt: capturedAt
        )
    }

    /// Builds a balance snapshot for a provider that reports remaining credit
    /// (e.g. DeepSeek). `label` is the pre-formatted amount, e.g. "$110.00".
    public static func balance(
        providerId: ProviderId,
        label: String,
        amount: Double? = nil,
        amountKind: AmountKind = .none,
        capturedAt: Date = Date()
    ) -> ServiceUsageSnapshot {
        let window = UsageWindow(
            type: .balance,
            percentUsed: 0,
            usedAmount: amount,   // numeric balance, for low-balance alerts + aggregation
            lastUpdated: capturedAt,
            label: label,
            amountKind: amountKind
        )
        return ServiceUsageSnapshot(
            providerId: providerId,
            primaryWindow: window,
            capturedAt: capturedAt
        )
    }

    /// The worst status across windows, used for the top-level pill color.
    public var combinedStatus: UsageStatus {
        let candidates: [UsageStatus] = [
            primaryWindow.status,
            secondaryWindow?.status ?? .healthy,
            tertiaryWindow?.status ?? .healthy
        ]
        if candidates.contains(.critical) { return .critical }
        if candidates.contains(.warning)  { return .warning }
        return .healthy
    }
}
