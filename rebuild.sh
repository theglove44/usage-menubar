#!/bin/bash
# Rebuild UsageMenuBar, re-sign, replace running instance.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/UsageMenuBar.app"

cd "$DIR"
echo "Building..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/UsageMenuBar"

echo "Stopping running instance (if any)..."
pkill -x UsageMenuBar 2>/dev/null || true

echo "Updating app bundle..."
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/UsageMenuBar"

echo "Signing..."
codesign --force --deep --sign - "$APP"

echo "Relaunching..."
open "$APP"

echo "Done."
