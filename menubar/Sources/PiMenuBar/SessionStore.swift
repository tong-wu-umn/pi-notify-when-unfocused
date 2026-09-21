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
        // Ack a completion the moment its pane is focused, so working in the terminal
        // clears the badge without touching the menu.
        for session in merged where session.focused {
            if session.state == .done || (session.state == .idle && session.settledAt != nil) {
                acknowledge(session, persistImmediately: false)
            }
        }
        sessions = merged
        onChange?()
    }

    func session(for key: String) -> Session? {
        sessions.first { $0.key == key }
    }

    func acknowledge(_ session: Session, persistImmediately: Bool = true) {
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
