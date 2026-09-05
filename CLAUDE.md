# usage-menubar

Native macOS menu bar app (SwiftUI `MenuBarExtra`) showing live Codex,
account-wide Claude, and account-wide Grok rate-limit quotas. Built as a self-hosted replacement for
`shanggqm/codexU` — same idea, no third-party binary.

## How it works

Polls Anthropic's OAuth usage endpoint at most every five minutes using Claude Code credentials
from macOS Keychain. This account-wide reading includes both claude.ai and
Claude Code usage. Reads local JSON snapshots for Codex and Claude fallback:
- `~/.claude/usage-dashboard/claude-rate-limits.json`
- `~/.claude/usage-dashboard/claude-rate-limits-merged.json`
- `~/.claude/usage-dashboard/codex-rate-limits.json`

These files are written by the companion dashboard project at
`~/.claude/usage-dashboard/` ([theglove44/usage-dashboard](https://github.com/theglove44/usage-dashboard),
own git repo, separate from this one) — statusline hook writes the Claude one on every
render; `codex-live-limits.mjs` / `parse-codex-logs.mjs` write the Codex one).
Grok usage is read from the Grok CLI's log at `~/.grok/logs/unified.jsonl`:
the CLI fetches the whole SuperGrok subscription's weekly credit usage from
xAI's billing service after each completed turn and logs it as a
"billing: fetched credits config" line. Account-wide, but only refreshed while
the Grok CLI is used on this Mac.

Only the Claude account quota request uses network access, and it talks directly
to Anthropic. If local files are missing, the relevant provider card shows
"no data yet". If Claude authentication fails, local Claude data stays visible
with an authentication warning.

## Layout

- `Package.swift` — Swift Package, macOS 14+, single executable target.
- `Sources/UsageMenuBar/Models.swift` — Codable structs matching the JSON
  snapshot shapes, the Grok log-line parser (`GrokLimits`), plus a unified
  `ProviderQuota` the view renders.
- `Sources/UsageMenuBar/QuotaStore.swift` — `ObservableObject`, Anthropic quota
  polling (`Timer`, 60s), macOS Keychain access, and local snapshot fallback.
- `Sources/UsageMenuBar/QuotaView.swift` — the dropdown UI (progress bars,
  reset countdowns, the menu bar provider picker) and the menu bar label.
- `Sources/UsageMenuBar/MenuBarPreference.swift` — which single provider the
  menu bar shows, enabled providers and runway visibility, persisted in `UserDefaults`.
- `Sources/UsageMenuBar/SettingsView.swift` — settings inside the dropdown.
- `Sources/UsageMenuBar/ModelUsage*.swift` — local token parsing, on-demand background
  scanning, dated API pricing and per-model detail UI. See `docs/model-usage.md`.
- `Sources/UsageMenuBar/MenuBarGauge.swift` — the ten-block usage gauge drawn
  into an `NSImage` (a `MenuBarExtra` label only renders Text and Image).
- `Sources/UsageMenuBar/UsageMenuBarApp.swift` — `@main` entry, sets
  `.accessory` activation policy so there's no Dock icon.

## Build / install

```
./rebuild.sh
```
Builds release, signs with the persistent local identity, replaces the binary inside
`~/Applications/UsageMenuBar.app`, and relaunches it. That's the only
supported way to ship a change — don't hand-edit the `.app` bundle.

The app is registered as a Login Item (System Settings > General > Login
Items), so it starts automatically on boot. `rebuild.sh` kills and relaunches
the running instance itself; no need to touch Login Items again unless the
app path changes.

## Editing notes

- Tests: run `./scripts/test.sh`, not bare `swift test`. The suite uses Swift
  Testing (`@Test` / `#expect`) because the Command Line Tools ship no XCTest,
  and the script supplies the framework search paths SwiftPM omits. `Package.swift`
  is on tools-version 6.0 for Swift Testing but pins `swiftLanguageModes: [.v5]`
  — the app code is not Swift 6 concurrency-clean.
- No Xcode project on purpose — plain `swift build` is enough for a
  menu-bar-only app this size. Don't add an `.xcodeproj` unless the app
  grows features that actually need Interface Builder / asset catalogs.
- No dependencies — stdlib + SwiftUI + AppKit only. Keep it that way; this
  app's whole value proposition is "small enough to read in one sitting and
  trust."
- If the JSON snapshot shape in `~/.claude/usage-dashboard/*.mjs` changes,
  update `Models.swift` to match — it's a hand-written mirror, not generated.
