# macOS menu bar status bar for pi sessions — implementation plan

| | |
|---|---|
| Branch | `menubar-status-bar` (off `main`) |
| Status | Plan / not started |
| Author | planning session, 2026-09-21 |
| Scope | A macOS menu bar (NSStatusItem) status bar that shows brief, essential info about **all** active pi sessions, and focuses the right pane on click. |

---

## 1. Goal and non-goals

**Goal.** One glance at the macOS menu bar tells you what your pi fleet is doing:
how many sessions are working, which one is *blocked waiting on you*, which one
finished while you were away, and — on click — which project each belongs to, the
model, elapsed time, current tool, and context usage. Clicking a row brings that
session's terminal pane back to the front.

**Non-goals**

- Not a replacement for `notify-when-unfocused` (that stays the "you are away, here
  is a banner" channel). This is the glanceable, always-present channel.
- Not a second pi UI. No prompt submission, no approval, no killing sessions.
- Not a new TUI. The pi-side extension only *publishes* state; rendering is native.
- Not a cross-machine dashboard (herdr has SSH machines and their own sockets; out of
  scope, though the design does not preclude it).

---

## 2. Verified constraints

Everything below was executed and verified in this environment (macOS 26, herdr
0.9.1, protocol 22, Ghostty, Node v26.9.0, Swift 6.3.3 CLI tools). Raw commands and
outputs are in [Appendix A](#appendix-a-raw-evidence).

| # | Fact | Evidence |
|---|---|---|
| 1 | pi has **no** macOS menu bar surface. Its only UI hooks are terminal-scoped: `ctx.ui.setStatus/setWidget/setFooter`. | `docs/extensions.md:2600`, `docs/tui.md:768`, `dist/core/extensions/types.d.ts:81` |
| 2 | A separate native process is therefore mandatory. | fact 1 |
| 3 | A menu bar app builds with **Command Line Tools only** (no Xcode project): `swift build` on a SwiftPM package, and `swiftc -framework AppKit main.swift -o PiBar` both succeed. | Appendix A.1 |
| 4 | herdr already tracks **every** agent across panes, cross-session: `herdr agent list` / `session.snapshot` return `agent`, `agent_status ∈ {idle,working,blocked,done,unknown}`, `cwd`, `pane_id`, `tab_id`, `workspace_id`, `focused`, `terminal_title`, `state_labels`, `tokens`. | Appendix A.2 |
| 5 | herdr exposes a **push** channel: newline-delimited JSON over `HERDR_SOCKET_PATH` (`~/.config/herdr/herdr.sock`, mode `srw-------`), `events.subscribe` → `{"id":…,"result":{"type":"subscription_started"}}`, then `{"event":"<kind>","data":{…}}`. | Appendix A.3 |
| 6 | Subscription events are **lossy by design**: no id, no sequence number, no replay. Ground truth must come from `session.snapshot`. | Appendix A.3 |
| 7 | After `events.subscribe`, that socket becomes an event stream — later requests on the *same* connection are not answered. One connection per purpose. | Appendix A.4 |
| 8 | `pane.updated` fires on **every output revision** (revisions 106→107 within seconds on a working pane). It must be throttled or avoided. | Appendix A.5 |
| 9 | `pane.agent_status_changed` is low-frequency but needs an explicit `pane_id` per subscription, and carries only a small payload. | Appendix A.6 |
| 10 | `herdr agent focus <pane_id>` resolves absolute targets (`agent get w1:p1` works; `agent focus nope:pX` → `agent_not_found`). `herdr pane focus` is **directional only** (`--direction left|right|up|down`) and cannot target a specific pane. | Appendix A.7 |
| 11 | An explicit focus command **marks the agent seen** (done → idle). Clicking a row is therefore also "acknowledge". | `herdr --skill`, line 59 |
| 12 | A pi extension can already report state to herdr today: `~/.pi/agent/extensions/herdr-agent-state.ts` (installed by herdr, `HERDR_INTEGRATION_VERSION=9`) sends `pane.report_agent` / `pane.report_agent_session` on `session_start` / `agent_start` / `agent_settled` and a `herdr:blocked` event. | file read, Appendix A.8 |
| 13 | Extra display metadata can be pushed from pi: `pane.report_metadata` with `--title`, `--display-agent`, `--state-label <STATUS=TEXT>`, `--token <NAME=VALUE>`, `--ttl-ms`. | `herdr pane report-metadata --help`, schema `PaneReportMetadataParams` |
| 14 | Node 26 runs TypeScript test files directly (`node --test tests/*.test.ts`), so pi-side tests need no build step. | `node --version` → v26.9.0 |

**Consequence.** The status bar is a consumer of two independent publishers:

1. **herdr** — authoritative, cross-session, event-driven, works even if the pi-side
   extension is broken or absent; only available inside herdr.
2. **A pi extension + registry file** — richer per-session detail (model, thinking,
   context %, current tool, last prompt, unseen-finished flag), the *only* source
   outside herdr, and the merge key that ties the two together.

---

## 3. Architecture

```
┌─ pi process A (herdr pane w1:p1) ──────────┐
│  extension: session-status.ts              │
│   session_start/agent_start/tool_*/turn_*  │
│   ui_prompt_start/ui_prompt_end            │
│   model_select/agent_settled/shutdown      │
└───────┬───────────────────────┬────────────┘
        │ atomic write          │ (optional) pane.report_metadata
        ▼                       ▼
 ~/.pi/agent/menubar/sessions/   herdr server ──┐
   <pid>.json   (heartbeat)      (agent state,  │
        ▲                          pane/tab/ws, │
        │ DispatchSource dir watch  focus)      │
        │                                        │
┌───────┴────────────────────────────────────────┴──────────┐
│ PiMenuBar.app  (LSUIElement, one instance, login item)    │
│  RegistryWatcher ─┐                                       │
│  HerdrClient ─────┴─► SessionStore (merge) ─► MenuBar UI  │
│    snapshot + events                    │         │       │
│                                         │         ▼       │
│                                    Focuser: `herdr agent  │
│                                    focus <pane_id>`       │
└───────────────────────────────────────────────────────────┘
```

### Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Native Swift `NSStatusItem` app, not SwiftBar/xbar/rumps | SwiftBar is not installed and is poll-only; a Swift app gets push updates, rich dropdown rows, and click-to-focus with no third-party runtime. CLT-only build verified (fact 3). |
| D2 | Two publishers, merged in the app, never one source of truth | herdr survives a broken extension; the registry is the only source outside herdr and holds the detail herdr does not know. Neither is sufficient alone. |
| D3 | Join on the **pi session file path** (`registry.sessionFile` ↔ `herdr.agent_session.value` where `kind == "path"`), fallback `pane_id`, fallback `pid` | herdr already reports the pi session JSONL path (`source: herdr:pi`), and the extension can obtain the same path from `ctx.sessionManager.getSessionFile()`. Unmatched rows are shown, never dropped. |
| D4 | Registry = one file per pi process, `updatedAt` heartbeat, atomic `rename`; liveness by mtime, not by locks | Independent writers, no coordination, crash-safe (a `kill -9`'d pi simply stops heartbeating and the row disappears after `staleAfterMs`). |
| D5 | Snapshot is ground truth; events are deltas; reconnect always re-snapshots | Events carry no id/seq and are not replayed (fact 6). |
| D6 | Subscribe to `pane.agent_status_changed` per agent pane + structural events; **do not** subscribe to `pane.updated` except as a throttled fallback | `pane.updated` fires per output revision (fact 8) — unusable unthrottled. |
| D7 | Click → `herdr agent focus <pane_id>` | Only absolute focus primitive that works (fact 10), and it doubles as "mark seen" (fact 11). |
| D8 | Home: **this repo**, `extensions/` (pi side) + `menubar/` (Swift) + shared `docs/plans/menubar-status-bar.md` | One schema, one version, no cross-repo drift for a personal tool. `package.json#files` already whitelists only `extensions/`, so `pi install` is unaffected by the Swift tree. See [§11](#11-open-decisions-o1-is-the-only-one-that-blocks-p1). |

---

## 4. Data contracts

### 4.1 Registry file (pi side) — `registry v1`

Location: `~/.pi/agent/menubar/sessions/<pid>.json` (override: `PI_MENUBAR_REGISTRY_DIR`).
Filename is the **pid**, so a restarted or forked session never clobbers another
process's file; the old file is GC'd as stale.

```jsonc
{
  "v": 1,
  "pid": 85713,
  "sessionId": "01a0c3d1-bbc8-74d6-bc36-64188b9b4974",
  "sessionFile": "/Users/tongwu/.pi/agent/sessions/--…--/2026-09-21T11-54-57-353Z_01a0c3d1-….jsonl",
  "cwd": "/Users/tongwu/Downloads/project/pi-notify-when-unfocused",
  "project": "pi-notify-when-unfocused",        // basename(cwd), precomputed for the UI
  "title": "π - pi-notify-when-unfocused",       // process title, informational
  "mode": "tui",                                  // tui | rpc | json | print  (headless still publishes)
  "state": "blocked",                             // idle | working | blocked | error
  "stateLabel": "Approve or reject — Bash command",// short human text for the row
  "blockedKind": "confirm",                       // select|confirm|input|editor|custom, when blocked
  "model": "deepseek-flash",
  "provider": "deepseek",
  "thinking": "high",
  "contextTokens": 84213,
  "contextWindow": 200000,
  "turnIndex": 12,
  "tool": { "name": "bash", "startedAt": 1758449999999 },   // present while a tool runs
  "lastTool": "bash",
  "runStartedAt": 1758449900000,                 // absent when idle
  "waitingSince": 1758450000000,                 // set when state=blocked
  "settledAt": 1758450000000,                    // set when a run settled
  "unseen": true,                                // settled/blocked since the pane was last focused
  "lastUserPrompt": "add a status bar that shows…",  // ≤120 chars, single line
  "queuedMessages": 0,
  "terminalBundleId": "com.mitchellh.ghostty",   // from __CFBundleIdentifier, for non-herdr focus
  "herdr": { "paneId": "w1:p1", "workspaceId": "w1", "tabId": "w1:t1" },  // omitted outside herdr
  "updatedAt": 1758450000123                     // heartbeat; liveness = now - updatedAt <= staleAfterMs
}
```

Write rules:

- **Atomic**: write `<pid>.json.tmp.<rand>` then `rename()` over the target. Readers
  therefore never see a partial document (D4).
- **When**: on every meaningful transition (see §6.1) plus a `heartbeatMs` timer
  (default 15 s) that only bumps `updatedAt`. The timer is `unref()`'d so it never
  holds pi open.
- **On shutdown**: `session_shutdown` deletes the file. `SIGINT`/`SIGTERM` are also
  covered because pi emits `session_shutdown` on its own shutdown path; a hard
  `kill -9` is covered by the staleness rule instead.
- Reader-side GC (app): ignore `updatedAt` older than `staleAfterMs`; delete files
  older than 10 × `staleAfterMs`; delete immediately if `kill(pid, 0)` throws
  `ESRCH`.
- Compatibility: the `v` field is checked; unknown-major files are ignored with a log
  line, not crashed on.

### 4.2 herdr socket protocol (verified)

Transport: `AF_UNIX` stream at `HERDR_SOCKET_PATH`. Framing: **one JSON object per
line, both directions**.

Request `{ "id": "<any>", "method": "<name>", "params": { … } }` →
response `{ "id": "<same>", "result": { … } }` or `{ "id": "<same>", "error": { "code": "…", "message": "…" } }`.

Methods used by the app:

| Method | Params | Use |
|---|---|---|
| `session.snapshot` | `{}` | Ground truth: `version`, `protocol`, `focused_{workspace,tab,pane}_id`, `workspaces[]`, `tabs[]`, `panes[]`, `layouts[]`, `agents[]` |
| `events.subscribe` | `{ subscriptions: [ {type}, … ] }` | Push stream; ack `{"result":{"type":"subscription_started"}}`, then `{"event":"…","data":{…}}` |

Subscriptions of interest (from schema `Subscription`, 27 kinds):

| Subscription | Extra params | Notes |
|---|---|---|
| `pane.agent_status_changed` | `pane_id` (**required**) | low frequency; payload `{pane_id, workspace_id, agent_status, agent, state_labels?, display_agent?, title?}` |
| `pane.created`, `pane.closed`, `pane.moved`, `pane.exited` | — | structural → re-snapshot |
| `tab.focused`, `tab.created`, `tab.closed`, `tab.renamed`, `tab.moved` | — | structural / focus |
| `workspace.focused`, `workspace.created`, `workspace.closed`, `workspace.renamed`, `workspace.moved`, `workspace.reordered` | — | structural / focus |
| `layout.updated` | — | splits/zoom — ignore for v1 (layout is not rendered) |
| `pane.updated` | — | **avoid** (per-revision chattiness, fact 8); use only as a 1 Hz-throttled fallback if `pane.agent_status_changed` per-pane coverage proves unreliable |

Snapshot-derived shapes that matter (verified fields):

```
agents[]     : agent, agent_status, cwd, focused, pane_id, tab_id, workspace_id,
               revision, state_change_seq, terminal_id, terminal_title,
               agent_session{agent,kind,source,value}, state_labels{}, tokens{}
panes[]      : superset of an agent entry + scroll{viewport_rows, offset_from_bottom,
               max_offset_from_bottom}
tabs[]       : tab_id, workspace_id, label, number, pane_count, agent_status, focused
workspaces[] : workspace_id, label, number, tab_count, pane_count, agent_status, focused,
               active_tab_id
```

Client rules:

1. Open connection A → `session.snapshot` → close.
2. Open connection B → `events.subscribe` → keep as a read-only stream until error/EOF.
3. On any structural event: re-snapshot (coalesced, ≥300 ms apart).
4. On disconnect: exponential backoff 500 ms → 5 s, then 1–3. Always.
5. Safety net: unconditional re-snapshot every `pollIntervalMs` (default 30 s) even
   while connected, because events are lossy.
6. If `protocol` < required minimum: run in registry-only mode and say so in the menu
   (`herdr protocol 22 unsupported`). Never crash.

### 4.3 Merged session model (in the app)

```swift
struct Session {
  let key: String            // sessionFile ?? "herdr:<paneId>" ?? "pid:<pid>"
  var source: Source         // .herdrAndRegistry | .herdr | .registry
  var project, cwd, sessionFile: String
  var sessionId: String?
  var state: SessionState    // .working .blocked .idle .done .unknown .error
  var unseen: Bool           // blocked || (done/idle-settled && !focused && !seen)
  var model, thinking: String?
  var contextTokens, contextWindow: Int?
  var tool: String?
  var runStartedAt, waitingSince, settledAt: Date?
  var lastUserPrompt: String?
  var herdr: HerdrRef?       // paneId, tabId, workspaceId, tabLabel, workspaceLabel, focused
  var focused: Bool
  var updatedAt: Date
}
```

Merge rules (deterministic, unit-testable):

1. Rows keyed by `key`; union of both sources.
2. `state`: herdr's `agent_status` wins when present **and fresh** (it is the same
   state machine pi reports to herdr); otherwise the registry's `state`. Map
   herdr `done` → `.done` (unseen until focused), `blocked` → `.blocked`,
   `unknown` → `.unknown`.
3. `unseen`: `true` if `state ∈ {blocked}` and `!focused`; or `state == .done` and
   `!focused`; or registry `unseen == true` and `!focused`. Cleared when the app
   focuses that row or when herdr's `focused` flips true.
4. Detail fields (`model`, `thinking`, tokens, `tool`, `lastUserPrompt`, timings) come
   from the registry only; missing → row renders without them (no placeholder noise).
5. `project` = registry `project` ?? `basename(herdr.cwd)`.
6. Age out: registry-only rows older than `staleAfterMs` vanish; herdr rows vanish when
   the pane/agent disappears from the snapshot.
7. `focused`: herdr `focused` when known, else `false` (never guess).

Aggregates for the title: `blockedCount`, `workingCount`, `unseenCount`, `idleCount`,
`total`, plus `oldestWaitingSince` for the tooltip.

---

## 5. Repository layout

```
pi-notify-when-unfocused/
├─ extensions/
│  ├─ notify-when-unfocused.ts          (existing, untouched)
│  └─ session-status.ts                 NEW  pi-side publisher  (§6.1)
├─ menubar/                             NEW  Swift app + packaging
│  ├─ Package.swift                     SwiftPM: PiMenuBarCore (lib) + PiMenuBar (exec)
│  ├─ Makefile                          build / bundle / run / install / uninstall
│  ├─ Resources/Info.plist              LSUIElement=1, bundle id, version
│  ├─ Sources/PiMenuBarCore/            testable, no AppKit
│  │  ├─ Models.swift                   Session, SessionState, HerdrRef
│  │  ├─ RegistryFile.swift             decode/staleness/GC
│  │  ├─ HerdrProtocol.swift            request/response/event Codable types
│  │  ├─ SessionStore.swift             merge rules §4.3 + change notification
│  │  └─ TitleFormatter.swift           §7.1 rendering rules
│  ├─ Sources/PiMenuBar/                AppKit only
│  │  ├─ main.swift                     NSApplication, .accessory, lock check
│  │  ├─ AppDelegate.swift              single-instance, login-item helpers
│  │  ├─ StatusItemController.swift     NSStatusItem, attributedTitle, tooltip
│  │  ├─ MenuBuilder.swift              NSMenu from SessionStore (§7.2)
│  │  ├─ HerdrClient.swift              snapshot + subscribe + reconnect (§4.2)
│  │  ├─ RegistryWatcher.swift          DispatchSource dir watch + debounce
│  │  ├─ Focuser.swift                  focus + mark-seen (§6.6)
│  │  ├─ Config.swift                   ~/.pi/agent/menubar.json
│  │  └─ Log.swift                      ~/Library/Logs/PiMenuBar.log
│  └─ Tests/PiMenuBarCoreTests/         swift test
├─ tests/
│  └─ session-status.test.ts            node --test (registry writer)
├─ dev/
│  └─ fake-sessions.sh                  NEW  synthesize N registry files for UI work
└─ docs/plans/menubar-status-bar.md      this file
```

`package.json#files` stays `["extensions", "README.md", "LICENSE"]` — the Swift tree is
never shipped to `pi install` consumers.

---

## 6. Component specifications

### 6.1 pi extension — `extensions/session-status.ts`

Single responsibility: keep one registry file current. No rendering, no herdr calls
required for the core path (herdr metadata push is optional, P5).

Config load follows the existing house style in `notify-when-unfocused.ts`:
`~/.pi/agent/menubar.json`, `PI_MENUBAR_*` env overrides, malformed config → defaults,
never throw at load.

State machine (one `recompute()` → `publish()` if changed, modelled on the
`blockedCount` coalescing already used in `herdr-agent-state.ts`):

| Event | Effect |
|---|---|
| `session_start` | write initial file, `state=idle`, reset counters, start heartbeat timer (`unref`) |
| `input` | `lastUserPrompt` = first line, ≤120 chars |
| `agent_start` | `state=working`, `runStartedAt=now`, `waitingSince=null`, `unseen=false` |
| `ui_prompt_start` | `blockedCount += 1`; `state=blocked`, `waitingSince=now`, `blockedKind`, `stateLabel` from `event.kind` + `event.title` first line |
| `ui_prompt_end` | `blockedCount -= 1` (floor 0); clear `waitingSince` when 0; recompute |
| `tool_execution_start` | `tool={name, startedAt}` |
| `tool_execution_end` | `lastTool=name`, `tool=null` |
| `turn_start` / `turn_end` | `turnIndex = event.turnIndex` |
| `message_end` | user message → `lastUserPrompt`; assistant message → `contextTokens` from usage, or `ctx.getContextUsage()` |
| `model_select`, `thinking_level_select` | `model`, `provider`, `thinking` |
| `agent_end` | if the run's messages carry an error stop reason → `state=error`, `stateLabel="error: …"` (else no-op; `agent_settled` decides) |
| `agent_settled` | if `ctx.isIdle()` → `state=idle`, `settledAt=now`, `unseen=true` |
| `session_shutdown` | delete file, clear timer |

Publishes in **all** modes that have a session file (tui/rpc/json/print) — unlike
`herdr-agent-state.ts`, which is TUI-gated, a headless pi run is still a live session
worth a row. `mode` is recorded instead of gating.

Commands — `/menubar` (the debugging surface, mirrors `/nudge`):

| Subcommand | Behaviour |
|---|---|
| `status` | registry dir, own file path, pretty state summary, staleness, whether PiMenuBar is running |
| `dump` | print the exact JSON currently on disk |
| `simulate <idle\|working\|blocked\|done\|error>` | write a canned state without needing a real run (drives UI development, see §9) |
| `clear` | delete the file |
| `doctor` | dir writability, `HERDR_SOCKET_PATH` reachable, herdr protocol version, `swift`/app presence |

Deliberate non-goals: it does **not** report agent state to herdr (that is
`herdr-agent-state.ts`'s job — two reporters with different `seq` can fight), and it
does not send notifications (`notify-when-unfocused` owns that).

### 6.2 `HerdrClient`

- Detects availability: `HERDR_SOCKET_PATH` set **and** connectable; otherwise
  `available=false` and the store runs registry-only.
- Two sockets (facts 6, 7): snapshot socket (short-lived) and event socket
  (long-lived).
- Decodes with `Codable` structs generated by hand from the schema dump
  (`herdr api schema --json`), tolerant of unknown fields (default `Codable` ignores
  extras) and of `null` optionals.
- Subscriptions built from the last snapshot: one `pane.agent_status_changed` per pane
  whose `agent` is non-null, plus the structural/focus events in §4.2. Rebuilt on every
  re-snapshot (subscribe is additive per connection, so a rebuild means resubscribing
  on a fresh connection — simplest correct behaviour).
- Debounce: structural events coalesce into one re-snapshot at ≥300 ms spacing.
- Backoff 500 ms → 5 s with jitter; logs connect/subscribe/EOF transitions.
- Protocol guard: require `protocol >= 22` (recorded constant), else registry-only +
  a menu warning row.

### 6.3 `RegistryWatcher`

- `DispatchSource.makeFileSystemObjectSource` on the registry **directory** (`.write`),
  plus a 2 s safety poll (directory events can be coalesced).
- Reads every `*.json`, ignores `*.tmp.*`, parses defensively (a malformed file is
  skipped and counted, never fatal), drops stale rows, applies `staleAfterMs`.
- Atomic-rename writes mean no partial reads (D4); the debounce (100 ms) also absorbs
  the `tmp` → final rename pair.
- Creates missing dirs on first run (`~/.pi/agent/menubar/sessions`).

### 6.4 `SessionStore`

Pure merge (§4.3) + `onChange` callback. All of §4.3 is implemented in
`PiMenuBarCore` and covered by `swift test` — this is the piece most likely to grow
subtle bugs, so it has no AppKit dependency on purpose.

### 6.5 `StatusItemController` / `MenuBuilder`

- `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`,
  `button.attributedTitle` for colour, `button.toolTip` for the full summary.
- `isVisible = !(hideWhenEmpty && total == 0)`.
- Rebuilds the title on store change (coalesced to ≤4 Hz).
- Menu is rebuilt lazily via `NSMenuDelegate.menuNeedsUpdate` **and** refreshed live if
  already open.
- Rows are plain `NSMenuItem`s in v1 (title + submenu), two-column `NSMenuItem.view`
  rows in P4.

### 6.6 `Focuser`

| Case | Action |
|---|---|
| `herdr.paneId` present | `herdr agent focus <paneId>`; on `agent_not_found` → `herdr workspace focus <ws>` then `herdr tab focus <tab>` |
| no herdr, `terminalBundleId` present | activate that app via `NSRunningApplication` (best effort: app-level only, tab cannot be targeted) |
| neither | no-op + log; menu row shows "cannot focus" |

After a successful focus: clear local `unseen` optimistically; herdr independently marks
the agent seen (fact 11). De-duplicate clicks within 500 ms. Run the CLI with a 3 s
timeout and never block the main thread (async `Process`, or a serial `DispatchQueue`).

### 6.7 Config — `~/.pi/agent/menubar.json`

Shared file; the app reads all keys, the extension reads its own and ignores the rest.

```json
{
  "enabled": true,
  "registryDir": "~/.pi/agent/menubar/sessions",
  "heartbeatMs": 15000,
  "staleAfterMs": 90000,
  "showIdle": true,
  "hideWhenEmpty": true,
  "maxRows": 20,
  "pollIntervalMs": 30000,
  "showNonPiAgents": false,
  "logLevel": "info"
}
```

Extension env overrides: `PI_MENUBAR_ENABLED`, `PI_MENUBAR_REGISTRY_DIR`,
`PI_MENUBAR_DEBUG=1`.

---

## 7. UX specification

### 7.1 Menu bar title

Compact by construction — menu bar space is the scarcest resource.

| Situation | Title |
|---|---|
| no sessions, `hideWhenEmpty` | (item hidden) |
| all idle | `π 3·` |
| one working, one blocked, one unseen-done | `π 1!1▶1○` |
| only idle but `showIdle: false` | `π 3` |
| > 9 in a bucket | clamp to `9+` |

Order and glyphs: `!` blocked, `▶` working, `○` finished-unseen, `·` idle. Prefix `π`.

Colours (`attributedTitle`): blocked `NSColor.systemRed`, unseen `NSColor.systemOrange`,
working `NSColor.labelColor`, idle `NSColor.secondaryLabelColor`, counts/glyph prefix
`NSColor.secondaryLabelColor`. macOS menu bar tinting may override in some
appearances — the layout must remain readable without colour, which is why glyphs
differ per state. Tooltip carries the full plain-text summary, e.g.
`π — 2 working (pi-notify-when-unfocused 12m, mobile_pda 3m) · 1 blocked 45s (jev-sts2) · 3 idle`.

### 7.2 Dropdown

```
π 6 sessions — 2 working · 1 blocked · 1 finished · 2 idle
────────────────────────────────────────────────────────────
WORKSPACE  tong's mbp
  TAB 1 · misc
    ! jev-sts2            blocked 45s · Approve Bash?          [focus]
    ▶ pi-notify-when-…    Bash · 12m · deepseek-flash · 42%    [focus]
  TAB 5 · mobile_pda
    ▶ mobile_pda          2 subagents · 3m · gpt-5 · 61%       [focus]
    ○ spend_tracker        finished 8m ago · deepseek-flash    [focus]
────────────────────────────────────────────────────────────
Refresh now · Open config… · Open registry folder · Open log · Quit PiMenuBar
```

- Row primary text: state glyph + project. Row secondary text (attributed, right side
  in v1, or a second line): `tool · elapsed · model · ctx%`, and for blocked/waiting
  `blocked <duration> · <stateLabel>`, for unseen-done `finished <duration> ago`.
- Row submenu: `Focus`, `Copy session path`, `Copy working directory`, `Show details…`
  (P4 window: raw merged `Session` pretty-printed), `Mark seen`.
- Focused session is rendered dimmed with a `•` marker and no focus action.
- Sessions whose source is herdr-only show a `…` where registry detail is missing.
- `showNonPiAgents: true` additionally lists claude/codex agents from the same snapshot
  (they have `agent`, `agent_status`, `cwd`; no registry detail).
- Keyboard/accessibility: menu items get explicit `accessibilityLabel`s.

---

## 8. Phases

Each phase ends with something demonstrable and independently useful.

### P0 — Skeleton and contracts
1. Verify toolchain (`swift build`, `node --test`) — already confirmed, re-run in CI-less
   local flow.
2. `menubar/Package.swift` with `PiMenuBarCore` + `PiMenuBar` targets; `Info.plist`
   (`LSUIElement=1`, `CFBundleIdentifier=dev.tongwu.PiMenuBar`).
3. `Makefile`: `build`, `bundle` (assemble `PiMenuBar.app`), `run`, `install`
   (`~/Applications`), `uninstall`, `test`.
4. Static `NSStatusItem` showing `π`.
5. Freeze `registry v1` here (this doc, §4.1) as the contract both sides code against.

**Accept:** `make run` puts `π` in the menu bar with an empty dropdown listing
`no sessions`; `make test` runs an empty-but-green test suite.

### P1 — pi-side publisher
1. `extensions/session-status.ts`: config load, atomic write, heartbeat, full event
   table (§6.1), `session_shutdown` cleanup.
2. `/menubar status|dump|simulate|clear|doctor`.
3. `tests/session-status.test.ts`: atomic-write helper, staleness math, state
   machine transitions driven by synthesized events (pure functions extracted for this).
4. `dev/fake-sessions.sh N` writes N plausible registry files with distinct pids, varied
   states, and staggered `updatedAt`.

**Accept:** `/menubar dump` matches the schema; `dev/fake-sessions.sh 6` produces six
files the app can read; `kill -9` of a pi process removes its row after `staleAfterMs`.

### P2 — App reads the registry (no herdr yet)
1. `RegistryFile`, `RegistryWatcher`, `SessionStore` (registry-only path).
2. `TitleFormatter` + `StatusItemController`.
3. `MenuBuilder` with grouping by `cwd`, rows, submenu, footer.
4. `swift test` for `TitleFormatter` and merge/staleness rules.

**Accept:** with `dev/fake-sessions.sh 6`, the title reads `π 2▶1!1○2·`, the dropdown
lists all six with model/tool/elapsed, `Quit` works, no polling-induced CPU spin
(idle CPU < 1%).

### P3 — herdr integration
1. `HerdrProtocol` (Codable), `HerdrClient` (snapshot, subscribe, backoff, protocol
   guard, debounce, safety-net poll).
2. Merge herdr rows with registry rows on `sessionFile` / `paneId` (§4.3).
3. `Focuser` with the `agent focus` chain; `unseen` clearing.

**Accept:** the row for a real second pi session in another pane appears and tracks
`working → blocked → idle` within ~1 s of each transition; clicking a row focuses that
pane; `herdr server stop` degrades to registry-only without a crash or a menu bar
hang; `herdr server` restart reconnects within 5 s.

### P4 — Polish and packaging
1. Coloured `attributedTitle`, two-column `NSMenuItem.view` rows, `Show details…`
   window, accessibility labels.
2. Config file honoured end to end; `showIdle`, `hideWhenEmpty`, `maxRows`,
   `showNonPiAgents`.
3. Logging to `~/Library/Logs/PiMenuBar.log` + `Open log` menu item; `logLevel`.
4. `make install` → `~/Applications/PiMenuBar.app` + `LaunchAgent` plist
   (`RunAtLoad=true`, `KeepAlive=false`) so it survives logout; single-instance check.
5. README section, screenshots, and a "how to read the glyphs" table.

**Accept:** reboot (or logout/login) → item present with correct counts; two launches
do not create two items; logs rotate/truncate at a sane size.

### P5 — Optional enrichments (pick per taste)
1. Push context % into herdr so the terminal UI benefits too:
   `pane.report_metadata --source pi-session-status --token ctx=42% --state-label …`
   (note: `herdr-agent-state.ts` already owns `--state-label`; use distinct token names
   only, and never `--title`, to avoid fighting the install/update of that file).
2. Consume `pi.events.on("herdr:blocked")` (emitted by `pi-permission-system`, already
   used by `herdr-agent-state.ts`) for a precise blocked label like
   `Approve Bash: rm -rf …`.
3. Notification → focus: teach `notify-when-unfocused` to send the pane id so clicking
   the banner focuses that session (via `terminal-notifier -execute` or `-activate`).
4. Menu bar click-through: clicking the *item* (not a row) focuses the blocked session
   directly, when exactly one is blocked.
5. `done`-state hygiene: clear `unseen` when the pane becomes `focused` in herdr, so
   working in the terminal clears the `○`.

### P6 — Distribution (only if it should leave this machine)
1. `make dist` → zip of `PiMenuBar.app` + sha256. Unsigned locally-built apps are fine;
   a downloaded build needs `xattr -d com.apple.quarantine` or a Developer ID + notarize.
2. Optional Homebrew cask / `pi install` docs update.

---

## 9. Testing

**Automated**

| Layer | Tool | Covers |
|---|---|---|
| `PiMenuBarCore` | `swift test` | merge rules §4.3, staleness/GC, join-key fallbacks, `TitleFormatter` buckets and clamping, registry decode incl. malformed/unknown-version input |
| extension | `node --test tests/session-status.test.ts` | atomic write (no partial file ever visible), heartbeat scheduling, state machine transitions incl. nested `ui_prompt_start` coalescing, shutdown cleanup |
| protocol | `swift test` fixtures | recorded `session.snapshot` and event JSON (from Appendix A) decode correctly; unknown fields tolerated |

**Replayable fixtures** — capture real payloads once into `menubar/Tests/Fixtures/`:
`snapshot.json`, `pane_updated.json`, `pane_agent_status_changed.json`,
`subscription_started.json`. These are the regression net for herdr protocol drift.

**Manual matrix** (run per release; P2–P4)

| Case | How | Expect |
|---|---|---|
| each state | `/menubar simulate blocked` etc., or a real run | correct glyph within 1 s |
| blocked → answered | `/nudge simulate` (existing command opens a real dialog) | `!` appears, disappears on answer |
| unseen-done | let a run settle, don't touch the terminal | `○` |
| seen | click the row | `○` → `·`, pane focused |
| many sessions | `dev/fake-sessions.sh 24` | title stays short, menu groups, `maxRows` respected |
| non-herdr session | run pi in a bare Ghostty window | row appears from registry alone; focus is app-level only |
| herdr down | `herdr server stop`, then start | degrades, then recovers ≤5 s |
| app restart | quit + `make run` | rows repopulate instantly from disk + snapshot |
| pi crash | `kill -9 <pid>` | row disappears after `staleAfterMs`, no ghost |
| malformed registry | write `{"v":1,` into a file | skipped, one log line, no crash |
| appearance | light/dark, reduce-transparency, menu bar overflow | readable, glyphs still distinguish states |

**Non-flakiness rule:** no test may depend on wall-clock sleeps ≥ 1 s; inject a clock
into the merge/staleness code instead.

---

## 10. Risks and mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | `pane.updated` is emitted per output revision (verified 106→107 in seconds) → CPU/UI thrash | high | Do not subscribe (D6); per-pane `pane.agent_status_changed` instead; if a fallback is ever needed, throttle to 1 Hz and coalesce renders to ≤4 Hz |
| R2 | Events are lossy (no id/seq, no replay) → a missed transition leaves a stale glyph | high | Snapshot is ground truth; unconditional 30 s re-snapshot; re-snapshot on reconnect and on every structural event |
| R3 | herdr protocol drift (`protocol: 22` today) | medium | Protocol guard → registry-only mode + visible warning; Codable ignores unknown fields; replayable fixtures catch decoder breakage |
| R4 | Menu bar space: many sessions, notch, other status items | medium | Title is a fixed-width-ish summary, never per-session; `maxRows`; item can be hidden when empty; document Cmd-drag reordering |
| R5 | Join failures (registry and herdr rows don't match) → duplicate rows | medium | Deterministic key chain (§4.3), fallback to `paneId`; duplicates are cosmetically bad but never lost data; unit-tested |
| R6 | Two state reporters to herdr (`herdr-agent-state.ts` + ours) fight over `--state-label`/title | medium | We never call `pane.report_agent`; P5 metadata uses distinct `--token` names only, never `--title`/`--state-label` |
| R7 | `agent focus` also marks the agent seen — clicking can silently clear herdr's Done badge the user wanted to keep | low (intended, but surprising) | Document it; `Mark seen` is an explicit submenu action and the row tooltip says "focus and mark seen" |
| R8 | Duplicate status items from two launches | low | Single-instance check (pidfile `flock` in `~/Library/Application Support/PiMenuBar/`); `open -a` for normal launches |
| R9 | LSUIElement app has no window/Dock → silent failures are invisible | medium | Log file + `Open log` menu item + `doctor` in the extension; failures degrade to fewer rows, never a crash loop |
| R10 | Stale registry files accumulate | low | Delete on shutdown + pid-liveness check + age GC on the app side |
| R11 | Locally built `.app` blocked by Gatekeeper when moved between machines | low | Unsigned is fine when built locally; document `xattr -d com.apple.quarantine`; notarize only if distributed (P6) |
| R12 | Reading a registry file mid-write | low | atomic `write` + `rename` (D4) |
| R13 | A headless (`pi -p`) run publishing a row the user never sees again | low | `mode` recorded; optional `hideHeadless` config; headless rows still clean up on process exit |

---

## 11. Open decisions (O1 is the only one that blocks P1)

| # | Question | Recommendation |
|---|---|---|
| O1 | Home: this repo (`menubar/`) or a new repo `pi-menubar`? | **This repo** (D8): one schema/version, no drift, `pi install` unaffected because `package.json#files` ships only `extensions/`. A separate repo is the better choice only if the app gets its own release cadence and notarized binary distribution. |
| O2 | Title style: per-state counts (`π 1!2▶`) vs one glyph per session (`π !▶▶·`) | Counts — bounded width regardless of session count. |
| O3 | Icon: text `π` vs SF Symbol vs custom template image | Text `π` in v1 (matches pi's own title marker and needs no asset pipeline); revisit in P4. |
| O4 | Include non-pi herdr agents (claude/codex/…) | Yes, behind `showNonPiAgents: false` (the snapshot already carries them for free). |
| O5 | Should clicking the item itself focus the single blocked session? | Yes in P5 — it is the highest-value interaction and costs ~15 lines. |
| O6 | Should the extension delete its file on `session_shutdown` or leave it for the app to GC? | Delete on shutdown (fast cleanup) **and** GC in the app (crash safety). |

---

## Appendix A: raw evidence

Verbatim commands run while writing this plan, so any claim above can be re-checked.

**A.1 Toolchain** — `xcrun --show-sdk-path` → `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`;
`swift build` on a minimal SwiftPM executable → `Build complete! (15.23s)`; Swift 6.3.3,
`node --version` → `v26.9.0`.

**A.2 Cross-session state**
```console
$ herdr agent list
{"id":"cli:agent:list","result":{"agents":[
 {"agent":"pi","agent_status":"working","cwd":"/Users/tongwu/Downloads/project/pi-notify-when-unfocused",
  "focused":true,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1",
  "terminal_title":"π - pi-notify-when-unfocused","revision":2,"state_change_seq":233,
  "agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/Users/tongwu/.pi/agent/sessions/…jsonl"}},
 {"agent":"pi","agent_status":"idle",   "pane_id":"w1:p2","cwd":"…/jev-sts2",  …},
 {"agent":"pi","agent_status":"working","pane_id":"w1:p9","cwd":"…/mobile_pda",
  "state_labels":{"working":"⏳ 2 subagents (worker)"},"tokens":{"title-suffix":"⏳2"}}]}}
$ herdr api snapshot   # keys: version protocol focused_workspace_id focused_tab_id focused_pane_id
                       #       workspaces tabs panes layouts agents   (protocol 22, herdr 0.9.1)
```

**A.3 Subscribe + real events** (12 s window while another pane streamed output)
```
EVT {"id":"s1","result":{"type":"subscription_started"}}
EVT {"data":{"pane":{…,"agent_status":"working","pane_id":"w1:p9","revision":106,…}},"event":"pane.updated"}
EVT {"data":{"agent":"pi","agent_status":"working","pane_id":"w1:p9","workspace_id":"w1"},"event":"pane.agent_status_changed"}
EVT {"data":{"pane":{…,"revision":107,…}},"event":"pane.updated"}
EVT {"data":{"agent":"pi","agent_status":"working","pane_id":"w1:p9",
      "state_labels":{"done":"⏳ 1 subagent (worker)","idle":"⏳ 1 subagent (worker)",
                      "working":"⏳ 1 subagent (worker)"},"workspace_id":"w1"},
      "event":"pane.agent_status_changed"}
```
Note the absence of any id/seq on event envelopes, and two `pane.updated` events within
seconds driven purely by terminal output revisions (R1, R2).

**A.4 One connection per purpose**
```
$ # subscribe on a connection, then send session.snapshot on the SAME connection
SNAP request → no response.   # only {"id":"t:sub","result":{"type":"subscription_started"}} arrived
$ # same snapshot on a FRESH connection
SNAP q1 version,protocol,focused_workspace_id,focused_tab_id,focused_pane_id,workspaces,tabs,panes,layouts,agents
```

**A.5 Schema-derived subscription requirements** (from `herdr api schema --json`, 276 851 bytes)
```
pane.agent_status_changed  required=[type, pane_id]
pane.scroll_changed        required=[type, pane_id]
pane.output_matched        required=[type, pane_id, source, match]
pane.updated / tab.focused / workspace.focused / layout.updated …  required=[type]
# 27 subscription kinds total; AgentStatus enum = idle | working | blocked | done | unknown
# EventsSubscribeParams { subscriptions: [Subscription] }; EventsWaitParams { match_event, timeout_ms }
```

**A.6 Focus primitives**
```console
$ herdr pane focus --help        # "Focus a neighboring pane" — --direction <left|right|up|down> only
$ herdr agent focus nope:pX
{"error":{"code":"agent_not_found","message":"agent target nope:pX not found"},"id":"cli:agent:focus"}
$ herdr agent get w1:p1          # pane ids are valid agent targets
$ herdr --skill | sed -n '59p'
… explicit focus commands mark the target seen, while reads do not. …
```

**A.7 Existing pi→herdr reporter** — `~/.pi/agent/extensions/herdr-agent-state.ts`
(`HERDR_INTEGRATION_ID=pi`, `HERDR_INTEGRATION_VERSION=9`, header says it is managed by
herdr and overwritten on reinstall): subscribes to `session_start` / `agent_start` /
`agent_settled` and `pi.events.on("herdr:blocked")`, then sends
`pane.report_agent` / `pane.report_agent_session` over the same socket with a monotonic
`seq`. This is why `agent_status` and `state_labels` are already populated for pi panes,
and why our extension must not duplicate that reporting (R6).

**A.8 pi UI surface** — `docs/extensions.md:2600` ("Widgets, Status, and Footer"),
`docs/tui.md:768`, `dist/core/extensions/types.d.ts:81` (`setStatus(key, text)`), and
`docs/extensions.md:998` (fire-and-forget methods incl. `setStatus`) — all terminal-only;
no macOS menu bar API exists.
