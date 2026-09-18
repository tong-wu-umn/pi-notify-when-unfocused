/**
 * Notify When Unfocused — pi extension
 *
 * Shows a macOS notification when pi is blocked waiting on YOU but the terminal
 * window/pane is not the active one (so you can walk away and still be told).
 *
 * Two triggers:
 *   1. `ui_prompt_start` — a blocking dialog is on screen (approve/reject, select,
 *      input, editor, custom). Covers pi-permission-system approvals.
 *   2. `agent_settled`   — the run finished and pi is idle waiting for your next
 *      message (opt-out via `notifyOnIdle: false`).
 *
 * Focus detection (macOS + Ghostty):
 *   - tier 1: `lsappinfo` asks which app is frontmost (no permissions needed).
 *   - tier 2: AppleScript asks Ghostty which terminal of the front window has focus,
 *     then matches its working directory + title against this pi session. This is
 *     what makes multi-window/multi-tab panes work: if you are looking at a
 *     *different* Ghostty pane, you still get notified.
 *   Any uncertainty fails open (assume focused, i.e. stay quiet).
 *
 * Delivery: OSC 777 (Ghostty/iTerm2) → OSC 9 → `osascript display notification`
 * → terminal bell. OSC notifications are attributed to Ghostty itself, so make
 * sure macOS notifications are allowed for Ghostty once.
 *
 * Gotchas (verified on Ghostty 1.3.1 + macOS 26):
 *   - macOS shows no banner when the notification's app (Ghostty) is itself the
 *     frontmost app, and Ghostty additionally clears its delivered notifications
 *     the moment it becomes active. A test run while you are staring at the
 *     terminal therefore shows nothing by design — use `/nudge test 5` and switch
 *     to another app to see the real thing.
 *   - Ghostty rate-limits notifications and suppresses identical repeats, so a
 *     burst of the same message may collapse into one.
 *
 * Config (all optional) — `~/.pi/agent/notify-when-unfocused.json`:
 *   {
 *     "enabled": true,
 *     "notifyOnPrompts": true,      // blocking dialogs
 *     "notifyOnIdle": true,         // agent finished, waiting for your message
 *     "idleMinRunMs": 15000,        // don't notify for quick replies
 *     "reminders": 2,               // extra nudges while still waiting
 *     "reminderIntervalMs": 20000,
 *     "dedupeMs": 10000,            // suppress near-duplicate notifications
 *     "terminalApps": ["Ghostty"],  // frontmost app names that count as "the terminal"
 *     "titleMarkers": ["π", "pi"],  // markers pi puts in its own terminal title
 *     "preciseFocus": true,         // tier-2 "which Ghostty pane is focused" check
 *     "transport": "auto",          // auto | osc777 | osc9 | osascript | bell | none
 *     "bell": false                 // also ring the terminal bell
 *   }
 * Env overrides: PI_NUDGE_<KEY> (e.g. PI_NUDGE_ENABLED=0, PI_NUDGE_TRANSPORT=osascript).
 * Debug: PI_NUDGE_FORCE_UNFOCUSED=1 pretends the terminal is always in the background.
 *
 * Commands: `/nudge status`, `/nudge focus`, `/nudge test`, `/nudge simulate`.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

// ─────────────────────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────────────────────

export interface NudgeConfig {
	enabled: boolean;
	notifyOnPrompts: boolean;
	notifyOnIdle: boolean;
	idleMinRunMs: number;
	reminders: number;
	reminderIntervalMs: number;
	dedupeMs: number;
	terminalApps: string[];
	titleMarkers: string[];
	preciseFocus: boolean;
	transport: "auto" | "osc777" | "osc9" | "osascript" | "bell" | "none";
	bell: boolean;
}

const DEFAULTS: NudgeConfig = {
	enabled: true,
	notifyOnPrompts: true,
	notifyOnIdle: true,
	idleMinRunMs: 15_000,
	reminders: 2,
	reminderIntervalMs: 20_000,
	dedupeMs: 10_000,
	terminalApps: ["Ghostty"],
	titleMarkers: ["π", "pi"],
	preciseFocus: true,
	transport: "auto",
	bell: false,
};

const CONFIG_PATH = path.join(homedir(), ".pi", "agent", "notify-when-unfocused.json");

function envKey(key: string): string {
	return `PI_NUDGE_${key.replace(/[A-Z]/g, (c) => `_${c}`).toUpperCase()}`;
}

function coerce(value: unknown, fallback: NudgeConfig[keyof NudgeConfig]): unknown {
	if (typeof fallback === "boolean") {
		if (typeof value === "boolean") return value;
		return /^(1|true|yes|on)$/i.test(String(value));
	}
	if (typeof fallback === "number") {
		const n = Number(value);
		return Number.isFinite(n) ? n : fallback;
	}
	if (Array.isArray(fallback)) {
		if (Array.isArray(value)) return value.map((v) => String(v));
		return String(value)
			.split(",")
			.map((v) => v.trim())
			.filter(Boolean);
	}
	return String(value);
}

export function loadConfig(): NudgeConfig {
	const cfg: NudgeConfig = { ...DEFAULTS };
	try {
		if (existsSync(CONFIG_PATH)) {
			const raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Record<string, unknown>;
			for (const key of Object.keys(DEFAULTS) as (keyof NudgeConfig)[]) {
				if (raw[key] !== undefined) {
					(cfg as Record<string, unknown>)[key] = coerce(raw[key], DEFAULTS[key]);
				}
			}
		}
	} catch {
		// Malformed config: keep defaults rather than breaking startup.
	}
	for (const key of Object.keys(DEFAULTS) as (keyof NudgeConfig)[]) {
		const raw = process.env[envKey(key)];
		if (raw !== undefined && raw !== "") {
			(cfg as Record<string, unknown>)[key] = coerce(raw, DEFAULTS[key]);
		}
	}
	return cfg;
}

// ─────────────────────────────────────────────────────────────────────────────
// Focus detection
// ─────────────────────────────────────────────────────────────────────────────

export interface FocusState {
	/** True when this pi session's terminal pane is what the user is looking at. */
	focused: boolean;
	/** Human-readable explanation, surfaced by `/nudge focus`. */
	reason: string;
}

