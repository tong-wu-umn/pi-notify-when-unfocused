import Foundation

/// What kind of wait a generation represents.
public enum AttentionKind: String, Sendable, Equatable, Codable {
    case prompt
    case completion
}

/// One distinct "the user needs to look at this" event.
///
/// A generation is deliberately *not* the current session state. It is minted once per
/// prompt wait (`waitingSince`) or per completed run (`settledAt` / herdr's
/// `state_change_seq`), so a heartbeat, a re-snapshot, a second `done` observation, or an
/// app restart can never look like a new event.
///
/// Equality and hashing use `generationKey` only. `identity` is a resolution hint that is
/// allowed to change without the alert changing: a registry-only session gains a herdr
/// pane id moments after it appears, and that must not cancel and re-raise the same alert.
public struct AttentionGeneration: Hashable, Sendable {
    public let sessionKey: String
    public let kind: AttentionKind
    public let marker: Int64
    public let identity: String

    public init(sessionKey: String, kind: AttentionKind, marker: Int64, identity: String) {
        self.sessionKey = sessionKey
        self.kind = kind
        self.marker = marker
        self.identity = identity
    }

    /// Persistence-friendly form. The marker is parsed from the right so a session path
    /// containing `|` cannot corrupt the key.
    public init?(generationKey: String) {
        guard let lastSeparator = generationKey.lastIndex(of: "|"),
              let firstSeparator = generationKey.firstIndex(of: "|"),
              lastSeparator > firstSeparator
        else { return nil }
        let kindPart = generationKey[generationKey.startIndex..<firstSeparator]
        let keyPart = generationKey[generationKey.index(after: firstSeparator)..<lastSeparator]
        let markerPart = generationKey[generationKey.index(after: lastSeparator)...]
        guard let kind = AttentionKind(rawValue: String(kindPart)), let marker = Int64(markerPart) else { return nil }
        self.init(sessionKey: String(keyPart), kind: kind, marker: marker, identity: String(keyPart))
    }

    public var generationKey: String { "\(kind.rawValue)|\(sessionKey)|\(marker)" }

    public static func == (lhs: AttentionGeneration, rhs: AttentionGeneration) -> Bool {
        lhs.generationKey == rhs.generationKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(generationKey)
    }
}

/// A session that currently warrants attention, plus the generation that describes it.
public struct Candidate: Sendable, Equatable {
    public let generation: AttentionGeneration
    public let session: Session

    public init(generation: AttentionGeneration, session: Session) {
        self.generation = generation
        self.session = session
    }
}

/// Decides when a native notification should be attempted, and how many reminders a
/// single wait earns.
///
/// Pure on purpose: timers, focus probes, and UserNotifications all live in the app
/// target, and every timing rule here is exercised by the test executable instead of by
/// watching a menu bar. The type is a state machine over `AttentionGeneration`s:
///
///  - the first `reconcile` after launch — or after notifications are re-enabled — only
///    establishes a baseline, so old blocked/done rows never replay as banners;
///  - a generation earns one initial attempt plus at most `reminders` reminder attempts;
///  - an attempt is *reserved* (`pending`) until the app reports its outcome, so a slow
///    focus probe can never let the same generation be attempted twice.
public struct NotificationPolicy: Sendable {
    /// One delivery the app should try. The app still has to check macOS focus; the
    /// policy has already decided that the attempt itself is warranted.
    public struct Attempt: Sendable, Equatable {
        public let generation: AttentionGeneration
        public let isReminder: Bool
        public let content: NotificationContent

        public init(generation: AttentionGeneration, isReminder: Bool, content: NotificationContent) {
            self.generation = generation
            self.isReminder = isReminder
            self.content = content
        }
    }

    public enum Action: Sendable, Equatable {
        case attempt(Attempt)
        /// The wait is over (answered, acknowledged, session gone, or reminders stopped):
        /// remove any delivered banner for it.
        case cancel(AttentionGeneration)
    }

    public struct Outcome: Sendable, Equatable {
        public var actions: [Action] = []
        /// True when this call only established the baseline.
        public var didPrime = false

        public init(actions: [Action] = [], didPrime: Bool = false) {
            self.actions = actions
            self.didPrime = didPrime
        }
    }

    private struct State: Sendable, Equatable {
        /// Set for baseline or explicitly stopped generations: tracked, never alerted.
        var silent = false
        var initialAttempted = false
        var remindersUsed = 0
        var nextCheckAt: Date?
        var pending: Attempt?
    }

    /// A state kept after its wait disappeared, so that a row flickering out for one
    /// snapshot (herdr reconnecting, a registry file rewritten) cannot re-raise a banner
    /// the user has already seen. Bounded by time, not by count: waits are few.
    private struct Retired: Sendable, Equatable {
        var state: State
        var retiredAt: Date
    }

