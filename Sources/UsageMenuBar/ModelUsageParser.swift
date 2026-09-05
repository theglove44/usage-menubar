import Foundation
import CoreFoundation

// One streaming parser per file. It retains usage metadata only, never message
// bodies. Quota percentages and runway's sampled burn rate are not token totals.
struct ModelUsageParser {
    let provider: MenuBarProvider
    var sessionID: String
    var model = "Unknown model"
    private var previousCodexUsage: UsageTokens?
    private var previousCodexTotal: Int64?
    private(set) var events: [ModelUsageEvent] = []
    private let iso = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(provider: MenuBarProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }

    mutating func consume(_ object: [String: Any], since cutoff: Date, now: Date) {
        switch provider {
        case .codex: consumeCodex(object, cutoff: cutoff, now: now)
        case .claude: consumeClaude(object, cutoff: cutoff, now: now)
        case .grok: consumeGrok(object, cutoff: cutoff, now: now)
        }
    }

    private mutating func consumeCodex(_ object: [String: Any], cutoff: Date, now: Date) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "session_meta" {
            sessionID = payload["id"] as? String ?? sessionID
        }
        if object["type"] as? String == "turn_context" {
            model = safeModel(payload["model"] as? String)
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let cumulative = info["total_token_usage"] as? [String: Any]
        else { return }
        let total = count(cumulative, "total_tokens")
        let current = codexTokens(cumulative)
        let previous = previousCodexUsage
        let previousTotal = previousCodexTotal
        previousCodexUsage = current
        previousCodexTotal = total
        // Repeated quota-only events repeat the last usage; do not bill it twice.
        guard current != previous || total != previousTotal else { return }
        let tokens: UsageTokens
        if let last = info["last_token_usage"] as? [String: Any] {
            tokens = codexTokens(last)
        } else if let previous, total >= (previousTotal ?? 0) {
            tokens = current.increasedSince(previous)
        } else {
            // Without a per-request reading or baseline we cannot place a session
            // lifetime total into the selected date range reliably.
            return
        }
        guard let date = date(object["timestamp"]), date >= cutoff, date <= now else { return }
        append(id: "codex:\(sessionID):\(date.timeIntervalSince1970):\(total)", model: model, date: date, tokens: tokens)
    }

    private mutating func consumeClaude(_ object: [String: Any], cutoff: Date, now: Date) {
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String,
              let date = date(object["timestamp"]), date >= cutoff, date <= now
        else { return }
        let writes = count(usage, "cache_creation_input_tokens")
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        let hour = min(writes, count(creation, "ephemeral_1h_input_tokens"))
        let tokens = UsageTokens(input: count(usage, "input_tokens"), cachedInput: count(usage, "cache_read_input_tokens"),
                                 cacheWrite: writes - hour, cacheWriteHour: hour, output: count(usage, "output_tokens"))
        append(id: "claude:\(id)", model: safeModel(message["model"] as? String), date: date, tokens: tokens)
    }

    private mutating func consumeGrok(_ object: [String: Any], cutoff: Date, now: Date) {
        guard let params = object["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any],
              let date = date(object["timestamp"]), date >= cutoff, date <= now
        else { return }
        let session = params["sessionId"] as? String ?? sessionID
        let turn = update["prompt_id"] as? String ?? String(date.timeIntervalSince1970)
        let models = usage["modelUsage"] as? [String: [String: Any]] ?? ["Unknown model": usage]
        for (name, value) in models {
            let input = count(value, "inputTokens")
            let cached = min(input, count(value, "cachedReadTokens"))
            let writes = min(input - cached, count(value, "cacheCreationTokens"))
            let tokens = UsageTokens(input: input - cached - writes, cachedInput: cached, cacheWrite: writes,
                                     output: count(value, "outputTokens"))
            let model = safeModel(name)
            append(id: "grok:\(session):\(turn):\(model)", model: model, date: date, tokens: tokens)
        }
    }

    private mutating func append(id: String, model: String, date: Date, tokens: UsageTokens) {
        guard tokens.total > 0 else { return }
        events.append(ModelUsageEvent(id: id, model: model, date: date, tokens: tokens))
    }

    private func codexTokens(_ usage: [String: Any]) -> UsageTokens {
        let input = count(usage, "input_tokens")
        let cached = min(input, count(usage, "cached_input_tokens"))
        let writes = min(input - cached, count(usage, "cache_write_input_tokens"))
        return UsageTokens(input: input - cached - writes, cachedInput: cached,
                           cacheWrite: writes, output: count(usage, "output_tokens"))
    }

    private func count(_ value: [String: Any], _ key: String) -> Int64 {
        guard let number = value[key] as? NSNumber else { return 0 }
        let raw = number.doubleValue
        // Reject corrupt counts instead of overflowing totals or trusting booleans.
        guard CFGetTypeID(number) != CFBooleanGetTypeID(), raw.isFinite,
              raw >= 0, raw <= 1_000_000_000_000, raw.rounded(.down) == raw else { return 0 }
        return number.int64Value
    }

    private func safeModel(_ value: String?) -> String {
        guard let value, value.count <= 100,
              value.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$"#, options: .regularExpression) != nil
        else { return "Unknown model" }
        return value
    }

    private func date(_ value: Any?) -> Date? {
        if let string = value as? String { return fractional.date(from: string) ?? iso.date(from: string) }
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            guard seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        return nil
    }
}
