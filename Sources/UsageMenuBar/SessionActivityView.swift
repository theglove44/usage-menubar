import Foundation
import SwiftUI

let sessionRunwayDefaultVisibleRows = 4

struct SessionRunwayPresentation: Equatable {
    let status: SessionMonitorStatus
    let activeCount: Int
    let waitingCount: Int
    let visibleSessions: [MenuBarSession]
    let hiddenLiveCount: Int
    let omittedNonLiveCount: Int
    let hiddenHistoricalCount: Int
    let hiddenRecentCount: Int

    init(
        snapshot: SessionActivitySnapshot,
        maxVisibleRows: Int = sessionRunwayDefaultVisibleRows
    ) {
        status = snapshot.status

        let liveSessions = snapshot.sessions
            .filter { $0.state == .active || $0.state == .waiting }
            .sorted(by: sessionRunwaySort)
        let visibleLimit = max(0, maxVisibleRows)

        activeCount = liveSessions.count { $0.state == .active }
        waitingCount = liveSessions.count { $0.state == .waiting }
        visibleSessions = Array(liveSessions.prefix(visibleLimit))
        hiddenLiveCount = max(0, liveSessions.count - visibleSessions.count)
        omittedNonLiveCount = snapshot.sessions.count - liveSessions.count
        hiddenHistoricalCount = snapshot.hiddenHistoricalCount
        hiddenRecentCount = snapshot.hiddenRecentCount
    }

    var diagnosticText: String? {
        var messages: [String] = []
        if hiddenLiveCount > 0 {
            messages.append("+\(hiddenLiveCount) recent sessions hidden")
        }
        if omittedNonLiveCount > 0 {
            messages.append("\(omittedNonLiveCount) non-live sessions omitted")
        }
        if hiddenHistoricalCount > 0 {
            messages.append("\(hiddenHistoricalCount)+ historical sessions hidden")
        }
        if hiddenRecentCount > 0 {
            messages.append("+\(hiddenRecentCount) recent sessions hidden")
        }
        return messages.isEmpty ? nil : messages.joined(separator: " · ")
    }
}

func sessionRunwayPresentation(
    for snapshot: SessionActivitySnapshot,
    maxVisibleRows: Int = sessionRunwayDefaultVisibleRows
) -> SessionRunwayPresentation {
    SessionRunwayPresentation(snapshot: snapshot, maxVisibleRows: maxVisibleRows)
}

private func sessionRunwaySort(lhs: MenuBarSession, rhs: MenuBarSession) -> Bool {
    let leftPriority = sessionRunwayStatePriority(lhs.state)
    let rightPriority = sessionRunwayStatePriority(rhs.state)
    if leftPriority != rightPriority { return leftPriority < rightPriority }

    switch (lhs.lastActivity, rhs.lastActivity) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        break
    }

    let leftKey = sessionRunwaySortKey(for: lhs)
    let rightKey = sessionRunwaySortKey(for: rhs)
    return leftKey < rightKey
}

private func sessionRunwayStatePriority(_ state: MenuBarSessionState) -> Int {
    switch state {
    case .active:
        return 0
    case .waiting:
        return 1
    case .stale, .unknown, .providerUnavailable:
        return 2
    }
}

private func sessionRunwaySortKey(for session: MenuBarSession) -> String {
    [
        session.displayProvider,
        sessionRunwayTitle(for: session),
        session.displayProjectTitle
    ]
    .joined(separator: "\u{0}")
    .lowercased()
}

func sessionRunwayTitle(for session: MenuBarSession) -> String {
    let title = session.displaySessionTitle
    if title == "Untitled session" || title == session.id || isSyntheticSessionIdentifier(title) {
        return session.displayProjectTitle
    }
    return title
}

private func isSyntheticSessionIdentifier(_ value: String) -> Bool {
    if UUID(uuidString: value) != nil { return true }

    let compact = value.replacingOccurrences(of: "-", with: "")
    guard compact.count >= 20 else { return false }
    let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    return compact.unicodeScalars.allSatisfy { hex.contains($0) }
}

func sessionRunwayProjectText(for session: MenuBarSession, now: Date) -> String {
    let project = session.displayProjectTitle
    let title = sessionRunwayTitle(for: session)
    let activity = formatLastActivity(session.lastActivity, now: now)
    return title == project ? activity : "\(project) · \(activity)"
}

