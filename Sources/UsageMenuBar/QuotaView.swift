import SwiftUI

func barColor(_ pct: Double) -> Color {
    if pct >= 85 { return .red }
    if pct >= 60 { return .orange
    }
    return .green
}

func formatCountdown(to date: Date, now: Date) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "resets now" }
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    if hours >= 24 {
        let days = hours / 24
        let remHours = hours % 24
        return "resets in \(days)d \(remHours)h"
    }
    if hours > 0 { return "resets in \(hours)h \(minutes)m" }
    return "resets in \(minutes)m"
}

struct QuotaBar: View {
    let label: String
    let pct: Double
    let resetsAt: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundStyle(barColor(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(pct))
                        .frame(width: max(2, geo.size.width * min(pct, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(formatCountdown(to: resetsAt, now: now))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ProviderCard: View {
    let quota: ProviderQuota
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(quota.name)
                .font(.subheadline.bold())
            if let pct = quota.fiveHourPct, let resets = quota.fiveHourResetsAt {
                QuotaBar(label: "5-hour used", pct: pct, resetsAt: resets, now: now)
            }
            if let pct = quota.weeklyPct, let resets = quota.weeklyResetsAt {
                QuotaBar(label: "Weekly used", pct: pct, resetsAt: resets, now: now)
            }
            if let staleness = quota.staleness, staleness > 3600 {
                Text("frozen · no \(quota.name) session in \(Int(staleness / 3600))h")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let device = quota.sourceDevice, device != "local" {
                Text("via \(device)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    @State private var now = Date()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Quotas")
                .font(.headline)
            Text("% used, not remaining (Codex's own app shows remaining)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            HStack(alignment: .top, spacing: 10) {
                if let codex = store.codex {
                    ProviderCard(quota: codex, now: now)
                } else {
                    emptyCard("Codex", "no data yet")
                }
                if let claude = store.claude {
                    ProviderCard(quota: claude, now: now)
                } else {
                    emptyCard("Claude Code", "no data yet")
                }
            }

            Divider()

            Button("Open full dashboard") {
                if let url = URL(string: "http://localhost:8484") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320)
        .onReceive(clock) { t in now = t }
    }

    private func emptyCard(_ name: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.bold())
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        let codexPct = store.codex?.fiveHourPct
        let claudePct = store.claude?.fiveHourPct
        Text(labelText(codex: codexPct, claude: claudePct))
    }

    private func labelText(codex: Double?, claude: Double?) -> String {
        let c = codex.map { "\(Int($0.rounded()))%" } ?? "--"
        let cl = claude.map { "\(Int($0.rounded()))%" } ?? "--"
        return "C \(c)u · CC \(cl)u"
    }
}
