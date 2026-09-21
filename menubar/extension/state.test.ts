/**
 * Registry publisher tests: `node --test extension/state.test.ts` (Node strips the types).
 *
 * These cover the behaviour the menu bar app relies on and that is easy to regress:
 * reload safety, revision ordering, parallel tool calls, prompt privacy, simulation
 * expiry, and config coercion.
 */

import assert from "node:assert/strict";
import test from "node:test";
import {
	coerceConfig,
	createRevisionSource,
	createRevisionSourceFrom,
	DEFAULT_CONFIG,
	expandTilde,
	projectName,
	registryFileName,
	resolveRegistryDir,
	sanitizeText,
	shouldPublish,
	StatusTracker,
} from "./state.ts";

interface Harness {
	tracker: StatusTracker;
	advance: (ms: number) => void;
	now: () => number;
}

function harness(options: { includePromptPreview?: boolean; cwd?: string; herdr?: boolean } = {}): Harness {
	let clock = 1_758_450_000_000;
	const tracker = new StatusTracker({
		clock: {
			now: () => clock,
			processStartedAt: clock - 12_000,
			pid: 85713,
		},
		nextRevision: createRevisionSource(clock),
		includePromptPreview: options.includePromptPreview ?? false,
		terminalBundleId: "com.mitchellh.ghostty",
		herdr: options.herdr === false ? undefined : { paneId: "w1:p1", workspaceId: "w1", tabId: "w1:t1" },
		identity: {
			sessionId: "01a0c3d1-bbc8-74d6-bc36-64188b9b4974",
			sessionFile: "/Users/tongwu/.pi/agent/sessions/--proj--/session.jsonl",
			sessionName: "menu bar work",
			cwd: options.cwd ?? "/Users/tongwu/Downloads/project/pi-notify-when-unfocused",
			mode: "tui",
		},
	});
	tracker.onSessionStart(tracker.identity, false);
	return {
		tracker,
		advance: (ms: number) => {
			clock += ms;
		},
		now: () => clock,
	};
}

test("Registry payload matches the app's required shape", () => {
	const { tracker } = harness();
	tracker.onAgentStart();
	tracker.onToolStart("call_1", "bash");
	tracker.onUsage(84_213, 200_000);
	tracker.onModel("deepseek-flash", "deepseek", "high");
	const state = tracker.snapshot();

	assert.equal(state.v, 1);
	assert.equal(state.pid, 85713);
	assert.equal(state.processStartedAt, 1_758_449_988_000);
	assert.equal(state.state, "working");
	assert.equal(state.project, "pi-notify-when-unfocused");
	assert.equal(state.mode, "tui");
	assert.deepEqual(state.activeTools, [{ id: "call_1", name: "bash", startedAt: state.activeTools[0].startedAt }]);
	assert.equal(state.contextTokens, 84_213);
	assert.equal(state.contextWindow, 200_000);
	assert.equal(state.model, "deepseek-flash");
	assert.equal(state.thinking, "high");
	assert.equal(state.herdr?.paneId, "w1:p1");
	assert.equal(state.simulated, false);
	assert.equal(state.expiresAt, null);
	assert.equal(state.hasPendingMessages, false);
	// The app keys completion acknowledgement off settledAt, and there is no regression
	// here on an initial session.
	assert.equal(tracker.state(), "working");
});

test("Revision survives a reload within the same millisecond", () => {
	const h = harness();
	h.tracker.onAgentStart();
	const published = h.tracker.snapshot().revision;

	// A reload reuses the same pid, so it writes the same file. Seeding from the clock
	// alone can produce an equal revision, which the app would treat as "not newer".
	const reloaded = createRevisionSourceFrom(h.now(), published);
	assert.ok(reloaded() > published, `${reloaded()} should exceed ${published}`);
});

test("A fresh revision source starts above the clock seed", () => {
	const source = createRevisionSource(1_758_450_000_000);
	const first = source();
	assert.ok(first > 1_758_450_000_000 * 1000);
	assert.equal(source(), first + 1);
});

test("Session start mid-run reports working, not idle", () => {
	const { tracker } = harness();
	tracker.onSessionStart(tracker.identity, true);
	assert.equal(tracker.snapshot().state, "working");

	tracker.onSessionStart(tracker.identity, false);
	assert.equal(tracker.snapshot().state, "idle");
});

