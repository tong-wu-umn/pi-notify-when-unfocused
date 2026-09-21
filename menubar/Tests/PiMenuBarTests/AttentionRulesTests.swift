import Foundation
@testable import PiMenuBarCore

/// Shared fixtures for `AttentionRulesTests`.
private enum ContextAttentionRulesTests {
    static let now = Date(millis: 1_758_450_000_000)
    static let ackAt = Date(millis: 1_758_450_000_000)
}

func registerAttentionRulesTests(_ t: TestRunner) {
    t.test("BlockedAlwaysWantsAttentionUnlessFocused") {
        expectTrue(AttentionRules.needsAttention(
            state: .blocked, focused: false, settledAt: nil, herdrStateChangeSeq: nil, acknowledgement: nil
        ))
        expectFalse(AttentionRules.needsAttention(
            state: .blocked, focused: true, settledAt: nil, herdrStateChangeSeq: nil, acknowledgement: nil
        ))
    }
    t.test("WorkingNeverWantsAttention") {
        expectFalse(AttentionRules.needsAttention(
            state: .working, focused: false, settledAt: nil, herdrStateChangeSeq: 5, acknowledgement: nil
        ))
    }
    t.test("UnacknowledgedHerdrCompletionWantsAttention") {
        expectTrue(AttentionRules.needsAttention(
            state: .done, focused: false, settledAt: nil, herdrStateChangeSeq: 42, acknowledgement: nil
        ))
    }
    t.test("AcknowledgedHerdrCompletionIsQuietUntilTheNextGeneration") {
        let acknowledgement = Acknowledgement(acknowledgedAt: ContextAttentionRulesTests.ackAt, herdrStateChangeSeq: 42)
        expectFalse(AttentionRules.needsAttention(
            state: .done, focused: false, settledAt: nil, herdrStateChangeSeq: 42, acknowledgement: acknowledgement
        ), "the same completion generation must stay acknowledged")
        expectTrue(AttentionRules.needsAttention(
            state: .done, focused: false, settledAt: nil, herdrStateChangeSeq: 43, acknowledgement: acknowledgement
        ), "a new completion must re-flag attention")
    }
    t.test("CompletionWithoutSequenceFallsBackToTimestamps") {
        let laterSettled = Acknowledgement(acknowledgedAt: ContextAttentionRulesTests.ackAt, herdrStateChangeSeq: nil)
        expectFalse(AttentionRules.needsAttention(
            state: .done, focused: false, settledAt: ContextAttentionRulesTests.ackAt.addingTimeInterval(-60), herdrStateChangeSeq: nil,
            acknowledgement: laterSettled
        ))
        expectTrue(AttentionRules.needsAttention(
            state: .done, focused: false, settledAt: ContextAttentionRulesTests.ackAt.addingTimeInterval(60), herdrStateChangeSeq: nil,
            acknowledgement: laterSettled
        ))
    }
    t.test("UnknownStateNeedsNoAttention") {
        expectFalse(AttentionRules.needsAttention(
            state: .unknown, focused: false, settledAt: nil, herdrStateChangeSeq: nil, acknowledgement: nil
        ))
    }
    t.test("IdleSessionThatNeverRanIsNotAttention") {
        expectFalse(AttentionRules.needsAttention(
            state: .idle, focused: false, settledAt: nil, herdrStateChangeSeq: nil, acknowledgement: nil
        ), "a freshly opened session must not show a badge")
    }
    t.test("IdleAfterCompletionFollowsTheAcknowledgement") {
        let settled = ContextAttentionRulesTests.now.addingTimeInterval(-30)
        expectTrue(AttentionRules.needsAttention(
            state: .idle, focused: false, settledAt: settled, herdrStateChangeSeq: nil, acknowledgement: nil
        ))
        expectFalse(AttentionRules.needsAttention(
            state: .idle, focused: false, settledAt: settled, herdrStateChangeSeq: nil,
            acknowledgement: Acknowledgement(acknowledgedAt: ContextAttentionRulesTests.now)
        ))
    }
    t.test("FocusedBeatsEverything") {
        let settled = ContextAttentionRulesTests.now.addingTimeInterval(-30)
        expectFalse(AttentionRules.needsAttention(
            state: .idle, focused: true, settledAt: settled, herdrStateChangeSeq: nil, acknowledgement: nil
        ))
    }
}

