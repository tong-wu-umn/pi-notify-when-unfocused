# Claude Code usage in the menu bar — implementation plan

| | |
|---|---|
| Status | **Implemented** |
| Scope | Display the Claude subscription's 5-hour and 7-day limit utilisation in PiMenuBar |
| Token cost | **Zero.** One HTTPS `GET` per refresh; no `claude` subprocess, no inference request |
| Compatibility target | macOS 13+, Swift 6 strict concurrency, Command Line Tools-only build |

## 1. Outcome

PiMenuBar gains one extra menu section, refreshed on a timer the user configures:

```
Claude Code usage — 12:46
  5-hour   78%  ⚠  resets in 2h 4m
  7-day     9%     resets Mon 04:00
Refresh usage now
```

and, if `showInTitle` is on, a suffix on the existing status title (`π 2▶ · 78%`).

Explicitly **not** in scope, per the request that drove this:

- No notifications, no banners, no reminders, no badge pulsing, no thresholds that
  interrupt. The warning glyph and colour are the entire signal.
- No LLM calls of any kind. The number is read from the same endpoint the `/usage`
  screen uses; it consumes no tokens.
- No transcription of the "what's contributing to your limits" coaching text, and no
  per-project / per-session breakdown.

## 2. Where the data comes from

`GET https://api.anthropic.com/api/oauth/usage`

Headers: `Authorization: Bearer <oauth access token>`, `anthropic-beta: oauth-2025-04-20`,
`anthropic-version: 2023-06-01`. Response (abridged, verified against a live Pro account):

```json
{
  "five_hour":  { "utilization": 78.0, "resets_at": "2026-10-23T16:50:00.147042+00:00" },
  "seven_day":  { "utilization": 9.0,  "resets_at": "2026-10-26T08:00:00.147064+00:00" },
  "limits": [
    { "kind": "session",    "percent": 78, "severity": "warning", "resets_at": "…", "is_active": true },
    { "kind": "weekly_all", "percent": 9,  "severity": "normal",  "resets_at": "…", "is_active": false }
  ],
  "seven_day_breakdown": { "rows": [ { "key": "claude_code", "percent": 100 } ] }
}
```

`limits[]` is the preferred source (it carries `severity`); `five_hour`/`seven_day` are the
fallback when only the older shape is returned. The endpoint is what the shipped CLI
calls, so treat it as stable-but-unofficial: every field is optional and a parse failure
degrades to "usage unavailable", never to a crash or an empty menu.

The access token lives in the login keychain as a generic password: service
`Claude Code-credentials`, account `<short user name>`, value
`{"claudeAiOauth":{"accessToken":"…","expiresAt":<ms epoch>,…}}`.

## 3. Configuration

One new object in `~/.pi/agent/menubar.json`, parsed with the same
clamp-and-ignore-malformed rules as everything else in `MenuBarConfig`:

```json
"claudeUsage": {
  "enabled": true,
  "refreshIntervalMs": 900000,
  "showInTitle": false,
  "warningPercent": 75
}
```

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | On by default so a fresh install shows usage without editing config. The first refresh causes a **one-time macOS keychain prompt** (§7). Set it to `false` to remove the section and stop all keychain/network activity. |
| `refreshIntervalMs` | `900000` (15 min) | The user-specified cadence. Clamped to `60_000…3_600_000`; 15 min ≈ 96 requests/day of a ~1 KB response. |
| `showInTitle` | `false` | Off by default because menu bar space is the scarcest resource in this app. When on: `π 2▶ · 78%`. |
| `warningPercent` | `75` | Fallback threshold for the ⚠ glyph when the API's own `severity` is absent. `≥90` renders red. |

## 4. Files and responsibilities

Core stays Foundation-only and unit-testable, exactly like `NotificationPolicy` /
`TitleFormatter`; anything that touches Security.framework or the network lives in the
AppKit target, exactly like `NotificationCoordinator`.

### New — `Sources/PiMenuBarCore/ClaudeUsage.swift` (~180 lines)

