#!/bin/bash
# Run the test suite.
#
# The tests use Swift Testing (the only test framework the Command Line Tools
# ship — there is no XCTest without full Xcode). SwiftPM does not add the
# Command Line Tools' framework directory to the compile or runtime search
# paths by itself, so the flags below point at Testing.framework and at the
# lib_TestingInterop.dylib it loads. Without them the build fails with
# "no such module 'Testing'" or dlopen errors at launch.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
INTEROP_LIB="$(xcode-select -p)/Library/Developer/usr/lib"

if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
  echo "Testing.framework not found under $FRAMEWORKS" >&2
  echo "Install/repair the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
  "$@"
