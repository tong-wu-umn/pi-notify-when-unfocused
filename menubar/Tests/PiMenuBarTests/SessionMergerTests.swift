import Foundation
@testable import PiMenuBarCore

/// Shared fixtures for `SessionMergerTests`.
private enum ContextSessionMergerTests {
    static let now = Date(millis: 1_758_450_000_000)

    static func merge(
        registry: [RegistryRecord] = [],
        herdr: HerdrSnapshot? = nil,
        fresh: Bool = true,
        acknowledgements: [String: Acknowledgement] = [:]
    ) -> [Session] {
        SessionMerger.merge(MergeInput(
            registry: registry,
            herdr: herdr,
            herdrFresh: fresh,
            acknowledgements: acknowledgements,
            now: now
        ))
    }

    static func makeSession(
        key: String,
        state: SessionState,
        needsAttention: Bool = false,
        waitingSince: Date? = nil,
        runStartedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> Session {
        Session(
            key: key,
            source: .registry,
            project: key,
            cwd: "/tmp/\(key)",
            state: state,
            updatedAt: updatedAt ?? now,
            needsAttention: needsAttention,
            runStartedAt: runStartedAt,
            waitingSince: waitingSince
        )
    }
}

private extension HerdrAgent {
    func withFocused(_ focused: Bool) -> HerdrAgent {
        HerdrAgent(
            agent: agent,
            agentSession: agentSession,
            agentStatus: agentStatus,
            cwd: cwd,
            focused: focused,
            paneId: paneId,
            tabId: tabId,
            workspaceId: workspaceId,
            revision: revision,
            stateChangeSeq: stateChangeSeq,
            terminalTitle: terminalTitle,
            stateLabels: stateLabels,
            tokens: tokens
        )
    }

    func withStatus(_ status: String) -> HerdrAgent {
        HerdrAgent(
            agent: agent,
            agentSession: agentSession,
            agentStatus: status,
            cwd: cwd,
            focused: focused,
            paneId: paneId,
            tabId: tabId,
            workspaceId: workspaceId,
            revision: revision,
            stateChangeSeq: stateChangeSeq,
            terminalTitle: terminalTitle,
            stateLabels: stateLabels,
            tokens: tokens
        )
    }
}

private extension HerdrSnapshot {
    func replacingAgentStatus(paneId: String, status: String) -> HerdrSnapshot {
        HerdrSnapshot(
            version: version,
            protocolVersion: `protocol`,
            focusedWorkspaceId: focusedWorkspaceId,
            focusedTabId: focusedTabId,
            focusedPaneId: focusedPaneId,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents.map { $0.paneId == paneId ? $0.withStatus(status) : $0 }
        )
    }

    func markingFocused(paneId: String) -> HerdrSnapshot {
        HerdrSnapshot(
            version: version,
            protocolVersion: `protocol`,
            focusedWorkspaceId: focusedWorkspaceId,
            focusedTabId: focusedTabId,
            focusedPaneId: paneId,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents.map { $0.paneId == paneId ? $0.withFocused(true) : $0 }
        )
    }
}

func registerSessionMergerTests(_ t: TestRunner) {
    t.test("JoinsHerdrAgentToRegistryRecordBySessionFile") {
        let record = TestSupport.record()
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let merged = try unwrap(sessions.first { $0.key == Fixtures.registrySessionFile })
        expectEqual(merged.source, .herdrAndRegistry)
        expectEqual(merged.herdr?.paneId, Fixtures.piNotifyPaneId)
        expectEqual(merged.model, "deepseek-flash", "registry detail must survive the join")
        expectEqual(merged.contextTokens, 84213)
        expectEqual(merged.activeTools.map(\.name), ["bash"])
        expectEqual(merged.project, "pi-notify-when-unfocused")
        expectEqual(merged.herdr?.workspaceLabel, "tong's mbp", "labels come from the snapshot")
        expectEqual(merged.herdr?.tabLabel, "misc")
        expectNotNil(merged.herdr?.stateChangeSeq)
    }

    t.test("HerdrRowWithoutRegistryIsShownWithCwdDerivedProject") {
        let sessions = ContextSessionMergerTests.merge(herdr: TestSupport.snapshot())
        let herdrOnly = sessions.filter { $0.source == .herdr }
        expectEqual(herdrOnly.count, 2)
        let pane = try unwrap(herdrOnly.first { $0.herdr?.paneId == Fixtures.herdrPaneId })
        expectEqual(pane.key, Fixtures.herdrSessionFile, "herdr reports the pi session path, so that is the key")
        expectEqual(pane.project, "mobile_pda")
        expectNil(pane.model)
        expectEqual(pane.state, .working)
    }

    t.test("RegistryRowWithoutHerdrIsShown") {
        let record = TestSupport.record(["herdr": NSNull()])
        let sessions = ContextSessionMergerTests.merge(registry: [record])
        let only = try unwrap(sessions.first)
        expectEqual(only.source, .registry)
        expectNil(only.herdr)
        expectEqual(only.project, "pi-notify-when-unfocused")
    }

    t.test("RegistryRecordWithoutSessionFileJoinsByPaneId") {
        let record = TestSupport.record(["sessionFile": NSNull()])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        expectEqual(sessions.count, 2, "the record must join the pane, not duplicate it")
        let joined = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(joined.source, .herdrAndRegistry)
        expectEqual(joined.model, "deepseek-flash")
        expectEqual(joined.key, Fixtures.registrySessionFile, "herdr supplies the session path used as the key")
    }

    t.test("NeitherSourceDuplicatesTheOther") {
        let record = TestSupport.record()
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        expectEqual(sessions.count, 2)
        expectEqual(Set(sessions.map(\.key)).count, sessions.count)
    }

    t.test("StaleHerdrSnapshotLosesToTheRegistry") {
        let record = TestSupport.record(["state": "idle"])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot(), fresh: false)
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(session.state, .idle, "registry wins when herdr is not fresh")
    }

