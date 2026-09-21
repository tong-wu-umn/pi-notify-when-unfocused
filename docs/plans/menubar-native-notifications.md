# PiMenuBar-owned native macOS notifications — implementation plan

| | |
|---|---|
| Status | **Implemented** — see [§11 Implementation record](#11-implementation-record) |
| Scope | Option A: keep native macOS notifications, but post them from `PiMenuBar.app` rather than from Ghostty/`osascript` |
| Prerequisite | PiMenuBar registry publisher installed; herdr is strongly recommended for exact-pane focus |
| Compatibility target | macOS 13+, Swift 6 strict concurrency, Command Line Tools-only build |

## 1. Outcome and terminology

This is **not** a custom popover hanging from the status item. It remains a normal macOS
banner/Notification Center notification, but it is owned by the bundled
`PiMenuBar.app`:

- Notification Center labels it **PiMenuBar** and uses the PiMenuBar app icon.
- It is no longer attributed to Ghostty, subject to Ghostty's OSC rate limiter, or
  cleared merely because Ghostty becomes active.
- PiMenuBar can add native **Focus** and **Mark seen** actions that use its existing
  `Focuser` and acknowledgement store.
- macOS still owns notification style, Focus/DND handling, sound, grouping, and
  Notification Center history.

A status-item badge remains the persistent, glanceable state. Native notifications are
the interruptive channel; they do not replace the menu bar counts or rows.

## 2. Scope, non-goals, and compatibility decision

### In scope

1. Post local notifications through `UNUserNotificationCenter` from PiMenuBar.
2. Detect newly blocked and newly completed sessions from the menu bar's merged session
   state, apply the same broad policy as `/nudge`, and schedule bounded prompt reminders.
3. Suppress delivery when the user is demonstrably looking at the affected session.
4. Supply native Focus / Mark seen actions, safe notification cleanup, tests, and
   migration documentation.
5. Add a proper bundled PiMenuBar icon so the sender is recognisable in Notification
   Center.

### Explicit non-goals

- No custom `NSPopover`, floating toast, overlay, or always-on-top panel.
- No attempt to read macOS Focus/DND state. There is no supported public API for that;
  native notifications deliberately let macOS apply the user's Focus and notification
  settings.
- No notification relay from the pi extension and no Unix-socket/event-spool protocol.
  PiMenuBar already observes the state needed to make the decision. Keeping one owner
  avoids two dedupe/reminder implementations.
- No change to the current status-row acknowledgement semantics in this feature. The
  notifier will use its own real macOS focus check rather than assuming that herdr's
  `focused` flag means the host terminal app is on screen.

### Duplicate-notification migration policy

The existing root extension (`extensions/notify-when-unfocused.ts`) continues to work
unchanged. It must **not** be left enabled alongside this feature, or Ghostty and
PiMenuBar can legitimately both alert for one wait.

For the first release, native menu-bar notifications are **opt-in** (`enabled: false` by
default). This avoids changing behaviour for existing PiMenuBar users and makes the
migration explicit:

1. install/run PiMenuBar and its publisher extension;
2. disable the legacy `/nudge` extension (`"enabled": false` in
   `~/.pi/agent/notify-when-unfocused.json`, or unload the root extension);
3. set `notifications.enabled` below to `true`;
4. use **Send test notification** to grant permission and verify the sender.

Do not try to infer whether the legacy extension is loaded from a config file: config
presence is not proof that the extension is installed, and a wrong inference would
silently remove alerts. The UI and documentation must instead state the conflict
plainly.

## 3. User-visible policy

### 3.1 Configuration

Extend the shared `~/.pi/agent/menubar.json` schema with a nested value. Unknown keys
remain ignored by the registry publisher, so this is backwards compatible.

```json
{
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
  }
}
```

Validation/clamps match the existing nudge extension:

| Key | Default | Rule |
|---|---:|---|
| `enabled` | `false` | Master switch. Does not request notification permission while false. |
| `notifyOnPrompts` / `notifyOnIdle` | `true` | Enable blocked / completed triggers independently. |
| `idleMinRunMs` | 15,000 | Clamp 0…600,000. A known shorter run is quiet. |
| `reminders` | 2 | Clamp 0…10; only applies while the *same* prompt remains blocked. |
| `reminderIntervalMs` | 20,000 | Clamp 5,000…600,000. |
| `dedupeMs` | 10,000 | Clamp 0…600,000; applies across different sessions and trigger kinds. |
| `sound` | `true` | Requests the default sound; macOS/user settings still decide actual playback. |
| `preciseFocus` | `true` | Enables Ghostty's registry-only pane fallback (§5). |
| `notifyUnknownDurationCompletions` | `false` | Normally suppress a herdr-only completion when no reliable run duration exists. |
| `showProjectName` | `true` | When false, bodies use “A pi session” rather than a project/session label. |

`MenuBarConfig` gets a `NotificationConfig` value with these defaults. Its manual JSON
parser should accept a `[String: Any]` at `notifications`, retain defaults for bad
members, and leave the last-good config active on a malformed edit as it does now.

### 3.2 Alert content and privacy

Do not place prompt previews, command text, CWDs, session-file paths, or raw registry
`stateLabel` strings in Notification Center. Notifications are visible on the lock
screen and retained outside PiMenuBar's private registry.

Default content is deliberately generic:

| Event | Title | Body (`showProjectName: true`) |
|---|---|---|
| blocking pi UI | `π needs your input` | `Approval or input is needed in <session label>.` |
| reminder | `π still needs your input` | `Still waiting in <session label>.` |
| settled run | `π finished` | `<session label> is waiting for your next message.` |
| manual test | `π test notification` | `PiMenuBar native notifications are working.` |

`<session label>` is the already-sanitized session name/project and is capped again at
60 characters at notification formatting time. The actual prompt kind (`confirm`,
`select`, `input`, …) can choose the generic phrase, but the prompt's title is never
shown. No sensitive identifier goes in `UNNotificationContent.userInfo`; it contains
only an opaque route UUID and a schema version.

### 3.3 Permission, status, and test UX

- Register the notification categories at app launch, but **never** prompt for permission
  merely because PiMenuBar launched or a registry heartbeat arrived.
- When native notifications are enabled, **Send test notification** requests
  authorization if the status is `.notDetermined`; after authorization succeeds it sends
  the test. This is the recommended setup path.
- If the first real eligible nudge arrives before a test, it may make the same one-time
  request because the user explicitly set `notifications.enabled: true`. Revalidate the
  session after the asynchronous prompt before delivering anything.
- For `.denied`, do not retry or spam dialogs. The menu presents a disabled status line
  explaining that PiMenuBar notifications are disabled in System Settings and an
  **Open Notification Settings…** item.
- Add a menu section: `Notifications: Off`, `Notifications: Ready`,
  `Notifications: Permission required`, or `Notifications: Disabled by macOS`, followed
  by **Send test notification** and **Open Notification Settings…**.
- `--probe` remains side-effect free: it neither initializes the coordinator nor asks for
  permission.

## 4. Architecture and data flow

```
registry + herdr ──> SessionStore.recompute ──> NotificationCoordinator.reconcile
                                                    │
                                                    ├─ NotificationPolicy (pure diff /
                                                    │  generations / timers / dedupe)
                                                    ├─ FocusResolver (async, fail open)
                                                    ├─ UNUserNotificationCenter
                                                    └─ NotificationRouteStore (opaque action routes)
```

PiMenuBar, not the pi extension, is the notification policy and delivery owner. The
publisher is still required for completion timing, `waitingSince`, and registry-only
sessions; herdr provides the strongest exact-pane focus signal.

### 4.1 Files and responsibilities

| File | Change |
|---|---|
| `menubar/Sources/PiMenuBarCore/Config.swift` | Add `NotificationConfig` parsing, defaults, and validation. |
| `menubar/Sources/PiMenuBarCore/NotificationPolicy.swift` | Pure candidate/generation, baseline, reminder, dedupe, content, and cleanup decisions. No AppKit/UserNotifications import. |
| `menubar/Sources/PiMenuBarCore/NotificationRouteStore.swift` | Atomically persist opaque native-notification routes at `~/Library/Application Support/PiMenuBar/notification-routes.json` (`0700` directory, `0600` file). |
| `menubar/Sources/PiMenuBar/FocusResolver.swift` | Asynchronous frontmost-app and exact-pane verdicts; converts platform evidence into a pure focus-policy input. |
| `menubar/Sources/PiMenuBar/NotificationCoordinator.swift` | Owns UserNotifications calls, timers, route lifecycle, permission state, and policy reconciliation. |
| `menubar/Sources/PiMenuBar/AppDelegate.swift` | Construct/wire the coordinator, set the notification delegate early, and forward native actions to `Focuser`/`SessionStore`. |
| `menubar/Sources/PiMenuBar/StatusItemController.swift` | Render notification status and expose test/settings callbacks. |
| `menubar/Package.swift` | Link `UserNotifications` for the app executable if SwiftPM does not link it transitively. |
| `menubar/Resources/PiMenuBar.icns`, `Info.plist`, `Makefile` | Add `CFBundleIconFile`, copy the icon into the app bundle, and verify the installed build has it. |

Do not make `PiMenuBarCore` depend on UserNotifications or AppKit. The existing
Command-Line-Tools test executable must keep testing policy without a GUI session.

### 4.2 Stable attention generations

`NotificationPolicy` operates on *generations*, not on every state snapshot:

```swift
enum AttentionKind { case prompt, completion }
struct AttentionGeneration: Hashable {
    let identity: String
    let kind: AttentionKind
    let marker: Int64             // waitingSince, settledAt, or stateChangeSeq
}
```

`identity` is `pane:<paneId>` when herdr is available, otherwise `session:<sessionFile>`
or the existing session key. Prefer the pane ID because a registry record may arrive
slightly after a herdr row and change the existing merge key; it is stable for the life
of the pane. Reuse of a pane after restart is safe because the generation marker differs.

Generation rules:

- **Prompt:** a session in `.blocked` with a non-null `waitingSince` forms
  `(identity, .prompt, waitingSince)`. Missing `waitingSince` fails quiet rather than
  inventing a heartbeat-driven generation.
- **Completion:** a `.done` session with herdr `stateChangeSeq`, or an `.idle`/`.done`
  registry session with `settledAt`, forms `(identity, .completion, marker)`. Prefer
  `settledAt` when present so it can be paired with `runStartedAt` for the duration
  threshold.
- Suppress `session.simulated`; `/menubar simulate` must never create a real banner.
- The first `reconcile` after launch/config enable establishes a baseline. It can remove
  routes whose matching generation no longer exists, but it **never sends historical
  notifications**. A PiMenuBar restart must not replay every old blocked/done row.
- On later reconciliations, only an unseen generation starts delivery. Heartbeats,
  repeated snapshots, and an unchanged merged row do nothing.

A completion sends only if `notifyOnIdle` is true and either:

1. both `runStartedAt` and `settledAt` exist and duration is at least
   `idleMinRunMs`; or
2. `notifyUnknownDurationCompletions` is explicitly enabled.

This keeps the current “do not alert on short replies” guarantee and avoids guessing
from a herdr-only `done` row.

### 4.3 Reminders, dedupe, and cleanup

For each blocked generation, the coordinator keeps one in-memory delivery state:
`initialAttempted`, `remindersRemaining`, `lastDeliveryAt`, timer, and route ID.

1. Attempt initial delivery as soon as a new generation is observed.
2. If it is suppressed because that session is focused, do not send; schedule the normal
   reminder check. This preserves current behaviour where the user can switch away while
   the same prompt remains open and receive the later reminder.
3. Each reminder revalidates that the exact generation still exists, resolves focus again,
   applies global `dedupeMs`, and posts only when unfocused.
4. Different candidates inside `dedupeMs` are skipped for that attempt; their next normal
   reminder may still deliver. This matches the root extension's prompt-after-idle
   behaviour without losing a genuinely still-blocked prompt.
5. A prompt ending, session disappearance, next agent run, completion acknowledgement,
   or an explicit Focus/Mark-seen action cancels the matching timer and its *pending*
   reminders. A banner that was already delivered stays in Notification Center: the app
   acknowledges a completion the moment the user is back at its pane, which is exactly
   when they go looking for the notification whose sound brought them back, and retracting
   it hid the very thing the sound announced. macOS removes the banner itself when the
   user acts on it or dismisses it. The route is kept so the banner's actions keep
   working until the seven-day prune.
6. Manual notification dismissal cancels further reminders for that generation but does
   **not** acknowledge the PiMenuBar completion badge. Dismissing a banner is not proof
   the user inspected the session.

All async paths must re-check the current generation after a focus query or permission
prompt returns; a prompt may have been answered while `osascript` or authorization was
in flight.

## 5. Focus-resolution contract

A native notification must be suppressed only with positive evidence that the user is
looking at **that session**. Any missing evidence returns `focused` (quiet), matching
the existing extension's fail-open safety policy.

`FocusResolver.resolve(session:)` runs off the main actor with a bounded timeout and
returns a testable evidence value. Its decision order is:

1. Read `NSWorkspace.shared.frontmostApplication` on the main actor. Resolve the
   expected terminal bundle ID from `session.terminalBundleId`, then
   `MenuBarConfig.terminalBundleId`.
2. If no frontmost application or no expected terminal identity is available, return
   `.unknownAssumeFocused`.
3. If the frontmost bundle ID differs from the expected terminal, return `.unfocused`.
4. If it matches and a fresh herdr snapshot has a row for the session, use the herdr pane
   selection: selected pane => `.focused`; another pane => `.unfocused`. This is the
   normal, exact pane-aware path.
5. For a registry-only Ghostty session when `preciseFocus` is true, use the existing
   bounded AppleScript query (`focused terminal of selected tab of front window`) on a
   background queue and compare the returned working directory and π/pi title marker.
   A matching pane is `.focused`; a different terminal is `.unfocused`.
6. An Automation denial, timeout, malformed AppleScript output, same-directory ambiguity,
   stale herdr snapshot, or unknown terminal type is `.unknownAssumeFocused`.

The herdr `Session.focused` field is not by itself proof that Ghostty is frontmost, so it
must never be the only condition used for a banner. It becomes definitive only after the
frontmost-app check succeeds.

Keep the exact-prompt fallback Ghostty-only in this release; other terminal identifiers
receive conservative app-level behaviour rather than a fragile shell/Accessibility
implementation. Log a rate-limited diagnostic only, never a CWD or prompt string.

## 6. Native notification delivery and actions

### 6.1 UserNotifications setup

- `AppDelegate` registers `UNNotificationCategory` values before any request:
  - `dev.tongwu.PiMenuBar.attention`: **Focus session** (`.foreground`) and
    **Mark seen** actions, plus `.customDismissAction`.
  - `dev.tongwu.PiMenuBar.test`: no custom action required.
- `NotificationCoordinator` calls `UNUserNotificationCenter.current().add(...)` with
  a locally generated request ID and `UNMutableNotificationContent` containing the
  category, body, optional default sound, and opaque route ID.
- Set the center delegate before app launch finishes. In `willPresent`, request `.banner`
  and `.list`, plus `.sound` when configured, so a notification remains visible even if
  PiMenuBar is technically active.
- Swift 6 note: UserNotifications delegate callbacks may arrive outside the main actor.
  Implement the imported Objective-C callbacks with explicit nonisolated boundaries,
  immediately hop to `Task { @MainActor in ... }`, and call the supplied completion
  handlers exactly once. Do not make socket/file I/O on the main actor.

### 6.2 Opaque action routes

`NotificationRouteStore` persists:

```json
{
  "v": 1,
  "routes": {
    "<uuid>": {
      "sessionKey": "<internal key>",
      "paneId": "w1:p1",
      "generation": "prompt:1758450000000",
      "requestId": "dev.tongwu.PiMenuBar.alert.<uuid>",
      "createdAt": 1758450000000
    }
  }
}
```

The UUID, not the session path/key, is the sole value in `content.userInfo`. Routes are
atomically written and pruned after seven days; they are removed sooner only on an
explicit dismissal action, never because a wait ended (a delivered banner may still be
needed to explain the sound the user just heard).

Action handling:

- **Focus session** and clicking the notification's default action resolve the route to
  the current live session, call existing `Focuser.focus`, and acknowledge only on the
  same successful/partial-herdr conditions already used by the menu row.
- **Mark seen** calls `SessionStore.acknowledge` without focusing; it is available for
  completions and omitted/disabled for an active blocked prompt.
- **Dismiss** stops reminders but leaves PiMenuBar's completion acknowledgement intact.
- If the route is expired or the session no longer exists, log a short diagnostic and
  finish successfully; never launch a shell command or attempt a best-guess terminal
  focus.

## 7. Implementation phases

### P0 — contracts and compatibility guardrails

1. Add this plan as the source of truth and add a concise “planned native notifications”
   reference to the existing menu-bar plan.
2. Freeze the JSON defaults, content privacy policy, generation rules, and opt-in/
   legacy-extension migration wording above.
3. Capture real fixtures for blocked → answered, long run → settled, and a herdr pane
   focused while Ghostty is and is not frontmost. Verify the semantics of herdr's
   `focused` field rather than assuming it represents macOS activation.

**Accept:** the team can state exactly why a notification is or is not sent for every
state transition, and native mode has no default duplicate path.

### P1 — pure configuration, policy, and route storage

1. Implement `NotificationConfig` in `Config.swift`; preserve last-good semantics.
2. Implement pure `NotificationPolicy` with injected clock/timer intent, no platform
   imports. Feed it ordered `[Session]` snapshots and have it return
   `send`, `schedule`, `cancel`, and `remove` intents.
3. Implement `NotificationRouteStore` with version validation, atomic replace,
   owner-only permissions, corrupt-file fallback, and pruning.
4. Add the `attentionIdentity` helper and generation marker rules without changing
   existing row rendering/acknowledgement behaviour.

**Accept:** all generation, duration, startup-baseline, reminder, dedupe, and cleanup
logic passes in the normal Swift test executable with no AppKit session.

### P2 — native delivery shell and permissions

1. Add the UserNotifications link/import, categories, permission-status cache, content
   formatter, test delivery, and rate-limited logging.
2. Add `PiMenuBar.icns`, update `Info.plist`, and copy resources in `make app`; manually
   verify the installed app, not only `.build`, is the visible sender/icon.
3. Add StatusItemController notification state/test/settings items and callbacks.
4. Keep the coordinator disabled unless config enables it; ensure `--probe` stays inert.

**Accept:** a user-enabled test notification shows “PiMenuBar”, carries the expected icon
and sound policy, appears in Notification Center, and denied permission is clear but
non-disruptive.

### P3 — lifecycle integration and focus suppression

1. Construct the coordinator in `AppDelegate`, feed every post-merge session snapshot to
   `reconcile`, and feed acknowledgement/focus actions back for cleanup.
2. Implement `FocusResolver` with injected command/frontmost-app adapters for tests,
   strict timeouts, and no main-thread process execution.
3. Wire native action responses to `Focuser` and `SessionStore`; correctly clean routes
   and delivered requests as states resolve.
4. Exercise config reload: disabling notifications cancels timers and removes pending
   requests; re-enabling establishes a fresh baseline rather than replaying history.

**Accept:** browser/unrelated-app and other-Ghostty-pane cases alert; the exact active
pane does not; a later reminder alerts after the user leaves an open prompt; no alert is
emitted solely from a heartbeat or app restart.

### P4 — migration, docs, and release hardening

1. Update `menubar/README.md` sections that currently say “No notifications”; document
   native ownership, config, permission, actions, privacy, and duplicate prevention.
2. Update root `README.md` with a clear choice: legacy Ghostty nudge **or** PiMenuBar
   native notifications, not both. Keep root extension install/use unchanged.
3. Update the parent status-bar plan's P5 notification item to reference this plan and
   remove the `terminal-notifier -open` proposal if this plan ships.
4. Add a migration checklist to `make install` output, but do not edit either config file
   automatically.

**Accept:** a new user can enable and test PiMenuBar-owned native alerts without reading
source; an existing `/nudge` user cannot miss the “disable one channel” instruction.

## 8. Test matrix

### Automated

**`NotificationPolicyTests.swift`**

- first snapshot establishes a quiet baseline;
- blocked → blocked heartbeat emits exactly one initial candidate;
- prompt close cancels timer; a new `waitingSince` creates a new generation;
- focused initial prompt schedules (but does not send) a later reminder;
- short, exact-threshold, and unknown-duration completions obey configuration;
- simulated rows, stale repeated snapshots, identity key changes, and app restart do not
  create duplicate delivery;
- global dedupe suppresses only that attempt and leaves an eligible reminder;
- acknowledgement/resolution removes the matching native request but not unrelated rows.

**`FocusPolicyTests.swift` / adapter tests**

- non-terminal frontmost app is unfocused;
- terminal + fresh selected herdr pane is focused;
- terminal + a different fresh herdr pane is unfocused;
- unavailable/stale evidence and AppleScript failure assume focused;
- Ghostty result matches only with both same CWD and title marker;
- timeout/cancellation cannot later send an obsolete generation.

**`NotificationRouteStoreTests.swift`**

- opaque UUID rather than session key enters userInfo;
- route round-trip uses owner-only atomic storage;
- corrupt/future data fails empty; pruning and cleanup are idempotent;
- response to a gone session is harmless.

Use a `UserNotificationDelivering` protocol and fake center to test request identifiers,
content, category, sound option, and cleanup without requiring macOS permission in CI.

### Manual release matrix

1. Native test notification shows **PiMenuBar** and its icon; Ghostty activation does not
   clear it merely because Ghostty became active.
2. A prompt while viewing its exact Ghostty pane is quiet; switch to a browser or a
   different Ghostty pane while it remains open and observe the reminder.
3. A 14-second run is quiet; a 15+-second run not in view notifies once.
4. Permission denied, later enabled in System Settings, config-disabled, and Focus mode
   each behave without crash or repeated authorization prompts.
5. Clicking banner/action selects the exact herdr pane and activates the terminal;
   Mark seen clears only the completed badge.
6. Answering a prompt, starting a new agent run, and acknowledging a completion remove
   stale delivered cards; manually dismissing an alert does not mark the completion seen.
7. Quit/restart PiMenuBar with old blocked/done rows: badges return, but banners do not
   replay. Confirm no duplicate Ghostty alert after legacy `/nudge` is disabled.
8. Test the installed LaunchAgent environment with no shell `PATH` or `HERDR_*` values.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Users enable both delivery channels | Native mode is opt-in; migration docs/menu/install output explicitly require disabling legacy `/nudge`. |
| herdr `focused` is mistaken for frontmost-app focus | Require `NSWorkspace` terminal match before trusting a fresh herdr pane selection. |
| Registry-only focus cannot be determined | Ghostty fallback only; otherwise fail open (quiet) rather than interrupting the active pane. |
| Historical rows replay after restart | Baseline-only startup; reconcile cleans stale routes but never creates new delivery from baseline. |
| Native banner exposes prompt text on lock screen | Generic body by default, sanitized labels only, opaque userInfo, no preview/CWD/session path. |
| Notifications become stale | Generation-specific cancellation/removal on prompt close, run start, acknowledgement, disappearance, and config disable. |
| AppKit/UserNotifications concurrency violation | Pure core policy, explicit nonisolated delegate boundary, actor hops, and strict Swift 6 build verification. |
| Bundle displays a generic icon | Bundle an `.icns`, update `Info.plist` and Makefile copy rules, verify installed app manually. |

## 10. Definition of done

Option A is complete when PiMenuBar can be deliberately enabled as the **sole** alert
owner, posts a visible native notification attributed to PiMenuBar for an unfocused
blocked/eligible-completed session, respects macOS permission and Focus settings,
avoids duplicate/replayed/stale alerts, and turns notification actions into the same
safe focus/acknowledgement behaviour as its menu rows.

---

## 11. Implementation record

Built in one pass against P0–P4. What changed against the plan, and what still needs a
human or a real desktop session:

**Landed**

| Area | Where |
|---|---|
| `NotificationConfig` (defaults, clamping, `notifications` block) | `PiMenuBarCore/Config.swift` |
| Generations, reminders, dedupe, baseline, duration gate | `PiMenuBarCore/NotificationPolicy.swift` |
| Banner text, categories, action ids, sanitizer, status labels | `PiMenuBarCore/NotificationContent.swift` |
| Focus decision table | `PiMenuBarCore/FocusPolicy.swift` |
| Opaque action routes (`0700`/`0600`, atomic, 7-day prune) | `PiMenuBarCore/NotificationRouteStore.swift` |
| Frontmost app + herdr pane + bounded Ghostty probe | `PiMenuBar/FocusResolver.swift` |
| UserNotifications delivery, permission, actions, deadlines | `PiMenuBar/NotificationCoordinator.swift` |
| Wiring, shared focus path, System Settings deep link | `PiMenuBar/AppDelegate.swift` |
| Notifications menu section (status, test, settings) | `PiMenuBar/StatusItemController.swift` |
| Bundle icon, `CFBundleIconFile`, `make app`/`make icon` | `Resources/PiMenuBar.icns`, `Resources/Info.plist`, `Makefile`, `dev/make-icon.swift` |
| Tests (43 new: policy, content, routes, focus) | `Tests/PiMenuBarTests/{NotificationPolicy,NotificationContent,NotificationRouteStore,FocusPolicy}Tests.swift` |

**Deliberate deviations**

1. **Two categories, not one.** `attention.prompt` offers only *Focus session*;
   `attention.completion` adds *Mark seen*. A single category cannot hide an action per
   notification, so the plan's one-category sketch became two (`NotificationCategory`).
2. **Content tests replaced the fake notification centre.** The test target can only
   import `PiMenuBarCore` (an executable target is not importable), so content, category,
   request-id and cleanup decisions live in pure Core types and are tested there;
   `NotificationCoordinator` is a thin executor.
3. **Dedupe uses “reserved” time, not “delivered” time.** Three prompts appearing in one
   reconcile would otherwise produce three banners, because the delivery callback is
   asynchronous. `lastReservedAt` gates the emit step and `lastDeliveryAt` gates the
   post-probe re-check.
4. **A cancelled generation is retired, not deleted.** A row that flickers out of one
   snapshot (`herdr` reconnecting, a registry file mid-rewrite) keeps its attempt count and
   delivery time for 15 minutes, so its reappearance resumes the queued reminder instead of
   starting a new banner series.
4. **The focus probe backs off for 60 s after a failure.** A denied or unanswered
   Automation consent prompt otherwise spawns (and kills) an `osascript` on every attempt.
   The probe also gets `SIGKILL` after its 3 s timeout so a blocked helper cannot pin a
   thread.
5. **`NotificationStatus` lives in Core** so the menu only maps an enum to a label, and
   the mapping is unit tested.

**Found in real use, after the first genuinely unfocused completion was missed**

Both bugs only affected *completions*; prompts were never lost, which is why the first
round of testing looked healthy.

1. **herdr's live status masked a fresh registry completion.** `SessionMerger` let a
   fresh herdr snapshot's `working` override the registry's `idle` + `settledAt`, so a
   finished run stayed "working" until herdr's own status update reached the app — up to
   a 30 s snapshot gap, since the event stream re-subscribes on a 30 s read timeout. The
   notification policy only considers `.blocked`, `.idle`, and `.done`, so it never saw a
   candidate. A wait the registry reports now wins over herdr's `working`, exactly like
   the existing registry-`.blocked` rule (`SessionMergerTests`).
2. **The row-level auto-acknowledge swallowed the notification.** `SessionStore`
   acknowledged any completed session whose *herdr* pane was selected, and the notifier
   reads the same acknowledgement store — so a run that settled while the user was in
   another application was marked seen before `NotificationPolicy` was ever consulted.
   The auto-acknowledge now requires the app's own macOS focus check
   (`FocusPolicy.preliminary == .focused`: host terminal frontmost *and* this session's
   pane selected). This is a deliberate change to the status-row acknowledgement
   semantics in the status-bar plan (rule 4): a lingering badge is harmless, a lost
   "π finished" is not.
3. Verified live after the fix, with real candidates fed through the real pipeline: a
   completion on a herdr-selected pane while herdr still said `working` produced a
   PiMenuBar banner; a real blocked prompt in a live pi session produced one while the
   user was in another application; clicking it ran **Focus session** and focused the
   pane; the reminder series posted at +20 s and +40 s and stopped at `reminders`.

**Found in real use, round 2: "I hear the sound but see no notification"**

The sound turned out to be herdr's own `Done` cue (herdr plays its own `Request`/`Done`
sounds), which PiMenuBar neither controls nor mirrors — so the report really meant "the
run finished and PiMenuBar showed nothing". Three defects compounded that:

