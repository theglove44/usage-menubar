# Session monitor build map

Status: proposal, 2026-08-02. This planning change must not alter Swift source or app behavior.

## Goal and boundary

Add a small local session cockpit to the existing menu bar app. First release watches:

- local Codex CLI/Desktop/VS Code rollout files;
- local Claude Code project transcripts;
- active, waiting/quiet, and stale presence;
- project name, session ID, provider, branch when available, and last local activity.

Out of scope for first release:

- transcript search, transcript preview, analytics, resume/open actions, or a persistent index;
- Claude Desktop local-agent-mode discovery;
- cloud session discovery or new credentials/network requests;
- changing existing quota polling, Keychain handling, or `QuotaStore` behavior.

Local session files contain prompts, tool calls, command output, paths, and possible secrets. The cockpit reads enough metadata to identify and age a session, then discards raw content. It must not copy transcripts into app state, logs, a database, or a network request.

## Repository baseline

Current package is a dependency-free macOS 14 Swift package. `QuotaStore` owns current quota refresh and `QuotaView` owns the dropdown. `ClaudeServices.swift` already contains injected credential, CLI, HTTP, clock, and launcher seams for quota work.

Keep session work separate:

- `QuotaStore` remains quota state and account usage state.
- `SessionActivityStore` becomes session state and local-source health.
- Session local sources never reuse Claude bearer credentials or the quota HTTP client.
- `QuotaView` receives a session store/view model and composes a cockpit section; it does not discover files.
- `Package.swift` needs no target change; SwiftPM already includes new files under the target paths.

Documentation conflict to resolve separately: `AGENTS.md` describes a no-network, capitalized `~/.Codex` snapshot layout, while current `CLAUDE.md`, `README.md`, and Swift code include Anthropic account polling and use lower-case `~/.codex`/`~/.claude` locations. This map follows current code and observed local layouts for session discovery. Session monitoring itself adds no network access.

## Build order

| Milestone | Work | Depends on | Exit check | Rollback point |
| --- | --- | --- | --- | --- |
| M0 | This map only | — | Docs diff only | Delete docs file |
| M1 | Value types, source ports, pure status classifier | M0 | Unit tests pass without home-directory access | Revert new model/port/classifier files |
| M2 | Codex and Claude Code file sources | M1 | Temp-directory fixtures decode identity and delta changes | Disable both sources; no UI change |
| M3 | Main-actor store, polling, health, backoff | M2 | Deterministic fake clock proves one in-flight scan and recovery | Do not instantiate store |
| M4 | Dropdown cockpit and compact menu-bar summary | M3 | `swift test`, `swift build`, manual `./rebuild.sh` smoke test | Revert only two UI wiring points |
| M5 | Optional Claude cloud source, only after explicit product decision | M1/M3 | Separate opt-in tests and privacy review | Remove cloud source from source list |

Recommended implementation order is M1 → M2 → M3 → M4. Do not start with cloud sessions or transcript indexing.

## Proposed files and ownership

### New production files

| File | Owner | Responsibility |
| --- | --- | --- |
| `Sources/UsageMenuBar/SessionActivityModels.swift` | Session domain | `SessionActivity`, provider/origin/state/evidence enums, source health, monitor snapshot, display-safe projections. No file I/O. |
| `Sources/UsageMenuBar/SessionActivitySources.swift` | Session infrastructure | `SessionActivitySource` protocol, `SessionFileSystem` port, `SessionProcessProbe` port, source scan request/result, path containment helpers. No UI. |
| `Sources/UsageMenuBar/SessionActivityClassifier.swift` | Session domain | Pure active/waiting/stale classification. Accepts timestamps, file delta, process evidence, and injected rules/clock. |
| `Sources/UsageMenuBar/CodexSessionSource.swift` | Codex adapter | Discovers and minimally parses Codex rollout JSONL. Produces normalized `SessionActivity` candidates. |
| `Sources/UsageMenuBar/ClaudeCodeSessionSource.swift` | Claude adapter | Discovers and minimally parses Claude Code project JSONL. Produces normalized `SessionActivity` candidates. |
| `Sources/UsageMenuBar/SessionActivityStore.swift` | App state | Owns source instances, polling lifecycle, per-source backoff/health, merge/dedupe, and `@Published` snapshot. Runs scans off the main actor. |
| `Sources/UsageMenuBar/SessionCockpitView.swift` | UI | Header, summary, Active/Waiting/Stale sections, row layout, empty/error states, accessibility labels. No discovery logic. |

