import Foundation
import Combine
import Security

@MainActor
final class QuotaStore: ObservableObject {
    @Published var claude: ProviderQuota?
    @Published var codex: ProviderQuota?
    @Published var lastError: String?

    // Prefer the multi-device merged snapshot (freshest across this Mac +
    // any synced remote devices — see sync-claude-limits.sh); fall back to
    // this device's own raw capture if the merge hasn't run yet.
    private let claudeMergedPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits-merged.json").expandingTildeInPath
    private let claudeLocalPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits.json").expandingTildeInPath
    private let codexPath = NSString(string: "~/.claude/usage-dashboard/codex-rate-limits.json").expandingTildeInPath
    private let claudeCredentialsPath = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
    private let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

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
        Task { await refreshClaudeAccountUsage() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                await self?.refreshClaudeAccountUsage()
            }
        }
    }

    func refresh() {
        claude = loadClaude()
        codex = loadCodex()
    }

    private func loadClaude() -> ProviderQuota? {
        let path = FileManager.default.fileExists(atPath: claudeMergedPath) ? claudeMergedPath : claudeLocalPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ClaudeLimits.self, from: data) else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let staleness = capturedAt.map { Date().timeIntervalSince($0) }
        return ProviderQuota(
            id: "claude",
            name: "Claude",
            fiveHourPct: decoded.five_hour.used_percentage,
            fiveHourResetsAt: Date(timeIntervalSince1970: decoded.five_hour.resets_at),
            weeklyPct: decoded.seven_day.used_percentage,
            weeklyResetsAt: Date(timeIntervalSince1970: decoded.seven_day.resets_at),
            staleness: staleness,
            sourceDevice: decoded.source_device
        )
    }

    private func refreshClaudeAccountUsage() async {
        guard let credentialsData = loadClaudeCredentialsData(),
              let credentials = try? JSONDecoder().decode(ClaudeCredentials.self, from: credentialsData)
        else {
            lastError = "Account usage unavailable · run `claude auth login`"
            return
        }
        if let expiresAt = credentials.claudeAiOauth.expiresAt,
           expiresAt <= Date().timeIntervalSince1970 * 1000 {
            lastError = "Claude login expired · run `claude auth login`"
            return
        }

        var request = URLRequest(url: claudeUsageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("usage-menubar/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Claude account usage request failed"
                return
            }
            let usage = try JSONDecoder().decode(ClaudeAccountUsage.self, from: data)
            let fiveHourReset = usage.five_hour.flatMap { parseDate($0.resets_at) }
            let weeklyReset = usage.seven_day.flatMap { parseDate($0.resets_at) }
            claude = ProviderQuota(
                id: "claude",
                name: "Claude",
                fiveHourPct: usage.five_hour?.utilization,
                fiveHourResetsAt: fiveHourReset,
                weeklyPct: usage.seven_day?.utilization,
                weeklyResetsAt: weeklyReset,
                staleness: 0,
                sourceDevice: "Anthropic account"
            )
            lastError = nil
        } catch {
            lastError = "Claude account usage unavailable: \(error.localizedDescription)"
        }
    }

    private func loadClaudeCredentialsData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return data
        }
        return FileManager.default.contents(atPath: claudeCredentialsPath)
    }

    private func loadCodex() -> ProviderQuota? {
        guard let data = FileManager.default.contents(atPath: codexPath) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CodexLimits.self, from: data) else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let staleness = capturedAt.map { Date().timeIntervalSince($0) }
        let fiveHour = decoded.fiveHourWindow
        let weekly = decoded.weeklyWindow
        return ProviderQuota(
            id: "codex",
            name: "Codex",
            fiveHourPct: fiveHour?.used_percent,
            fiveHourResetsAt: fiveHour.map { Date(timeIntervalSince1970: $0.resets_at) },
            weeklyPct: weekly?.used_percent,
            weeklyResetsAt: weekly.map { Date(timeIntervalSince1970: $0.resets_at) },
            staleness: staleness,
            sourceDevice: nil
        )
    }
}
