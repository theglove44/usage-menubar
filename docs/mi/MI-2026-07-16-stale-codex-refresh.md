# MI-2026-07-16: Stale Codex quota refresh

## Trigger / symptom

Menu bar reported no Codex session for two hours while a Codex session was
actively writing its rollout file.

## Scope inspected

- Codex snapshot capture time and file modification time
- Current Codex rollout file activity
- Quota refresh LaunchAgent state
- Refresh script logs and child processes
- Menu bar staleness wording

## Commands run

```bash
stat ~/.claude/usage-dashboard/codex-rate-limits.json
jq ... ~/.claude/usage-dashboard/codex-rate-limits.json
find ~/.codex/sessions ... | stat ...
launchctl print gui/501/com.christaylor.claude-limits-sync
ps -o pid,ppid,etime,state,command ...
launchctl kickstart -k gui/501/com.christaylor.claude-limits-sync
swift test
./rebuild.sh
```

## Files inspected

- `Sources/UsageMenuBar/QuotaView.swift`
- `~/.claude/usage-dashboard/sync-claude-limits.sh`
- `~/.claude/usage-dashboard/codex-live-limits.mjs`
- `~/Library/LaunchAgents/com.christaylor.claude-limits-sync.plist`
- `~/.claude/usage-dashboard/sync-claude-limits.log`

## Findings

Active rollout file was updating during investigation. Codex quota snapshot was
over two hours old because the five-minute LaunchAgent had been blocked for the
same period in its first remote Claude `rsync`. Codex refresh runs after that
sync, so it was never reached.

The menu app inferred "no Codex session" from snapshot age. That inference is
invalid because Codex snapshot capture is driven by a separate scheduled RPC,
not session activity.

## Direct answers / conclusions

Codex session is active. Stale message came from a blocked quota refresh job,
not an absent session.

## Proposed surgical fix

- Menu app: describe stale Codex data as an old quota snapshot.
- Operational recovery: restart the stuck LaunchAgent and refresh Codex quota.
- Companion dashboard follow-up: refresh Codex before remote Claude sync and
  add an SSH connection timeout so an offline device cannot block the job.

## Files changed

- `Sources/UsageMenuBar/QuotaView.swift`
- `~/.claude/usage-dashboard/sync-claude-limits.sh`
- `docs/mi/README.md`
- This MI record

Companion refresh now runs Codex before remote Claude sync. Remote `rsync` is
capped at 15 seconds using Homebrew `timeout`.

## Validation status

- Stuck process confirmed as remote `rsync`, elapsed over two hours.
- LaunchAgent restarted and completed with exit code 0.
- Fresh Codex snapshot captured through `app_server_rpc`: weekly usage 4%.
- `swift test`: passed; one test, zero failures.
- `./rebuild.sh`: passed.
- Installed app signature verification: passed.
- Installed app process is running.

## Current status / next steps

Fixed and running. Five-minute refresh can no longer be indefinitely blocked by
offline remote Claude sync.
