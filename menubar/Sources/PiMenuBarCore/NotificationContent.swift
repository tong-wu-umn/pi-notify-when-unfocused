import Foundation

/// Native-notification categories, actions, and the text that is allowed to leave the
/// app.
///
/// Everything here is pure so the privacy rule — "Notification Center never learns more
/// than a project name" — is unit tested instead of trusted. Previews, command text,
/// working directories, session files, and the registry's raw `stateLabel` deliberately
/// never reach a banner: banners are visible on the lock screen and persist after the
/// session is gone.
public enum NotificationCategory {
    /// A blocking pi dialog. Focusing is the only useful action.
    public static let prompt = "dev.tongwu.PiMenuBar.attention.prompt"
    /// A finished run. "Mark seen" is meaningful here.
    public static let completion = "dev.tongwu.PiMenuBar.attention.completion"
    public static let test = "dev.tongwu.PiMenuBar.test"
}

public enum NotificationActionIdentifier {
    public static let focus = "dev.tongwu.PiMenuBar.action.focus"
    public static let seen = "dev.tongwu.PiMenuBar.action.seen"
}

/// How available PiMenuBar-owned notifications currently are.
public enum NotificationStatus: String, Sendable, Equatable {
    case disabled
    case unsupported
    case permissionRequired
    case ready
    case denied

    public var label: String {
        switch self {
        case .disabled: return "Off (menubar.json)"
        case .unsupported: return "Unavailable (run the bundled app)"
        case .permissionRequired: return "Permission required"
        case .ready: return "Ready"
        case .denied: return "Disabled in System Settings"
        }
    }

    /// True when an alert can be posted right now.
    public var canDeliver: Bool { self == .ready }

    /// True when the menu's "Send test notification" item makes sense.
    public var canRequestPermission: Bool { self == .permissionRequired || self == .ready }
}

public struct NotificationContent: Sendable, Equatable {
    public let title: String
    public let body: String
    public let category: String

    public init(title: String, body: String, category: String) {
        self.title = title
        self.body = body
        self.category = category
    }
}

public enum NotificationContentBuilder {
    public static let requestIdPrefix = "dev.tongwu.PiMenuBar.alert."
    public static let promptTitle = "π needs your input"
    public static let reminderTitle = "π still needs your input"
    public static let completionTitle = "π finished"
    public static let testTitle = "π test notification"
    /// Longest session label that may appear in a notification body.
    public static let maxLabelLength = 60

    public static func category(for kind: AttentionKind) -> String {
        switch kind {
        case .prompt: return NotificationCategory.prompt
        case .completion: return NotificationCategory.completion
        }
    }

    /// Builds the banner text for one attention generation.
    ///
    /// The text never varies with what pi is actually asking: a prompt title, tool name,
    /// or command could be anything, and a notification is not a private channel.
    public static func content(
        for generation: AttentionGeneration,
        session: Session,
        isReminder: Bool,
        config: NotificationConfig
    ) -> NotificationContent {
        let where_ = location(session: session, config: config)
        switch generation.kind {
        case .prompt:
            return NotificationContent(
                title: isReminder ? reminderTitle : promptTitle,
                body: isReminder
                    ? "Still waiting in \(where_)."
                    : "Approval or input is needed in \(where_).",
                category: category(for: .prompt)
            )
        case .completion:
            return NotificationContent(
                title: completionTitle,
                body: "\(where_) is waiting for your next message.",
                category: category(for: .completion)
            )
        }
    }

    public static func testContent() -> NotificationContent {
        NotificationContent(
            title: testTitle,
            body: "PiMenuBar native notifications are working.",
            category: NotificationCategory.test
        )
    }

    /// Names the session only when the user asked for it, and never longer than
    /// `maxLabelLength`.
    private static func location(session: Session, config: NotificationConfig) -> String {
        guard config.showProjectName else { return "A pi session" }
        let label = sanitize(session.label, max: maxLabelLength)
        return label.isEmpty ? "A pi session" : label
    }

    /// Strips ANSI escapes and other control/format scalars, collapses whitespace, and
    /// clamps length. Registry values are already sanitized by the publisher, but a
    /// notification outlives the process that wrote them, so this is enforced again at
    /// the point of use.
    public static func sanitize(_ value: String, max: Int) -> String {
        let withoutAnsi = ansiPattern.flatMap { pattern -> String in
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return pattern.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: " ")
        } ?? value

        var collapsed = ""
        var lastWasSpace = false
        for scalar in withoutAnsi.unicodeScalars {
            // Whitespace is checked first: tab, newline, and carriage return are `control`
            // scalars, and they must collapse to a space rather than vanish mid-word.
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                if !lastWasSpace, !collapsed.isEmpty {
                    collapsed.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { continue }
            collapsed.unicodeScalars.append(scalar)
            lastWasSpace = false
        }

        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > max else { return trimmed }
        guard max > 1 else { return String(trimmed.prefix(max)) }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    private static let ansiPattern = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")
}
