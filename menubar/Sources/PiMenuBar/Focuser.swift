import AppKit
import PiMenuBarCore

/// Brings a session to the front and, when that succeeds, marks it seen.
///
/// macOS activation and herdr pane selection are separate concerns: herdr can select an
/// exact pane without activating the host terminal, and activating an app cannot select
/// a pane. Both are attempted, and a partial result is reported instead of claimed.
@MainActor
final class Focuser {
    enum Outcome: Equatable {
        case focused(String)
        case partial(String)
        case failed(String)
    }

    private var lastAttempt: (key: String, at: Date)?

    func focus(_ session: Session, via client: HerdrClient, defaultBundleId: String?) async -> Outcome {
        // Ignore double clicks on the same row.
        if let lastAttempt, lastAttempt.key == session.key, Date().timeIntervalSince(lastAttempt.at) < 0.5 {
            return .partial("already focusing")
        }
        lastAttempt = (session.key, Date())

        var notes: [String] = []
        var paneSelected = false

        if let ref = session.herdr {
            let outcome = await client.focus(paneId: ref.paneId, workspaceId: ref.workspaceId, tabId: ref.tabId)
            switch outcome {
            case .focused:
                paneSelected = true
            case let .partiallyFocused(_, note):
                paneSelected = true
                notes.append(note)
            case let .failed(reason):
                notes.append("herdr focus failed: \(reason)")
            }
        } else {
            notes.append("no herdr pane for this session")
        }

        // Nothing selected the app yet: activate the host terminal.
        if let bundleId = session.terminalBundleId ?? defaultBundleId, let app = Self.runningApplication(bundleId: bundleId) {
            let activated = app.activate(options: [])
            if !activated { notes.append("could not activate \(bundleId)") }
        } else if session.terminalBundleId != nil || defaultBundleId != nil {
            notes.append("host terminal is not running")
        } else {
            notes.append("no terminal bundle id known")
        }

        if paneSelected, notes.isEmpty { return .focused(session.label) }
        if paneSelected { return .partial(notes.joined(separator: "; ")) }
        return .failed(notes.joined(separator: "; "))
    }

    private static func runningApplication(bundleId: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    /// Activate the terminal that owns a hint bundle id, falling back to any app the user
    /// has used for pi (learned from the registry).
    func activateOnly(bundleId: String?) -> Bool {
        guard let bundleId, let app = Self.runningApplication(bundleId: bundleId) else { return false }
        return app.activate(options: [])
    }
}
