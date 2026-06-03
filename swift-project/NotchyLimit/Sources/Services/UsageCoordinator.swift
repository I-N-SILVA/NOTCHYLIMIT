import Foundation
import Combine

/// Glues UsageService → AppState → NotificationService.
/// Owns no UI; only updates published state and fires notifications.
public final class UsageCoordinator {
    private let appState: AppState
    private let authService: AuthService
    private let usageService: UsageService
    private let notifications: NotificationService
    private var cancellables = Set<AnyCancellable>()

    public init(
        appState: AppState,
        authService: AuthService,
        usageService: UsageService,
        notifications: NotificationService
    ) {
        self.appState = appState
        self.authService = authService
        self.usageService = usageService
        self.notifications = notifications
    }

    /// Ensures every provider with a stored credential (or Claude OAuth) is in
    /// `enabledProviders`, so a configured provider always survives relaunch even
    /// if it wasn't persisted. Preserves the user's existing order.
    private func reconcileEnabledProviders() {
        // Keep only providers we actually have credentials for (preserves order),
        // then add any configured provider not already listed. This drops stale
        // defaults like an unconfigured Claude so it doesn't sit at "Waiting…".
        var enabled = appState.enabledProviders.filter { isConfigured($0) }
        for id in ProviderId.allCases where isConfigured(id) && !enabled.contains(id) {
            enabled.append(id)
        }
        if enabled != appState.enabledProviders {
            appState.enabledProviders = enabled
        }
        // Ensure the active (notch) provider is one that's actually enabled.
        if !enabled.contains(appState.activeProviderId), let first = enabled.first {
            appState.activeProviderId = first
            appState.latestSnapshot = appState.snapshots[first]
        }
    }

    public func start() {
        reconcileEnabledProviders()
        LocalAPIServer.shared.start()

        // Pipe snapshots into both the legacy `latestSnapshot` and the multi-provider dict.
        usageService.snapshotPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.appState.snapshots[snapshot.providerId] = snapshot
                self.appState.providerErrors[snapshot.providerId] = nil
                if snapshot.providerId == self.appState.activeProviderId {
                    self.appState.latestSnapshot = snapshot
                    self.appState.authStatus     = .valid
                    self.appState.syncStatus     = .ok(at: Date())
                }
                self.handleNotifications(for: snapshot)
                UsageHistory.shared.record(snapshot)
                LocalAPIServer.shared.update(UsageExporter.json(from: self.appState.snapshots))
            }
            .store(in: &cancellables)

        usageService.errorPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (providerId, err) in
                guard let self else { return }
                self.appState.providerErrors[providerId] = err   // track per provider
                guard providerId == self.appState.activeProviderId else { return }
                if err.isAuthIssue {
                    let wasValid = self.appState.authStatus == .valid
                    self.appState.authStatus = (err == .missingCredentials) ? .notConfigured : .expired
                    if wasValid && err == .unauthorized {
                        self.notifications.send(
                            title: "\(providerId.displayName) credentials expired",
                            body: "Open Notchy → Settings to reconnect."
                        )
                    }
                }
                self.appState.syncStatus = .error(err)
            }
            .store(in: &cancellables)

        // Outage monitoring — independent of auth, so poll all enabled providers.
        IncidentMonitor.shared.onIncident = { [weak self] providerId, incident in
            self?.appState.incidents[providerId] = incident
        }
        IncidentMonitor.shared.start(providers: appState.enabledProviders)

        // Begin polling for all enabled providers that have credentials.
        let configured = appState.enabledProviders.filter { isConfigured($0) }
        if configured.isEmpty {
            appState.authStatus = .notConfigured
        } else {
            appState.authStatus = .valid
            usageService.start(providers: configured, interval: appState.pollIntervalSeconds)
        }
    }

    public func stop() {
        usageService.stopAll()
        IncidentMonitor.shared.stop()
        LocalAPIServer.shared.stop()
        cancellables.removeAll()
    }

    public func onCredentialsSaved(for providerId: ProviderId = .claude) {
        if !appState.enabledProviders.contains(providerId) {
            appState.enabledProviders.append(providerId)
        }
        appState.authStatus = .valid
        usageService.start(providers: appState.enabledProviders.filter { isConfigured($0) },
                           interval: appState.pollIntervalSeconds)
        IncidentMonitor.shared.start(providers: appState.enabledProviders)
    }

    public func refreshNow() {
        appState.syncStatus = .syncing
        usageService.refreshNow()
    }

    public func disableProvider(_ providerId: ProviderId) {
        appState.enabledProviders.removeAll { $0 == providerId }
        appState.snapshots.removeValue(forKey: providerId)
        appState.incidents.removeValue(forKey: providerId)
        if providerId == appState.activeProviderId { appState.latestSnapshot = nil }
        usageService.stop(providerId: providerId)
        IncidentMonitor.shared.start(providers: appState.enabledProviders)
    }

    // MARK: - Helpers

    private func isConfigured(_ providerId: ProviderId) -> Bool {
        if authService.cliOAuthAvailable(for: providerId) { return true }
        return authService.hasCredential(for: providerId)
    }

    private func handleNotifications(for snapshot: ServiceUsageSnapshot) {
        guard appState.notificationsEnabled else { return }
        notifications.evaluate(snapshot: snapshot,
                               thresholds: appState.thresholds,
                               providerId: snapshot.providerId)
        notifications.evaluateBalance(snapshot: snapshot,
                                      threshold: appState.lowBalanceThreshold,
                                      providerId: snapshot.providerId)
    }
}
