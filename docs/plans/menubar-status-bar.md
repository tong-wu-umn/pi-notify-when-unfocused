# macOS menu bar status bar for pi sessions — implementation plan

| | |
|---|---|
| Branch | `menubar-status-bar` (off `main`) |
| Status | Plan / not started |
| Author | planning session, 2026-09-21 |
| Last reviewed | architecture revision 3 (post-implementation), 2026-09-21 |
| Status | **Implemented** — see [§12 Implementation record](#12-implementation-record) for what changed against this plan |
| Scope | A macOS menu bar (`NSStatusItem`) that shows brief, essential info about active interactive pi sessions and focuses the right pane on click. |

---

## 1. Goal and non-goals

**Goal.** One glance at the macOS menu bar tells you what your interactive pi
sessions are doing: how many are working, which one is *blocked waiting on you*, and
which one finished while you were away. Opening the menu shows the project, model,
elapsed time, active tools, and context usage. Clicking a row brings that session's
terminal pane back to the front and acknowledges a completed session.

V1 tracks TUI sessions by default. Long-lived RPC sessions can be opted in later via
`includedModes`; short-lived `print`/`json` invocations are excluded by default so the
menu does not flicker for one-shot commands.

**Non-goals**

- Not a replacement for `notify-when-unfocused` (that stays the "you are away, here
  is a banner" channel). This is the glanceable, always-present channel. (PiMenuBar-owned
  native notifications are a later, opt-in third option — see
  [menubar-native-notifications.md](menubar-native-notifications.md) — and are meant to
  replace the terminal-transport channel rather than run beside it.)
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
| 8 | `pane.updated` fires on **every output revision** (revisions 106→107 within seconds on a working pane). It must be throttled or avoided. Also: the real event name is `pane_updated` (underscore), not `pane.updated`. | Appendix A.3, A.9 |
| 9 | `pane.agent_status_changed` is low-frequency but needs an explicit `pane_id` per subscription, and carries only a small payload. | Appendix A.5 |
| 10 | `herdr agent focus <pane_id>` resolves absolute targets (`agent get w1:p1` works; `agent focus nope:pX` → `agent_not_found`). `herdr pane focus` is **directional only** (`--direction left|right|up|down`) and cannot target a specific pane. | Appendix A.6 |
| 11 | An explicit focus command **marks the agent seen** (done → idle). Clicking a row is therefore also "acknowledge". | `herdr --skill`, line 59 |
| 12 | A pi extension can already report state to herdr today: `~/.pi/agent/extensions/herdr-agent-state.ts` (installed by herdr, `HERDR_INTEGRATION_VERSION=9`) sends `pane.report_agent` / `pane.report_agent_session` on `session_start` / `agent_start` / `agent_settled` and a `herdr:blocked` event. | file read, Appendix A.7 |
| 13 | Extra display metadata can be pushed from pi: `pane.report_metadata` with `--title`, `--display-agent`, `--state-label <STATUS=TEXT>`, `--token <NAME=VALUE>`, `--ttl-ms`. | `herdr pane report-metadata --help`, schema `PaneReportMetadataParams` |
| 14 | Node 26 runs TypeScript test files directly (`node --test tests/*.test.ts`), so pi-side tests need no build step. | `node --version` → v26.9.0 |
| 15 | herdr mixes separators in event names: `pane_updated`, `pane_focused`, `tab_focused`, `workspace_focused` use underscores while `pane.agent_status_changed` uses dots. Matching must normalize the first separator. | Appendix A.9 |
| 16 | `state_change_seq` exists only on `agents[]` in a snapshot — not on `panes[]` and not on any event payload — so completion acknowledgement needs a re-snapshot on status changes. | Appendix A.10 |
| 17 | `agents[].tokens` and `agents[].state_labels` are absent for panes with no title suffix, so they must decode as optional. | Appendix A.10 |
| 18 | Events are sparse when the fleet is quiet: a 22-subscription stream produced **zero** events in a 2-minute idle window. The initial snapshot plus the safety poll is what keeps the display correct, not the event rate. | Appendix A.11 |
| 19 | Command Line Tools ships **no XCTest and no Testing module**, so `swift test` cannot link without Xcode. | Appendix A.12 |

**Additional operational constraint.** An app launched by LaunchServices or a
LaunchAgent does not inherit the shell environment of a terminal pane. The app must
not rely on `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, or the shell's `PATH` being present.
Socket discovery and focus therefore need explicit, non-shell fallbacks (§6.2, §6.6).

**Consequence.** The status bar consumes two independent sources:

1. **herdr** — authoritative, cross-session, event-driven, works even if the pi-side
   extension is broken or absent; only available inside herdr.
2. **A pi extension + registry file** — richer per-session detail (model, thinking,
   context %, active tools, completion time), the *only* source outside herdr, and the
   merge key that ties the two together.

Neither source writes the other's state. The app merges them and owns acknowledgement
("seen") state separately so a heartbeat can never resurrect an acknowledged item.

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
│                                    Focuser: socket        │
│                                    `agent.focus` request  │
└───────────────────────────────────────────────────────────┘
```

### Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Native Swift `NSStatusItem` app, not SwiftBar/xbar/rumps | SwiftBar is not installed and is poll-only; a Swift app gets push updates, rich dropdown rows, and click-to-focus with no third-party runtime. CLT-only build verified (fact 3). |
| D2 | Two sources, merged in the app; acknowledgement is app-owned | herdr survives a broken extension; the registry works outside herdr and supplies detail. A separate acknowledgement store prevents the extension heartbeat from reasserting "unseen" after a click. |
| D3 | Join on the **pi session file path** (`registry.sessionFile` ↔ `herdr.agent_session.value` where `kind == "path"`), fallback `pane_id`, then `pid + processStartedAt` | herdr reports the same JSONL path available from `ctx.sessionManager.getSessionFile()`. `processStartedAt` prevents PID reuse from joining unrelated processes. Unmatched rows are shown, never dropped. |
| D4 | Registry = one file per pi process, monotonic `revision`, `updatedAt` heartbeat, atomic `rename`, mode `0600` in a `0700` directory | Independent writers, deterministic ordering, no partial reads, privacy for cwd/prompt metadata, and crash tolerance. A `kill -9`'d process simply stops heartbeating and ages out. |
| D5 | Snapshot is ground truth; events are deltas; connect uses snapshot → subscribe → snapshot | Events carry no id/seq and are not replayed. The second snapshot closes the race between the first snapshot and subscription acknowledgement. |
| D6 | Subscribe to `pane.agent_status_changed` per agent pane plus focus/detection/structural events; **do not** subscribe to `pane.updated` in v1 | `pane.updated` fires per output revision (fact 8). New/detected panes trigger a re-snapshot and subscription rebuild. |
| D10 | Normalize event names before matching | herdr 0.9.1 mixes `pane_updated` and `pane.agent_status_changed` (fact 15); only the first separator is canonicalized so `agent_status_changed` survives. |
| D11 | Re-snapshot on `pane.agent_status_changed` | The event carries no `state_change_seq` (fact 16), which completion acknowledgement needs. Status changes are low frequency. |
| D7 | Focus via socket request `agent.focus {target: paneId}`, not a `herdr` subprocess | It is the same absolute primitive as the CLI, marks the target seen, and works when a login app has no shell `PATH`. |
| D8 | Keep the implementation in this repo, but as a **separate install surface** under `menubar/` | Adding another file under root `extensions/` would silently load it for every existing `pi-notify-when-unfocused` user because the package discovers that directory. `menubar/extension/` is installed only by the menu-bar installer; the root pi package remains notification-only. |
| D9 | V1 connects to one local herdr server | Socket discovery precedence: explicit config → fresh registry entries → app environment → `~/.config/herdr/herdr.sock`. Multiple distinct live sockets produce a warning instead of silently merging servers. |

---

## 4. Data contracts

### 4.1 Registry file (pi side) — `registry v1`

Location: `~/.pi/agent/menubar/sessions/<pid>.json` (override: `PI_MENUBAR_REGISTRY_DIR`).
Filename is the **pid**, so a restarted or forked session never clobbers another
process's file; the old file is GC'd as stale.

```jsonc
{
  "v": 1,
  "revision": 1758450000123001,                  // Date.now()*1000 seed + increments; survives reload
  "pid": 85713,
  "processStartedAt": 1758449800000,              // rounded Date.now()-process.uptime(); stable across reload
  "sessionId": "01a0c3d1-bbc8-74d6-bc36-64188b9b4974",
  "sessionFile": "/Users/tongwu/.pi/agent/sessions/--…--/2026-09-21T11-54-57-353Z_01a0c3d1-….jsonl",
  "sessionName": "menu bar work",                 // optional; from getSessionName()/session_info_changed
  "cwd": "/Users/tongwu/Downloads/project/pi-notify-when-unfocused",
  "project": "pi-notify-when-unfocused",
  "mode": "tui",
  "state": "blocked",                             // idle | working | blocked
  "stateLabel": "Approve or reject — Bash command",
  "blockedKind": "confirm",                       // select|confirm|input|editor|custom
  "model": "deepseek-flash",
  "provider": "deepseek",
  "thinking": "high",
  "contextTokens": 84213,
  "contextWindow": 200000,
  "turnIndex": 12,
  "activeTools": [
    { "id": "call_1", "name": "bash", "startedAt": 1758449999999 },
    { "id": "call_2", "name": "read", "startedAt": 1758450000000 }
  ],
  "lastTool": "read",
  "runStartedAt": 1758449900000,
  "waitingSince": 1758450000000,
  "settledAt": null,                               // set only after agent_settled; cleared on agent_start
  "hasPendingMessages": false,                    // ctx.hasPendingMessages(), not a count
  "lastUserPrompt": null,                         // omitted by default; opt-in, sanitized, ≤120 chars
  "terminalBundleId": "com.mitchellh.ghostty",
  "herdr": {
    "paneId": "w1:p1",
    "workspaceId": "w1",
    "tabId": "w1:t1",
    "socketPath": "/Users/tongwu/.config/herdr/herdr.sock"
  },
  "updatedAt": 1758450000123,
  "simulated": false,                             // optional dev-only marker
  "expiresAt": null                               // required when simulated=true; epoch ms
}
```

All timestamps are integer milliseconds since the Unix epoch. `revision` is a
monotonic ordering token, not a timestamp: seed it from `Date.now() * 1000` and
increment so a reloaded extension cannot publish a lower revision than its predecessor.

There is deliberately no registry `unseen` boolean. The app derives completion
attention from `settledAt` and its own acknowledgement timestamp (§4.3). Otherwise a
heartbeat from an idle extension would immediately resurrect a row the user had just
acknowledged.

Write rules:

- **Private and atomic**: create the directory with mode `0700`; write a mode-`0600`
  `<pid>.json.tmp.<rand>` and `rename()` over the target. The payload is small, so the
  extension uses synchronous write+rename to preserve event order without an async
  write queue. Increment `revision` before each publish.
- **When**: publish on every meaningful transition (§6.1) plus a `heartbeatMs` timer
  (default 15 s) that bumps `updatedAt`. `unref()` the timer so it never keeps pi open.
- **On shutdown/reload/session replacement**: the idempotent `session_shutdown`
  handler clears the timer and deletes the file. This is best-effort; signals and hard
  crashes are covered by staleness, not assumed to emit shutdown.
- **Privacy**: omit prompt previews by default (`includePromptPreview=false`). Any
  displayed string is control-character stripped, whitespace-collapsed, and capped.
- **Reader GC**: ignore rows older than `staleAfterMs`; remove final and temp files
  older than 10 × `staleAfterMs`. PID checks may accelerate cleanup after staleness,
  but never override a fresh heartbeat (PID reuse makes PID alone unsafe).
- **Compatibility**: unknown `v` values are ignored with one rate-limited log entry.

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
| `pane.focused`, `pane.agent_detected` | — | focus/agent set changed → re-snapshot and rebuild subscriptions |
| `pane.created`, `pane.closed`, `pane.moved`, `pane.exited` | — | structural → re-snapshot |
| `tab.focused`, `tab.created`, `tab.closed`, `tab.renamed`, `tab.moved` | — | structural / focus |
| `workspace.focused`, `workspace.created`, `workspace.closed`, `workspace.renamed`, `workspace.moved`, `workspace.reordered` | — | structural / focus |
| `layout.updated` | — | splits/zoom — ignore for v1 (layout is not rendered) |
| `pane.updated` | — | **do not subscribe in v1** (per-revision chattiness, fact 8); the 30 s safety snapshot covers metadata that has no low-frequency event |

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

1. Discover one socket using D9; a login app must not assume terminal environment.
2. Open connection A → `session.snapshot` → close.
3. Build per-pane subscriptions from that snapshot. Open connection B →
   `events.subscribe` → wait for `subscription_started`.
4. Immediately run a second `session.snapshot` on a fresh connection. This closes the
   snapshot/subscribe race: pre-ack changes are in snapshot 2; post-ack changes stream.
5. Subscribe to `pane.focused`, `pane.agent_detected`, pane lifecycle, tab focus/lifecycle,
   workspace focus/lifecycle, and one `pane.agent_status_changed` per known agent pane.
   Detection/lifecycle changes cause a debounced re-snapshot and subscription rebuild.
6. On disconnect: exponential backoff 500 ms → 5 s with jitter. Safety-net snapshot
   every `pollIntervalMs` (default 30 s), because events are lossy.
7. Bound newline frames (8 MiB), connection/request timeouts, and buffered bytes; a
   malformed or oversized frame tears down only that connection and triggers retry.
8. V1 supports protocol **22 exactly**. A different protocol runs registry-only and
   shows a warning. Do not assume a numerically newer protocol is compatible.

### 4.3 Merged session model (in the app)

```swift
struct Session: Sendable {
  let key: String            // sessionFile ?? "herdr:<paneId>" ?? "pid:<pid>:<startedAt>"
  var source: Source         // .herdrAndRegistry | .herdr | .registry
  var project, cwd: String
  var sessionFile, sessionId, sessionName: String?
  var state: SessionState    // .working .blocked .idle .done .unknown
  var needsAttention: Bool   // derived, never written by the extension
  var model, thinking: String?
  var contextTokens, contextWindow: Int?
  var stateLabel: String?    // registry label, else herdr label/token summary
  var activeTools: [ActiveTool]
  var runStartedAt, waitingSince, settledAt: Date?
  var lastUserPrompt: String?
  var herdr: HerdrRef?       // paneId, tabId, workspaceId, tabLabel, workspaceLabel, focused
  var focused: Bool
  var updatedAt: Date
}
```

Acknowledgements live at
`~/Library/Application Support/PiMenuBar/acknowledgements.json` (directory `0700`,
file `0600`, atomically replaced). Each session key stores
`{ acknowledgedAt, herdrStateChangeSeq? }`. They are app-owned, survive restarts, and
are pruned after 30 days. The herdr sequence acknowledges one specific completion
generation; the timestamp handles registry-only `settledAt`.

Merge rules (deterministic, unit-testable):

1. Rows are the union of both sources, joined by session file, then pane id, then
   `pid + processStartedAt` (D3).
2. A herdr snapshot is fresh until `2 × pollIntervalMs`. While fresh, its
   `agent_status` wins; otherwise use registry state. Map herdr `done` → `.done` and
   `unknown` → `.unknown`.
3. `needsAttention` is always true for an unfocused blocked session. A herdr `done`
   row needs attention when its `state_change_seq` differs from the acknowledged
   sequence. A registry-only idle row needs attention when `settledAt > acknowledgedAt`.
   Initial idle sessions with no `settledAt` do not. An acknowledged herdr `done` row
   is presented with the idle glyph until its next state change.
4. On successful focus, or when herdr reports the pane focused, store `now` and the
   current `state_change_seq`. This clears completed attention but not an active
   blocked state.
5. Detail fields (model, thinking, context usage, active tools, prompt preview, timings)
   come from the registry. `stateLabel` prefers the registry's blocked label, then
   herdr `state_labels[currentStatus]`, then `tokens.summary`. Missing values are
   omitted rather than rendered as ellipses; all external labels are sanitized.
6. `project` = registry project ?? `basename(herdr.cwd)`; `sessionName`, when present,
   is the preferred row label and project remains secondary.
7. Registry-only rows older than `staleAfterMs` vanish; herdr rows vanish on the next
   snapshot after the agent disappears.
8. `focused` comes from herdr when known; otherwise false. A successful non-herdr
   app-activation click acknowledges but cannot prove pane focus.

Aggregates: `blockedCount`, `workingCount`, `completedAttentionCount`, `idleCount`,
`total`, plus `oldestWaitingSince` for the tooltip.

---

## 5. Repository layout

```
pi-notify-when-unfocused/
├─ extensions/
│  └─ notify-when-unfocused.ts          existing root package; unchanged
├─ menubar/                             NEW, separately installed product
│  ├─ Package.swift                     macOS 13+, SwiftPM core lib + AppKit executable
│  ├─ Makefile                          build/bundle/run/install/uninstall/test
│  ├─ Resources/Info.plist              LSUIElement=1, bundle id, version
│  ├─ extension/
│  │  ├─ index.ts                       auto-discovered pi publisher (§6.1)
│  │  ├─ state.ts                       pure state/schema helpers
│  │  └─ state.test.ts                  node --test
│  ├─ Sources/PiMenuBarCore/            Foundation only; testable
│  │  ├─ Models.swift
│  │  ├─ RegistryFile.swift
│  │  ├─ AcknowledgementStore.swift
│  │  ├─ HerdrProtocol.swift
│  │  ├─ SessionStore.swift
│  │  └─ TitleFormatter.swift
│  ├─ Sources/PiMenuBar/                AppKit / socket I/O
│  │  ├─ main.swift
│  │  ├─ AppDelegate.swift
│  │  ├─ StatusItemController.swift
│  │  ├─ MenuBuilder.swift
│  │  ├─ HerdrClient.swift
│  │  ├─ RegistryWatcher.swift
│  │  ├─ Focuser.swift
│  │  ├─ Config.swift
│  │  └─ Log.swift
│  ├─ Tests/PiMenuBarCoreTests/
│  └─ dev/fake-sessions.sh
└─ docs/plans/menubar-status-bar.md
```

The root `package.json` and root `extensions/` discovery remain unchanged. For
development, `make install-extension` symlinks the `menubar/extension/` directory as
`~/.pi/agent/extensions/pi-menubar/` (whose `index.ts` is auto-discovered); release
installation copies the directory. Existing pi sessions need `/reload` once after
install/uninstall. This avoids imposing heartbeat
writes on users who installed only the notification extension.

---

## 6. Component specifications

### 6.1 pi extension — `menubar/extension/index.ts`

Single responsibility: keep one private registry file current. No rendering and no
herdr reporting in the core path.

Config load follows the existing house style in `notify-when-unfocused.ts`:
`~/.pi/agent/menubar.json`, `PI_MENUBAR_*` overrides, malformed config → defaults,
never throw at load. Default `includedModes=["tui"]`; other modes return before
creating a file.

State updates:

| Event | Effect |
|---|---|
| `session_start` | idempotently clear old timer/file; refresh session id/file/name and all `ctx` fields; initialize `agentActive = !ctx.isIdle()` and derived state (important on `/reload`); clear prompt/tool state; start heartbeat |
| `session_info_changed` | update `sessionName` |
| `before_agent_start` | optional sanitized preview from final expanded `event.prompt`; update `hasPendingMessages` |
| `agent_start` | `agentActive=true`, `state=working`, `runStartedAt=now`, clear `waitingSince`, `settledAt`, and stale active tools |
| `ui_prompt_start` | set `promptOpen=true`; `state=blocked`, `waitingSince=now`, kind/label. Pi already coalesces nested prompts, so a boolean is sufficient |
| `ui_prompt_end` | clear `promptOpen`/waiting metadata; recompute to working or idle from `agentActive` |
| `tool_execution_start` | add/replace `activeTools[event.toolCallId] = {event.toolName, startedAt}` (parallel tools are supported) |
| `tool_execution_end` | remove by `toolCallId`; set `lastTool=event.toolName`; keep other active tools |
| `turn_start` / `turn_end` | update `turnIndex`; refresh `ctx.getContextUsage()` and `ctx.hasPendingMessages()` |
| `message_end` | refresh context usage only; user prompt preview comes from `before_agent_start`, not raw pre-transform input |
| `model_select`, `thinking_level_select` | update model/provider/context window/thinking |
| `agent_settled` | if `ctx.isIdle()`: `agentActive=false`, `state=idle`, `settledAt=now`, clear active tools, refresh usage/pending flag |
| `session_shutdown` | idempotently clear timer and delete own file |

Every transition publishes synchronously and atomically with an incremented revision.
String fields are sanitized. The extension never infers an error from undocumented
assistant stop-reason shapes; error/outcome display is deferred until pi exposes a
stable event contract.

Commands — `/menubar`:

| Subcommand | Behaviour |
|---|---|
| `status` | registry path, revision, current state, config/mode, app lock-file presence |
| `dump` | show the exact JSON on disk |
| `simulate <idle\|working\|blocked\|completed> [seconds]` | apply an expiring presentation override (default 15 s) while real events continue updating underneath; expiry republishes the latest real state |
| `clear` | delete and immediately republish the real state (avoids a misleading permanent disappearance) |
| `doctor` | directory permissions, discovered socket candidates/protocol, app/extension install paths |

It does **not** call `pane.report_agent` or `pane.report_metadata`; the managed
`herdr-agent-state.ts` owns herdr reporting. It does not send notifications.

### 6.2 `HerdrClient`

- Discovers a socket using D9; does not depend on inherited environment or a herdr
  executable. Registry paths must be absolute sockets owned by the current uid.
- Uses short-lived request sockets for `session.snapshot`, `agent.focus`,
  `workspace.focus`, and `tab.focus`; a separate long-lived socket owns the event
  stream. All use newline framing and bounded buffers/timeouts.
- Performs snapshot → subscribe/ack → snapshot (§4.2), then rebuilds per-pane
  subscriptions when detection/lifecycle events change the agent set.
- Decodes hand-written tolerant `Codable` structs from protocol-22 fixtures; unknown
  JSON fields are ignored, but an unknown protocol number disables herdr integration.
- Structural/focus events coalesce into one re-snapshot at ≥300 ms spacing. Backoff is
  500 ms → 5 s with jitter; transitions are logged without flooding.
- Socket parsing and file I/O run off-main. Immutable `Sendable` values are delivered
  to an `@MainActor SessionStore`, satisfying Swift 6 strict concurrency rather than
  relying on ad-hoc locking.

### 6.3 `RegistryWatcher`

- Opens the registry directory with `O_EVTONLY` and watches `.write/.rename/.delete`
  via `DispatchSource`; reopens the watch if the directory itself is replaced.
- Debounces rescans by 100 ms. A 30 s safety rescan also expires stale rows; there is
  no 2 s polling loop. Elapsed-time labels update at 1 Hz only while the menu is open.
- Uses `lstat`, accepts only current-user regular files (not symlinks), ignores temp
  files, validates mode/version/revision, and skips malformed files with rate-limited
  logging. Creates the directory as `0700`. Expired `simulated` rows are ignored.
- Applies only the highest observed revision for a process identity. Atomic rename
  means normal readers never see partial JSON.

### 6.4 `SessionStore`

Pure merge (§4.3) plus acknowledgement persistence. `PiMenuBarCore` has no AppKit
dependency and is covered by `swift test`. `SessionStore` is `@MainActor`; watcher and
socket callbacks submit immutable snapshots to it. Change detection excludes heartbeat-only
`updatedAt` changes so idle heartbeats do not rebuild the menu.

### 6.5 `StatusItemController` / `MenuBuilder`

- `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`,
  `button.attributedTitle` for colour, `button.toolTip` for the full summary.
- The item stays visible by default even with zero sessions (`π` dimmed), because an
  LSUIElement app otherwise has no Dock/menu route to Config or Quit. `hideWhenEmpty`
  is an explicit opt-in.
- Rebuilds the title only on semantic store changes (coalesced to ≤4 Hz).
- Menu is rebuilt lazily via `NSMenuDelegate.menuNeedsUpdate`; duration text refreshes
  while open without replacing highlighted menu items.
- V1 uses plain accessible `NSMenuItem` titles such as
  `▶ project — bash +1 · 12m · model · 42%`. Custom row views are deferred because
  they complicate keyboard navigation and accessibility.

### 6.6 `Focuser`

| Case | Action |
|---|---|
| herdr pane + live socket | request `agent.focus {target: paneId}`; on `agent_not_found`, request workspace then tab focus as a partial fallback; afterward activate the host terminal app using the row's registry bundle id or configured/learned fallback |
| no herdr, `terminalBundleId` present | activate a matching `NSRunningApplication` (best effort when several windows/processes exist; app-level only, tab cannot be targeted) |
| pane focus succeeds but app activation is unavailable | report partial success: herdr selected/acknowledged the pane, but macOS could not bring a host app forward |
| neither | offer explicit `Mark completed seen`; log and show "cannot focus precisely" |

A successful `agent.focus` stores the current herdr acknowledgement even if host-app
activation is partial, because herdr itself already marked the target seen. A
registry-only acknowledgement is stored only after app activation succeeds or the
user explicitly chooses Mark seen. Learn `terminalBundleId` from fresh registry rows;
allow a config fallback for herdr-only rows. De-duplicate clicks within 500 ms and
never block the main actor.

### 6.7 Config — `~/.pi/agent/menubar.json`

Shared file; the app reads all keys, the extension reads its own and ignores the rest.

```json
{
  "enabled": true,
  "includedModes": ["tui"],
  "registryDir": "~/.pi/agent/menubar/sessions",
  "heartbeatMs": 15000,
  "staleAfterMs": 90000,
  "includePromptPreview": false,
  "showIdle": true,
  "hideWhenEmpty": false,
  "maxRows": 20,
  "pollIntervalMs": 30000,
  "herdrSocketPath": null,
  "terminalBundleId": null,
  "ackRetentionDays": 30,
  "logLevel": "info"
}
```

Extension env overrides: `PI_MENUBAR_ENABLED`, `PI_MENUBAR_REGISTRY_DIR`,
`PI_MENUBAR_DEBUG=1`. Both implementations expand `~`, require absolute resolved
paths, and clamp intervals/row counts. The app watches config and retains the last-good
value on a malformed edit; the extension reloads config only on pi `session_start`
(`/reload`, startup, or session replacement).

---

## 7. UX specification

### 7.1 Menu bar title

Compact by construction — menu bar space is the scarcest resource.

| Situation | Title |
|---|---|
| no sessions (default) | dim `π` — menu still exposes Config and Quit |
| no sessions, explicit `hideWhenEmpty: true` | item hidden |
| all idle | `π 3·` |
| one working, one blocked, one completed-attention | `π 1!1▶1○` |
| only idle but `showIdle: false` | `π 3` |
| > 9 in a bucket | clamp to `9+` |

Order and glyphs: `!` blocked, `▶` working, `○` completed-attention, `·` idle. Prefix `π`.

Colours (`attributedTitle`): blocked `NSColor.systemRed`, completed-attention `NSColor.systemOrange`.
The neutral states (working, idle, unknown) deliberately set **no** foreground colour:
AppKit re-tints a plain status item title for the menu bar's appearance but draws an
explicit `attributedTitle` colour verbatim, so `labelColor`/`secondaryLabelColor`
resolved against the app's appearance (Aqua in light mode) and came out black on a
dark-tinted menu bar. Omitting the attribute matches the neighbouring system items in
every appearance — the layout stays readable without colour too, which is why glyphs
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

- Sort: blocked (oldest wait first), completed attention, working (oldest run first),
  then idle (most recently updated). Within a herdr server, group workspace → tab;
  registry-only rows go under `Other terminals`.
- Plain row title: state glyph + session name/project + compact details
  (`tool +N · elapsed · model · ctx%`). Missing detail is omitted, never replaced by `…`.
- Row submenu: `Focus and acknowledge`, `Copy session path`, `Copy working directory`,
  `Show details…`, and `Mark completed seen` (disabled for blocked sessions).
- Focused sessions use a `•` marker but retain their submenu. If `maxRows` truncates,
  append a disabled `N more sessions…` item; aggregate counts still include all rows.
- V1 lists pi agents only. Other herdr agent types are a later opt-in feature, not part
  of the initial merge contract.
- Keyboard/accessibility: plain menu items, explicit labels, and no colour-only state.

---

## 8. Phases

Sequence by fastest user value: herdr already has the essential cross-session state,
so build a useful herdr-only menu before adding the richer registry publisher. Every
phase ends with something demonstrable.

### P0 — Skeleton and contracts
1. Re-run the confirmed toolchain checks (`swift build`, `node --test`).
2. `menubar/Package.swift` targeting macOS 13 with `PiMenuBarCore` + `PiMenuBar`;
   enable Swift 6 strict-concurrency checking immediately.
3. `Info.plist` (`LSUIElement=1`, `CFBundleIdentifier=dev.tongwu.PiMenuBar`) and
   `Makefile`: build, bundle, run, install-app, install-extension, uninstall, test.
4. Static `NSStatusItem` showing dim `π`, with About/Config/Quit when empty.
5. Freeze herdr protocol-22 fixtures, `registry v1`, and acknowledgement contracts.
6. Baseline tests for title formatting, acknowledgements, and recorded JSON decoding.

**Accept:** `make run` puts `π` in the menu bar; the empty menu is usable; `make test`
builds both Swift targets and runs non-placeholder tests.

### P1 — Herdr-backed MVP (useful without a new pi extension)
1. Implement bounded line framing, tolerant protocol-22 decoding, socket discovery
   (D9), snapshot → subscribe/ack → snapshot, reconnect, and safety resync.
2. Verify with a real transition that `state_change_seq` is stable across metadata-only
   updates and advances for a new completion; capture the fixture before using it as an
   acknowledgement generation.
3. Implement herdr-only `SessionStore`, persisted acknowledgements, `TitleFormatter`,
   menu grouping/sorting, and plain accessible rows.
4. Subscribe to pane status/focus/detection/lifecycle plus tab/workspace lifecycle;
   rebuild per-pane subscriptions when the agent set changes.
5. Focus with direct `agent.focus`, then activate the configured/learned host terminal.
6. Cover framing, timeout/EOF, ordering, merge, and acknowledgement in `swift test`.

**Accept:** the currently running pi panes appear with correct `working/blocked/done/idle`
counts; a transition reaches the title within ~1 s; clicking from another macOS app
selects the exact pane and activates the terminal (or clearly reports partial focus);
app restart preserves seen completions.

### P2 — Registry enrichment and non-herdr sessions
1. Build `menubar/extension/index.ts` + pure `state.ts`: TUI mode gate, private atomic
   publisher, reload-stable revision/process identity, heartbeat, parallel-tool map,
   context/model/session metadata, and reload-safe lifecycle (§6.1).
2. Add `/menubar status|dump|simulate|clear|doctor`; simulation is an expiring overlay.
3. Implement `RegistryWatcher`, stale/fixture expiry, private-file validation, and the
   full herdr+registry merge key chain (§4.3).
4. Persist registry-only acknowledgements; add `menubar/dev/fake-sessions.sh N`.
5. Node tests cover permissions, sanitation, reload/replacement, parallel completion
   order, prompt privacy, and mode gating; Swift tests cover joins and staleness.

**Accept:** `/menubar dump` matches v1 and is mode `0600`; `/reload` leaves one
publisher/timer; model/tool/context details enrich herdr rows; a bare-Ghostty pi appears
from the registry alone; completing one parallel tool does not hide the others; a
heartbeat never resurrects an acknowledged completion.

### P3 — Production hardening
1. Exercise herdr stop/restart, subscription rebuilds, missed-event safety snapshots,
   unknown protocols, malformed/oversized frames, and multiple-socket warnings.
2. Exercise registry crash/stale/temp cleanup, malformed/symlink/wrong-owner files,
   PID reuse, session new/resume/fork, and app restart.
3. Implement config watch with last-good fallback, bounded/rate-limited logs, semantic
   render coalescing, and `maxRows` truncation.
4. Test the real LaunchAgent environment with `PATH`/HERDR variables absent and verify
   direct socket focus + bundle activation.
5. Measure 24 fake sessions + active streaming panes: idle CPU <1%, no output-rate UI
   churn, bounded memory, and no main-thread file/socket I/O.

**Accept:** herdr restart recovers within 5 s; dead registry rows age out; malformed
inputs cannot crash or leak content to logs; counts remain correct under streaming;
`menubar/dev/fake-sessions.sh 24` sorts/truncates as specified.

### P4 — Polish and packaging
1. Coloured `attributedTitle`, details window, accessibility pass, and empty/partial
   focus states. Keep plain menu rows unless custom views prove equally accessible.
2. Honour privacy, included-mode, idle/empty, terminal bundle, and row-limit config.
3. `Open log/config/registry` menu items; bounded log rotation.
4. `make install`: app in `~/Applications`, extension copy, mode-`0600` LaunchAgent
   (`RunAtLoad=true`, `KeepAlive=false`), `launchctl bootstrap gui/$UID`, single-instance
   lock, and matching idempotent bootout/uninstall.
5. README: `/reload`, glyphs, privacy defaults, socket discovery, non-herdr focus limits.

**Accept:** logout/login starts one item with correct counts; install/uninstall are
idempotent; two launches cannot create duplicate items; all controls remain keyboard
and VoiceOver accessible.

### P5 — Optional enrichments
1. Optional herdr `ctx=42%` display token only after proving it cannot conflict with
   managed integrations; never report agent state/title/state labels.
2. Consume `pi.events.on("herdr:blocked")` for richer labels when available.
3. ~~Notification → focus via registered `pimenubar://focus?...` and
   `terminal-notifier -open`, never shell `-execute`.~~ Superseded by
   [PiMenuBar-owned native notifications](menubar-native-notifications.md), which posts the
   banner from this app and wires its actions straight to `Focuser`, so no URL scheme or
   `terminal-notifier` is needed.
4. Direct status-item click focuses the sole blocked session; otherwise opens the menu.
5. Stable error/outcome display once pi exposes a documented signal.
6. Optional non-pi agents and, separately, multiple local herdr sockets.

### P6 — Distribution (only if it should leave this machine)
1. `make dist` → zip containing `PiMenuBar.app`, the pi extension directory, an
   idempotent installer/uninstaller, and sha256. Downloaded builds require quarantine
   removal or Developer ID signing + notarization.
2. Optional Homebrew cask and separate pi-extension package docs.

---

## 9. Testing

**Automated**

| Layer | Tool | Covers |
|---|---|---|
| `PiMenuBarCore` | `swift test` | merge rules §4.3, staleness/GC, join-key fallbacks, `TitleFormatter` buckets and clamping, registry decode incl. malformed/unknown-version input |
| extension | `node --test menubar/extension/state.test.ts` | permissions, atomic revisioned writes, reload-stable identity/revision, heartbeat cleanup, prompt privacy, parallel tools, mode gating |
| protocol | `swift test` fixtures + fake Unix socket | split/coalesced/oversized lines, request timeout/EOF, snapshot and event decode, unknown fields, snapshot→subscribe→snapshot ordering |

**Replayable fixtures** — capture real payloads once into `menubar/Tests/Fixtures/`:
`snapshot.json`, `pane_updated.json`, `pane_agent_status_changed.json`,
`subscription_started.json`. These are the regression net for herdr protocol drift.

**Manual matrix** (run per release; P1–P4)

| Case | How | Expect |
|---|---|---|
| each state | expiring `/menubar simulate blocked` etc., or a real run | correct glyph within 1 s, then real state restored |
| blocked → answered | `/nudge simulate` (existing command opens a real dialog) | `!` appears, disappears on answer |
| completed attention | let a run settle, don't touch the terminal | `○` |
| seen/focus from browser | click the row while another macOS app is frontmost | `○` → `·`, exact herdr pane selected, host terminal activated; heartbeat does not resurrect `○` |
| many sessions | `menubar/dev/fake-sessions.sh 24` | title stays short, menu groups, `maxRows` respected |
| non-herdr session | run pi in a bare Ghostty window | row appears from registry alone; focus is app-level only |
| herdr down | `herdr server stop`, then start | degrades, then recovers ≤5 s |
| login environment | launch via LaunchAgent with HERDR/PATH vars absent | discovers configured/registry/default socket and focuses via direct request |
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
| R5 | Join failures produce duplicate rows | medium | session-file → pane-id → pid+start chain; unmatched rows remain visible; fixtures cover reload/resume/fork |
| R6 | App-installed publisher changes behaviour for notification-only package users | high | separate `menubar/extension` install surface (D8); root package discovery is unchanged |
| R7 | Extension heartbeat or repeated herdr `done` snapshot resurrects a completed badge after click | high | registry has no `unseen`; app acknowledgements compare `settledAt` and herdr `state_change_seq` |
| R8 | Parallel tools finish out of order and a singular `tool` field lies | medium | registry tracks `activeTools` by `toolCallId`; each end removes only its own call |
| R9 | Login app lacks terminal `PATH`/HERDR env or cannot activate herdr's host terminal | high | D9 socket discovery; direct focus request; learn bundle id from registry with explicit config fallback; report partial focus |
| R10 | `agent.focus` marks Done seen | low (intended) | action is labelled `Focus and acknowledge`; failed focus does not acknowledge |
| R11 | LSUIElement hidden when empty leaves no Config/Quit path | medium | visible dim `π` by default; hiding is opt-in |
| R12 | Duplicate app instances | low | `flock` single-instance lock; normal launch uses `open -a` |
| R13 | Sensitive prompt/cwd data on disk | medium | `0700` dirs, `0600` files, previews opt-in, sanitation/truncation, no content in logs |
| R14 | Stale files / PID reuse | low | heartbeat+processStartedAt, age-based GC; PID is never sole freshness evidence |
| R15 | Swift 6 callbacks race AppKit state | medium | immutable `Sendable` snapshots + `@MainActor SessionStore`; semantic render coalescing |
| R16 | Locally built app moved between machines is quarantined | low | document quarantine removal; notarize only in P6 |
| R17 | `state_change_seq` changes for metadata-only updates, invalidating completion acknowledgements | medium | explicit P1 verification/fixture; if unstable, use a persisted idle→done generation maintained by snapshot transitions and document offline limitations |

---

## 11. Resolved scope and deferred choices

No open decision blocks P0/P1.

| Topic | V1 decision | Deferred |
|---|---|---|
| Repository/install | This repo, separate `menubar/` install surface (D8) | Split repo only if app gets independent notarized releases |
| Title | Bounded per-state counts (`π 1!2▶`) | Custom icon/SF Symbol in P4+ |
| Empty state | Visible dim `π` by default | User may opt into hiding |
| Agent types | pi only | Non-pi herdr agents in P5+ |
| herdr servers | One local socket, explicit warning on multiple | Multi-socket/machine dashboard |
| Completion acknowledgement | App-owned timestamp + herdr completion sequence after P1 verification; focus acknowledges | Rich notification/deep-link flows in P5 |
| Registry cleanup | Extension deletes best-effort; app performs age GC | None |

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

**A.9 Real event names (live subscription, 22 subscription types)**
```console
NEW event="pane_focused"               data.type="pane_focused"               dataKeys=pane_id|type|workspace_id
NEW event="tab_focused"                data.type="tab_focused"                dataKeys=tab_id|type|workspace_id
NEW event="workspace_focused"          data.type="workspace_focused"          dataKeys=type|workspace_id
EVT {"data":{"pane":{...}},"event":"pane_updated"}            # underscore
EVT {"data":{"agent":"pi",...},"event":"pane.agent_status_changed"}   # dots
```
Only the first separator is canonicalized, because `agent_status_changed` is part of the
name.

**A.10 `state_change_seq` and optional agent fields** — `snapshot.agents[].state_change_seq`
is present (`239`, `27`, `228` for three panes) but `snapshot.panes[]` has no
`state_change_seq` at all, and no event payload carries it. Separately, `tokens` and
`state_labels` appear only on panes with a title suffix, so a strict decoder fails on the
fixture (`Key 'tokens' not found ... Path: agents[0]`).

**A.11 Events are sparse when idle** — a subscription to 22 event kinds produced zero
events in a two-minute window while the fleet was quiet; the same subscription produced
`pane_updated` events within seconds while another pane was streaming. The initial
snapshot and the periodic re-sync carry the display.

**A.12 No XCTest in Command Line Tools**
```console
$ ls /Library/Developer/CommandLineTools/usr/lib/swift/macosx/   # no XCTest
$ find /Library/Developer/CommandLineTools -name 'XCTest*'      # nothing
$ xcode-select -p                                               # /Library/Developer/CommandLineTools
```
Hence the harness executable in `Tests/PiMenuBarTests/TestHarness.swift`.

**A.8 pi UI surface** — `docs/extensions.md:2600` ("Widgets, Status, and Footer"),
`docs/tui.md:768`, `dist/core/extensions/types.d.ts:81` (`setStatus(key, text)`), and
`docs/extensions.md:998` (fire-and-forget methods incl. `setStatus`) — all terminal-only;
no macOS menu bar API exists.

---

## 12. Implementation record

Built 2026-09-21 on branch `menubar-status-bar`. Everything is in `menubar/`; the root pi
package and `extensions/notify-when-unfocused.ts` are untouched, so existing
`pi-notify-when-unfocused` users are unaffected.

### What exists

| Path | Contents |
|---|---|
| `menubar/Sources/PiMenuBarCore/` | Models, config, NDJSON framing, protocol-22 decoding, registry reader, acknowledgements, merge, grouping, title formatting, `AF_UNIX` client (`Foundation` only) |
| `menubar/Sources/PiMenuBar/` | AppKit shell: status item + menu, herdr client, registry watcher, focuser, config loader, logging, `--probe` |
| `menubar/extension/` | pi publisher (`index.ts`), pure logic (`state.ts`), tests |
| `menubar/dev/fake-sessions.sh` | Expiring simulated rows for layout/sorting work |
| `menubar/Makefile`, `Resources/Info.plist` | Bundle, run, test, install, uninstall, dist |
| `menubar/Tests/PiMenuBarTests/` | 97 tests + real herdr wire fixtures |

Verified end to end against a live herdr 0.9.1 / protocol 22 with three pi panes:
`make probe` prints the merged fleet, grouped by workspace → tab, with the real state
labels; the app connects, renders, and refuses a second instance.

### Deviations from this plan

| Plan said | Built | Why |
|---|---|---|
| `swift test` with XCTest | `swift run PiMenuBarTests` harness | CLT ships no XCTest/Testing (fact 19). `make test` runs the Swift suite plus `node --test extension/` |
| `swift build` | `swift build --product PiMenuBar` | The test target uses `@testable import`, which SwiftPM enables for debug builds only |
| Extension at `extensions/session-status.ts` | `menubar/extension/index.ts` | Auto-discovery needs `index.ts` in a directory; the dir is symlinked/copied into `~/.pi/agent/extensions/pi-menubar` |
| Delete the registry file on `session_shutdown` | Delete only when `reason == "quit"` | A replacement (reload/new/resume/fork) is followed by another `session_start` in the same process; deleting first lost the revision seed and flickered the row |
| `registry v1` has `state: idle｜working｜blocked` plus optional `error` | No `error` state | pi exposes no documented error signal; inventing one from assistant stop reasons was not worth the false positives |
| Acknowledgement keyed on `state_change_seq` from events | Re-snapshot on status changes | Events carry no `state_change_seq` (fact 16) |
| `pane.updated` throttled fallback | Not subscribed at all | Two captures showed it firing per output revision and zero times while idle (facts 8, 18) |
| Tests for `state_change_seq` stability as a P1 gate | Still captured as a fixture, not yet an asserted invariant | The app uses it only to compare one completion generation against the last acknowledged one, and falls back to timestamps when absent |

### Known limitations

1. **`state_change_seq` stability is unverified long-term.** If herdr bumps it for
   metadata-only updates, an acknowledged completion could re-flag once. Mitigated by
   comparing against the acknowledged generation and by `settledAt` fallback.
2. **Non-herdr focus is app-level only.** Without a pane id, the app can activate the
   terminal but not select a tab or split.
3. **`terminalBundleId` is learned from the registry.** A herdr-only row in a terminal
   that never published has no bundle id unless `terminalBundleId` is configured.
4. **The menu bar title cannot show which specific session needs you** — only counts.
   That is the dropdown's job, by design (R4).
5. **`--probe` and the app share the discovery rules but not the code path** for events;
   the event path is exercised by fixtures and socket tests rather than a live assertion.
