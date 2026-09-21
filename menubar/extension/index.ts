/**
 * PiMenuBar registry publisher — the pi side of the menu bar status bar.
 *
 * Keeps one private, atomically-written JSON file per pi process in
 * `~/.pi/agent/menubar/sessions/<pid>.json`. The menu bar app reads those files for
 * detail herdr does not have (model, tools, context, session name) and as its only
 * source for pi running outside herdr.
 *
 * Invariants worth keeping:
 *  - the registry has no "unseen" flag; acknowledgement belongs to the app, otherwise a
 *    heartbeat would resurrect a badge the user just cleared;
 *  - every publish is a full snapshot with a monotonic revision, so a reload cannot
 *    publish stale ordering and a reader never needs to merge deltas;
 *  - this extension never calls `pane.report_agent`: herdr's own managed `pi` integration
 *    (`~/.pi/agent/extensions/herdr-agent-state.ts`) owns that, and two reporters with
 *    independent sequence numbers would fight.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import {
	createRevisionSourceFrom,
	DEFAULT_CONFIG,
	type AgentState,
	type MenuBarExtensionConfig,
	type RegistryState,
	resolveRegistryDir,
	registryFileName,
	shouldPublish,
	StatusTracker,
	coerceConfig,
} from "./state.ts";

const CONFIG_PATH = path.join(homedir(), ".pi", "agent", "menubar.json");

function loadConfig(): MenuBarExtensionConfig {
	let config = { ...DEFAULT_CONFIG };
	try {
		if (existsSync(CONFIG_PATH)) {
			config = coerceConfig(JSON.parse(readFileSync(CONFIG_PATH, "utf8")));
		}
	} catch {
		// Malformed config keeps the defaults; a broken file must not disable publishing.
	}
	// PI_MENUBAR_ENABLED=0 is the escape hatch for a single session.
	const enabledOverride = process.env.PI_MENUBAR_ENABLED;
	if (enabledOverride !== undefined && enabledOverride !== "") {
		config.enabled = /^(1|true|yes|on)$/i.test(enabledOverride);
	}
	const dirOverride = process.env.PI_MENUBAR_REGISTRY_DIR;
	if (dirOverride) config.registryDir = dirOverride;
	return config;
}

/**
 * Revision of the file this process previously published.
 *
 * A reload keeps the same pid and file, so continuing from the on-disk revision is what
 * keeps ordering monotonic even when the clock has not advanced a millisecond.
 */
function previousRevision(file: string): number {
	try {
		const parsed = JSON.parse(readFileSync(file, "utf8")) as { revision?: unknown };
		return typeof parsed.revision === "number" && Number.isFinite(parsed.revision) ? parsed.revision : 0;
	} catch {
		return 0;
	}
}

function herdrIdentity(): RegistryState["herdr"] | undefined {
	if (process.env.HERDR_ENV !== "1" || !process.env.HERDR_PANE_ID) return undefined;
	return {
		paneId: process.env.HERDR_PANE_ID,
		workspaceId: process.env.HERDR_WORKSPACE_ID,
		tabId: process.env.HERDR_TAB_ID,
		socketPath: process.env.HERDR_SOCKET_PATH,
	};
}