### Existing files touched only at M4

| File | Change |
| --- | --- |
| `Sources/UsageMenuBar/UsageMenuBarApp.swift` | Instantiate/inject `SessionActivityStore`; retain current accessory-only app policy. |
| `Sources/UsageMenuBar/QuotaView.swift` | Compose `SessionCockpitView` above the quota divider and pass active-session count to `MenuBarLabel`. Keep quota cards unchanged. |

Do not change `Models.swift`, `QuotaStore.swift`, or `ClaudeServices.swift` for the first session slice. A later refactor may move shared clock/path utilities, but that is not required for this feature.

### New test files

| File | Responsibility |
| --- | --- |
| `Tests/UsageMenuBarTests/SessionActivityTests.swift` | Classifier boundary table, dedupe, stable IDs, clock/backoff, source health, and store concurrency tests. |
| `Tests/UsageMenuBarTests/SessionSourceTests.swift` | Codex/Claude JSONL fixtures, path discovery, partial writes, malformed records, mtime/size deltas, project identity, and containment. Uses temporary directories or fake filesystem; never real `~/.codex` or `~/.claude`. |

No fixture transcript needs to be committed initially. Use tiny synthetic JSONL strings containing metadata/envelope fields only. Add redacted fixture files only if parser behavior cannot be expressed in test strings.

## `SessionActivity` data model

Proposed shape. Keep it value-type, `Equatable`, and `Sendable`; do not make raw transcript payload part of it.

```swift
enum SessionProvider: String, CaseIterable, Sendable {
    case codex
    case claudeCode
}

enum SessionOrigin: String, Sendable {
    case codexRolloutFile
    case claudeCodeTranscript
    // Reserved for M5. Never construct in M1-M4.
    case claudeCloud
}

enum SessionPresence: String, Sendable {
    case active
    case waiting       // quiet / likely waiting; not proof of human input
    case stale
}

enum SessionEvidence: String, Sendable {
    case fileChanged
    case recentEvent
    case transcriptOpenByProcess
    case providerProcessPresent
    case quietFile
    case agedFile
    case sourceDegraded
}

enum SessionConfidence: String, Sendable {
    case high
    case medium
    case low
}

struct SessionActivity: Identifiable, Equatable, Sendable {
    let id: String                  // provider + origin + stable session ID
    let provider: SessionProvider
    let origin: SessionOrigin
    let sessionID: String            // parsed ID; filename fallback allowed
    let projectPath: String?         // internal; never shown by default
    let projectName: String          // safe basename or "Unknown project"
    let branch: String?
    let presence: SessionPresence
    let confidence: SessionConfidence
    let evidence: [SessionEvidence]
    let lastEventAt: Date?
    let fileModifiedAt: Date?
    let observedAt: Date
    let sourcePath: String           // internal diagnostic identity only
}

struct SessionMonitorSnapshot: Equatable, Sendable {
    let sessions: [SessionActivity]
    let sourceHealth: [SessionOrigin: SourceHealth]
    let observedAt: Date?
    let nextPollAt: Date?
}
```

Implementation notes:

- `id` must remain stable when a file grows. Prefer parsed session ID; fallback to normalized relative path plus filename, not mtime.
- `projectName` comes from the parsed `cwd` basename. `projectPath` may be used for matching and diagnostics but not normal row text.
- `lastEventAt` is an envelope timestamp only. Do not retain prompt, assistant text, tool input, command output, or encrypted content.
- `fileModifiedAt` is the reliable fallback when event schema drifts.
- `presence` is a local observation, not provider truth. Waiting row tooltip must say “no recent local event observed.”
- `sourceHealth` carries missing root, denied read, parse degradation, process-probe unavailability, and backoff state separately from session presence.

## Source ports and seams

Use one narrow source interface so local and future cloud sources share merge/UI code without sharing credentials:

```swift
protocol SessionActivitySource: Sendable {
    var origin: SessionOrigin { get }
    func scan(_ request: SessionScanRequest) async -> SessionScanResult
}
```

`SessionScanRequest` carries `now`, previous file stats, previous activities, lookback/caps, and a cancellation boundary. `SessionScanResult` carries candidates, removed IDs, changed stats, health, and whether the source was truncated by a cap.

Inject these live/fake dependencies:

