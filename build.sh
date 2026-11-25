#!/bin/bash
# Builds build/GroqHotkey.app from the Swift sources (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/GroqHotkey.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# Pin the deployment target (matches LSMinimumSystemVersion in Info.plist);
# otherwise swiftc may target a newer macOS than the one you're running.
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos12.0" \
    -framework Cocoa -framework Carbon -framework Security \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/GroqHotkey"

# Sign with a stable local identity if available, so macOS keeps Accessibility/Keychain
# permissions across rebuilds. Otherwise fall back to an ad-hoc signature
# (works, but permissions must be re-granted after every rebuild).
IDENTITY="GroqHotkey Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Note: '$IDENTITY' certificate not found; using ad-hoc signing."
    codesign --force --sign - "$APP"
fi

echo "Built $APP"

# If the login agent is installed, restart the app so the new build is running.
if launchctl print "gui/$(id -u)/local.groqhotkey" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/local.groqhotkey"
    echo "Restarted the running app (login agent)."
else
    echo "Run it with:  open \"$APP\"   (or ./install-agent.sh to auto-start + auto-restart)"
fi
