import Foundation
@testable import PiMenuBarCore

/// Fixtures for `NotificationPolicyTests`.
private enum PolicyFixture {
    static let now = Date(millis: 1_758_450_000_000)

    static func candidates(_ sessions: [Session], _ config: NotificationConfig) -> [Candidate] {
        NotificationPolicy.candidates(sessions: sessions, acknowledgements: [:], config: config)
    }

    static func candidates(
        _ sessions: [Session],
        _ config: NotificationConfig,
        acknowledgements: [String: Acknowledgement]
    ) -> [Candidate] {
        NotificationPolicy.candidates(sessions: sessions, acknowledgements: acknowledgements, config: config)
    }

    static func attempts(_ outcome: NotificationPolicy.Outcome) -> [NotificationPolicy.Attempt] {
        outcome.actions.compactMap { action in
            if case let .attempt(attempt) = action { return attempt }
            return nil
        }
    }

    static func cancels(_ outcome: NotificationPolicy.Outcome) -> [AttentionGeneration] {
        outcome.actions.compactMap { action in
            if case let .cancel(generation) = action { return generation }
            return nil
        }
    }

    /// `unwrap` throws instead of trapping, so a failed expectation reports itself rather
    /// than crashing the whole suite.
    static func onlyAttempt(_ outcome: NotificationPolicy.Outcome) throws -> NotificationPolicy.Attempt {
        let attempts = attempts(outcome)
        try expectEqual(attempts.count, 1)
        return try unwrap(attempts.first, "expected exactly one attempt")
    }

    static func blocked(_ waitingSince: Date, key: String = "session-a", herdr: HerdrRef? = nil) -> Session {
        TestSupport.session(key: key, state: .blocked, waitingSince: waitingSince, herdr: herdr)
    }

    /// A policy that already saw an empty fleet, so the next new wait is a real event.
    static func primedPolicy(_ config: NotificationConfig) -> NotificationPolicy {
        var policy = NotificationPolicy(config: config)
        _ = policy.reconcile(candidates: [], now: now)
        return policy
    }
}

