import Foundation
import Testing
@testable import UsageMenuBar

struct SessionRunwayTests {
    @Test func recentTranscriptWithoutProcessIsNotActiveEvenAfterFileChange() async {
        let fixture = RunwayFixture()
        let firstTime = fixture.now.addingTimeInterval(-10)
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-recent.jsonl")
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: firstTime,
            size: 1,
            data: codexTranscript(id: "recent-id", cwd: "/workspace/runway", prompt: "Fix the runway", timestamp: firstTime)
        )

        let scanner = makeScanner(fixture)
        let first = await scanner.scan()
        #expect(first.rows.first?.state == .openIdle)
        #expect(!(first.rows.first?.evidence.contains(.transcriptOpenByProcess) ?? true))

        let secondTime = fixture.now
        fixture.now = secondTime
        fixture.update(
            path: path,
            modifiedAt: secondTime,
            size: 2,
            data: codexTranscript(id: "recent-id", cwd: "/workspace/runway", prompt: "Fix the runway", timestamp: secondTime)
        )

        let second = await scanner.scan()
        #expect(second.rows.first?.state == .openIdle)
        #expect(second.rows.first?.state != .activeWorking)
        #expect(second.rows.first?.evidence.contains(.fileChanged) ?? false)
    }

    @Test func historicalTranscriptHiddenButOpenPathBypassesLookback() async {
        let fixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-old.jsonl")
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: fixture.now.addingTimeInterval(-17 * 60 * 60),
            size: 1,
            data: codexTranscript(id: "old-id", cwd: "/workspace/old", prompt: "Old work", timestamp: fixture.now.addingTimeInterval(-17 * 60 * 60))
        )

        let scanner = makeScanner(fixture)
        let hidden = await scanner.scan()
        #expect(hidden.rows.isEmpty)
        #expect(hidden.hiddenHistoricalCount == 1)
        #expect(hidden.diagnostics.hiddenHistoricalCount == 1)

        fixture.processSnapshot = SessionRunwayProcessSnapshot(
            openTranscriptPaths: [path.standardizedFileURL.path],
            liveProviders: [.codex],
            liveSessionIDs: [],
            available: true
        )
        let live = await scanner.scan()
        #expect(live.rows.count == 1)
        #expect(live.rows.first?.state == .activeWorking)
        #expect(live.hiddenHistoricalCount == 0)
    }

    @Test func historicalTranscriptCanBeKeptBySessionRegistryID() async {
        let fixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-registry.jsonl")
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: fixture.now.addingTimeInterval(-2 * 60 * 60),
            size: 1,
            data: codexTranscript(id: "registry-id", cwd: "/workspace/registry", prompt: "Registry work", timestamp: fixture.now.addingTimeInterval(-2 * 60 * 60))
        )
        fixture.processSnapshot = SessionRunwayProcessSnapshot(
            openTranscriptPaths: [],
            liveProviders: [.codex],
            liveSessionIDs: ["registry-id"],
            available: true
        )

        let snapshot = await makeScanner(fixture).scan()
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.state == .activeWorking)
        #expect(snapshot.rows.first?.evidence.contains(.transcriptOpenByProcess) ?? false)
    }

    @Test func futureEventTimestampIsRejectedAndCannotMakeRowActive() async {
        let fixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-future.jsonl")
        let future = fixture.now.addingTimeInterval(10 * 60)
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: fixture.now.addingTimeInterval(-10),
            size: 1,
            data: codexTranscript(id: "future-id", cwd: "/workspace/future", prompt: "Future event", timestamp: future)
        )

        let snapshot = await makeScanner(fixture).scan()
        #expect(snapshot.diagnostics.futureTimestampCount == 1)
        #expect(snapshot.rows.first?.state == .openIdle)
        #expect(!(snapshot.rows.first?.evidence.contains(.recentEvent) ?? true))
        #expect(snapshot.rows.first?.state != .activeWorking)
    }

    @Test func futureFileTimestampProducesUnknownState() async {
        let fixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-clock-skew.jsonl")
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: fixture.now.addingTimeInterval(10 * 60),
            size: 1,
            data: Data()
        )

        let snapshot = await makeScanner(fixture).scan()
        #expect(snapshot.rows.first?.state == .unknown)
        #expect(snapshot.rows.first?.state != .activeWorking)
    }

    @Test func titleFallbackOrderAndCompaction() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var rules = SessionRunwayRules()
        rules.clockSkewTolerance = 120

        let stateTitleData = codexTranscript(
            id: "codex-state-id",
            cwd: "/workspace/state-project",
            prompt: "A prompt that should lose to state title",
            timestamp: now
        )
        let stateTitle = SessionRunwayParser.parse(
            provider: .codex,
            url: URL(fileURLWithPath: "/fixture/rollout-state.jsonl"),
            prefix: stateTitleData,
            tail: stateTitleData,
            fileModifiedAt: now,
            now: now,
            rules: rules,
            codexTitles: SessionRunwayCodexTitleLookup { _, _ in "State title" }
        )
        #expect(stateTitle?.title == "State title")

        let prompt = SessionRunwayParser.parse(
            provider: .codex,
            url: URL(fileURLWithPath: "/fixture/rollout-prompt.jsonl"),
            prefix: codexTranscript(id: "prompt-id", cwd: "/workspace/prompt-project", prompt: "Implement the local session runway", timestamp: now),
            tail: nil,
            fileModifiedAt: now,
            now: now,
            rules: rules
        )
        #expect(prompt?.title == "Implement the local session runway")

        let claude = SessionRunwayParser.parse(
            provider: .claudeCode,
            url: URL(fileURLWithPath: "/fixture/claude.jsonl"),
            prefix: Data("""
            {"sessionId":"claude-id","cwd":"/workspace/claude-project","type":"custom-title","customTitle":"  Claude   cockpit  "}
            """.utf8),
            tail: nil,
            fileModifiedAt: now,
            now: now,
            rules: rules
        )
        #expect(claude?.title == "Claude cockpit")

        let genericPrompt = SessionRunwayParser.parse(
            provider: .claudeCode,
            url: URL(fileURLWithPath: "/fixture/claude-generic.jsonl"),
            prefix: Data("""
            {"sessionId":"generic-id","cwd":"/workspace/generic-project","type":"user","message":{"role":"user","content":"continue"}}
            """.utf8),
            tail: nil,
            fileModifiedAt: now,
            now: now,
            rules: rules
        )
        #expect(genericPrompt?.title == "generic-project")

        let long = SessionRunwayParser.compactTitle(String(repeating: "x", count: 80), fallback: "fallback")
        #expect(long.count == 48)
        #expect(long.hasSuffix("…"))
    }

    @Test func parentAndSubagentProduceOneRow() async {
        let fixture = RunwayFixture()
        let parent = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-parent-id.jsonl")
        let child = URL(fileURLWithPath: "/fixture/codex/sessions/parent-id/subagents/rollout-child-id.jsonl")
        let modifiedAt = fixture.now.addingTimeInterval(-5)
        fixture.add(
            provider: .codex,
            url: parent,
            modifiedAt: modifiedAt,
            size: 1,
            data: codexTranscript(id: "parent-id", cwd: "/workspace/grouped", prompt: "Parent task", timestamp: modifiedAt)
        )
        fixture.add(
            provider: .codex,
            url: child,
            modifiedAt: modifiedAt,
            size: 1,
            data: codexTranscript(id: "child-id", cwd: "/workspace/grouped", prompt: "Subagent task", timestamp: modifiedAt)
        )

        let snapshot = await makeScanner(fixture).scan()
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.sessionID == "parent-id")
        #expect(snapshot.rows.first?.childSessionCount == 1)
        #expect(snapshot.diagnostics.groupedSubagentCount == 1)
    }

    @Test func observedBurnMathAndCodexDelta() async {
        #expect(SessionRunwayBurnMath.tokensPerHour(deltaTokens: 100, interval: 10) == 36_000)
        #expect(SessionRunwayBurnMath.providerShare(deltaTokens: 25, providerDelta: 100) == 0.25)
        #expect(SessionRunwayBurnMath.tokensPerHour(deltaTokens: 100, interval: 0) == nil)
        #expect(SessionRunwayBurnMath.providerShare(deltaTokens: 25, providerDelta: 0) == nil)

        let fixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-burn.jsonl")
        fixture.add(
            provider: .codex,
            url: path,
            modifiedAt: fixture.now.addingTimeInterval(-5),
            size: 1,
            data: codexTranscript(id: "burn-id", cwd: "/workspace/burn", prompt: "Measure burn", timestamp: fixture.now, totalTokens: 100)
        )
        let scanner = makeScanner(fixture)
        let first = await scanner.scan()
        #expect(first.rows.first?.burn.state == .measuring)

        let secondTime = fixture.now.addingTimeInterval(60)
        fixture.now = secondTime
        fixture.update(
            path: path,
            modifiedAt: secondTime,
            size: 2,
            data: codexTranscript(id: "burn-id", cwd: "/workspace/burn", prompt: "Measure burn", timestamp: secondTime, totalTokens: 300)
        )
        let second = await scanner.scan()
        #expect(second.rows.first?.burn.state == .observed)
        #expect(second.rows.first?.burn.observedTokenDelta == 200)
        #expect(abs((second.rows.first?.burn.observedTokensPerHour ?? 0) - 12_000) < 0.01)
        #expect(second.rows.first?.burn.shareOfObservedProviderBurn == 1)
    }

    @Test func emptySourcesAndUnknownCandidateStayHonest() async {
        let emptyFixture = RunwayFixture()
        let emptySnapshot = await makeScanner(emptyFixture).scan()
        #expect(emptySnapshot.rows.isEmpty)
        #expect(emptySnapshot.health[.codex] == .missing)
        #expect(emptySnapshot.health[.claudeCode] == .missing)

        let unknownFixture = RunwayFixture()
        let path = URL(fileURLWithPath: "/fixture/codex/sessions/rollout-unknown.jsonl")
        unknownFixture.add(
            provider: .codex,
            url: path,
            modifiedAt: unknownFixture.now.addingTimeInterval(10 * 60),
            size: 0,
            data: Data()
        )
        let unknownSnapshot = await makeScanner(unknownFixture).scan()
        #expect(unknownSnapshot.rows.first?.state == .unknown)
        #expect(unknownSnapshot.rows.first?.burn.state == .unsupported)
    }

    @Test func liveDiscoverySortsBeforeApplyingFileCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-runway-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let old = sessions.appendingPathComponent("rollout-old.jsonl")
        let recent = sessions.appendingPathComponent("rollout-recent.jsonl")
        try Data("{}\n".utf8).write(to: old)
        try Data("{}\n".utf8).write(to: recent)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 60 * 60)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-5)],
            ofItemAtPath: recent.path
        )

        var rules = SessionRunwayRules()
        rules.maxFilesPerProvider = 1
        let configuration = SessionRunwayConfiguration(
            codexSessionsRoot: sessions,
            codexStateDatabase: nil,
            claudeConfigRoots: []
        )
        let discovered = SessionRunwayLiveFileSystem.discover(
            provider: .codex,
            configuration: configuration,
            rules: rules,
            now: now
        )

        #expect(
            discovered.map { $0.standardizedFileURL.path }
                == [recent.standardizedFileURL.path]
        )
    }

    private func makeScanner(_ fixture: RunwayFixture, rules: SessionRunwayRules = SessionRunwayRules()) -> SessionRunwayScanner {
        let fileSystem = SessionRunwayFileSystem(
            discover: { provider, _, _, _ in fixture.files[provider] ?? [] },
            stat: { url in fixture.stats[url.standardizedFileURL.path] },
            readPrefix: { url, _ in fixture.data[url.standardizedFileURL.path] },
            readTail: { url, _ in fixture.data[url.standardizedFileURL.path] }
        )
        let processProbe = SessionRunwayProcessProbe(
            snapshot: { _, _ in fixture.processSnapshot }
        )
        return SessionRunwayScanner(
            configuration: fixture.configuration,
            fileSystem: fileSystem,
            processProbe: processProbe,
            titleStore: .none,
            rules: rules,
            clock: { fixture.now }
        )
    }
}

