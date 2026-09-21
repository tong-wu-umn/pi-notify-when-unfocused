import Foundation

/// Session state as shown in the menu bar.
///
/// `done` is herdr's "finished, not yet acknowledged" state. `idle` means ready for
/// input with nothing new to look at.
public enum SessionState: String, Sendable, CaseIterable, Codable {
    case working
    case blocked
    case idle
    case done
    case unknown

    /// Glyph used in the title and menu rows. Distinct per state so the display stays
    /// readable when macOS tints or hides menu bar colours.
    public var glyph: String {
        switch self {
        case .blocked: return "!"
        case .working: return "▶"
        case .done: return "○"
        case .idle: return "·"
        case .unknown: return "?"
        }
    }

    /// Sort priority for the dropdown: what needs a human first.
    var sortRank: Int {
        switch self {
        case .blocked: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }
}

public struct ActiveTool: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let startedAt: Date

    public init(id: String, name: String, startedAt: Date) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
    }
}

/// Everything the app needs to know about where a session lives in herdr.
public struct HerdrRef: Sendable, Equatable {
    public let paneId: String
    public var tabId: String?
    public var workspaceId: String?
    public var tabLabel: String?
    public var workspaceLabel: String?
    public var tabNumber: Int?
    public var workspaceNumber: Int?
    public var focused: Bool
    /// herdr's monotonic per-pane state counter. Used to acknowledge one specific
    /// completion generation (verify with a captured fixture before trusting it).
    public var stateChangeSeq: Int64?

    public init(
        paneId: String,
        tabId: String? = nil,
        workspaceId: String? = nil,
        tabLabel: String? = nil,
        workspaceLabel: String? = nil,
        tabNumber: Int? = nil,
        workspaceNumber: Int? = nil,
        focused: Bool = false,
        stateChangeSeq: Int64? = nil
    ) {
        self.paneId = paneId
        self.tabId = tabId
        self.workspaceId = workspaceId
        self.tabLabel = tabLabel
        self.workspaceLabel = workspaceLabel
        self.tabNumber = tabNumber
        self.workspaceNumber = workspaceNumber
        self.focused = focused
        self.stateChangeSeq = stateChangeSeq
    }
}

public enum SessionSource: String, Sendable {
    /// Both publishers agree: herdr knows the pane, the registry knows the detail.
    case herdrAndRegistry
    /// herdr only: the registry extension is not installed, or its file aged out.
    case herdr
    /// Registry only: pi outside herdr, or a pane herdr no longer reports.
    case registry
}

/// One row in the menu and one unit in the title summary.
public struct Session: Sendable, Equatable, Identifiable {
    public var id: String { key }

    /// Stable merge identity: session file, else herdr pane, else pid+start time.
    public let key: String
    public var source: SessionSource
    public var sessionName: String?
    public var project: String
    public var cwd: String
    public var sessionFile: String?
    public var sessionId: String?
    public var mode: String?
    public var state: SessionState
    public var needsAttention: Bool
    public var focused: Bool
    public var stateLabel: String?
    public var model: String?
    public var thinking: String?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var activeTools: [ActiveTool]
    public var runStartedAt: Date?
    public var waitingSince: Date?
    public var settledAt: Date?
    public var lastUserPrompt: String?
    public var herdr: HerdrRef?
    public var terminalBundleId: String?
    public var updatedAt: Date
    public var simulated: Bool

    public init(
        key: String,
        source: SessionSource,
        project: String,
        cwd: String,
        state: SessionState,
        updatedAt: Date,
        sessionName: String? = nil,
        sessionFile: String? = nil,
        sessionId: String? = nil,
        mode: String? = nil,
        needsAttention: Bool = false,
        focused: Bool = false,
        stateLabel: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        activeTools: [ActiveTool] = [],
        runStartedAt: Date? = nil,
        waitingSince: Date? = nil,
        settledAt: Date? = nil,
        lastUserPrompt: String? = nil,
        herdr: HerdrRef? = nil,
        terminalBundleId: String? = nil,
        simulated: Bool = false
    ) {
        self.key = key
        self.source = source
        self.project = project
        self.cwd = cwd
        self.state = state
        self.updatedAt = updatedAt
        self.sessionName = sessionName
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.mode = mode
        self.needsAttention = needsAttention
        self.focused = focused
        self.stateLabel = stateLabel
        self.model = model
        self.thinking = thinking
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.activeTools = activeTools
        self.runStartedAt = runStartedAt
        self.waitingSince = waitingSince
        self.settledAt = settledAt
        self.lastUserPrompt = lastUserPrompt
        self.herdr = herdr
        self.terminalBundleId = terminalBundleId
        self.simulated = simulated
    }

    /// Preferred row label: an explicit pi session name, else the project directory.
    public var label: String {
        if let name = sessionName, !name.isEmpty { return name }
        return project
    }

    /// What the menu bar and menu should show. An acknowledged completion is presented
    /// as idle until that session's next state change, so the badge means "new", not
    /// "ever finished".
    public var displayState: SessionState {
        if state == .done, !needsAttention { return .idle }
        return state
    }

    public var contextPercent: Int? {
        guard let tokens = contextTokens, let window = contextWindow, window > 0 else { return nil }
        return Int((Double(tokens) / Double(window) * 100).rounded())
    }

    /// Compact detail line: `bash +1 · 12m · deepseek-flash · 42%`.
    public func detailLine(now: Date) -> String {
        var parts: [String] = []
        // Detail text follows what the row shows: an acknowledged completion is idle, so
        // it must not keep advertising "finished".
        let shown = displayState
        if !activeTools.isEmpty {
            var tools = activeTools[0].name
            if activeTools.count > 1 { tools += " +\(activeTools.count - 1)" }
            parts.append(tools)
        }
        switch shown {
        case .blocked:
            if let since = waitingSince { parts.append("blocked \(DurationLabel.compact(from: since, to: now))") }
            else { parts.append("blocked") }
        case .done:
            if let settled = settledAt { parts.append("finished \(DurationLabel.compact(from: settled, to: now)) ago") }
            else { parts.append("finished") }
        case .working:
            if let started = runStartedAt { parts.append(DurationLabel.compact(from: started, to: now)) }
        case .idle, .unknown:
            break
        }
        if let model { parts.append(model) }
        if let percent = contextPercent { parts.append("\(percent)%") }
        if let stateLabel, !stateLabel.isEmpty { parts.append(stateLabel) }
        return parts.joined(separator: " · ")
    }
}

/// Compact human durations: `45s`, `12m`, `2h7m`, `3d`.
public enum DurationLabel {
    public static func compact(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rem = minutes % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h\(rem)m"
        }
        return "\(hours / 24)d"
    }
}
