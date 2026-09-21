import Darwin
import Foundation

/// One "the user has seen this" record.
///
/// Two independent pieces of evidence, because the two sources complete differently:
///  - `herdrStateChangeSeq` acknowledges exactly one herdr completion generation, so a
///    repeated `done` snapshot cannot resurrect a badge the user already cleared.
///  - `acknowledgedAt` covers registry-only rows, where completion is a timestamp.
public struct Acknowledgement: Codable, Sendable, Equatable {
    public var acknowledgedAt: Int64
    public var herdrStateChangeSeq: Int64?

    public init(acknowledgedAt: Date, herdrStateChangeSeq: Int64? = nil) {
        self.acknowledgedAt = acknowledgedAt.millis
        self.herdrStateChangeSeq = herdrStateChangeSeq
    }

    public var date: Date { Date(millis: acknowledgedAt) }
}

/// Decides whether a completed or blocked session still wants the user's eyes.
///
/// Kept as a pure function: this is the rule that a heartbeat, a re-snapshot, or an app
/// restart must never break, so it is unit tested directly.
public enum AttentionRules {
    public static func needsAttention(
        state: SessionState,
        focused: Bool,
        settledAt: Date?,
        herdrStateChangeSeq: Int64?,
        acknowledgement: Acknowledgement?
    ) -> Bool {
        if focused { return false }
        switch state {
        case .blocked:
            return true
        case .done:
            guard let acknowledgement else { return true }
            if let current = herdrStateChangeSeq, let acknowledged = acknowledgement.herdrStateChangeSeq {
                return current != acknowledged
            }
            if let settledAt {
                return settledAt > acknowledgement.date
            }
            return false
        case .idle:
            guard let settledAt else { return false }
            guard let acknowledgement else { return true }
            return settledAt > acknowledgement.date
        case .working, .unknown:
            return false
        }
    }
}

/// App-owned, persistent acknowledgement store.
///
/// The registry deliberately has no `unseen` flag: if it did, the extension's heartbeat
/// would immediately resurrect a badge the user just cleared. Ownership lives here.
public struct AcknowledgementStore: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var entries: [String: Acknowledgement]

    public init(version: Int = AcknowledgementStore.currentVersion, entries: [String: Acknowledgement] = [:]) {
        self.version = version
        self.entries = entries
    }

    public subscript(key: String) -> Acknowledgement? { entries[key] }

    public mutating func acknowledge(key: String, at date: Date, herdrStateChangeSeq: Int64?) {
        // Never move an acknowledgement backwards: a delayed event must not re-flag a
        // completion the user already cleared.
        if let existing = entries[key], existing.date > date { return }
        entries[key] = Acknowledgement(acknowledgedAt: date, herdrStateChangeSeq: herdrStateChangeSeq)
    }

    public mutating func prune(now: Date, retentionDays: Int) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        entries = entries.filter { $0.value.date >= cutoff }
    }

    public static func load(path: String) -> AcknowledgementStore {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(AcknowledgementStore.self, from: data),
              store.version == currentVersion
        else { return AcknowledgementStore() }
        return store
    }

    /// Atomic, owner-only write. Best effort: a read-only home must not break the app.
    @discardableResult
    public func write(to path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        let temporary = "\(path).tmp.\(getpid())"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
    }
}
