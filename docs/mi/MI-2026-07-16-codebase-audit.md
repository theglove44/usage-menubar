# MI-2026-07-16: Codebase audit

## Trigger / symptom

Requested audit of project structure and risks. No reported runtime failure.

## Scope inspected

- Swift package manifest and target layout
- All Swift source files
- Build/install script
- Repository documentation and ignore rules
- Current installed app bundle metadata/signature
- Current snapshot schemas and companion writers
- Git history relevant to snapshot selection and packaging

Pre-existing untracked `AGENTS.md` was excluded from changes.

## Commands run

```bash
git status --short
rg --files
swift build -c debug
swift test
bash -n rebuild.sh
swift package describe
rg -n "URLSession|Network|NWConnection|CFNetwork|WebSocket|http://|https://|NSWorkspace|contents\(atPath|try\?|lastError|fileExists|Timer" ...
plutil -p ~/Applications/UsageMenuBar.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 ~/Applications/UsageMenuBar.app
```

A clean temporary bundle was also assembled using the same `mkdir`, `cp`, and
`codesign` steps as `rebuild.sh`, without launching it.

## Files inspected

- `Package.swift`
- `Sources/UsageMenuBar/Models.swift`
- `Sources/UsageMenuBar/QuotaStore.swift`
- `Sources/UsageMenuBar/QuotaView.swift`
- `Sources/UsageMenuBar/UsageMenuBarApp.swift`
- `rebuild.sh`
- `.gitignore`
- `README.md`
- `CLAUDE.md`
- Companion snapshot writers under `~/.claude/usage-dashboard/`
- `~/.claude/statusline-command.sh`

## Findings

### Medium: clean install is not reproducible

`rebuild.sh` creates only `Contents/MacOS`, copies the executable, signs, and
opens the bundle. Repository contains no `Info.plist`, while the currently
installed bundle has an `Info.plist` created outside version control. A clean
temporary bundle produced by the script's assembly steps had no `Info.plist`.

Impact: first-time install or bundle deletion loses bundle identifier, version,
minimum OS, `LSUIElement`, and other app metadata. Script works today because it
mutates a previously hand-created bundle.

### Medium: snapshot read failures erase last known-good quota

`QuotaStore.refresh()` replaces each published quota with the direct result of
`loadClaude()` / `loadCodex()`. Missing files, schema drift, invalid dates, or
decode failures all return `nil`; decoding errors are discarded with `try?`.
The declared `lastError` property is never assigned or rendered.

Impact: users see generic "no data yet" for both expected absence and broken
input, and a previously valid display disappears instead of remaining visible
with an error/stale marker.

Companion writers currently use atomic rename, reducing partial-write risk, but
schema drift and invalid/null fields remain unobservable.

### Low: merged Claude snapshot selection trusts file existence, not freshness

If `claude-rate-limits-merged.json` exists, it always wins. The local snapshot
is never compared by `captured_at`. The merger currently selects the freshest
device correctly, but if that scheduled merge stops while the local writer
continues, the menu bar remains pinned to the stale merged file.

Impact: stale usage can be shown despite fresher local data being available.

### Low: no automated tests

Package defines one executable target and no test target. `swift test` exits
with `error: no tests found`. Pure logic suitable for focused tests includes
date parsing, countdown formatting, color thresholds, percentage bounds,
schema decoding, and snapshot preference.

### Low: install update is non-atomic

`rebuild.sh` kills the running process before copying and signing directly into
the live bundle. A copy/sign failure leaves the app stopped and may leave a
partially updated bundle. `pkill -x UsageMenuBar` also targets by process name,
not exact bundle path.

### Positive controls

- Small, readable separation: wire models, store, views, app entry.
- No package dependencies.
- No direct external networking APIs found.
- Local dashboard opening is explicit user action via `NSWorkspace`.
- Main-actor isolation and weak timer capture are appropriate.
- Companion snapshot writers use temporary files plus rename.
- Debug build passes.
- Shell syntax check passes.
- Installed bundle signature verifies.

## Direct answers / conclusions

Architecture fits current size and trust goal. Highest risks are operational,
not algorithmic: installation depends on hidden pre-existing bundle state, and
input failures are silently collapsed into "no data yet." No high-severity
security issue found.

## Proposed surgical fix

1. Version an `Info.plist`; have `rebuild.sh` assemble a complete temporary app
   bundle, sign it, then replace the installed bundle atomically.
2. Decode into temporary results, retain last known-good quota on failure, and
   expose provider-specific read/decode errors.
3. Compare merged and local Claude `captured_at` values before choosing.
4. Add a small test target around parsing, selection, formatting, and bounds.

## Files changed

- Added this MI record.
- Added `docs/mi/README.md`.
- No production code changed.

## Validation status

- `swift build -c debug`: passed.
- `swift test`: no tests found.
- `bash -n rebuild.sh`: passed.
- `swift package describe`: passed; confirmed one executable target only.
- Installed app `codesign --verify --deep --strict`: passed.
- Clean temporary bundle check: confirmed missing `Info.plist`.

Initial sandboxed SwiftPM commands failed because Swift could not write its
module cache under `~/.cache`; rerun outside the sandbox passed.

## Current status / next steps

Audit complete. Recommended order: packaging reproducibility, error retention
and reporting, snapshot freshness comparison, focused tests.
