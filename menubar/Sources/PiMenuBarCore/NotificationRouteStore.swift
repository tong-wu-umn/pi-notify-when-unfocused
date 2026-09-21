import Darwin
import Foundation

/// One native notification that PiMenuBar posted, kept so a user action can be mapped
/// back to a session.
///
/// The notification payload carries only `id`; the session key, pane, and request id stay
/// in an owner-only file under Application Support. Notification Center content is
/// visible on the lock screen and survives the session, so nothing identifying goes into
/// `userInfo`.
public struct NotificationRoute: Codable, Sendable, Equatable {
    public var id: String
    public var sessionKey: String
    public var paneId: String?
    public var generationKey: String
    public var requestId: String
    public var createdAt: Int64

    public init(
        id: String,
        sessionKey: String,
        paneId: String?,
        generationKey: String,
        requestId: String,
        createdAt: Date
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.paneId = paneId
        self.generationKey = generationKey
        self.requestId = requestId
        self.createdAt = createdAt.millis
    }

    public var date: Date { Date(millis: createdAt) }
    public var generation: AttentionGeneration? { AttentionGeneration(generationKey: generationKey) }

    /// The entire payload PiMenuBar puts in `UNNotificationContent.userInfo`.
    public var userInfo: [String: String] { [NotificationRouteStore.userInfoKey: id] }
}

/// Persistent map of opaque notification routes.
public struct NotificationRouteStore: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let userInfoKey = "dev.tongwu.PiMenuBar.route"
    public static let requestIdPrefix = "dev.tongwu.PiMenuBar.alert."
    /// A route that never resolved is dropped after this long.
    public static let retentionDays = 7

    public var version: Int
    public var routes: [String: NotificationRoute]

    public init(version: Int = NotificationRouteStore.currentVersion, routes: [String: NotificationRoute] = [:]) {
        self.version = version
        self.routes = routes
    }

    public subscript(id: String) -> NotificationRoute? { routes[id] }

    public func route(for generation: AttentionGeneration) -> NotificationRoute? {
        routes.values.first { $0.generationKey == generation.generationKey }
    }

    /// Reuses the existing route for a generation so a re-post keeps the same request
    /// identifier instead of stacking a second banner.
    @discardableResult
    public mutating func ensureRoute(for generation: AttentionGeneration, session: Session, now: Date) -> NotificationRoute {
        if let existing = route(for: generation) { return existing }
        let id = UUID().uuidString
        let route = NotificationRoute(
            id: id,
            sessionKey: session.key,
            paneId: session.herdr?.paneId,
            generationKey: generation.generationKey,
            requestId: Self.requestIdPrefix + id,
            createdAt: now
        )
        routes[id] = route
        return route
    }

    @discardableResult
    public mutating func remove(id: String) -> NotificationRoute? {
        routes.removeValue(forKey: id)
    }

    @discardableResult
    public mutating func remove(generation: AttentionGeneration) -> NotificationRoute? {
        guard let route = route(for: generation) else { return nil }
        routes.removeValue(forKey: route.id)
        return route
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        routes = routes.filter { $0.value.date >= cutoff }
    }

    public static func load(path: String) -> NotificationRouteStore {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(NotificationRouteStore.self, from: data),
              store.version == currentVersion
        else { return NotificationRouteStore() }
        return store
    }

    /// Atomic, owner-only write. Best effort: a read-only home must not break the app.
    @discardableResult
    public func write(to path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        let temporary = "\(path).tmp.\(getpid())"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
    }
}
