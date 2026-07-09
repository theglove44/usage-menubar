# usage-menubar

Native macOS menu bar app showing live Codex + Claude Code usage quotas.

Self-built replacement for [`shanggqm/codexU`](https://github.com/shanggqm/codexU) —
same idea, but fully local: zero network calls, no third-party binary, nothing
phoning home. It only reads two JSON files already sitting on disk.

![Usage Quotas dropdown](screenshot.png)

## What it does

Menu bar label shows both providers' 5-hour usage at a glance. Click it for a
dropdown with 5-hour and weekly quota bars, color-coded (green/orange/red),
plus a live "resets in Xh Ym" countdown for each.

## How it works

Polls two local snapshot files every 20s — no API calls, no polling of Codex
or Claude's servers:
- `~/.claude/usage-dashboard/claude-rate-limits.json`
- `~/.claude/usage-dashboard/codex-rate-limits.json`

Both are written by the companion dashboard at `~/.claude/usage-dashboard/`
([theglove44/usage-dashboard](https://github.com/theglove44/usage-dashboard) —
see that repo for how the snapshots themselves get captured).

## Build & install

```
./rebuild.sh
```

Builds release, re-signs (adhoc), replaces `~/Applications/UsageMenuBar.app`,
relaunches it. Add it to Login Items (System Settings > General > Login Items)
to have it start on boot.

See [CLAUDE.md](CLAUDE.md) for the file layout and editing notes.
