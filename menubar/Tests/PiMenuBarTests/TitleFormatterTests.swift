import Foundation
@testable import PiMenuBarCore

/// Shared fixtures for `TitleFormatterTests`.
private enum ContextTitleFormatterTests {
    static let now = Date(millis: 1_758_450_000_000)

    static func makeSession(
        state: SessionState,
        needsAttention: Bool = false,
        label: String = "project",
        waitingSince: Date? = nil,
        runStartedAt: Date? = nil
    ) -> Session {
        Session(
            key: label,
            source: .registry,
            project: label,
            cwd: "/tmp/\(label)",
            state: state,
            updatedAt: now,
            needsAttention: needsAttention || state == .blocked,
            runStartedAt: runStartedAt,
            waitingSince: waitingSince
        )
    }
}

func registerTitleFormatterTests(_ t: TestRunner) {
    t.test("EmptyFleetShowsBarePrefix") {
        expectEqual(TitleFormatter.title([], showIdle: true), "π")
        expectEqual(TitleFormatter.tooltip([], now: ContextTitleFormatterTests.now), "π — no active sessions")
    }

    t.test("BoundedCountsInAttentionOrder") {
        let sessions = [
            ContextTitleFormatterTests.makeSession(state: .blocked),
            ContextTitleFormatterTests.makeSession(state: .working),
            ContextTitleFormatterTests.makeSession(state: .working),
            ContextTitleFormatterTests.makeSession(state: .done, needsAttention: true),
            ContextTitleFormatterTests.makeSession(state: .idle),
            ContextTitleFormatterTests.makeSession(state: .idle),
        ]
        expectEqual(TitleFormatter.title(sessions, showIdle: true), "π 1!2▶1○2·")
    }

    t.test("IdleCanBeHidden") {
        let sessions = [
            ContextTitleFormatterTests.makeSession(state: .working),
            ContextTitleFormatterTests.makeSession(state: .idle),
            ContextTitleFormatterTests.makeSession(state: .idle),
        ]
        expectEqual(TitleFormatter.title(sessions, showIdle: false), "π 1▶")
        expectEqual(TitleFormatter.title(sessions, showIdle: true), "π 1▶2·")
    }

    t.test("CountsClampAtNine") {
        let sessions = (0..<14).map { _ in ContextTitleFormatterTests.makeSession(state: .working) }
        expectEqual(TitleFormatter.title(sessions, showIdle: true), "π 9+▶")
    }

    t.test("UnknownGetsItsOwnBucket") {
        let sessions = [
            ContextTitleFormatterTests.makeSession(state: .unknown),
            ContextTitleFormatterTests.makeSession(state: .idle),
        ]
        expectEqual(TitleFormatter.title(sessions, showIdle: true), "π 1·1?")
    }

    t.test("AcknowledgedCompletionIsNotCountedAsAttention") {
        let sessions = [
            ContextTitleFormatterTests.makeSession(state: .done, needsAttention: true),
            ContextTitleFormatterTests.makeSession(state: .done, needsAttention: false),
        ]
        expectEqual(TitleFormatter.title(sessions, showIdle: true), "π 1○1·")
        let summary = TitleFormatter.summary(sessions)
        expectEqual(summary.attention, 1)
        expectEqual(summary.idle, 1)
        expectEqual(summary.total, 2)
    }

    t.test("TooltipNamesSessionsAndOldestWaits") {
        let now = ContextTitleFormatterTests.now
        let sessions = [
            ContextTitleFormatterTests.makeSession(state: .blocked, label: "jev-sts2", waitingSince: now.addingTimeInterval(-45)),
            ContextTitleFormatterTests.makeSession(state: .working, label: "mobile_pda", runStartedAt: now.addingTimeInterval(-180)),
            ContextTitleFormatterTests.makeSession(state: .idle, label: "spend_tracker"),
        ]
        let tooltip = TitleFormatter.tooltip(sessions, now: now)
        expectTrue(tooltip.hasPrefix("π — "), tooltip)
        expectTrue(tooltip.contains("1 blocked (jev-sts2 45s)"), tooltip)
        expectTrue(tooltip.contains("1 working (mobile_pda 3m)"), tooltip)
        expectTrue(tooltip.contains("1 idle (spend_tracker)"), tooltip)
    }

    t.test("TooltipTruncatesLongFleets") {
        let sessions = (0..<7).map { ContextTitleFormatterTests.makeSession(state: .working, label: "p\($0)") }
        let tooltip = TitleFormatter.tooltip(sessions, now: ContextTitleFormatterTests.now)
        expectTrue(tooltip.contains("7 working"), tooltip)
        expectTrue(tooltip.contains("+3 more"), tooltip)
    }

    t.test("RowTitleIncludesGlyphFocusMarkerAndDetails") {
        let now = ContextTitleFormatterTests.now
        var session = ContextTitleFormatterTests.makeSession(state: .working, label: "mobile_pda")
        session.activeTools = [
            ActiveTool(id: "1", name: "bash", startedAt: now.addingTimeInterval(-5)),
            ActiveTool(id: "2", name: "read", startedAt: now.addingTimeInterval(-3)),
        ]
        session.runStartedAt = now.addingTimeInterval(-720)
        session.model = "deepseek-flash"
        session.contextTokens = 84_000
        session.contextWindow = 200_000
        expectEqual(TitleFormatter.rowTitle(session, now: now), "▶  mobile_pda — bash +1 · 12m · deepseek-flash · 42%")

        session.focused = true
        expectTrue(TitleFormatter.rowTitle(session, now: now).hasPrefix("▶• mobile_pda"), TitleFormatter.rowTitle(session, now: now))
    }

    t.test("BlockedRowTitleLeadsWithWaitingTime") {
        let now = ContextTitleFormatterTests.now
        let session = ContextTitleFormatterTests.makeSession(state: .blocked, label: "jev-sts2", waitingSince: now.addingTimeInterval(-45))
        expectEqual(TitleFormatter.rowTitle(session, now: now), "!  jev-sts2 — blocked 45s")
    }

    t.test("AcknowledgedCompletionRowShowsIdleGlyph") {
        let session = ContextTitleFormatterTests.makeSession(state: .done, needsAttention: false, label: "spend_tracker")
        expectEqual(TitleFormatter.rowTitle(session, now: ContextTitleFormatterTests.now), "·  spend_tracker")
    }

    t.test("DetailTextReportsTheFactsNeededToDebugARow") {
        let now = ContextTitleFormatterTests.now
        var session = ContextTitleFormatterTests.makeSession(state: .blocked, label: "jev-sts2", waitingSince: now.addingTimeInterval(-45))
        session.herdr = HerdrRef(paneId: "w1:p2", tabId: "w1:t2", workspaceId: "w1")
        session.sessionFile = "/tmp/session.jsonl"
        session.model = "deepseek-flash"
        session.contextTokens = 1_000
        session.contextWindow = 8_000
        session.stateLabel = "Approve or reject — Bash command"
        let text = TitleFormatter.detailText(session, now: now)
        for expected in [
            "state:      blocked (needs attention)",
            "pane:       w1:p2",
            "session:    /tmp/session.jsonl",
            "model:      deepseek-flash",
            "context:    1000/8000 (13%)",
            "waiting:    45s",
            "label:      Approve or reject — Bash command",
        ] {
            expectTrue(text.contains(expected), "missing \(expected) in:\n\(text)")
        }
    }

    t.test("DurationLabels") {
        let now = ContextTitleFormatterTests.now
        expectEqual(DurationLabel.compact(from: now, to: now), "0s")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-45), to: now), "45s")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-90), to: now), "1m")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-720), to: now), "12m")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-7_620), to: now), "2h7m")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-7_200), to: now), "2h")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(-3 * 86_400), to: now), "3d")
        expectEqual(DurationLabel.compact(from: now.addingTimeInterval(60), to: now), "0s", "clock skew must not go negative")
    }
}