```swift
struct SessionFileSystem: Sendable {
    var directoryExists: @Sendable (URL) -> Bool
    var list: @Sendable (URL) throws -> [URL]
    var stat: @Sendable (URL) -> SessionFileStat?
    var readPrefix: @Sendable (URL, Int) -> Data?
    var readTail: @Sendable (URL, Int) -> Data?
}

struct SessionProcessProbe: Sendable {
    var snapshot: @Sendable ([URL]) async -> ProcessPresenceSnapshot
}
```

Live process probe should be best-effort and optional. If implemented with `/usr/sbin/lsof`, pass fixed argument arrays, filter returned paths against allowlisted roots, and retain only PID/executable/open-session-path facts. Never capture command-line arguments or process output in `SessionActivity`.

## Codex discovery and presence signals

### Discovery

1. Root: `$CODEX_HOME/sessions` when `CODEX_HOME` is set; otherwise `~/.codex/sessions`.
2. Candidate files: `rollout-*.jsonl` in current and recent date shards. Include previous known paths even when outside the recent shard. Do not index all history for the cockpit.
3. Initial lookback: three calendar days, capped at 200 candidate files. Scan today first. Keep cap and lookback in `SessionMonitorRules` so tuning does not touch UI.
4. Read only file metadata plus bounded prefix/tail. Never decode an entire rollout.

### Identity and project

- First useful envelope: `type == "session_meta"`.
- Session ID: `payload.id` or `payload.session_id`; fallback to UUID in `rollout-...jsonl` filename.
- Project path: `payload.cwd`; fallback to a missing-project label.
- Branch: `payload.git.branch` when present. Branch is optional and must not block a row.
- Event timestamp: top-level `timestamp` from the newest parseable tail envelope. Clamp future timestamps to `now` for age calculations.

### Presence

- `fileChanged`: mtime or size differs from prior scan. Strong per-session signal; classify active.
- `recentEvent`: newest envelope is within the active window. Medium signal; classify active when no contradictory source error exists.
- `transcriptOpenByProcess`: optional process probe associates `codex` with this rollout path. Strong signal; classify active.
- No recent change with a readable file: classify waiting/quiet until stale threshold. This describes observation, not guaranteed user-input wait.
- No recent change and no process evidence beyond stale threshold: classify stale.

Archived rollout files are not active. They may remain as stale rows only when already known and inside the visible lookback; otherwise ignore them.

## Claude Code discovery and presence signals

### Discovery

1. Roots: `$CLAUDE_CONFIG_DIRS`, then `$CLAUDE_CONFIG_DIR`, then `~/.claude`. For each root, use `<root>/projects` when present.
2. Candidate files: project-scoped `*.jsonl`. Skip `journal.jsonl`, sidecar metadata, and `subagents/` descendants in first release. Subagent nesting is a later feature.
3. Initial scan: newest project directories first, max 12 projects and 50 transcript files per project. Include prior known paths. Keep caps configurable.
4. Do not scan Claude Desktop local-agent-mode paths in M1-M4. Add only after a separate storage/permission decision.

### Identity and project

- Session ID: top-level `sessionId`; fallback to filename stem.
- Project path: top-level `cwd` from an early `attachment` or `user` record; fallback to decoded project-folder label only for display.
- Branch: top-level `gitBranch` when present.
- Event timestamp: newest parseable top-level `timestamp` in bounded tail.

### Presence

Use same classifier and thresholds as Codex. `claude` process/open-transcript facts are supporting evidence only. A malformed Claude record must not erase a previously valid row; retain last identity and mark source health `parseDegraded`.

## Presence rules, polling, and backoff

Defaults should be constants in `SessionMonitorRules`, injected into classifier tests:

```text
poll interval:       20 seconds
active window:       90 seconds
stale threshold:     10 minutes
recent lookback:     3 calendar days
max candidates:      200 per source after filtering
tail/prefix budget:  64 KiB per changed file
```

Classification order:

1. If file grew/mtime changed this poll, or a process probe has the transcript open: `active`.
2. Else if newest local event/file age is <= active window: `active` with lower confidence.
3. Else if source is readable and age is <= stale threshold: `waiting` with `quietFile` evidence. If a matching process is present, confidence rises; do not call it proof of human input.
4. Else: `stale` with `agedFile` evidence.

If source access is denied or process probing is unavailable, retain last good rows and mark source health. Do not manufacture `active`; do not silently treat a permission failure as proof that a session stopped.

### Polling behavior

