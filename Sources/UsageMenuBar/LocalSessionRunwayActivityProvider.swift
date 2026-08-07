import Foundation

// Long-lived adapter from the actor-backed local runway scanner to the small
// snapshot consumed by SwiftUI. Scanner state must survive refreshes so burn
// deltas can be measured between polls.
struct LocalSessionRunwayActivityProvider: SessionActivityProviding {
    let snapshot: SessionActivitySnapshot
    private let scanner: SessionRunwayScanner

    init(scanner: SessionRunwayScanner = SessionRunwayScanner()) {
        self.scanner = scanner
        snapshot = SessionActivitySnapshot(status: .unknown)
    }

    func discover() async -> SessionActivitySnapshot {
        let runway = await scanner.scan()
        let sessions = runway.rows.map(makeMenuBarSession)
        let hasLiveRows = sessions.contains { $0.state == .active || $0.state == .waiting }
        let hasUsableSource = runway.health.values.contains { health in
            health == .ready || health == .degraded
        }
        let status: SessionMonitorStatus
        if hasLiveRows || hasUsableSource || runway.diagnostics.processProbeAvailable {
            status = .ready
        } else if runway.health.values.contains(.unavailable) {
            status = .unknown
        } else {
            status = .ready
        }

        return SessionActivitySnapshot(
            status: status,
            sessions: sessions,
            capturedAt: runway.scannedAt,
            hiddenHistoricalCount: runway.hiddenHistoricalCount,
            hiddenRecentCount: runway.diagnostics.hiddenRecentCount
        )
    }

    private func makeMenuBarSession(_ row: SessionRunwayRow) -> MenuBarSession {
        MenuBarSession(
            id: row.id,
            provider: row.provider.displayName,
            projectTitle: row.projectName,
            sessionTitle: row.title,
            state: menuBarState(for: row.state),
            lastActivity: row.lastActivityAt,
            burn: MenuBarSessionBurn(
                state: menuBarBurnState(for: row.burn.state),
                tokensPerHour: row.burn.observedTokensPerHour,
                providerShare: row.burn.shareOfObservedProviderBurn
            ),
            childSessionCount: row.childSessionCount
        )
    }

    private func menuBarState(for state: SessionRunwayState) -> MenuBarSessionState {
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

    private func menuBarBurnState(for state: SessionRunwayBurnState) -> MenuBarSessionBurnState {
        switch state {
        case .measuring:
            return .measuring
        case .observed:
            return .observed
        case .noRecentBurn:
            return .noRecentBurn
        case .unsupported:
            return .unsupported
        }
    }
}