```swift
public struct ClaudeUsageLimit: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable { case normal, warning, critical }
    public var percent: Int              // rounded 0…999
    public var severity: Severity
    public var resetsAt: Date?
}

public struct ClaudeUsageSnapshot: Sendable, Equatable, Codable {
    public var fetchedAt: Date
    public var session: ClaudeUsageLimit?
    public var weekly: ClaudeUsageLimit?
    public var claudeCodeShare: Int?     // seven_day_breakdown row "claude_code"
}

public enum ClaudeUsageParser {
    /// Throws only when the body is not JSON; every missing field is tolerated.
    public static func parse(_ data: Data, now: Date, warningPercent: Int) throws -> ClaudeUsageSnapshot
}

public enum ClaudeUsageFormat {
    public static func titleSuffix(_ s: ClaudeUsageSnapshot) -> String       // "78% · 9%"
    public static func menuLines(_ s: ClaudeUsageSnapshot, now: Date) -> [(String, ClaudeUsageLimit.Severity)] // aligned columns
}

public enum ClaudeUsageCache {
    public static var path: String { … "Application Support/PiMenuBar/claude-usage.json" }
    public static func load() -> ClaudeUsageSnapshot?
    public static func save(_ s: ClaudeUsageSnapshot)     // 0600; never contains a token
}
```

Rules baked into the parser:

- Prefer `limits[]` `kind == "session"` / `"weekly_all"`; fall back to `five_hour` /
  `seven_day` `utilization`; missing either one is `nil`, not zero.
- Percent is `Double.rounded()` clamped to `0…999` — the API returns `78.0` and rounding
  (not truncating) keeps `99.6` from reading as `99`.
- `resets_at` parses with `ISO8601DateFormatter` set to
  `.withInternetDateTime, .withFractionalSeconds`, then retries with
  `.withInternetDateTime` alone. Both passes are required: the `limits[]` fields carry
  microseconds (`…16:50:00.147042+00:00`, which the fractional mode parses fine) while the
  legacy `five_hour`/`seven_day` fields currently omit them (`…08:00:00+00:00`, which
  fractional mode returns `nil` for). Verified on macOS 26.
- Unknown keys, `null` limits, and the long tail of feature-flag fields
  (`tangelo`, `iguana_necktie`, …) are ignored by construction.

### New — `Sources/PiMenuBar/ClaudeCredentials.swift` (~70 lines)

```swift
enum ClaudeCredential {
    struct Value { let token: String; let expiresAt: Date? }
    enum Failure: Equatable { case notFound, malformed, unreadable(OSStatus) }
    static func load() -> Result<Value, Failure>     // SecItemCopyMatching, in-process
}
```

- `kSecClassGenericPassword`, `kSecAttrService "Claude Code-credentials"`,
  `kSecReturnData true`, `kSecMatchLimitOne`. The account attribute is deliberately left
  unset so a renamed local account still resolves.
- Reads `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt` (ms epoch) from the
  returned JSON blob. Nothing else is consulted; the refresh token is **never** touched
  (§7).

### New — `Sources/PiMenuBar/ClaudeUsageMonitor.swift` (~130 lines)

```swift
enum ClaudeUsageState: Sendable, Equatable {
    case disabled
    case noCredentials
    case fresh(ClaudeUsageSnapshot)
    case stale(ClaudeUsageSnapshot, note: String)   // last good value + why it is old
}

@MainActor final class ClaudeUsageMonitor {
    private(set) var state: ClaudeUsageState
    var onChange: (() -> Void)?
    func start()                                  // load cache → immediate refresh → schedule timer
    func stop()
    func refreshIfStale(maxAge: TimeInterval)     // menu-open hook, min-gap guard = 60 s
    private func refresh()
}
```

- One `Timer` with `tolerance = interval * 0.1`, rescheduled on config change. No
  `DispatchSource`, no wake observer: a repeating timer fires once after sleep, and
  `refreshIfStale` covers menu opens.
