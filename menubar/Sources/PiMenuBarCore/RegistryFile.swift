import Darwin
import Foundation

/// One `registry v1` file written by the pi-side extension.
///
/// Timestamps are integer milliseconds since the Unix epoch on the wire; the `date`
/// helpers convert at the edge so the rest of the app works in `Date`.
public struct RegistryRecord: Decodable, Sendable, Equatable {
    public let v: Int
    /// Monotonic ordering token. Seeded from `Date.now()*1000` by the writer so a
    /// reloaded extension can never publish a lower revision than its predecessor.
    public let revision: Int64
    public let pid: Int32
    /// `Date.now() - process.uptime()`, rounded: stable across `/reload`, and enough to
    /// disambiguate PID reuse.
    public let processStartedAt: Int64
    public let sessionId: String?
    public let sessionFile: String?
    public let sessionName: String?
    public let cwd: String
    public let project: String?
    public let mode: String?
    public let state: String
    public let stateLabel: String?
    public let blockedKind: String?
    public let model: String?
    public let provider: String?
    public let thinking: String?
    public let contextTokens: Int?
    public let contextWindow: Int?
    public let turnIndex: Int?
    public let activeTools: [RegistryTool]
    public let lastTool: String?
    public let runStartedAt: Int64?
    public let waitingSince: Int64?
    public let settledAt: Int64?
    public let hasPendingMessages: Bool?
    public let lastUserPrompt: String?
    public let terminalBundleId: String?
    public let herdr: RegistryHerdr?
    public let updatedAt: Int64
    /// Dev-only marker used by `menubar/dev/fake-sessions.sh`; ignored unless expired.
    public let simulated: Bool?
    public let expiresAt: Int64?

    public var sessionState: SessionState { SessionState(registryState: state) }
    public var updatedDate: Date { Date(millis: updatedAt) }
    public var runStartedDate: Date? { runStartedAt.map(Date.init(millis:)) }
    public var waitingDate: Date? { waitingSince.map(Date.init(millis:)) }
    public var settledDate: Date? { settledAt.map(Date.init(millis:)) }

    public var activeToolModels: [ActiveTool] {
        activeTools.map { ActiveTool(id: $0.id, name: $0.name, startedAt: Date(millis: $0.startedAt)) }
    }

    /// `sessionFile`, else pid+start identity. Used as the primary merge key.
    public var mergeKey: String {
        if let sessionFile, !sessionFile.isEmpty { return sessionFile }
        return "pid:\(pid):\(processStartedAt)"
    }

    public var isSimulatedAndExpired: (Date) -> Bool {
        { now in
            guard simulated == true else { return false }
            guard let expiresAt else { return true }
            return Date(millis: expiresAt) < now
        }
    }

    public func isStale(now: Date, staleAfterMs: Int) -> Bool {
        now.timeIntervalSince(updatedDate) * 1000 > Double(staleAfterMs)
    }

    public func toSession(acknowledgement: Acknowledgement?, now: Date) -> Session {
        let state = sessionState
        var session = Session(
            key: mergeKey,
            source: .registry,
            project: project ?? Self.projectName(for: cwd),
            cwd: cwd,
            state: state,
            updatedAt: updatedDate,
            sessionName: sessionName,
            sessionFile: sessionFile,
            sessionId: sessionId,
            mode: mode,
            focused: false,
            stateLabel: stateLabel,
            model: model,
            thinking: thinking,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            activeTools: activeToolModels,
            runStartedAt: runStartedDate,
            waitingSince: waitingDate,
            settledAt: settledDate,
            lastUserPrompt: lastUserPrompt,
            herdr: herdr.map {
                HerdrRef(
                    paneId: $0.paneId,
                    tabId: $0.tabId,
                    workspaceId: $0.workspaceId,
                    focused: false,
                    stateChangeSeq: nil
                )
            },
            terminalBundleId: terminalBundleId,
            simulated: simulated ?? false
        )
        session.needsAttention = AttentionRules.needsAttention(
            state: session.state,
            focused: false,
            settledAt: session.settledAt,
            herdrStateChangeSeq: nil,
            acknowledgement: acknowledgement
        )
        return session
    }

    public static func projectName(for cwd: String) -> String {
        // Keep "/" as "/" rather than trimming it to an empty label.
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let base = (trimmed as NSString).lastPathComponent
        return base.isEmpty ? trimmed : base
    }
}

public struct RegistryTool: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let startedAt: Int64
}

public struct RegistryHerdr: Decodable, Sendable, Equatable {
    public let paneId: String
    public let workspaceId: String?
    public let tabId: String?
    public let socketPath: String?
}

