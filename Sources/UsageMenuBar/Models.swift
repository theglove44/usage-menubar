import Foundation

struct ClaudeLimits: Decodable {
    struct Window: Decodable {
        let used_percentage: Double
        let resets_at: Double
    }
    let captured_at: String
    let five_hour: Window
    let seven_day: Window
    let cost_usd: Double?
    let model: String?
    // Present when read from claude-rate-limits-merged.json: which device
    // (this Mac, or a synced remote like "mac-mini") produced the freshest
    // snapshot. Absent when reading the raw per-device file directly.
    let source_device: String?
}

struct ClaudeAccountUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resets_at: String
    }

    let five_hour: Window?
    let seven_day: Window?
}

struct ClaudeCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
    }

    let claudeAiOauth: OAuth
}

enum ClaudeUsageState: Equatable {
    case ready
    case refreshing
    case cliMissing
    case loginRequired
    case rateLimited
    case networkUnavailable
    case requestFailed

    var message: String? {
        switch self {
        case .ready, .refreshing:
            return nil
        case .cliMissing:
            return "Claude CLI not found · showing latest snapshot"
        case .loginRequired:
            return "Claude login required · showing latest snapshot"
        case .rateLimited:
            return "Claude account polling rate-limited · showing latest snapshot"
        case .networkUnavailable:
            return "Claude account usage unavailable offline · showing latest snapshot"
        case .requestFailed:
            return "Claude account usage request failed · showing latest snapshot"
        }
    }

    var offersLogin: Bool {
        self == .loginRequired
    }
}

struct CodexLimits: Decodable {
    struct Window: Decodable {
        let used_percent: Double
        let window_minutes: Double
        let resets_at: Double
    }
    let captured_at: String
    let primary: Window?
    let secondary: Window?
    let plan_type: String?

    private var windows: [Window] {
        [primary, secondary].compactMap { $0 }
    }

    var fiveHourWindow: Window? {
        windows.first { $0.window_minutes < 24 * 60 }
    }

    var weeklyWindow: Window? {
        windows.first { $0.window_minutes >= 24 * 60 }
    }
}

// Grok usage comes from the Grok CLI's log at ~/.grok/logs/unified.jsonl. After
// each completed turn the CLI fetches the account's credit usage from xAI's
// billing service and logs it as a "billing: fetched credits config" line. That
// number is the whole SuperGrok subscription's weekly usage, not this machine's
// share — but it only refreshes while the Grok CLI is used on this Mac, which is
// why the staleness field matters for this provider.
enum GrokLimits {
    static let billingMessage = "billing: fetched credits config"

    struct LogRecord: Decodable {
        struct Ctx: Decodable { let config: Config }
        struct Config: Decodable {
            let creditUsagePercent: Double
            let currentPeriod: Period?
        }
        struct Period: Decodable { let end: String }
        let ts: String
        let msg: String
        let ctx: Ctx
    }

    // Scans JSONL data backwards for the newest billing line and maps it onto the
    // shared ProviderQuota shape. Grok only has a weekly window, no 5-hour one.
    static func latestQuota(fromLogData data: Data, now: Date) -> ProviderQuota? {
        guard let record = latestBillingRecord(in: data) else { return nil }
        let capturedAt = parseDate(record.ts)
        return ProviderQuota(
            id: "grok",
            name: "Grok",
            fiveHourPct: nil,
            fiveHourResetsAt: nil,
            weeklyPct: record.ctx.config.creditUsagePercent,
            weeklyResetsAt: record.ctx.config.currentPeriod.flatMap { parseDate($0.end) },
            staleness: capturedAt.map { now.timeIntervalSince($0) },
            sourceDevice: "xAI account"
        )
    }

    private static func latestBillingRecord(in data: Data) -> LogRecord? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n").reversed() {
            guard line.contains(billingMessage),
                  let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(LogRecord.self, from: lineData),
                  record.msg == billingMessage
            else { continue }
            return record
        }
        return nil
    }

    // The log mixes fraction lengths ("...12.448Z" and "...01.539882+00:00");
    // ISO8601DateFormatter only accepts exactly three fractional digits, so trim
    // longer fractions to milliseconds before parsing.
    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        if let date = fractional.date(from: string) ?? plain.date(from: string) {
            return date
        }
        let trimmed = string.replacingOccurrences(
            of: #"(\.\d{3})\d+"#,
            with: "$1",
            options: .regularExpression
        )
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}

// Unified shape the view renders, so Claude/Codex share one code path.
struct ProviderQuota: Identifiable {
    let id: String
    let name: String
    let fiveHourPct: Double?
    let fiveHourResetsAt: Date?
    let weeklyPct: Double?
    let weeklyResetsAt: Date?
    let staleness: TimeInterval? // seconds since the snapshot file was captured
    let sourceDevice: String? // which device the freshest reading came from, when known
}
