import Foundation
import Testing
@testable import UsageMenuBar

struct SessionActivityTests {
    @Test func readySnapshotCountsOnlyActiveAndWaitingSessions() {
        let snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                MenuBarSession(id: "active", provider: "Codex", state: .active),
                MenuBarSession(id: "waiting", provider: "Claude", state: .waiting),
                MenuBarSession(id: "stale", provider: "Codex", state: .stale),
                MenuBarSession(id: "unknown", provider: "Claude", state: .unknown)
            ]
        )

        #expect(snapshot.activeCount == 1)
        #expect(snapshot.waitingCount == 1)
        #expect(snapshot.compactCount == "1A/1W")
    }

    @Test func uncertainMonitorStatusDoesNotExposeStaleCounts() {
        let stale = SessionActivitySnapshot(
            status: .stale,
            sessions: [MenuBarSession(id: "active", provider: "Codex", state: .active)]
        )
        let unavailable = SessionActivitySnapshot.unavailable

        #expect(stale.compactCount == "stale")
        #expect(stale.activeCount == 0)
        #expect(unavailable.compactCount == "unavailable")
        #expect(unavailable.waitingCount == 0)
    }

    @Test func snapshotStatusDoesNotOverwritePerRowState() {
        let session = MenuBarSession(
            id: "session",
            provider: "Codex",
            state: .active
        )

        #expect(
            SessionActivitySnapshot(status: .stale, sessions: [session]).displayState(for: session)
                == .active
        )
        #expect(
            SessionActivitySnapshot(status: .unknown, sessions: [session]).displayState(for: session)
                == .active
        )
        #expect(
            SessionActivitySnapshot.unavailable.displayState(for: session) == .providerUnavailable
        )
    }

    @Test func missingSessionMetadataUsesExplicitUnknownLabels() {
        let session = MenuBarSession(
            id: "session",
            provider: " \n",
            projectTitle: "",
            sessionTitle: nil,
            state: .unknown
        )

        #expect(session.displayProvider == "Unknown provider")
        #expect(session.displayProjectTitle == "Unknown project")
        #expect(session.displaySessionTitle == "Untitled session")
    }

    @Test func activityFormattingDoesNotPretendMissingTimestampIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(formatLastActivity(nil, now: now) == "last activity unknown")
        #expect(formatLastActivity(now.addingTimeInterval(-90), now: now) == "last activity 1m ago")
        #expect(formatLastActivity(now.addingTimeInterval(30), now: now) == "last activity in future")
        #expect(formatSessionSnapshotAge(nil, now: now) == "last update unknown")
    }

    @Test func menuBarLabelShowsOnlyTheChosenProvider() {
        #expect(menuBarLabelText(provider: .codex, pct: 12) == "Codex 12%")
        #expect(menuBarLabelText(provider: .claude, pct: 87.4) == "Claude 87%")
        #expect(menuBarLabelText(provider: .grok, pct: 32) == "Grok 32%")
        #expect(menuBarLabelText(provider: .codex, pct: nil) == "Codex --")
    }

    @Test func menuBarGaugeFillsOneSegmentPerTenPercent() {
        #expect(menuBarFilledSegments(pct: nil) == 0)
        #expect(menuBarFilledSegments(pct: 0) == 0)
        // Any usage at all lights one block, so it never looks like "no data".
        #expect(menuBarFilledSegments(pct: 1) == 1)
        #expect(menuBarFilledSegments(pct: 45) == 5)
        #expect(menuBarFilledSegments(pct: 100) == 10)
        #expect(menuBarFilledSegments(pct: 140) == 10)
        #expect(menuBarFilledSegments(pct: -5) == 0)
    }

    @Test @MainActor func storeStartsFromInjectedProviderAndAcceptsUpdates() {
        let initial = PreviewSessionActivityProvider(now: Date(timeIntervalSince1970: 1_000_000))
        let store = SessionActivityStore(provider: initial)

        #expect(store.snapshot == initial.snapshot)

        store.update(.init(status: .unknown))

        #expect(store.snapshot.status == .unknown)
    }
}
