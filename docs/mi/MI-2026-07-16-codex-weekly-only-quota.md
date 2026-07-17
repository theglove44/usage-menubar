# MI-2026-07-16: Codex weekly-only quota

## Trigger / symptom

Toolbar app showed no Codex data after OpenAI removed the 5-hour quota and
started returning only the weekly quota.

## Scope inspected

- Current `codex-rate-limits.json`
- Codex decoding model
- Provider quota mapping
- Menu bar percentage selection
- SwiftPM target and test structure

## Commands run

```bash
jq '{captured_at, plan_type, primary, secondary}' ~/.claude/usage-dashboard/codex-rate-limits.json
swift test
./rebuild.sh
codesign --verify --deep --strict --verbose=2 ~/Applications/UsageMenuBar.app
pgrep -fl UsageMenuBar
```

## Files inspected

- `Package.swift`
- `Sources/UsageMenuBar/Models.swift`
- `Sources/UsageMenuBar/QuotaStore.swift`
- `Sources/UsageMenuBar/QuotaView.swift`

## Findings

Current snapshot uses `primary` for the 10080-minute weekly window and sets
`secondary` to `null`. Both fields were required, so `JSONDecoder` rejected the
entire snapshot. Existing mapping also assumed primary always meant 5-hour and
secondary always meant weekly.

## Direct answers / conclusions

Support both old dual-window snapshots and new weekly-only snapshots by making
windows optional and classifying them using `window_minutes`.

## Proposed surgical fix

- Decode `primary` and `secondary` as optional.
- Treat windows shorter than one day as 5-hour and windows of at least one day
  as weekly.
- Show weekly Codex percentage in the menu bar when no 5-hour percentage exists.
- Add one regression test using the observed weekly-only shape.

## Files changed

- `Package.swift`
- `Sources/UsageMenuBar/Models.swift`
- `Sources/UsageMenuBar/QuotaStore.swift`
- `Sources/UsageMenuBar/QuotaView.swift`
- `Tests/UsageMenuBarTests/CodexLimitsTests.swift`
- `docs/mi/README.md`
- This MI record

## Validation status

- `swift test`: passed; one regression test, zero failures.
- `./rebuild.sh`: passed; release build, signing, and relaunch completed.
- Installed bundle signature verification: passed.
- Process check: installed `UsageMenuBar` executable is running.

## Current status / next steps

Fixed, installed, and running.
