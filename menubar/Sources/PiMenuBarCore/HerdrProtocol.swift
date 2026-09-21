import Foundation

/// herdr socket API, protocol 22.
///
/// Verified against a live herdr 0.9.1 (`herdr api schema --json`, `herdr api snapshot`,
/// and a real `events.subscribe` session). Only the fields the status bar needs are
/// declared; unknown JSON keys are ignored, and every field that can legitimately be
/// absent is optional so one protocol addition cannot break the decoder.
public enum HerdrProtocol {
    public static let version = 22
    public static let defaultSocketPath = ("~/.config/herdr/herdr.sock" as NSString).expandingTildeInPath
}

public let herdrSupportedProtocolVersion = 22

public struct HerdrError: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
}

public struct HerdrResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    public let id: String?
    public let result: Result?
    public let error: HerdrError?
}

// MARK: - Requests

public struct HerdrRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public let id: String
    public let method: String
    public let params: Params

    public init(id: String, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }

}

/// Request builders. Kept outside `HerdrRequest` because a generic type cannot return
/// differently-parameterised instances of itself from its own static methods.
public enum HerdrRequests {
    public static func snapshot(id: String) -> HerdrRequest<HerdrEmptyParams> {
        HerdrRequest(id: id, method: "session.snapshot", params: HerdrEmptyParams())
    }

    public static func subscribe(id: String, _ subscriptions: [HerdrSubscription]) -> HerdrRequest<HerdrSubscribeParams> {
        HerdrRequest(id: id, method: "events.subscribe", params: HerdrSubscribeParams(subscriptions: subscriptions))
    }

    /// Absolute focus. `herdr pane focus` is directional only, so agent focus by pane id
    /// is the sole absolute primitive; it also marks the target seen.
    public static func focusAgent(id: String, paneId: String) -> HerdrRequest<HerdrFocusTargetParams> {
        HerdrRequest(id: id, method: "agent.focus", params: HerdrFocusTargetParams(target: paneId))
    }

    public static func focusWorkspace(id: String, workspaceId: String) -> HerdrRequest<HerdrWorkspaceFocusParams> {
        HerdrRequest(id: id, method: "workspace.focus", params: HerdrWorkspaceFocusParams(workspaceId: workspaceId))
    }

    public static func focusTab(id: String, tabId: String) -> HerdrRequest<HerdrTabFocusParams> {
        HerdrRequest(id: id, method: "tab.focus", params: HerdrTabFocusParams(tabId: tabId))
    }
}

public struct HerdrEmptyParams: Encodable, Sendable {
    public init() {}
}

public struct HerdrSubscription: Encodable, Sendable, Equatable {
    public let type: String
    /// Required by `pane.agent_status_changed` and `pane.scroll_changed`; omitted for
    /// the global lifecycle events.
    public let paneId: String?

    public init(type: String, paneId: String? = nil) {
        self.type = type
        self.paneId = paneId
    }

    public static func global(_ types: [String]) -> [HerdrSubscription] {
        types.map { HerdrSubscription(type: $0) }
    }

    public static let structuralTypes = [
        "pane.created", "pane.closed", "pane.moved", "pane.exited",
        "pane.focused", "pane.agent_detected",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "workspace.created", "workspace.closed", "workspace.focused",
        "workspace.renamed", "workspace.moved", "workspace.reordered",
    ]
}

public struct HerdrSubscribeParams: Encodable, Sendable {
    public let subscriptions: [HerdrSubscription]
}

public struct HerdrFocusTargetParams: Encodable, Sendable {
    public let target: String
}

public struct HerdrWorkspaceFocusParams: Encodable, Sendable {
    public let workspaceId: String
}

public struct HerdrTabFocusParams: Encodable, Sendable {
    public let tabId: String
}

// MARK: - Responses

public struct HerdrSubscribeAck: Decodable, Sendable {
    public let type: String
}

public struct HerdrSnapshotEnvelope: Decodable, Sendable {
    public let snapshot: HerdrSnapshot
}

public struct HerdrAgentSession: Decodable, Sendable, Equatable {
    public let agent: String?
    public let kind: String?
    public let source: String?
    public let value: String?

    /// The pi session JSONL path when herdr learned it from the pi integration. This is
    /// the primary join key against the registry.
    public var sessionFilePath: String? {
        guard kind == "path", let value, value.hasPrefix("/") else { return nil }
        return value
    }
}

