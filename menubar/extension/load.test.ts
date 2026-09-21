/**
 * End-to-end test for the publisher wiring: `node --test extension/load.test.ts`.
 *
 * `index.ts` is imported for real (Node strips the types; the pi import is type-only) and
 * driven with a stub `pi` object, so this covers the parts `state.test.ts` cannot: which
 * events are subscribed, what lands on disk, permissions, reload cleanup, and shutdown.
 */

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

type Handler = (event: any, ctx: any) => unknown;

interface StubPi {
	handlers: Map<string, Handler[]>;
	commands: Map<string, { description: string; handler: (args: string, ctx: any) => Promise<void> }>;
	on: (event: string, handler: Handler) => () => void;
	registerCommand: (name: string, definition: any) => void;
	fire: (event: string, payload?: any, ctx?: any) => Promise<void>;
}

function stubPi(): StubPi {
	const handlers = new Map<string, Handler[]>();
	const commands = new Map<string, any>();
	return {
		handlers,
		commands,
		on(event, handler) {
			const list = handlers.get(event) ?? [];
			list.push(handler);
			handlers.set(event, list);
			return () => {};
		},
		registerCommand(name, definition) {
			commands.set(name, definition);
		},
		async fire(event, payload = {}, ctx = {}) {
			for (const handler of handlers.get(event) ?? []) {
				await handler({ type: event, ...payload }, ctx);
			}
		},
	};
}

interface ContextOptions {
	mode?: string;
	idle?: boolean;
	cwd?: string;
	tokens?: number | null;
	pending?: boolean;
}

function stubContext(options: ContextOptions = {}) {
	const notifications: string[] = [];
	return {
		notifications,
		mode: options.mode ?? "tui",
		cwd: options.cwd ?? "/Users/fake/projects/demo",
		isIdle: () => options.idle ?? true,
		hasPendingMessages: () => options.pending ?? false,
		getContextUsage: () => ({ tokens: options.tokens ?? 12_345, contextWindow: 200_000, percent: 6 }),
		sessionManager: {
			getSessionFile: () => "/Users/fake/.pi/agent/sessions/--demo--/session.jsonl",
			getSessionId: () => "session-abc",
			getSessionName: () => "demo session",
		},
		ui: { notify: (message: string) => notifications.push(message) },
	};
}

interface LoadedExtension {
	pi: StubPi;
	registryFile: string;
	directory: string;
	cleanup: () => void;
}

async function loadExtension(name: string, env: Record<string, string> = {}): Promise<LoadedExtension> {
	const directory = mkdtempSync(path.join(tmpdir(), `pmb-ext-${name}-`));
	for (const [key, value] of Object.entries(env)) process.env[key] = value;
	process.env.PI_MENUBAR_REGISTRY_DIR = directory;

	// Fresh import per test: the factory reads config when it is called.
	const module = await import(`./index.ts?${name}-${Date.now()}`);
	const pi = stubPi();
	module.default(pi as any);
	return {
		pi,
		directory,
		registryFile: path.join(directory, `${process.pid}.json`),
		cleanup: () => {
			rmSync(directory, { recursive: true, force: true });
			delete process.env.PI_MENUBAR_REGISTRY_DIR;
			delete process.env.PI_MENUBAR_ENABLED;
		},
	};
}

function readRegistry(file: string): any {
	return JSON.parse(readFileSync(file, "utf8"));
}

test("publishes a v1 registry file through a full session lifecycle", async () => {
	const loaded = await loadExtension("lifecycle");
	try {
		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext({ idle: true }));
		assert.ok(existsSync(loaded.registryFile), "session_start must publish immediately");

		const initial = readRegistry(loaded.registryFile);
		assert.equal(initial.v, 1);
		assert.equal(initial.state, "idle");
		assert.equal(initial.pid, process.pid);
		assert.equal(initial.mode, "tui");
		assert.equal(initial.sessionFile, "/Users/fake/.pi/agent/sessions/--demo--/session.jsonl");
		assert.equal(initial.sessionName, "demo session");
		assert.equal(initial.contextTokens, 12_345);
		assert.ok(initial.processStartedAt > 0 && initial.processStartedAt <= Date.now());

		// Permissions: the payload can contain prompts once opted in.
		assert.equal(statSync(loaded.registryFile).mode & 0o777, 0o600);
		assert.equal(statSync(loaded.directory).mode & 0o777, 0o700);

		await loaded.pi.fire("before_agent_start", { prompt: "do the thing" }, stubContext({ idle: false, pending: true }));
		await loaded.pi.fire("agent_start", {}, stubContext({ idle: false }));
		const working = readRegistry(loaded.registryFile);
		assert.equal(working.state, "working");
		assert.equal(working.hasPendingMessages, true);
		assert.equal(working.lastUserPrompt, null, "prompt previews stay off by default");
		assert.ok(working.revision > initial.revision, "revision must move forward");

		await loaded.pi.fire("tool_execution_start", { toolCallId: "c1", toolName: "bash" }, stubContext({ idle: false }));
		assert.deepEqual(readRegistry(loaded.registryFile).activeTools.map((tool: any) => tool.name), ["bash"]);

		await loaded.pi.fire("tool_execution_end", { toolCallId: "c1", toolName: "bash" }, stubContext({ idle: false }));
		const afterTool = readRegistry(loaded.registryFile);
		assert.deepEqual(afterTool.activeTools, []);
		assert.equal(afterTool.lastTool, "bash");

		await loaded.pi.fire("ui_prompt_start", { kind: "confirm", title: "Approve or reject\nBash command" }, stubContext({ idle: false }));
		const blocked = readRegistry(loaded.registryFile);
		assert.equal(blocked.state, "blocked");
		assert.equal(blocked.blockedKind, "confirm");
		assert.equal(blocked.stateLabel, "Approve or reject");
		assert.ok(blocked.waitingSince > 0);

		await loaded.pi.fire("ui_prompt_end", { kind: "confirm" }, stubContext({ idle: false }));
		assert.equal(readRegistry(loaded.registryFile).state, "working");

		await loaded.pi.fire("agent_settled", {}, stubContext({ idle: true }));
		const settled = readRegistry(loaded.registryFile);
		assert.equal(settled.state, "idle");
		assert.ok(settled.settledAt > 0, "completion time drives acknowledgement in the app");

		// Quitting does remove it: the session is over.
		await loaded.pi.fire("session_shutdown", { reason: "quit" }, stubContext());
		assert.equal(existsSync(loaded.registryFile), false, "shutdown removes the file");
	} finally {
		loaded.cleanup();
	}
});