- Initial scan immediately after store creation.
- One 20-second timer schedules scans. File enumeration, bounded reads, and process probing run off the main actor; only published snapshots return to main.
- Use mtime + size maps. Unchanged files get presence reclassified from cached metadata; changed files get bounded parsing.
- Coalesce overlapping polls. At most one scan per source is in flight.
- A menu opening may request an immediate coalesced refresh, never a second concurrent scan.
- Source failures are isolated. One bad file is skipped; one bad provider does not hide the other provider.

### Backoff

Per-source retry delays: `20s → 40s → 80s → 160s → 300s` cap, with small jitter only in live scheduling. Reset after a successful source scan. Missing root is a quiet health state retried at the normal interval; denied root/process probe uses backoff. No network retry exists in local sources.

Keep last good activities while a transient source error is backing off. Display source health separately. After a long access failure, rows can become stale by age, but the UI must still say the source is unavailable so stale does not look authoritative.

## Dropdown and menu-bar UX

Keep current quota card behavior. Add compact session cockpit above the quota divider:

```text
Live sessions                         2 active · 1 waiting
● Codex       usage-menubar   #a4c1   active · 12s
● Claude      idea-keeper     #0690   active · 38s
◐ Codex       harbor          #71d2   waiting · 3m
Stale (2)                              collapsed
────────────────────────────────────
Usage Quotas
...
```

Rules:

- Sort active first, then waiting, then stale. Within a section sort newest activity first.
- Row fields: provider badge, project basename, short session ID, branch when available, relative age, and text status. Never show full path or prompt by default.
- Stale section collapsed by default. Show count and an expand affordance; cap visible rows to keep menu small.
- Empty state: “No recent local sessions.” Missing source state: “Codex sessions unavailable” or “Claude sessions unavailable,” with last-good age when known.
- Use status text plus symbol/color; color alone cannot carry state. Add accessibility labels such as “Codex session in usage-menubar, active, last local event 12 seconds ago.”
- Keep quota percentages in the menu-bar label. Append a compact live count only when useful, for example `C 23%u · Cl 41%u · 2 live`; preserve a stable accessibility label when counts are unavailable.
- No resume, reveal, terminal launch, delete, or transcript preview in this slice. Those actions expand privacy and command-injection surface.

## Test strategy

### File and parser tests

- Inject temporary directory or fake `SessionFileSystem`; never read real home paths in tests.
- Codex: date-sharded rollout discovery, `CODEX_HOME`, session-meta identity, cwd/branch extraction, filename fallback, tail parsing, partial final line, unknown envelope, malformed line, and archived exclusion.
- Claude: project-root discovery, `CLAUDE_CONFIG_DIR`, sessionId/cwd/gitBranch extraction, filename fallback, sidecar/journal/subagent exclusion, partial final line, malformed line, and duplicate path suppression.
- Verify path containment rejects symlinks/paths outside configured roots.
- Verify unchanged mtime+size avoids bounded reads and changed size/mtime triggers one parse.

### Classifier and store tests

Use a fixed clock and rules instead of sleeping:

- changed file → active;
- open transcript process → active;
- recent but quiet file → active/low or waiting according to exact boundary;
- quiet readable file → waiting;
- age exactly at active/stale boundaries;
- aged file → stale;
- future timestamp clamped to zero age;
- process probe absent/denied → file-only evidence and degraded health;
- source root missing → empty result plus missing health;
- transient source error preserves last good rows;
- backoff sequence and reset after recovery;
- concurrent refresh requests coalesce to one scan;
- stable IDs survive file growth and source ordering changes;
- same session found through duplicate configured roots dedupes deterministically.

### UI checks

- Unit-test pure menu-label/count formatting.
- Manual dropdown smoke test with fixture store: active, waiting, stale, empty, and source-error states.
- Verify VoiceOver labels, dark/light mode, narrow menu width, and no prompt/path leakage.
- Run existing quota suite unchanged, then `swift test`, `swift build`, and finally `./rebuild.sh` only at M4.

## Permissions and privacy risks

| Risk | Control |
| --- | --- |
| Session JSONL contains sensitive prompts, code, commands, and secrets | Read bounded metadata/envelopes only; discard raw content; no transcript cache/logging/network. |
| Home/config roots may be denied by macOS or packaging context | Treat denial as source health; no Full Disk Access prompt or workaround in MVP. Test packaged app, not only SwiftPM executable. |
| Process enumeration may be restricted or expose unrelated paths | Optional probe; fixed command args; filter to configured roots; retain only provider/PID/open-target facts; no command lines. |
| Symlink or configurable root escapes home/project scope | Resolve and verify path containment before reading; do not follow outside-root links. |
| Existing Claude quota code uses Keychain and Anthropic network access | Do not share credentials/dependencies with session sources; document local monitor as network-free. |
| Future resume/open actions could execute unsafe commands | Not in MVP. Later actions must pass argv arrays, use explicit confirmation, and never interpolate transcript text into a shell. |
| Cloud session support could blur local/cloud trust | Keep `SessionOrigin` and `SourceHealth` distinct; cloud source disabled by default and injected separately. |

