import SwiftUI

// Everything you actually see in the dropdown: the coloured usage bars, each
// provider's card, and the reset countdowns. Display only - it holds no data of its
// own and calculates nothing beyond formatting, reading from QuotaStore and
// SessionActivityStore.

// Green through amber to red as the bar fills. Driven by a single hue calculation
// rather than fixed thresholds, so the colour shifts smoothly instead of jumping.
func barColor(_ pct: Double) -> Color {
    let progress = min(max(pct, 0), 100) / 100
    return Color(
        hue: 0.14 * (1 - progress),
        saturation: 0.95,
        brightness: 1
    )
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
    let brand: ProviderBrand

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
                let clampedPct = min(max(pct, 0), 100)
                let progress = clampedPct / 100
                let fillWidth = geo.size.width * progress
                let logoSize = 14.0
                let logoX = min(
                    max(fillWidth, logoSize / 2),
                    geo.size.width - logoSize / 2
                )

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 7)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(clampedPct))
                        .frame(width: max(2, fillWidth), height: 7)
                    ProviderLogo(brand: brand)
                        .frame(width: logoSize, height: logoSize)
                        .offset(x: logoX - logoSize / 2)
                        .shadow(
                            color: barColor(clampedPct).opacity(progress),
                            radius: progress * 3
                        )
                }
                .frame(maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.35), value: clampedPct)
            }
            .frame(height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) usage")
            .accessibilityValue("\(Int(pct.rounded())) percent")
            Text(formatCountdown(to: resetsAt, now: now))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ProviderCard: View {
    let quota: ProviderQuota
    let now: Date

    private var brand: ProviderBrand {
        ProviderBrand(rawValue: quota.id) ?? .codex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(quota.name)
                .font(.subheadline.bold())
            if let pct = quota.fiveHourPct, let resets = quota.fiveHourResetsAt {
                QuotaBar(
                    label: "5-hour used",
                    pct: pct,
                    resetsAt: resets,
                    now: now,
                    brand: brand
                )
            }
            if let pct = quota.weeklyPct, let resets = quota.weeklyResetsAt {
                QuotaBar(
                    label: "Weekly used",
                    pct: pct,
                    resetsAt: resets,
                    now: now,
                    brand: brand
                )
            }
            if let staleness = quota.staleness, staleness > 3600, quota.id != "claude" {
                Text(stalenessText(hours: Int(staleness / 3600)))
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

    private func stalenessText(hours: Int) -> String {
        return "quota snapshot \(hours)h old"
    }
}

struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var sessionStore: SessionActivityStore
    @ObservedObject var preferences: MenuBarPreferences
    @State private var now = Date()
    @State private var showingSettings = false
    @State private var selectedProvider: MenuBarProvider?
    @State private var usageScanner = ModelUsageScanner()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if showingSettings {
                AppSettingsView(preferences: preferences) { showingSettings = false }
            } else if let provider = selectedProvider {
                ModelUsageView(provider: provider, scanner: usageScanner) { selectedProvider = nil }
                    .id(provider)
            } else {
                dashboard
            }
        }
        .padding(12)
        .frame(width: 470)
        .onReceive(clock) { t in now = t }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage Quotas").font(.headline)
                Spacer()
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            Text("% used, not remaining (Codex's own app shows remaining)")
                .font(.caption2).foregroundStyle(.secondary)

            if preferences.visibleProviders.isEmpty {
                Text("All providers are disabled. Open Settings to enable a provider.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(preferences.visibleProviders) { provider in
                        Button { selectedProvider = provider } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if let quota = quota(for: provider) {
                                    ProviderCard(quota: quota, now: now)
                                } else {
                                    emptyCard(provider.displayName, "no quota data yet")
                                }
                                Label("Model usage", systemImage: "chart.bar")
                                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(provider.displayName) model usage")
                        .help("View tokens and API-equivalent cost by model")
                    }
                }
            }
            if preferences.enabledProviders.contains(.claude), let message = store.claudeState.message {
                HStack(spacing: 8) {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                    if store.claudeState.offersLogin {
                        Button("Sign in to Claude") { store.signInToClaude() }.font(.caption2)
                    }
                }
            }
            if preferences.showSessionRunway {
                SessionActivitySection(store: sessionStore, now: now)
            }
            Divider()
            HStack {
                if preferences.enabledProviders.contains(.claude) {
                    Link("Open Claude usage", destination: URL(string: "https://claude.ai/settings/usage")!)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).font(.caption)
        }
    }

    private func quota(for provider: MenuBarProvider) -> ProviderQuota? {
        switch provider {
        case .codex: return store.codex
        case .claude: return store.claude
        case .grok: return store.grok
        }
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
    @ObservedObject var preferences: MenuBarPreferences

    var body: some View {
        let provider = preferences.effectiveProvider
        let pct = provider.flatMap { store.menuBarPct(for: $0) }
        HStack(spacing: 4) {
            if let image = renderMenuBarGauge(pct: pct) {
                Image(nsImage: image)
            }
            Text(provider.map { menuBarLabelText(provider: $0, pct: pct) } ?? "Usage")
        }
    }
}

extension QuotaStore {
    // The menu bar shows the shortest window that has data, because that is the
    // limit you are most likely to hit next.
    func menuBarPct(for provider: MenuBarProvider) -> Double? {
        let quota: ProviderQuota?
        switch provider {
        case .codex: quota = codex
        case .claude: quota = claude
        case .grok: quota = grok
        }
        return quota.flatMap { $0.fiveHourPct ?? $0.weeklyPct }
    }
}
