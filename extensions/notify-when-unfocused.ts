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
 * Focus detection (macOS):
 *   - inside herdr (`HERDR_ENV=1`): `herdr pane current` says whether this pane is
 *     the active pane of its session, and tier 1 `lsappinfo` says whether the
 *     terminal window is frontmost. herdr owns every pane pty and re-renders panes
 *     as cells through its client, so Ghostty's AppleScript cannot see herdr panes.
 *   - bare Ghostty: tier 1 `lsappinfo` asks which app is frontmost (no permissions
 *     needed); tier 2 AppleScript asks Ghostty which terminal of the front window
 *     has focus, then matches its working directory + title against this pi
 *     session. This is what makes multi-window/multi-tab panes work: if you are
 *     looking at a *different* Ghostty pane, you still get notified.
 *   Any uncertainty fails open (assume focused, i.e. stay quiet).
 *
 * Delivery: inside herdr → a desktop notification (`terminal-notifier`, else
 * `osascript`), or `herdr notification show` for a `terminal`-delivery popup that
 * has to reach the outer terminal. Outside herdr: OSC 777 (Ghostty/iTerm2) →
 * OSC 9 → desktop notifier → terminal bell. OSC notifications are attributed to
 * the terminal itself, so make sure macOS notifications are allowed for it once.
 *
 * Gotchas (verified on Ghostty 1.3.1 + macOS 26, herdr 0.9.1):
 *   - a herdr pane's OSC 777/9 and terminal bells are consumed by the herdr server
 *     and never reach Ghostty, which is why the herdr transport exists.
 *   - macOS shows no banner when a terminal-owned notification's app is itself the
 *     frontmost app, and Ghostty additionally clears its delivered notifications
 *     the moment it becomes active. A test run while you are staring at the
 *     terminal therefore shows nothing by design — use `/nudge test 5` and switch
 *     to another app to see the real thing.
 *   - Ghostty rate-limits notifications and suppresses identical repeats, so a
 *     burst of the same message may collapse into one.
 *   - herdr notifies for a *finished* pi agent itself (its pi integration reports
 *     the idle state) wherever `[ui.toast] delivery` points; when that banner is
 *     guaranteed to be visible this extension stays quiet instead of duplicating
 *     it. Prompt notifications are never covered by herdr.
 *
 * Config (all optional) — `~/.pi/agent/notify-when-unfocused.json`:
 *   {
 *     "enabled": true,
 *     "notifyOnPrompts": true,      // blocking dialogs
 *     "notifyOnIdle": true,         // agent finished, waiting for your message
 *     "idleMinRunMs": 15000,        // don't notify for quick replies
 *     "reminders": 2,               // extra nudges while a dialog stays open
 *     "reminderIntervalMs": 20000,
 *     "remindersOnIdle": false,     // also repeat the "finished" nudge
 *     "dedupeMs": 10000,            // suppress near-duplicate notifications
 *     "terminalApps": ["Ghostty"],  // frontmost app names that count as "the terminal"
 *                                 // (inside herdr, common host terminals and the
 *                                 // launching terminal's bundle id are also accepted)
 *     "titleMarkers": ["π", "pi"],  // markers pi puts in its own terminal title
 *     "preciseFocus": true,         // tier-2 "which Ghostty pane is focused" check
 *     "transport": "auto",          // auto | herdr | osc777 | osc9 | osascript | bell | none
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
	/** Also repeat the "finished, waiting for you" nudge. Off by default: a run
	 *  that finished needs one ping, not a countdown. */
	remindersOnIdle: boolean;
	dedupeMs: number;
	terminalApps: string[];
	titleMarkers: string[];
	preciseFocus: boolean;
	transport: "auto" | "herdr" | "osc777" | "osc9" | "osascript" | "bell" | "none";
	bell: boolean;
}

const DEFAULTS: NudgeConfig = {
	enabled: true,
	notifyOnPrompts: true,
	notifyOnIdle: true,
	idleMinRunMs: 15_000,
	reminders: 2,
	reminderIntervalMs: 20_000,
	remindersOnIdle: false,
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
	/** Present only when running inside herdr — used for `/nudge status` and to
	 *  avoid duplicating herdr's own agent notifications. */
	herdr?: HerdrFocus;
}

