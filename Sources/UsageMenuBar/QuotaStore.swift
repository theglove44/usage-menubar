import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published var claude: ProviderQuota?
    @Published var codex: ProviderQuota?
    @Published var lastError: String?

    private let claudePath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits.json").expandingTildeInPath
    private let codexPath = NSString(string: "~/.claude/usage-dashboard/codex-rate-limits.json").expandingTildeInPath

    private var timer: Timer?
    // Claude's captured_at has no fractional seconds; Codex's does. Try both.
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    private func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? iso.date(from: s)
    }

    init() {
        refresh()
        // Local file read only — no network. 20s is plenty since the source
        // files themselves only change when Codex/Claude sessions are active.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        claude = loadClaude()
        codex = loadCodex()
    }

    private func loadClaude() -> ProviderQuota? {
        guard let data = FileManager.default.contents(atPath: claudePath) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ClaudeLimits.self, from: data) else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let staleness = capturedAt.map { Date().timeIntervalSince($0) }
        return ProviderQuota(
            id: "claude",
            name: "Claude Code",
            fiveHourPct: decoded.five_hour.used_percentage,
            fiveHourResetsAt: Date(timeIntervalSince1970: decoded.five_hour.resets_at),
            weeklyPct: decoded.seven_day.used_percentage,
            weeklyResetsAt: Date(timeIntervalSince1970: decoded.seven_day.resets_at),
            staleness: staleness
        )
    }

    private func loadCodex() -> ProviderQuota? {
        guard let data = FileManager.default.contents(atPath: codexPath) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CodexLimits.self, from: data) else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let staleness = capturedAt.map { Date().timeIntervalSince($0) }
        return ProviderQuota(
            id: "codex",
            name: "Codex",
            fiveHourPct: decoded.primary.used_percent,
            fiveHourResetsAt: Date(timeIntervalSince1970: decoded.primary.resets_at),
            weeklyPct: decoded.secondary.used_percent,
            weeklyResetsAt: Date(timeIntervalSince1970: decoded.secondary.resets_at),
            staleness: staleness
        )
    }
}
