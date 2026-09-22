import SwiftUI
import Combine

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
                ScrollView {
                    AppSettingsView(preferences: preferences) { showingSettings = false }
                        .padding(18)
                }
            } else if let provider = selectedProvider {
                ScrollView {
                    ModelUsageView(provider: provider, scanner: usageScanner) { selectedProvider = nil }
                        .id(provider)
                        .padding(18)
                }
            } else {
                ConstellationDashboard(
                    store: store,
                    sessionStore: sessionStore,
                    preferences: preferences,
                    now: now,
                    openSettings: { showingSettings = true },
                    openModelUsage: { selectedProvider = $0 }
                )
            }
        }
        .frame(width: 470, height: 650, alignment: .top)
        .background(ConstellationTheme.background)
        .environment(\.colorScheme, .dark)
        .onReceive(clock) { t in now = t }
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