interface FrontmostApp {
	name?: string;
	bundleId?: string;
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

/** Frontmost macOS app via lsappinfo — no Automation permission required. */
async function frontmostApp(): Promise<FrontmostApp> {
	const front = await run("lsappinfo", ["front"], 1500);
	if (!front.ok) return {};
	const asn = front.stdout.trim().replace(/:$/, "");
	if (!asn) return {};
	const info = await run("lsappinfo", ["info", "-only", "name,bundleid", asn], 1500);
	if (!info.ok) return {};
	return {
		name: info.stdout.match(/"LSDisplayName"="([^"]*)"/)?.[1],
		bundleId: info.stdout.match(/"CFBundleIdentifier"="([^"]*)"/)?.[1],
	};
}

// ─────────────────────────────────────────────────────────────────────────────
// herdr integration
//
// Inside herdr (`HERDR_ENV=1`) the herdr server owns every pane pty and the
// attached client re-renders panes as a grid of cells, so OSC 777/9 written by a
// pane is consumed by herdr and never reaches Ghostty (bells are relayed, but a
// bell is not a notification). Notifications therefore go through herdr's own
// pipeline (`herdr notification show`, which honours `[ui.toast] delivery`), and
// pane-level focus comes from `herdr pane current` instead of Ghostty AppleScript.
// ─────────────────────────────────────────────────────────────────────────────

export type HerdrDelivery = "off" | "herdr" | "terminal" | "system";

export interface HerdrFocus {
	/** Public id of the pane this pi process runs in (e.g. `w1:p1`). */
	paneId?: string;
	/** Is this pane the active pane of its herdr session? undefined = unknown. */
	active?: boolean;
	/** Effective `[ui.toast] delivery` from herdr's config. */
	delivery: HerdrDelivery;
	/** The frontmost app is the terminal hosting the herdr client. */
	windowFront: boolean;
}

/** Terminal apps that may host a herdr client, on top of `cfg.terminalApps`. */
const HERDR_HOST_TERMINALS = [
	"Ghostty",
	"Terminal",
	"iTerm2",
	"WezTerm",
	"kitty",
	"Alacritty",
	"Warp",
	"Hyper",
	"Tabby",
	"Rio",
	"Code",
	"Cursor",
	"Windsurf",
	"Zed",
];

export function inHerdr(): boolean {
	return process.env.HERDR_ENV === "1";
}

function herdrBin(): string {
	return process.env.HERDR_BIN_PATH || "herdr";
}

function herdrConfigFile(): string {
	const fromEnv = process.env.HERDR_CONFIG_PATH;
	if (fromEnv && existsSync(fromEnv)) return fromEnv;
	return path.join(homedir(), ".config", "herdr", "config.toml");
}

/**
 * Effective `[ui.toast] delivery` from herdr's config, mirroring herdr's own
 * resolution: `delivery` wins over the legacy `enabled` key, and the default is
 * `off` (no popups at all).
 */
