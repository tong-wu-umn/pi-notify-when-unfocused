import AppKit
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

    /// Frontmost macOS application. Injectable so the acknowledgement rule is testable
    /// without a GUI session.
    var frontmostBundleId: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

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
        // Ack a completion the moment the user is *really* looking at its pane, so
        // working in the terminal clears the badge without touching the menu.
        //
        // This has to be a live macOS focus check, not herdr's pane selection: herdr
        // keeps the last-used pane selected while the user is in another application, so
        // acking on that flag would clear the badge — and, because the notifier reads the
        // same acknowledgement, swallow the completion notification — for exactly the
        // case the notification exists for. Ambiguity never acknowledges: a lingering
        // badge is harmless, a lost “π finished” is not.
        for session in merged where isLooking(at: session, herdrSnapshot: herdrSnapshot, herdrFresh: herdrFresh) {
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

    /// True only when the session's host terminal is frontmost *and* this session's pane
    /// is the selected one. Shares `FocusPolicy` with the notifier so the menu and a
    /// banner can never disagree about what “the user is looking at it” means.
    private func isLooking(at session: Session, herdrSnapshot: HerdrSnapshot?, herdrFresh: Bool) -> Bool {
        FocusPolicy.preliminary(
            frontmostBundleId: frontmostBundleId(),
            expectedBundleId: session.terminalBundleId ?? config().terminalBundleId,
            herdrFresh: herdrFresh,
            selectedPaneId: herdrSnapshot?.focusedPaneId,
            sessionPaneId: session.herdr?.paneId
        ) == .focused
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
