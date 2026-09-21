import Foundation
@testable import PiMenuBarCore

func registerHerdrProtocolTests(_ t: TestRunner) {
    t.test("DecodesRealSnapshot") {
        let snapshot = TestSupport.snapshot()
        expectEqual(snapshot.version, "0.9.1")
        expectEqual(snapshot.protocol, 22)
        expectEqual(snapshot.focusedPaneId, "w1:p9")
        expectEqual(snapshot.agents.count, 2)
        expectFalse(snapshot.tabs.isEmpty)
        expectFalse(snapshot.workspaces.isEmpty)

        let agent = try unwrap(snapshot.agents.first(where: { $0.paneId == "w1:p9" }))
        expectEqual(agent.agent, "pi")
        expectEqual(agent.agentStatus, "working")
        expectEqual(agent.sessionState, .working)
        expectEqual(agent.tabId, "w1:t5")
        expectEqual(agent.workspaceId, "w1")
        expectEqual(agent.cwd, "/Users/tongwu/Downloads/project/mobile_pda")
        expectEqual(agent.focused, true)
        expectNotNil(agent.stateChangeSeq, "state_change_seq must decode; it drives completion acknowledgement")
        expectEqual(agent.agentSession?.sessionFilePath?.hasSuffix(".jsonl"), true)
        expectEqual(agent.displayLabel, "⏳ 2 subagents (worker)")
    }
    t.test("SnapshotPanelsWithoutAgentsDecodeAsUnknown") {
        let snapshot = TestSupport.snapshot()
        let agentless = snapshot.panes.filter { $0.agent == nil }
        expectFalse(agentless.isEmpty, "fixture must include a pane with no agent")
        for pane in agentless {
            expectEqual(pane.sessionState, .unknown)
            expectNil(pane.agentSession)
        }
    }
    t.test("DecodesSubscriptionAck") {
        let ack = try HerdrCoding.decodeFrame(
            Data(Fixtures.subscriptionStartedJSON.utf8),
            as: HerdrResponse<HerdrSubscribeAck>.self
        )
        expectEqual(ack.id, "fixture:sub")
        expectEqual(ack.result?.type, "subscription_started")
        expectNil(ack.error)
    }
    t.test("DecodesPaneUpdatedEventWithUnderscoreName") {
        let event = try HerdrCoding.decodeFrame(Data(Fixtures.paneUpdatedJSON.utf8), as: HerdrEvent.self)
        expectEqual(HerdrEventKind.normalize(event.event), HerdrEventKind.paneUpdated)
        let pane = try unwrap(event.data?.pane)
        expectEqual(pane.paneId, "w1:p9")
        expectEqual(pane.agentStatus, "working")
        expectEqual(pane.sessionState, .working)
        expectEqual(pane.displayLabel, "⏳ 2 subagents (worker)")
    }
    t.test("DecodesAgentStatusChangedEventWithDottedName") {
        let event = try HerdrCoding.decodeFrame(Data(Fixtures.agentStatusChangedJSON.utf8), as: HerdrEvent.self)
        expectEqual(HerdrEventKind.normalize(event.event), HerdrEventKind.agentStatusChanged)
        expectEqual(event.data?.paneId, "w1:p9")
        expectEqual(event.data?.sessionState, .working)
        expectEqual(event.data?.stateLabels?["working"], "⏳ 2 subagents (worker)")
    }
    t.test("EventNameNormalizationCoversBothSeparators") {
        let cases: [(String, String)] = [
            ("pane_updated", "pane.updated"),
            ("pane.updated", "pane.updated"),
            ("pane_focused", "pane.focused"),
            ("tab_focused", "tab.focused"),
            ("workspace_focused", "workspace.focused"),
            ("pane.agent_status_changed", "pane.agent_status_changed"),
            ("pane_agent_status_changed", "pane.agent_status_changed"),
            ("layout_updated", "layout.updated"),
        ]
        for (raw, expected) in cases {
            expectEqual(HerdrEventKind.normalize(raw), expected, "raw=\(raw)")
        }
    }
    t.test("UnknownEventNameIsNotMistakenForAKnownOne") {
        expectEqual(HerdrEventKind.normalize("pane.teleported"), "pane.teleported")
        expectEqual(HerdrEventKind.kind(for: "pane.teleported"), nil)
    }
    t.test("DecodesErrorResponse") {
        let response = try HerdrCoding.decodeFrame(
            Data(Fixtures.errorAgentNotFoundJSON.utf8),
            as: HerdrResponse<HerdrSubscribeAck>.self
        )
        expectEqual(response.error?.code, "agent_not_found")
        expectNil(response.result)
    }
    t.test("ToleratesUnknownFieldsAndMissingArrays") {
        let json = """
        {"version":"9.9.9","protocol":23,"future_field":{"nested":[1,2,3]},"agents":[]}
        """
        let snapshot = try HerdrCoding.decodeFrame(Data(json.utf8), as: HerdrSnapshot.self)
        expectEqual(snapshot.protocol, 23)
        expectEqual(snapshot.agents.count, 0)
        expectTrue(snapshot.panes.isEmpty)
    }
    t.test("SnapshotEnvelopeDecodesNestedSnapshot") {
        let envelope = try HerdrCoding.decodeFrame(
            Data("{\"id\":\"x\",\"result\":{\"snapshot\":\(Fixtures.snapshotJSON)}}".utf8),
            as: HerdrResponse<HerdrSnapshotEnvelope>.self
        )
        expectEqual(envelope.result?.snapshot.agents.count, 2)
    }
    t.test("EncodesRequestsInHerdrWireFormat") {
        let data = try HerdrCoding.encodeLine(HerdrRequests.snapshot(id: "req-1"))
        let text = String(decoding: data, as: UTF8.self)
        expectTrue(text.hasSuffix("\n"))
        let object = try unwrap(
            JSONSerialization.jsonObject(with: Data(text.dropLast().utf8)) as? [String: Any]
        )
        expectEqual(object["id"] as? String, "req-1")
        expectEqual(object["method"] as? String, "session.snapshot")
        expectEqual((object["params"] as? [String: Any])?.isEmpty, true)

        let subscribe = String(
            decoding: try HerdrCoding.encodeLine(
                HerdrRequests.subscribe(id: "req-2", [HerdrSubscription(type: "pane.agent_status_changed", paneId: "w1:p9")])
            ),
            as: UTF8.self
        )
        expectTrue(subscribe.contains("\"pane_id\":\"w1:p9\""), "params must use herdr's snake_case: \(subscribe)")

        let focus = String(
            decoding: try HerdrCoding.encodeLine(HerdrRequests.focusAgent(id: "req-3", paneId: "w1:p1")),
            as: UTF8.self
        )
        expectTrue(focus.contains("\"method\":\"agent.focus\""))
        expectTrue(focus.contains("\"target\":\"w1:p1\""))
    }
    t.test("StructuralSubscriptionListOmitsPerPaneTypes") {
        let types = Set(HerdrSubscription.structuralTypes)
        expectTrue(types.contains("pane.focused"))
        expectTrue(types.contains("pane.agent_detected"))
        expectTrue(types.contains("workspace.focused"))
        // pane.updated is deliberately absent: it fires once per output revision.
        expectFalse(types.contains("pane.updated"))
        for perPane in ["pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"] {
            expectFalse(types.contains(perPane), "\(perPane) requires a pane_id and must not be global")
        }
    }
    t.test("StateVocabularyMapping") {
        expectEqual(SessionState(herdrStatus: "idle"), .idle)
        expectEqual(SessionState(herdrStatus: "working"), .working)
        expectEqual(SessionState(herdrStatus: "blocked"), .blocked)
        expectEqual(SessionState(herdrStatus: "done"), .done)
        expectEqual(SessionState(herdrStatus: nil), .unknown)
        expectEqual(SessionState(herdrStatus: "teleported"), .unknown)
    }
}