func registerNotificationPolicyTests(_ t: TestRunner) {
    let now = PolicyFixture.now

    t.test("FirstReconcileOnlyEstablishesABaseline") {
        let config = TestSupport.notifications()
        var policy = NotificationPolicy(config: config)
        let waiting = PolicyFixture.blocked(now.addingTimeInterval(-600))

        let first = policy.reconcile(candidates: PolicyFixture.candidates([waiting], config), now: now)
        expectTrue(first.didPrime, "the first reconcile must not alert")
        expectEqual(first.actions.count, 0, "a prompt that already existed at launch must stay quiet")

        // Even repeated snapshots and heartbeats never turn a baseline row into an alert.
        let later = policy.reconcile(candidates: PolicyFixture.candidates([waiting], config), now: now.addingTimeInterval(60))
        expectEqual(later.actions.count, 0)
        expectNil(policy.nextDeadline)
    }

    t.test("NewPromptAlertsOnceAndThenOnlyAtReminderDeadlines") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let waiting = PolicyFixture.blocked(now.addingTimeInterval(-5))
        let candidates = PolicyFixture.candidates([waiting], config)

        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))
        expectEqual(attempt.isReminder, false)
        expectEqual(attempt.content.title, NotificationContentBuilder.promptTitle)
        policy.recordAttempt(attempt.generation, delivered: true, now: now)

        // A heartbeat / repeated snapshot a second later must not alert again.
        let repeatOutcome = policy.reconcile(candidates: candidates, now: now.addingTimeInterval(1))
        expectEqual(repeatOutcome.actions.count, 0)
        expectEqual(policy.nextDeadline, now.addingTimeInterval(20), "the reminder still has to be scheduled")

        let reminder = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now.addingTimeInterval(20)))
        expectEqual(reminder.isReminder, true)
        expectEqual(reminder.content.title, NotificationContentBuilder.reminderTitle)
    }

    t.test("RemindersAreBounded") {
        let config = TestSupport.notifications(reminders: 2)
        var policy = PolicyFixture.primedPolicy(config)
        let waiting = PolicyFixture.blocked(now)
        let candidates = PolicyFixture.candidates([waiting], config)

        var clock = now
        var attemptCount = 0
        for _ in 0..<10 {
            let outcome = policy.reconcile(candidates: candidates, now: clock)
            for attempt in PolicyFixture.attempts(outcome) {
                attemptCount += 1
                policy.recordAttempt(attempt.generation, delivered: true, now: clock)
            }
            clock = clock.addingTimeInterval(20)
        }
        expectEqual(attemptCount, 3, "one initial attempt plus two reminders")
        expectNil(policy.nextDeadline)
    }

    t.test("AFocusedInitialAttemptStillEarnsItsReminders") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let waiting = PolicyFixture.blocked(now)
        let candidates = PolicyFixture.candidates([waiting], config)

        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))
        policy.recordAttempt(attempt.generation, delivered: false, now: now)

        let reminder = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now.addingTimeInterval(20)))
        expectEqual(reminder.isReminder, true, "the user may have walked away while the same prompt is open")
    }

    t.test("ANewPromptIsANewGenerationWhileTheOldOneIsCancelled") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)

        let first = PolicyFixture.blocked(now.addingTimeInterval(-30))
        let firstAttempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: PolicyFixture.candidates([first], config), now: now))
        policy.recordAttempt(firstAttempt.generation, delivered: true, now: now)

        let working = TestSupport.session(key: "session-a", state: .working)
        let cancelled = policy.reconcile(candidates: PolicyFixture.candidates([working], config), now: now.addingTimeInterval(1))
        expectEqual(PolicyFixture.cancels(cancelled), [firstAttempt.generation], "answering the prompt removes the banner")

        // Past the dedupe window, so this is a fresh alert rather than a duplicate.
        let second = PolicyFixture.blocked(now.addingTimeInterval(5))
        let secondAttempt = try PolicyFixture.onlyAttempt(
            policy.reconcile(candidates: PolicyFixture.candidates([second], config), now: now.addingTimeInterval(15))
        )
        expectNotEqual(secondAttempt.generation, firstAttempt.generation, "a new waitingSince is a new wait")
    }

    t.test("TheSameWaitSurvivesGainingAHerdrPane") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let waitingSince = now.addingTimeInterval(-4)

        let registryOnly = PolicyFixture.blocked(waitingSince)
        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: PolicyFixture.candidates([registryOnly], config), now: now))
        expectEqual(attempt.generation.identity, "session:session-a")
        policy.recordAttempt(attempt.generation, delivered: true, now: now)

        let withPane = PolicyFixture.blocked(
            waitingSince,
            herdr: HerdrRef(paneId: "w1:p1", focused: false, stateChangeSeq: 12)
        )
        let second = policy.reconcile(candidates: PolicyFixture.candidates([withPane], config), now: now.addingTimeInterval(1))
        expectEqual(second.actions.count, 0, "a resolution hint change must not cancel or re-raise the alert")
        expectEqual(PolicyFixture.candidates([withPane], config).first?.generation.identity, "pane:w1:p1")
    }

    t.test("ABurstInOnePassAlertsOnceAndKeepsTheOthersReminders") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let first = PolicyFixture.blocked(now, key: "session-a")
        let second = PolicyFixture.blocked(now, key: "session-b")
        let third = PolicyFixture.blocked(now, key: "session-c")
        let candidates = PolicyFixture.candidates([first, second, third], config)

        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))
        expectEqual(attempt.generation.sessionKey, "session-a", "the priority order decides who gets the slot")
        policy.recordAttempt(attempt.generation, delivered: true, now: now)

        let later = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now.addingTimeInterval(20)))
        expectEqual(later.isReminder, true, "the deduped waits still get their reminder slot")
    }

    t.test("AuthorizeRejectsASupersededAttempt") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let candidates = PolicyFixture.candidates([PolicyFixture.blocked(now)], config)
        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))

        expectTrue(policy.authorize(attempt, now: now))
        policy.recordAttempt(attempt.generation, delivered: true, now: now.addingTimeInterval(1))
        expectFalse(policy.authorize(attempt, now: now.addingTimeInterval(2)), "an already reported attempt must not post twice")
    }

    t.test("ACancelledWaitCannotDeliverALateFocusResult") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let candidates = PolicyFixture.candidates([PolicyFixture.blocked(now)], config)
        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))

        _ = policy.reconcile(candidates: [], now: now)
        expectFalse(policy.authorize(attempt, now: now), "the prompt was answered while the focus probe was in flight")
    }

    t.test("StopRemindersSilencesOneWait") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let candidates = PolicyFixture.candidates([PolicyFixture.blocked(now)], config)
        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))
        policy.recordAttempt(attempt.generation, delivered: true, now: now)

        policy.stopReminders(attempt.generation)
        expectNil(policy.nextDeadline)
        let after = policy.reconcile(candidates: candidates, now: now.addingTimeInterval(100))
        expectEqual(after.actions.count, 0, "a dismissed banner must not come back for the same wait")
    }

    t.test("AFlickeringRowDoesNotReRaiseTheSameWait") {
        let config = TestSupport.notifications()
        var policy = PolicyFixture.primedPolicy(config)
        let waiting = PolicyFixture.blocked(now)
        let candidates = PolicyFixture.candidates([waiting], config)

        let attempt = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now))
        policy.recordAttempt(attempt.generation, delivered: true, now: now)

        // The row vanishes for one snapshot (herdr reconnecting, a registry rewrite).
        let gone = policy.reconcile(candidates: [], now: now.addingTimeInterval(1))
        expectEqual(PolicyFixture.cancels(gone), [attempt.generation])

        // It comes back well past the dedupe window: the wait is still the same one, so
        // the reminder that was already due is what fires — not a second initial banner.
        let returned = try PolicyFixture.onlyAttempt(policy.reconcile(candidates: candidates, now: now.addingTimeInterval(30)))
        expectEqual(returned.isReminder, true)
        expectEqual(returned.content.title, NotificationContentBuilder.reminderTitle)
    }

    t.test("BlockedWithoutWaitingSinceIsNotACandidate") {
        let config = TestSupport.notifications()
        let waiting = TestSupport.session(state: .blocked, waitingSince: nil)
        expectEqual(PolicyFixture.candidates([waiting], config).count, 0, "without a marker there is no stable generation")
    }

    t.test("BlockedWinsOverAPreviousCompletion") {
        let config = TestSupport.notifications()
        let session = TestSupport.session(
            state: .blocked,
            waitingSince: now,
            settledAt: now.addingTimeInterval(-60),
            runStartedAt: now.addingTimeInterval(-120)
        )
        let candidates = PolicyFixture.candidates([session], config)
        expectEqual(candidates.count, 1)
        expectEqual(candidates.first?.generation.kind, .prompt)
    }

    t.test("AcknowledgementSilencesACompletion") {
        let config = TestSupport.notifications()
        let settled = now.addingTimeInterval(-120)
        let session = TestSupport.session(
            state: .idle,
            settledAt: settled,
            runStartedAt: settled.addingTimeInterval(-600)
        )
        let acknowledgement = Acknowledgement(acknowledgedAt: now)

        let unacknowledged = PolicyFixture.candidates([session], config)
        expectEqual(unacknowledged.count, 1)
        expectEqual(unacknowledged.first?.generation.kind, .completion)

        let acknowledged = PolicyFixture.candidates([session], config, acknowledgements: [session.key: acknowledgement])
        expectEqual(acknowledged.count, 0)
    }

    t.test("DurationGateDecidesWhetherACompletionCanAlert") {
        let config = TestSupport.notifications(idleMinRunMs: 15_000)
        let settled = now

        let short = TestSupport.session(state: .idle, settledAt: settled, runStartedAt: settled.addingTimeInterval(-5))
        expectEqual(PolicyFixture.candidates([short], config).count, 0, "a quick reply must not interrupt")

        let atThreshold = TestSupport.session(state: .idle, settledAt: settled, runStartedAt: settled.addingTimeInterval(-15))
        expectEqual(PolicyFixture.candidates([atThreshold], config).count, 1)

        let unknown = TestSupport.session(state: .idle, settledAt: settled, runStartedAt: nil)
        expectEqual(PolicyFixture.candidates([unknown], config).count, 0, "unknown duration stays quiet by default")

        let permissive = TestSupport.notifications(idleMinRunMs: 15_000, notifyUnknownDurationCompletions: true)
        expectEqual(PolicyFixture.candidates([unknown], permissive).count, 1)
    }

    t.test("HerdrOnlyCompletionUsesTheStateChangeSequence") {
        let config = TestSupport.notifications()
        let session = TestSupport.session(
            state: .done,
            herdr: HerdrRef(paneId: "w1:p9", focused: false, stateChangeSeq: 228)
        )
        expectEqual(PolicyFixture.candidates([session], config).count, 0, "no timings means no duration proof")

        let permissive = TestSupport.notifications(notifyUnknownDurationCompletions: true)
        let candidates = PolicyFixture.candidates([session], permissive)
        expectEqual(candidates.count, 1)
        expectEqual(candidates.first?.generation.marker, 228)

        var acknowledgement = Acknowledgement(acknowledgedAt: now)
        acknowledgement.herdrStateChangeSeq = 228
        let acknowledged = PolicyFixture.candidates([session], permissive, acknowledgements: [session.key: acknowledgement])
        expectEqual(acknowledged.count, 0, "the same completion generation must stay acknowledged")
    }

    t.test("SimulatedAndDisabledSessionsAreIgnored") {
        let config = TestSupport.notifications()
        let simulated = TestSupport.session(state: .blocked, waitingSince: now, simulated: true)
        expectEqual(PolicyFixture.candidates([simulated], config).count, 0, "/menubar simulate must never post a real banner")

        var disabled = config
        disabled.enabled = false
        expectEqual(PolicyFixture.candidates([PolicyFixture.blocked(now)], disabled).count, 0)
    }

    t.test("TriggerSwitchesDisableOneChannelAtATime") {
        let promptsOff = TestSupport.notifications(notifyOnPrompts: false)
        expectEqual(PolicyFixture.candidates([PolicyFixture.blocked(now)], promptsOff).count, 0)

        let settled = now
        let completed = TestSupport.session(state: .idle, settledAt: settled, runStartedAt: settled.addingTimeInterval(-60))
        let idleOff = TestSupport.notifications(notifyOnIdle: false)
        expectEqual(PolicyFixture.candidates([completed], idleOff).count, 0)
    }

    t.test("GenerationKeysRoundTrip") {
        let generation = AttentionGeneration(
            sessionKey: "/tmp/a|b/session.jsonl",
            kind: .completion,
            marker: 1_758_450_000_000,
            identity: "pane:w1:p1"
        )
        let parsed = AttentionGeneration(generationKey: generation.generationKey)
        expectNotNil(parsed)
        expectEqual(parsed?.sessionKey, generation.sessionKey)
        expectEqual(parsed?.kind, generation.kind)
        expectEqual(parsed?.marker, generation.marker)
        expectEqual(parsed, generation, "equality follows the generation key, not the resolution hint")
        expectNil(AttentionGeneration(generationKey: "garbage"))
    }
}