public struct HerdrSnapshot: Decodable, Sendable, Equatable {
    public let version: String?
    public let `protocol`: Int?
    public let focusedWorkspaceId: String?
    public let focusedTabId: String?
    public let focusedPaneId: String?
    public let workspaces: [HerdrWorkspace]
    public let tabs: [HerdrTab]
    public let panes: [HerdrPane]
    public let agents: [HerdrAgent]

    public init(
        version: String? = nil,
        protocolVersion: Int? = nil,
        focusedWorkspaceId: String? = nil,
        focusedTabId: String? = nil,
        focusedPaneId: String? = nil,
        workspaces: [HerdrWorkspace] = [],
        tabs: [HerdrTab] = [],
        panes: [HerdrPane] = [],
        agents: [HerdrAgent] = []
    ) {
        self.version = version
        self.`protocol` = protocolVersion
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        `protocol` = try container.decodeIfPresent(Int.self, forKey: .protocol)
        focusedWorkspaceId = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceId)
        focusedTabId = try container.decodeIfPresent(String.self, forKey: .focusedTabId)
        focusedPaneId = try container.decodeIfPresent(String.self, forKey: .focusedPaneId)
        workspaces = try container.decodeIfPresent([HerdrWorkspace].self, forKey: .workspaces) ?? []
        tabs = try container.decodeIfPresent([HerdrTab].self, forKey: .tabs) ?? []
        panes = try container.decodeIfPresent([HerdrPane].self, forKey: .panes) ?? []
        agents = try container.decodeIfPresent([HerdrAgent].self, forKey: .agents) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case `protocol`
        case focusedWorkspaceId
        case focusedTabId
        case focusedPaneId
        case workspaces
        case tabs
        case panes
        case agents
    }
}

public struct HerdrAgent: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { paneId }
    public let agent: String?
    public let agentSession: HerdrAgentSession?
    public let agentStatus: String?
    public let cwd: String?
    public let focused: Bool?
    public let paneId: String
    public let tabId: String?
    public let workspaceId: String?
    public let revision: Int64?
    /// Monotonic per-pane state counter. Used to acknowledge a specific completion.
    public let stateChangeSeq: Int64?
    public let terminalTitle: String?
    public let stateLabels: [String: String]?
    /// Absent for panes whose agent never reported a title suffix (most bare pi panes).
    public let tokens: [String: String]?

    public init(
        agent: String?,
        agentSession: HerdrAgentSession?,
        agentStatus: String?,
        cwd: String?,
        focused: Bool?,
        paneId: String,
        tabId: String?,
        workspaceId: String?,
        revision: Int64?,
        stateChangeSeq: Int64?,
        terminalTitle: String?,
        stateLabels: [String: String]?,
        tokens: [String: String]?
    ) {
        self.agent = agent
        self.agentSession = agentSession
        self.agentStatus = agentStatus
        self.cwd = cwd
        self.focused = focused
        self.paneId = paneId
        self.tabId = tabId
        self.workspaceId = workspaceId
        self.revision = revision
        self.stateChangeSeq = stateChangeSeq
        self.terminalTitle = terminalTitle
        self.stateLabels = stateLabels
        self.tokens = tokens
    }

    public var sessionState: SessionState { SessionState(herdrStatus: agentStatus) }

    public var ref: HerdrRef {
        HerdrRef(
            paneId: paneId,
            tabId: tabId,
            workspaceId: workspaceId,
            focused: focused ?? false,
            stateChangeSeq: stateChangeSeq
        )
    }

    /// herdr's own display label for the current state, e.g. "⏳ 2 subagents (worker)".
    public var displayLabel: String? {
        if let labels = stateLabels, let status = agentStatus, let label = labels[status], !label.isEmpty {
            return label
        }
        if let summary = tokens?["summary"], !summary.isEmpty { return summary }
        return nil
    }
}

public struct HerdrPane: Decodable, Sendable, Equatable {
    public let paneId: String
    public let tabId: String?
    public let workspaceId: String?
    public let agent: String?
    public let agentSession: HerdrAgentSession?
    public let agentStatus: String?
    public let cwd: String?
    public let focused: Bool?
    public let terminalTitle: String?
    public let stateLabels: [String: String]?
    public let tokens: [String: String]?

    public var sessionState: SessionState { SessionState(herdrStatus: agentStatus) }

    public var displayLabel: String? {
        if let labels = stateLabels, let status = agentStatus, let label = labels[status], !label.isEmpty {
            return label
        }
        if let summary = tokens?["summary"], !summary.isEmpty { return summary }
        return nil
    }
}

