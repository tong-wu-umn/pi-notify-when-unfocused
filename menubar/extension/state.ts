/**
 * Pure registry logic for the PiMenuBar publisher.
 *
 * Everything here is free of pi imports so `node --test state.test.ts` can exercise it
 * directly (Node strips the types). `index.ts` only translates pi events into these
 * calls and owns the timer.
 */

export const REGISTRY_VERSION = 1;

export type AgentState = "idle" | "working" | "blocked";

export interface RegistryTool {
	id: string;
	name: string;
	startedAt: number;
}

export interface RegistryHerdr {
	paneId: string;
	workspaceId?: string;
	tabId?: string;
	socketPath?: string;
}

/** `registry v1`, exactly what the menu bar app decodes. */
export interface RegistryState {
	v: number;
	revision: number;
	pid: number;
	processStartedAt: number;
	sessionId?: string;
	sessionFile?: string;
	sessionName?: string;
	cwd: string;
	project: string;
	mode: string;
	state: AgentState;
	stateLabel: string | null;
	blockedKind: string | null;
	model?: string;
	provider?: string;
	thinking?: string;
	contextTokens: number | null;
	contextWindow: number | null;
	turnIndex: number;
	activeTools: RegistryTool[];
	lastTool: string | null;
	runStartedAt: number | null;
	waitingSince: number | null;
	settledAt: number | null;
	hasPendingMessages: boolean;
	lastUserPrompt: string | null;
	terminalBundleId?: string;
	herdr?: RegistryHerdr;
	updatedAt: number;
	simulated?: boolean;
	expiresAt?: number | null;
}

export interface MenuBarExtensionConfig {
	enabled: boolean;
	includedModes: string[];
	registryDir: string;
	heartbeatMs: number;
	staleAfterMs: number;
	includePromptPreview: boolean;
}

export const DEFAULT_CONFIG: MenuBarExtensionConfig = {
	enabled: true,
	includedModes: ["tui"],
	registryDir: "~/.pi/agent/menubar/sessions",
	heartbeatMs: 15_000,
	staleAfterMs: 90_000,
	includePromptPreview: false,
};

/**
 * Strips ANSI escapes and control characters, collapses whitespace, and clamps length.
 *
 * Prompt titles can carry coloured terminal output; without the explicit ANSI pass, the
 * escape byte is dropped but its `[31m` arguments survive into the menu bar.
 */
export function sanitizeText(value: unknown, max: number): string | null {
	if (typeof value !== "string") return null;
	const withoutAnsi = value.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, " ").replace(/\u001b[@-Z\\-_]/g, " ");
	const cleaned = withoutAnsi
		// eslint-disable-next-line no-control-regex
		.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
		.replace(/\s+/g, " ")
		.trim();
	if (!cleaned) return null;
	return cleaned.length > max ? `${cleaned.slice(0, Math.max(0, max - 1))}…` : cleaned;
}

/** First non-empty line of a possibly multi-line title, sanitized. */
export function firstLine(value: unknown, max: number): string | null {
	if (typeof value !== "string") return null;
	for (const line of value.split(/\r?\n/)) {
		const cleaned = sanitizeText(line, max);
		if (cleaned) return cleaned;
	}
	return null;
}

export function projectName(cwd: string): string {
	const trimmed = cwd.length > 1 && cwd.endsWith("/") ? cwd.slice(0, -1) : cwd;
	const parts = trimmed.split("/");
	const base = parts[parts.length - 1] ?? "";
	return base || trimmed || "/";
}

/** Monotonic revision source: seeded from the clock, so a reload cannot go backwards. */
export function createRevisionSource(seed: number): () => number {
	return createRevisionSourceFrom(seed, 0);
}

/**
 * Revision source that continues past a previously published revision.
 *
 * A reload reuses the same pid and therefore the same registry file; seeding only from
 * the clock could produce an equal (not greater) revision within the same millisecond,
 * and the app keeps the highest revision per process identity.
 */
export function createRevisionSourceFrom(seed: number, previousRevision: number): () => number {
	let revision = Math.max(Math.floor(seed * 1000), Math.floor(previousRevision) + 1);
	return () => {
		revision += 1;
		return revision;
	};
}

export interface Clock {
	now: () => number;
	processStartedAt: number;
	pid: number;
}

export interface SessionIdentity {
	sessionId?: string;
	sessionFile?: string;
	sessionName?: string;
	cwd: string;
	mode: string;
}

