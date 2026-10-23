import Foundation
@testable import PiMenuBarCore

/// Fixture-backed parser/formatting/cache tests.
private enum ClaudeUsageFixture {
    static let now = Date(millis: 1_792_000_000_000)

    static func data() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-usage.json")
        return try Data(contentsOf: url)
    }

    static func parse(_ json: String, warningPercent: Int = 75) throws -> ClaudeUsageSnapshot {
        try ClaudeUsageParser.parse(Data(json.utf8), now: now, warningPercent: warningPercent)
    }

    static func resetColumn(_ text: String) -> Int? {
        text.range(of: "resets").map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }
}

func registerClaudeUsageTests(_ t: TestRunner) {
    let now = ClaudeUsageFixture.now

    t.test("FixturePrefersLimitsAndParsesEverythingOptional") {
        let snapshot = try ClaudeUsageParser.parse(
            ClaudeUsageFixture.data(),
            now: now,
            warningPercent: 75
        )
        expectEqual(snapshot.fetchedAt, now)
        expectEqual(snapshot.session?.percent, 78)
        expectEqual(snapshot.session?.severity, .warning)
        expectEqual(snapshot.weekly?.percent, 9)
        expectEqual(snapshot.weekly?.severity, .normal)
        expectEqual(snapshot.claudeCodeShare, 100)
        expectNotNil(snapshot.session?.resetsAt, "limits[] timestamps carry microseconds")
        expectNotNil(snapshot.weekly?.resetsAt)
    }

    t.test("LimitsWinOverTheLegacyObjects") {
        let snapshot = try ClaudeUsageFixture.parse("""
        {
          "limits": [
            {"kind": "session", "percent": 42, "severity": "critical"},
            {"kind": "weekly_all", "percent": 7, "severity": "normal"}
          ],
          "five_hour": {"utilization": 90},
          "seven_day": {"utilization": 80}
        }
        """)
        expectEqual(snapshot.session?.percent, 42)
        expectEqual(snapshot.session?.severity, .critical)
        expectEqual(snapshot.weekly?.percent, 7)
    }

    t.test("LegacyOnlyPayloadStillParses") {
        let snapshot = try ClaudeUsageFixture.parse("""
        {
          "five_hour": {"utilization": 12.4, "resets_at": "2026-10-26T08:00:00+00:00"},
          "seven_day": {"utilization": 3}
        }
        """)
        expectEqual(snapshot.session?.percent, 12, "12.4 must round, not truncate")
        expectNotNil(snapshot.session?.resetsAt, "the legacy timestamp has no fractional seconds")
        expectEqual(snapshot.weekly?.percent, 3)
        expectNil(snapshot.weekly?.resetsAt)
    }

    t.test("AMissingLimitStaysNilInsteadOfZero") {
        let snapshot = try ClaudeUsageFixture.parse(#"{"five_hour": {"utilization": 12}}"#)
        expectEqual(snapshot.session?.percent, 12)
        expectNil(snapshot.weekly, "no seven_day object means no weekly value, not 0%")
        expectNil(snapshot.claudeCodeShare)
    }

    t.test("PercentRoundsAndClamps") {
        let rounded = try ClaudeUsageFixture.parse("""
        {"limits": [{"kind": "session", "percent": 99.6}, {"kind": "weekly_all", "percent": -4}]}
        """)
        expectEqual(rounded.session?.percent, 100, "99.6 rounds up")
        expectEqual(rounded.weekly?.percent, 0, "negative values clamp")

        let clamped = try ClaudeUsageFixture.parse("""
        {"limits": [{"kind": "session", "percent": 1500}, {"kind": "weekly_all", "percent": 1200.4}]}
        """)
        expectEqual(clamped.session?.percent, 999)
        expectEqual(clamped.weekly?.percent, 999)
    }

    t.test("AMalformedResetTimeKeepsThePercentage") {
        let snapshot = try ClaudeUsageFixture.parse("""
        {"five_hour": {"utilization": 33, "resets_at": "yesterday-ish"}}
        """)
        expectEqual(snapshot.session?.percent, 33)
        expectNil(snapshot.session?.resetsAt)
    }

    t.test("SeverityFallsBackToWarningPercent") {
        let warning = try ClaudeUsageFixture.parse(#"{"five_hour": {"utilization": 80}}"#, warningPercent: 75)
        expectEqual(warning.session?.severity, .warning)

        let normal = try ClaudeUsageFixture.parse(#"{"five_hour": {"utilization": 74}}"#, warningPercent: 75)
        expectEqual(normal.session?.severity, .normal)

        let critical = try ClaudeUsageFixture.parse(#"{"five_hour": {"utilization": 95}}"#, warningPercent: 75)
        expectEqual(critical.session?.severity, .critical)

        // The API's own severity wins when it is present, even if the percentage is high.
        let apiSaysNormal = try ClaudeUsageFixture.parse("""
        {"limits": [{"kind": "session", "percent": 99, "severity": "normal"}]}
        """)
        expectEqual(apiSaysNormal.session?.severity, .normal)
    }

    t.test("UnknownKeysAndUnknownLimitKindsAreIgnored") {
        let snapshot = try ClaudeUsageFixture.parse("""
        {
          "tangelo": {"anything": [1, 2, 3]},
          "limits": [
            {"kind": "seven_day_opus", "percent": 55, "severity": "critical"},
            {"kind": "session", "percent": 10}
          ],
          "iguana_necktie": true
        }
        """)
        expectEqual(snapshot.session?.percent, 10)
        expectNil(snapshot.weekly)
    }

    t.test("NonJSONBodyIsTheOnlyHardFailure") {
        expectThrows(
            try ClaudeUsageParser.parse(Data("not json".utf8), now: now, warningPercent: 75)
        ) { error in
            expectEqual(error as? ClaudeUsageParseError, .invalidJSON)
        }
    }

    t.test("CacheRoundTripPreservesDatesAndIsOwnerOnly") {
        let directory = TestSupport.TempDirectory()
        let path = (directory.path as NSString).appendingPathComponent("claude-usage.json")
        let snapshot = ClaudeUsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_792_000_000.123456),
            session: ClaudeUsageLimit(
                percent: 78,
                severity: .warning,
                resetsAt: Date(timeIntervalSince1970: 1_792_007_000.147042)
            ),
            weekly: ClaudeUsageLimit(percent: 9, severity: .normal),
            claudeCodeShare: 100
        )
        expectTrue(ClaudeUsageCache.save(snapshot, path: path))
        let loaded = try unwrap(ClaudeUsageCache.load(path: path))
        expectEqual(loaded, snapshot, "the cache must preserve sub-second dates")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        expectEqual(permissions, 0o600)
    }

    t.test("MenuLinesAlignAndDescribeResets") {
        let snapshot = ClaudeUsageSnapshot(
            fetchedAt: now,
            session: ClaudeUsageLimit(
                percent: 78,
                severity: .warning,
                resetsAt: now.addingTimeInterval(2 * 3_600 + 4 * 60)
            ),
            weekly: ClaudeUsageLimit(
                percent: 9,
                severity: .normal,
                resetsAt: now.addingTimeInterval(3 * 86_400)
            )
        )
        let lines = ClaudeUsageFormat.menuLines(snapshot, now: now)
        expectEqual(lines.count, 2)
        expectEqual(lines[0].1, .warning)
        expectEqual(lines[1].1, .normal)
        expectTrue(lines[0].0.hasPrefix("5-hour"), lines[0].0)
        expectTrue(lines[0].0.contains("78%"), lines[0].0)
        expectTrue(lines[0].0.contains("⚠"), lines[0].0)
        expectTrue(lines[0].0.contains("resets in 2h 4m"), lines[0].0)
        expectFalse(lines[1].0.contains("⚠"), lines[1].0)
        expectTrue(lines[1].0.hasPrefix("7-day"), lines[1].0)
        expectTrue(lines[1].0.contains("9%"), lines[1].0)
        expectTrue(lines[1].0.contains("resets "), lines[1].0)
        expectFalse(lines[1].0.contains("resets in"), "a weekly reset uses an absolute weekday/time")

        let sessionColumn = try unwrap(ClaudeUsageFixture.resetColumn(lines[0].0))
        let weeklyColumn = try unwrap(ClaudeUsageFixture.resetColumn(lines[1].0))
        expectEqual(sessionColumn, weeklyColumn, "the reset text must start in the same column")
        expectEqual(sessionColumn, 16)
    }

    t.test("MenuLinesReportAMissingResetExplicitly") {
        let snapshot = ClaudeUsageSnapshot(
            fetchedAt: now,
            session: ClaudeUsageLimit(percent: 4, severity: .normal, resetsAt: nil)
        )
        let lines = ClaudeUsageFormat.menuLines(snapshot, now: now)
        expectEqual(lines.count, 1)
        expectTrue(lines[0].0.contains("reset time unknown"), lines[0].0)
    }

    t.test("TitleSuffixAndSeverity") {
        let both = ClaudeUsageSnapshot(
            fetchedAt: now,
            session: ClaudeUsageLimit(percent: 78, severity: .warning),
            weekly: ClaudeUsageLimit(percent: 9, severity: .normal)
        )
        expectEqual(ClaudeUsageFormat.titleSuffix(both), "78% · 9%")
        expectEqual(ClaudeUsageFormat.titleSeverity(both), .warning)

        let weeklyOnly = ClaudeUsageSnapshot(
            fetchedAt: now,
            weekly: ClaudeUsageLimit(percent: 9, severity: .critical)
        )
        expectEqual(ClaudeUsageFormat.titleSuffix(weeklyOnly), "9%")
        expectEqual(ClaudeUsageFormat.titleSeverity(weeklyOnly), .critical)

        expectEqual(ClaudeUsageFormat.titleSuffix(ClaudeUsageSnapshot(fetchedAt: now)), "")
        expectEqual(ClaudeUsageFormat.titleSeverity(ClaudeUsageSnapshot(fetchedAt: now)), .normal)
    }
}
