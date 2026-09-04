import XCTest
@testable import UsageMenuBar

final class GrokLimitsTests: XCTestCase {
    // A real (trimmed) line from ~/.grok/logs/unified.jsonl.
    private func billingLine(ts: String = "2026-09-03T06:28:12.448Z", pct: Double = 32.0) -> String {
        """
        {"ts":"\(ts)","src":"shell","pid":21026,"ver":"1.0.13","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":\(pct),"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-27T13:05:01.539882+00:00","end":"2026-09-03T13:05:01.539882+00:00"},"isUnifiedBillingUser":true},"subscriptionTier":"SuperGrok"}}
        """
    }

    private let otherLine = """
    {"ts":"2026-09-03T06:28:12.320Z","src":"grok-pager","pid":21026,"lvl":"info","msg":"agent response complete"}
    """

    func testParsesNewestBillingLineIntoWeeklyQuota() {
        let log = [otherLine, billingLine(pct: 30.0), otherLine, billingLine(pct: 32.0), otherLine]
            .joined(separator: "\n")
        let now = GrokLimits.parseDate("2026-09-03T07:28:12.448Z")!

        let quota = GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: now)

        XCTAssertEqual(quota?.id, "grok")
        XCTAssertEqual(quota?.weeklyPct, 32.0)
        XCTAssertNil(quota?.fiveHourPct)
        XCTAssertEqual(quota?.weeklyResetsAt, GrokLimits.parseDate("2026-09-03T13:05:01.539+00:00"))
        // Captured an hour before "now", so staleness is one hour.
        XCTAssertEqual(quota?.staleness ?? 0, 3600, accuracy: 1)
    }

    func testIgnoresLogsWithoutBillingLines() {
        let log = [otherLine, otherLine].joined(separator: "\n")
        XCTAssertNil(GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: Date()))
    }

    func testIgnoresGarbageAndEmptyInput() {
        XCTAssertNil(GrokLimits.latestQuota(fromLogData: Data(), now: Date()))
        XCTAssertNil(GrokLimits.latestQuota(fromLogData: Data("not json\n{broken".utf8), now: Date()))
        // A line mentioning the billing message inside another field must not decode.
        let impostor = """
        {"ts":"2026-09-03T06:00:00.000Z","msg":"other","note":"billing: fetched credits config"}
        """
        XCTAssertNil(GrokLimits.latestQuota(fromLogData: Data(impostor.utf8), now: Date()))
    }

    func testSkipsTruncatedFirstLineFromTailRead() {
        // Reading a fixed-size tail can slice the first line in half; the parser
        // must skip it and use the intact newer billing line.
        let truncated = String(billingLine(pct: 30.0).dropFirst(40))
        let log = [truncated, billingLine(pct: 31.0)].joined(separator: "\n")

        let quota = GrokLimits.latestQuota(fromLogData: Data(log.utf8), now: Date())

        XCTAssertEqual(quota?.weeklyPct, 31.0)
    }

    func testParsesMicrosecondFractionDates() {
        XCTAssertNotNil(GrokLimits.parseDate("2026-09-03T13:05:01.539882+00:00"))
        XCTAssertNotNil(GrokLimits.parseDate("2026-09-03T06:28:12.448Z"))
        XCTAssertNotNil(GrokLimits.parseDate("2026-09-03T06:28:12Z"))
        XCTAssertNil(GrokLimits.parseDate("not a date"))
    }
}
