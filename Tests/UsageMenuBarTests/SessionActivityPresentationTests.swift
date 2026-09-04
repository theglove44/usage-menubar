import Foundation
import Testing
@testable import UsageMenuBar

struct SessionActivityPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func presentationFiltersNonLiveRowsWithoutGlobalStateOverride() {
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

        #expect(presentation.visibleSessions.map(\.id) == ["active", "waiting"])
        #expect(presentation.activeCount == 1)
        #expect(presentation.waitingCount == 1)
        #expect(presentation.omittedNonLiveCount == 3)
        #expect(presentation.visibleSessions.map(\.state) == [.active, .waiting])
    }

    @Test func presentationRanksActiveBeforeWaitingThenNewestActivity() {
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

        #expect(
            presentation.visibleSessions.map(\.id)
                == ["active-new", "active-old", "waiting-new", "waiting-old"]
        )
    }

    @Test func presentationCapsRowsAndReportsHiddenAndNonLiveData() {
        let live = (0..<6).map { index in
            session(id: "live-\(index)", state: .active, age: TimeInterval(index))
        }
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: live + [session(id: "old", state: .stale)]
        )

        let presentation = sessionRunwayPresentation(for: snapshot, maxVisibleRows: 3)

        #expect(presentation.visibleSessions.count == 3)
        #expect(presentation.hiddenLiveCount == 3)
        #expect(presentation.omittedNonLiveCount == 1)
        #expect(
            presentation.diagnosticText
                == "+3 recent sessions hidden · 1 non-live sessions omitted"
        )
    }

    @Test func syntheticSessionTitleFallsBackToProject() {
        let session = MenuBarSession(
            id: "019fc255-f153-7e03-a334-8c5612d3b4e9",
            provider: "Codex",
            projectTitle: "usage-menubar",
            sessionTitle: "019fc255-f153-7e03-a334-8c5612d3b4e9",
            state: .active
        )

        #expect(sessionRunwayTitle(for: session) == "usage-menubar")
    }

    @Test func statusTextShowsLiveCountsAndRefreshAge() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                session(id: "active", state: .active, age: 30),
                session(id: "waiting", state: .waiting, age: 90)
            ],
            capturedAt: now.addingTimeInterval(-120)
        )

        #expect(sessionRunwayStatusText(for: snapshot) == "Live · 1 active · 1 waiting")
        #expect(formatSessionRefreshAge(snapshot.capturedAt, now: now) == "last refresh 2m ago")
    }

    @Test func unknownRowsNeverCountAsActive() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [session(id: "unknown", state: .unknown)]
        )

        let presentation = sessionRunwayPresentation(for: snapshot)

        #expect(presentation.activeCount == 0)
        #expect(presentation.waitingCount == 0)
        #expect(presentation.visibleSessions.isEmpty)
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