    t.test("FreshHerdrSnapshotWinsOverTheRegistry") {
        let record = TestSupport.record(["state": "working"])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(session.state, .working)
    }

    t.test("BlockedRegistryStateIsNotMaskedByHerdrWorking") {
        let record = TestSupport.record(["state": "blocked", "waitingSince": ContextSessionMergerTests.now.millis - 45_000])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(session.state, .blocked, "herdr's working must not mask a registry block")
        expectTrue(session.needsAttention)
        expectEqual(session.waitingSince, ContextSessionMergerTests.now.addingTimeInterval(-45))
        expectTrue(session.detailLine(now: ContextSessionMergerTests.now).contains("blocked 45s"), session.detailLine(now: ContextSessionMergerTests.now))
    }

    t.test("FreshRegistryCompletionIsNotMaskedByHerdrWorking") {
        let record = TestSupport.record([
            "state": "idle",
            "settledAt": ContextSessionMergerTests.now.millis - 2_000,
            "runStartedAt": ContextSessionMergerTests.now.millis - 62_000,
        ])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(
            session.state,
            .idle,
            "a run the registry reported as settled must not be masked by herdr's stale working"
        )
        expectEqual(session.settledAt, ContextSessionMergerTests.now.addingTimeInterval(-2))
        expectTrue(session.needsAttention, "the finished run still needs to be seen")
        let candidates = NotificationPolicy.candidates(
            sessions: sessions,
            acknowledgements: [:],
            config: TestSupport.notifications()
        )
        expectTrue(
            candidates.contains { $0.generation.kind == .completion },
            "a finished run the registry reported must still become a notification candidate"
        )
    }

    t.test("HerdrWorkingStillWinsWithoutARegistryCompletion") {
        let record = TestSupport.record(["state": "idle", "settledAt": NSNull()])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(session.state, .working, "without a settle there is no completion to protect")
        expectFalse(session.needsAttention)
    }

