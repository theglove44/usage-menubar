import Combine
import Foundation

// The menu bar's source of numbers: how much of your Claude and Codex allowance is
// used, and when it resets.
//
// Two sources feed it. Snapshot files written by the usage dashboard under
// ~/.claude/usage-dashboard are read every 60 seconds and cost nothing. Claude's own
// account API is called at most every 5 minutes, because it is rate limited and will
// push back if asked more often. Live API figures win over the snapshot when both
// are present, which is what hasAccountClaudeUsage and lastAccountSuccess track.
//
// If this file stops working the menu shows stale or empty numbers - it never blocks
// the app.

@MainActor
final class QuotaStore: ObservableObject {
    @Published var claude: ProviderQuota?
    @Published var codex: ProviderQuota?
    @Published var grok: ProviderQuota?
    @Published var claudeState: ClaudeUsageState = .refreshing

    private let claudeMergedPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits-merged.json").expandingTildeInPath
    private let claudeLocalPath = NSString(string: "~/.claude/usage-dashboard/claude-rate-limits.json").expandingTildeInPath
    private let codexPath = NSString(string: "~/.claude/usage-dashboard/codex-rate-limits.json").expandingTildeInPath
    private let grokLogPath = NSString(string: "~/.grok/logs/unified.jsonl").expandingTildeInPath
    private let dependencies: QuotaDependencies
    private var enabledProviders: Set<MenuBarProvider>
    private var preferencesSubscription: AnyCancellable?
    private var timer: Timer?
    private var refreshInProgress = false
    private var hasAccountClaudeUsage = false
    private var lastAccountSuccess: Date?
    private var nextAccountRefresh = Date.distantPast
    private let accountRefreshInterval: TimeInterval = 5 * 60

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let iso = ISO8601DateFormatter()

    init(dependencies: QuotaDependencies = .live, startImmediately: Bool = true,
         preferences: MenuBarPreferences? = nil) {
        self.dependencies = dependencies
        enabledProviders = preferences?.enabledProviders ?? Set(MenuBarProvider.allCases)
        preferencesSubscription = preferences?.$enabledProviders.dropFirst().sink { [weak self] enabled in
            self?.enabledProviders = enabled
            self?.refreshSnapshots()
            if startImmediately {
                Task { await self?.refreshClaudeAccountUsage() }
            }
        }
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
        if enabledProviders.contains(.claude), let snapshot = loadClaudeSnapshot(),
           !hasAccountClaudeUsage || snapshot.capturedAt.map({ $0 > (lastAccountSuccess ?? .distantPast) }) == true {
            claude = snapshot.quota
        }
        if enabledProviders.contains(.codex) { codex = loadCodex() }
        if enabledProviders.contains(.grok) { grok = loadGrok() }
    }

    // Asks Claude's API for current usage, at most once per refresh interval, skipping
    // entirely if a previous attempt is still running.
    func refreshClaudeAccountUsage() async {
        guard enabledProviders.contains(.claude) else { return }
        guard !refreshInProgress else { return }
        guard dependencies.now() >= nextAccountRefresh else { return }
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
        guard enabledProviders.contains(.claude) else { return }
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

    // Handles the three answers the API gives besides success: 401 means the saved
    // credentials expired, so refresh them once and retry; 429 means slow down, so back
    // off until the time it names; anything else is reported as a failed request rather
    // than being silently ignored.
    private func requestUsage(credentials: ClaudeCredentials, mayRefreshAfterUnauthorized: Bool) async {
        guard enabledProviders.contains(.claude) else { return }
        do {
            let response = try await dependencies.fetchUsage(credentials.claudeAiOauth.accessToken)
            if response.statusCode == 401, mayRefreshAfterUnauthorized {
                await refreshCredentialsAndUsage()
                return
            }
            if response.statusCode == 429 {
                nextAccountRefresh = dependencies.now().addingTimeInterval(
                    max(response.retryAfter ?? accountRefreshInterval, accountRefreshInterval)
                )
                refreshSnapshots()
                claudeState = .rateLimited
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
            lastAccountSuccess = dependencies.now()
            nextAccountRefresh = dependencies.now().addingTimeInterval(accountRefreshInterval)
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

    private func loadClaudeSnapshot() -> (quota: ProviderQuota, capturedAt: Date?)? {
        let path = FileManager.default.fileExists(atPath: claudeMergedPath) ? claudeMergedPath : claudeLocalPath
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(ClaudeLimits.self, from: data)
        else { return nil }
        let capturedAt = parseDate(decoded.captured_at)
        let quota = ProviderQuota(
            id: "claude",
            name: "Claude",
            fiveHourPct: decoded.five_hour.used_percentage,
            fiveHourResetsAt: Date(timeIntervalSince1970: decoded.five_hour.resets_at),
            weeklyPct: decoded.seven_day.used_percentage,
            weeklyResetsAt: Date(timeIntervalSince1970: decoded.seven_day.resets_at),
            staleness: capturedAt.map { dependencies.now().timeIntervalSince($0) },
            sourceDevice: decoded.source_device
        )
        return (quota, capturedAt)
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

    // Reads the tail of the Grok CLI's log rather than the whole thing — the file
    // grows without rotation and only the newest billing line matters. 4 MiB is
    // roughly the log's total size after two weeks, so the newest billing line
    // (typically within the last 100 KiB) is always inside the window.
    private func loadGrok() -> ProviderQuota? {
        guard let handle = FileHandle(forReadingAtPath: grokLogPath) else { return nil }
        defer { try? handle.close() }
        let tailLimit: UInt64 = 4 * 1024 * 1024
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > tailLimit ? size - tailLimit : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        return GrokLimits.latestQuota(fromLogData: data, now: dependencies.now())
    }
}
