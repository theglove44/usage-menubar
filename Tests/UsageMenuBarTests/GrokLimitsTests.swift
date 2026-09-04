import Foundation
import Testing
@testable import UsageMenuBar

struct GrokLimitsTests {
    // A real (trimmed) line from ~/.grok/logs/unified.jsonl.
    private func billingLine(ts: String = "2026-09-03T06:28:12.448Z", pct: Double = 32.0) -> String {
        """
        {"ts":"\(ts)","src":"shell","pid":21026,"ver":"1.0.13","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":\(pct),"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-27T13:05:01.539882+00:00","end":"2026-09-03T13:05:01.539882+00:00"},"isUnifiedBillingUser":true},"subscriptionTier":"SuperGrok"}}
        """
    }

    private let otherLine = """
    {"ts":"2026-09-03T06:28:12.320Z","src":"grok-pager","pid":21026,"lvl":"info","msg":"agent response complete"}
    """

    @Test func parsesNewestBillingLineIntoWeeklyQuota() throws {
        let log = [otherLine, billingLine(pct: 30.0), otherLine, billingLine(pct: 32.0), otherLine]
            .joined(separator: "\n")
        let now = try #require(GrokLimits.parseDate("2026-09-03T07:28:12.448Z"))

        let quota = GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: now)

        #expect(quota?.id == "grok")
        #expect(quota?.weeklyPct == 32.0)
        #expect(quota?.fiveHourPct == nil)
        #expect(quota?.weeklyResetsAt == GrokLimits.parseDate("2026-09-03T13:05:01.539+00:00"))
        // Captured an hour before "now", so staleness is one hour.
        #expect(abs((quota?.staleness ?? 0) - 3600) < 1)
    }

    @Test func ignoresLogsWithoutBillingLines() {
        let log = [otherLine, otherLine].joined(separator: "\n")
        #expect(GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: Date()) == nil)
    }

    @Test func ignoresGarbageAndEmptyInput() {
        #expect(GrokLimits.latestQuota(fromLogData: Data(), now: Date()) == nil)
        #expect(GrokLimits.latestQuota(fromLogData: Data("not json\n{broken".utf8), now: Date()) == nil)
        // A line mentioning the billing message inside another field must not decode.
        let impostor = """
        {"ts":"2026-09-03T06:00:00.000Z","msg":"other","note":"billing: fetched credits config"}
        """
        #expect(GrokLimits.latestQuota(fromLogData: Data(impostor.utf8), now: Date()) == nil)
    }

    @Test func skipsTruncatedFirstLineFromTailRead() {
        // Reading a fixed-size tail can slice the first line in half; the parser
        // must skip it and use the intact newer billing line.
        let truncated = String(billingLine(pct: 30.0).dropFirst(40))
        let log = [truncated, billingLine(pct: 31.0)].joined(separator: "\n")

        let quota = GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: Date())

        #expect(quota?.weeklyPct == 31.0)
    }

    @Test func parsesMicrosecondFractionDates() {
        #expect(GrokLimits.parseDate("2026-09-03T13:05:01.539882+00:00") != nil)
        #expect(GrokLimits.parseDate("2026-09-03T06:28:12.448Z") != nil)
        #expect(GrokLimits.parseDate("2026-09-03T06:28:12Z") != nil)
        #expect(GrokLimits.parseDate("not a date") == nil)
    }
}