    t.test("StaleBlockedRegistryRowFollowsHerdr") {
        let record = TestSupport.record(["state": "blocked"])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot(), fresh: false)
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectEqual(session.state, .blocked, "a registry-only block is still a block")
    }

    t.test("FocusedPaneNeverNeedsAttention") {
        let record = TestSupport.record(["state": "blocked"])
        let snapshot = TestSupport.snapshot().markingFocused(paneId: Fixtures.piNotifyPaneId)
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: snapshot)
        let session = try unwrap(sessions.first { $0.herdr?.paneId == Fixtures.piNotifyPaneId })
        expectTrue(session.focused, "fixture rewrite must mark the pane focused")
        expectFalse(session.needsAttention)
    }

    t.test("AcknowledgedCompletionDisplaysAsIdle") {
        let snapshot = TestSupport.snapshot()
        let agent = try unwrap(snapshot.agents.first { $0.paneId == Fixtures.piNotifyPaneId })
        let seq = try unwrap(agent.stateChangeSeq)
        let done = snapshot.replacingAgentStatus(paneId: Fixtures.piNotifyPaneId, status: "done")

        func display(_ acknowledgements: [String: Acknowledgement]) throws -> (SessionState, Bool) {
            let session = try unwrap(
                ContextSessionMergerTests.merge(herdr: done, acknowledgements: acknowledgements)
                    .first { $0.herdr?.paneId == Fixtures.piNotifyPaneId }
            )
            return (session.displayState, session.needsAttention)
        }

        // A herdr row that also has a session path keys on the session file, not the pane.
        let unacked = try display([:])
        expectEqual(unacked.0, .done)
        expectTrue(unacked.1)

        let acked = try display([
            Fixtures.registrySessionFile: Acknowledgement(acknowledgedAt: ContextSessionMergerTests.now, herdrStateChangeSeq: seq),
        ])
        expectEqual(acked.0, .idle, "an acknowledged completion shows the idle glyph")
        expectFalse(acked.1)

        let stale = try display([
            Fixtures.registrySessionFile: Acknowledgement(acknowledgedAt: ContextSessionMergerTests.now, herdrStateChangeSeq: seq - 1),
        ])
        expectEqual(stale.0, .done, "a different generation is a new completion")
        expectTrue(stale.1)
    }

    t.test("HeartbeatDoesNotResurrectAnAcknowledgedCompletion") {
        // The registry keeps publishing idle+settledAt every 15s. Once acknowledged, the
        // row must stay quiet until a genuinely new completion.
        let settled = ContextSessionMergerTests.now.addingTimeInterval(-120)
        let record = TestSupport.record([
            "state": "idle",
            "settledAt": settled.millis,
            "updatedAt": ContextSessionMergerTests.now.millis,
        ])
        let acknowledgement = Acknowledgement(acknowledgedAt: ContextSessionMergerTests.now, herdrStateChangeSeq: nil)

        let unacked = try unwrap(ContextSessionMergerTests.merge(registry: [record]).first)
        expectTrue(unacked.needsAttention, "a registry completion with no acknowledgement is attention")

        let acked = try unwrap(
            ContextSessionMergerTests.merge(
                registry: [record],
                acknowledgements: [record.mergeKey: acknowledgement]
            ).first
        )
        expectFalse(acked.needsAttention, "a later heartbeat must not re-flag it")
    }

    t.test("NewCompletionAfterAcknowledgementFlagsAgain") {
        let acknowledgement = Acknowledgement(acknowledgedAt: ContextSessionMergerTests.now, herdrStateChangeSeq: nil)
        let record = TestSupport.record([
            "state": "idle",
            "settledAt": ContextSessionMergerTests.now.addingTimeInterval(60).millis,
        ])
        let session = try unwrap(
            ContextSessionMergerTests.merge(
                registry: [record],
                acknowledgements: [record.mergeKey: acknowledgement]
            ).first
        )
        expectTrue(session.needsAttention)
    }

    t.test("SortOrdersByWhatNeedsAHumanFirst") {
        let blocked = ContextSessionMergerTests.makeSession(key: "b", state: .blocked, waitingSince: ContextSessionMergerTests.now.addingTimeInterval(-90))
        let blockedNew = ContextSessionMergerTests.makeSession(key: "b2", state: .blocked, waitingSince: ContextSessionMergerTests.now.addingTimeInterval(-5))
        let finished = ContextSessionMergerTests.makeSession(key: "f", state: .done, needsAttention: true)
        let working = ContextSessionMergerTests.makeSession(key: "w", state: .working, runStartedAt: ContextSessionMergerTests.now.addingTimeInterval(-600))
        let idle = ContextSessionMergerTests.makeSession(key: "i", state: .idle)
        let sorted = SessionMerger.sort([idle, working, finished, blockedNew, blocked])
        expectEqual(sorted.map(\.key), ["b", "b2", "f", "w", "i"])
    }

    t.test("GroupingUsesWorkspaceAndTabLabels") {
        let sessions = ContextSessionMergerTests.merge(herdr: TestSupport.snapshot())
        let groups = SessionGrouping.groups(sessions)
        expectEqual(groups.count, 1)
        expectEqual(groups[0].title, "tong's mbp")
        expectEqual(groups[0].tabs.count, 2)
        expectEqual(groups[0].tabs.map(\.title), ["Tab 1 · misc", "Tab 5 · mobile pda"])
        expectEqual(groups[0].tabs[1].sessions.map(\.label), ["mobile_pda"])
    }

    t.test("GroupingPutsRegistryOnlySessionsLast") {
        let record = TestSupport.record([
            "herdr": NSNull(), "sessionFile": NSNull(), "cwd": "/tmp/standalone",
            "project": "standalone", "sessionName": NSNull(),
        ])
        let sessions = ContextSessionMergerTests.merge(registry: [record], herdr: TestSupport.snapshot())
        let groups = SessionGrouping.groups(sessions)
        expectEqual(groups.map(\.title), ["tong's mbp", "Other terminals"])
        expectEqual(groups[1].tabs[0].sessions.map(\.label), ["standalone"])
    }

    t.test("ProjectFallbackForCwdWithTrailingSlash") {
        expectEqual(RegistryRecord.projectName(for: "/tmp/thing/"), "thing")
        expectEqual(RegistryRecord.projectName(for: "/"), "/")
    }
}
