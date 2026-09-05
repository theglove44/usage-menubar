import Foundation
import Testing
@testable import UsageMenuBar

struct ModelUsageTests {
    private let now = Date(timeIntervalSince1970: 1_788_588_000)

    @Test @MainActor func preferencesPersistAndKeepAnEscapeWhenAllProvidersAreDisabled() throws {
        let name = "UsageMenuBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MenuBarPreferences(defaults: defaults)
        #expect(preferences.visibleProviders.count == 3)
        #expect(preferences.showSessionRunway)
        preferences.provider = .claude
        preferences.setEnabled(false, for: .claude)
        #expect(preferences.effectiveProvider == .codex)
        preferences.showSessionRunway = false
        for provider in MenuBarProvider.allCases { preferences.setEnabled(false, for: provider) }
        let restored = MenuBarPreferences(defaults: defaults)
        #expect(restored.effectiveProvider == nil)
        #expect(restored.visibleProviders.isEmpty)
        #expect(!restored.showSessionRunway)
        restored.setEnabled(true, for: .grok)
        #expect(restored.effectiveProvider == .grok)
    }

    @Test @MainActor func disabledClaudeDoesNotReadCredentialsOrRequestUsage() async throws {
        let name = "UsageMenuBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MenuBarPreferences(defaults: defaults)
        preferences.setEnabled(false, for: .claude)
        var credentialReads = 0
        let dependencies = QuotaDependencies(
            readCredentials: { credentialReads += 1; return nil },
            refreshCLI: { .loginRequired },
            fetchUsage: { _ in Issue.record("Disabled provider made an HTTP request"); throw URLError(.badURL) },
            now: { now }, launchLogin: {})
        let store = QuotaStore(dependencies: dependencies, startImmediately: false, preferences: preferences)
        await store.refreshClaudeAccountUsage()
        #expect(credentialReads == 0)
        preferences.setEnabled(true, for: .claude)
        await store.refreshClaudeAccountUsage()
        #expect(credentialReads == 1)
        preferences.setEnabled(false, for: .claude)
        await store.refreshClaudeAccountUsage()
        #expect(credentialReads == 1)
    }

