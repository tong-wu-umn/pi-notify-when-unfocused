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
and **Mark completed seen**. The whole count is tinted red while something is blocked and
orange while something finished unseen; the other states use the menu bar's own text
colour, so the item reads like the system items next to it on any wallpaper.

Acknowledgement is deliberate: a `○` means "finished and you have not looked at it yet".
Focusing the pane, clicking the row, or choosing *Mark completed seen* clears it, and a
repeated `idle` heartbeat can never resurrect it. A completion clears itself only when you
are genuinely looking at that session — its host terminal frontmost *and* its pane the
selected one — so a badge earned while you were in another application stays until you
come back or clear it.

---

## Native notifications (optional)

PiMenuBar can also post the banners itself, so the sender is **PiMenuBar** instead of
Ghostty. That is a different bargain from the terminal-transport notifications in
[pi-notify-when-unfocused](../README.md):

| | PiMenuBar native | `/nudge` (OSC 777 via Ghostty) |
|---|---|---|
| Shown as | PiMenuBar, its own icon | Ghostty |
| Suppressed while the sender is frontmost | effectively never (accessory app) | yes, while Ghostty is active |
| Ghostty's rate limiter / “clear on activation” | not involved | applies |
| Actions on the banner | **Focus session**, **Mark seen**, dismiss | none |
| Needs | notification permission | Ghostty + `/nudge` installed |

Both channels are independent and **you should use only one**; otherwise one wait can
ring twice. Native notifications are therefore **off by default**.

### Turning them on

1. install PiMenuBar (`make install`) and run `/reload` once in each pi session;
2. add the block below to `~/.pi/agent/menubar.json`;
3. stop the other channel: set `"enabled": false` in
   `~/.pi/agent/notify-when-unfocused.json` and `/reload` (or uninstall the root extension);
4. menu bar → **Send test notification** to grant permission and confirm the sender.

```json
{
  "notifications": {
    "enabled": true
  }
}
```

What alerts, and what does not:

- a **blocking dialog** appears (approve/reject, select, input, editor) and you are
  looking at a different app or a different terminal pane;
- a run settles after at least `idleMinRunMs` while you are away — **once**, with no
  reminder series;
- up to `reminders` extra nudges while the *same* prompt is still open — the series ends
  as soon as you are back at that session's pane, even if you leave again without
  answering;
- nothing for a prompt that was already open when PiMenuBar started, nothing for short
  replies, and nothing for `/menubar simulate` — a restart never replays old banners.

Banner text is deliberately generic (`Approval or input is needed in <project>.`) and the
notification payload contains only an opaque id: prompts, tool names, commands, paths, and
working directories never reach Notification Center, which is visible on the lock screen
and keeps items after the session has ended. Set `"showProjectName": false` to hide the
project name as well.

Actions map to the same code as the menu rows, so **Focus session** selects the exact
herdr pane and activates the terminal, and **Mark seen** clears the `○` without focusing.
Dismissing a banner stops its reminders but deliberately does *not* mark anything seen.

A delivered banner stays in Notification Center: only its *pending* reminders are
cancelled when the wait is over (the prompt was answered, the completion was
acknowledged, the session disappeared). Retracting it hid the notification whose sound
had just brought you back to the terminal — you acknowledge a completion by simply
returning to its pane. macOS removes the banner itself when you act on it or dismiss it;
turning notifications off clears everything.

### Pane-precise suppression

To tell “you are looking at this session” from “you are looking at another Ghostty pane”,
PiMenuBar uses herdr's selected pane when it is available, and otherwise asks Ghostty
which terminal has focus. The Ghostty query needs one-time Automation permission
(*System Settings → Privacy & Security → Automation → PiMenuBar → Ghostty*); until it is
granted, PiMenuBar assumes you are looking at the session and stays quiet rather than
interrupting the pane in use. A failed probe backs off for a minute instead of retrying on
every alert.

---

## Claude Code usage

PiMenuBar shows the Claude subscription's 5-hour and 7-day limit utilisation next to the
session counts. It is **on by default**; set `claudeUsage.enabled: false` to remove the
section and stop all keychain/network activity. It reads the same HTTPS endpoint as the
`/usage` screen — **no `claude` subprocess and no inference request**, so it costs no
tokens.

