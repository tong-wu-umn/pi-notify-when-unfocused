import Foundation
@testable import PiMenuBarCore

private enum ContentFixture {
    static let now = Date(millis: 1_758_450_000_000)

    static func promptSession(project: String = "pi-notify-when-unfocused") -> Session {
        TestSupport.session(project: project, state: .blocked, waitingSince: now)
    }

    static func completionSession(project: String = "mobile_pda") -> Session {
        TestSupport.session(
            project: project,
            state: .idle,
            settledAt: now,
            runStartedAt: now.addingTimeInterval(-600)
        )
    }

    static func generation(_ session: Session, kind: AttentionKind) -> AttentionGeneration {
        AttentionGeneration(sessionKey: session.key, kind: kind, marker: 1, identity: "pane:w1:p1")
    }
}

func registerNotificationContentTests(_ t: TestRunner) {
    t.test("PromptBodiesAreGenericAndPrivacyPreserving") {
        let session = ContentFixture.promptSession()
        let content = NotificationContentBuilder.content(
            for: ContentFixture.generation(session, kind: .prompt),
            session: session,
            isReminder: false,
            config: TestSupport.notifications()
        )
        expectEqual(content.title, "π needs your input")
        expectEqual(content.body, "Approval or input is needed in pi-notify-when-unfocused.")
        expectEqual(content.category, NotificationCategory.prompt)
        // The blocker's own text never appears: banners outlive the session and are
        // visible on the lock screen.
        expectFalse(content.body.contains(session.cwd))
        expectFalse(content.body.contains("session.jsonl"))
    }

    t.test("ReminderAndCompletionBodies") {
        let session = ContentFixture.promptSession()
        let reminder = NotificationContentBuilder.content(
            for: ContentFixture.generation(session, kind: .prompt),
            session: session,
            isReminder: true,
            config: TestSupport.notifications()
        )
        expectEqual(reminder.title, "π still needs your input")
        expectEqual(reminder.body, "Still waiting in pi-notify-when-unfocused.")

        let completion = ContentFixture.completionSession()
        let finished = NotificationContentBuilder.content(
            for: ContentFixture.generation(completion, kind: .completion),
            session: completion,
            isReminder: false,
            config: TestSupport.notifications()
        )
        expectEqual(finished.title, "π finished")
        expectEqual(finished.body, "mobile_pda is waiting for your next message.")
        expectEqual(finished.category, NotificationCategory.completion)
    }

    t.test("ShowProjectNameOffHidesTheProject") {
        let session = ContentFixture.promptSession(project: "secret-project")
        let content = NotificationContentBuilder.content(
            for: ContentFixture.generation(session, kind: .prompt),
            session: session,
            isReminder: false,
            config: TestSupport.notifications(showProjectName: false)
        )
        expectEqual(content.body, "Approval or input is needed in A pi session.")
        expectFalse(content.body.contains("secret-project"))
    }

    t.test("LabelsAreSanitizedAndClamped") {
        expectEqual(NotificationContentBuilder.sanitize("  a\n\n b  ", max: 40), "a b")
        expectEqual(NotificationContentBuilder.sanitize("hi\u{001B}[31mthere", max: 40), "hi there", "ANSI escapes must not leak into a banner")
        expectEqual(NotificationContentBuilder.sanitize("tab\tseparated", max: 40), "tab separated")
        expectEqual(NotificationContentBuilder.sanitize("\u{0007}bell", max: 40), "bell")
        expectEqual(NotificationContentBuilder.sanitize(String(repeating: "x", count: 200), max: 20), String(repeating: "x", count: 19) + "…")
        expectEqual(NotificationContentBuilder.sanitize("   ", max: 20), "")

        let long = TestSupport.session(project: String(repeating: "p", count: 200), state: .blocked, waitingSince: ContentFixture.now)
        let content = NotificationContentBuilder.content(
            for: ContentFixture.generation(long, kind: .prompt),
            session: long,
            isReminder: false,
            config: TestSupport.notifications()
        )
        expectTrue(content.body.count <= NotificationContentBuilder.maxLabelLength + 40)
    }

    t.test("ATestNotificationIsItsOwnCategory") {
        let content = NotificationContentBuilder.testContent()
        expectEqual(content.title, "π test notification")
        expectEqual(content.category, NotificationCategory.test)
        expectEqual(NotificationContentBuilder.category(for: .prompt), NotificationCategory.prompt)
        expectEqual(NotificationContentBuilder.category(for: .completion), NotificationCategory.completion)
    }

    t.test("StatusLabelsAndCapabilities") {
        expectEqual(NotificationStatus.disabled.label, "Off (menubar.json)")
        expectEqual(NotificationStatus.permissionRequired.label, "Permission required")
        expectEqual(NotificationStatus.denied.label, "Disabled in System Settings")
        expectTrue(NotificationStatus.ready.canDeliver)
        expectFalse(NotificationStatus.denied.canDeliver)
        expectTrue(NotificationStatus.permissionRequired.canRequestPermission)
        expectFalse(NotificationStatus.disabled.canRequestPermission)
        expectFalse(NotificationStatus.unsupported.canRequestPermission)
    }
}