test("a reload replaces the previous publisher without leaving stale state", async () => {
	const loaded = await loadExtension("reload");
	try {
		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext({ idle: true }));
		const before = readRegistry(loaded.registryFile);

		// A reload fires session_shutdown then session_start with the agent mid-run. The
		// file survives the gap so the row does not flicker and the revision can continue.
		await loaded.pi.fire("session_shutdown", { reason: "reload" }, stubContext());
		assert.equal(existsSync(loaded.registryFile), true, "a replacement keeps the row");
		await loaded.pi.fire("session_start", { reason: "reload" }, stubContext({ idle: false }));

		const after = readRegistry(loaded.registryFile);
		assert.equal(after.state, "working", "a mid-run reload must not report idle");
		assert.ok(after.revision > before.revision, `revision ${after.revision} must exceed ${before.revision}`);
		assert.equal(after.settledAt, null);

		await loaded.pi.fire("session_shutdown", { reason: "quit" }, stubContext());
	} finally {
		loaded.cleanup();
	}
});

test("headless modes do not publish by default and clean up after themselves", async () => {
	const loaded = await loadExtension("headless");
	try {
		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext({ mode: "print" }));
		assert.equal(existsSync(loaded.registryFile), false, "print mode is excluded by default");
	} finally {
		loaded.cleanup();
	}
});

test("a session that is not included removes any leftover file", async () => {
	const loaded = await loadExtension("leftover");
	try {
		// Simulate a previous run of this pid having published a row.
		writeFileSync(loaded.registryFile, JSON.stringify({ v: 1, revision: 1, pid: process.pid }), { mode: 0o600 });
		assert.ok(existsSync(loaded.registryFile));
		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext({ mode: "json" }));
		assert.equal(existsSync(loaded.registryFile), false, "an excluded session must not leave a ghost row");
	} finally {
		loaded.cleanup();
	}
});

test("PI_MENUBAR_ENABLED=0 disables publishing entirely", async () => {
	const loaded = await loadExtension("disabled", { PI_MENUBAR_ENABLED: "0" });
	try {
		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext());
		assert.equal(existsSync(loaded.registryFile), false);
	} finally {
		loaded.cleanup();
	}
});

test("/menubar commands report state, simulate with expiry, and never throw", async () => {
	const loaded = await loadExtension("commands");
	try {
		const command = loaded.pi.commands.get("menubar");
		assert.ok(command, "the /menubar command must be registered");

		await loaded.pi.fire("session_start", { reason: "startup" }, stubContext({ idle: true }));
		const ctx = stubContext({ idle: false });
		await loaded.pi.fire("agent_start", {}, ctx);

		await command!.handler("status", ctx);
		assert.ok(ctx.notifications.at(-1)?.includes("publishing:   yes"), ctx.notifications.at(-1));

		await command!.handler("dump", ctx);
		assert.ok(ctx.notifications.at(-1)?.startsWith("{"), "dump prints JSON");

		await command!.handler("doctor", ctx);
		assert.ok(ctx.notifications.at(-1)?.includes("registry file:"), ctx.notifications.at(-1));

		await command!.handler("simulate blocked 1", ctx);
		const simulated = readRegistry(loaded.registryFile);
		assert.equal(simulated.state, "blocked");
		assert.equal(simulated.simulated, true);
		assert.ok(simulated.expiresAt > Date.now());

		await command!.handler("bogus-subcommand", ctx);
		assert.ok(ctx.notifications.at(-1)?.includes("publishing:"), "unknown subcommands fall back to status");

		await command!.handler("simulate nonsense 1", ctx);
		assert.ok(ctx.notifications.at(-1)?.includes("Unknown state"), ctx.notifications.at(-1));

		// Returns to the live state once the override expires; polling keeps the test fast
		// because expiry is evaluated per snapshot rather than by a timer.
		const deadline = Date.now() + 3_000;
		let state = simulated.state;
		while (Date.now() < deadline) {
			await new Promise((resolve) => setTimeout(resolve, 200));
			state = readRegistry(loaded.registryFile).state;
			if (state === "working") break;
		}
		assert.equal(state, "working", "the simulation must expire back to the live state");

		await loaded.pi.fire("session_shutdown", { reason: "quit" }, ctx);
	} finally {
		loaded.cleanup();
	}
});
