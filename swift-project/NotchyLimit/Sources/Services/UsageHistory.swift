import Foundation

/// A rolling, persisted history of usage samples per provider, powering the
/// inline sparklines in the expanded panel.
///
/// Each sample is a single number in 0…1 — a percentage window's `percentUsed`,
/// or a balance normalized against its session high so a drawdown still trends.
/// We keep the last `maxSamples` per provider in UserDefaults (tiny: a few
/// hundred floats), so the trend survives relaunches.
public final class UsageHistory {
    public static let shared = UsageHistory()
    private init() { load() }

    private let defaultsKey = "com.notchylimit.UsageHistory"
    private let maxSamples = 60

    // providerId.rawValue → recent values (oldest first)
    private var samples: [String: [Double]] = [:]

    /// Record the current value for a provider (call on each fresh snapshot).
    public func record(_ snapshot: ServiceUsageSnapshot) {
        let value: Double
        if snapshot.showsPercentBar {
            value = max(0, min(1, snapshot.primaryWindow.percentUsed))
        } else if snapshot.isBalance, let amt = snapshot.primaryWindow.usedAmount {
            // Normalize a balance against its running max so the line still moves.
            let key = snapshot.providerId.rawValue
            let peak = Swift.max(peakAmount[key] ?? amt, Swift.max(amt, 1.0))
            peakAmount[key] = peak
            value = max(0, min(1, amt / peak))
        } else {
            return   // connected-only: nothing meaningful to chart
        }

        var arr = samples[snapshot.providerId.rawValue] ?? []
        arr.append(value)
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
        samples[snapshot.providerId.rawValue] = arr
        save()
    }

    /// Recent samples (oldest first) for sparkline rendering.
    public func series(for providerId: ProviderId) -> [Double] {
        samples[providerId.rawValue] ?? []
    }

    private var peakAmount: [String: Double] = [:]

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(samples, forKey: defaultsKey)
    }
    private func load() {
        samples = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]]) ?? [:]
    }
}
