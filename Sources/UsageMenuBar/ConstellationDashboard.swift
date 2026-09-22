import SwiftUI

enum ConstellationTheme {
    static let background = Color(red: 0.15, green: 0.11, blue: 0.25)
    static let surface = Color(red: 0.22, green: 0.16, blue: 0.34)
    static let line = Color(red: 0.42, green: 0.33, blue: 0.56)
    static let text = Color(red: 0.97, green: 0.94, blue: 1)
    static let secondary = Color(red: 0.76, green: 0.69, blue: 0.86)
    static let violet = Color(red: 0.76, green: 0.59, blue: 1)
    static let amber = Color(red: 1, green: 0.76, blue: 0.42)
}

struct ConstellationDashboard: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var sessionStore: SessionActivityStore
    @ObservedObject var preferences: MenuBarPreferences
    let now: Date
    let openSettings: () -> Void
    let openModelUsage: (MenuBarProvider) -> Void
    @State private var showingList = false

    private var presentation: SessionRunwayPresentation {
        sessionRunwayPresentation(for: sessionStore.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                if preferences.showSessionRunway {
                    sessionContent
                } else {
                    Text("Session Runway is hidden. Turn it on in Settings to see local activity.")
                        .font(.caption)
                        .foregroundStyle(ConstellationTheme.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ConstellationTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                quotaPanel
                if preferences.enabledProviders.contains(.claude), let message = store.claudeState.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(message)
                        if store.claudeState.offersLogin {
                            Button("Sign in") { store.signInToClaude() }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(ConstellationTheme.amber)
                }
                footer
            }
            .padding(18)
        }
        // MenuBarExtra needs a definite content height; an unconstrained
        // ScrollView can produce an invisible zero-height popover.
        .frame(height: 650)
        .background(ConstellationTheme.background)
        .foregroundStyle(ConstellationTheme.text)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE CANVAS")
                    .font(.caption2.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(ConstellationTheme.secondary)
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.subheadline)
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .help("Settings")
            }
            Text("Work in motion")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .tracking(-0.8)
            Text(preferences.showSessionRunway
                 ? "\(presentation.activeCount) active · \(presentation.waitingCount) waiting · \(formatSessionRefreshAge(sessionStore.snapshot.capturedAt, now: now))"
                 : "Local activity is hidden")
                .font(.caption)
                .foregroundStyle(ConstellationTheme.secondary)
        }
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("SESSION RUNWAY")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(ConstellationTheme.secondary)
                Spacer()
                Text(sessionStore.snapshot.status.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(sessionStore.snapshot.status == .ready ? ConstellationTheme.violet : ConstellationTheme.amber)
                Button(showingList ? "Map" : "List") { showingList.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel(showingList ? "Show session map" : "Show session list")
            }
            if sessionStore.snapshot.status != .ready {
                Text(sessionStore.snapshot.status.detail)
                    .font(.caption2)
                    .foregroundStyle(ConstellationTheme.amber)
            }
            if showingList {
                sessionList
            } else {
                ConstellationMap(sessions: presentation.visibleSessions, liveCount: presentation.activeCount + presentation.waitingCount, now: now)
                    .frame(height: 248)
            }
            if let diagnostic = presentation.diagnosticText {
                Text(diagnostic)
                    .font(.caption2)
                    .foregroundStyle(ConstellationTheme.secondary)
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.visibleSessions.isEmpty {
                Text("No active sessions detected")
                    .font(.caption)
                    .foregroundStyle(ConstellationTheme.secondary)
                    .padding(14)
            } else {
                ForEach(presentation.visibleSessions) { session in
                    SessionActivityRow(session: session, state: session.state, now: now)
                        .padding(.horizontal, 12)
                    if session.id != presentation.visibleSessions.last?.id {
                        Divider().overlay(ConstellationTheme.line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConstellationTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var quotaPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("QUOTAS · USED")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(ConstellationTheme.secondary)
                Spacer()
                Text("Select for model usage")
                    .font(.caption2)
                    .foregroundStyle(ConstellationTheme.secondary)
            }
            if preferences.visibleProviders.isEmpty {
                Text("All providers are disabled. Open Settings to enable one.")
                    .font(.caption)
                    .foregroundStyle(ConstellationTheme.secondary)
            } else {
                ForEach(preferences.visibleProviders) { provider in
                    Button { openModelUsage(provider) } label: {
                        quotaRows(for: provider)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(provider.displayName) model usage")
                    if provider != preferences.visibleProviders.last {
                        Divider().overlay(ConstellationTheme.line)
                    }
                }
            }
        }
        .padding(14)
        .background(ConstellationTheme.surface, in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private func quotaRows(for provider: MenuBarProvider) -> some View {
        if let quota = quota(for: provider) {
            VStack(alignment: .leading, spacing: 9) {
                if let pct = quota.fiveHourPct {
                    ConstellationQuotaRow(label: "\(provider.displayName) · 5-hour", pct: pct, resetsAt: quota.fiveHourResetsAt, now: now)
                }
                if let pct = quota.weeklyPct {
                    ConstellationQuotaRow(label: "\(provider.displayName) · weekly", pct: pct, resetsAt: quota.weeklyResetsAt, now: now)
                }
                if quota.fiveHourPct == nil && quota.weeklyPct == nil {
                    Text("\(provider.displayName) · no quota data yet")
                        .font(.caption)
                        .foregroundStyle(ConstellationTheme.secondary)
                }
                if let staleness = quota.staleness, staleness > 3600, quota.id != "claude" {
                    Text("Snapshot \(Int(staleness / 3600))h old")
                        .font(.caption2)
                        .foregroundStyle(ConstellationTheme.amber)
                }
                if let device = quota.sourceDevice, device != "local" {
                    Text("via \(device)")
                        .font(.caption2)
                        .foregroundStyle(ConstellationTheme.secondary)
                }
            }
        } else {
            Text("\(provider.displayName) · no quota data yet")
                .font(.caption)
                .foregroundStyle(ConstellationTheme.secondary)
        }
    }

    private func quota(for provider: MenuBarProvider) -> ProviderQuota? {
        switch provider {
        case .codex: return store.codex
        case .claude: return store.claude
        case .grok: return store.grok
        }
    }

    private var footer: some View {
        HStack {
            if preferences.enabledProviders.contains(.claude) {
                Link("Open Claude usage", destination: URL(string: "https://claude.ai/settings/usage")!)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(ConstellationTheme.secondary)
        .padding(.top, 4)
    }
}

private struct ConstellationMap: View {
    let sessions: [MenuBarSession]
    let liveCount: Int
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RadialGradient(colors: [ConstellationTheme.surface, ConstellationTheme.background], center: .center, startRadius: 15, endRadius: 270)
                Path { path in
                    for index in sessions.indices {
                        path.move(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                        path.addLine(to: nodePosition(index, in: geometry.size))
                    }
                }
                .stroke(ConstellationTheme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
                .accessibilityHidden(true)
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    ConstellationNode(session: session, now: now)
                        .frame(width: 142)
                        .position(nodePosition(index, in: geometry.size))
                }
                VStack(spacing: 1) {
                    Text("\(liveCount)")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                }
                .foregroundStyle(ConstellationTheme.background)
                .frame(width: 79, height: 79)
                .background(ConstellationTheme.text, in: Circle())
                .overlay(Circle().stroke(ConstellationTheme.violet.opacity(0.35), lineWidth: 7))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .accessibilityLabel("\(liveCount) live sessions")
                if sessions.isEmpty {
                    Text("No active sessions detected")
                        .font(.caption)
                        .foregroundStyle(ConstellationTheme.secondary)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 28)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func nodePosition(_ index: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: index.isMultiple(of: 2) ? 78 : size.width - 78,
                y: index < 2 ? 55 : size.height - 55)
    }
}

private struct ConstellationNode: View {
    let session: MenuBarSession
    let now: Date

    private var accent: Color {
        session.state == .active ? ConstellationTheme.violet : ConstellationTheme.amber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sessionRunwayTitle(for: session))
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("\(session.state.title) · \(session.displayProvider)")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(ConstellationTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ConstellationTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayProvider), \(sessionRunwayTitle(for: session)), \(session.state.title), \(formatLastActivity(session.lastActivity, now: now)), \(formatSessionBurn(session.burn))")
    }
}

private struct ConstellationQuotaRow: View {
    let label: String
    let pct: Double
    let resetsAt: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ConstellationTheme.line)
                    Capsule().fill(ConstellationTheme.violet)
                        .frame(width: max(2, geometry.size.width * min(max(pct, 0), 100) / 100))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(resetsAt.map { formatCountdown(to: $0, now: now) } ?? "reset time unavailable")
                .font(.caption2)
                .foregroundStyle(ConstellationTheme.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(pct.rounded())) percent used")
    }
}
