import XCTest
@testable import UsageMenuBar

final class SessionActivityTests: XCTestCase {
    func testReadySnapshotCountsOnlyActiveAndWaitingSessions() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                MenuBarSession(id: "active", provider: "Codex", state: .active),
                MenuBarSession(id: "waiting", provider: "Claude", state: .waiting),
                MenuBarSession(id: "stale", provider: "Codex", state: .stale),
                MenuBarSession(id: "unknown", provider: "Claude", state: .unknown)
            ]
        )

        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.waitingCount, 1)
        XCTAssertEqual(snapshot.compactCount, "1A/1W")
    }

    func testUncertainMonitorStatusDoesNotExposeStaleCounts() {
        let stale = SessionActivitySnapshot(
            status: .stale,
            sessions: [MenuBarSession(id: "active", provider: "Codex", state: .active)]
        )
        let unavailable = SessionActivitySnapshot.unavailable

        XCTAssertEqual(stale.compactCount, "stale")
        XCTAssertEqual(stale.activeCount, 0)
        XCTAssertEqual(unavailable.compactCount, "unavailable")
        XCTAssertEqual(unavailable.waitingCount, 0)
    }

    func testSnapshotStatusDoesNotOverwritePerRowState() {
        let session = MenuBarSession(
            id: "session",
            provider: "Codex",
            state: .active
        )

        XCTAssertEqual(
            SessionActivitySnapshot(status: .stale, sessions: [session]).displayState(for: session),
            .active
        )
        XCTAssertEqual(
            SessionActivitySnapshot(status: .unknown, sessions: [session]).displayState(for: session),
            .active
        )
        XCTAssertEqual(
            SessionActivitySnapshot.unavailable.displayState(for: session),
            .providerUnavailable
        )
    }

    func testMissingSessionMetadataUsesExplicitUnknownLabels() {
        let session = MenuBarSession(
            id: "session",
            provider: " \n",
            projectTitle: "",
            sessionTitle: nil,
            state: .unknown
        )

        XCTAssertEqual(session.displayProvider, "Unknown provider")
        XCTAssertEqual(session.displayProjectTitle, "Unknown project")
        XCTAssertEqual(session.displaySessionTitle, "Untitled session")
    }

    func testActivityFormattingDoesNotPretendMissingTimestampIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(formatLastActivity(nil, now: now), "last activity unknown")
        XCTAssertEqual(formatLastActivity(now.addingTimeInterval(-90), now: now), "last activity 1m ago")
        XCTAssertEqual(formatLastActivity(now.addingTimeInterval(30), now: now), "last activity in future")
        XCTAssertEqual(formatSessionSnapshotAge(nil, now: now), "last update unknown")
    }

    func testMenuBarLabelShowsOnlyTheChosenProvider() {
        XCTAssertEqual(menuBarLabelText(provider: .codex, pct: 12), "Codex 12%")
        XCTAssertEqual(menuBarLabelText(provider: .claude, pct: 87.4), "Claude 87%")
        XCTAssertEqual(menuBarLabelText(provider: .codex, pct: nil), "Codex --")
    }

    func testMenuBarGaugeFillsOneSegmentPerTenPercent() {
        XCTAssertEqual(menuBarFilledSegments(pct: nil), 0)
        XCTAssertEqual(menuBarFilledSegments(pct: 0), 0)
        // Any usage at all lights one block, so it never looks like "no data".
        XCTAssertEqual(menuBarFilledSegments(pct: 1), 1)
        XCTAssertEqual(menuBarFilledSegments(pct: 45), 5)
        XCTAssertEqual(menuBarFilledSegments(pct: 100), 10)
        XCTAssertEqual(menuBarFilledSegments(pct: 140), 10)
        XCTAssertEqual(menuBarFilledSegments(pct: -5), 0)
    }

    @MainActor
    func testStoreStartsFromInjectedProviderAndAcceptsUpdates() {
        let initial = PreviewSessionActivityProvider(now: Date(timeIntervalSince1970: 1_000_000))
        let store = SessionActivityStore(provider: initial)

        XCTAssertEqual(store.snapshot, initial.snapshot)

        store.update(.init(status: .unknown))

        XCTAssertEqual(store.snapshot.status, .unknown)
    }
}
