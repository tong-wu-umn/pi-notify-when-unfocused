import Foundation
@testable import PiMenuBarCore

enum TestSupport {
    /// Builds a registry record through the real decoder, so tests fail if the wire
    /// schema and the decoder drift apart.
    static func record(_ overrides: [String: Any] = [:]) -> RegistryRecord {
        var base: [String: Any] = [
            "v": 1,
            "revision": 1_758_450_000_123_001,
            "pid": 85713,
            "processStartedAt": 1_758_449_800_000,
            "sessionId": "01a0c3d1-bbc8-74d6-bc36-64188b9b4974",
            "sessionFile": Fixtures.registrySessionFile,
            "sessionName": "menu bar work",
            "cwd": "/Users/tongwu/Downloads/project/pi-notify-when-unfocused",
            "project": "pi-notify-when-unfocused",
            "mode": "tui",
            "state": "working",
            "model": "deepseek-flash",
            "provider": "deepseek",
            "thinking": "high",
            "contextTokens": 84213,
            "contextWindow": 200000,
            "turnIndex": 12,
            "activeTools": [["id": "call_1", "name": "bash", "startedAt": 1_758_449_999_999]],
            "lastTool": "bash",
            "runStartedAt": 1_758_449_900_000,
            "terminalBundleId": "com.mitchellh.ghostty",
            "herdr": ["paneId": "w1:p1", "workspaceId": "w1", "tabId": "w1:t1"],
            "updatedAt": 1_758_450_000_123,
            "simulated": false,
        ]
        for (key, value) in overrides {
            if value is NSNull {
                base.removeValue(forKey: key)
            } else {
                base[key] = value
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: base)
        do {
            return try JSONDecoder().decode(RegistryRecord.self, from: data)
        } catch {
            fail("registry fixture did not decode: \(error)")
            fatalError("unreachable")
        }
    }

    static func snapshot() -> HerdrSnapshot {
        try! HerdrCoding.decodeFrame(Data(Fixtures.snapshotJSON.utf8), as: HerdrSnapshot.self)
    }

    /// A temp directory that removes itself when the test object is deallocated.
    final class TempDirectory {
        let path: String

        init(prefix: String = "pimenubar-tests") {
            path = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: path)
        }

        @discardableResult
        func write(_ name: String, _ contents: String, permissions: Int = 0o600) -> String {
            let full = (path as NSString).appendingPathComponent(name)
            FileManager.default.createFile(
                atPath: full,
                contents: Data(contents.utf8),
                attributes: [.posixPermissions: permissions]
            )
            return full
        }
    }
}