    @Test func codexCountsRequestsOnceAndTracksModelSwitches() {
        var parser = ModelUsageParser(provider: .codex, sessionID: "session")
        consume(&parser, ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]])
        let first = codexEvent(totalInput: 1_000, totalOutput: 100, input: 1_000, cached: 600, write: 100, output: 100)
        consume(&parser, first)
        consume(&parser, first)
        consume(&parser, ["type": "turn_context", "payload": ["model": "gpt-5.6-terra"]])
        consume(&parser, codexEvent(totalInput: 2_000, totalOutput: 200, input: 1_000, cached: 800, write: 0, output: 100))
        #expect(parser.events.count == 2)
        #expect(parser.events[0].tokens == UsageTokens(input: 300, cachedInput: 600, cacheWrite: 100, output: 100))
        #expect(parser.events[1].model == "gpt-5.6-terra")
        #expect(parser.events.reduce(Int64(0)) { $0 + $1.tokens.total } == 2_200)
    }

    @Test func codexKeepsBaselineOutsideWindowAndHandlesCounterReset() {
        var parser = ModelUsageParser(provider: .codex, sessionID: "session")
        var first = codexEvent(totalInput: 9_000, totalOutput: 900, input: 1_000, cached: 0, write: 0, output: 100)
        first["timestamp"] = now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970
        consume(&parser, first)
        consume(&parser, codexEvent(totalInput: 100, totalOutput: 10, input: 100, cached: 0, write: 0, output: 10))
        #expect(parser.events.count == 1)
        #expect(parser.events[0].tokens.total == 110)
        #expect(parser.events[0].model == "Unknown model")
    }

    @Test func claudeDeduplicatesStreamingMessagesAndDistinguishesCacheDurations() {
        var parser = ModelUsageParser(provider: .claude, sessionID: "session")
        consume(&parser, claudeEvent(output: 10))
        consume(&parser, claudeEvent(output: 50))
        let report = ModelUsageReport(events: parser.events + parser.events)
        let rows = report.rows(since: now.addingTimeInterval(-10), until: now)
        #expect(rows.count == 1)
        #expect(rows[0].tokens == UsageTokens(input: 20, cachedInput: 100, cacheWrite: 30, cacheWriteHour: 70, output: 50))
        #expect(abs((rows[0].cost ?? 0) - 0.0022875) < 0.00000001)
    }

    @Test func grokUsesPerModelPerTurnUsageAndDoesNotAddReasoningTwice() {
        var parser = ModelUsageParser(provider: .grok, sessionID: "fallback")
        let object: [String: Any] = ["timestamp": now.timeIntervalSince1970, "params": [
            "sessionId": "session", "update": ["sessionUpdate": "turn_completed", "prompt_id": "turn",
                "usage": ["inputTokens": 999_999, "modelUsage": ["grok-4.6-build": [
                    "inputTokens": 1_000, "cachedReadTokens": 800, "outputTokens": 100, "reasoningTokens": 60
                ]]]]]]
        consume(&parser, object)
        consume(&parser, object)
        let rows = ModelUsageReport(events: parser.events).rows(since: now.addingTimeInterval(-1), until: now)
        #expect(rows[0].tokens.total == 1_100)
        #expect(rows[0].tokens.input == 200)
        #expect(abs((rows[0].cost ?? 0) - 0.0014) < 0.00000001)
    }

    @Test func pricesMatchVerifiedRatesAndNeverGuessUnknownVariants() throws {
        let tokens = UsageTokens(input: 1_000_000, cachedInput: 1_000_000, cacheWrite: 1_000_000, output: 1_000_000)
        #expect(try #require(ModelPricing.rate(for: "gpt-5.6-sol")).cost(tokens) == 29.4)
        #expect(try #require(ModelPricing.rate(for: "gpt-6-astra")).cost(tokens) == 73.5)
        #expect(ModelPricing.rate(for: "claude-opus-4-6-20260101") != nil)
        #expect(ModelPricing.rate(for: "gpt-5.6-sol-2026-08-21") != nil)
        #expect(ModelPricing.rate(for: "gpt-5.6-sol-secret-variant") == nil)
        #expect(ModelPricing.rate(for: "codex-auto-review") == nil)
        #expect(ModelPricing.rate(for: "grok-4.7") == nil)
    }

    @Test func datesRejectFutureRecordsAndTodayUsesLocalMidnight() {
        var parser = ModelUsageParser(provider: .claude, sessionID: "session")
        var future = claudeEvent(output: 10)
        future["timestamp"] = now.addingTimeInterval(60).timeIntervalSince1970
        consume(&parser, future)
        #expect(parser.events.isEmpty)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        #expect(UsagePeriod.today.start(now: now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(UsagePeriod.week.start(now: now) == now.addingTimeInterval(-7 * 86_400))
    }

    @Test func malformedCountsCannotBecomeNegativeCostsOrDoubleCachedInput() {
        var parser = ModelUsageParser(provider: .codex, sessionID: "session")
        consume(&parser, codexEvent(totalInput: 100, totalOutput: 10, input: 100, cached: 300, write: 200, output: -10))
        #expect(parser.events[0].tokens == UsageTokens(cachedInput: 100))
    }

    @Test func scannerReadsFixturesHandlesPartialLinesAndRefreshesChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = try JSONSerialization.data(withJSONObject: claudeEvent(output: 10))
        data.append(Data("\n{broken\n".utf8))
        try data.write(to: file)
        let scanner = ModelUsageScanner(roots: [.claude: [root, root]])
        let first = await scanner.scan(provider: .claude, now: now)
        #expect(first.filesRead == 1)
        #expect(first.incompleteFiles == 1)
        #expect(first.events.count == 1)
        try JSONSerialization.data(withJSONObject: claudeEvent(output: 50)).write(to: file)
        let second = await scanner.scan(provider: .claude, now: now)
        #expect(second.incompleteFiles == 0)
        #expect(second.events[0].tokens.output == 50)
        let missing = await scanner.scan(provider: .grok, now: now)
        #expect(!missing.sourceAvailable)
    }

    private func consume(_ parser: inout ModelUsageParser, _ object: [String: Any]) {
        parser.consume(object, since: now.addingTimeInterval(-30 * 86_400), now: now)
    }

    private func claudeEvent(output: Int) -> [String: Any] {
        ["type": "assistant", "timestamp": now.timeIntervalSince1970,
         "message": ["id": "message-one", "model": "claude-opus-5", "usage": [
            "input_tokens": 20, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 100,
            "cache_creation": ["ephemeral_1h_input_tokens": 70, "ephemeral_5m_input_tokens": 30],
            "output_tokens": output]]]
    }

    private func codexEvent(totalInput: Int, totalOutput: Int, input: Int, cached: Int, write: Int, output: Int) -> [String: Any] {
        ["timestamp": now.timeIntervalSince1970, "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": totalInput, "output_tokens": totalOutput, "total_tokens": totalInput + totalOutput],
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write,
                                 "output_tokens": output, "reasoning_output_tokens": 50]]]]
    }
}
