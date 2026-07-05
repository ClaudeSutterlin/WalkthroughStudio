#!/bin/zsh
# Builds WalkthroughStudio.app (release) into ./build/.
# The bundle carries Info.plist (speech-recognition usage description) and is
# ad-hoc signed so macOS privacy permissions stick between launches.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Walkthrough Studio.app"
BIN=".build/release/WalkthroughStudio"
BUNDLE=".build/release/WalkthroughStudio_WalkthroughStudio.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/WalkthroughStudio"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$BUNDLE" ]]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# Sign with a stable identity so Keychain "Always Allow" survives rebuilds.
# Ad-hoc signing (-) changes the app's code identity every build, which makes
# macOS re-prompt for keychain access after each rebuild.
# Override with:  CODESIGN_ID="Apple Development: You (TEAM)" ./build-app.sh
if [[ -z "${CODESIGN_ID:-}" ]]; then
  CODESIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
fi
if [[ -n "${CODESIGN_ID:-}" ]]; then
  echo "Signing with: $CODESIGN_ID"
  codesign --force --options runtime --sign "$CODESIGN_ID" "$APP"
else
  echo "WARNING: no code-signing identity found — falling back to ad-hoc signing."
  echo "         Keychain access prompts will reappear after every rebuild."
  codesign --force --sign - "$APP"
fi

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\""
