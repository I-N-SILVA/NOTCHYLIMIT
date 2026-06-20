import Foundation

/// A timestamped usage sample: a percentage in 0…1 captured at a point in time.
public struct UsageSample: Codable, Hashable {
    public let at: Date
    public let percent: Double
    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

/// The result of projecting current usage forward to its limit.
///
/// `willResetFirst` is the good case: at the current pace the rolling window
/// resets before you would ever reach 100%, so you are on track.
public struct UsageForecast: Hashable {
    public let ratePerHour: Double          // usage points (0…1 scale) per hour, always > 0
    public let secondsToLimit: TimeInterval // seconds until percentUsed reaches 1.0
    public let eta: Date                     // now + secondsToLimit
    public let willResetFirst: Bool          // window resets before the limit is hit

    public init(ratePerHour: Double, secondsToLimit: TimeInterval, eta: Date, willResetFirst: Bool) {
        self.ratePerHour = ratePerHour
        self.secondsToLimit = secondsToLimit
        self.eta = eta
        self.willResetFirst = willResetFirst
    }

    /// "3h 20m", "2d 4h", "45m" — a compact duration.
    static func human(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 {
            let days = hours / 24
            let remH = hours % 24
            return remH > 0 ? "\(days)d \(remH)h" : "\(days)d"
        }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }

    /// Compact remaining-at-pace duration, e.g. "3h 20m".
    public var remainingShort: String { Self.human(secondsToLimit) }

    /// A sentence for the pace row.
    public var paceLabel: String {
        if willResetFirst { return "On track — resets before you hit the limit." }
        return "At this pace, you'll hit the limit in ~\(remainingShort)."
    }
}

/// Records a short, persisted trail of timestamped usage samples per provider
/// and projects them forward to a "time to limit" forecast.
///
/// The projection is a pure function (`project`) so it is fully unit-testable
/// without touching disk or the clock. Samples are stored under their own
/// UserDefaults key, independent of `UsageHistory`, so neither can corrupt the
/// other.
public final class UsageForecaster {
    public static let shared = UsageForecaster()
    private init() { load() }

    private let defaultsKey = "com.notchylimit.UsageForecaster.samples"
    private let maxSamples = 24

    // providerId.rawValue → recent timestamped samples (oldest first)
    private var samples: [String: [UsageSample]] = [:]

    /// Append the current percentage reading for a provider. No-op for
    /// providers that don't report a chartable percentage (balance/connected).
    public func record(_ snapshot: ServiceUsageSnapshot) {
        guard snapshot.showsPercentBar else { return }
        let key = snapshot.providerId.rawValue
        var arr = samples[key] ?? []
        let sample = UsageSample(
            at: snapshot.capturedAt,
            percent: max(0, min(1.2, snapshot.primaryWindow.percentUsed))
        )
        // Skip a duplicate at (effectively) the same timestamp.
        if let last = arr.last, abs(last.at.timeIntervalSince(sample.at)) < 1 { return }
        arr.append(sample)
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
        samples[key] = arr
        save()
    }

    /// Forecast for the active window of a snapshot, using the stored trail.
    public func forecast(for providerId: ProviderId,
                         snapshot: ServiceUsageSnapshot?,
                         now: Date = Date()) -> UsageForecast? {
        guard let snapshot, snapshot.showsPercentBar else { return nil }
        return Self.project(samples: samples[providerId.rawValue] ?? [],
                            current: snapshot.primaryWindow,
                            now: now)
    }

    /// Pure projection — exposed for testing.
    ///
    /// Estimates the recent rate of change from the trailing samples and
    /// extrapolates linearly to 100%. Returns nil when there isn't enough
    /// signal (too few samples, too little elapsed time, flat or falling usage,
    /// or already at the limit).
    public static func project(samples: [UsageSample],
                               current: UsageWindow,
                               now: Date = Date()) -> UsageForecast? {
        guard samples.count >= 2 else { return nil }
        let recent = Array(samples.suffix(6))
        guard let first = recent.first, let last = recent.last else { return nil }

        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed >= 60 else { return nil }            // need real time between samples

        let deltaPct = last.percent - first.percent
        let ratePerSec = deltaPct / elapsed
        guard ratePerSec > 0 else { return nil }           // flat or falling: no limit ETA

        let currentPct = current.percentUsed
        guard currentPct < 1.0 else { return nil }         // already at the limit

        let secondsToLimit = (1.0 - currentPct) / ratePerSec
        guard secondsToLimit.isFinite,
              secondsToLimit > 0,
              secondsToLimit < 14 * 24 * 3600 else { return nil }   // cap at 14 days

        let eta = now.addingTimeInterval(secondsToLimit)
        let willResetFirst = current.resetAt.map { $0 < eta } ?? false

        return UsageForecast(ratePerHour: ratePerSec * 3600,
                             secondsToLimit: secondsToLimit,
                             eta: eta,
                             willResetFirst: willResetFirst)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [UsageSample]].self, from: data)
        else { return }
        samples = decoded
    }
}
