import Darwin
import Foundation

/// Chooses which herdr socket to talk to.
///
/// A menu bar app started by LaunchServices or a LaunchAgent inherits no shell
/// environment, so `HERDR_SOCKET_PATH` is usually absent even while herdr is running.
/// The registry files carry the socket the writer actually used, which is the only
/// in-band discovery signal available outside a terminal.
public enum HerdrSocketDiscovery {
    public struct Candidate: Sendable, Equatable {
        public let path: String
        public let source: String

        public init(path: String, source: String) {
            self.path = path
            self.source = source
        }
    }

    /// Ordered candidates, best first. Pure: no filesystem access, so it is testable.
    public static func candidates(
        configuredPath: String?,
        registry: [RegistryRecord],
        environment: [String: String],
        defaultPath: String = HerdrProtocol.defaultSocketPath
    ) -> [Candidate] {
        var result: [Candidate] = []
        var seen: Set<String> = []

        func add(_ path: String?, _ source: String) {
            guard let path, !path.isEmpty else { return }
            let expanded = MenuBarConfig.expand(path)
            guard expanded.hasPrefix("/"), !seen.contains(expanded) else { return }
            seen.insert(expanded)
            result.append(Candidate(path: expanded, source: source))
        }

        add(configuredPath, "config herdrSocketPath")
        add(environment["HERDR_SOCKET_PATH"], "HERDR_SOCKET_PATH")
        // Most recently updated registry rows are the freshest evidence of a live server.
        let sockets = registry
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { $0.herdr?.socketPath }
        for socket in sockets {
            add(socket, "registry")
        }
        add(defaultPath, "default")
        return result
    }

    /// True when `path` is a socket owned by this user that can be connected to.
    public static func isUsableSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return false }
        guard info.st_uid == getuid() else { return false }
        guard let socket = try? UnixSocket(path: path) else { return false }
        socket.close()
        return true
    }

    /// First usable candidate, plus how many distinct usable sockets exist so the app can
    /// warn instead of silently merging two servers.
    public static func resolve(
        configuredPath: String?,
        registry: [RegistryRecord],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultPath: String = HerdrProtocol.defaultSocketPath
    ) -> (chosen: Candidate?, usableCount: Int, attempted: [Candidate]) {
        let all = candidates(
            configuredPath: configuredPath,
            registry: registry,
            environment: environment,
            defaultPath: defaultPath
        )
        let usable = all.filter { isUsableSocket($0.path) }
        return (usable.first, usable.count, all)
    }
}