private final class RunwayFixture: @unchecked Sendable {
    let configuration = SessionRunwayConfiguration(
        codexSessionsRoot: URL(fileURLWithPath: "/fixture/codex/sessions", isDirectory: true),
        codexStateDatabase: nil,
        claudeConfigRoots: []
    )
    var now = Date(timeIntervalSince1970: 1_000_000_000)
    var files: [SessionRunwayProvider: [URL]] = [:]
    var stats: [String: SessionRunwayFileStat] = [:]
    var data: [String: Data] = [:]
    var processSnapshot = SessionRunwayProcessSnapshot.empty

    func add(provider: SessionRunwayProvider, url: URL, modifiedAt: Date, size: Int64, data: Data) {
        files[provider, default: []].append(url)
        update(path: url, modifiedAt: modifiedAt, size: size, data: data)
    }

    func update(path: URL, modifiedAt: Date, size: Int64, data: Data) {
        let key = path.standardizedFileURL.path
        stats[key] = SessionRunwayFileStat(modifiedAt: modifiedAt, size: size)
        self.data[key] = data
    }
}

private func codexTranscript(
    id: String,
    cwd: String,
    prompt: String,
    timestamp: Date,
    totalTokens: Int64? = nil
) -> Data {
    var lines = [
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}}",
        "{\"type\":\"event_msg\",\"timestamp\":\"\(iso8601(timestamp))\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(prompt)\"}}"
    ]
    if let totalTokens {
        lines.append("{\"type\":\"event_msg\",\"timestamp\":\"\(iso8601(timestamp))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(totalTokens)}}}}")
    }
    return Data(lines.joined(separator: "\n").utf8)
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
