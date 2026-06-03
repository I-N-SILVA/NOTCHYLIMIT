import Foundation
import SwiftUI

/// Which window inside a provider this usage belongs to.
public enum UsageWindowType: String, Codable, Hashable {
    case session     // Claude's 5-hour rolling window
    case weekly      // Claude's 7-day window
    case weeklyModel // Claude Pro's 7-day Sonnet sub-window
    case monthly     // Calendar-month billing window (OpenAI spend vs limit)
    case daily       // Rolling daily quota (Gemini Code Assist per-model buckets)
    case connected   // Provider authenticated but exposes no quota endpoint (Gemini, Perplexity)
    case balance     // Provider reports a remaining credit balance, not a % (DeepSeek)
}

/// What a window's `usedAmount` dollar figure means, so the app can aggregate
/// like-with-like across providers (you can't add "spent" to "credit left").
public enum AmountKind: String, Codable, Hashable {
    case none        // usedAmount isn't a comparable dollar figure
    case spend       // dollars spent this period (OpenRouter, Perplexity, Copilot)
    case remaining   // dollars of prepaid credit left (DeepSeek)
}

/// Health classification derived from percent used + reset proximity.
public enum UsageStatus: String, Codable, Hashable {
    case healthy   // under warning threshold
    case warning   // approaching limit
    case critical  // at or past hard threshold
    case unknown   // no data yet

    /// SwiftUI color for the status, honoring `Theme`.
    public var color: Color {
        switch self {
        case .healthy:  return Theme.statusHealthy
        case .warning:  return Theme.statusWarning
        case .critical: return Theme.statusCritical
        case .unknown:  return Theme.statusUnknown
        }
    }
}

/// A single rolling usage window inside a provider snapshot.
///
/// `percentUsed` is normalized to 0...1. `usedAmount` and `limitAmount` are
/// kept as optional `Double`s in case the provider only reports a percentage
/// (which is the case for Claude today — see ClaudeUsageBar reference).
public struct UsageWindow: Codable, Hashable {
    public let type: UsageWindowType
    public let percentUsed: Double          // 0.0 ... 1.0+
    public let usedAmount: Double?
    public let limitAmount: Double?
    public let resetAt: Date?
    public let lastUpdated: Date
    /// Pre-formatted short text for windows without a percentage (e.g. a
    /// `.balance` window's "$110.00"). Nil for percentage windows.
    public let label: String?

    /// What `usedAmount` means in dollars, for cross-provider aggregation.
    public let amountKind: AmountKind

    public init(
        type: UsageWindowType,
        percentUsed: Double,
        usedAmount: Double? = nil,
        limitAmount: Double? = nil,
        resetAt: Date? = nil,
        lastUpdated: Date = Date(),
        label: String? = nil,
        amountKind: AmountKind = .none
    ) {
        self.type = type
        self.percentUsed = percentUsed
        self.usedAmount = usedAmount
        self.limitAmount = limitAmount
        self.resetAt = resetAt
        self.lastUpdated = lastUpdated
        self.label = label
        self.amountKind = amountKind
    }

    /// Derive a health classification using the default thresholds.
    public var status: UsageStatus {
        let p = percentUsed
        if p >= 0.9 { return .critical }
        if p >= 0.7 { return .warning }
        return .healthy
    }

    /// Whether the window is at or past its limit.
    public var isAtLimit: Bool { percentUsed >= 1.0 }

    /// Compact reset countdown for tight spaces, e.g. "1h 12m". Nil if no resetAt.
    public func timeToResetShortString(now: Date = Date()) -> String? {
        guard let resetAt = resetAt else { return nil }
        let interval = resetAt.timeIntervalSince(now)
        if interval <= 0 { return "soon" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }

    /// Human-readable countdown to reset, e.g. "Resets in 1h 12m".
    public func timeToResetString(now: Date = Date()) -> String? {
        guard let resetAt = resetAt else { return nil }
        let interval = resetAt.timeIntervalSince(now)
        if interval <= 0 { return "Resetting…" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            let days = hours / 24
            let rem = hours % 24
            return rem > 0 ? "Resets in \(days)d \(rem)h" : "Resets in \(days)d"
        }
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        }
        return "Resets in \(max(minutes, 1))m"
    }
}