- `refresh()` short-circuits to `.disabled` when `claudeUsage.enabled` is false, and does
  **not** touch the keychain in that case.
- Request: `URLSession` with `.ephemeral` configuration (no cookies, no cache),
  `timeoutIntervalForRequest = 10`, `User-Agent: PiMenuBar/<version>`.
- Failure handling, in order of likelihood: keychain `errSecItemNotFound` →
  `.noCredentials` (retried next tick, cheap, no prompt); HTTP 401 → re-read the keychain
  once (the CLI may have rotated the token), then `.stale(…, "re-authenticate")`; HTTP
  429/5xx or offline → `.stale(lastGood, "offline")`. Every case keeps the last good
  numbers on screen with their timestamp, and logs at `debug`/`warn` — never repeatedly at
  `error`.
- If `expiresAt` is in the past, skip the request entirely and report
  `.stale(…, "token expired — open Claude Code")`. We do not refresh it ourselves.

### Changed — `Sources/PiMenuBarCore/Config.swift`

Add `public var claudeUsage = ClaudeUsageConfig()` plus the nested struct and its
`parse(_:)`, following the file's existing `int`/`clamp` helpers. No change to any
existing key.

### Changed — `Sources/PiMenuBar/StatusItemController.swift` (~40 lines)

- New `var claudeUsage: (() -> ClaudeUsageState)?` supplied by `AppDelegate`, so the
  controller keeps no networking of its own.
- `rebuildMenu()`: after the notification block and before `Refresh now`, insert a
  separator, a disabled header line (`Claude Code usage — 12:46`, or the reason it is
  unavailable), one disabled line per limit (percent, ⚠/red prefix, aligned reset
  column), and `Refresh usage now`.
- `menuWillOpen`: call `onMenuOpened?()` so the monitor can `refreshIfStale(maxAge: 60)`.
  A stale refresh is therefore invisible in the common case and instant when the numbers
  are minutes old.
- `render(force:)`: when `showInTitle` is on and a snapshot exists, append
  ` · <suffix>`; colour that tail range orange/red when severity warrants it. The rest of
  the attributed title keeps its current "no foreground colour unless alerting" rule
  (§ existing comment in `attributedTitle`), so the dark-menu-bar fix stays intact.

### Changed — `Sources/PiMenuBar/AppDelegate.swift` (~25 lines)

Construct the monitor, `start()` it next to `client.start()`, `stop()` it in
`applicationWillTerminate`, refresh it from `configLoader.onChange`, and repaint via
`statusItem.scheduleRender()` in its `onChange`.

### Changed — `Sources/PiMenuBar/Probe.swift` (~15 lines)

`--probe` prints the cached value only (still offline-safe and deterministic):
`claude usage: 5h 78% (warning) · 7d 9% — cached 3m ago`.
A new `--probe-usage` does one live fetch and prints the parsed result, so
"why is my number different from `/usage`" is answerable from a terminal.

### New — `Tests/PiMenuBarTests/ClaudeUsageTests.swift` + fixture

`Fixtures/claude-usage.json` is the payload captured above with the token-bearing fields
absent (the response contains none). Registered in `Tests/PiMenuBarTests/main.swift`.

Cases: `limits[]` preferred over legacy fields · legacy-only payload still parses ·
`five_hour` without `seven_day` yields `weekly == nil` · percent rounding and clamping ·
malformed `resets_at` leaves `resetsAt == nil` but keeps the percentage · `severity`
fallback to `warningPercent` · cache round-trip preserves dates · unknown keys ignored ·
`menuLines` column alignment and reset wording · title suffix.

### Docs

`menubar/README.md`: a short "Claude Code usage (optional)" section — the three config
keys, the keychain prompt, and the four troubleshooting rows (no credentials, token
expired, 401 after re-login, offline). `make probe-usage` added to the `Makefile` help and
to the existing probe commands.

## 5. Implementation order

Each step leaves the build green and is reviewable on its own.

