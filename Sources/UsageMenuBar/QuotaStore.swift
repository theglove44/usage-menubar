import Combine
import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    @Published var claude: ProviderQuota?
    @Published var codex: ProviderQuota?
    @Published var claudeState: ClaudeUsageState = .refreshing

    private let claudeMergedPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits-merged.json").expandingTildeInPath
    private let claudeLocalPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits.json").expandingTildeInPath
    private let codexPath = NSString(string: "~/.claude/usage-dashboard/codex-rate-limits.json").expandingTildeInPath
    private let dependencies: QuotaDependencies
    private var timer: Timer?
    private var refreshInProgress = false
    private var hasAccountClaudeUsage = false

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let iso = ISO8601DateFormatter()

    init(dependencies: QuotaDependencies = .live, startImmediately: Bool = true) {
        self.dependencies = dependencies
        refreshSnapshots()
        guard startImmediately else { return }
        Task { await refreshClaudeAccountUsage() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSnapshots()
                await self?.refreshClaudeAccountUsage()
            }
        }
    }

    func refreshSnapshots() {
        if !hasAccountClaudeUsage { claude = loadClaudeSnapshot() }
        codex = loadCodex()
    }

    func refreshClaudeAccountUsage() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        claudeState = .refreshing

        guard let credentials = decodeCredentials() else {
            await refreshCredentialsAndUsage()
            return
        }
        if isExpired(credentials) {
            await refreshCredentialsAndUsage()
            return
        }
        await requestUsage(credentials: credentials, mayRefreshAfterUnauthorized: true)
    }

    func signInToClaude() {
        do {
            try dependencies.launchLogin()
        } catch {
            claudeState = .cliMissing
        }
    }

    private func refreshCredentialsAndUsage() async {
        switch await dependencies.refreshCLI() {
        case .refreshed:
            guard let credentials = decodeCredentials(), !isExpired(credentials) else {
                claudeState = .loginRequired
                return
            }
            await requestUsage(credentials: credentials, mayRefreshAfterUnauthorized: false)
        case .missing:
            claudeState = .cliMissing
        case .loginRequired:
            claudeState = .loginRequired
        case .timedOut, .failed:
            claudeState = .requestFailed
        }
    }

    private func requestUsage(credentials: ClaudeCredentials, mayRefreshAfterUnauthorized: Bool) async {
        do {
            let response = try await dependencies.fetchUsage(credentials.claudeAiOauth.accessToken)
            if response.statusCode == 401, mayRefreshAfterUnauthorized {
                await refreshCredentialsAndUsage()
                return
            }
            guard response.statusCode == 200,
                  let usage = try? JSONDecoder().decode(ClaudeAccountUsage.self, from: response.data)
            else {
                claudeState = response.statusCode == 401 ? .loginRequired : .requestFailed
                return
            }
            claude = ProviderQuota(
                id: "claude",
                name: "Claude",
                fiveHourPct: usage.five_hour?.utilization,
                fiveHourResetsAt: usage.five_hour.flatMap { parseDate($0.resets_at) },
                weeklyPct: usage.seven_day?.utilization,
                weeklyResetsAt: usage.seven_day.flatMap { parseDate($0.resets_at) },
                staleness: 0,
                sourceDevice: "Anthropic account"
            )
            hasAccountClaudeUsage = true
            claudeState = .ready
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            claudeState = .networkUnavailable
        } catch {
            claudeState = .requestFailed
        }
    }

    private func decodeCredentials() -> ClaudeCredentials? {
        dependencies.readCredentials().flatMap { try? JSONDecoder().decode(ClaudeCredentials.self, from: $0) }
    }

    private func isExpired(_ credentials: ClaudeCredentials) -> Bool {
        guard let expiresAt = credentials.claudeAiOauth.expiresAt else { return false }
        return expiresAt <= dependencies.now().timeIntervalSince1970 * 1000
    }

    private func parseDate(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? iso.date(from: string)
    }

    private func loadClaudeSnapshot() -> ProviderQuota? {
        let path = FileManager.default.fileExists(atPath: claudeMergedPath) ? claudeMergedPath : claudeLocalPath
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(ClaudeLimits.self, from: data)
        else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        return ProviderQuota(
            id: "claude",
            name: "Claude",
            fiveHourPct: decoded.five_hour.used_percentage,
            fiveHourResetsAt: Date(timeIntervalSince1970: decoded.five_hour.resets_at),
            weeklyPct: decoded.seven_day.used_percentage,
            weeklyResetsAt: Date(timeIntervalSince1970: decoded.seven_day.resets_at),
            staleness: capturedAt.map { dependencies.now().timeIntervalSince($0) },
            sourceDevice: decoded.source_device
        )
    }

    private func loadCodex() -> ProviderQuota? {
        guard let data = FileManager.default.contents(atPath: codexPath),
              let decoded = try? JSONDecoder().decode(CodexLimits.self, from: data)
        else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let fiveHour = decoded.fiveHourWindow
        let weekly = decoded.weeklyWindow
        return ProviderQuota(
            id: "codex",
            name: "Codex",
            fiveHourPct: fiveHour?.used_percent,
            fiveHourResetsAt: fiveHour.map { Date(timeIntervalSince1970: $0.resets_at) },
            weeklyPct: weekly?.used_percent,
            weeklyResetsAt: weekly.map { Date(timeIntervalSince1970: $0.resets_at) },
            staleness: capturedAt.map { dependencies.now().timeIntervalSince($0) },
            sourceDevice: nil
        )
    }
}