export function herdrDelivery(): HerdrDelivery {
	try {
		const text = readFileSync(herdrConfigFile(), "utf8");
		let section = "";
		let delivery: string | undefined;
		let legacyEnabled: string | undefined;
		for (const rawLine of text.split(/\r?\n/)) {
			const line = rawLine.replace(/#.*$/, "").trim();
			if (!line) continue;
			const header = line.match(/^\[([^\]]+)\]$/);
			if (header) {
				section = header[1].trim();
				continue;
			}
			if (section !== "ui.toast") continue;
			const entry = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
			if (!entry) continue;
			const value = entry[2].trim().replace(/^["']|["']$/g, "").toLowerCase();
			if (entry[1] === "delivery") delivery = value;
			if (entry[1] === "enabled") legacyEnabled = value;
		}
		if (delivery === "off" || delivery === "herdr" || delivery === "terminal" || delivery === "system") {
			return delivery;
		}
		if (legacyEnabled !== undefined) return /^(1|true|yes|on)$/.test(legacyEnabled) ? "herdr" : "off";
	} catch {
		// No config file / unreadable: herdr's default is "off".
	}
	return "off";
}

async function herdrPane(): Promise<{ paneId?: string; active?: boolean } | undefined> {
	const res = await run(herdrBin(), ["pane", "current"], 2500);
	if (!res.ok) return undefined;
	try {
		const parsed = JSON.parse(res.stdout) as {
			result?: { pane?: { pane_id?: string; focused?: boolean } };
		};
		const pane = parsed.result?.pane;
		if (!pane) return undefined;
		const expected = process.env.HERDR_PANE_ID;
		// The CLI honours HERDR_PANE_ID, but if it ever resolved a different pane
		// its focus flag would describe the wrong pane — report focus as unknown.
		if (expected && pane.pane_id && pane.pane_id !== expected) return { paneId: pane.pane_id };
		return { paneId: pane.pane_id, active: pane.focused === true };
	} catch {
		return undefined;
	}
}

/** Ask herdr to notify. False when herdr reports that nothing was shown. */
async function herdrNotify(title: string, body: string): Promise<boolean> {
	const res = await run(herdrBin(), ["notification", "show", title, "--body", body], 3000);
	if (!res.ok) return false;
	try {
		const parsed = JSON.parse(res.stdout) as { result?: { shown?: boolean } };
		if (parsed.result?.shown === false) return false;
	} catch {
		// No JSON on stdout: trust the exit status.
	}
	return true;
}

/** Does the frontmost app count as the terminal that hosts this herdr client? */
function isHerdrHostTerminal(cfg: NudgeConfig, front: FrontmostApp): boolean {
	const name = front.name?.toLowerCase();
	if (name && cfg.terminalApps.some((app) => app.toLowerCase() === name)) return true;
	if (name && HERDR_HOST_TERMINALS.some((app) => app.toLowerCase() === name)) return true;
	// The terminal that launched this herdr session tags the environment with its
	// bundle id, which also covers terminals we do not have in the list.
	const launchedFrom = process.env.__CFBundleIdentifier;
	return !!launchedFrom && !!front.bundleId && launchedFrom === front.bundleId;
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
	if (front.name === undefined) {
		return { focused: true, reason: "could not determine frontmost app (assuming focused)" };
	}

	if (inHerdr()) {
		// herdr knows which of its panes is active; AppleScript on Ghostty does
		// not, because every herdr pane is a cell grid drawn by the herdr client.
		const pane = await herdrPane();
		const herdr: HerdrFocus = {
			paneId: pane?.paneId ?? process.env.HERDR_PANE_ID,
			active: pane?.active,
			delivery: herdrDelivery(),
			windowFront: isHerdrHostTerminal(cfg, front),
		};
		const where = `herdr pane ${herdr.paneId ?? "?"}`;
		if (!cfg.preciseFocus) {
			// App-level check only, as requested — pane focus is still reported and
			// used to avoid duplicating herdr's own agent notifications.
			return herdr.windowFront
				? { focused: true, reason: `${front.name} is frontmost (preciseFocus off)`, herdr }
				: { focused: false, reason: `frontmost app is ${front.name}`, herdr };
		}
		if (!herdr.windowFront) {
			return { focused: false, reason: `frontmost app is ${front.name}`, herdr };
		}
		if (herdr.active !== false) {
			const verdict = herdr.active === true ? "is the active pane" : "focus unknown";
			return { focused: true, reason: `${where} ${verdict} and ${front.name} is frontmost`, herdr };
		}
		return { focused: false, reason: `${where} is not the active pane`, herdr };
	}

	if (!cfg.terminalApps.some((app) => app.toLowerCase() === front.name!.toLowerCase())) {
		return { focused: false, reason: `frontmost app is ${front.name}` };
	}
	if (!cfg.preciseFocus) {
		return { focused: true, reason: `${front.name} is frontmost` };
	}

	const res = await run("osascript", ["-e", GHOSTTY_FOCUSED_TERMINAL], 3000);
	if (!res.ok) {
		return { focused: true, reason: `${front.name} is frontmost (AppleScript unavailable)` };
	}
	const [name = "", termCwd = ""] = res.stdout.replace(/\n+$/, "").split(US);
	const isPiTitle = cfg.titleMarkers.some((marker) => name.includes(marker));
	if (samePath(termCwd, cwd) && isPiTitle) {
		return { focused: true, reason: `focused ${front.name} pane is this session ("${name.trim()}")` };
	}
	const shown = name.trim() || "(untitled)";
	return {
		focused: false,
		reason: `focused ${front.name} pane is "${shown}" in ${termCwd.trim() || "?"}`,
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

export type Transport = NudgeConfig["transport"] | "herdr" | "osc777" | "osc9" | "osascript" | "bell" | "none";

function resolveTransport(cfg: NudgeConfig): Exclude<NudgeConfig["transport"], "auto"> {
	if (cfg.transport !== "auto") return cfg.transport;
	// Inside herdr the pane's own escape sequences never reach the terminal, so
	// herdr has to relay the notification for us.
	if (inHerdr()) return "herdr";
	if (process.env.TERM_PROGRAM === "ghostty") return "osc777";
	if (process.platform === "darwin") return "osascript";
	return "osc9";
}

/** Absolute locations checked before falling back to a PATH scan. */
const TERMINAL_NOTIFIER_CANDIDATES = [
	"/opt/homebrew/bin/terminal-notifier",
	"/usr/local/bin/terminal-notifier",
];

let cachedTerminalNotifier: string | null | undefined;

/**
 * `terminal-notifier`, if this Mac has it. Its banners are attributed to a real
 * app and can activate the terminal on click. `osascript display notification`
 * needs the Script Editor to have notification permission — on installs where it
 * never registered (no entry in `com.apple.ncprefs`), it exits 0 and shows
 * nothing at all.
 */
export function terminalNotifierBin(): string | undefined {
	if (cachedTerminalNotifier !== undefined) return cachedTerminalNotifier ?? undefined;
	cachedTerminalNotifier = null;
	for (const candidate of TERMINAL_NOTIFIER_CANDIDATES) {
		if (existsSync(candidate)) {
			cachedTerminalNotifier = candidate;
			return candidate;
		}
	}
	for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
		if (!dir) continue;
		const candidate = path.join(dir, "terminal-notifier");
		if (existsSync(candidate)) {
			cachedTerminalNotifier = candidate;
			return candidate;
		}
	}
	return undefined;
}

/**
 * Desktop notification through the best available tool. Returns the tool used or
 * "none". Fire-and-forget by design: notifications must not delay the prompt.
 */
function desktopNotify(title: string, body: string): string {
	const notifier = terminalNotifierBin();
	if (notifier) {
		const args = ["-title", title, "-message", body, "-group", "pi-nudge"];
		// Clicking the banner returns to whichever terminal launched this session.
		const activate = process.env.__CFBundleIdentifier;
		if (activate) args.push("-activate", activate);
		try {
			execFile(notifier, args);
			return "terminal-notifier";
		} catch {
			/* fall through to osascript */
		}
	}
	try {
		execFile("osascript", [
			"-e",
			`display notification ${appleScriptString(body)} with title ${appleScriptString(title)}`,
		]);
		return "osascript";
	} catch {
		return "none";
	}
}

/**
 * Fire a desktop notification. Returns the transport actually used.
 *
 * `windowFront` describes the terminal window's focus, which only matters inside
 * herdr: a `terminal`-delivery notification is an OSC 9 sequence to the outer
 * terminal, and Ghostty silently drops those while it is the frontmost app.
 */
export async function sendNotification(
	cfg: NudgeConfig,
	title: string,
	body: string,
	hints: { windowFront?: boolean } = {},
): Promise<string> {
	const t = sanitize(title, 90) || "pi";
	const b = sanitize(body, 220);
	const requested = resolveTransport(cfg);
	let used = "none";

	if (requested === "osc777") {
		writeToTerminal(`\u001b]777;notify;${t};${b}\u0007`);
		used = "osc777";
	} else if (requested === "osc9") {
		// OSC 9 carries a single string; Ghostty uses it as the title.
		writeToTerminal(`\u001b]9;${t}${b ? ` — ${b}` : ""}\u0007`);
		used = "osc9";
	} else if (requested === "herdr") {
		const delivery = herdrDelivery();
		// `system` is a plain desktop notification — send it ourselves rather than
		// through herdr, because herdr broadcasts API notifications to *every*
		// attached client shell, so N attached clients mean N identical banners.
		// `terminal` has to go through herdr: only it can address the outer terminal.
		const viaHerdr = delivery === "terminal" && hints.windowFront === false;
		if (viaHerdr && (await herdrNotify(t, b))) {
			used = `herdr(${delivery})`;
		} else if (process.platform === "darwin") {
			// `[ui.toast] delivery` is off or in-app only (invisible away from the
			// terminal), or herdr could not reach a foreground client: a real macOS
			// notification is still wanted.
			used = desktopNotify(t, b);
		}
	} else if (requested === "osascript") {
		used = desktopNotify(t, b);
	}

	if (cfg.bell && requested !== "bell") writeToTerminal("\u0007");
	return used;
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
	/** `prompt` dialogs are only ever announced by us; `idle` is also announced by
	 *  herdr itself, so a visible herdr banner makes ours redundant. */
	kind: "prompt" | "idle";
	title: string;
	body: string;
	remindersLeft: number;
	timer?: ReturnType<typeof setTimeout>;
}

/**
 * herdr notifies for a *finished* pi agent on its own (its pi integration reports
 * the idle state) and shows that wherever `[ui.toast] delivery` points, even when
 * the pane is in a background tab. When that banner is guaranteed to be visible,
 * a second one from us is just noise — so stay quiet. Prompt notifications are
 * never covered by herdr, and `off`/`herdr` (in-app toast) delivery produces
 * nothing visible while you are away, so those always fall through to us.
 */
function herdrAlreadyNotifies(current: WaitingSpan, focus: FocusState): boolean {
	const herdr = focus.herdr;
	if (!herdr || current.kind !== "idle" || herdr.active !== false) return false;
	if (herdr.delivery === "system") return true;
	// A `terminal` notification is an OSC 9 sequence to the outer terminal, which
	// Ghostty drops while it is the frontmost app.
	if (herdr.delivery === "terminal") return !herdr.windowFront;
	return false;
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
		if (herdrAlreadyNotifies(current, focus)) return;

		const now = Date.now();
		if (!isReminder && now - lastNotifiedAt < cfg.dedupeMs) return; // e.g. prompt right after an idle nudge
		lastNotifiedAt = now;

		const body = isReminder ? `${current.body} (still waiting)` : current.body;
		const transport = await sendNotification(cfg, current.title, body, {
			windowFront: focus.herdr?.windowFront,
		});
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

	function beginSpan(kind: "prompt" | "idle", title: string, body: string): void {
		endSpan();
		// Reminders are for blocking dialogs — pi is stuck until you answer, so
		// repeated nudges are useful. A finished run only needs to be announced
		// once (opt back in with `remindersOnIdle`).
		const reminders = kind === "idle" && !cfg.remindersOnIdle ? 0 : Math.max(0, cfg.reminders);
		const current: WaitingSpan = {
			id: ++spanCounter,
			kind,
			title,
			body,
			remindersLeft: reminders,
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
		beginSpan("prompt", "π needs your input", `${label} in ${where}${firstLine ? ` — ${firstLine.trim()}` : ""}`);
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
		beginSpan("idle", "π is waiting for you", `Finished in ${where} — switch back to your terminal`);
	});

	pi.registerCommand("nudge", {
		description: "Notify-when-unfocused: status | focus | test | simulate",
		handler: async (args: string, ctx: ExtensionCommandContext) => {
			const sub = args.trim().toLowerCase().split(/\s+/)[0] ?? "";
			if (sub === "test") {
				const seconds = Number.parseFloat(args.trim().split(/\s+/)[1] ?? "0");
				const delayMs = Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 120) * 1000 : 0;
				if (delayMs > 0) {
					// Delayed on purpose: a terminal-owned banner is hidden while the
					// terminal is the active app, so the useful test happens after you
					// switch away.
					ctx.ui.notify(`Test notification in ${Math.round(delayMs / 1000)}s — switch to another app now.`, "info");
					const timer = setTimeout(() => {
						void sendNotification(cfg, "π test notification", "Delayed test — you should be looking at another app now.");
					}, delayMs);
					(timer as unknown as { unref?: () => void }).unref?.();
					return;
				}
				const used = await sendNotification(cfg, "π test notification", "Notifications are working.");
				ctx.ui.notify(
					`Sent via "${used}". If you saw nothing: a terminal-owned banner is hidden while the terminal is the active app — try "/nudge test 5" and switch away.`,
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
				`reminders=${cfg.reminders}@${Math.round(cfg.reminderIntervalMs / 1000)}s idleMinRunMs=${cfg.idleMinRunMs} remindersOnIdle=${cfg.remindersOnIdle}`,
			];
			if (focus.herdr) {
				const h = focus.herdr;
				lines.push(`herdr: pane=${h.paneId ?? "?"} paneActive=${h.active ?? "?"} windowFront=${h.windowFront} toastDelivery=${h.delivery}`);
				if (h.delivery === "off") {
					lines.push(`note: herdr popups are off — notifications fall back to the desktop notifier; set [ui.toast] delivery in ~/.config/herdr/config.toml for herdr-owned banners`);
				}
			}
			lines.push(`desktop notifier: ${terminalNotifierBin() ?? "osascript (no terminal-notifier; Script Editor needs notification permission)"}`);
			lines.push(
				`focus: ${focus.focused ? "active" : "NOT active"} — ${focus.reason}`,
				`note: a terminal-owned banner is hidden while the terminal is the active app; test with "/nudge test 5" + switch away`,
				`config file: ${existsSync(CONFIG_PATH) ? CONFIG_PATH : `${CONFIG_PATH} (not present, using defaults)`}`,
			);
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
