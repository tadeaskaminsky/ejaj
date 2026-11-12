#!/bin/zsh
# Usage: scripts/publish.sh "Short title"
# Publishes the version in Resources/Info.plist as a GitHub release: tag v<version>, a fresh build/EJAJ-macOS.zip
# attached, the version's CHANGELOG entry as the notes. Run it after the commit, with main pushed.
# EJAJ's updater offers the latest release to everyone who runs the app, so this is the moment a version ships.
set -eu
cd "$(dirname "$0")/.."
TITLE=${1:?give the release a short title}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[[ -z $(git status --porcelain) ]] || { echo "commit first: the release is tagged at HEAD"; exit 1 }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "push main first"; exit 1 }
# Built here, from the clean HEAD that gets tagged, so the zip always matches the released source.
scripts/package.sh
ZIPPED=$(unzip -p build/EJAJ-macOS.zip EJAJ.app/Contents/Info.plist | plutil -extract CFBundleShortVersionString raw -)
[[ $ZIPPED == $VERSION ]] || { echo "build/EJAJ-macOS.zip is $ZIPPED, not $VERSION"; exit 1 }
NOTES=$(awk -v v="## $VERSION " 'index($0, v) == 1 {on = 1; next} /^## / {on = 0} on' CHANGELOG.md)
[[ -n $NOTES ]] || { echo "CHANGELOG.md has no entry for $VERSION"; exit 1 }
gh release create "v$VERSION" build/EJAJ-macOS.zip --target "$(git rev-parse HEAD)" --title "EJAJ $VERSION: $TITLE" \
  --notes "$NOTES"
echo "published v$VERSION"