```json
{
  "claudeUsage": {
    "enabled": true,
    "refreshIntervalMs": 900000,
    "showInTitle": false,
    "warningPercent": 75
  }
}
```

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | On by default; the first refresh triggers the keychain prompt below |
| `refreshIntervalMs` | `900000` (15 min) | Clamped to 1 minute … 1 hour |
| `showInTitle` | `false` | Adds `· 78%` to the status title; off because menu bar space is scarce |
| `warningPercent` | `75` | Fallback for the ⚠ glyph when the API omits its own severity; ≥90 is red |

The menu section looks like:

```
Claude Code usage — 12:46
  5-hour   78%  ⚠  resets in 2h 4m
  7-day     9%     resets Mon 04:00
Refresh usage now
```

**Keychain prompt.** The access token lives in the login keychain as the generic password
`Claude Code-credentials`, written by the CLI. The first read shows *“PiMenuBar wants to
use your confidential information stored in Claude Code-credentials”*; choose **Always
Allow** so refreshes stay silent. Builds are ad-hoc signed, so a rebuilt or reinstalled
binary can be a different code identity and prompt again. PiMenuBar never reads the
refresh token and never refreshes it: once `expiresAt` passes it stops polling and says
so, and the CLI rotates the token on its own the next time you use it.

| Symptom | Check |
|---|---|
| `Claude Code usage — no credentials` | Claude Code has never logged in on this Mac, or the keychain item was deleted. Open the CLI once |
| `token expired — open Claude Code` | the CLI has not refreshed the token yet; run it once, then **Refresh usage now** |
| `re-authenticate` after logging in again | the old token was revoked. The next refresh picks up the new keychain value; if it does not, restart PiMenuBar |
| `offline` or an old timestamp | the last good numbers stay on screen. Network and 429/5xx failures are expected to be transient |
| Numbers differ from `/usage` | `make probe-usage` prints the live parsed payload; the endpoint is unofficial and its shape can change |

With `enabled: false` there is no keychain access and no network traffic. Disabling it
also removes the menu section; the cached percentages can be deleted with
`~/Library/Application Support/PiMenuBar/claude-usage.json`.

---

## Requirements

