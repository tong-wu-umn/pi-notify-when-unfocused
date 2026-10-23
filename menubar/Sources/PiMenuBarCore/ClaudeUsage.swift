import Foundation

/// One utilisation bucket from the Claude subscription usage endpoint.
///
/// Percent is already rounded and clamped by the parser; the raw API can return a
/// fractional value (`78.0`) and, in unusual cases, out-of-range numbers.
public struct ClaudeUsageLimit: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable, CaseIterable {
        case normal, warning, critical

        /// Ordering for "worst wins" when two limits are shown in one title suffix.
        public var rank: Int {
            switch self {
            case .normal: return 0
            case .warning: return 1
            case .critical: return 2
            }
        }
    }

    public var percent: Int
    public var severity: Severity
    public var resetsAt: Date?

    public init(percent: Int, severity: Severity, resetsAt: Date? = nil) {
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
    }
}

/// A parsed `/api/oauth/usage` response, plus when PiMenuBar fetched it.
///
/// This is also the cache format. It deliberately contains no token, account id, or
/// per-project data: percentages and reset times only.
public struct ClaudeUsageSnapshot: Sendable, Equatable, Codable {
    public var fetchedAt: Date
    public var session: ClaudeUsageLimit?
    public var weekly: ClaudeUsageLimit?
    /// `seven_day_breakdown.rows[key == "claude_code"].percent`, when present.
    public var claudeCodeShare: Int?

    public init(
        fetchedAt: Date,
        session: ClaudeUsageLimit? = nil,
        weekly: ClaudeUsageLimit? = nil,
        claudeCodeShare: Int? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.session = session
        self.weekly = weekly
        self.claudeCodeShare = claudeCodeShare
    }
}

public enum ClaudeUsageParseError: Error, Equatable {
    case invalidJSON
}

/// Parses the (unofficial) usage endpoint defensively.
///
/// The endpoint ships with the CLI, not as a documented API: every field is optional,
/// `limits[]` is preferred over the older `five_hour`/`seven_day` objects, and a body that
/// is not JSON is the only hard failure. Anything else degrades to a missing limit rather
/// than a crash or a fabricated zero.
public enum ClaudeUsageParser {
    public static func parse(_ data: Data, now: Date, warningPercent: Int) throws -> ClaudeUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw ClaudeUsageParseError.invalidJSON }

        var session: ClaudeUsageLimit?
        var weekly: ClaudeUsageLimit?
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let kind = entry["kind"] as? String else { continue }
                switch kind {
                case "session" where session == nil:
                    session = limit(entry, warningPercent: warningPercent)
                case "weekly_all" where weekly == nil:
                    weekly = limit(entry, warningPercent: warningPercent)
                default:
                    continue
                }
            }
        }

        // Older responses (and some feature-flag branches) only carry these two objects.
        if session == nil, let legacy = root["five_hour"] as? [String: Any] {
            session = limit(legacy, warningPercent: warningPercent)
        }
        if weekly == nil, let legacy = root["seven_day"] as? [String: Any] {
            weekly = limit(legacy, warningPercent: warningPercent)
        }

        var share: Int?
        if let breakdown = root["seven_day_breakdown"] as? [String: Any],
           let rows = breakdown["rows"] as? [[String: Any]] {
            for row in rows where row["key"] as? String == "claude_code" {
                share = percent(row["percent"])
                break
            }
        }

        return ClaudeUsageSnapshot(fetchedAt: now, session: session, weekly: weekly, claudeCodeShare: share)
    }

    private static func limit(_ entry: [String: Any], warningPercent: Int) -> ClaudeUsageLimit? {
        let raw = entry["percent"] ?? entry["utilization"]
        guard let percent = percent(raw) else { return nil }
        let severity = (entry["severity"] as? String).flatMap(ClaudeUsageLimit.Severity.init(rawValue:))
            ?? fallbackSeverity(percent: percent, warningPercent: warningPercent)
        return ClaudeUsageLimit(percent: percent, severity: severity, resetsAt: parseDate(entry["resets_at"]))
    }

    /// Rounding rather than truncation keeps `99.6` from reading as `99`.
    private static func percent(_ any: Any?) -> Int? {
        guard let value = number(any), value.isFinite else { return nil }
        return min(max(Int(value.rounded()), 0), 999)
    }

    private static func fallbackSeverity(percent: Int, warningPercent: Int) -> ClaudeUsageLimit.Severity {
        let threshold = min(max(warningPercent, 0), 100)
        if percent >= 90 { return .critical }
        if percent >= threshold { return .warning }
        return .normal
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    /// The `limits[]` timestamps carry microseconds; the legacy fields currently omit
    /// them. Fractional mode returns nil for the latter, so both passes are required.
    private static func parseDate(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Menu and title text for a snapshot. Formatting stays in core so it is unit tested.
public enum ClaudeUsageFormat {
    /// `78% · 9%`, or just the one limit that exists.
    public static func titleSuffix(_ snapshot: ClaudeUsageSnapshot) -> String {
        [snapshot.session, snapshot.weekly]
            .compactMap { $0.map { "\($0.percent)%" } }
            .joined(separator: " · ")
    }

    public static func titleSeverity(_ snapshot: ClaudeUsageSnapshot) -> ClaudeUsageLimit.Severity {
        [snapshot.session?.severity, snapshot.weekly?.severity]
            .compactMap { $0 }
            .max { $0.rank < $1.rank } ?? .normal
    }

    /// Aligned rows for the menu, one per limit:
    ///
    ///     5-hour   78%  ⚠  resets in 2h 4m
    ///     7-day     9%     resets Mon 04:00
    ///
    /// The severity is returned separately so the AppKit layer can colour the row.
    public static func menuLines(
        _ snapshot: ClaudeUsageSnapshot,
        now: Date
    ) -> [(String, ClaudeUsageLimit.Severity)] {
        var lines: [(String, ClaudeUsageLimit.Severity)] = []
        if let session = snapshot.session {
            lines.append((line("5-hour", session, now: now), session.severity))
        }
        if let weekly = snapshot.weekly {
            lines.append((line("7-day", weekly, now: now), weekly.severity))
        }
        return lines
    }

    private static func line(_ label: String, _ limit: ClaudeUsageLimit, now: Date) -> String {
        let labelColumn = label.padding(toLength: 7, withPad: " ", startingAt: 0)
        let digits = String(limit.percent)
        let percentColumn = String(repeating: " ", count: max(0, 3 - digits.count)) + digits + "%"
        let marker = limit.severity == .normal ? " " : "⚠"
        return "\(labelColumn) \(percentColumn) \(marker)  \(resetText(limit.resetsAt, now: now))"
    }

    private static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "reset time unknown" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        if seconds < 86_400 { return "resets in \(compact(Int(seconds.rounded())))" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return "resets \(formatter.string(from: date))"
    }

    /// Like `DurationLabel` but with a space between hours and minutes, because this text
    /// sits in a free-form menu row rather than a dense session detail line.
    private static func compact(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

/// Owner-only cache of the last good snapshot, so a launch or a network failure can still
/// show numbers (with their timestamp) instead of an empty section.
public enum ClaudeUsageCache {
    public static var path: String {
        let base = ("~/Library/Application Support/PiMenuBar" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("claude-usage.json")
    }

    public static func load(path: String = ClaudeUsageCache.path) -> ClaudeUsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
    }

    /// Best effort: a read-only home must not break the app. The file never contains a
    /// token, but it is still written owner-only (0600 in a 0700 directory).
    @discardableResult
    public static func save(_ snapshot: ClaudeUsageSnapshot, path: String = ClaudeUsageCache.path) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
