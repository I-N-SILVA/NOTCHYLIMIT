import Foundation
import Combine

/// Owns the polling loop for one or more providers.
///
/// Each enabled provider gets its own independent `Task` so a slow or rate-limited
/// provider doesn't block others. Snapshots and errors are emitted via publishers
/// consumed by `UsageCoordinator`.
///
/// Failure backoff: consecutive errors double the wait interval (cap: 1 hour).
/// A 429 rate-limit forces at least 5-minute backoff regardless of the configured interval.
public final class UsageService {
    public static let shared = UsageService()
    private init() {}

    public let snapshotPublisher = PassthroughSubject<ServiceUsageSnapshot, Never>()
    /// Emits `(providerId, error)` tuples so the coordinator can react per provider.
    public let errorPublisher    = PassthroughSubject<(ProviderId, ProviderError), Never>()

    private var pollTasks: [ProviderId: Task<Void, Never>] = [:]
    private var intervalSeconds: TimeInterval = 300
    private var consecutiveErrors: [ProviderId: Int] = [:]

    // MARK: - Lifecycle

    /// Start (or restart) polling for all given providers.
    public func start(providers: [ProviderId], interval: TimeInterval) {
        stopAll()
        intervalSeconds = max(60, interval)
        for p in providers where p.isAvailable { startProvider(p) }
    }

    /// Convenience for single-provider (backward-compat).
    public func start(providerId: ProviderId, interval: TimeInterval) {
        start(providers: [providerId], interval: interval)
    }

    public func stopAll() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
        consecutiveErrors.removeAll()
    }

    public func stop(providerId: ProviderId) {
        pollTasks[providerId]?.cancel()
        pollTasks.removeValue(forKey: providerId)
        consecutiveErrors.removeValue(forKey: providerId)
    }

    public func refreshNow(providerId: ProviderId? = nil) {
        if let id = providerId {
            Task { await fetchOnce(providerId: id) }
        } else {
            for id in pollTasks.keys { Task { await fetchOnce(providerId: id) } }
        }
    }

    /// Refresh all active providers.
    public func refreshNow() { refreshNow(providerId: nil) }

    public func updateInterval(_ seconds: TimeInterval) {
        intervalSeconds = max(60, seconds)
        let active = Array(pollTasks.keys)
        start(providers: active, interval: intervalSeconds)
    }

    // MARK: - Per-provider polling

    private func startProvider(_ providerId: ProviderId) {
        consecutiveErrors[providerId] = 0
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchOnce(providerId: providerId)
            while !Task.isCancelled {
                let wait = self.backoffInterval(for: providerId)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { break }
                await self.fetchOnce(providerId: providerId)
            }
        }
        pollTasks[providerId] = task
    }

    private func backoffInterval(for providerId: ProviderId) -> TimeInterval {
        let errs = consecutiveErrors[providerId] ?? 0
        let base = errs > 0
            ? min(intervalSeconds * pow(2.0, Double(min(errs, 6))), 3600)
            : intervalSeconds
        // Ease off on battery / Low Power Mode to be a good menu-bar citizen,
        // and to avoid needless hits on the providers' internal endpoints.
        return min(base * PowerState.pollMultiplier(), 3600)
    }

    private func fetchOnce(providerId: ProviderId) async {
        guard let provider = ProviderRegistry.shared.provider(for: providerId) else {
            await publish(error: .unknown("No provider registered for \(providerId.rawValue)"), id: providerId)
            return
        }
        do {
            let snapshot = try await provider.fetchUsage()
            consecutiveErrors[providerId] = 0
            await publish(snapshot: snapshot)
        } catch let error as ProviderError {
            consecutiveErrors[providerId, default: 0] += 1
            if case .rateLimited = error {
                consecutiveErrors[providerId] = max(
                    consecutiveErrors[providerId]!,
                    Int(ceil(log2(300 / intervalSeconds + 1)))
                )
            }
            await publish(error: error, id: providerId)
        } catch {
            consecutiveErrors[providerId, default: 0] += 1
            await publish(error: .unknown("unexpected"), id: providerId)
        }
    }

    @MainActor
    private func publish(snapshot: ServiceUsageSnapshot) {
        snapshotPublisher.send(snapshot)
    }

    @MainActor
    private func publish(error: ProviderError, id: ProviderId) {
        errorPublisher.send((id, error))
    }
}
