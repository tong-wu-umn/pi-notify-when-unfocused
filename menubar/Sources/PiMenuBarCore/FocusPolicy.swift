import Foundation

/// The answer to "is the user looking at *this* session right now?".
public struct FocusVerdict: Sendable, Equatable {
    public let focused: Bool
    public let reason: String

    public init(focused: Bool, reason: String) {
        self.focused = focused
        self.reason = reason
    }

    public static func focused(_ reason: String) -> FocusVerdict { FocusVerdict(focused: true, reason: reason) }
    public static func unfocused(_ reason: String) -> FocusVerdict { FocusVerdict(focused: false, reason: reason) }
}

/// What the platform must still find out before a verdict is possible.
public enum FocusDecision: Sendable, Equatable {
    case focused
    case unfocused
    /// The host terminal is frontmost but the exact pane is unknown: ask the terminal.
    case needsTerminalProbe
    /// Not enough evidence. Stay quiet rather than interrupt the pane the user is in.
    case unknownAssumeFocused
}

/// What the terminal reported about its focused pane.
public enum TerminalEvidence: Sendable, Equatable {
    case pane(cwd: String, title: String)
    case unavailable
}

/// Focus rules, split from the AppKit/AppleScript plumbing so every branch is testable.
///
/// The whole policy is fail-open: any uncertainty means "assume the user is looking", so
/// a broken probe costs a missed banner instead of interrupting the pane in use.
public enum FocusPolicy {
    /// First stage: app-level evidence, plus herdr's pane selection when it is fresh.
    ///
    /// `selectedPaneId` is only meaningful together with `herdrFresh`; a stale snapshot
    /// must not be able to claim that the user is looking at a pane.
    public static func preliminary(
        frontmostBundleId: String?,
        expectedBundleId: String?,
        herdrFresh: Bool,
        selectedPaneId: String?,
        sessionPaneId: String?
    ) -> FocusDecision {
        guard let frontmost = frontmostBundleId, !frontmost.isEmpty else {
            return .unknownAssumeFocused
        }
        // Without a known host terminal there is nothing to compare against.
        guard let expected = expectedBundleId, !expected.isEmpty else {
            return .unknownAssumeFocused
        }
        guard frontmost == expected else { return .unfocused }
        if herdrFresh, let selected = selectedPaneId, let pane = sessionPaneId, !pane.isEmpty {
            return selected == pane ? .focused : .unfocused
        }
        return .needsTerminalProbe
    }

    /// Second stage: the terminal told us which pane has focus.
    public static func terminalVerdict(
        evidence: TerminalEvidence,
        sessionCwd: String,
        titleMarkers: [String]
    ) -> FocusVerdict {
        switch evidence {
        case .unavailable:
            return .focused("the focused terminal pane could not be identified")
        case let .pane(cwd, title):
            let sameDirectory = samePath(cwd, sessionCwd)
            let isPi = titleMarkers.contains { !$0.isEmpty && title.contains($0) }
            guard sameDirectory, isPi else {
                return .unfocused("the focused terminal pane is a different pane")
            }
            return .focused("the focused terminal pane is this session")
        }
    }

    /// Trailing slashes and empty paths never count as a match.
    public static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ value: String) -> String {
            var trimmed = value.trimmingCharacters(in: .whitespaces)
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }
}
