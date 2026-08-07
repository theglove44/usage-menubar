import XCTest
@testable import UsageMenuBar

final class SessionActivityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testPresentationFiltersNonLiveRowsWithoutGlobalStateOverride() {
        let snapshot = SessionActivitySnapshot(
            status: .unknown,
            sessions: [
                session(id: "active", state: .active),
                session(id: "waiting", state: .waiting),
                session(id: "stale", state: .stale),
                session(id: "unknown", state: .unknown),
                session(id: "unavailable", state: .providerUnavailable)
            ]
        )

        let presentation = sessionRunwayPresentation(for: snapshot)

        XCTAssertEqual(presentation.visibleSessions.map(\.id), ["active", "waiting"])
        XCTAssertEqual(presentation.activeCount, 1)
        XCTAssertEqual(presentation.waitingCount, 1)
        XCTAssertEqual(presentation.omittedNonLiveCount, 3)
        XCTAssertEqual(presentation.visibleSessions.map(\.state), [.active, .waiting])
    }

    func testPresentationRanksActiveBeforeWaitingThenNewestActivity() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                session(id: "waiting-old", state: .waiting, age: 600),
                session(id: "active-old", state: .active, age: 600),
                session(id: "active-new", state: .active, age: 30),
                session(id: "waiting-new", state: .waiting, age: 15)
            ]
        )

        let presentation = sessionRunwayPresentation(for: snapshot)

        XCTAssertEqual(
            presentation.visibleSessions.map(\.id),
            ["active-new", "active-old", "waiting-new", "waiting-old"]
        )
    }

    func testPresentationCapsRowsAndReportsHiddenAndNonLiveData() {
        let live = (0..<6).map { index in
            session(id: "live-\(index)", state: .active, age: TimeInterval(index))
        }
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: live + [session(id: "old", state: .stale)]
        )

        let presentation = sessionRunwayPresentation(for: snapshot, maxVisibleRows: 3)

        XCTAssertEqual(presentation.visibleSessions.count, 3)
        XCTAssertEqual(presentation.hiddenLiveCount, 3)
        XCTAssertEqual(presentation.omittedNonLiveCount, 1)
        XCTAssertEqual(
            presentation.diagnosticText,
            "+3 recent sessions hidden · 1 non-live sessions omitted"
        )
    }

    func testSyntheticSessionTitleFallsBackToProject() {
        let session = MenuBarSession(
            id: "019fc255-f153-7e03-a334-8c5612d3b4e9",
            provider: "Codex",
            projectTitle: "usage-menubar",
            sessionTitle: "019fc255-f153-7e03-a334-8c5612d3b4e9",
            state: .active
        )

        XCTAssertEqual(sessionRunwayTitle(for: session), "usage-menubar")
    }

    func testStatusTextShowsLiveCountsAndRefreshAge() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                session(id: "active", state: .active, age: 30),
                session(id: "waiting", state: .waiting, age: 90)
            ],
            capturedAt: now.addingTimeInterval(-120)
        )

        XCTAssertEqual(
            sessionRunwayStatusText(for: snapshot),
            "Live · 1 active · 1 waiting"
        )
        XCTAssertEqual(formatSessionRefreshAge(snapshot.capturedAt, now: now), "last refresh 2m ago")
    }

    func testUnknownRowsNeverCountAsActive() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [session(id: "unknown", state: .unknown)]
        )

        let presentation = sessionRunwayPresentation(for: snapshot)

        XCTAssertEqual(presentation.activeCount, 0)
        XCTAssertEqual(presentation.waitingCount, 0)
        XCTAssertTrue(presentation.visibleSessions.isEmpty)
    }

    private func session(
        id: String,
        state: MenuBarSessionState,
        age: TimeInterval? = nil
    ) -> MenuBarSession {
        MenuBarSession(
            id: id,
            provider: "Codex",
            projectTitle: "usage-menubar",
            sessionTitle: id,
            state: state,
            lastActivity: age.map { now.addingTimeInterval(-$0) }
        )
    }
}