public struct HerdrTab: Decodable, Sendable, Equatable {
    public let tabId: String
    public let workspaceId: String?
    public let label: String?
    public let number: Int?
    public let paneCount: Int?
    public let agentStatus: String?
    public let focused: Bool?

    public var sessionState: SessionState { SessionState(herdrStatus: agentStatus) }
}

public struct HerdrWorkspace: Decodable, Sendable, Equatable {
    public let workspaceId: String
    public let label: String?
    public let number: Int?
    public let tabCount: Int?
    public let paneCount: Int?
    public let agentStatus: String?
    public let focused: Bool?
    public let activeTabId: String?

    public var sessionState: SessionState { SessionState(herdrStatus: agentStatus) }
}

// MARK: - Events

/// herdr 0.9.1 is inconsistent about event-name separators: live captures show
/// `pane_updated`, `pane_focused`, `tab_focused` and `workspace_focused`, but
/// `pane.agent_status_changed`. Both forms are the same subscription, so matching goes
/// through `normalize` rather than string equality. Only the first separator is
/// canonicalized, because `agent_status_changed` is itself part of the name.
public enum HerdrEventKind {
    public static let paneUpdated = "pane.updated"
    public static let paneCreated = "pane.created"
    public static let paneClosed = "pane.closed"
    public static let paneMoved = "pane.moved"
    public static let paneExited = "pane.exited"
    public static let paneFocused = "pane.focused"
    public static let paneAgentDetected = "pane.agent_detected"
    public static let agentStatusChanged = "pane.agent_status_changed"
    public static let tabFocused = "tab.focused"
    public static let tabCreated = "tab.created"
    public static let tabClosed = "tab.closed"
    public static let tabRenamed = "tab.renamed"
    public static let tabMoved = "tab.moved"
    public static let workspaceFocused = "workspace.focused"
    public static let workspaceCreated = "workspace.created"
    public static let workspaceClosed = "workspace.closed"
    public static let workspaceRenamed = "workspace.renamed"
    public static let workspaceMoved = "workspace.moved"
    public static let workspaceReordered = "workspace.reordered"
    public static let layoutUpdated = "layout.updated"

    public static let known: Set<String> = [
        paneUpdated, paneCreated, paneClosed, paneMoved, paneExited, paneFocused,
        paneAgentDetected, agentStatusChanged,
        tabFocused, tabCreated, tabClosed, tabRenamed, tabMoved,
        workspaceFocused, workspaceCreated, workspaceClosed, workspaceRenamed,
        workspaceMoved, workspaceReordered, layoutUpdated,
    ]

    public static func normalize(_ raw: String) -> String {
        guard let index = raw.firstIndex(where: { $0 == "_" || $0 == "." }) else { return raw }
        var normalized = raw
        normalized.replaceSubrange(index...index, with: ".")
        return normalized
    }

    /// Canonical kind, or nil for an event this version does not know.
    public static func kind(for raw: String) -> String? {
        let normalized = normalize(raw)
        return known.contains(normalized) ? normalized : nil
    }

    /// Events that change which panes or agents exist, or which pane is focused.
    /// Anything here triggers a debounced re-snapshot instead of a local patch.
    public static let requiresResnapshot: Set<String> = [
        paneCreated, paneClosed, paneMoved, paneExited, paneAgentDetected,
        tabCreated, tabClosed, tabRenamed, tabMoved,
        workspaceCreated, workspaceClosed, workspaceRenamed, workspaceMoved, workspaceReordered,
    ]

    /// Focus changes are cheap to apply locally; no re-snapshot needed.
    public static let focusEvents: Set<String> = [paneFocused, tabFocused, workspaceFocused]
}

/// `{"event":"pane.agent_status_changed","data":{...}}` — no id and no sequence number.
public struct HerdrEvent: Decodable, Sendable, Equatable {
    public let event: String
    public let data: HerdrEventData?
}

public struct HerdrEventData: Decodable, Sendable, Equatable {
    public let pane: HerdrPane?
    public let paneId: String?
    public let workspaceId: String?
    public let agent: String?
    public let agentStatus: String?
    public let displayAgent: String?
    public let title: String?
    public let stateLabels: [String: String]?

    public var sessionState: SessionState? {
        guard agentStatus != nil else { return nil }
        return SessionState(herdrStatus: agentStatus)
    }
}

public extension SessionState {
    /// Maps herdr's status vocabulary, tolerating additions.
    init(herdrStatus: String?) {
        switch herdrStatus {
        case "working": self = .working
        case "blocked": self = .blocked
        case "idle": self = .idle
        case "done": self = .done
        default: self = .unknown
        }
    }
}