public extension Date {
    init(millis: Int64) {
        self.init(timeIntervalSince1970: Double(millis) / 1000)
    }

    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

public extension SessionState {
    /// Maps the registry's vocabulary. The extension publishes
    /// `idle | working | blocked`.
    init(registryState: String) {
        switch registryState {
        case "working": self = .working
        case "blocked": self = .blocked
        case "idle": self = .idle
        case "done": self = .done
        default: self = .unknown
        }
    }
}

public struct RegistryIssue: Sendable, Equatable {
    public let path: String
    public let reason: String
}

public struct RegistryScan: Sendable {
    public let records: [RegistryRecord]
    public let issues: [RegistryIssue]
    /// Files removed by the age-based garbage collector.
    public let removedPaths: [String]
}

/// Reads, validates, ages out and garbage collects the registry directory.
///
/// Only regular files owned by the current user are read; symlinks and
/// group/other-accessible files are skipped and reported. Nothing here throws:
/// a broken registry must never stop the menu bar from showing herdr state.
public enum RegistryReader {
    public static let currentVersion = 1

    public static func scan(
        directory: String,
        config: MenuBarConfig,
        now: Date = Date(),
        collectGarbage: Bool = true
    ) -> RegistryScan {
        let fileManager = FileManager.default
        var issues: [RegistryIssue] = []
        var removed: [String] = []
        var decoded: [(record: RegistryRecord, path: String, revision: Int64)] = []
        var seenIdentity: [String: Int64] = [:]

        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return RegistryScan(records: [], issues: [], removedPaths: [])
        }

        let staleSeconds = Double(config.staleAfterMs) / 1000
        let ageLimit = now.addingTimeInterval(-staleSeconds * 10)

        for name in entries.sorted() {
            let path = (directory as NSString).appendingPathComponent(name)
            let isTemporary = name.contains(".tmp.")
            guard name.hasSuffix(".json") || isTemporary else { continue }

            guard let stat = lstatOrNil(path) else { continue }
            guard (stat.st_mode & S_IFMT) == S_IFREG else {
                if !isTemporary { issues.append(RegistryIssue(path: path, reason: "not a regular file")) }
                continue
            }
            guard stat.st_uid == getuid() else {
                if !isTemporary { issues.append(RegistryIssue(path: path, reason: "owned by uid \(stat.st_uid)")) }
                continue
            }
            // The writer creates 0600 inside an 0700 directory; anything group/other
            // accessible is either an old writer or tampering, so do not read it.
            if stat.st_mode & 0o077 != 0 {
                if !isTemporary { issues.append(RegistryIssue(path: path, reason: "group/other permissions set")) }
                continue
            }

            if isTemporary {
                if collectGarbage, modificationDate(stat) < ageLimit {
                    if removeIfPossible(path) { removed.append(path) }
                }
                continue
            }

            guard stat.st_size > 0, stat.st_size < 1 << 20 else {
                issues.append(RegistryIssue(path: path, reason: "implausible size \(stat.st_size)"))
                continue
            }
            guard let data = fileManager.contents(atPath: path) else {
                issues.append(RegistryIssue(path: path, reason: "unreadable"))
                continue
            }
            let record: RegistryRecord
            do {
                record = try JSONDecoder().decode(RegistryRecord.self, from: data)
            } catch {
                issues.append(RegistryIssue(path: path, reason: "malformed: \(shortReason(error))"))
                continue
            }
            guard record.v == currentVersion else {
                issues.append(RegistryIssue(path: path, reason: "unsupported registry version \(record.v)"))
                continue
            }
            if record.isSimulatedAndExpired(now) { continue }
            if record.isStale(now: now, staleAfterMs: config.staleAfterMs) {
                if collectGarbage, record.updatedDate < ageLimit, removeIfPossible(path) {
                    removed.append(path)
                }
                continue
            }

            // A process that republishes faster than the scan can read may briefly have
            // two files; keep the newest revision for each process identity.
            let identity = "\(record.pid):\(record.processStartedAt)"
            if let previous = seenIdentity[identity], previous >= record.revision {
                continue
            }
            seenIdentity[identity] = record.revision
            decoded.append((record, path, record.revision))
        }

        // Drop any earlier revision that a newer duplicate displaced.
        var newest: [String: (record: RegistryRecord, path: String, revision: Int64)] = [:]
        for entry in decoded {
            let identity = "\(entry.record.pid):\(entry.record.processStartedAt)"
            if let existing = newest[identity], existing.revision >= entry.revision { continue }
            newest[identity] = entry
        }

        return RegistryScan(
            records: newest.values.map(\.record),
            issues: issues,
            removedPaths: removed
        )
    }

    private static func shortReason(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, _): return "missing key \(key.stringValue)"
            case let .typeMismatch(_, context): return "type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case let .valueNotFound(_, context): return "null at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted: return "invalid JSON"
            @unknown default: return "decoding error"
            }
        }
        return "\(error)"
    }

    private static func lstatOrNil(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info
    }

    private static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    private static func removeIfPossible(_ path: String) -> Bool {
        (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    /// Creates the registry directory with owner-only permissions.
    public static func ensureDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(domain: "PiMenuBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "registry path is not a directory"])
            }
        } else {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }
}