const US = String.fromCharCode(31); // unit separator, survives osascript round-trips

const GHOSTTY_FOCUSED_TERMINAL = [
	'tell application "Ghostty"',
	"  set t to focused terminal of selected tab of front window",
	`  return (name of t) & (character id 31) & (working directory of t)`,
	"end tell",
].join("\n");

function run(cmd: string, args: string[], timeoutMs = 2500): Promise<{ ok: boolean; stdout: string }> {
	return new Promise((resolve) => {
		try {
			execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 1 << 20 }, (error, stdout) => {
				resolve({ ok: !error, stdout: typeof stdout === "string" ? stdout : String(stdout ?? "") });
			});
		} catch {
			resolve({ ok: false, stdout: "" });
		}
	});
}

/** Frontmost macOS app name via lsappinfo — no Automation permission required. */
async function frontmostApp(): Promise<string | undefined> {
	const front = await run("lsappinfo", ["front"], 1500);
	if (!front.ok) return undefined;
	const asn = front.stdout.trim().replace(/:$/, "");
	if (!asn) return undefined;
	const info = await run("lsappinfo", ["info", "-only", "name", asn], 1500);
	if (!info.ok) return undefined;
	return info.stdout.match(/"LSDisplayName"="([^"]*)"/)?.[1];
}

function samePath(a: string, b: string): boolean {
	const norm = (p: string) => p.trim().replace(/\/+$/, "");
	return norm(a).length > 0 && norm(a) === norm(b);
}

/**
 * Decide whether the user is currently looking at *this* pi session.
 * Fails open (returns focused) whenever the answer cannot be determined.
 */
export async function checkFocus(cfg: NudgeConfig, cwd: string = process.cwd()): Promise<FocusState> {
	if (process.env.PI_NUDGE_FORCE_UNFOCUSED === "1") {
		return { focused: false, reason: "forced unfocused (PI_NUDGE_FORCE_UNFOCUSED=1)" };
	}
	if (process.platform !== "darwin") {
		return { focused: true, reason: `no focus detection on ${process.platform}` };
	}

	const front = await frontmostApp();
	if (front === undefined) {
		return { focused: true, reason: "could not determine frontmost app (assuming focused)" };
	}
	if (!cfg.terminalApps.some((app) => app.toLowerCase() === front.toLowerCase())) {
		return { focused: false, reason: `frontmost app is ${front}` };
	}
	if (!cfg.preciseFocus) {
		return { focused: true, reason: `${front} is frontmost` };
	}

	const res = await run("osascript", ["-e", GHOSTTY_FOCUSED_TERMINAL], 3000);
	if (!res.ok) {
		return { focused: true, reason: `${front} is frontmost (AppleScript unavailable)` };
	}
	const [name = "", termCwd = ""] = res.stdout.replace(/\n+$/, "").split(US);
	const isPiTitle = cfg.titleMarkers.some((marker) => name.includes(marker));
	if (samePath(termCwd, cwd) && isPiTitle) {
		return { focused: true, reason: `focused ${front} pane is this session ("${name.trim()}")` };
	}
	const shown = name.trim() || "(untitled)";
	return {
		focused: false,
		reason: `focused ${front} pane is "${shown}" in ${termCwd.trim() || "?"}`,
	};
}

