#!/bin/zsh
# Usage: scripts/build.sh
# Builds build/EJAJ, build/collector-tests and build/window-tests, then runs both tests.
# Prints compiler errors (warnings are filtered) and stops at the first failing step.
set -u
cd "$(dirname "$0")/.."
mkdir -p build
FLAGS=(-O -target arm64-apple-macos13.0 -module-cache-path build/module-cache
  -import-objc-header Vendor/zstd/EJAJ-Bridging.h)
compile() {
  local log; log=$(swiftc $FLAGS "$@" 2>&1); local rc=$?
  print -r -- "$log" | grep -v -E "warning:|^\s*$|note:|^\s+[0-9]+ \||^\s+\|" | grep -B1 -A3 "error:"
  return $rc
}
compile Sources/main.swift Sources/Models.swift Sources/Plan.swift Sources/Views.swift Vendor/zstd/libzstd.a -o build/EJAJ \
  || { echo "BUILD FAILED: build/EJAJ"; exit 1 }
compile Sources/Models.swift Sources/Plan.swift Tests/Tests.swift Vendor/zstd/libzstd.a -o build/collector-tests \
  || { echo "BUILD FAILED: build/collector-tests"; exit 1 }
build/collector-tests || { echo "TESTS FAILED"; exit 1 }
compile Sources/Models.swift Sources/Plan.swift Sources/Views.swift Tests/WindowTests.swift Vendor/zstd/libzstd.a -o build/window-tests \
  || { echo "BUILD FAILED: build/window-tests"; exit 1 }
out=$(build/window-tests 2>&1); rc=$?
print -r -- "$out" | grep -v "^Charts:"
(( rc == 0 )) || { echo "TESTS FAILED: build/window-tests"; exit 1 }
echo "built build/EJAJ"
