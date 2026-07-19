import XCTest
@testable import UsageMenuBar

final class CodexLimitsTests: XCTestCase {
    func testClaudeAccountUsageDecodesAccountWideWindows() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 23.5,
            "resets_at": "2026-07-18T18:00:00Z"
          },
          "seven_day": {
            "utilization": 41.0,
            "resets_at": "2026-07-24T00:00:00Z"
          }
        }
        """

        let usage = try JSONDecoder().decode(ClaudeAccountUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.five_hour?.utilization, 23.5)
        XCTAssertEqual(usage.seven_day?.utilization, 41.0)
    }

    func testWeeklyOnlySnapshotDecodesAndMapsPrimaryAsWeekly() throws {
        let json = """
        {
          "captured_at": "2026-07-16T05:53:17.192Z",
          "plan_type": "plus",
          "primary": {
            "used_percent": 12,
            "window_minutes": 10080,
            "resets_at": 1784785996
          },
          "secondary": null
        }
        """

        let limits = try JSONDecoder().decode(CodexLimits.self, from: Data(json.utf8))

        XCTAssertNil(limits.fiveHourWindow)
        XCTAssertEqual(limits.weeklyWindow?.used_percent, 12)
        XCTAssertEqual(limits.weeklyWindow?.window_minutes, 10080)
    }
}
