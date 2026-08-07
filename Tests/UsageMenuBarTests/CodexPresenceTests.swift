import Foundation
import XCTest
@testable import UsageMenuBar

final class CodexPresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexHomeResolverHonorsEnvironmentAndNormalizesPath() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let configured = CodexHomeResolver.resolve(
            environment: ["CODEX_HOME": "~/Library/../codex-data"],
            homeDirectory: home
        )
        let fallback = CodexHomeResolver.resolve(environment: [:], homeDirectory: home)

        XCTAssertEqual(configured.path, "/Users/tester/codex-data")
        XCTAssertEqual(fallback.path, "/Users/tester/.codex")
    }

    func testMatchingSessionUsesRegistryAndProcessEvidence() {
        let id = "019fc263-a238-7991-90bd-3abb41a2b194"
        let root = URL(fileURLWithPath: "/tmp/codex-presence-match", isDirectory: true)
        let configuration = CodexPresenceConfiguration(
            codexHome: root,
            staleAfter: 300,
            workingAfter: 30,
            registryFreshAfter: 30
        )
        let workspace = "/tmp/codex-presence-match/project/./"
        let logURL = configuration.sessionsDirectory
            .appendingPathComponent("2026/08/02/rollout-(id).jsonl")
        let logDate = now.addingTimeInterval(-5)
        let fixture = FixtureFileSystem()
        fixture.addRollout(
            at: logURL,
            data: rolloutData(id: id, cwd: workspace, timestamp: iso(logDate)),
            modificationDate: logDate
        )
        fixture.addRegistry(
            at: configuration.activeRegistryURL,
            data: registryData(id: id, cwd: "/private/tmp/codex-presence-match/project", pid: 42, updatedAt: logDate),
            modificationDate: logDate
        )

        let scanner = CodexPresenceScanner(
            configuration: configuration,
            fileSystem: fixture.fileSystem,
            processProbe: CodexProcessProbe {
                [CodexProcessEvidence(
                    pid: 42,
                    workingDirectory: "/tmp/codex-presence-match/project",
                    tty: "ttys001"
                )]
            },
            now: { self.now }
        )

        let activity = try! XCTUnwrap(scanner.discover().first)
        XCTAssertEqual(activity.id, "codex:\(id)")
        XCTAssertEqual(activity.state, .activeWorking)
        XCTAssertEqual(activity.confidence, .high)
        XCTAssertEqual(activity.pid, 42)
        XCTAssertEqual(activity.tty, "ttys001")
        XCTAssertEqual(activity.workspace, CodexHomeResolver.normalizedPath(workspace))
        XCTAssertEqual(activity.logPath, CodexHomeResolver.normalizeURL(logURL).path)
        XCTAssertEqual(activity.lastSeen, logDate)
    }

    func testFreshRegistryWithQuietRolloutIsOpenIdle() {
        let id = "019fc263-a238-7991-90bd-3abb41a2b194"
        let root = URL(fileURLWithPath: "/tmp/codex-presence-idle", isDirectory: true)
        let configuration = CodexPresenceConfiguration(
            codexHome: root,
            staleAfter: 300,
            workingAfter: 30,
            registryFreshAfter: 30
        )
        let logDate = now.addingTimeInterval(-60)
        let fixture = FixtureFileSystem()
        fixture.addRollout(
            at: configuration.sessionsDirectory.appendingPathComponent("rollout-(id).jsonl"),
            data: rolloutData(id: id, cwd: "/tmp/codex-presence-idle/project", timestamp: iso(logDate)),
            modificationDate: logDate
        )
        fixture.addRegistry(
            at: configuration.activeRegistryURL,
            data: registryData(id: id, cwd: "/tmp/codex-presence-idle/project", pid: nil, updatedAt: now.addingTimeInterval(-2)),
            modificationDate: now.addingTimeInterval(-2)
        )

        let scanner = scanner(configuration: configuration, fixture: fixture)
        let activity = try! XCTUnwrap(scanner.discover().first)

        XCTAssertEqual(activity.state, .openIdle)
        XCTAssertEqual(activity.confidence, .medium)
    }

    func testRecentRolloutWithoutLiveEvidenceStaysUnknown() {
        let id = "019fc263-a238-7991-90bd-3abb41a2b194"
        let root = URL(fileURLWithPath: "/tmp/codex-presence-unknown", isDirectory: true)
        let configuration = CodexPresenceConfiguration(
            codexHome: root,
            staleAfter: 300,
            workingAfter: 30,
            registryFreshAfter: 30
        )
        let fixture = FixtureFileSystem()
        fixture.addRollout(
            at: configuration.sessionsDirectory.appendingPathComponent("rollout-(id).jsonl"),
            data: rolloutData(id: id, cwd: "/tmp/codex-presence-unknown/project", timestamp: iso(now.addingTimeInterval(-2))),
            modificationDate: now.addingTimeInterval(-2)
        )

        let activity = try! XCTUnwrap(scanner(configuration: configuration, fixture: fixture).discover().first)

        XCTAssertEqual(activity.state, .unknown)
        XCTAssertEqual(activity.confidence, .low)
    }

    func testFileMtimePastStaleTTLProducesStaleActivity() {
        let id = "019fc263-a238-7991-90bd-3abb41a2b194"
        let root = URL(fileURLWithPath: "/tmp/codex-presence-stale", isDirectory: true)
        let configuration = CodexPresenceConfiguration(
            codexHome: root,
            staleAfter: 300,
            workingAfter: 30,
            registryFreshAfter: 30
        )
        let oldDate = now.addingTimeInterval(-301)
        let fixture = FixtureFileSystem()
        fixture.addRollout(
            at: configuration.sessionsDirectory.appendingPathComponent("rollout-(id).jsonl"),
            data: rolloutData(id: id, cwd: "/tmp/codex-presence-stale/project", timestamp: iso(oldDate)),
            modificationDate: oldDate
        )

        let activity = try! XCTUnwrap(scanner(configuration: configuration, fixture: fixture).discover().first)

        XCTAssertEqual(activity.state, .stale)
        XCTAssertEqual(activity.confidence, .high)
        XCTAssertEqual(activity.lastSeen, oldDate)
    }

    func testMalformedRolloutUsesFilenameIDAndReportsUnknown() {
        let id = "019fc263-a238-7991-90bd-3abb41a2b194"
        let root = URL(fileURLWithPath: "/tmp/codex-presence-malformed", isDirectory: true)
        let configuration = CodexPresenceConfiguration(codexHome: root)
        let logURL = configuration.sessionsDirectory.appendingPathComponent("rollout-\(id).jsonl")
        let fixture = FixtureFileSystem()
        fixture.addRollout(
            at: logURL,
            data: Data("not-json\n{\"type\":\"event_msg\"}\n".utf8),
            modificationDate: now.addingTimeInterval(-2)
        )
        let activity = try! XCTUnwrap(scanner(configuration: configuration, fixture: fixture).discover().first)

        XCTAssertEqual(activity.id, "codex:\(id)")
        XCTAssertEqual(activity.state, .unknown)
        XCTAssertEqual(activity.confidence, .low)
        XCTAssertNil(activity.workspace)
        XCTAssertEqual(activity.logPath, CodexHomeResolver.normalizeURL(logURL).path)
    }

    func testMissingAndMalformedFilesAreSafeAndReturnNoFalseSession() {
        let root = URL(fileURLWithPath: "/tmp/codex-presence-missing", isDirectory: true)
        let configuration = CodexPresenceConfiguration(codexHome: root)
        let fixture = FixtureFileSystem()
        fixture.addRegistry(
            at: configuration.activeRegistryURL,
            data: Data("{ definitely-not-json".utf8),
            modificationDate: now
        )

        XCTAssertTrue(scanner(configuration: configuration, fixture: fixture).discover().isEmpty)
    }

    private func scanner(
        configuration: CodexPresenceConfiguration,
        fixture: FixtureFileSystem
    ) -> CodexPresenceScanner {
        CodexPresenceScanner(
            configuration: configuration,
            fileSystem: fixture.fileSystem,
            processProbe: CodexProcessProbe { [] },
            now: { self.now }
        )
    }

    private func rolloutData(id: String, cwd: String, timestamp: String) -> Data {
        Data("""
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(id)","cwd":"\(cwd)"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"turn_context"}}
        """.utf8)
    }

    private func registryData(id: String, cwd: String, pid: Int32?, updatedAt: Date) -> Data {
        let pidField = pid.map { ",\"osPid\":\($0)" } ?? ""
        let milliseconds = Int(updatedAt.timeIntervalSince1970 * 1_000)
        return Data("""
        [{"conversationId":"\(id)","cwd":"\(cwd)"\(pidField),"updatedAtMs":\(milliseconds)}]
        """.utf8)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class FixtureFileSystem {
    private var data: [String: Data] = [:]
    private var dates: [String: Date] = [:]
    private(set) var rolloutURLs: [URL] = []

    lazy var fileSystem = CodexPresenceFileSystem(
        listFiles: { [self] _ in rolloutURLs },
        readData: { [self] url in data[key(for: url)] },
        modificationDate: { [self] url in dates[key(for: url)] }
    )

    func addRollout(at url: URL, data: Data, modificationDate: Date?) {
        rolloutURLs.append(url)
        self.data[key(for: url)] = data
        if let modificationDate {
            dates[key(for: url)] = modificationDate
        }
    }

    func addRegistry(at url: URL, data: Data, modificationDate: Date?) {
        self.data[key(for: url)] = data
        if let modificationDate {
            dates[key(for: url)] = modificationDate
        }
    }

    private func key(for url: URL) -> String {
        CodexHomeResolver.normalizeURL(url).path
    }
}