1. **A settled pi run was never presented as finished.** `Session.displayState` only
   reported `.done` for herdr's `done` status, which the pi integration never sends — it
   reports `idle` the moment a run ends. So a registry completion with
   `needsAttention == true` still rendered as `·`, and the `○` never appeared in the
   title, the tooltip, or a row. Presentation now follows attention: settled and unseen is
   finished (`FinishedRunShowsTheFinishedGlyphUntilAcknowledged`).
2. **Attention used herdr's pane selection as "the user is looking".** That flag keeps
   pointing at the last-used pane while the user is in another application, so a
   completion on that pane was never attention — no `○`, and (before the previous fix) no
   notification either. The badge now uses the same live macOS focus check as the
   notifier, factored into `SessionFocus` and shared with `--probe`, so the menu, the
   banner, and the probe cannot disagree (`SessionFocus.withAttention`).
3. **A delivered banner was retracted as soon as the wait ended** — including the
   acknowledgement that fires when the user comes back to the pane, i.e. exactly when they
   would look for the notification whose sound brought them back. `removeNotification` now
   cancels pending reminders only and leaves the banner (and its route, so **Focus
   session** still works) in Notification Center; macOS removes it when the user acts on
   it or dismisses it. Verified: the auto-ack fires, the wait is cancelled, and no
   `Removed banner notification` reaches the notification daemon.

