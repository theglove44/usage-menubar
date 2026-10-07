# Battery and Keychain fixes — 7 October 2026

The installed app's measured average CPU use fell from 19.86% to 0.82% of one
CPU core across separate one-minute windows. That is about 96% less CPU work
in this comparison, not a measured improvement in hours of battery life.
The new app's window began after a 20-second startup warm-up. Session work
continued during both observations. Longer use and battery discharge were
not measured.

## Why it was expensive

A process sample captured session discovery sorting. The comparator repeatedly
looked up each file's modification date through Foundation. Discovery now reads
that metadata once before sorting. Hidden historical transcripts also lost their
parsed cache every scan; they now retain it until their file changes or leaves
the discovered set. A missing configured Codex title database no longer causes
repeated cache invalidation. The regression test verifies cache reuse, subsequent
live-process recognition and rereading changed files.

Sessions still refresh every 20 seconds. Local quota snapshots still refresh every
60 seconds. Timers now allow a small delay so macOS can group wake-ups. Claude
requests, including failed attempts, wait at least five minutes between attempts;
server-requested longer delays still apply. Model usage remains on demand.

## Why password prompts could recur

The app's existing silent Keychain reader used LocalAuthentication, but it did
not disable legacy macOS Keychain interaction. When credentials were unavailable
or expired, it also launched `claude auth status`, which could perform its own
Keychain access outside the app's silent-read setting. The exact dialog the owner
reported was not captured, so these are identified prompt routes rather than a
confirmed attribution of that particular dialog.

The reader now disables legacy interaction for the duration of its serialised
read and restores the previous setting afterwards. It retains the existing
LocalAuthentication restriction. Background refreshes no longer launch Claude.
Claude Code owns credential renewal; unavailable or expired credentials retain
the local snapshot and offer the existing explicit sign-in action. This does not
alter the credential's access list or authorise another app. Fresh Claude account
data still requires a current credential that macOS permits this app to read.
After explicit sign-in, figures update on the next scheduled check; the
failed-attempt cooldown remains in place.

## Commands and observed results

The default macOS 27 SDK lacked the installed SwiftUI macro plugin. The installed
macOS 26.5 SDK was used without changing the system-selected toolchain or the
app's macOS 14 deployment target. The repository test script now supplies the
installed Swift Testing plugin path as well as its existing framework paths.

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/test.sh --disable-sandbox
```

Actual final output:

```text
✔ Test run with 53 tests in 6 suites passed after 1.954 seconds.
```

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./rebuild.sh
```

Actual output included:

```text
Build complete! (44.25 secs)
Stopping running instance (if any)...
Updating app bundle...
Signing...
Relaunching...
Done.
```

```bash
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/UsageMenuBar.app"
```

Actual output:

```text
/Users/christaylor/Applications/UsageMenuBar.app: valid on disk
/Users/christaylor/Applications/UsageMenuBar.app: satisfies its Designated Requirement
```

The rebuilt app retained the same certificate-based designated requirement as
its predecessor. Its machine-code section matched the release build (SHA-256
`a1657bd2a15bf0675179702d07aed871efd85bda1d2d999e0186ad180a25935b`).
The previous app was copied to `/tmp/usage-menubar-before-20261007.app` before
installation and its signature verified. This temporary rollback copy may be
removed by macOS. Source changes were uncommitted at measurement time.

The original process was sampled with:

```bash
/usr/bin/sample 1286 3 -file /tmp/usage-menubar-before.sample.txt
```

CPU time and instantaneous CPU use were collected every 20 seconds with:

```bash
/bin/ps -p 1286 -o time=,pcpu=
/bin/ps -p 35453 -o time=,pcpu=
```

The measurement script calculated average CPU as the increase in process CPU
seconds divided by elapsed wall-clock seconds, multiplied by 100. These are app
process readings; they do not include subprocess CPU or whole-system power.

```text
Before: 60.1s elapsed; CPU consumed 11.93s; average CPU 19.86%; current 95.7%
After: 60.1s elapsed; CPU consumed 0.49s; average CPU 0.82%; current 0.0%
```

`git diff --check` and `bash -n scripts/test.sh rebuild.sh` both exited 0.

## Verification limits

Native interface inspection timed out twice with `timeoutReached`. The visible
dashboard, live authenticated Claude figures and absence of password dialogs
are NOT VERIFIED through the UI. Automated tests cover snapshot preservation,
credential backoff, explicit sign-in delegation, quota parsing, preferences,
model usage and session behaviour. Installation, signature, running process and
CPU reduction were verified separately.
