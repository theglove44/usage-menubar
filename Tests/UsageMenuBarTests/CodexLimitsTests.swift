import XCTest
@testable import UsageMenuBar

final class CodexLimitsTests: XCTestCase {
    func testClaudeAccountUsageDecodesAccountWideWindows() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 23.5,
            "resets_at": "2026-07-18T18:00:00Z"
          },
          "seven_day": {
            "utilization": 41.0,
            "resets_at": "2026-07-24T00:00:00Z"
          }
        }
        """

        let usage = try JSONDecoder().decode(ClaudeAccountUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.five_hour?.utilization, 23.5)
        XCTAssertEqual(usage.seven_day?.utilization, 41.0)
    }

    func testWeeklyOnlySnapshotDecodesAndMapsPrimaryAsWeekly() throws {
        let json = """
        {
          "captured_at": "2026-07-16T05:53:17.192Z",
          "plan_type": "plus",
          "primary": {
            "used_percent": 12,
            "window_minutes": 10080,
            "resets_at": 1784785996
          },
          "secondary": null
        }
        """

        let limits = try JSONDecoder().decode(CodexLimits.self, from: Data(json.utf8))

        XCTAssertNil(limits.fiveHourWindow)
        XCTAssertEqual(limits.weeklyWindow?.used_percent, 12)
        XCTAssertEqual(limits.weeklyWindow?.window_minutes, 10080)
    }

    @MainActor
    func testValidClaudeTokenFetchesWithoutRefreshingCLI() async throws {
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in ClaudeUsageHTTPResponse(statusCode: 200, data: self.accountUsage()) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(store.claude?.fiveHourPct, 23.5)
        XCTAssertEqual(store.claudeState, .ready)
    }

    @MainActor
    func testExpiredTokenRefreshesCLIAndRereadsCredentials() async throws {
        var credentialReadCount = 0
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: {
                credentialReadCount += 1
                return self.credentials(expiresAt: credentialReadCount == 1 ? 1 : 2_000_000_000_000)
            },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in ClaudeUsageHTTPResponse(statusCode: 200, data: self.accountUsage()) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(credentialReadCount, 2)
        XCTAssertEqual(store.claudeState, .ready)
    }

    @MainActor
    func testUnauthorizedRefreshesAndRetriesOnce() async throws {
        var fetchCount = 0
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                return ClaudeUsageHTTPResponse(
                    statusCode: fetchCount == 1 ? 401 : 200,
                    data: self.accountUsage()
                )
            },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(store.claudeState, .ready)
    }

    @MainActor
    func testFailedSilentRefreshOffersLoginAndPreservesSnapshot() async throws {
        let dependencies = QuotaDependencies(
            readCredentials: { self.credentials(expiresAt: 1, refreshToken: nil) },
            refreshCLI: { .loginRequired },
            fetchUsage: { _ in throw URLError(.badServerResponse) },
            now: Date.init,
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)
        let snapshotPercentage = store.claude?.fiveHourPct

        await store.refreshClaudeAccountUsage()

        XCTAssertEqual(store.claude?.fiveHourPct, snapshotPercentage)
        XCTAssertEqual(store.claudeState, .loginRequired)
        XCTAssertTrue(store.claudeState.offersLogin)
    }

    @MainActor
    func testConcurrentRefreshesShareSingleRequest() async throws {
        var fetchCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                try await Task.sleep(nanoseconds: 30_000_000)
                return ClaudeUsageHTTPResponse(statusCode: 200, data: self.accountUsage())
            },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        async let first: Void = store.refreshClaudeAccountUsage()
        async let second: Void = store.refreshClaudeAccountUsage()
        _ = await (first, second)

        XCTAssertEqual(fetchCount, 1)
    }

    @MainActor
    func testNetworkFailureGetsOfflineState() async throws {
        let dependencies = QuotaDependencies(
            readCredentials: { self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in throw URLError(.notConnectedToInternet) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        XCTAssertEqual(store.claudeState, .networkUnavailable)
    }

    @MainActor
    func testSignInUsesInjectedLauncher() {
        var launchCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { nil },
            refreshCLI: { .loginRequired },
            fetchUsage: { _ in throw URLError(.badServerResponse) },
            now: Date.init,
            launchLogin: { launchCount += 1 }
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        store.signInToClaude()

        XCTAssertEqual(launchCount, 1)
    }

    private func credentials(expiresAt: Double, refreshToken: String? = "refresh") -> Data {
        let refreshField = refreshToken.map { "\"refreshToken\": \"\($0)\"," } ?? ""
        return Data("""
        {"claudeAiOauth":{"accessToken":"access",\(refreshField)"expiresAt":\(expiresAt)}}
        """.utf8)
    }

    private func accountUsage() -> Data {
        Data("""
        {
          "five_hour":{"utilization":23.5,"resets_at":"2026-07-18T18:00:00Z"},
          "seven_day":{"utilization":41.0,"resets_at":"2026-07-24T00:00:00Z"}
        }
        """.utf8)
    }
}
