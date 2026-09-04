import Foundation
import Testing
@testable import UsageMenuBar

struct CodexLimitsTests {
    @Test func claudeAccountUsageDecodesAccountWideWindows() throws {
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

        #expect(usage.five_hour?.utilization == 23.5)
        #expect(usage.seven_day?.utilization == 41.0)
    }

    @Test func weeklyOnlySnapshotDecodesAndMapsPrimaryAsWeekly() throws {
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

        #expect(limits.fiveHourWindow == nil)
        #expect(limits.weeklyWindow?.used_percent == 12)
        #expect(limits.weeklyWindow?.window_minutes == 10080)
    }

    @Test @MainActor func validClaudeTokenFetchesWithoutRefreshingCLI() async throws {
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in ClaudeUsageHTTPResponse(statusCode: 200, data: Self.accountUsage()) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        #expect(refreshCount == 0)
        #expect(store.claude?.fiveHourPct == 23.5)
        #expect(store.claudeState == .ready)
    }

    @Test @MainActor func expiredTokenRefreshesCLIAndRereadsCredentials() async throws {
        var credentialReadCount = 0
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: {
                credentialReadCount += 1
                return Self.credentials(expiresAt: credentialReadCount == 1 ? 1 : 2_000_000_000_000)
            },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in ClaudeUsageHTTPResponse(statusCode: 200, data: Self.accountUsage()) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        #expect(refreshCount == 1)
        #expect(credentialReadCount == 2)
        #expect(store.claudeState == .ready)
    }

    @Test @MainActor func unauthorizedRefreshesAndRetriesOnce() async throws {
        var fetchCount = 0
        var refreshCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { refreshCount += 1; return .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                return ClaudeUsageHTTPResponse(
                    statusCode: fetchCount == 1 ? 401 : 200,
                    data: Self.accountUsage()
                )
            },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        #expect(refreshCount == 1)
        #expect(fetchCount == 2)
        #expect(store.claudeState == .ready)
    }

    @Test @MainActor func failedSilentRefreshOffersLoginAndPreservesSnapshot() async throws {
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 1, refreshToken: nil) },
            refreshCLI: { .loginRequired },
            fetchUsage: { _ in throw URLError(.badServerResponse) },
            now: Date.init,
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)
        let snapshotPercentage = store.claude?.fiveHourPct

        await store.refreshClaudeAccountUsage()

        #expect(store.claude?.fiveHourPct == snapshotPercentage)
        #expect(store.claudeState == .loginRequired)
        #expect(store.claudeState.offersLogin)
    }

    @Test @MainActor func concurrentRefreshesShareSingleRequest() async throws {
        var fetchCount = 0
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                try await Task.sleep(nanoseconds: 30_000_000)
                return ClaudeUsageHTTPResponse(statusCode: 200, data: Self.accountUsage())
            },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        async let first: Void = store.refreshClaudeAccountUsage()
        async let second: Void = store.refreshClaudeAccountUsage()
        _ = await (first, second)

        #expect(fetchCount == 1)
    }

    @Test @MainActor func networkFailureGetsOfflineState() async throws {
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in throw URLError(.notConnectedToInternet) },
            now: { Date(timeIntervalSince1970: 1_000_000_000) },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()

        #expect(store.claudeState == .networkUnavailable)
    }

    @Test @MainActor func signInUsesInjectedLauncher() {
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

        #expect(launchCount == 1)
    }

    @Test @MainActor func successfulAccountRequestBacksOffForFiveMinutes() async {
        var fetchCount = 0
        var now = Date(timeIntervalSince1970: 1_000_000_000)
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                return ClaudeUsageHTTPResponse(statusCode: 200, data: Self.accountUsage())
            },
            now: { now },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)

        await store.refreshClaudeAccountUsage()
        now = now.addingTimeInterval(60)
        await store.refreshClaudeAccountUsage()
        #expect(fetchCount == 1)

        now = now.addingTimeInterval(240)
        await store.refreshClaudeAccountUsage()
        #expect(fetchCount == 2)
    }

    @Test @MainActor func rateLimitUsesRetryAfterAndShowsSnapshot() async {
        var fetchCount = 0
        var now = Date(timeIntervalSince1970: 1_000_000_000)
        let dependencies = QuotaDependencies(
            readCredentials: { Self.credentials(expiresAt: 2_000_000_000_000) },
            refreshCLI: { .refreshed },
            fetchUsage: { _ in
                fetchCount += 1
                return ClaudeUsageHTTPResponse(statusCode: 429, data: Data(), retryAfter: 600)
            },
            now: { now },
            launchLogin: {}
        )
        let store = QuotaStore(dependencies: dependencies, startImmediately: false)
        // Whatever the local snapshot gave us at init (possibly nothing, if the
        // dashboard has not written real numbers yet) must survive the 429.
        let snapshotBefore = store.claude?.fiveHourPct

        await store.refreshClaudeAccountUsage()
        #expect(store.claudeState == .rateLimited)
        #expect(store.claude?.fiveHourPct == snapshotBefore)

        now = now.addingTimeInterval(599)
        await store.refreshClaudeAccountUsage()
        #expect(fetchCount == 1)
        now = now.addingTimeInterval(1)
        await store.refreshClaudeAccountUsage()
        #expect(fetchCount == 2)
    }

    private static func credentials(expiresAt: Double, refreshToken: String? = "refresh") -> Data {
        let refreshField = refreshToken.map { "\"refreshToken\": \"\($0)\"," } ?? ""
        return Data("""
        {"claudeAiOauth":{"accessToken":"access",\(refreshField)"expiresAt":\(expiresAt)}}
        """.utf8)
    }

    private static func accountUsage() -> Data {
        Data("""
        {
          "five_hour":{"utilization":23.5,"resets_at":"2026-07-18T18:00:00Z"},
          "seven_day":{"utilization":41.0,"resets_at":"2026-07-24T00:00:00Z"}
        }
        """.utf8)
    }
}