test("Blocked has priority over working and carries waiting time", () => {
	const h = harness();
	h.tracker.onAgentStart();
	h.advance(5_000);
	h.tracker.onPromptStart("confirm", "Approve or reject\nBash command");
	const blocked = h.tracker.snapshot();
	assert.equal(blocked.state, "blocked");
	assert.equal(blocked.blockedKind, "confirm");
	assert.equal(blocked.stateLabel, "Approve or reject", "only the first line of a multi-line title is used");
	assert.equal(blocked.waitingSince, h.now());

	h.tracker.onPromptEnd();
	assert.equal(h.tracker.snapshot().state, "working", "answering returns to the run, not to idle");
	assert.equal(h.tracker.snapshot().waitingSince, null);
});

test("Prompt labels fall back to a readable default and are sanitized", () => {
	const h = harness();
	h.tracker.onPromptStart("custom", "  \u0007\u001b[31mweird\u001b[0m   title  ");
	const label = h.tracker.snapshot().stateLabel ?? "";
	assert.equal(label.includes("\u001b"), false, "control characters must not reach the app");
	assert.equal(label, "weird title");

	h.tracker.onPromptStart("select");
	assert.equal(h.tracker.snapshot().stateLabel, "Select an option");
});

test("Parallel tools finish out of order without losing the others", () => {
	const h = harness();
	h.tracker.onAgentStart();
	h.tracker.onToolStart("a", "bash");
	h.tracker.onToolStart("b", "read");
	h.tracker.onToolStart("c", "grep");
	h.tracker.onToolEnd("b", "read");
	assert.deepEqual(h.tracker.snapshot().activeTools.map((tool) => tool.name).sort(), ["bash", "grep"]);
	assert.equal(h.tracker.snapshot().lastTool, "read");

	h.tracker.onToolEnd("a", "bash");
	h.tracker.onToolEnd("c", "grep");
	assert.deepEqual(h.tracker.snapshot().activeTools, []);
});

test("Settling clears tools and records the completion time", () => {
	const h = harness();
	h.tracker.onAgentStart();
	h.tracker.onToolStart("a", "bash");
	h.advance(1_500);
	h.tracker.onSettled();
	const state = h.tracker.snapshot();
	assert.equal(state.state, "idle");
	assert.equal(state.settledAt, h.now());
	assert.deepEqual(state.activeTools, []);
});

test("Agent start after a completion clears the previous settledAt", () => {
	const h = harness();
	h.tracker.onAgentStart();
	h.tracker.onSettled();
	assert.notEqual(h.tracker.snapshot().settledAt, null);
	h.advance(30_000);
	h.tracker.onAgentStart();
	assert.equal(h.tracker.snapshot().settledAt, null, "a new run must not look already finished");
});

test("Prompts are omitted by default and truncated when enabled", () => {
	const off = harness();
	off.tracker.onUserPrompt("secret token sk-12345");
	assert.equal(off.tracker.snapshot().lastUserPrompt, null);

	const on = harness({ includePromptPreview: true });
	on.tracker.onUserPrompt(`${"x".repeat(500)}\nsecond line`);
	const preview = on.tracker.snapshot().lastUserPrompt ?? "";
	assert.ok(preview.length <= 120, `preview was ${preview.length} chars`);
	assert.equal(preview.includes("\n"), false);
});

test("Session name changes are sanitized and persisted in the row label data", () => {
	const h = harness();
	h.tracker.onSessionName("  review   bot \u0000");
	assert.equal(h.tracker.snapshot().sessionName, "review bot");
	h.tracker.onSessionName(undefined);
	assert.equal(h.tracker.snapshot().sessionName, undefined);
});

