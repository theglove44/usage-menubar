import XCTest
@testable import UsageMenuBar

final class LocalSessionActivityTests: XCTestCase {
    func testLocalSourceMapsProvidersProjectsAndStatesIntoMenuRows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = LocalSessionActivitySource(
            discoverCodex: {
                [SessionActivity(
                    provider: .codex,
                    sessionID: "codex-session-1234",
                    workspace: "/Users/tester/Projects/usage-menubar",
                    lastSeen: now.addingTimeInterval(-5),
                    state: .activeWorking,
                    confidence: .high
                )]
            },
            discoverClaude: {
                [SessionActivity(
                    provider: .claude,
                    sessionID: "claude-session-5678",
                    workspace: "/Users/tester/Projects/dashboard",
                    lastSeen: now.addingTimeInterval(-120),
                    state: .openIdle,
                    confidence: .medium
                )]
            }
        )

        let snapshot = source.discoverSnapshot(now: now)

        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.waitingCount, 1)
        XCTAssertEqual(snapshot.sessions.map(\.provider), ["Codex", "Claude"])
        XCTAssertEqual(snapshot.sessions.map(\.displayProjectTitle), ["usage-menubar", "dashboard"])
        XCTAssertEqual(snapshot.sessions.map(\.state), [.active, .waiting])
        XCTAssertEqual(snapshot.sessions.map(\.displaySessionTitle), ["Session codex-se", "Session claude-s"])
    }

    func testLocalSourceKeepsStaleAndUnknownHonest() {
        let source = LocalSessionActivitySource(
            discoverCodex: {
                [SessionActivity(
                    provider: .codex,
                    sessionID: "stale-session",
                    state: .stale,
                    confidence: .high
                )]
            },
            discoverClaude: {
                [SessionActivity(
                    provider: .claude,
                    sessionID: "unknown-session",
                    state: .unknown,
                    confidence: .low
                )]
            }
        )

        let snapshot = source.discoverSnapshot()

        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertEqual(snapshot.compactCount, "?")
        XCTAssertEqual(snapshot.sessions.map(\.state), [.unknown, .stale])
    }
}