Also fixed while reproducing: the auto-acknowledge no longer repeats on every recompute
for an already-acknowledged completion (it repainted the menu every few seconds while a
finished session stayed selected).

**Still needs a human**

1. ~~Grant notification permission once (**Send test notification**) and confirm the banner
   is attributed to PiMenuBar with its icon.~~ **Verified on this machine**: the first
   request was refused outright by macOS (`Notifications are not allowed for this
   application`, status `.denied`, no prompt shown) because the login item execs the binary
   rather than launching the bundle through LaunchServices. Toggling *PiMenuBar* on by hand
   in *System Settings → Notifications* fixed it; two test notifications then posted and the
   status settled on `ready`. The failure mode is safe by design (`.denied` is explained in
   the menu with a direct link to that pane, and nothing retries in a loop), and it is
   documented in the menubar README's troubleshooting table.
2. Grant *Privacy & Security → Automation → PiMenuBar → Ghostty* once. Measured here:
   a bare `osascript` for the probe **hangs** until that consent is answered, which is why
   the fail-open timeout and backoff exist. Until it is granted, pane-precise suppression
   degrades to app-level suppression (quieter, never louder).
3. The broader manual matrix in §8 was not executed end to end: the machine's installed
   PiMenuBar (single-instance lock) was left running, and `swift run` cannot post
   notifications because `UNUserNotificationCenter` needs a bundle. Verified from the live
   log instead: config reload without restart, baseline with no replay, `.denied` → `ready`
   transition, test delivery, an unfocused completion, the reminder series, and **Focus
   session** on a banner. Still unverified by hand: **Mark seen** on a banner, and the
   banner being removed when the prompt is answered or the session acknowledged.
