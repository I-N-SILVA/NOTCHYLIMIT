import Foundation
import AppKit

/// Threshold-aware notification dispatcher.
///
/// Strategy: high-water mark per window.
///
/// For each usage window (session, weekly, model) we track the highest
/// threshold we have already notified about. A notification fires only when
/// the current usage climbs strictly above that mark. When usage drops back
/// below the lowest configured threshold (window reset), the mark is cleared
/// so the next rising edge fires again.
///
/// This replaces a previous key-based design that embedded `resets_at` in a
/// deduplication key. Claude's API recalculates `resets_at` as "now + 5h" on
/// every call, so the key drifted by the poll interval each fetch, causing
/// notifications to fire on every single poll.
///
/// The mark is persisted in UserDefaults so app restarts within the same
/// window do not re-fire already-seen thresholds.
public final class NotificationService {
    public static let shared = NotificationService()
    private init() { loadMark() }

    private let defaultsKey = "com.notchylimit.NotificationService.highWaterMark"

    // "claude:session" → highest threshold already notified (0.0 = none)
    private var mark: [String: Double] = [:]

    // MARK: - Public API

    public func evaluate(snapshot: ServiceUsageSnapshot,
                         thresholds: [Double],
                         providerId: ProviderId) {
        guard !thresholds.isEmpty else { return }

        var windows: [(UsageWindow, String)] = [(snapshot.primaryWindow, "session")]
        if let w = snapshot.secondaryWindow { windows.append((w, "weekly")) }
        if let w = snapshot.tertiaryWindow  { windows.append((w, "model"))  }

        let sorted = thresholds.sorted()
        let lowest = sorted.first!

        var dirty = false

        for (window, label) in windows where window.percentUsed > 0 {
            let key = "\(providerId.rawValue):\(label)"
            var current = mark[key] ?? 0

            // Reset on window rollover: usage has fallen back below the lowest
            // threshold, meaning the window cycled. Clear the mark and notify
            // so the user knows they can get back to work.
            if window.percentUsed < lowest && current > 0 {
                mark[key] = 0
                current = 0
                dirty = true
                fire(
                    title: "\(providerId.displayName) \(label) reset",
                    body: "\(label.capitalized) window reset — you're back to 0%."
                )
            }

            // Find the highest threshold the current usage has crossed.
            guard let highest = sorted.last(where: { window.percentUsed >= $0 }) else { continue }

            // Only fire if we have crossed above the previously recorded mark.
            guard highest > current else { continue }

            mark[key] = highest
            dirty = true
            let title = highest >= 1.0
                ? "\(providerId.displayName) \(label) limit reached"
                : "\(providerId.displayName) \(label) \(Int(highest * 100))% used"
            fire(title: title, body: usageBody(window: window, label: label))
        }

        if dirty { saveMark() }
    }

    /// Low-balance alert for balance-reporting providers (DeepSeek, Copilot…).
    /// Fires once when the numeric balance drops below `threshold`; re-arms when
    /// the balance climbs back above it (a top-up), so the next drawdown alerts
    /// again instead of staying silent forever.
    public func evaluateBalance(snapshot: ServiceUsageSnapshot,
                                threshold: Double,
                                providerId: ProviderId) {
        guard threshold > 0,
              snapshot.isBalance,
              let balance = snapshot.primaryWindow.usedAmount else { return }

        let key = "\(providerId.rawValue):balance"
        let alreadyLow = (mark[key] ?? 0) > 0   // 1 = already alerted for the current low spell

        if balance < threshold && !alreadyLow {
            mark[key] = 1
            saveMark()
            fire(title: "\(providerId.displayName) balance low",
                 body: "\(snapshot.primaryWindow.label ?? "Balance") left — consider topping up.")
        } else if balance >= threshold && alreadyLow {
            mark[key] = 0
            saveMark()
        }
    }

    public func send(title: String, body: String) {
        fire(title: title, body: body)
    }

    public func sendTest() {
        fire(title: "Notchy Limit", body: "Notifications are working.")
    }

    /// Trajectory-based alert: fires once when the forecast says you are on pace
    /// to exhaust the window *before* it resets, and re-arms only after you fall
    /// back off that pace. This complements the fixed 25/50/75/90% thresholds
    /// with a "you won't make it to reset at this rate" heads-up.
    ///
    /// Only meaningful for windows that actually reset (session/weekly), so the
    /// caller should pass a forecast computed against a window with a `resetAt`.
    public func evaluatePace(forecast: UsageForecast?, providerId: ProviderId) {
        let key = "\(providerId.rawValue):pace"
        let armed = (mark[key] ?? 0) > 0
        // On pace to exhaust = we have a forecast and the window will NOT reset first.
        let onPaceToExhaust = forecast.map { !$0.willResetFirst } ?? false

        if onPaceToExhaust, let f = forecast, !armed {
            mark[key] = 1
            saveMark()
            fire(title: "\(providerId.displayName) on pace to run out",
                 body: "At this rate you'll hit the limit in ~\(f.remainingShort), before it resets. Ease off to make it through.")
        } else if !onPaceToExhaust && armed {
            mark[key] = 0
            saveMark()
        }
    }

    // MARK: - Persistence

    private func saveMark() {
        UserDefaults.standard.set(mark, forKey: defaultsKey)
    }

    private func loadMark() {
        mark = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    // MARK: - Delivery

    private func usageBody(window: UsageWindow, label: String) -> String {
        if window.isAtLimit {
            return window.timeToResetString().map { "Blocked. \($0)." } ?? "Session limit reached."
        }
        let pct = Int(window.percentUsed * 100)
        if let reset = window.timeToResetString() {
            return "\(pct)% of \(label) limit. \(reset)."
        }
        return "\(pct)% of your \(label) limit used."
    }

    private func fire(title: String, body: String) {
        NotificationBannerController.shared.show(title: title, body: body)
    }
}
