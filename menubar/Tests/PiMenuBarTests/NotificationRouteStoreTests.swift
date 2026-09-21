import Foundation
@testable import PiMenuBarCore

private enum RouteFixture {
    static let now = Date(millis: 1_758_450_000_000)

    static func generation(marker: Int64 = 1_758_450_000_000) -> AttentionGeneration {
        AttentionGeneration(
            sessionKey: Fixtures.registrySessionFile,
            kind: .prompt,
            marker: marker,
            identity: "pane:w1:p1"
        )
    }

    static func session() -> Session {
        TestSupport.session(
            state: .blocked,
            waitingSince: now,
            herdr: HerdrRef(paneId: "w1:p1", focused: false, stateChangeSeq: 4)
        )
    }
}

func registerNotificationRouteStoreTests(_ t: TestRunner) {
    t.test("UserInfoCarriesOnlyAnOpaqueIdentifier") {
        var store = NotificationRouteStore()
        let route = store.ensureRoute(for: RouteFixture.generation(), session: RouteFixture.session(), now: RouteFixture.now)
        expectEqual(route.userInfo.count, 1)
        expectNotNil(route.userInfo[NotificationRouteStore.userInfoKey])
        // The session path, pane id, and project must not travel with the notification.
        let payload = route.userInfo.values.joined()
        expectFalse(payload.contains(Fixtures.registrySessionFile))
        expectFalse(payload.contains("w1:p1"))
        expectTrue(route.requestId.hasPrefix(NotificationRouteStore.requestIdPrefix))
    }

    t.test("EnsureRouteIsIdempotentPerGeneration") {
        var store = NotificationRouteStore()
        let generation = RouteFixture.generation()
        let first = store.ensureRoute(for: generation, session: RouteFixture.session(), now: RouteFixture.now)
        let second = store.ensureRoute(for: generation, session: RouteFixture.session(), now: RouteFixture.now.addingTimeInterval(30))
        expectEqual(first.id, second.id, "a re-post must reuse the request id instead of stacking banners")
        expectEqual(store.routes.count, 1)
        expectNotNil(store.route(for: generation))
    }

    t.test("ANewCompletionGenerationGetsANewRoute") {
        var store = NotificationRouteStore()
        let first = store.ensureRoute(for: RouteFixture.generation(marker: 1), session: RouteFixture.session(), now: RouteFixture.now)
        let second = store.ensureRoute(for: RouteFixture.generation(marker: 2), session: RouteFixture.session(), now: RouteFixture.now)
        expectNotEqual(first.id, second.id)
        expectEqual(store.route(for: RouteFixture.generation(marker: 1))?.id, first.id)
        expectEqual(store.routes.count, 2)
    }

    t.test("RemovalByGenerationAndById") {
        var store = NotificationRouteStore()
        let generation = RouteFixture.generation()
        let route = store.ensureRoute(for: generation, session: RouteFixture.session(), now: RouteFixture.now)
        expectEqual(store.remove(generation: generation)?.id, route.id)
        expectNil(store.route(for: generation))
        expectNil(store.remove(generation: generation), "removing twice is harmless")

        // A fresh route gets a fresh identifier, so remove the one that exists now.
        store.ensureRoute(for: generation, session: RouteFixture.session(), now: RouteFixture.now)
        let recreated = store.route(for: generation)
        expectNotNil(recreated)
        expectNotNil(store.remove(id: recreated?.id ?? ""))
        expectTrue(store.routes.isEmpty)
    }

    t.test("RouteGenerationRoundTripsThroughItsKey") {
        var store = NotificationRouteStore()
        let generation = RouteFixture.generation()
        store.ensureRoute(for: generation, session: RouteFixture.session(), now: RouteFixture.now)
        let route = store.routes.values.first
        expectEqual(route?.generation?.sessionKey, generation.sessionKey)
        expectEqual(route?.generation?.kind, generation.kind)
        expectEqual(route?.generation?.marker, generation.marker)
        expectEqual(route?.paneId, "w1:p1")
        expectEqual(store.routes.values.first?.sessionKey, Fixtures.registrySessionFile)
    }

    t.test("PruneDropsOldRoutes") {
        var store = NotificationRouteStore()
        store.ensureRoute(for: RouteFixture.generation(marker: 1), session: RouteFixture.session(), now: RouteFixture.now)
        store.ensureRoute(for: RouteFixture.generation(marker: 2), session: RouteFixture.session(), now: RouteFixture.now.addingTimeInterval(-8 * 86_400))
        store.prune(now: RouteFixture.now)
        expectEqual(store.routes.count, 1)
    }

    t.test("RoundTripsThroughDiskWithOwnerOnlyPermissions") {
        let directory = TestSupport.TempDirectory()
        let path = (directory.path as NSString).appendingPathComponent("PiMenuBar/notification-routes.json")
        var store = NotificationRouteStore()
        store.ensureRoute(for: RouteFixture.generation(), session: RouteFixture.session(), now: RouteFixture.now)
        expectTrue(store.write(to: path))

        let loaded = NotificationRouteStore.load(path: path)
        expectEqual(loaded.routes.count, 1)
        expectNotNil(loaded.route(for: RouteFixture.generation()))

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        expectEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    t.test("LoadOfMissingCorruptOrFutureFileYieldsEmptyStore") {
        let directory = TestSupport.TempDirectory()
        let missing = (directory.path as NSString).appendingPathComponent("nope.json")
        expectTrue(NotificationRouteStore.load(path: missing).routes.isEmpty)

        let corrupt = directory.write("corrupt.json", "{\"version\":1,\"routes\":")
        expectTrue(NotificationRouteStore.load(path: corrupt).routes.isEmpty)

        let future = directory.write("future.json", "{\"version\":99,\"routes\":{}}")
        expectTrue(NotificationRouteStore.load(path: future).routes.isEmpty)
    }
}
