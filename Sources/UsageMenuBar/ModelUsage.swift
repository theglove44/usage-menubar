import Foundation

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days"
    var id: String { rawValue }

    func start(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

// Input categories are disjoint. Reasoning is already part of output and must
// never be added a second time. No prompt or response text enters these types.
struct UsageTokens: Equatable, Sendable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWriteHour: Int64 = 0
    var output: Int64 = 0

    var total: Int64 { input + cachedInput + cacheWrite + cacheWriteHour + output }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheWriteHour: lhs.cacheWriteHour + rhs.cacheWriteHour,
             output: lhs.output + rhs.output)
    }

    func increasedSince(_ previous: Self) -> Self {
        Self(input: max(0, input - previous.input), cachedInput: max(0, cachedInput - previous.cachedInput),
             cacheWrite: max(0, cacheWrite - previous.cacheWrite),
             cacheWriteHour: max(0, cacheWriteHour - previous.cacheWriteHour), output: max(0, output - previous.output))
    }

    func mergedMaximum(_ other: Self) -> Self {
        Self(input: max(input, other.input), cachedInput: max(cachedInput, other.cachedInput),
             cacheWrite: max(cacheWrite, other.cacheWrite), cacheWriteHour: max(cacheWriteHour, other.cacheWriteHour),
             output: max(output, other.output))
    }
}

struct ModelUsageEvent: Sendable {
    let id: String
    let model: String
    let date: Date
    var tokens: UsageTokens
}

struct ModelUsageRow: Identifiable {
    let model: String
    var tokens: UsageTokens
    var id: String { model }
    var cost: Double? { ModelPricing.rate(for: model)?.cost(tokens) }
}

struct ModelUsageReport: Sendable {
    var events: [ModelUsageEvent] = []
    var filesRead = 0
    var incompleteFiles = 0
    var sourceAvailable = false
    var capturedAt = Date()

    func rows(since start: Date, until end: Date) -> [ModelUsageRow] {
        var totals: [String: UsageTokens] = [:]
        // Copies of a session can exist in multiple configured roots or archives.
        // Streaming Claude messages may repeat the same request with fuller usage.
        var unique: [String: ModelUsageEvent] = [:]
        for event in events where event.date >= start && event.date <= end {
            if var previous = unique[event.id] {
                previous.tokens = previous.tokens.mergedMaximum(event.tokens)
                unique[event.id] = previous
            } else { unique[event.id] = event }
        }
        for event in unique.values {
            totals[event.model, default: UsageTokens()] = totals[event.model, default: UsageTokens()] + event.tokens
        }
        return totals.map { ModelUsageRow(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.total == $1.tokens.total ? $0.model < $1.model : $0.tokens.total > $1.tokens.total }
    }
}

struct ModelRate {
    let input: Double
    let cached: Double
    let write: Double
    let writeHour: Double
    let output: Double

    func cost(_ tokens: UsageTokens) -> Double {
        (Double(tokens.input) * input + Double(tokens.cachedInput) * cached
         + Double(tokens.cacheWrite) * write + Double(tokens.cacheWriteHour) * writeHour
         + Double(tokens.output) * output) / 1_000_000
    }
}

enum ModelPricing {
    static let checkedDate = "5 September 2026"
    static let openAIURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    static let claudeURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    static let grokURL = URL(string: "https://docs.x.ai/developers/models/grok-4.6")!

    // Standard, short-context USD list rates per million tokens, verified on the
    // date above. This is a comparable baseline, not a subscription invoice or a
    // reconstruction of service-tier/long-context/tool charges. See docs/model-usage.md.
    static func rate(for model: String) -> ModelRate? {
        let name = model.lowercased()
        if let rate = rates[name] { return rate }
        // Only strip an explicit dated snapshot suffix, never fuzzy-match future models.
        if let range = name.range(of: #"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$"#, options: .regularExpression) {
            return rates[String(name[..<range.lowerBound])]
        }
        return nil
    }

    private static let rates: [String: ModelRate] = {
        var result: [String: ModelRate] = [:]
        func add(_ names: [String], _ input: Double, _ cached: Double, _ write: Double, _ hour: Double, _ output: Double) {
            for name in names { result[name] = ModelRate(input: input, cached: cached, write: write, writeHour: hour, output: output) }
        }
        add(["gpt-6-astra"], 10, 1, 12.5, 12.5, 50)
        add(["gpt-5.6-sol"], 4, 0.4, 5, 5, 20)
        add(["gpt-5.6-terra"], 2, 0.2, 2.5, 2.5, 12)
        add(["gpt-5.6-luna"], 0.2, 0.02, 0.25, 0.25, 1.2)
        add(["gpt-5.5"], 5, 0.5, 5, 5, 30)
        add(["claude-fable-5-1", "claude-mythos-5-1"], 10, 0.25, 12.5, 20, 50)
        add(["claude-fable-5", "claude-mythos-5"], 10, 1, 12.5, 20, 50)
        add(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 0.5, 6.25, 10, 25)
        add(["claude-sonnet-5"], 2, 0.2, 2.5, 4, 10)
        add(["claude-sonnet-4-6", "claude-sonnet-4-5"], 3, 0.3, 3.75, 6, 15)
        add(["claude-haiku-4-5"], 1, 0.1, 1.25, 2, 5)
        // The Build variant is explicitly shown as a public Grok 4.6 equivalent.
        add(["grok-4.6", "grok-4.6-build"], 2, 0.5, 2, 2, 6)
        return result
    }()
}
