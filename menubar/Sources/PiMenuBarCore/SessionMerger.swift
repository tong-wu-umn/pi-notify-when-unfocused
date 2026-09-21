import Foundation

public struct MergeInput: Sendable {
    public var registry: [RegistryRecord]
    public var herdr: HerdrSnapshot?
    /// A snapshot older than `2 × pollIntervalMs` is treated as stale and loses to the
    /// registry, so a hung herdr connection degrades instead of freezing the display.
    public var herdrFresh: Bool
    public var acknowledgements: [String: Acknowledgement]
    public var now: Date

    public init(
        registry: [RegistryRecord] = [],
        herdr: HerdrSnapshot? = nil,
        herdrFresh: Bool = false,
        acknowledgements: [String: Acknowledgement] = [:],
        now: Date = Date()
    ) {
        self.registry = registry
        self.herdr = herdr
        self.herdrFresh = herdrFresh
        self.acknowledgements = acknowledgements
        self.now = now
    }
}

/// Merges the two independent publishers into one row set.
///
/// herdr knows which panes exist and their lifecycle state even if the pi extension is
/// broken; the registry knows model/tool/context detail and covers pi outside herdr.
/// Join order: pi session file, then herdr pane id, then pid+start identity. Unmatched
/// rows are always shown rather than dropped.
public enum SessionMerger {
    public static func merge(_ input: MergeInput) -> [Session] {
        let snapshot = input.herdr
        let tabsById = Dictionary(uniqueKeysWithValues: (snapshot?.tabs ?? []).map { ($0.tabId, $0) })
        let workspacesById = Dictionary(uniqueKeysWithValues: (snapshot?.workspaces ?? []).map { ($0.workspaceId, $0) })

        var registryByKey: [String: RegistryRecord] = [:]
        for record in input.registry {
            if let existing = registryByKey[record.mergeKey], existing.revision > record.revision { continue }
            registryByKey[record.mergeKey] = record
        }
        var registryByPane: [String: RegistryRecord] = [:]
        for record in input.registry {
            guard let pane = record.herdr?.paneId else { continue }
            if let existing = registryByPane[pane], existing.revision > record.revision { continue }
            registryByPane[pane] = record
        }

        var sessions: [Session] = []
        var usedRegistryKeys: Set<String> = []

        for agent in (snapshot?.agents ?? []).sorted(by: { $0.paneId < $1.paneId }) {
            let sessionFile = agent.agentSession?.sessionFilePath
            let key = sessionFile ?? "herdr:\(agent.paneId)"
            let record = (sessionFile.flatMap { registryByKey[$0] }) ?? registryByPane[agent.paneId]
            if let record { usedRegistryKeys.insert(record.mergeKey) }

            let tab = agent.tabId.flatMap { tabsById[$0] }
            let workspace = agent.workspaceId.flatMap { workspacesById[$0] }
            var ref = agent.ref
            ref.tabLabel = tab?.label
            ref.workspaceLabel = workspace?.label
            ref.tabNumber = tab?.number
            ref.workspaceNumber = workspace?.number

            sessions.append(
                makeSession(
                    key: key,
                    source: record == nil ? .herdr : .herdrAndRegistry,
                    record: record,
                    herdrState: agent.sessionState,
                    herdrLabel: agent.displayLabel,
                    ref: ref,
                    cwd: record?.cwd ?? agent.cwd ?? "",
                    focused: agent.focused ?? false,
                    stateChangeSeq: agent.stateChangeSeq,
                    input: input
                )
            )
        }

        for record in input.registry where !usedRegistryKeys.contains(record.mergeKey) {
            sessions.append(record.toSession(acknowledgement: input.acknowledgements[record.mergeKey], now: input.now))
        }

        return sort(sessions)
    }

