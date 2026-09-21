import AppKit
import PiMenuBarCore

/// The app's answer to "is the user looking at this session?".
///
/// `Session.focused` from the merge is herdr's pane *selection*, which keeps pointing at
/// the pane the user last used while they are in another application — so it answers a
/// different question than the one the badge, the acknowledgement, and the notifier all
/// need. Everything that decides whether a finished run has been seen goes through here,
/// so the menu, the banner, and `--probe` cannot disagree.
@MainActor
enum SessionFocus {
    /// Frontmost macOS application. Injectable so the rule can be exercised without a GUI
    /// session.
    static var frontmostBundleId: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func isLooking(
        at session: Session,
        herdrSnapshot: HerdrSnapshot?,
        herdrFresh: Bool,
        defaultTerminalBundleId: String?
    ) -> Bool {
        FocusPolicy.preliminary(
            frontmostBundleId: frontmostBundleId(),
            expectedBundleId: session.terminalBundleId ?? defaultTerminalBundleId,
            herdrFresh: herdrFresh,
            selectedPaneId: herdrSnapshot?.focusedPaneId,
            sessionPaneId: session.herdr?.paneId
        ) == .focused
    }

    /// Merged rows with `needsAttention` recomputed from the live focus verdict, plus the
    /// keys the user is looking at right now (which the store acknowledges).
    static func withAttention(
        _ sessions: [Session],
        acknowledgements: [String: Acknowledgement],
        herdrSnapshot: HerdrSnapshot?,
        herdrFresh: Bool,
        defaultTerminalBundleId: String?
    ) -> (sessions: [Session], looking: Set<String>) {
        var looking: Set<String> = []
        let updated = sessions.map { session -> Session in
            let isLooking = isLooking(
                at: session,
                herdrSnapshot: herdrSnapshot,
                herdrFresh: herdrFresh,
                defaultTerminalBundleId: defaultTerminalBundleId
            )
            if isLooking { looking.insert(session.key) }
            var copy = session
            copy.needsAttention = AttentionRules.needsAttention(
                state: session.state,
                focused: isLooking,
                settledAt: session.settledAt,
                herdrStateChangeSeq: session.herdr?.stateChangeSeq,
                acknowledgement: acknowledgements[session.key]
            )
            return copy
        }
        return (updated, looking)
    }
}
