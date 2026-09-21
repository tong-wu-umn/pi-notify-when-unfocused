# pi-notify-when-unfocused

A [pi](https://pi.dev) extension that pings you with a **macOS notification when pi is blocked waiting on you and your terminal is not the active window** — so you can walk away from an approval prompt without it silently sitting there.

Windows notifications are **pane-aware**: if you have several pi sessions in several Ghostty windows, tabs, or splits, you only get pinged when you are *not* looking at the session that needs you. It also works when pi runs inside [Herdr](https://herdr.dev) — see [Inside herdr](#inside-herdr).

```
┌─ you start a long run, then switch to your browser ──────────────────┐
│                                                                     │
│   π needs your input                                (notification)  │
│   Approve or reject in misc — Bash command                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## What triggers it

| Trigger | When | Default |
|---|---|---|
| `ui_prompt_start` | Any blocking pi dialog is on screen: approve/reject, select, input, editor, custom. Covers permission extensions such as `pi-permission-system`. | on |
| `agent_settled` | A run finished and pi is idle, waiting for your next message. | on, only for runs longer than 15s |

While a dialog stays open, a couple of reminders are sent (default: 2 more, 20s apart), and near-duplicate notifications are suppressed.

## Requirements

- macOS (the focus check is macOS-only; elsewhere the extension stays inert)
- Ghostty *(optional but recommended — see [How it works](#how-it-works))*
- Notifications must be allowed for **Ghostty** in *System Settings → Notifications*. Set the style to **Alerts** if you want them to stay on screen until dismissed. Inside herdr the banner may instead belong to your herdr delivery target — see [Inside herdr](#inside-herdr).

## Install

```bash
pi install git:github.com/tong-wu-umn/pi-notify-when-unfocused@v0.1.0
```

Then `/reload` in each running pi session (or restart pi).

Other ways to load it:

```bash
pi -e git:github.com/tong-wu-umn/pi-notify-when-unfocused   # try without installing
cp extensions/notify-when-unfocused.ts ~/.pi/agent/extensions/   # manual, auto-discovered
```

> **Do not load it twice.** If you previously copied the `.ts` file into `~/.pi/agent/extensions/`, remove that copy after installing the package, otherwise both copies load and you get duplicate notifications.

## Commands

| Command | What it does |
|---|---|
| `/nudge status` | Config, transport, and the live focus verdict with reasons |
| `/nudge focus` | Just the focus check — is this terminal pane the one you're looking at? |
| `/nudge test` | Send a notification immediately |
| `/nudge test 5` | Send it in 5 seconds — **switch to another app first** (see [Gotchas](#gotchas)) |
| `/nudge simulate` | Open a real dialog through the true `ui_prompt_start` path to test end to end |

## Configuration

Optional file at `~/.pi/agent/notify-when-unfocused.json` (defaults are used when absent):

```json
{
  "enabled": true,
  "notifyOnPrompts": true,
  "notifyOnIdle": true,
  "idleMinRunMs": 15000,
  "reminders": 2,
  "reminderIntervalMs": 20000,
  "remindersOnIdle": false,
  "dedupeMs": 10000,
  "terminalApps": ["Ghostty"],
  "titleMarkers": ["π", "pi"],
  "preciseFocus": true,
  "transport": "auto",
  "bell": false
}
```

| Key | Meaning |
|---|---|
| `notifyOnPrompts` | Notify for blocking dialogs |
| `notifyOnIdle` | Notify when a run settles and pi waits for your next message |
| `idleMinRunMs` | Don't notify for runs shorter than this |
| `reminders` / `reminderIntervalMs` | Extra nudges while a **dialog** stays open (pi is stuck until you answer) |
| `remindersOnIdle` | Also repeat the "finished, waiting for you" nudge (off — one ping per finished run) |
| `dedupeMs` | Suppress a second notification this soon after the first |
| `terminalApps` | Frontmost app names that count as "the terminal" |
| `titleMarkers` | Substrings pi puts in its own terminal title, used to identify this pane |
| `preciseFocus` | Check *which* terminal pane has focus, not just which app is frontmost |
| `transport` | `auto` \| `herdr` \| `osc777` \| `osc9` \| `osascript` \| `bell` \| `none` |
| `bell` | Also ring the terminal bell |

Environment overrides use `PI_NUDGE_<KEY>` (e.g. `PI_NUDGE_ENABLED=0`, `PI_NUDGE_TRANSPORT=osascript`, `PI_NUDGE_IDLE_MIN_RUN_MS=5000`). Handy for debugging:

- `PI_NUDGE_FORCE_UNFOCUSED=1` — pretend the terminal is always in the background
- `PI_NUDGE_DEBUG=1` — log every notification decision to stderr

Setting `preciseFocus: false` skips the pane-level check everywhere and only asks which app is frontmost.

## How it works

**1. Knowing pi is waiting.** pi emits `ui_prompt_start` / `ui_prompt_end` around every blocking `ctx.ui` dialog, and `agent_settled` when a run is fully done. The extension subscribes to those; no polling of the UI.

**2. Knowing you are not looking.** Two tiers, cheapest first, failing open (assume you are looking → stay quiet):

1. `lsappinfo` reports the frontmost app (~12ms, no macOS permissions). Not the terminal → you are elsewhere, notify.
2. If the terminal *is* frontmost, the extension checks that you are looking at *this* pane: inside herdr `herdr pane current` reports whether this pane is the session's active pane; in a bare Ghostty window AppleScript asks Ghostty for `focused terminal of selected tab of front window` (~95ms) and compares that pane's `working directory` and `name` against this pi session. A different pane means you are looking at another terminal, so you still get notified. Any failure here means "assume focused".

**3. Getting your attention.** In a bare Ghostty window the extension writes an OSC 777 notification escape sequence to pi's stdout. Ghostty turns it into a native macOS notification attributed to Ghostty itself (not `osascript`/Script Editor). `osc9`, `osascript`, and the terminal bell are available as fallbacks via `transport`. Inside herdr that sequence is swallowed by herdr's terminal emulator, so the notification is handed to `herdr notification show` instead — see below.

## Inside herdr

Run pi inside [Herdr](https://herdr.dev) (`HERDR_ENV=1`) and the extension adapts: herdr's server owns every pane pty and re-renders panes as a grid of cells through its client, so **escape sequences written by a pane — including OSC 777/9 — never reach Ghostty**. Writing them and hoping was the reason notifications silently stopped working.

- **Focus** comes from `herdr pane current`: `focused` says whether this pane is the active pane of its session, which the Ghostty AppleScript tiers cannot see. The frontmost-app check still runs, and because a herdr client can be hosted by any terminal, the extension also accepts a set of common macOS host terminals (Terminal, iTerm2, WezTerm, kitty, Alacritty, Warp, VS Code, …) plus the launching terminal's bundle id (`__CFBundleIdentifier`) there.
- **Delivery** goes through `herdr notification show`, which honours herdr's own popup setting:

| `[ui.toast] delivery` | What herdr would show | What the extension does |
|---|---|---|
| `system` | macOS notification (`terminal-notifier`, else `osascript`) | sends through herdr |
| `terminal` | OSC 9 to the outer terminal | sends through herdr when the terminal is **not** frontmost, otherwise a desktop notification — Ghostty silently drops OSC 9 while it is the active app |
| `herdr` | in-app toast, visible only in the terminal frame | desktop notification — a toast you cannot see while away is not a notification |
| `off` (herdr's default) | nothing | desktop notification |

"Desktop notification" means `terminal-notifier` when it is installed (properly attributed, click-to-activate) and `osascript display notification` only as a last resort — the Script Editor has to have notification permission, and on installs where it never registered, `osascript` exits 0 and shows nothing at all. `/nudge status` prints which one is in use.

So notifications work with herdr's default config, and setting a delivery makes herdr own the banner instead. Recommended, in `~/.config/herdr/config.toml`:

```toml
[ui.toast]
delivery = "system"
delay_seconds = 1
```

Then `herdr server reload-config` (or the client's `reload_config` binding) and `brew install terminal-notifier` — without it the desktop notification falls back to `osascript`, which needs the Script Editor to have notification permission.

Herdr also notifies on its own when a **detected pi agent finishes**, based on the state the `pi` integration reports (`herdr integration install pi`; check with `herdr integration status`). When that banner is guaranteed to be visible, this extension stays quiet instead of sending a second one. Herdr has no equivalent for approval prompts, so those always come from this extension. `/nudge status` prints the live herdr pane, its focus state, and the delivery it detected.

## Gotchas

These are real, verified against Ghostty 1.3.1, herdr 0.9.1, and macOS 26 — and they are why `/nudge test` can appear to do nothing:

- **macOS shows no banner when the notification's own app is frontmost.** `/nudge test` while you are staring at Ghostty is invisible by design. Use `/nudge test 5` and switch away.
- **Ghostty clears its delivered notifications the moment it becomes active.** Switch back to the terminal and the banner and its Notification Center entry disappear. This is good behaviour, but it means a notification you triggered and then immediately walked toward may vanish as you arrive.
- **Ghostty rate-limits notifications and suppresses identical repeats**, so a burst of the same message can collapse into one.
- **Only extension dialogs emit `ui_prompt_start`.** pi's built-in pickers (session/model/theme selectors, project-trust prompt, OAuth login) do not, so they do not trigger a notification. Waiting for you to *type* is covered by `agent_settled` instead.
- **Two pi sessions in the same directory are indistinguishable** by `working directory` + title, which can cause a missed notification (never a spurious one).
- **Inside herdr, the transport is not yours to pick.** `osc777`/`osc9` written by a pane are consumed by herdr's terminal emulator and never reach Ghostty, so `transport: "auto"` resolves to `herdr` there. Pin `osascript` if you would rather bypass herdr entirely; the terminal bell is relayed by herdr and keeps working either way.

## License

MIT
