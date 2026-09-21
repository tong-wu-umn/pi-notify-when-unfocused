import Foundation
@testable import PiMenuBarCore

/// Shared fixtures for `RegistryReaderTests`.
private enum ContextRegistryReaderTests {
    static let now = Date(millis: 1_758_450_000_123)

    static var config: MenuBarConfig {
        var config = MenuBarConfig()
        config.staleAfterMs = 90_000
        return config
    }

    static func registryJSON(
        pid: Int,
        revision: Int64 = 1_758_450_000_123_001,
        processStartedAt: Int64 = 1_758_449_800_000,
        updatedAt: Int64? = nil,
        state: String = "working",
        overrides: [String: Any] = [:]
    ) -> String {
        var payload: [String: Any] = [
            "v": 1,
            "revision": revision,
            "pid": pid,
            "processStartedAt": processStartedAt,
            "cwd": "/tmp/project",
            "project": "project",
            "state": state,
            "activeTools": [],
            "updatedAt": updatedAt ?? now.millis,
        ]
        for (key, value) in overrides { payload[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

func registerRegistryReaderTests(_ t: TestRunner) {
    t.test("DecodesRealRecordShape") {
        let record = TestSupport.record()
        expectEqual(record.v, 1)
        expectEqual(record.sessionState, .working)
        expectEqual(record.project, "pi-notify-when-unfocused")
        expectEqual(record.mergeKey, Fixtures.registrySessionFile, "join key must be the session file")
        expectEqual(record.activeToolModels.map(\.name), ["bash"])
        expectEqual(record.herdr?.paneId, Fixtures.piNotifyPaneId)
        expectEqual(record.updatedDate, ContextRegistryReaderTests.now)
        expectNotNil(record.runStartedDate)
        expectNil(record.settledDate)
    }

    t.test("ReadsAValidFile") {
        let directory = TestSupport.TempDirectory()
        directory.write("123.json", Fixtures.registryRecordJSON)
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectEqual(scan.records.count, 1)
        expectTrue(scan.issues.isEmpty, "\(scan.issues)")
        expectTrue(scan.removedPaths.isEmpty)
    }

    t.test("StaleRecordIsDroppedButYoungRecordSurvives") {
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        directory.write("fresh.json", ContextRegistryReaderTests.registryJSON(pid: 1, updatedAt: now.millis - 10_000))
        directory.write("stale.json", ContextRegistryReaderTests.registryJSON(pid: 2, updatedAt: now.millis - 120_000))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now)
        expectEqual(scan.records.map(\.pid), [1])
    }

    t.test("FutureSkewedTimestampIsNotStale") {
        // Clocks move backwards (NTP, sleep/wake); a future stamp must not hide a row.
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        directory.write("future.json", ContextRegistryReaderTests.registryJSON(pid: 3, updatedAt: now.millis + 5_000))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now)
        expectEqual(scan.records.count, 1)
    }

    t.test("MalformedFileIsReportedNotFatal") {
        let directory = TestSupport.TempDirectory()
        directory.write("broken.json", "{\"v\":1,")
        directory.write("good.json", Fixtures.registryRecordJSON)
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectEqual(scan.records.count, 1)
        expectEqual(scan.issues.count, 1)
        expectTrue(scan.issues[0].reason.contains("malformed"), scan.issues[0].reason)
    }

    t.test("UnsupportedVersionIsReported") {
        let directory = TestSupport.TempDirectory()
        directory.write("v2.json", ContextRegistryReaderTests.registryJSON(pid: 4, overrides: ["v": 2]))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectTrue(scan.records.isEmpty)
        expectEqual(scan.issues.first?.reason, "unsupported registry version 2")
    }

    t.test("GroupOrOtherAccessibleFileIsRefused") {
        let directory = TestSupport.TempDirectory()
        directory.write("loose.json", Fixtures.registryRecordJSON, permissions: 0o644)
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectTrue(scan.records.isEmpty, "a world-readable registry file must not be parsed")
        expectEqual(scan.issues.first?.reason, "group/other permissions set")
    }

    t.test("SymlinkIsRefused") {
        let directory = TestSupport.TempDirectory()
        let target = directory.write("real.json", Fixtures.registryRecordJSON)
        try FileManager.default.createSymbolicLink(
            atPath: (directory.path as NSString).appendingPathComponent("link.json"),
            withDestinationPath: target
        )
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectEqual(scan.records.count, 1, "only the real file is read")
        expectTrue(scan.issues.contains { $0.reason == "not a regular file" }, "\(scan.issues)")
    }

    t.test("HighestRevisionWinsForTheSameProcessIdentity") {
        let directory = TestSupport.TempDirectory()
        directory.write("old.json", ContextRegistryReaderTests.registryJSON(pid: 5, revision: 100, processStartedAt: 42, state: "idle"))
        directory.write("new.json", ContextRegistryReaderTests.registryJSON(pid: 5, revision: 200, processStartedAt: 42, state: "working"))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectEqual(scan.records.count, 1)
        expectEqual(scan.records[0].sessionState, .working)
    }

    t.test("TempFilesAreIgnoredAndOldTempFilesCollected") {
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        let temp = directory.write("123.json.tmp.999", "{")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)], ofItemAtPath: temp)
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now)
        expectTrue(scan.records.isEmpty)
        expectFalse(scan.issues.contains { $0.path.hasSuffix("999") }, "temp files are not user-visible problems")
        expectTrue(scan.removedPaths.contains(temp))
        expectFalse(FileManager.default.fileExists(atPath: temp))
    }

    t.test("GarbageCollectionRemovesLongDeadFilesOnly") {
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        let dead = directory.write("dead.json", ContextRegistryReaderTests.registryJSON(pid: 6, updatedAt: now.millis - 1_000_000))
        let recentlyStale = directory.write("recent.json", ContextRegistryReaderTests.registryJSON(pid: 7, updatedAt: now.millis - 95_000))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now, collectGarbage: true)
        expectTrue(scan.records.isEmpty)
        expectTrue(scan.removedPaths.contains(dead))
        expectFalse(scan.removedPaths.contains(recentlyStale), "only 10x-stale files are removed")
        expectTrue(FileManager.default.fileExists(atPath: recentlyStale))
    }

    t.test("GarbageCollectionCanBeDisabled") {
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        let dead = directory.write("dead.json", ContextRegistryReaderTests.registryJSON(pid: 8, updatedAt: now.millis - 1_000_000))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now, collectGarbage: false)
        expectTrue(scan.removedPaths.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: dead))
    }

    t.test("ExpiredSimulatedRowIsHiddenButLiveOneIsKept") {
        let directory = TestSupport.TempDirectory()
        let now = ContextRegistryReaderTests.now
        directory.write("expired.json", ContextRegistryReaderTests.registryJSON(pid: 9, overrides: ["simulated": true, "expiresAt": now.millis - 1_000]))
        directory.write("live.json", ContextRegistryReaderTests.registryJSON(pid: 10, overrides: ["simulated": true, "expiresAt": now.millis + 60_000]))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: now)
        expectEqual(scan.records.map(\.pid), [10])
        expectEqual(scan.records[0].simulated, true, "simulated flag decodes")
    }

    t.test("SimulatedRowWithoutExpiryIsHidden") {
        let directory = TestSupport.TempDirectory()
        directory.write("noexpiry.json", ContextRegistryReaderTests.registryJSON(pid: 11, overrides: ["simulated": true]))
        let scan = RegistryReader.scan(directory: directory.path, config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectTrue(scan.records.isEmpty)
    }

    t.test("MissingDirectoryIsNotAnError") {
        let scan = RegistryReader.scan(directory: "/nonexistent/pimenubar", config: ContextRegistryReaderTests.config, now: ContextRegistryReaderTests.now)
        expectTrue(scan.records.isEmpty)
        expectTrue(scan.issues.isEmpty)
    }

    t.test("EnsureDirectoryCreatesOwnerOnlyDirectory") {
        let base = TestSupport.TempDirectory()
        let target = (base.path as NSString).appendingPathComponent("nested/sessions")
        try RegistryReader.ensureDirectory(target)
        var isDirectory: ObjCBool = false
        expectTrue(FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory))
        expectTrue(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: target)
        expectEqual(attributes[.posixPermissions] as? Int, 0o700)
    }
}
