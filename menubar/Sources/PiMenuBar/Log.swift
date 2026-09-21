import Foundation
import PiMenuBarCore

/// Bounded file logger.
///
/// The app is an `LSUIElement` with no window, so a log file is the only way to explain
/// why a row or a focus action behaved oddly. Content is never logged, only decisions.
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let lock = NSLock()
    private var level: MenuBarConfig.LogLevel = .info
    private let path: String
    private let maxBytes = 2 * 1024 * 1024

    private init() {
        path = MenuBarConfig.logPath
    }

    var filePath: String { path }

    func configure(level: MenuBarConfig.LogLevel) {
        lock.lock()
        defer { lock.unlock() }
        self.level = level
    }

    func debug(_ message: String) { write(.debug, message) }
    func info(_ message: String) { write(.info, message) }
    func warn(_ message: String) { write(.warn, message) }
    func error(_ message: String) { write(.error, message) }

    private func write(_ messageLevel: MenuBarConfig.LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard messageLevel.rank >= level.rank else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(messageLevel.rawValue)] \(message)\n"
        rotateIfNeeded()
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > maxBytes
        else { return }
        let backup = path + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: path, toPath: backup)
    }
}

extension MenuBarConfig.LogLevel {
    /// Ordering for the `logLevel` cutoff.
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}
