#!/bin/bash
# Rebuild UsageMenuBar, re-sign, replace running instance.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/UsageMenuBar.app"
CACHE_ROOT="${TMPDIR:-/tmp}/usage-menubar-build-cache"

mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swift"
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swift"

cd "$DIR"
echo "Building..."
swift build --disable-sandbox -c release

BIN="$(swift build --disable-sandbox -c release --show-bin-path)/UsageMenuBar"
RESOURCE_BUNDLE="$(swift build --disable-sandbox -c release --show-bin-path)/UsageMenuBar_UsageMenuBar.bundle"

echo "Stopping running instance (if any)..."
pkill -x UsageMenuBar 2>/dev/null || true

echo "Updating app bundle..."
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/UsageMenuBar"
mkdir -p "$APP/Contents/Resources"
if [[ -d "$APP/UsageMenuBar_UsageMenuBar.bundle" ]]; then
  mv "$APP/UsageMenuBar_UsageMenuBar.bundle" "$APP/Contents/Resources/"
fi
mkdir -p "$APP/Contents/Resources/UsageMenuBar_UsageMenuBar.bundle"
cp -R "$RESOURCE_BUNDLE"/. "$APP/Contents/Resources/UsageMenuBar_UsageMenuBar.bundle"/

echo "Signing..."
codesign --force --deep --sign - "$APP"

echo "Relaunching..."
open "$APP"

echo "Done."