export interface TrackerOptions {
	clock: Clock;
	nextRevision: () => number;
	includePromptPreview: boolean;
	terminalBundleId?: string;
	herdr?: RegistryHerdr;
	identity: SessionIdentity;
	blockedLabels?: Record<string, string>;
}

const BLOCKED_LABELS: Record<string, string> = {
	select: "Select an option",
	confirm: "Approve or reject",
	input: "Type a value",
	editor: "Edit text",
	custom: "Respond in pi",
};

/**
 * Turns pi's event stream into registry state.
 *
 * `agentActive` and `promptOpen` are the only real inputs: every published field is
 * derived, so the state can always be recomputed from scratch (which is what makes
 * `/reload` safe).
 */
export class StatusTracker {
	private readonly options: TrackerOptions;
	private readonly nextRevision: () => number;

	identity: SessionIdentity;
	agentActive = false;
	promptOpen = false;
	blockedKind: string | null = null;
	blockedLabel: string | null = null;
	waitingSince: number | null = null;
	settledAt: number | null = null;
	runStartedAt: number | null = null;
	turnIndex = 0;
	activeTools = new Map<string, RegistryTool>();
	lastTool: string | null = null;
	model: string | undefined;
	provider: string | undefined;
	thinking: string | undefined;
	contextTokens: number | null = null;
	contextWindow: number | null = null;
	hasPendingMessages = false;
	lastUserPrompt: string | null = null;
	herdr: RegistryHerdr | undefined;
	simulatedUntil: number | null = null;
	simulatedState: AgentState | null = null;
	terminalBundleId: string | undefined;

	constructor(options: TrackerOptions) {
		this.options = options;
		this.identity = options.identity;
		this.nextRevision = options.nextRevision;
		this.herdr = options.herdr;
		this.terminalBundleId = options.terminalBundleId;
	}

	state(): AgentState {
		if (this.promptOpen) return "blocked";
		if (this.agentActive) return "working";
		return "idle";
	}

	/** Applies `session_start` semantics, including mid-run `/reload`. */
	onSessionStart(identity: SessionIdentity, agentActive: boolean): void {
		this.identity = identity;
		this.agentActive = agentActive;
		this.promptOpen = false;
		this.blockedKind = null;
		this.blockedLabel = null;
		this.waitingSince = null;
		this.settledAt = null;
		this.activeTools.clear();
		this.lastTool = null;
		this.turnIndex = 0;
		this.runStartedAt = agentActive ? this.options.clock.now() : null;
	}

	onAgentStart(): void {
		this.agentActive = true;
		this.runStartedAt = this.options.clock.now();
		this.settledAt = null;
		this.waitingSince = null;
		this.activeTools.clear();
	}

	onPromptStart(kind: string, title?: string): void {
		this.promptOpen = true;
		this.blockedKind = kind;
		this.waitingSince = this.options.clock.now();
		this.blockedLabel =
			firstLine(title, 80) ?? this.options.blockedLabels?.[kind] ?? BLOCKED_LABELS[kind] ?? "Needs input";
	}

	onPromptEnd(): void {
		this.promptOpen = false;
		this.blockedKind = null;
		this.blockedLabel = null;
		this.waitingSince = null;
	}

	/** Parallel tool calls finish out of order, so tools are tracked by call id. */
	onToolStart(toolCallId: string, toolName: string): void {
		this.activeTools.set(toolCallId, {
			id: toolCallId,
			name: toolName,
			startedAt: this.options.clock.now(),
		});
	}

	onToolEnd(toolCallId: string, toolName: string): void {
		this.activeTools.delete(toolCallId);
		this.lastTool = toolName;
	}

	onTurn(turnIndex: number): void {
		this.turnIndex = turnIndex;
	}

	onUsage(tokens: number | null, contextWindow: number | null): void {
		this.contextTokens = tokens;
		this.contextWindow = contextWindow;
	}

	onModel(model?: string, provider?: string, thinking?: string): void {
		if (model) this.model = model;
		if (provider) this.provider = provider;
		if (thinking) this.thinking = thinking;
	}

	onSettled(): void {
		this.agentActive = false;
		this.activeTools.clear();
		this.settledAt = this.options.clock.now();
	}

	/** A user prompt preview is opt-in: prompts can contain anything. */
	onUserPrompt(prompt: string | undefined): void {
		if (!this.options.includePromptPreview) {
			this.lastUserPrompt = null;
			return;
		}
		this.lastUserPrompt = sanitizeText(prompt, 120);
	}

