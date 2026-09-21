import AppKit
import PiMenuBarCore

/// Answers "is the user looking at this session?" for the notification coordinator.
///
/// Two tiers, cheapest first, and any failure falls back to "assume focused" (stay
/// quiet):
///  1. `NSWorkspace` frontmost application, compared with the session's host terminal —
///     no permissions, no subprocess, and already enough for the common case;
///  2. if that terminal *is* frontmost, herdr's selected pane, or a bounded AppleScript
///     query for the focused Ghostty terminal, so a different pane in the same window
///     still counts as "not looking at this one".
///
/// The rules themselves live in `PiMenuBarCore.FocusPolicy`; this type only gathers
/// evidence, so the decision table is unit tested without a GUI session.
@MainActor
final class FocusResolver {
    /// Ghostty's bundle id. The pane probe is Ghostty-only on purpose: it is the terminal
    /// the project targets, and a broken probe must never interrupt the wrong pane.
    static let ghosttyBundleId = "com.mitchellh.ghostty"
    /// Markers pi puts in its own terminal title, matching the root extension.
    static let titleMarkers = ["π", "pi"]
    /// `osascript` can block on an Automation prompt; never wait longer than this.
    nonisolated static let probeTimeout: TimeInterval = 3
    /// After a failed probe, stop asking for this long. A denied Automation permission
    /// must not spawn (and kill) an `osascript` on every single notification attempt,
    /// while still recovering on its own once permission is granted.
    nonisolated static let probeBackoff: TimeInterval = 60

    /// Unit separator, so title and cwd survive an AppleScript round trip unambiguously.
    nonisolated private static let unitSeparator = String(UnicodeScalar(31))

    nonisolated private static let focusedGhosttyTerminal = [
        "tell application \"Ghostty\"",
        "  set t to focused terminal of selected tab of front window",
        "  return (name of t) & (character id 31) & (working directory of t)",
        "end tell",
    ].joined(separator: "\n")

    /// Injectable for manual verification (`FocusResolver(frontmost:probe:)`).
    var frontmostBundleId: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var probeTerminal: () async -> TerminalEvidence = FocusResolver.runGhosttyProbe
    private var probeBackoffUntil: Date?

    func resolve(
        session: Session,
        defaultTerminalBundleId: String?,
        preciseFocus: Bool,
        herdrFresh: Bool,
        selectedPaneId: String?
    ) async -> FocusVerdict {
        let expected = session.terminalBundleId ?? defaultTerminalBundleId
        let decision = FocusPolicy.preliminary(
            frontmostBundleId: frontmostBundleId(),
            expectedBundleId: expected,
            herdrFresh: herdrFresh,
            selectedPaneId: selectedPaneId,
            sessionPaneId: session.herdr?.paneId
        )

        switch decision {
        case .focused:
            return .focused("the host terminal is frontmost and this pane is selected")
        case .unfocused:
            return .unfocused("another pane or application is in front")
        case .unknownAssumeFocused:
            return .focused("the frontmost application could not be identified")
        case .needsTerminalProbe:
            guard preciseFocus else {
                return .focused("the host terminal is frontmost (preciseFocus is off)")
            }
            guard expected == Self.ghosttyBundleId else {
                return .focused("the host terminal is frontmost and the pane cannot be probed")
            }
            if let until = probeBackoffUntil, Date() < until {
                return .focused("the terminal pane probe is backing off after a failure")
            }
            let evidence = await probeTerminal()
            if case .unavailable = evidence {
                probeBackoffUntil = Date().addingTimeInterval(Self.probeBackoff)
                Log.shared.warn(
                    "notifications: could not ask Ghostty which terminal pane is focused; assuming focused for \(Int(Self.probeBackoff))s (grant PiMenuBar Automation access to Ghostty to keep pane-precise suppression)"
                )
            } else {
                probeBackoffUntil = nil
            }
            return FocusPolicy.terminalVerdict(
                evidence: evidence,
                sessionCwd: session.cwd,
                titleMarkers: Self.titleMarkers
            )
        }
    }

    // MARK: - Ghostty probe

    /// Asks Ghostty which terminal of the front window has focus. Runs off the main
    /// actor; a timeout, a missing Automation permission, or unexpected output all mean
    /// "unknown", which the caller treats as focused.
    static func runGhosttyProbe() async -> TerminalEvidence {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeSync())
            }
        }
    }

    /// Container so the background read can hand data back across the semaphore.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
        var status: Int32 = -1
    }

    /// Explicitly `nonisolated`: this class is `@MainActor`, so without the annotation the
    /// method would inherit main-actor isolation and the global-queue call above would be
    /// a lie the compiler only warns about.
    nonisolated private static func probeSync() -> TerminalEvidence {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", focusedGhosttyTerminal]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let box = OutputBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            // Reads until EOF, which happens when the process exits.
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            box.status = process.terminationStatus
            finished.signal()
        }
        if finished.wait(timeout: .now() + probeTimeout) == .timedOut {
            // A blocked `osascript` (most often an unanswered Automation consent prompt)
            // must not keep a thread alive or delay anything else.
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .unavailable
        }
        guard box.status == 0 else { return .unavailable }

        let text = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let parts = text.components(separatedBy: unitSeparator)
        guard parts.count >= 2 else { return .unavailable }
        return .pane(cwd: parts[1], title: parts[0])
    }
}
