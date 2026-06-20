import XCTest
@testable import NotchyLimit

// MARK: - ClaudeUsageMapper Tests

final class ClaudeUsageMappingTests: XCTestCase {

    // 1. Happy path: all three windows present.
    func test_snapshot_parsesAllWindows() throws {
        let json = """
        {
          "five_hour":        { "utilization": 42.5, "resets_at": "2026-05-18T10:00:00Z" },
          "seven_day":        { "utilization": 61.0, "resets_at": "2026-05-25T00:00:00Z" },
          "seven_day_sonnet": { "utilization": 28.0, "resets_at": "2026-05-25T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: json)
        let snapshot = try ClaudeUsageMapper.snapshot(from: dto)

        XCTAssertEqual(snapshot.providerId, .claude)
        XCTAssertEqual(snapshot.primaryWindow.percentUsed, 0.425, accuracy: 0.001)
        XCTAssertEqual(snapshot.secondaryWindow?.percentUsed, 0.610, accuracy: 0.001)
        XCTAssertEqual(snapshot.tertiaryWindow?.percentUsed, 0.280, accuracy: 0.001)
        XCTAssertNotNil(snapshot.primaryWindow.resetAt)
    }

    // 2. Missing five_hour → decoding error.
    func test_snapshot_throwsWhenFiveHourMissing() throws {
        let json = """
        {
          "seven_day": { "utilization": 61.0, "resets_at": "2026-05-25T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: json)
        XCTAssertThrowsError(try ClaudeUsageMapper.snapshot(from: dto)) { error in
            guard case ProviderError.decoding = error else {
                return XCTFail("Expected ProviderError.decoding, got \(error)")
            }
        }
    }

    // 3. Null utilization on five_hour → decoding error.
    func test_snapshot_throwsWhenUtilizationNull() throws {
        let json = """
        { "five_hour": { "resets_at": "2026-05-18T10:00:00Z" } }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: json)
        XCTAssertThrowsError(try ClaudeUsageMapper.snapshot(from: dto)) { error in
            guard case ProviderError.decoding = error else {
                return XCTFail("Expected ProviderError.decoding, got \(error)")
            }
        }
    }

    // 4. Missing optional windows → secondaryWindow and tertiaryWindow are nil.
    func test_snapshot_optionalWindowsAreNil() throws {
        let json = """
        { "five_hour": { "utilization": 10.0, "resets_at": null } }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: json)
        let snapshot = try ClaudeUsageMapper.snapshot(from: dto)

        XCTAssertNil(snapshot.secondaryWindow)
        XCTAssertNil(snapshot.tertiaryWindow)
        XCTAssertNil(snapshot.primaryWindow.resetAt)
    }
}

// MARK: - OpenAI status-only snapshot tests

// OpenAI is a connected-status provider (issue #9): its old billing dashboard
// endpoints reject standard `sk-` API keys, so Notchy verifies the key is live
// and reports an "Active" status rather than a fabricated quota %.
final class OpenAIStatusOnlyTests: XCTestCase {

    func test_openai_connectedSnapshot_isStatusOnly() {
        let snapshot = ServiceUsageSnapshot.connected(providerId: .openai)
        XCTAssertEqual(snapshot.providerId, .openai)
        XCTAssertTrue(snapshot.isStatusOnly)
        XCTAssertFalse(snapshot.showsPercentBar)
        XCTAssertEqual(snapshot.shortLabel, "Active")
    }

    func test_openai_connectedSnapshot_hasNoSecondaryWindows() {
        let snapshot = ServiceUsageSnapshot.connected(providerId: .openai)
        XCTAssertNil(snapshot.secondaryWindow)
        XCTAssertNil(snapshot.tertiaryWindow)
    }
}

// MARK: - ClaudeOAuthCredential Parsing Tests

final class ClaudeOAuthCredentialTests: XCTestCase {

    // 14. Standard claudeAiOauthToken field.
    func test_parse_claudeAiOauthToken_field() {
        let json = #"{"claudeAiOauthToken":"tok-abc123","expiresAt":9999999999999}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertEqual(cred?.accessToken, "tok-abc123")
    }

    // 15. Falls back to accessToken field.
    func test_parse_accessToken_field() {
        let json = #"{"accessToken":"sk-ant-oauth01XYZ"}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertEqual(cred?.accessToken, "sk-ant-oauth01XYZ")
    }

    // 16. Falls back to token field.
    func test_parse_token_field() {
        let json = #"{"token":"raw-token-value"}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertEqual(cred?.accessToken, "raw-token-value")
    }

    // 17. Empty string token → nil.
    func test_parse_emptyToken_returnsNil() {
        let json = #"{"claudeAiOauthToken":""}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeOAuthCredential.parse(from: json))
    }

    // 18. No token field → nil.
    func test_parse_missingToken_returnsNil() {
        let json = #"{"expiresAt":9999999999999}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeOAuthCredential.parse(from: json))
    }

