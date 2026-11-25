#!/bin/bash
# Makes Groq Hotkey start at login and restart automatically if it is killed or crashes.
# Choosing "Quit Groq Hotkey" from the menu still quits it for good (until next login).
# Undo with:  ./install-agent.sh uninstall
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.groqhotkey"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="$PWD/build/GroqHotkey.app/Contents/MacOS/GroqHotkey"

# Stop any running copy (agent-managed or launched by hand).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "GroqHotkey.app/Contents/MacOS/GroqHotkey" 2>/dev/null || true

if [[ "${1:-}" == "uninstall" ]]; then
    rm -f "$PLIST"
    echo "Removed login agent. Start the app manually with: open build/GroqHotkey.app"
    exit 0
fi

[[ -x "$BINARY" ]] || { echo "Build the app first: ./build.sh"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart only if it exits abnormally (killed/crashed), not when you choose Quit. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed: Groq Hotkey now starts at login and restarts if it gets killed."
