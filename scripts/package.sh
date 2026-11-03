#!/bin/zsh
# Usage: scripts/package.sh [--install /path/to/EJAJ.app]
# Builds and tests, then makes build/EJAJ.app (ad-hoc signed) and build/EJAJ-macOS.zip.
# --install replaces an existing EJAJ.app with the new one and relaunches it. It refuses any path
# that is not an EJAJ bundle, so it never overwrites something else.
set -eu
cd "$(dirname "$0")/.."
INSTALL=""
if [[ ${1:-} == --install ]]; then INSTALL=${2:?--install needs the path of an EJAJ.app}; fi

scripts/build.sh
APP=build/EJAJ.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp build/EJAJ $APP/Contents/MacOS/EJAJ
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
xattr -cr $APP
codesign --force --sign - $APP 2>/dev/null
codesign --verify --strict $APP
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $APP/Contents/Info.plist)

rm -f build/EJAJ-macOS.zip
ditto -c -k --norsrc --keepParent $APP build/EJAJ-macOS.zip
zip -q build/EJAJ-macOS.zip README.md
echo "packaged EJAJ $VERSION: $APP, build/EJAJ-macOS.zip"

if [[ -n $INSTALL ]]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL/Contents/Info.plist" 2>/dev/null || true)
  [[ $INSTALL == *.app && $ID == local.tadeas.ejaj ]] || { echo "not an EJAJ.app: $INSTALL"; exit 1 }
  pkill -x EJAJ || true
  rm -rf "$INSTALL"
  ditto $APP "$INSTALL"
  open "$INSTALL"
  echo "installed and relaunched $INSTALL"
fi
