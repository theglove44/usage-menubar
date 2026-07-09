# usage-menubar

Native macOS menu bar app (SwiftUI `MenuBarExtra`) showing live Codex + Claude
Code rate-limit quotas. Built as a self-hosted replacement for
`shanggqm/codexU` — same idea, but fully local, no third-party binary, no
network calls of any kind.

## How it works

Reads two JSON snapshot files directly off disk, polling every 20s:
- `~/.claude/usage-dashboard/claude-rate-limits.json`
- `~/.claude/usage-dashboard/codex-rate-limits.json`

Both files are written by the companion dashboard project at
`~/.claude/usage-dashboard/` (statusline hook writes the Claude one on every
render; `codex-live-limits.mjs` / `parse-codex-logs.mjs` write the Codex one).
This app is a pure reader — it never talks to Codex, Claude, or any network
endpoint. If those JSON files are missing, the relevant provider card just
shows "no data yet".

## Layout

- `Package.swift` — Swift Package, macOS 14+, single executable target.
- `Sources/UsageMenuBar/Models.swift` — Codable structs matching the JSON
  snapshot shapes, plus a unified `ProviderQuota` the view renders.
- `Sources/UsageMenuBar/QuotaStore.swift` — `ObservableObject`, file-based
  polling (`Timer`, 20s), no network APIs used anywhere.
- `Sources/UsageMenuBar/QuotaView.swift` — the dropdown UI (progress bars,
  reset countdowns) and the menu bar label text.
- `Sources/UsageMenuBar/UsageMenuBarApp.swift` — `@main` entry, sets
  `.accessory` activation policy so there's no Dock icon.

## Build / install

```
./rebuild.sh
```
Builds release, re-signs (adhoc), replaces the binary inside
`~/Applications/UsageMenuBar.app`, and relaunches it. That's the only
supported way to ship a change — don't hand-edit the `.app` bundle.

The app is registered as a Login Item (System Settings > General > Login
Items), so it starts automatically on boot. `rebuild.sh` kills and relaunches
the running instance itself; no need to touch Login Items again unless the
app path changes.

## Editing notes

- No Xcode project on purpose — plain `swift build` is enough for a
  menu-bar-only app this size. Don't add an `.xcodeproj` unless the app
  grows features that actually need Interface Builder / asset catalogs.
- No dependencies — stdlib + SwiftUI + AppKit only. Keep it that way; this
  app's whole value proposition is "small enough to read in one sitting and
  trust."
- If the JSON snapshot shape in `~/.claude/usage-dashboard/*.mjs` changes,
  update `Models.swift` to match — it's a hand-written mirror, not generated.