test("Simulation overrides presentation, keeps real state, and expires", () => {
	const h = harness();
	h.tracker.onAgentStart();
	h.tracker.simulate("blocked", 2);
	const simulated = h.tracker.snapshot();
	assert.equal(simulated.state, "blocked");
	assert.equal(simulated.simulated, true);
	assert.equal(simulated.expiresAt, h.now() + 2_000);
	assert.equal(simulated.stateLabel, "simulated (menubar simulate)");

	// Real events still land underneath.
	h.tracker.onToolStart("a", "bash");
	assert.equal(h.tracker.snapshot().state, "blocked");
	assert.equal(h.tracker.snapshot().activeTools.length, 1);

	h.advance(2_001);
	const expired = h.tracker.snapshot();
	assert.equal(expired.simulated, false);
	assert.equal(expired.state, "working", "expiry republishes the live state");
	assert.equal(expired.expiresAt, null);
});

test("Clearing a simulation restores the live state", () => {
	const h = harness();
	h.tracker.simulate("idle", 60);
	assert.equal(h.tracker.snapshot().state, "idle");
	h.tracker.clearSimulation();
	assert.equal(h.tracker.snapshot().state, "idle");
	h.tracker.onAgentStart();
	assert.equal(h.tracker.snapshot().state, "working");
});

test("Context usage tolerates unknown values", () => {
	const h = harness();
	h.tracker.onUsage(null, 200_000);
	assert.equal(h.tracker.snapshot().contextTokens, null);
	assert.equal(h.tracker.snapshot().contextWindow, 200_000);
});

test("Config coercion clamps, defaults, and enforces heartbeat < staleness", () => {
	assert.deepEqual(coerceConfig(null), DEFAULT_CONFIG);
	assert.deepEqual(coerceConfig("nonsense"), DEFAULT_CONFIG);

	const clamped = coerceConfig({ heartbeatMs: 1, staleAfterMs: 2, registryDir: "", includedModes: [] });
	assert.equal(clamped.heartbeatMs, 1_000);
	assert.equal(clamped.registryDir, DEFAULT_CONFIG.registryDir);
	assert.deepEqual(clamped.includedModes, DEFAULT_CONFIG.includedModes);
	assert.ok(clamped.staleAfterMs >= clamped.heartbeatMs * 4);

	const custom = coerceConfig({
		enabled: false,
		includedModes: ["tui", "rpc"],
		registryDir: "/tmp/custom",
		includePromptPreview: true,
	});
	assert.equal(custom.enabled, false);
	assert.deepEqual(custom.includedModes, ["tui", "rpc"]);
	assert.equal(custom.registryDir, "/tmp/custom");
	assert.equal(custom.includePromptPreview, true);
});

test("Mode gating keeps headless runs out by default, RPC allowed when opted in", () => {
	assert.equal(shouldPublish(DEFAULT_CONFIG, "tui"), true);
	assert.equal(shouldPublish(DEFAULT_CONFIG, "print"), false);
	assert.equal(shouldPublish(DEFAULT_CONFIG, "json"), false);
	assert.equal(shouldPublish(DEFAULT_CONFIG, "rpc"), false);
	assert.equal(shouldPublish({ ...DEFAULT_CONFIG, includedModes: ["tui", "rpc"] }, "rpc"), true);
	assert.equal(shouldPublish({ ...DEFAULT_CONFIG, enabled: false }, "tui"), false);
});

test("Paths expand and file names follow the pid", () => {
	assert.equal(expandTilde("~/sessions", "/Users/t"), "/Users/t/sessions");
	assert.equal(expandTilde("~", "/Users/t"), "/Users/t");
	assert.equal(expandTilde("/abs/path", "/Users/t"), "/abs/path");
	assert.equal(resolveRegistryDir(DEFAULT_CONFIG, "/Users/t"), "/Users/t/.pi/agent/menubar/sessions");
	assert.equal(registryFileName(4242), "4242.json");
});

test("Text sanitizing strips control sequences and clamps length", () => {
	assert.equal(sanitizeText(undefined, 10), null);
	assert.equal(sanitizeText("   ", 10), null);
	assert.equal(sanitizeText("a\u0000b", 10), "a b");
	assert.equal(sanitizeText("multi\nline\ttext", 40), "multi line text");
	assert.equal(sanitizeText("x".repeat(50), 10)?.length, 10);
});

test("Project names come from the working directory", () => {
	assert.equal(projectName("/Users/t/project"), "project");
	assert.equal(projectName("/Users/t/project/"), "project");
	assert.equal(projectName("/"), "/");
});