/// Shared fixtures for `AcknowledgementStoreTests`.
private enum ContextAcknowledgementStoreTests {
    static let now = Date(millis: 1_758_450_000_000)
}

func registerAcknowledgementStoreTests(_ t: TestRunner) {
    t.test("AcknowledgeAndRead") {
        var store = AcknowledgementStore()
        store.acknowledge(key: "k", at: ContextAcknowledgementStoreTests.now, herdrStateChangeSeq: 7)
        expectEqual(store["k"]?.herdrStateChangeSeq, 7)
        expectEqual(store["k"]?.date, ContextAcknowledgementStoreTests.now)
        expectNil(store["missing"])
    }
    t.test("AcknowledgementNeverMovesBackwards") {
        var store = AcknowledgementStore()
        store.acknowledge(key: "k", at: ContextAcknowledgementStoreTests.now, herdrStateChangeSeq: 9)
        // A delayed event arriving later must not clear a newer acknowledgement.
        store.acknowledge(key: "k", at: ContextAcknowledgementStoreTests.now.addingTimeInterval(-120), herdrStateChangeSeq: 8)
        expectEqual(store["k"]?.herdrStateChangeSeq, 9)
        expectEqual(store["k"]?.date, ContextAcknowledgementStoreTests.now)
    }
    t.test("RoundTripsThroughDiskWithOwnerOnlyPermissions") {
        let directory = TestSupport.TempDirectory()
        let path = (directory.path as NSString).appendingPathComponent("ack/acknowledgements.json")
        var store = AcknowledgementStore()
        store.acknowledge(key: "a", at: ContextAcknowledgementStoreTests.now, herdrStateChangeSeq: 3)
        store.acknowledge(key: "b", at: ContextAcknowledgementStoreTests.now, herdrStateChangeSeq: nil)
        expectTrue(store.write(to: path))

        let loaded = AcknowledgementStore.load(path: path)
        expectEqual(loaded.entries.count, 2)
        expectEqual(loaded["a"]?.herdrStateChangeSeq, 3)
        expectEqual(loaded["b"]?.herdrStateChangeSeq, nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        expectEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
    t.test("LoadOfMissingOrCorruptFileYieldsEmptyStore") {
        let directory = TestSupport.TempDirectory()
        let missing = (directory.path as NSString).appendingPathComponent("nope.json")
        expectTrue(AcknowledgementStore.load(path: missing).entries.isEmpty)

        let corrupt = directory.write("corrupt.json", "{\"version\":1,\"entries\":")
        expectTrue(AcknowledgementStore.load(path: corrupt).entries.isEmpty)

        let futureVersion = directory.write("future.json", "{\"version\":99,\"entries\":{\"k\":{\"acknowledgedAt\":1}}}")
        expectTrue(AcknowledgementStore.load(path: futureVersion).entries.isEmpty)
    }
    t.test("PruneDropsOldEntries") {
        var store = AcknowledgementStore()
        store.acknowledge(key: "old", at: ContextAcknowledgementStoreTests.now.addingTimeInterval(-40 * 86_400), herdrStateChangeSeq: nil)
        store.acknowledge(key: "recent", at: ContextAcknowledgementStoreTests.now.addingTimeInterval(-2 * 86_400), herdrStateChangeSeq: nil)
        store.prune(now: ContextAcknowledgementStoreTests.now, retentionDays: 30)
        expectEqual(Set(store.entries.keys), ["recent"])
    }
}
