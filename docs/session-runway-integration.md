# Session Runway UI integration contract

Core owner: `SessionRunwayScanner` and types under `Sources/UsageMenuBar/`.
UI owner: existing session UI worker. This document intentionally does not
change SwiftUI files.

## Input and lifecycle

Create one scanner for the app lifetime. Call it from a non-main task and
publish the returned value on the main actor:

```swift
let scanner = SessionRunwayScanner()

Task {
    let snapshot = await scanner.scan()
    await MainActor.run {
        // assign snapshot to UI-owned @Published state
    }
}
```

`SessionRunwayScanner` is an actor. It owns file-stat, parsed-candidate, and
burn baselines. Reuse it across polls. Do not create a new scanner per view
render or per menu opening.

Recommended poll: 20 seconds. Coalesce overlapping calls. A menu opening may
request an immediate scan, but must not run two scans concurrently.

## Snapshot contract

Consume `SessionRunwaySnapshot`:

- `rows`: already filtered, grouped, deduped, sorted, and capped at four rows
  by default. Render these only.
- `hiddenHistoricalCount`: old discovered transcript files omitted from runway.
  This is a lower bound when `diagnostics.hiddenHistoricalCountIsLowerBound` is
  true; render as `N+` or use diagnostics text, never as rows.
- `health[provider]`: `.ready`, `.missing`, `.degraded`, or `.unavailable`.
- `diagnostics.hiddenRecentCount`: recent rows omitted by the core cap. UI may
  show a compact “+N recent” hint, but must not fetch history to fill the menu.
- `diagnostics.processProbeAvailable`: process evidence quality. File-only
  scans remain valid but less confident.

Suggested display order is already applied: active working, open idle, stale,
unknown; then newest activity.

## Row contract

`SessionRunwayRow` fields:

- `provider`: provider badge/icon source.
- `title`: sanitized, compact title. Do not prepend synthetic `Session`.
- `projectName`: optional project basename.
- `sessionID`: use only as a short fallback/detail label. Prefer `title`.
- `branch`: optional secondary detail.
- `state`: map text and symbol from enum, not color alone:
  - `.activeWorking`: “working”;
  - `.openIdle`: “idle” or “quiet”;
  - `.stale`: “stale”;
  - `.unknown`: “unknown”.
- `confidence`: show only when useful, e.g. a subtle “low confidence” tooltip.
- `lastActivityAt`: relative age. This falls back to file modification time.
- `childSessionCount`: optional “+N subagents” detail. Never render child rows.
- `burn`: observed local token attribution; never convert it to quota percent.

## Burn contract

`row.burn` is intentionally honest:

- `.measuring`: baseline exists or scanner has only one observation;
- `.observed`: show observed tokens/hour and, when nonzero provider delta exists,
  share of observed provider burn;
- `.noRecentBurn`: no new local token/usage delta in the latest observation;
- `.unsupported`: source format did not expose a usable token counter.

Use labels such as:

- `measuring burn`;
- `12.4k tok/h · 62% of observed provider burn`;
- `no recent burn`;
- `burn unsupported`.

Never label `shareOfObservedProviderBurn` as quota share or exact plan usage.
Codex quota snapshots expose provider-level used percent/reset data only; the
runway layer has no exact per-session quota denominator.

## Empty and diagnostic states

- No rows and both providers missing: “No recent local sessions”.
- No rows with hidden history: “No live runway · N historical sessions hidden”.
- Unknown rows: keep them only when they are recent/processable or process
  confirmed. Do not reintroduce old unknown transcripts.
- Degraded source: retain last good rows if UI owns a previous snapshot, and
  show a small source warning. Do not turn permission failure into active or
  stopped claims.

## Privacy boundary

Core stores only compact title text and normalized metadata. UI must not display
full transcript paths, prompts beyond the sanitized title, tool input, command
output, or raw parser diagnostics. No resume/open/delete action belongs in this
integration slice.