// ─────────────────────────────────────────────────────────────────────────────
// Notification delivery
// ─────────────────────────────────────────────────────────────────────────────

function sanitize(text: string, max: number): string {
	return text
		.replace(/[\u0000-\u001f\u007f]/g, " ") // never let a caller inject control sequences
		.replace(/;/g, ":") // ';' is the field separator in OSC 777
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, max);
}

function appleScriptString(text: string): string {
	return `"${text.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function writeToTerminal(sequence: string): void {
	try {
		process.stdout.write(sequence);
	} catch {
		// stdout closed (shutdown in progress) — nothing useful to do.
	}
}

export type Transport = NudgeConfig["transport"] | "osc777" | "osc9" | "osascript" | "bell" | "none";

function resolveTransport(cfg: NudgeConfig): Exclude<NudgeConfig["transport"], "auto"> {
	if (cfg.transport !== "auto") return cfg.transport;
	if (process.env.TERM_PROGRAM === "ghostty") return "osc777";
	if (process.platform === "darwin") return "osascript";
	return "osc9";
}

/** Fire a desktop notification. Returns the transport actually used. */
export function sendNotification(cfg: NudgeConfig, title: string, body: string): string {
	const t = sanitize(title, 90) || "pi";
	const b = sanitize(body, 220);
	const transport = resolveTransport(cfg);

	switch (transport) {
		case "osc777":
			writeToTerminal(`\u001b]777;notify;${t};${b}\u0007`);
			break;
		case "osc9":
			// OSC 9 carries a single string; Ghostty uses it as the title.
			writeToTerminal(`\u001b]9;${t}${b ? ` — ${b}` : ""}\u0007`);
			break;
		case "osascript":
			// Fire-and-forget: notifications must not delay the prompt.
			try {
				execFile("osascript", [
					"-e",
					`display notification ${appleScriptString(b)} with title ${appleScriptString(t)}`,
				]);
			} catch {
				/* ignore */
			}
			break;
		case "bell":
		case "none":
			break;
	}

	if (cfg.bell && transport !== "bell") writeToTerminal("\u0007");
	return transport;
}

// ─────────────────────────────────────────────────────────────────────────────
// Extension
// ─────────────────────────────────────────────────────────────────────────────

const PROMPT_LABELS: Record<string, string> = {
	select: "Select an option",
	confirm: "Approve or reject",
	input: "Type a value",
	editor: "Edit text",
	custom: "Respond in pi",
};

interface WaitingSpan {
	id: number;
	title: string;
	body: string;
	remindersLeft: number;
	timer?: ReturnType<typeof setTimeout>;
}

export default function (pi: ExtensionAPI) {
	const cfg = loadConfig();
	if (!cfg.enabled) return;

	let span: WaitingSpan | undefined;
	let spanCounter = 0;
	let lastNotifiedAt = 0;
	let runStartedAt = 0;
	// Used to ignore any settle event that arrives while pi is still starting up.
	const loadedAt = Date.now();

	function endSpan(): void {
		if (span?.timer) clearTimeout(span.timer);
		span = undefined;
	}

	async function nudge(current: WaitingSpan, isReminder: boolean): Promise<void> {
		const focus = await checkFocus(cfg);
		if (span?.id !== current.id || focus.focused) return;

		const now = Date.now();
		if (!isReminder && now - lastNotifiedAt < cfg.dedupeMs) return; // e.g. prompt right after an idle nudge
		lastNotifiedAt = now;

		const body = isReminder ? `${current.body} (still waiting)` : current.body;
		const transport = sendNotification(cfg, current.title, body);
		if (process.env.PI_NUDGE_DEBUG === "1") {
			process.stderr.write(`[notify-when-unfocused] ${transport}: ${current.title} — ${body} (${focus.reason})\n`);
		}
	}

	function scheduleReminder(current: WaitingSpan): void {
		if (current.remindersLeft <= 0) return;
		current.timer = setTimeout(() => {
			current.timer = undefined;
			if (span?.id !== current.id) return;
			void (async () => {
				await nudge(current, true);
				if (span?.id === current.id) {
					current.remindersLeft -= 1;
					scheduleReminder(current);
				}
			})();
		}, cfg.reminderIntervalMs);
		// Don't hold the process open just for a reminder.
		(current.timer as unknown as { unref?: () => void }).unref?.();
	}

	function beginSpan(title: string, body: string): void {
		endSpan();
		const current: WaitingSpan = {
			id: ++spanCounter,
			title,
			body,
			remindersLeft: Math.max(0, cfg.reminders),
		};
		span = current;
		void (async () => {
			await nudge(current, false);
			if (span?.id === current.id) scheduleReminder(current);
		})();
	}

	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		runStartedAt = 0;
		endSpan();
	});

	pi.on("agent_start", () => {
		runStartedAt = Date.now();
	});

	pi.on("ui_prompt_start", (event, ctx) => {
		// Headless modes (print/json/rpc) have no terminal to nudge.
		if (ctx.mode !== "tui" || !cfg.notifyOnPrompts) return;
		const label = PROMPT_LABELS[event.kind] ?? "Needs input";
		const firstLine = (event.title ?? "").split("\n").find((line) => line.trim().length > 0);
		const where = path.basename(process.cwd()) || process.cwd();
		beginSpan("π needs your input", `${label} in ${where}${firstLine ? ` — ${firstLine.trim()}` : ""}`);
	});

	pi.on("ui_prompt_end", () => {
		endSpan();
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (ctx.mode !== "tui" || !cfg.notifyOnIdle) return;
		if (Date.now() - loadedAt < 2_000) return;
		if (!ctx.isIdle()) return;
		const started = runStartedAt;
		runStartedAt = 0;
		// `started === 0` means no agent_start was seen in this process (e.g. the
		// extension was reloaded mid-run) — notify, but skip the duration filter.
		if (started !== 0 && Date.now() - started < cfg.idleMinRunMs) return;
		const where = path.basename(process.cwd()) || process.cwd();
		beginSpan("π is waiting for you", `Finished in ${where} — switch back to Ghostty`);
	});

	pi.registerCommand("nudge", {
		description: "Notify-when-unfocused: status | focus | test | simulate",
		handler: async (args: string, ctx: ExtensionCommandContext) => {
			const sub = args.trim().toLowerCase().split(/\s+/)[0] ?? "";
			if (sub === "test") {
				const seconds = Number.parseFloat(args.trim().split(/\s+/)[1] ?? "0");
				const delayMs = Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 120) * 1000 : 0;
				if (delayMs > 0) {
					// Delayed on purpose: macOS hides the banner while Ghostty is the
					// active app, so the useful test happens after you switch away.
					ctx.ui.notify(`Test notification in ${Math.round(delayMs / 1000)}s — switch to another app now.`, "info");
					const timer = setTimeout(() => {
						sendNotification(cfg, "π test notification", "Delayed test — you should be looking at another app now.");
					}, delayMs);
					(timer as unknown as { unref?: () => void }).unref?.();
					return;
				}
				const used = sendNotification(cfg, "π test notification", "Notifications are working.");
				ctx.ui.notify(
					`Sent via "${used}". If you saw nothing: macOS hides it while Ghostty is the active app — try "/nudge test 5" and switch away.`,
					"info",
				);
				return;
			}
			if (sub === "simulate") {
				// Exercises the whole chain: this dialog emits ui_prompt_start, which is
				// exactly what a permission approval does.
				await ctx.ui.confirm(
					"Nudge self-test",
					"If your terminal is in the background, a notification should appear now.",
				);
				return;
			}
			if (sub === "focus") {
				const focus = await checkFocus(cfg);
				ctx.ui.notify(`Focus: ${focus.focused ? "terminal active" : "terminal NOT active"} — ${focus.reason}`, "info");
				return;
			}
			const focus = await checkFocus(cfg);
			const lines = [
				`enabled=${cfg.enabled} prompts=${cfg.notifyOnPrompts} idle=${cfg.notifyOnIdle} transport=${resolveTransport(cfg)}`,
				`mode=${ctx.mode} preciseFocus=${cfg.preciseFocus} terminalApps=${cfg.terminalApps.join(",")}`,
				`reminders=${cfg.reminders}@${Math.round(cfg.reminderIntervalMs / 1000)}s idleMinRunMs=${cfg.idleMinRunMs}`,
				`focus: ${focus.focused ? "active" : "NOT active"} — ${focus.reason}`,
				`note: macOS hides banners while Ghostty is active; test with "/nudge test 5" + switch away`,
				`config file: ${existsSync(CONFIG_PATH) ? CONFIG_PATH : `${CONFIG_PATH} (not present, using defaults)`}`,
			];
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
