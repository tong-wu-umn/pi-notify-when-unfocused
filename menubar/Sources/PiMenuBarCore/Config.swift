import Foundation

/// Shared configuration, read by both the menu bar app and the pi extension.
///
/// File: `~/.pi/agent/menubar.json`. Missing file, malformed JSON, or out-of-range
/// values fall back to defaults; nothing in here can prevent startup.
public struct MenuBarConfig: Sendable, Equatable {
    public var enabled: Bool = true
    /// Session modes that publish/render rows. Headless `print`/`json` runs would
    /// otherwise flicker one-shot rows into the menu.
    public var includedModes: [String] = ["tui"]
    public var registryDir: String = MenuBarConfig.defaultRegistryDir
    public var heartbeatMs: Int = 15_000
    public var staleAfterMs: Int = 90_000
    /// Off by default: the registry may contain prompts the user did not expect on disk.
    public var includePromptPreview: Bool = false
    public var showIdle: Bool = true
    public var hideWhenEmpty: Bool = false
    public var maxRows: Int = 20
    public var pollIntervalMs: Int = 30_000
    /// Explicit herdr socket. Needed when the app is launched by LaunchServices and
    /// therefore inherits no terminal environment.
    public var herdrSocketPath: String?
    /// Fallback host terminal used for a herdr row whose registry record is missing.
    public var terminalBundleId: String?
    public var ackRetentionDays: Int = 30
    public var logLevel: LogLevel = .info
    /// PiMenuBar-owned native notifications. Off by default: enabling them while the
    /// root `notify-when-unfocused` extension is still loaded would alert twice.
    public var notifications = NotificationConfig()

    public enum LogLevel: String, Sendable, Codable, CaseIterable {
        case debug, info, warn, error
    }

    public init() {}

    public static var configPath: String {
        ("~/.pi/agent/menubar.json" as NSString).expandingTildeInPath
    }

    public static var defaultRegistryDir: String {
        ("~/.pi/agent/menubar/sessions" as NSString).expandingTildeInPath
    }

    public static var acknowledgementsPath: String {
        let base = ("~/Library/Application Support/PiMenuBar" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("acknowledgements.json")
    }

    public static var lockPath: String {
        let base = ("~/Library/Application Support/PiMenuBar" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("instance.lock")
    }

    /// Opaque native-notification action routes (session key → request id). Kept out of
    /// the notification payload so nothing identifying reaches Notification Center.
    public static var notificationRoutesPath: String {
        let base = ("~/Library/Application Support/PiMenuBar" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("notification-routes.json")
    }

    public static var logPath: String {
        ("~/Library/Logs/PiMenuBar.log" as NSString).expandingTildeInPath
    }

    public var resolvedRegistryDir: String { Self.expand(registryDir) }
    public var resolvedHerdrSocketPath: String? { herdrSocketPath.map(Self.expand) }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Loads config, clamping out-of-range values and ignoring unknown keys.
    public static func load(path: String = MenuBarConfig.configPath) -> MenuBarConfig {
        var config = MenuBarConfig()
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        if let value = raw["enabled"] as? Bool { config.enabled = value }
        if let value = raw["includedModes"] as? [String], !value.isEmpty { config.includedModes = value }
        if let value = raw["registryDir"] as? String, !value.isEmpty { config.registryDir = value }
        if let value = int(raw["heartbeatMs"]) { config.heartbeatMs = clamp(value, 1_000, 600_000) }
        if let value = int(raw["staleAfterMs"]) { config.staleAfterMs = clamp(value, 5_000, 3_600_000) }
        if let value = raw["includePromptPreview"] as? Bool { config.includePromptPreview = value }
        if let value = raw["showIdle"] as? Bool { config.showIdle = value }
        if let value = raw["hideWhenEmpty"] as? Bool { config.hideWhenEmpty = value }
        if let value = int(raw["maxRows"]) { config.maxRows = clamp(value, 1, 200) }
        if let value = int(raw["pollIntervalMs"]) { config.pollIntervalMs = clamp(value, 5_000, 600_000) }
        if let value = raw["herdrSocketPath"] as? String { config.herdrSocketPath = value }
        if let value = raw["terminalBundleId"] as? String { config.terminalBundleId = value }
        if let value = int(raw["ackRetentionDays"]) { config.ackRetentionDays = clamp(value, 1, 3_650) }
        if let value = raw["logLevel"] as? String, let level = LogLevel(rawValue: value) { config.logLevel = level }
        if let value = raw["notifications"] as? [String: Any] {
            config.notifications = NotificationConfig.parse(value)
        }

        // A heartbeat slower than the staleness window would make every row look dead.
        if config.heartbeatMs * 4 > config.staleAfterMs { config.staleAfterMs = config.heartbeatMs * 4 }
        return config
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }
}

/// Policy for PiMenuBar-owned native notifications.
///
/// Everything here is about *whether* an alert is warranted; the delivery mechanics live
/// in the app target. Defaults mirror the root `notify-when-unfocused` extension so the
/// two channels behave alike when a user switches from one to the other — except for
/// `enabled`, which starts false so no existing install suddenly alerts twice.
public struct NotificationConfig: Sendable, Equatable {
    public var enabled: Bool = false
    public var notifyOnPrompts: Bool = true
    public var notifyOnIdle: Bool = true
    /// A completed run shorter than this stays quiet. 0 disables the filter.
    public var idleMinRunMs: Int = 15_000
    /// Extra nudges while the *same* prompt is still open.
    public var reminders: Int = 2
    public var reminderIntervalMs: Int = 20_000
    /// Suppress an alert this soon after the previous one, across sessions.
    public var dedupeMs: Int = 10_000
    public var sound: Bool = true
    /// Ask Ghostty which terminal pane is focused when herdr cannot say.
    public var preciseFocus: Bool = true
    /// Alert for a completion whose run duration is not published. Off by default:
    /// a herdr-only `done` row cannot be distinguished from a two-second reply.
    public var notifyUnknownDurationCompletions: Bool = false
    /// Off means bodies say "A pi session" instead of naming the project.
    public var showProjectName: Bool = true

    public init() {}

    /// Parses the `notifications` object, keeping defaults for anything malformed.
    public static func parse(_ raw: [String: Any]) -> NotificationConfig {
        var config = NotificationConfig()
        if let value = raw["enabled"] as? Bool { config.enabled = value }
        if let value = raw["notifyOnPrompts"] as? Bool { config.notifyOnPrompts = value }
        if let value = raw["notifyOnIdle"] as? Bool { config.notifyOnIdle = value }
        if let value = int(raw["idleMinRunMs"]) { config.idleMinRunMs = clamp(value, 0, 600_000) }
        if let value = int(raw["reminders"]) { config.reminders = clamp(value, 0, 10) }
        if let value = int(raw["reminderIntervalMs"]) { config.reminderIntervalMs = clamp(value, 5_000, 600_000) }
        if let value = int(raw["dedupeMs"]) { config.dedupeMs = clamp(value, 0, 600_000) }
        if let value = raw["sound"] as? Bool { config.sound = value }
        if let value = raw["preciseFocus"] as? Bool { config.preciseFocus = value }
        if let value = raw["notifyUnknownDurationCompletions"] as? Bool { config.notifyUnknownDurationCompletions = value }
        if let value = raw["showProjectName"] as? Bool { config.showProjectName = value }
        return config
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