export default function (pi: ExtensionAPI) {
	const config = loadConfig();
	const registryDir = resolveRegistryDir(config, homedir());
	const file = path.join(registryDir, registryFileName(process.pid));

	const clock = {
		now: () => Date.now(),
		processStartedAt: Date.now() - Math.round(process.uptime() * 1000),
		pid: process.pid,
	};

	let tracker: StatusTracker | null = null;
	let heartbeat: ReturnType<typeof setInterval> | undefined;
	let simulationTimer: ReturnType<typeof setTimeout> | undefined;
	let lastWritten = "";

	function ensureDirectory(): void {
		mkdirSync(registryDir, { recursive: true, mode: 0o700 });
	}

	/**
	 * Synchronous write + rename: the payload is small, and synchronous ordering means a
	 * burst of events can never publish out of order. Readers only ever see a complete
	 * document because rename is atomic.
	 */
	function publish(options: { force?: boolean } = {}): RegistryState | undefined {
		if (!tracker) return undefined;
		const state = tracker.snapshot();
		const serialized = JSON.stringify(state);
		if (!options.force && serialized === lastWritten) return state;
		try {
			ensureDirectory();
			const temporary = `${file}.tmp.${process.pid}`;
			writeFileSync(temporary, serialized, { mode: 0o600 });
			renameSync(temporary, file);
			lastWritten = serialized;
		} catch (error) {
			process.stderr.write(`[pimenubar] could not publish registry state: ${String(error)}\n`);
		}
		return state;
	}

	function stopHeartbeat(): void {
		if (heartbeat) clearInterval(heartbeat);
		heartbeat = undefined;
	}

	function startHeartbeat(): void {
		stopHeartbeat();
		heartbeat = setInterval(() => publish(), config.heartbeatMs);
		// Never keep pi alive just to publish.
		(heartbeat as unknown as { unref?: () => void }).unref?.();
	}

	function clearFile(): void {
		try {
			rmSync(file, { force: true });
		} catch {
			// Best effort: the app also ages out stale files.
		}
	}

	function disabled(): boolean {
		return !config.enabled;
	}

	pi.on("session_start", (event, ctx) => {
		if (disabled()) return;
		// The app's liveness rule keys off this file, so start from a clean slate: a
		// reload or session replacement must not leave two publishers behind.
		stopHeartbeat();
		if (simulationTimer) clearTimeout(simulationTimer);
		simulationTimer = undefined;

		const mode = ctx.mode ?? "tui";
		if (!shouldPublish(config, mode)) {
			clearFile();
			tracker = null;
			return;
		}

		let sessionFile: string | undefined;
		let sessionId: string | undefined;
		let sessionName: string | undefined;
		try {
			const value = ctx.sessionManager?.getSessionFile?.();
			if (typeof value === "string" && value.startsWith("/")) sessionFile = value;
			sessionId = ctx.sessionManager?.getSessionId?.();
			sessionName = ctx.sessionManager?.getSessionName?.();
		} catch {
			// A missing session manager is not fatal: cwd still identifies the row.
		}

		tracker = new StatusTracker({
			clock,
			nextRevision: createRevisionSourceFrom(Date.now(), previousRevision(file)),
			includePromptPreview: config.includePromptPreview,
			terminalBundleId: process.env.__CFBundleIdentifier,
			herdr: herdrIdentity(),
			identity: { sessionId, sessionFile, sessionName, cwd: ctx.cwd ?? process.cwd(), mode },
		});
		// On /reload the agent may already be mid-run.
		tracker.onSessionStart(tracker.identity, ctx.isIdle?.() === false);
		tracker.onUsage(ctx.getContextUsage?.()?.tokens ?? null, ctx.getContextUsage?.()?.contextWindow ?? null);
		publish({ force: true });
		startHeartbeat();
		void event;
	});

	pi.on("session_info_changed", (event) => {
		tracker?.onSessionName(event.name);
		publish();
	});

	pi.on("agent_start", () => {
		if (!tracker) return;
		tracker.onAgentStart();
		publish();
	});

	pi.on("before_agent_start", (event, ctx) => {
		if (!tracker) return;
		tracker.onUserPrompt(event.prompt);
		tracker.onPendingMessages(ctx.hasPendingMessages?.() === true);
		publish();
	});

	pi.on("ui_prompt_start", (event) => {
		if (!tracker) return;
		tracker.onPromptStart(event.kind ?? "custom", event.title);
		publish();
	});

	pi.on("ui_prompt_end", () => {
		if (!tracker) return;
		tracker.onPromptEnd();
		publish();
	});

	pi.on("tool_execution_start", (event) => {
		if (!tracker) return;
		tracker.onToolStart(event.toolCallId, event.toolName);
		publish();
	});

	pi.on("tool_execution_end", (event) => {
		if (!tracker) return;
		tracker.onToolEnd(event.toolCallId, event.toolName);
		publish();
	});

	pi.on("turn_start", (event) => {
		if (!tracker) return;
		tracker.onTurn(event.turnIndex ?? 0);
		publish();
	});

	pi.on("turn_end", (event, ctx) => {
		if (!tracker) return;
		tracker.onTurn(event.turnIndex ?? 0);
		tracker.onPendingMessages(ctx.hasPendingMessages?.() === true);
		publish();
	});

	pi.on("message_end", (_event, ctx) => {
		if (!tracker) return;
		const usage = ctx.getContextUsage?.();
		if (usage) tracker.onUsage(usage.tokens ?? null, usage.contextWindow ?? null);
		publish();
	});

	pi.on("model_select", (event, ctx) => {
		if (!tracker) return;
		tracker.onModel(event.model?.id, event.model?.provider, ctx.thinkingLevel);
		publish();
	});

	pi.on("thinking_level_select", (event) => {
		if (!tracker) return;
		tracker.onModel(undefined, undefined, event.level);
		publish();
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (!tracker) return;
		if (ctx.isIdle?.() === true) tracker.onSettled();
		const usage = ctx.getContextUsage?.();
		if (usage) tracker.onUsage(usage.tokens ?? null, usage.contextWindow ?? null);
		tracker.onPendingMessages(ctx.hasPendingMessages?.() === true);
		publish();
	});

	pi.on("session_shutdown", (event) => {
		stopHeartbeat();
		if (simulationTimer) clearTimeout(simulationTimer);
		simulationTimer = undefined;
		tracker = null;
		// A replacement (reload/new/resume/fork) is immediately followed by another
		// session_start in the same process, which rewrites this same file: keeping it
		// avoids a flickering row and preserves the revision to seed ordering from.
		// Only a real quit, or an excluded mode, removes the row.
		if (event.reason === "quit") clearFile();
	});

	pi.registerCommand("menubar", {
		description: "PiMenuBar: status | dump | simulate <state> [seconds] | clear | doctor",
		handler: async (args: string, ctx: ExtensionCommandContext) => {
			const [sub = "status", ...rest] = args.trim().split(/\s+/).filter(Boolean);

			if (sub === "simulate") {
				if (!tracker) {
					ctx.ui.notify("This session is not publishing (see /menubar status).", "warning");
					return;
				}
				const state = (rest[0] ?? "working") as AgentState;
				if (!["idle", "working", "blocked"].includes(state)) {
					ctx.ui.notify(`Unknown state "${state}". Use idle | working | blocked.`, "warning");
					return;
				}
				const seconds = Number.parseFloat(rest[1] ?? "15");
				const until = tracker.simulate(state, Number.isFinite(seconds) ? seconds : 15);
				publish({ force: true });
				if (simulationTimer) clearTimeout(simulationTimer);
				simulationTimer = setTimeout(() => {
					simulationTimer = undefined;
					tracker?.clearSimulation();
					publish({ force: true });
				}, Math.max(1, seconds) * 1000);
				(simulationTimer as unknown as { unref?: () => void }).unref?.();
				ctx.ui.notify(
					`Simulating "${state}" for ${Math.round((until - Date.now()) / 1000)}s. Real events keep updating underneath.`,
					"info",
				);
				return;
			}

			if (sub === "clear") {
				if (tracker) {
					tracker.clearSimulation();
					publish({ force: true });
					ctx.ui.notify(`Simulation cleared and live state republished to ${file}.`, "info");
					return;
				}
				clearFile();
				ctx.ui.notify(`Removed ${file}; this session will republish on its next event.`, "info");
				return;
			}

			if (sub === "dump") {
				try {
					ctx.ui.notify(readFileSync(file, "utf8"), "info");
				} catch {
					ctx.ui.notify(`No registry file at ${file}.`, "warning");
				}
				return;
			}

			if (sub === "doctor") {
				const lines = [
					`config:            ${existsSync(CONFIG_PATH) ? CONFIG_PATH : `${CONFIG_PATH} (absent, defaults)`}`,
					`registry dir:      ${registryDir}`,
					`registry file:     ${file} ${existsSync(file) ? "(present)" : "(absent)"}`,
					`publishing:        ${tracker ? "yes" : "no"}`,
					`includePromptPreview: ${config.includePromptPreview}`,
					`heartbeat:         ${config.heartbeatMs}ms, stale after ${config.staleAfterMs}ms`,
					`herdr env:         ${process.env.HERDR_ENV === "1" ? `pane ${process.env.HERDR_PANE_ID ?? "?"}` : "not inside herdr"}`,
					`herdr socket:      ${process.env.HERDR_SOCKET_PATH ?? "(not set; app will use registry/default)"}`,
					"app:               launch with `make run` in menubar/, or check for π in the menu bar",
				];
				ctx.ui.notify(lines.join("\n"), "info");
				return;
			}

			const state = tracker?.snapshot();
			const lines = [
				`publishing:   ${tracker ? "yes" : "no"}`,
				`mode:         ${ctx.mode} (includedModes: ${config.includedModes.join(",")})`,
				`registry:     ${file}`,
				`config:       ${CONFIG_PATH}`,
			];
			if (state) {
				lines.push(
					`state:        ${state.state}${state.simulated ? " (simulated)" : ""} rev ${state.revision}`,
					`project:      ${state.project} (${state.cwd})`,
					`session:      ${state.sessionId ?? "?"} ${state.sessionName ? `"${state.sessionName}"` : ""}`,
					`model:        ${state.model ?? "?"}${state.thinking ? ` (${state.thinking})` : ""}`,
					`context:      ${state.contextTokens ?? "?"}/${state.contextWindow ?? "?"}`,
					`tools:        ${state.activeTools.map((tool) => tool.name).join(", ") || "none"} (last: ${state.lastTool ?? "-"})`,
					`run:          ${state.runStartedAt ? `${Math.round((Date.now() - state.runStartedAt) / 1000)}s` : "-"}  waiting: ${state.waitingSince ? `${Math.round((Date.now() - state.waitingSince) / 1000)}s` : "-"}`,
					`herdr:        ${state.herdr?.paneId ?? "(not inside herdr)"}`,
				);
			}
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
