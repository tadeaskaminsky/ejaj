#!/bin/zsh
# Usage: scripts/render-calendar.sh [out.png] [width] [plan|signedout|live]
# Renders the calendar panel (with today's day selected) from the cached history, for checking layout
# without clicking through the app. Width defaults to 880, the dashboard's minimum window width.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -Onone -target arm64-apple-macos13.0 -module-cache-path build/module-cache \
  -import-objc-header Vendor/zstd/EJAJ-Bridging.h \
  scripts/render-calendar.swift Sources/Models.swift Sources/Plan.swift Sources/Update.swift Sources/Views.swift Vendor/zstd/libzstd.a \
  -o build/render-calendar 2>&1 | grep "error:" && exit 1
build/render-calendar "${1:-build/calendar.png}" "${2:-880}" ${3:+"$3"} 2>&1 | grep -v "^Charts:"