    /// How long a retired generation can suppress a re-alert.
    public static let retiredRetention: TimeInterval = 15 * 60

    public var config: NotificationConfig
    private var states: [AttentionGeneration: State] = [:]
    private var retired: [AttentionGeneration: Retired] = [:]
    /// When the last alert was actually delivered. Guards the asynchronous gap between
    /// reserving an attempt and posting it.
    private var lastDeliveryAt: Date?
    /// When the last attempt was reserved, delivered or not. This is what a burst of new
    /// waits is measured against, so three prompts appearing at once cannot produce three
    /// banners a second apart.
    private var lastReservedAt: Date?
    private var isPrimed = false

    public init(config: NotificationConfig = NotificationConfig()) {
        self.config = config
    }

    public var didPrime: Bool { isPrimed }

    /// Earliest moment the app should call `reconcile` again, or nil when nothing is
    /// waiting. Attempts still in flight are excluded: the app reschedules when it
    /// reports their outcome.
    public var nextDeadline: Date? {
        states.values
            .filter { $0.pending == nil }
            .compactMap(\.nextCheckAt)
            .min()
    }

    /// Records the current waits as already-known without alerting. Called implicitly by
    /// the first `reconcile`.
    public mutating func prime(candidates: [Candidate], now: Date) {
        isPrimed = true
        states.removeAll()
        retired.removeAll()
        for candidate in candidates {
            states[candidate.generation] = State(silent: true)
        }
    }

    /// Forgets all state so the next `reconcile` re-establishes a baseline. Used when
    /// notifications are disabled, or when their configuration changes.
    public mutating func reset() {
        isPrimed = false
        states.removeAll()
        retired.removeAll()
        lastDeliveryAt = nil
        lastReservedAt = nil
    }

    public mutating func reconcile(candidates: [Candidate], now: Date) -> Outcome {
        var outcome = Outcome()
        guard isPrimed else {
            prime(candidates: candidates, now: now)
            outcome.didPrime = true
            return outcome
        }

        let activeKeys = Set(candidates.map(\.generation))
        let cancelled = states.keys.filter { !activeKeys.contains($0) }
        for generation in cancelled {
            outcome.actions.append(.cancel(generation))
            if var state = states.removeValue(forKey: generation) {
                // Keep the bookkeeping (attempts used, delivery time) so a reappearance
                // resumes where it stopped instead of starting a fresh banner series.
                state.pending = nil
                retired[generation] = Retired(state: state, retiredAt: now)
            }
        }
        retired = retired.filter { now.timeIntervalSince($0.value.retiredAt) < Self.retiredRetention }

        for candidate in candidates where states[candidate.generation] == nil {
            // A new wait is due immediately; the baseline path created its states in
            // `prime`, which sets `silent` instead.
            if let previous = retired.removeValue(forKey: candidate.generation) {
                states[candidate.generation] = previous.state
            } else {
                states[candidate.generation] = State(nextCheckAt: now)
            }
        }

        for candidate in candidates {
            guard var state = states[candidate.generation], !state.silent, state.pending == nil else { continue }
            guard let nextCheckAt = state.nextCheckAt, now >= nextCheckAt else { continue }

            let isReminder = state.initialAttempted
            if isReminder, state.remindersUsed >= config.reminders {
                state.nextCheckAt = nil
                states[candidate.generation] = state
                continue
            }
            // Near-duplicates wait for the reminder interval instead of stacking up.
            // The initial slot is consumed either way, so a deduped prompt can still earn
            // its normal reminders while it stays open.
            if let last = lastReservedAt, now.timeIntervalSince(last) * 1000 < Double(config.dedupeMs) {
                state.initialAttempted = true
                state.nextCheckAt = reminderDeadline(after: now, remindersUsed: state.remindersUsed)
                states[candidate.generation] = state
                continue
            }

            let attempt = Attempt(
                generation: candidate.generation,
                isReminder: isReminder,
                content: NotificationContentBuilder.content(
                    for: candidate.generation,
                    session: candidate.session,
                    isReminder: isReminder,
                    config: config
                )
            )
            state.pending = attempt
            state.initialAttempted = true
            if isReminder { state.remindersUsed += 1 }
            state.nextCheckAt = reminderDeadline(after: now, remindersUsed: state.remindersUsed)
            states[candidate.generation] = state
            lastReservedAt = now
            outcome.actions.append(.attempt(attempt))
        }
        return outcome
    }

