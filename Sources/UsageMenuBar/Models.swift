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
