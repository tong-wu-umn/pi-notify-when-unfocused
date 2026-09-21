import Foundation
@testable import PiMenuBarCore

private enum FocusFixture {
    static let ghostty = "com.mitchellh.ghostty"
    static let terminal = "com.apple.Terminal"

    static func preliminary(
        frontmost: String?,
        expected: String? = ghostty,
        herdrFresh: Bool = true,
        selected: String? = "w1:p1",
        session: String? = "w1:p1"
    ) -> FocusDecision {
        FocusPolicy.preliminary(
            frontmostBundleId: frontmost,
            expectedBundleId: expected,
            herdrFresh: herdrFresh,
            selectedPaneId: selected,
            sessionPaneId: session
        )
    }
}

func registerFocusPolicyTests(_ t: TestRunner) {
    t.test("AnotherFrontmostApplicationMeansTheUserIsElsewhere") {
        expectEqual(FocusFixture.preliminary(frontmost: "com.apple.Safari"), .unfocused)
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.terminal, expected: FocusFixture.ghostty), .unfocused)
    }

    t.test("UnknownEvidenceAssumesTheUserIsLooking") {
        expectEqual(FocusFixture.preliminary(frontmost: nil), .unknownAssumeFocused, "no frontmost app must fail open")
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty, expected: nil), .unknownAssumeFocused)
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty, expected: ""), .unknownAssumeFocused)
    }

    t.test("AFreshHerdrSnapshotDecidesBetweenPanes") {
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty), .focused)
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty, selected: "w1:p1", session: "w1:p9"), .unfocused)
    }

    t.test("AStaleSnapshotOrMissingPaneFallsBackToTheTerminalProbe") {
        expectEqual(
            FocusFixture.preliminary(frontmost: FocusFixture.ghostty, herdrFresh: false),
            .needsTerminalProbe,
            "a stale snapshot must not be able to claim the pane is focused"
        )
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty, session: nil), .needsTerminalProbe)
        expectEqual(FocusFixture.preliminary(frontmost: FocusFixture.ghostty, selected: nil), .needsTerminalProbe)
    }

    t.test("TerminalVerdictMatchesCwdAndTitleMarker") {
        let focused = FocusPolicy.terminalVerdict(
            evidence: .pane(cwd: "/tmp/project", title: "π - project"),
            sessionCwd: "/tmp/project",
            titleMarkers: ["π", "pi"]
        )
        expectTrue(focused.focused)

        let otherCwd = FocusPolicy.terminalVerdict(
            evidence: .pane(cwd: "/tmp/other", title: "π - other"),
            sessionCwd: "/tmp/project",
            titleMarkers: ["π", "pi"]
        )
        expectFalse(otherCwd.focused)

        let notPi = FocusPolicy.terminalVerdict(
            evidence: .pane(cwd: "/tmp/project", title: "zsh"),
            sessionCwd: "/tmp/project",
            titleMarkers: ["π", "pi"]
        )
        expectFalse(notPi.focused, "the same directory as a shell is not the pi session")
    }

    t.test("TerminalVerdictNormalizesPaths") {
        let trailingSlash = FocusPolicy.terminalVerdict(
            evidence: .pane(cwd: "/tmp/project/", title: "π - project"),
            sessionCwd: "/tmp/project",
            titleMarkers: ["π"]
        )
        expectTrue(trailingSlash.focused)

        let empty = FocusPolicy.terminalVerdict(
            evidence: .pane(cwd: "", title: "π"),
            sessionCwd: "",
            titleMarkers: ["π"]
        )
        expectFalse(empty.focused, "two unknown directories must not be treated as the same one")

        expectFalse(FocusPolicy.samePath("", ""))
        expectFalse(FocusPolicy.samePath("/", ""))
        expectTrue(FocusPolicy.samePath("/tmp/a/", "/tmp/a"))
    }

    t.test("AnUnavailableProbeAssumesTheUserIsLooking") {
        let verdict = FocusPolicy.terminalVerdict(
            evidence: .unavailable,
            sessionCwd: "/tmp/project",
            titleMarkers: ["π"]
        )
        expectTrue(verdict.focused, "a broken probe must cost a missed banner, not interrupt the wrong pane")
    }
}