    /// Final gate before posting, after the asynchronous focus probe has returned.
    ///
    /// `false` means another alert was delivered in the meantime, or the attempt was
    /// cancelled; the caller must report the outcome with `recordAttempt`.
    public func authorize(_ attempt: Attempt, now: Date) -> Bool {
        guard let state = states[attempt.generation], !state.silent, state.pending == attempt else { return false }
        if let last = lastDeliveryAt, now.timeIntervalSince(last) * 1000 < Double(config.dedupeMs) { return false }
        return true
    }

    /// Reports what actually happened to a reserved attempt so the generation can be
    /// rescheduled. `delivered: false` covers "the user was looking at it", "permission
    /// unavailable", and "another alert won the dedupe window".
    public mutating func recordAttempt(_ generation: AttentionGeneration, delivered: Bool, now: Date) {
        guard var state = states[generation] else { return }
        state.pending = nil
        if delivered {
            lastDeliveryAt = now
            lastReservedAt = now
        }
        states[generation] = state
    }

    /// A banner the user dismissed: stop reminding for that wait, but do not treat the
    /// dismissal as having seen the session.
    public mutating func stopReminders(_ generation: AttentionGeneration) {
        guard var state = states[generation] else { return }
        state.silent = true
        state.pending = nil
        state.nextCheckAt = nil
        states[generation] = state
    }

    // MARK: - Candidates

    /// Sessions that currently warrant attention, in the order they were given (already
    /// sorted by the merger: what needs a human first).
    public static func candidates(
        sessions: [Session],
        acknowledgements: [String: Acknowledgement],
        config: NotificationConfig
    ) -> [Candidate] {
        guard config.enabled else { return [] }
        var candidates: [Candidate] = []
        for session in sessions {
            // A `/menubar simulate` overlay is a presentation aid and must never produce
            // a real banner, even though the registry carries it as a blocked state.
            guard !session.simulated else { continue }
            guard let generation = generation(for: session, acknowledgements: acknowledgements, config: config) else { continue }
            // A short run is never a candidate. The check lives here (rather than in the
            // state machine) so an ineligible completion leaves no state behind and can
            // become eligible later if a late registry record supplies its timings.
            guard isEligible(session: session, kind: generation.kind, config: config) else { continue }
            candidates.append(Candidate(generation: generation, session: session))
        }
        return candidates
    }

    public static func generation(
        for session: Session,
        acknowledgements: [String: Acknowledgement],
        config: NotificationConfig
    ) -> AttentionGeneration? {
        // `focused: false` on purpose: herdr's pane selection is not the macOS focus
        // check, which can only be answered at delivery time by the app.
        let wantsAttention = AttentionRules.needsAttention(
            state: session.state,
            focused: false,
            settledAt: session.settledAt,
            herdrStateChangeSeq: session.herdr?.stateChangeSeq,
            acknowledgement: acknowledgements[session.key]
        )
        switch session.state {
        case .blocked:
            guard config.notifyOnPrompts, wantsAttention, let waitingSince = session.waitingSince else { return nil }
            return AttentionGeneration(
                sessionKey: session.key,
                kind: .prompt,
                marker: waitingSince.millis,
                identity: identity(for: session)
            )
        case .done, .idle:
            guard config.notifyOnIdle, wantsAttention else { return nil }
            // Prefer the registry timestamp (it pairs with `runStartedAt` for the
            // duration filter) and fall back to herdr's completion generation.
            guard let marker = session.settledAt?.millis ?? session.herdr?.stateChangeSeq else { return nil }
            return AttentionGeneration(
                sessionKey: session.key,
                kind: .completion,
                marker: marker,
                identity: identity(for: session)
            )
        case .working, .unknown:
            return nil
        }
    }

    /// Whether a generation of this kind may alert at all. Re-evaluated on every
    /// reconcile, so a completion that temporarily has no timings becomes eligible if a
    /// late registry record supplies them.
    public static func isEligible(session: Session, kind: AttentionKind, config: NotificationConfig) -> Bool {
        switch kind {
        case .prompt:
            return true
        case .completion:
            guard let settled = session.settledAt, let started = session.runStartedAt else {
                return config.notifyUnknownDurationCompletions
            }
            return settled.timeIntervalSince(started) * 1000 >= Double(config.idleMinRunMs)
        }
    }

    private static func identity(for session: Session) -> String {
        if let paneId = session.herdr?.paneId, !paneId.isEmpty { return "pane:\(paneId)" }
        return "session:\(session.key)"
    }

    private func reminderDeadline(after now: Date, remindersUsed: Int) -> Date? {
        guard remindersUsed < config.reminders else { return nil }
        return now.addingTimeInterval(Double(config.reminderIntervalMs) / 1000)
    }
}
