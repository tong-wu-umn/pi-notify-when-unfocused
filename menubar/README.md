# PiMenuBar

A macOS menu bar status bar for [pi](https://pi.dev) sessions: one glance tells you how
many sessions are working, which one is **blocked waiting on you**, and which one
finished while you were away. Opening the menu shows the project, model, active tools and
context usage per session; clicking a row brings that pane to the front.

```
π 1!2▶1○3·      ← 1 blocked · 2 working · 1 finished-unseen · 3 idle
```

Built for the case where several pi sessions run in [herdr](https://herdr.dev) panes and
you are looking at none of them.

---

## What it shows

| Glyph | Meaning |
|---|---|
| `!` | Blocked — a pi dialog is on screen (approve/reject, select, input, editor) |
| `▶` | Working — an agent run is in progress |
| `○` | Finished and not yet acknowledged |
| `·` | Idle — ready for your next prompt |
| `?` | herdr cannot classify the pane's agent |

Counts are bounded (`9+`), idle can be hidden, and the dropdown grows from the same data:
workspace → tab → session, with `tool +N · elapsed · model · ctx%`, the blocked reason and
waiting time, and a submenu for **Focus and acknowledge**, **Show details**, copy paths,
and **Mark completed seen**.

Acknowledgement is deliberate: a `○` means "finished and you have not looked at it yet".
Focusing the pane, clicking the row, or choosing *Mark completed seen* clears it, and a
repeated `idle` heartbeat can never resurrect it.

---

## Requirements

- macOS 13 or newer
- **Command Line Tools** (`xcode-select --install`) — no Xcode project, no XCTest
- [herdr](https://herdr.dev) for cross-session state and click-to-focus. Without herdr the
  app still works, but only for pi sessions that publish to the registry (below)

## Install

```bash
cd menubar
make test          # 122 tests, no XCTest required
make probe         # print what the menu bar would show right now
make run           # build PiMenuBar.app and launch it
make install       # app in ~/Applications + extension + login item
```

`make install` does three things:

1. copies `PiMenuBar.app` to `~/Applications` and starts it,
2. installs the pi publisher as `~/.pi/agent/extensions/pi-menubar` (a symlink in a dev
   checkout — edit `extension/*.ts` and `/reload`),
3. writes a `RunAtLoad` LaunchAgent so it comes back after login.

Run `/reload` in each running pi session once so it starts publishing. `make uninstall`
removes the app, the extension and the LaunchAgent; registry files and config are kept.

> The status item is the only way to quit the app (there is no Dock icon). `pkill -f
> PiMenuBar.app` works too.

---

## How it works

Two independent sources, merged in the app:

```
pi extension ──▶ ~/.pi/agent/menubar/sessions/<pid>.json ──┐
  (model, tools, context, session name, completion time)   ├─▶ merge ─▶ menu bar
herdr socket ─── events.subscribe + session.snapshot ──────┘
  (which panes exist, working/blocked/idle/done, focus)
```

- **herdr** is authoritative for pane lifecycle and state, and is the only way to select
  an exact pane on click. Its event stream is lossy (no sequence numbers, no replay), so
  the app treats `session.snapshot` as ground truth: connect runs snapshot → subscribe →
  snapshot, structural events trigger a debounced re-snapshot, and a 30 s safety poll
  re-syncs even while connected.
- **The registry** adds what herdr does not know and is the only source for pi running
  outside herdr. Each process writes one private JSON file (`0700` directory, `0600` file,
  atomic rename), with a monotonic `revision` and a 15 s heartbeat. A `kill -9`'d session
  simply stops heartbeating and its row disappears after 90 s.
- Join order: pi session file → herdr pane id → pid + process start. Unmatched rows are
  still shown rather than silently dropped.

The app never writes pi's state: it never calls `pane.report_agent` (herdr's own managed
`pi` integration owns that) and it never sends notifications. It owns exactly one thing on
disk: `~/Library/Application Support/PiMenuBar/acknowledgements.json`.

---

## Configuration

`~/.pi/agent/menubar.json` — shared by the app and the extension; unknown keys are
ignored, malformed files fall back to defaults, and the app reloads on change:

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

| Key | Notes |
|---|---|
| `includedModes` | `tui` by default; add `rpc` for long-lived RPC sessions. Short-lived `print`/`json` runs are excluded so the menu does not flicker |
| `includePromptPreview` | Off. When on, the first 120 characters of your prompt go into the state file |
| `hideWhenEmpty` | Off, so the menu stays reachable (Config/Log/Quit) when no session is running |
| `herdrSocketPath` | Only needed when the app cannot discover herdr itself (see below) |
| `terminalBundleId` | Fallback host terminal for herdr rows with no registry record |

Extension env overrides: `PI_MENUBAR_ENABLED=0` (disable one session),
`PI_MENUBAR_REGISTRY_DIR=/somewhere/else`.
The app's log is `~/Library/Logs/PiMenuBar.log` (2 MB rotation), reachable from the menu.

### Socket discovery

A login item inherits no shell environment, so `HERDR_SOCKET_PATH` is usually absent even
while herdr runs. The app tries, in order: config `herdrSocketPath` → `HERDR_SOCKET_PATH`
→ the socket path recorded in fresh registry files → `~/.config/herdr/herdr.sock`. If more
than one socket turns out to be usable it says so in the menu instead of silently merging
two servers.

---

## Commands

`/menubar` in pi:

| Subcommand | Purpose |
|---|---|
| `status` | publishing yes/no, registry path, state, revision, model, tools, context |
| `dump` | the exact JSON currently on disk |
| `simulate blocked 20` | presentation-only override with an expiry, for UI work; real events keep updating underneath |
| `clear` | clear a simulation and republish the live state |
| `doctor` | config, registry, permissions, herdr env, install paths |

Development helpers:

```bash
make probe                 # integration check against the live herdr, no GUI
make probe-json            # same, machine readable
./dev/fake-sessions.sh 24  # 24 simulated rows (expiring) to test layout and sorting
./dev/fake-sessions.sh 0   # clean up
```

## What it deliberately does not do

- No prompt submission, no approval, no killing sessions from the menu.
- No notifications: [pi-notify-when-unfocused](../README.md) owns "you are away, here is a
  banner". They compose, and neither requires the other.
- Not a dashboard for remote machines: one local herdr server at a time.
- No TLS/network surface at all: one Unix socket, one local directory.

## Troubleshooting

| Symptom | Check |
|---|---|
| No π in the menu bar | `make run` and look at `~/Library/Logs/PiMenuBar.log` |
| π but no sessions | `/menubar status` in pi — is this session publishing? (headless modes don't, by default) |
| Rows but no herdr detail | `make probe` — the socket line says which candidate was chosen |
| Multiple herdr sockets warning | set `herdrSocketPath` explicitly |
| Click focuses the wrong thing | herdr selects the pane; your terminal must be able to activate. Rows with `pane=-` have no pane to select |
| π appears, then quits ~15 s later | read `~/Library/Logs/PiMenuBar.log`; a crash leaves no "stopping" line. See the `@Sendable` note below |
| `swift build` fails in release | `make build` builds only the app product; the test target needs debug (`@testable`) |

## Development notes

- `swift test` is unavailable with Command Line Tools only (no XCTest), so the suite runs
  as a normal executable: `make test` → `swift run PiMenuBarTests` (97 tests) plus
  `node --test extension/` (25 tests). `PiMenuBarCore` holds everything testable; the
  AppKit shell is deliberately thin.
- Real wire fixtures live in `Tests/PiMenuBarTests/Fixtures.swift`, captured from a live
  herdr 0.9.1. Note that herdr mixes event-name separators (`pane_updated` vs
  `pane.agent_status_changed`); decoding normalizes the first separator.
- Version: protocol 22 is the only herdr protocol this build accepts. Anything else runs
  in registry-only mode and says so in the menu.
- Swift 6 concurrency footgun: `DispatchSource` handlers in this target must be written
  `source.setEventHandler { @Sendable [weak self] in Task { @MainActor in ... } }`.
  `DispatchSourceHandler` is a plain `@convention(block) () -> Void`, so an unannotated
  closure literal written inside a `@MainActor` class inherits main-actor isolation — and
  the compiler then inserts an isolation assertion that traps in
  `dispatch_assert_queue` on the source's own queue. That killed the app 15 s in (first
  registry heartbeat) with `EXC_BREAKPOINT` and no log line. `Timer` blocks and
  `DispatchQueue.async` are fine: both are already `@Sendable`.
