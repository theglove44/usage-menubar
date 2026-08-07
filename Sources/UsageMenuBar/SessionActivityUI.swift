import Foundation

enum SessionMonitorStatus: Equatable, Sendable {
    case ready
    case stale
    case unknown
    case providerUnavailable

    var title: String {
        switch self {
        case .ready:
            return "Live"
        case .stale:
            return "Stale"
        case .unknown:
            return "Unknown"
        case .providerUnavailable:
            return "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "Session monitor connected"
        case .stale:
            return "Session data is stale"
        case .unknown:
            return "Session state is unknown"
        case .providerUnavailable:
            return "Session provider unavailable"
        }
    }
}

enum MenuBarSessionState: Equatable, Sendable {
    case active
    case waiting
    case stale
    case unknown
    case providerUnavailable

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .waiting:
            return "Waiting"
        case .stale:
            return "Stale"
        case .unknown:
            return "Unknown"
        case .providerUnavailable:
            return "Provider unavailable"
        }
    }

    var iconName: String {
        switch self {
        case .active:
            return "bolt.fill"
        case .waiting:
            return "pause.fill"
        case .stale:
            return "clock.badge.exclamationmark"
        case .unknown:
            return "questionmark.circle"
        case .providerUnavailable:
            return "exclamationmark.triangle"
        }
    }

}

enum MenuBarSessionBurnState: Equatable, Sendable {
    case measuring
    case observed
    case noRecentBurn
    case unsupported
}

struct MenuBarSessionBurn: Equatable, Sendable {
    let state: MenuBarSessionBurnState
    let tokensPerHour: Double?
    let providerShare: Double?

    init(
        state: MenuBarSessionBurnState,
        tokensPerHour: Double? = nil,
        providerShare: Double? = nil
    ) {
        self.state = state
        self.tokensPerHour = tokensPerHour
        self.providerShare = providerShare
    }
}

// UI-facing summary only. A provider adapter maps its own session model into
// this bounded shape; this app never reads transcripts or owns session polling.
struct MenuBarSession: Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let projectTitle: String?
    let sessionTitle: String?
    let state: MenuBarSessionState
    let lastActivity: Date?
    let burn: MenuBarSessionBurn?
    let childSessionCount: Int

    init(
        id: String,
        provider: String,
        projectTitle: String? = nil,
        sessionTitle: String? = nil,
        state: MenuBarSessionState,
        lastActivity: Date? = nil,
        burn: MenuBarSessionBurn? = nil,
        childSessionCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.projectTitle = projectTitle
        self.sessionTitle = sessionTitle
        self.state = state
        self.lastActivity = lastActivity
        self.burn = burn
        self.childSessionCount = max(0, childSessionCount)
    }

    var displayProvider: String {
        provider.nonEmptyOr("Unknown provider")
    }

    var displayProjectTitle: String {
        projectTitle?.nonEmptyOr("Unknown project") ?? "Unknown project"
    }

    var displaySessionTitle: String {
        sessionTitle?.nonEmptyOr("Untitled session") ?? "Untitled session"
    }
}

struct SessionActivitySnapshot: Equatable, Sendable {
    let status: SessionMonitorStatus
    let sessions: [MenuBarSession]
    let capturedAt: Date?
    let hiddenHistoricalCount: Int
    let hiddenRecentCount: Int

    init(
        status: SessionMonitorStatus,
        sessions: [MenuBarSession] = [],
        capturedAt: Date? = nil,
        hiddenHistoricalCount: Int = 0,
        hiddenRecentCount: Int = 0
    ) {
        self.status = status
        self.sessions = sessions
        self.capturedAt = capturedAt
        self.hiddenHistoricalCount = max(0, hiddenHistoricalCount)
        self.hiddenRecentCount = max(0, hiddenRecentCount)
    }

    static let unavailable = SessionActivitySnapshot(status: .providerUnavailable)

    var activeCount: Int {
        guard status == .ready else { return 0 }
        return sessions.count { $0.state == .active }
    }

    var waitingCount: Int {
        guard status == .ready else { return 0 }
        return sessions.count { $0.state == .waiting }
    }

    var compactCount: String {
        switch status {
        case .ready:
            return "\(activeCount)A/\(waitingCount)W"
        case .stale:
            return "stale"
        case .unknown:
            return "?"
        case .providerUnavailable:
            return "unavailable"
        }
    }

    func displayState(for session: MenuBarSession) -> MenuBarSessionState {
        if session.state == .providerUnavailable || status == .providerUnavailable {
            return .providerUnavailable
        }
        return session.state
    }
}

// Integration seam for the future Codex/Claude session monitor. Provider owns
// discovery, polling, and subscriptions; menu-bar UI consumes only snapshots.
protocol SessionActivityProviding: Sendable {
    var snapshot: SessionActivitySnapshot { get }
    func discover() async -> SessionActivitySnapshot
}

struct UnavailableSessionActivityProvider: SessionActivityProviding {
    let snapshot = SessionActivitySnapshot.unavailable

    func discover() async -> SessionActivitySnapshot { snapshot }
}

struct PreviewSessionActivityProvider: SessionActivityProviding {
    let snapshot: SessionActivitySnapshot

    func discover() async -> SessionActivitySnapshot { snapshot }

    init(now: Date = Date()) {
        snapshot = SessionActivitySnapshot(
            status: .ready,
            sessions: [
                MenuBarSession(
                    id: "preview-codex",
                    provider: "Codex",
                    projectTitle: "usage-menubar",
                    sessionTitle: "Add session summary",
                    state: .active,
                    lastActivity: now.addingTimeInterval(-45)
                ),
                MenuBarSession(
                    id: "preview-claude",
                    provider: "Claude",
                    projectTitle: "dashboard",
                    sessionTitle: "Waiting on approval",
                    state: .waiting,
                    lastActivity: now.addingTimeInterval(-8 * 60)
                )
            ],
            capturedAt: now
        )
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