1. **Config** — `ClaudeUsageConfig` + parse + `ConfigTests` cases + README config block.
   *Verify:* `make test`.
2. **Core model** — `ClaudeUsage.swift` (parse/format/cache) + `ClaudeUsageTests` with the
   fixture. Nothing wired yet. *Verify:* `make test`.
3. **Credentials** — `ClaudeCredentials.load()`; check it standalone via
   `swift run PiMenuBar --probe-usage --credentials-only` (prints "found, expires in 2h",
   never the token). *Verify:* by hand, one keychain prompt, `Always Allow`.
4. **Monitor** — timer, state machine, `.ephemeral` URLSession, logging. *Verify:*
   `--probe-usage` live fetch; log shows one line per refresh at `info`.
5. **Menu + title** — menu section, `showInTitle` suffix, refresh-on-open. *Verify:*
   `make run`, numbers match `claude -p "/usage"`.
6. **Probe + docs** — `--probe` cache line, `make probe-usage`, README section.
7. **Polish** — `make install`, confirm the LaunchAgent copy behaves (no terminal
   environment), uninstall/reinstall to observe the keychain prompt behaviour in §7.

## 6. Verification

```bash
make test                                  # core suite, incl. ClaudeUsageTests
make build
swift run PiMenuBar --probe-usage          # live, prints parsed percentages
make probe                                 # offline, prints cached value
make app && open .build/PiMenuBar.app      # menu section + title suffix
claude -p "/usage"                         # cross-check the same numbers
```

Acceptance: the session and weekly percentages match `/usage` within a minute; a
disconnected network leaves the last numbers visible with their timestamp and no error
dialog; `enabled: false` produces no keychain access and no network traffic (verify with
`log stream --predicate 'process == "PiMenuBar"'` plus no keychain prompt); the app's own
token cost stays at zero — no `claude` process is ever spawned.

## 7. Risks and decisions

| Risk | Decision |
|---|---|
| **Keychain prompt.** Reading another app's item shows "PiMenuBar wants to use your confidential information stored in Claude Code-credentials" the first time. | Inherent to the design; the feature is on by default, so the prompt appears on first launch unless `claudeUsage.enabled` is set to false. Document "Always Allow". Because installs are ad-hoc signed, a rebuilt/reinstalled binary is a different code identity and may prompt again — call that out in the README rather than pretend otherwise. |
| **Token rotation.** The refresh token is single-use; consuming it could log the CLI out. | Never refresh. Past `expiresAt`, stop polling and say "token expired — open Claude Code". The CLI refreshes on its own and our next tick picks the new value up. |
| **Unofficial endpoint.** It can change shape or gain a required header. | Every field optional, `limits[]` with legacy fallback, cache-first rendering, `--probe-usage` for diagnosis. A failed parse shows the last good value and never wedges the menu. |
| **Menu bar space.** | `showInTitle` off by default; the menu section is the primary surface. |
| **Timer drift / sleep.** | A repeating timer fires once after wake; menu opens force a bounded refresh (`maxAge: 60`). No wake notifications needed. |
| **Privacy.** The cache file holds percentages and timestamps only — no token, no account id, no per-project usage. Token stays in memory for the process lifetime. | |

## 8. Rollback

Set `"claudeUsage": {"enabled": false}` (or delete the key). The monitor then stops
touching the keychain and the network, the menu section disappears, and nothing else in
the app observes it. Deleting `~/Library/Application Support/PiMenuBar/claude-usage.json`
removes the cached numbers.

## 9. Deliberately deferred

- Per-model (`seven_day_opus` / `seven_day_sonnet`) sub-limits — same payload, no new
  plumbing, add when a plan actually has them.
- A 7-day sparkline or history file — needs a sampler and a chart; not worth it for a
  number that resets twice a day.
- Extra-usage credits / dollar balances (`spend`, `extra_usage`) — currently disabled on
  this account and never enabled by PiMenuBar.
- The "what's contributing to your limits" coaching text — the `/usage` screen's job, and
  it reads as advice, not state.