    // 19. Invalid JSON → nil.
    func test_parse_malformedJSON_returnsNil() {
        XCTAssertNil(ClaudeOAuthCredential.parse(from: Data("not json".utf8)))
    }

    // 20. Expiry as millisecond Unix timestamp (> 1e12).
    func test_parse_expiryMilliseconds() {
        // 9_999_999_999_000 ms = 9_999_999_999 s  (far future)
        let json = #"{"claudeAiOauthToken":"t","expiresAt":9999999999000}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertNotNil(cred?.expiresAt)
        XCTAssertFalse(cred?.isLikelyExpired ?? true)
    }

    // 21. Expiry as second Unix timestamp.
    func test_parse_expirySeconds() {
        let future = Date().timeIntervalSince1970 + 3600
        let json = "{\"claudeAiOauthToken\":\"t\",\"expiresAt\":\(future)}".data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertFalse(cred?.isLikelyExpired ?? true, "Token expires in 1 hour, should not be expired")
    }

    // 22. Expired token → isLikelyExpired is true.
    func test_parse_expiredToken_isLikelyExpired() {
        let past = Date().timeIntervalSince1970 - 3600
        let json = "{\"claudeAiOauthToken\":\"t\",\"expiresAt\":\(past)}".data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertTrue(cred?.isLikelyExpired ?? false)
    }

    // 23. ISO-8601 expiry string.
    func test_parse_expiryISO8601String() {
        let json = #"{"claudeAiOauthToken":"t","expiresAt":"2099-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertNotNil(cred?.expiresAt)
        XCTAssertFalse(cred?.isLikelyExpired ?? true)
    }

    // 24. No expiresAt → expiresAt is nil, isLikelyExpired is false (assume valid).
    func test_parse_noExpiry_notExpired() {
        let json = #"{"claudeAiOauthToken":"t"}"#.data(using: .utf8)!
        let cred = ClaudeOAuthCredential.parse(from: json)
        XCTAssertNil(cred?.expiresAt)
        XCTAssertFalse(cred?.isLikelyExpired ?? true)
    }
}

// MARK: - NotificationService high-water mark tests

final class NotificationServiceEvaluateTests: XCTestCase {

    private let defaultsKey = "com.notchylimit.NotificationService.highWaterMark"
    private let thresholds: [Double] = [0.25, 0.5, 0.75, 0.9]

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func snapshot(percent: Double) -> ServiceUsageSnapshot {
        ServiceUsageSnapshot(
            providerId: .claude,
            primaryWindow: UsageWindow(type: .session, percentUsed: percent,
                                       lastUpdated: Date()),
            secondaryWindow: nil,
            tertiaryWindow: nil,
            capturedAt: Date()
        )
    }

    private func mark() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    // 5a. Skipping thresholds: jumping from 0% to 76% records the 75% mark.
    func test_skippedThresholds_recordsHighestOnly() {
        let service = NotificationService.shared
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0.75,
                       "mark should be 0.75 — the highest crossed threshold")
    }

    // 5b. Repeated polls at the same usage level fire nothing extra.
    func test_repeatedEvaluate_doesNotReFire() {
        let service = NotificationService.shared
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        let markAfterFirst = mark()
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark(), markAfterFirst,
                       "mark must not change on a second evaluate at the same usage")
    }

    // 5c. Crossing a higher threshold on a later poll fires once more.
    func test_newHigher_threshold_fires() {
        let service = NotificationService.shared
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0.75)
        service.evaluate(snapshot: snapshot(percent: 0.92),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0.9,
                       "mark should advance to 0.9 when usage crosses 90%")
    }

    // 5d. Window reset: usage drops below the lowest threshold → mark clears.
    func test_windowReset_clearsMark() {
        let service = NotificationService.shared
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0.75)
        service.evaluate(snapshot: snapshot(percent: 0.05),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0,
                       "mark should clear to 0 when usage drops below lowest threshold")
        service.evaluate(snapshot: snapshot(percent: 0.76),
                         thresholds: thresholds, providerId: .claude)
        XCTAssertEqual(mark()["claude:session"], 0.75,
                       "mark should advance again after window reset")
    }

    // 6. KeychainStore round-trip: write → read → delete.
    func test_keychainStore_roundTrip() {
        let store = KeychainStore(service: "com.notchylimit.tests.\(UUID().uuidString)")
        let payload = "test-payload-\(UUID().uuidString)".data(using: .utf8)!
        store.set(account: "roundtrip", data: payload)
        let read = store.get(account: "roundtrip")
        XCTAssertEqual(read, payload)
        let deleted = store.delete(account: "roundtrip")
        XCTAssertTrue(deleted)
        XCTAssertNil(store.get(account: "roundtrip"))
    }
}

// MARK: - Burn-rate forecast tests

