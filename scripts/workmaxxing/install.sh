#!/bin/bash
# Install the built tagged dev app as /Applications/Workmaxxing.app.
#
# The copy's baked paths are pointed at itself and it is re-signed with
# WORKMAXXING_SIGN_IDENTITY (a local code-signing identity), so macOS privacy
# grants carry over between installs. Without an identity it is ad-hoc signed
# and macOS asks for permissions again after every install.
set -euo pipefail
TAG="${WORKMAXXING_TAG:-wm}"
CONFIG="${WORKMAXXING_CONFIG:-Release}"
SRC="$HOME/Library/Developer/Xcode/DerivedData/cmux-$TAG/Build/Products/$CONFIG/cmux DEV $TAG.app"
DEST="/Applications/Workmaxxing.app"
STAGE="/Applications/.Workmaxxing.app.installing"
[ -d "$SRC" ] || { echo "error: no build at $SRC; run scripts/workmaxxing/build.sh" >&2; exit 1; }
# Quit whatever runs from the installed copy (it may be another tag's build).
INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
for id in "$INSTALLED_ID" "com.cmuxterm.app.debug.$TAG"; do
  [ -n "$id" ] && osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
done
for _ in $(seq 1 20); do pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break; sleep 1; done
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
PLIST="$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SHELL_INTEGRATION_DIR $DEST/Contents/Resources/shell-integration" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_BUNDLED_CLI_PATH $DEST/Contents/Resources/bin/cmux" "$PLIST"
/usr/bin/codesign --force --sign "${WORKMAXXING_SIGN_IDENTITY:--}" --timestamp=none --generate-entitlement-der "$STAGE" >/dev/null
rm -rf "$DEST"
mv "$STAGE" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
echo "installed $DEST"