No new persisted storage is needed. If a future index is added, it needs a separate privacy decision and purge behavior.

## Integration and rollback points

1. M1/M2 are additive files plus tests. They do not instantiate a store or touch app behavior.
2. M3 adds `SessionActivityStore` but leaves it unreferenced. Validate scans and health in tests first.
3. M4 changes only `UsageMenuBarApp.swift` and `QuotaView.swift`. The rollback switch is the single session-store injection plus the one cockpit composition call; reverting those restores quota-only UI.
4. Do not alter `rebuild.sh`, login-item registration, app activation policy, quota timers, or Claude account flow for this feature.
5. If file access or process probing causes regressions, ship with the cockpit omitted while retaining parser tests; local quota behavior remains untouched.

## Optional Claude cloud seam

Reserve `SessionOrigin.claudeCloud` and the `SessionActivitySource` protocol now, but ship no implementation and no cloud settings in M1-M4. A later `ClaudeCloudSessionSource.swift` may:

- be constructed only after explicit opt-in;
- own its network client, auth dependency, retry policy, and privacy copy;
- return cloud sessions with `origin == .claudeCloud` and separate health;
- never feed cloud data into local file/process presence classification;
- fail closed when credentials/network are unavailable, without hiding local Claude Code rows.

This keeps a future Claude cloud adapter additive instead of forcing `SessionActivityStore` or `SessionCockpitView` to know about OAuth.

## Open questions

1. **Waiting semantics.** Does the installed Codex/Claude process keep its transcript open while waiting for user input and while a tool runs? Validate with a controlled session. If not, keep “waiting” wording explicitly heuristic and rely on file age.
2. **Visible stale window.** Recommended default: scan three days, show stale only for the last 24 hours. Confirm whether user wants older stale rows or only currently/recently touched sessions.
3. **Project identity.** Worktree `cwd` may be more useful than repository root. Decide whether first UI shows basename only or adds branch/worktree detail on a second line.
4. **Claude roots.** Decide whether non-default `CLAUDE_CONFIG_DIRS` support is required for first ship or can follow default `~/.claude/projects`.
5. **Process probe packaging.** Verify `/usr/sbin/lsof` visibility and cost in the signed app. If unavailable, ship file-only state with degraded confidence rather than request broader permissions.
6. **Cloud scope.** Define what “Claude cloud session” means before implementation: account activity, browser/desktop local-agent sessions, or remote API jobs. These have different identity and privacy contracts.
7. **Documentation alignment.** Reconcile `AGENTS.md`, `CLAUDE.md`, and `README.md` quota/network claims in a separate change so future contributors do not infer the wrong boundary.

## Recommended next implementation slice

Implement M1 + M2 without UI wiring:

1. Add `SessionActivityModels.swift`.
2. Add `SessionActivitySources.swift` and `SessionActivityClassifier.swift` with injected filesystem, process, clock, and rules seams.
3. Add `CodexSessionSource.swift` and `ClaudeCodeSessionSource.swift` using bounded prefix/tail parsing and mtime/size deltas.
4. Add `SessionActivityTests.swift` and `SessionSourceTests.swift` with synthetic temp fixtures.
5. Run `swift test` and `swift build`; inspect no real home data in logs.

This slice resolves storage/schema and state-boundary uncertainty while preserving current app behavior. M3 can then wire a deterministic store; M4 can add the cockpit after the data is trustworthy.

## Inspiration

The design borrows only the useful local-first patterns from [Agent Sessions](https://github.com/jazzyalex/agent-sessions): date-sharded Codex rollout discovery, Claude project JSONL discovery, bounded recent scans, and mtime/size deltas. Its [Codex guide](https://jazzyalex.github.io/agent-sessions/guides/codex-local-history.html) documents `$CODEX_HOME/sessions` and rollout files; its [Claude Code guide](https://jazzyalex.github.io/agent-sessions/guides/claude-code-jsonl-history.html) documents `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. This app deliberately stops before history indexing, transcript search, resume workflows, and cloud usage features.