- macOS 13 or newer
- **Command Line Tools** (`xcode-select --install`) — no Xcode project, no XCTest
- [herdr](https://herdr.dev) for cross-session state and click-to-focus. Without herdr the
  app still works, but only for pi sessions that publish to the registry (below)

## Install

```bash
cd menubar
make test          # 163 tests, no XCTest required
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
`pi` integration owns that) and it never sends notifications. It owns two things on
disk: `~/Library/Application Support/PiMenuBar/acknowledgements.json`, and — only when
`claudeUsage.enabled` is on — `claude-usage.json` (percentages and timestamps, never a
token).

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
  "logLevel": "info",
  "notifications": {
    "enabled": false,
    "notifyOnPrompts": true,
    "notifyOnIdle": true,
    "idleMinRunMs": 15000,
    "reminders": 2,
    "reminderIntervalMs": 20000,
    "dedupeMs": 10000,
    "sound": true,
    "preciseFocus": true,
    "notifyUnknownDurationCompletions": false,
    "showProjectName": true
  },
  "claudeUsage": {
    "enabled": false,
    "refreshIntervalMs": 900000,
    "showInTitle": false,
    "warningPercent": 75
  }
}
```

| Key | Notes |
|---|---|
| `includedModes` | `tui` by default; add `rpc` for long-lived RPC sessions. Short-lived `print`/`json` runs are excluded so the menu does not flicker |
| `includePromptPreview` | Off. When on, the first 120 characters of your prompt go into the state file |
| `hideWhenEmpty` | Off, so the menu stays reachable (Config/Log/Quit) when no session is running |
| `herdrSocketPath` | Only needed when the app cannot discover herdr itself (see below) |
| `terminalBundleId` | Fallback host terminal for herdr rows with no registry record |
| `notifications.*` | Native banners. Off by default; see [Native notifications](#native-notifications-optional) |
| `notifications.dedupeMs` | Suppresses a second banner this soon after the previous one, across sessions |
| `notifications.notifyUnknownDurationCompletions` | Off, because a herdr-only `done` row cannot prove the run was not a two-second reply |
| `claudeUsage.*` | Subscription-usage readout, on by default; see [Claude Code usage](#claude-code-usage) |

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
make probe-usage           # one live Claude usage fetch, parsed and printed
./dev/fake-sessions.sh 24  # 24 simulated rows (expiring) to test layout and sorting
./dev/fake-sessions.sh 0   # clean up
```

## What it deliberately does not do

- No prompt submission, no approval, no killing sessions from the menu.
- No notifications of its own until you ask for them: the terminal-transport channel in
  [pi-notify-when-unfocused](../README.md) stays the default, and the two must not be
  enabled together.
- No custom toast, popover, or overlay. Banners are ordinary macOS notifications, so
  Focus mode, per-app settings, and Notification Center history keep working.
- Does not read macOS Focus/DND state: there is no supported API for it.
- Not a dashboard for remote machines: one local herdr server at a time.
- No network surface unless `claudeUsage.enabled` is on: then it is one optional HTTPS
  `GET` to the usage endpoint, not a general-purpose client. The status item data itself
  still comes from one Unix socket and one local directory.

## Troubleshooting

| Symptom | Check |
|---|---|
| No π in the menu bar | `make run` and look at `~/Library/Logs/PiMenuBar.log` |
| π but no sessions | `/menubar status` in pi — is this session publishing? (headless modes don't, by default) |
| Rows but no herdr detail | `make probe` — the socket line says which candidate was chosen |
| Multiple herdr sockets warning | set `herdrSocketPath` explicitly |
| No banner, `Notifications: Permission required` in the menu | click **Send test notification** and allow it |
| `authorization request failed: Notifications are not allowed for this application` in the log | macOS refused to show the consent prompt and marked the app denied. Turn **PiMenuBar** on by hand in *System Settings → Notifications*, then **Send test notification** again — the app picks the new state up within ~30 s without a restart |
| No banner, `Notifications: Off (menubar.json)` | add `"notifications": {"enabled": true}` to `~/.pi/agent/menubar.json` |
| Banners arrive twice | two channels are on: disable `/nudge` (`~/.pi/agent/notify-when-unfocused.json`) or set `notifications.enabled: false` |
| No banner while looking at another Ghostty pane | the Automation probe failed; see [Pane-precise suppression](#pane-precise-suppression) and `~/Library/Logs/PiMenuBar.log` |
| Click focuses the wrong thing | herdr selects the pane; your terminal must be able to activate. Rows with `pane=-` have no pane to select |
| π appears, then quits ~15 s later | read `~/Library/Logs/PiMenuBar.log`; a crash leaves no "stopping" line. See the `@Sendable` note below |
| `swift build` fails in release | `make build` builds only the app product; the test target needs debug (`@testable`) |

## Development notes

- `swift test` is unavailable with Command Line Tools only (no XCTest), so the suite runs
  as a normal executable: `make test` → `swift run PiMenuBarTests` (163 tests) plus
  `node --test extension/` (25 tests). `PiMenuBarCore` holds everything testable —
  including the notification decision table and the focus rules — and the AppKit shell is
  deliberately thin.
- Real wire fixtures live in `Tests/PiMenuBarTests/Fixtures.swift`, captured from a live
  herdr 0.9.1. Note that herdr mixes event-name separators (`pane_updated` vs
  `pane.agent_status_changed`); decoding normalizes the first separator.
- Version: protocol 22 is the only herdr protocol this build accepts. Anything else runs
  in registry-only mode and says so in the menu.
- Notification decisions (generations, reminders, dedupe, baseline, privacy) live in
  `Sources/PiMenuBarCore/NotificationPolicy.swift`; `NotificationCoordinator` only
  executes them. Records of posted banners belong to the app:
  `~/Library/Application Support/PiMenuBar/notification-routes.json` (0700/0600, atomically
  replaced, pruned after 7 days).
- Swift 6 concurrency footgun: `DispatchSource` handlers in this target must be written
  `source.setEventHandler { @Sendable [weak self] in Task { @MainActor in ... } }`.
  `DispatchSourceHandler` is a plain `@convention(block) () -> Void`, so an unannotated
  closure literal written inside a `@MainActor` class inherits main-actor isolation — and
  the compiler then inserts an isolation assertion that traps in
  `dispatch_assert_queue` on the source's own queue. That killed the app 15 s in (first
  registry heartbeat) with `EXC_BREAKPOINT` and no log line. `Timer` blocks and
  `DispatchQueue.async` are fine: both are already `@Sendable`.
