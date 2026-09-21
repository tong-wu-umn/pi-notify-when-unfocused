import Foundation
import PiMenuBarCore

/// Holds the merged view the UI renders, plus the acknowledgement store.
///
/// The registry never carries an "unseen" flag (its heartbeat would resurrect cleared
/// badges), so acknowledgement is owned here and persisted separately.
@MainActor
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var acknowledgements: AcknowledgementStore
    var onChange: (() -> Void)?

    private let config: () -> MenuBarConfig

    init(config: @escaping () -> MenuBarConfig) {
        self.config = config
        acknowledgements = AcknowledgementStore.load(path: MenuBarConfig.acknowledgementsPath)
    }

    func recompute(registry: [RegistryRecord], herdrSnapshot: HerdrSnapshot?, herdrFresh: Bool) {
        let merged = SessionMerger.merge(MergeInput(
            registry: registry,
            herdr: herdrSnapshot,
            herdrFresh: herdrFresh,
            acknowledgements: acknowledgements.entries,
            now: Date()
        ))
        // Attention follows the live macOS focus check, not herdr's pane selection: a run
        // that finishes while the user is in another application has to show the `○`
        // badge (and reach the notifier) even though herdr still calls that pane focused.
        let refreshed = SessionFocus.withAttention(
            merged,
            acknowledgements: acknowledgements.entries,
            herdrSnapshot: herdrSnapshot,
            herdrFresh: herdrFresh,
            defaultTerminalBundleId: config().terminalBundleId
        )
        // Clear a completion the moment the user is *really* looking at its pane, so
        // working in the terminal clears the badge without touching the menu.
        for session in refreshed.sessions where refreshed.looking.contains(session.key) {
            let finished = session.state == .done || (session.state == .idle && session.settledAt != nil)
            // Only when it is still unseen: a recompute every few seconds must not re-ack
            // an already acknowledged completion and repaint the menu each time.
            let seen = AttentionRules.needsAttention(
                state: session.state,
                focused: false,
                settledAt: session.settledAt,
                herdrStateChangeSeq: session.herdr?.stateChangeSeq,
                acknowledgement: acknowledgements[session.key]
            ) == false
            if finished, !seen {
                Log.shared.debug("completion for \(session.label) cleared while looking at its pane")
                acknowledge(session, persistImmediately: false)
            }
        }
        sessions = refreshed.sessions
        onChange?()
    }

    func session(for key: String) -> Session? {
        sessions.first { $0.key == key }
    }

    func acknowledge(_ session: Session, persistImmediately: Bool = true) {
        // An acknowledgement both clears the badge and retires the wait, so a banner the
        // notifier already posted is removed right after. Worth a line: it is the most
        // common reason a delivered banner disappears before the user looks at it.
        Log.shared.debug("acknowledged \(session.label) (\(session.state.rawValue)")
        acknowledgements.acknowledge(
            key: session.key,
            at: Date(),
            herdrStateChangeSeq: session.herdr?.stateChangeSeq
        )
        if persistImmediately {
            persist()
        }
        // Reflect the change immediately; the next recompute will confirm it.
        if let index = sessions.firstIndex(where: { $0.key == session.key }) {
            var updated = sessions[index]
            updated.needsAttention = AttentionRules.needsAttention(
                state: updated.state,
                focused: updated.focused,
                settledAt: updated.settledAt,
                herdrStateChangeSeq: updated.herdr?.stateChangeSeq,
                acknowledgement: acknowledgements[updated.key]
            )
            sessions[index] = updated
        }
        onChange?()
    }

    func persist() {
        var store = acknowledgements
        store.prune(now: Date(), retentionDays: config().ackRetentionDays)
        acknowledgements = store
        if !acknowledgements.write(to: MenuBarConfig.acknowledgementsPath) {
            Log.shared.warn("could not persist acknowledgements to \(MenuBarConfig.acknowledgementsPath)")
        }
    }
}