	onSessionName(name: string | undefined): void {
		this.identity = { ...this.identity, sessionName: sanitizeText(name, 60) ?? undefined };
	}

	onPendingMessages(pending: boolean): void {
		this.hasPendingMessages = pending;
	}

	/**
	 * Presentation-only override with an expiry. Real events keep updating the tracker
	 * underneath, so expiry always republishes the live state.
	 */
	simulate(state: AgentState, seconds: number): number {
		const until = this.options.clock.now() + Math.max(1, seconds) * 1000;
		this.simulatedUntil = until;
		this.simulatedState = state;
		return until;
	}

	clearSimulation(): void {
		this.simulatedUntil = null;
		this.simulatedState = null;
	}

	simulationActive(): boolean {
		if (this.simulatedUntil === null || this.simulatedState === null) return false;
		return this.options.clock.now() < this.simulatedUntil;
	}

	snapshot(): RegistryState {
		const now = this.options.clock.now();
		const simulated = this.simulationActive();
		const state = simulated ? (this.simulatedState as AgentState) : this.state();
		const label = simulated
			? "simulated (menubar simulate)"
			: this.promptOpen
				? this.blockedLabel
				: null;

		return {
			v: REGISTRY_VERSION,
			revision: this.nextRevision(),
			pid: this.options.clock.pid,
			processStartedAt: this.options.clock.processStartedAt,
			sessionId: this.identity.sessionId,
			sessionFile: this.identity.sessionFile,
			sessionName: this.identity.sessionName,
			cwd: this.identity.cwd,
			project: projectName(this.identity.cwd),
			mode: this.identity.mode,
			state,
			stateLabel: label,
			blockedKind: this.blockedKind,
			model: this.model,
			provider: this.provider,
			thinking: this.thinking,
			contextTokens: this.contextTokens,
			contextWindow: this.contextWindow,
			turnIndex: this.turnIndex,
			activeTools: [...this.activeTools.values()],
			lastTool: this.lastTool,
			runStartedAt: this.runStartedAt,
			waitingSince: this.waitingSince,
			settledAt: this.settledAt,
			hasPendingMessages: this.hasPendingMessages,
			lastUserPrompt: this.lastUserPrompt,
			terminalBundleId: this.terminalBundleId,
			herdr: this.herdr,
			updatedAt: now,
			simulated,
			expiresAt: simulated ? this.simulatedUntil : null,
		};
	}
}

export interface WriteResult {
	path: string;
	bytes: number;
}

/** Coerces a config value the way the app does, so both ends agree on defaults. */
export function coerceConfig(raw: unknown): MenuBarExtensionConfig {
	const config: MenuBarExtensionConfig = { ...DEFAULT_CONFIG };
	if (!raw || typeof raw !== "object") return config;
	const source = raw as Record<string, unknown>;
	if (typeof source.enabled === "boolean") config.enabled = source.enabled;
	if (Array.isArray(source.includedModes) && source.includedModes.length > 0) {
		config.includedModes = source.includedModes.map((mode) => String(mode));
	}
	if (typeof source.registryDir === "string" && source.registryDir) config.registryDir = source.registryDir;
	if (typeof source.heartbeatMs === "number" && Number.isFinite(source.heartbeatMs)) {
		config.heartbeatMs = Math.min(600_000, Math.max(1_000, Math.round(source.heartbeatMs)));
	}
	if (typeof source.staleAfterMs === "number" && Number.isFinite(source.staleAfterMs)) {
		config.staleAfterMs = Math.min(3_600_000, Math.max(5_000, Math.round(source.staleAfterMs)));
	}
	if (typeof source.includePromptPreview === "boolean") config.includePromptPreview = source.includePromptPreview;
	// A heartbeat slower than the staleness window would make rows look dead.
	if (config.heartbeatMs * 4 > config.staleAfterMs) config.staleAfterMs = config.heartbeatMs * 4;
	return config;
}

export function expandTilde(path: string, home: string): string {
	if (path === "~") return home;
	if (path.startsWith("~/")) return `${home}/${path.slice(2)}`;
	return path;
}

export function resolveRegistryDir(config: MenuBarExtensionConfig, home: string): string {
	return expandTilde(config.registryDir, home);
}

export function registryFileName(pid: number): string {
	return `${pid}.json`;
}

/** True when the session should publish at all. */
export function shouldPublish(config: MenuBarExtensionConfig, mode: string): boolean {
	return config.enabled && config.includedModes.includes(mode);
}
