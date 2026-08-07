import Foundation
import XCTest
@testable import UsageMenuBar

final class ClaudeSessionDiscoveryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testEncodedProjectPathDecodesAbsoluteProjectDirectory() {
        XCTAssertEqual(
            ClaudeProjectPath.decode("-Users-alice-Projects-demo"),
            "/Users/alice/Projects/demo"
        )
    }

    func testSessionIDExtractionHandlesMainAndSubagentLogPaths() {
        let sessionID = "06909792-d8fa-408c-bdb9-dd04b94e9ed2"
        let mainPath = "/tmp/projects/-Users-alice-Projects-demo/\(sessionID).jsonl"
        let subagentPath = "/tmp/projects/-Users-alice-Projects-demo/\(sessionID)/subagents/agent-a651ab1547f337155.jsonl"

        XCTAssertEqual(ClaudeSessionLogPath.sessionID(from: mainPath), sessionID)
        XCTAssertEqual(ClaudeSessionLogPath.sessionID(from: subagentPath), sessionID)
    }

    func testMalformedTranscriptLinesDoNotHideValidMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = "session-malformed-lines"
        let fixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-demo",
            filename: "\(sessionID).jsonl",
            contents: "not json\n{\"type\":\"assistant\",\"sessionId\":\"\(sessionID)\",\"cwd\":\"/Users/alice/Projects/demo\",\"timestamp\":\"2026-08-02T00:00:00Z\"}\n{broken\n"
        )

        let activities = discover(fixture.configRoot, now: now)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].sessionID, sessionID)
        XCTAssertEqual(activities[0].workspace, "/Users/alice/Projects/demo")
    }

    func testStaleTTLMarksClosedOldTranscriptStale() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = "session-stale"
        let fixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-demo",
            filename: "\(sessionID).jsonl",
            contents: "{\"sessionId\":\"\(sessionID)\",\"cwd\":\"/Users/alice/Projects/demo\",\"timestamp\":\"2026-08-02T00:00:00Z\"}\n",
            modificationDate: now.addingTimeInterval(-301)
        )

        let activities = discover(
            fixture.configRoot,
            now: now,
            configuration: ClaudeSessionDiscoveryConfiguration(
                staleAfter: 300,
                activeLogWindow: 30,
                sessionLookback: 365 * 24 * 60 * 60
            )
        )

        XCTAssertEqual(activities.first?.state, .stale)
        XCTAssertNil(activities.first?.pid)
    }

    func testInjectedProcessEvidenceMatchesLogAndExposesPIDTTY() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = "session-process-match"
        let fixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-demo",
            filename: "\(sessionID).jsonl",
            contents: "{\"sessionId\":\"\(sessionID)\",\"cwd\":\"/Users/alice/Projects/demo\",\"timestamp\":\"2026-08-02T00:00:00Z\"}\n",
            modificationDate: now.addingTimeInterval(-5)
        )
        let process = ClaudeProcessEvidence(
            pid: 4242,
            sessionID: sessionID,
            commandLine: "/opt/homebrew/bin/claude --resume \(sessionID)",
            workingDirectory: "/Users/alice/Projects/demo",
            tty: "ttys004",
            activity: .unknown
        )

        let activities = discover(fixture.configRoot, now: now, processes: [process])

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].pid, 4242)
        XCTAssertEqual(activities[0].tty, "ttys004")
        XCTAssertEqual(activities[0].state, .activeWorking)
        XCTAssertEqual(activities[0].confidence, .high)
    }

    func testClaudeProcessProbeReturnsEmptyOnPSFailureWithoutRealProcessCalls() {
        var executables: [String] = []
        var timeouts: [TimeInterval] = []

        let evidence = ClaudeProcessEvidenceSource.live { executable, _, timeout in
            executables.append(executable)
            timeouts.append(timeout)
            return nil
        }

        XCTAssertTrue(evidence.isEmpty)
        XCTAssertEqual(executables, ["/bin/ps"])
        XCTAssertEqual(timeouts.count, 1)
        XCTAssertGreaterThan(timeouts[0], 0)
        XCTAssertLessThanOrEqual(timeouts[0], 0.5)
    }

    func testClaudeProcessProbeKeepsPSEvidenceWhenLsofFails() {
        var executables: [String] = []
        let psOutput = Data("42 ttys001 S /opt/homebrew/bin/claude --resume session-probe\n".utf8)

        let evidence = ClaudeProcessEvidenceSource.live { executable, _, _ in
            executables.append(executable)
            return executable == "/bin/ps" ? psOutput : nil
        }

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].pid, 42)
        XCTAssertEqual(evidence[0].sessionID, "session-probe")
        XCTAssertNil(evidence[0].workingDirectory)
        XCTAssertEqual(executables, ["/bin/ps", "/usr/sbin/lsof"])
    }

    func testOpenIdleAndUnknownRemainExplicit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idleFixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-idle",
            filename: "session-idle.jsonl",
            contents: "{\"sessionId\":\"session-idle\",\"cwd\":\"/Users/alice/Projects/idle\"}\n",
            modificationDate: now.addingTimeInterval(-600)
        )
        let idleProcess = ClaudeProcessEvidence(
            pid: 4343,
            sessionID: "session-idle",
            workingDirectory: "/Users/alice/Projects/idle",
            tty: "ttys005",
            activity: .idle
        )

        let idle = discover(idleFixture.configRoot, now: now, processes: [idleProcess])
        XCTAssertEqual(idle.first?.state, .openIdle)

        let unknownFixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-unknown",
            filename: "session-unknown.jsonl",
            contents: "{\"sessionId\":\"session-unknown\",\"cwd\":\"/Users/alice/Projects/unknown\"}\n",
            modificationDate: now.addingTimeInterval(-30)
        )
        let unknown = discover(unknownFixture.configRoot, now: now)
        XCTAssertEqual(unknown.first?.state, .unknown)
    }

    func testSubagentLogsAttachAsMetadataAndDoNotCreateSeparateActivity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = "session-with-agent"
        let fixture = try makeFixture(
            projectDirectory: "-Users-alice-Projects-demo",
            filename: "\(sessionID).jsonl",
            contents: "{\"sessionId\":\"\(sessionID)\",\"cwd\":\"/Users/alice/Projects/demo\"}\n"
        )
        let subagentDirectory = fixture.projectsRoot
            .appendingPathComponent("-Users-alice-Projects-demo", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)
        let subagentPath = subagentDirectory.appendingPathComponent("agent-a1.jsonl")
        try "{\"sessionId\":\"\(sessionID)\",\"isSidechain\":true}\n".write(to: subagentPath, atomically: true, encoding: .utf8)

        let activities = discover(fixture.configRoot, now: now)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].subagentCount, 1)
        XCTAssertEqual(activities[0].badges, ["subagents"])
        XCTAssertEqual(activities[0].subagentLogPaths.count, 1)
        XCTAssertTrue(activities[0].subagentLogPaths[0].hasSuffix(
            "/projects/-Users-alice-Projects-demo/\(sessionID)/subagents/agent-a1.jsonl"
        ))
    }

    func testConfigDirectoryEnvironmentHonorsSingularAndColonSeparatedRoots() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let roots = ClaudeConfigDirectories.roots(
            environment: [
                "CLAUDE_CONFIG_DIR": "~/claude-primary",
                "CLAUDE_CONFIG_DIRS": "~/claude-secondary:/tmp/claude-third"
            ],
            homeDirectory: home
        )

        XCTAssertEqual(
            roots.map(\.path),
            ["/Users/alice/claude-primary", "/Users/alice/claude-secondary", "/tmp/claude-third"]
        )
    }

    private func discover(
        _ configRoot: URL,
        now: Date,
        configuration: ClaudeSessionDiscoveryConfiguration = ClaudeSessionDiscoveryConfiguration(
            sessionLookback: 365 * 24 * 60 * 60
        ),
        processes: [ClaudeProcessEvidence] = []
    ) -> [SessionActivity] {
        ClaudeSessionDiscovery(
            configRoots: [configRoot],
            configuration: configuration,
            now: { now },
            processEvidence: { processes }
        ).discover()
    }

    private func makeFixture(
        projectDirectory: String,
        filename: String,
        contents: String,
        modificationDate: Date? = nil
    ) throws -> (configRoot: URL, projectsRoot: URL, logPath: URL) {
        let configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-discovery-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(configRoot)
        let projectsRoot = configRoot.appendingPathComponent("projects", isDirectory: true)
        let projectRoot = projectsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let logPath = projectRoot.appendingPathComponent(filename)
        try contents.write(to: logPath, atomically: true, encoding: .utf8)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: logPath.path
            )
        }
        return (configRoot, projectsRoot, logPath)
    }
}