final class UsageForecastTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(_ pct: Double, resetIn: TimeInterval? = nil) -> UsageWindow {
        UsageWindow(type: .session, percentUsed: pct,
                    resetAt: resetIn.map { now.addingTimeInterval($0) })
    }

    // Rising usage projects a finite ETA; reset is far off so willResetFirst is false.
    func test_risingUsage_projectsFiniteETA() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-600), percent: 0.10),
            UsageSample(at: now, percent: 0.20),
        ]
        let f = UsageForecaster.project(samples: samples,
                                        current: window(0.20, resetIn: 36_000),
                                        now: now)
        XCTAssertNotNil(f)
        // remaining 0.8 at 0.10 per 600s → 4800s.
        XCTAssertEqual(f!.secondsToLimit, 4800, accuracy: 60)
        XCTAssertFalse(f!.willResetFirst)
    }

    // Slow rise but the window resets long before the limit → on track.
    func test_resetsBeforeLimit_setsWillResetFirst() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-3600), percent: 0.50),
            UsageSample(at: now, percent: 0.55),
        ]
        let f = UsageForecaster.project(samples: samples,
                                        current: window(0.55, resetIn: 3600),
                                        now: now)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.willResetFirst)
    }

    func test_flatUsage_returnsNil() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-600), percent: 0.40),
            UsageSample(at: now, percent: 0.40),
        ]
        XCTAssertNil(UsageForecaster.project(samples: samples, current: window(0.40), now: now))
    }

    func test_fallingUsage_returnsNil() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-600), percent: 0.40),
            UsageSample(at: now, percent: 0.20),
        ]
        XCTAssertNil(UsageForecaster.project(samples: samples, current: window(0.20), now: now))
    }

    func test_alreadyAtLimit_returnsNil() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-600), percent: 0.90),
            UsageSample(at: now, percent: 1.0),
        ]
        XCTAssertNil(UsageForecaster.project(samples: samples, current: window(1.0), now: now))
    }

    func test_tooFewSamples_returnsNil() {
        XCTAssertNil(UsageForecaster.project(samples: [UsageSample(at: now, percent: 0.2)],
                                             current: window(0.2), now: now))
    }

    // Less than 60s between first and last sample is too little signal.
    func test_tooShortElapsed_returnsNil() {
        let samples = [
            UsageSample(at: now.addingTimeInterval(-30), percent: 0.10),
            UsageSample(at: now, percent: 0.20),
        ]
        XCTAssertNil(UsageForecaster.project(samples: samples, current: window(0.20), now: now))
    }
}

// MARK: - Staleness tests

final class StaleDetectionTests: XCTestCase {

    private func appState(pollInterval: TimeInterval = 300) -> AppState {
        let app = AppState()
        app.pollIntervalSeconds = pollInterval
        return app
    }

    private func snapshot(ageSeconds: TimeInterval) -> ServiceUsageSnapshot {
        ServiceUsageSnapshot(
            providerId: .claude,
            primaryWindow: UsageWindow(type: .session, percentUsed: 0.3),
            capturedAt: Date().addingTimeInterval(-ageSeconds)
        )
    }

    func test_freshSnapshot_isNotStale() {
        let app = appState()
        app.latestSnapshot = snapshot(ageSeconds: 0)
        XCTAssertFalse(app.isActiveStale)
    }

    func test_oldSnapshot_isStale() {
        let app = appState(pollInterval: 300)   // stale threshold = 750s
        app.latestSnapshot = snapshot(ageSeconds: 1000)
        XCTAssertTrue(app.isActiveStale)
    }

    func test_noSnapshot_isNotStale() {
        XCTAssertFalse(appState().isActiveStale)
    }
}

// MARK: - Pace (trajectory) alert tests

final class NotificationServicePaceTests: XCTestCase {

    private let defaultsKey = "com.notchylimit.NotificationService.highWaterMark"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func mark() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    private func forecast(willResetFirst: Bool) -> UsageForecast {
        UsageForecast(ratePerHour: 0.1, secondsToLimit: 3600,
                      eta: Date().addingTimeInterval(3600), willResetFirst: willResetFirst)
    }

    func test_onPaceToExhaust_armsOnce() {
        NotificationService.shared.evaluatePace(forecast: forecast(willResetFirst: false),
                                                providerId: .claude)
        XCTAssertEqual(mark()["claude:pace"], 1)
    }

    func test_onTrack_doesNotArm() {
        NotificationService.shared.evaluatePace(forecast: forecast(willResetFirst: true),
                                                providerId: .claude)
        XCTAssertNil(mark()["claude:pace"])
    }

    func test_disarmsWhenBackOnTrack() {
        let service = NotificationService.shared
        service.evaluatePace(forecast: forecast(willResetFirst: false), providerId: .claude)
        XCTAssertEqual(mark()["claude:pace"], 1)
        service.evaluatePace(forecast: forecast(willResetFirst: true), providerId: .claude)
        XCTAssertEqual(mark()["claude:pace"], 0)
    }

    func test_nilForecast_doesNotArm() {
        NotificationService.shared.evaluatePace(forecast: nil, providerId: .codex)
        XCTAssertNil(mark()["codex:pace"])
    }
}