func registerConfigTests(_ t: TestRunner) {
    t.test("Defaults") {
        let config = MenuBarConfig()
        expectTrue(config.enabled)
        expectEqual(config.includedModes, ["tui"])
        expectEqual(config.includePromptPreview, false, "prompt previews must be opt-in")
        expectEqual(config.hideWhenEmpty, false, "the item must stay reachable when empty")
        expectEqual(config.registryDir, MenuBarConfig.defaultRegistryDir)
        expectEqual(config.maxRows, 20)
        expectNil(config.herdrSocketPath)
    }

    t.test("MissingOrMalformedFileYieldsDefaults") {
        let directory = TestSupport.TempDirectory()
        let missing = (directory.path as NSString).appendingPathComponent("absent.json")
        expectEqual(MenuBarConfig.load(path: missing), MenuBarConfig())

        let broken = directory.write("broken.json", "{not json")
        expectEqual(MenuBarConfig.load(path: broken), MenuBarConfig())
    }

    t.test("KnownKeysLoadAndUnknownKeysAreIgnored") {
        let directory = TestSupport.TempDirectory()
        let path = directory.write("config.json", """
        {
          "enabled": false,
          "includedModes": ["tui", "rpc"],
          "registryDir": "/tmp/custom-registry",
          "heartbeatMs": 20000,
          "staleAfterMs": 120000,
          "includePromptPreview": true,
          "showIdle": false,
          "hideWhenEmpty": true,
          "maxRows": 5,
          "pollIntervalMs": 45000,
          "herdrSocketPath": "/tmp/herdr.sock",
          "terminalBundleId": "com.mitchellh.ghostty",
          "ackRetentionDays": 7,
          "logLevel": "debug",
          "somethingNew": {"nested": true}
        }
        """)
        let config = MenuBarConfig.load(path: path)
        expectEqual(config.enabled, false)
        expectEqual(config.includedModes, ["tui", "rpc"])
        expectEqual(config.registryDir, "/tmp/custom-registry")
        expectEqual(config.heartbeatMs, 20_000)
        expectEqual(config.staleAfterMs, 120_000)
        expectEqual(config.includePromptPreview, true)
        expectEqual(config.showIdle, false)
        expectEqual(config.hideWhenEmpty, true)
        expectEqual(config.maxRows, 5)
        expectEqual(config.pollIntervalMs, 45_000)
        expectEqual(config.herdrSocketPath, "/tmp/herdr.sock")
        expectEqual(config.terminalBundleId, "com.mitchellh.ghostty")
        expectEqual(config.ackRetentionDays, 7)
        expectEqual(config.logLevel, .debug)
    }

    t.test("OutOfRangeValuesAreClamped") {
        let directory = TestSupport.TempDirectory()
        let path = directory.write("config.json", """
        {"heartbeatMs": 1, "staleAfterMs": 2, "maxRows": 100000, "pollIntervalMs": 1, "ackRetentionDays": 0, "logLevel": "shout"}
        """)
        let config = MenuBarConfig.load(path: path)
        expectEqual(config.heartbeatMs, 1_000)
        expectEqual(config.maxRows, 200)
        expectEqual(config.pollIntervalMs, 5_000)
        expectEqual(config.ackRetentionDays, 1)
        expectEqual(config.logLevel, .info, "an unknown level must fall back")
        // A heartbeat slower than the staleness window would make every row look dead.
        expectGreaterThanOrEqual(config.staleAfterMs, config.heartbeatMs * 4)
    }

    t.test("TildeExpansion") {
        expectFalse(MenuBarConfig().resolvedRegistryDir.hasPrefix("~"))
        expectTrue(MenuBarConfig().resolvedRegistryDir.hasPrefix("/"))
    }

    t.test("NativeNotificationsAreOffByDefault") {
        let config = MenuBarConfig()
        expectFalse(config.notifications.enabled, "enabling by default would alert twice for /nudge users")
        expectTrue(config.notifications.notifyOnPrompts)
        expectTrue(config.notifications.notifyOnIdle)
        expectEqual(config.notifications.idleMinRunMs, 15_000)
        expectEqual(config.notifications.reminders, 2)
        expectFalse(config.notifications.notifyUnknownDurationCompletions)
        expectTrue(config.notifications.preciseFocus)
        expectTrue(config.notifications.sound)
        expectTrue(MenuBarConfig.notificationRoutesPath.hasPrefix("/"))
    }

    t.test("NotificationsBlockLoadsAndClamps") {
        let directory = TestSupport.TempDirectory()
        let path = directory.write("config.json", """
        {
          "notifications": {
            "enabled": true,
            "notifyOnPrompts": false,
            "notifyOnIdle": true,
            "idleMinRunMs": 2500,
            "reminders": 99,
            "reminderIntervalMs": 1,
            "dedupeMs": -5,
            "sound": false,
            "preciseFocus": false,
            "notifyUnknownDurationCompletions": true,
            "showProjectName": false,
            "somethingNew": true
          }
        }
        """)
        let config = MenuBarConfig.load(path: path)
        expectTrue(config.notifications.enabled)
        expectFalse(config.notifications.notifyOnPrompts)
        expectTrue(config.notifications.notifyOnIdle)
        expectEqual(config.notifications.idleMinRunMs, 2_500)
        expectEqual(config.notifications.reminders, 10, "clamped")
        expectEqual(config.notifications.reminderIntervalMs, 5_000, "clamped")
        expectEqual(config.notifications.dedupeMs, 0, "clamped")
        expectFalse(config.notifications.sound)
        expectFalse(config.notifications.preciseFocus)
        expectTrue(config.notifications.notifyUnknownDurationCompletions)
        expectFalse(config.notifications.showProjectName)
    }

    t.test("AMalformedNotificationsBlockKeepsTheDefaults") {
        let directory = TestSupport.TempDirectory()
        let path = directory.write("config.json", "{\"notifications\": \"yes please\"}")
        expectEqual(MenuBarConfig.load(path: path).notifications, NotificationConfig())
        expectEqual(MenuBarConfig.load(path: path).notifications.enabled, false)
    }
}
