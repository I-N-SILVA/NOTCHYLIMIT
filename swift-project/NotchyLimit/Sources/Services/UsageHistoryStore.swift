import Foundation

/// Persists a rolling 7-day history of usage percentages per provider so the
/// expanded panel can draw a trend sparkline (#22).
///
/// Local JSON in Application Support — no network, no telemetry, consistent with
/// Notchy's local-first design. Access is serialized on a private queue so it's
/// safe to call `record` from the coordinator and `points` from the UI.
public final class UsageHistoryStore {
    public static let shared = UsageHistoryStore()

    public struct Point: Codable, Hashable {
        public let at: Date
        public let percent: Double   // 0...1
    }

    private let queue = DispatchQueue(label: "com.notchylimit.history")
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60   // keep 7 days
    private let minGap: TimeInterval = 4 * 60             // ignore samples closer than this
    private let capPerProvider = 800                      // hard upper bound per provider

    private var cache: [String: [Point]] = [:]
    private var loaded = false

    private init() {}

    private var fileURL: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("NotchyLimit", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("usage-history.json")
    }

    /// Record a usage sample (0...1) for a provider. Samples closer together than
    /// `minGap` are dropped so a burst of refreshes doesn't flood the series.
    public func record(providerId: ProviderId, percent: Double, at date: Date = Date()) {
        queue.sync {
            loadIfNeeded()
            let key = providerId.rawValue
            var points = cache[key] ?? []
            if let last = points.last, date.timeIntervalSince(last.at) < minGap { return }
            points.append(Point(at: date, percent: max(0, min(1, percent))))
            cache[key] = prune(points, now: date)
            save()
        }
    }

    /// Chronological usage points within the last 7 days for a provider.
    public func points(for providerId: ProviderId, now: Date = Date()) -> [Point] {
        queue.sync {
            loadIfNeeded()
            return prune(cache[providerId.rawValue] ?? [], now: now)
        }
    }

    // MARK: - Internal

    private func prune(_ points: [Point], now: Date) -> [Point] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var out = points.filter { $0.at >= cutoff }
        if out.count > capPerProvider { out = Array(out.suffix(capPerProvider)) }
        return out
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [Point]].self, from: data) else { return }
        cache = decoded
    }

    private func save() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