// One piece of relative-age arithmetic, three sets of words. The wording is not
// consistent between callers and must not be made so: the snapshot line reads
// "last update unknown" but "updated 2m ago", and the dropdown says a bare
// "just now". Each caller supplies its own phrasing; the maths lives here only.
private func relativeAge(_ date: Date?, now: Date,
                         unknown: String, future: String,
                         justNow: String, prefix: String) -> String {
    guard let date else { return unknown }
    let interval = now.timeIntervalSince(date)
    if interval < 0 { return future }
    if interval < 60 { return justNow }

    let minutes = Int(interval / 60)
    if minutes < 60 { return "\(prefix)\(minutes)m ago" }

    let hours = minutes / 60
    if hours < 24 { return "\(prefix)\(hours)h ago" }
    return "\(prefix)\(hours / 24)d ago"
}

func formatLastActivity(_ date: Date?, now: Date) -> String {
    relativeAge(date, now: now, unknown: "last activity unknown",
                future: "last activity in future", justNow: "just now",
                prefix: "last activity ")
}

func formatSessionSnapshotAge(_ date: Date?, now: Date) -> String {
    relativeAge(date, now: now, unknown: "last update unknown",
                future: "last update in future", justNow: "updated just now",
                prefix: "updated ")
}

func formatSessionRefreshAge(_ date: Date?, now: Date) -> String {
    relativeAge(date, now: now, unknown: "last refresh unknown",
                future: "last refresh in future", justNow: "last refresh just now",
                prefix: "last refresh ")
}

func sessionRunwayCountsText(for snapshot: SessionActivitySnapshot) -> String {
    let presentation = sessionRunwayPresentation(for: snapshot)
    return "\(presentation.activeCount) active · \(presentation.waitingCount) waiting"
}

func sessionRunwayStatusText(for snapshot: SessionActivitySnapshot) -> String {
    "\(snapshot.status.title) · \(sessionRunwayCountsText(for: snapshot))"
}

func formatSessionBurn(_ burn: MenuBarSessionBurn?) -> String {
    guard let burn else { return "rate —" }

    switch burn.state {
    case .observed:
        var parts: [String] = []
        if let tokensPerHour = burn.tokensPerHour {
            parts.append("~\(formatTokensPerHour(tokensPerHour)) tok/h")
        }
        if let providerShare = burn.providerShare {
            parts.append("\(Int((providerShare * 100).rounded()))% observed")
        }
        return parts.isEmpty ? "burn observed" : parts.joined(separator: " · ")
    case .measuring:
        return "measuring burn…"
    case .noRecentBurn:
        return "no recent burn"
    case .unsupported:
        return "burn unavailable"
    }
}

private func formatTokensPerHour(_ value: Double) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }
    if absolute >= 1_000 {
        return String(format: "%.1fk", value / 1_000)
    }
    return String(format: "%.0f", value)
}

struct SessionStateBadge: View {
    let state: MenuBarSessionState

    var body: some View {
        Text(state.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor.opacity(0.14), in: Capsule())
    }

    private var stateColor: Color {
        switch state {
        case .active:
            return .green
        case .waiting, .stale:
            return .orange
        case .unknown:
            return .secondary
        case .providerUnavailable:
            return .red
        }
    }
}

struct SessionActivityRow: View {
    let session: MenuBarSession
    let state: MenuBarSessionState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(session.displayProvider) · \(sessionRunwayTitle(for: session))")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                SessionStateBadge(state: state)
            }

            HStack(spacing: 4) {
                Text(sessionRunwayProjectText(for: session, now: now))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.childSessionCount > 0 {
                    Text("+\(session.childSessionCount) subagent\(session.childSessionCount == 1 ? "" : "s")")
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(formatSessionBurn(session.burn))
                    .accessibilityLabel("Observed session burn \(formatSessionBurn(session.burn))")
                    .fixedSize()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct SessionActivitySection: View {
    @ObservedObject var store: SessionActivityStore
    let now: Date

    private var presentation: SessionRunwayPresentation {
        sessionRunwayPresentation(for: store.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Session Runway")
                    .font(.subheadline.bold())
                Spacer()
                Text(store.snapshot.status.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 4) {
                Text(sessionRunwayCountsText(for: store.snapshot))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(formatSessionRefreshAge(store.snapshot.capturedAt, now: now))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if store.snapshot.status != .ready {
                Text(store.snapshot.status.detail)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            Divider()

            if presentation.visibleSessions.isEmpty {
                Text("No active sessions detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(presentation.visibleSessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider().padding(.leading, 4)
                        }
                        SessionActivityRow(
                            session: session,
                            state: session.state,
                            now: now
                        )
                    }
                }
            }

            if let diagnosticText = presentation.diagnosticText {
                Text(diagnosticText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sessionRunwayStatusText(for: store.snapshot))
    }

    private var statusColor: Color {
        switch store.snapshot.status {
        case .ready:
            return .green
        case .stale:
            return .orange
        case .unknown:
            return .secondary
        case .providerUnavailable:
            return .red
        }
    }
}