    private static func makeSession(
        key: String,
        source: SessionSource,
        record: RegistryRecord?,
        herdrState: SessionState,
        herdrLabel: String?,
        ref: HerdrRef,
        cwd: String,
        focused: Bool,
        stateChangeSeq: Int64?,
        input: MergeInput
    ) -> Session {
        // Blocked wins from either source. Missing the one state that means "a human is
        // required" is far worse than briefly showing a stale blocked badge; herdr
        // resolves it on the next state change either way.
        //
        // A wait the registry has already reported wins for the same reason. The registry
        // is written synchronously by the pi process the moment a prompt opens or a run
        // settles, while herdr's status for that pane arrives through another daemon and
        // then the app's subscription — so herdr can still say "working" after a run has
        // settled. Letting that win would hide a finished run from the menu *and* from the
        // notification policy, which only alerts on `.blocked`, `.done`, and `.idle`.
        // The reverse contradiction cannot survive a beat: `agent_start` publishes
        // `working` and clears `settledAt` in one synchronous write.
        let registryState = record?.sessionState
        let registryReportsWait: Bool
        switch registryState {
        case .blocked: registryReportsWait = true
        case .idle, .done: registryReportsWait = record?.settledDate != nil
        default: registryReportsWait = false
        }
        var state: SessionState
        if registryState == .blocked || (input.herdrFresh && herdrState == .blocked) {
            state = .blocked
        } else if input.herdrFresh, !(registryReportsWait && herdrState == .working) {
            state = herdrState
        } else {
            state = registryState ?? herdrState
        }
        if state == .idle, record?.sessionState == .working, !input.herdrFresh {
            state = .working
        }

        let settledAt = record?.settledDate
        let acknowledgement = input.acknowledgements[key]

        var session = Session(
            key: key,
            source: source,
            project: record?.project ?? RegistryRecord.projectName(for: cwd),
            cwd: cwd,
            state: state,
            updatedAt: record?.updatedDate ?? input.now,
            sessionName: record?.sessionName,
            sessionFile: record?.sessionFile,
            sessionId: record?.sessionId,
            mode: record?.mode,
            focused: focused,
            stateLabel: record?.stateLabel ?? herdrLabel,
            model: record?.model,
            thinking: record?.thinking,
            contextTokens: record?.contextTokens,
            contextWindow: record?.contextWindow,
            activeTools: record?.activeToolModels ?? [],
            runStartedAt: record?.runStartedDate,
            waitingSince: record?.waitingDate,
            settledAt: settledAt,
            lastUserPrompt: record?.lastUserPrompt,
            herdr: ref,
            terminalBundleId: record?.terminalBundleId,
            simulated: record?.simulated ?? false
        )
        session.needsAttention = AttentionRules.needsAttention(
            state: session.state,
            focused: focused,
            settledAt: settledAt,
            herdrStateChangeSeq: stateChangeSeq,
            acknowledgement: acknowledgement
        )
        return session
    }

    /// What needs a human first, then what is running, then what is resting.
    public static func sort(_ sessions: [Session]) -> [Session] {
        sessions.sorted { lhs, rhs in
            if lhs.displayState.sortRank != rhs.displayState.sortRank {
                return lhs.displayState.sortRank < rhs.displayState.sortRank
            }
            switch lhs.displayState {
            case .blocked:
                let left = lhs.waitingSince ?? lhs.updatedAt
                let right = rhs.waitingSince ?? rhs.updatedAt
                if left != right { return left < right }
            case .working:
                let left = lhs.runStartedAt ?? lhs.updatedAt
                let right = rhs.runStartedAt ?? rhs.updatedAt
                if left != right { return left < right }
            case .done, .idle, .unknown:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            }
            if lhs.label != rhs.label { return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending }
            return lhs.key < rhs.key
        }
    }
}

// MARK: - Grouping

public struct SessionGroup: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let tabs: [TabGroup]
}

public struct TabGroup: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let sessions: [Session]
}

public enum SessionGrouping {
    public static let registryOnlyGroupId = "registry-only"

    /// Groups herdr rows by workspace → tab (the structure the user already navigates),
    /// and everything else under "Other terminals".
    public static func groups(_ sessions: [Session]) -> [SessionGroup] {
        var workspaces: [String: (title: String, number: Int, tabs: [String: (title: String, number: Int, sessions: [Session])])] = [:]
        var registryOnly: [Session] = []

        for session in sessions {
            guard let ref = session.herdr else {
                registryOnly.append(session)
                continue
            }
            let workspaceId = ref.workspaceId ?? "herdr-other"
            let workspaceTitle = ref.workspaceLabel ?? "herdr"
            let tabId = ref.tabId ?? "\(workspaceId):unknown"
            let tabTitle: String
            if let label = ref.tabLabel, !label.isEmpty {
                tabTitle = ref.tabNumber.map { "Tab \($0) · \(label)" } ?? label
            } else {
                tabTitle = ref.tabNumber.map { "Tab \($0)" } ?? "Pane"
            }
            var workspace = workspaces[workspaceId] ?? (workspaceTitle, ref.workspaceNumber ?? Int.max, [:])
            workspace.title = ref.workspaceLabel ?? workspace.title
            workspace.number = min(workspace.number, ref.workspaceNumber ?? workspace.number)
            var tab = workspace.tabs[tabId] ?? (tabTitle, ref.tabNumber ?? Int.max, [])
            tab.title = tabTitle
            tab.sessions.append(session)
            workspace.tabs[tabId] = tab
            workspaces[workspaceId] = workspace
        }

        var groups: [SessionGroup] = workspaces.map { workspaceId, workspace in
            let tabs = workspace.tabs
                .sorted { lhs, rhs in
                    if lhs.value.number != rhs.value.number { return lhs.value.number < rhs.value.number }
                    return lhs.value.title.localizedStandardCompare(rhs.value.title) == .orderedAscending
                }
                .map { TabGroup(id: $0.key, title: $0.value.title, sessions: $0.value.sessions) }
            return SessionGroup(id: workspaceId, title: workspace.title, tabs: tabs)
        }
        groups.sort { lhs, rhs in
            let left = workspaces[lhs.id]?.number ?? Int.max
            let right = workspaces[rhs.id]?.number ?? Int.max
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        if !registryOnly.isEmpty {
            groups.append(
                SessionGroup(
                    id: registryOnlyGroupId,
                    title: "Other terminals",
                    tabs: [TabGroup(id: registryOnlyGroupId, title: "pi outside herdr", sessions: registryOnly)]
                )
            )
        }
        return groups
    }
}
