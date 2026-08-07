import Foundation

// Local-only source merger. It reads existing Codex/Claude files and process
// metadata; it never launches either CLI and never makes network requests.
struct LocalSessionActivityProvider: SessionActivityProviding {
    let snapshot: SessionActivitySnapshot
    private let source: LocalSessionActivitySource

    init(source: LocalSessionActivitySource = .live) {
        self.source = source
        snapshot = SessionActivitySnapshot(status: .unknown)
    }

    func discover() async -> SessionActivitySnapshot {
        source.discoverSnapshot()
    }
}

struct LocalSessionActivitySource: @unchecked Sendable {
    private let discoverCodex: @Sendable () -> [SessionActivity]
    private let discoverClaude: @Sendable () -> [SessionActivity]

    init(
        codexScanner: CodexPresenceScanner = CodexPresenceScanner(),
        claudeDiscovery: ClaudeSessionDiscovery = ClaudeSessionDiscovery()
    ) {
        self.discoverCodex = { codexScanner.discover() }
        self.discoverClaude = { claudeDiscovery.discover() }
    }

    init(
        discoverCodex: @escaping @Sendable () -> [SessionActivity],
        discoverClaude: @escaping @Sendable () -> [SessionActivity]
    ) {
        self.discoverCodex = discoverCodex
        self.discoverClaude = discoverClaude
    }

    static let live = LocalSessionActivitySource()

    func discoverSnapshot(now: Date = Date()) -> SessionActivitySnapshot {
        let activities = (discoverCodex() + discoverClaude())
            .sorted { lhs, rhs in
                let leftRank = stateRank(lhs.state)
                let rightRank = stateRank(rhs.state)
                if leftRank != rightRank { return leftRank > rightRank }
                return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
            }

        return SessionActivitySnapshot(
            status: monitorStatus(for: activities),
            sessions: activities.map(makeMenuBarSession),
            capturedAt: now
        )
    }

    private func makeMenuBarSession(_ activity: SessionActivity) -> MenuBarSession {
        let shortID = String(activity.sessionID.prefix(8))
        let sessionTitle = shortID.isEmpty ? nil : "Session \(shortID)"
        return MenuBarSession(
            id: activity.id,
            provider: activity.provider.displayName,
            projectTitle: projectTitle(for: activity.workspace),
            sessionTitle: sessionTitle,
            state: menuBarState(for: activity.state),
            lastActivity: activity.lastSeen
        )
    }

    private func projectTitle(for workspace: String?) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let name = URL(fileURLWithPath: workspace).lastPathComponent
        return name.isEmpty ? workspace : name
    }

    private func menuBarState(for state: SessionActivityState) -> MenuBarSessionState {
        switch state {
        case .activeWorking:
            return .active
        case .openIdle:
            return .waiting
        case .stale:
            return .stale
        case .unknown:
            return .unknown
        }
    }

    private func monitorStatus(for activities: [SessionActivity]) -> SessionMonitorStatus {
        guard !activities.isEmpty else { return .ready }
        if activities.contains(where: { $0.state == .activeWorking || $0.state == .openIdle }) {
            return .ready
        }
        if activities.allSatisfy({ $0.state == .stale }) {
            return .stale
        }
        if activities.allSatisfy({ $0.state == .unknown }) {
            return .unknown
        }
        return .unknown
    }

    private func stateRank(_ state: SessionActivityState) -> Int {
        switch state {
        case .activeWorking: return 4
        case .openIdle: return 3
        case .unknown: return 2
        case .stale: return 1
        }
    }
}

private extension SessionActivityProvider {
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}
