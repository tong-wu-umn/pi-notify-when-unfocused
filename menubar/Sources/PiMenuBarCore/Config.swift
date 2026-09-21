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
