#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/Applications/Codex Monitor.app"
OLD_APP_DIR="/Applications/Sol Usage Monitor.app"
OLD_HOME_APP_DIR="$HOME/Applications/Sol Usage Monitor.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/CodexMonitor"
CLI_PATH="$HOME/.local/bin/codex-monitor"
LEGACY_CLI_PATH="$HOME/.local/bin/sol-usage"
PLIST_PATH="$HOME/Library/LaunchAgents/com.pkheisig.codexmonitor.plist"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/com.pkheisig.codex-monitor.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/com.pkheisig.sol-usage-monitor.plist"
LABEL="com.pkheisig.codexmonitor"
OLD_LABEL="com.pkheisig.codex-monitor"
LEGACY_LABEL="com.pkheisig.sol-usage-monitor"

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"

BIN_DIR="$(cd "$PROJECT_DIR" && swift build -c release --show-bin-path)"

# A SwiftUI MenuBarExtra must be launched through LaunchServices (`open`) to
# create its menu-bar scene. Stop an older direct-executable instance before
# replacing the app bundle so the new scene is the only one registered.
pkill -x CodexMonitor >/dev/null 2>&1 || true

if [[ -d "$OLD_APP_DIR" && "$OLD_APP_DIR" != "$APP_DIR" ]]; then
    rm -rf "$OLD_APP_DIR"
fi
if [[ -d "$OLD_HOME_APP_DIR" && "$OLD_HOME_APP_DIR" != "$APP_DIR" ]]; then
    rm -rf "$OLD_HOME_APP_DIR"
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SolUsageMonitor" "$APP_EXECUTABLE"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_EXECUTABLE"

cp "$BIN_DIR/sol-usage" "$CLI_PATH"
cp "$BIN_DIR/sol-usage" "$LEGACY_CLI_PATH"
chmod 755 "$CLI_PATH"
chmod 755 "$LEGACY_CLI_PATH"

cp "$PROJECT_DIR/Resources/com.pkheisig.codex-monitor.plist.template" "$PLIST_PATH"
plutil -remove ProgramArguments.3 "$PLIST_PATH"
plutil -insert ProgramArguments.3 -string "$APP_DIR" "$PLIST_PATH"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
plutil -lint "$PLIST_PATH" >/dev/null

codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR" >/dev/null

UID_VALUE="$(id -u)"
DOMAIN="gui/$UID_VALUE"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1 || true
for _ in {1..10}; do
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        sleep 0.2
    else
        break
    fi
done

if ! launchctl bootstrap "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1; then
    sleep 0.5
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || {
        echo "Could not load $PLIST_PATH" >&2
        exit 1
    }
fi
launchctl kickstart -k "$DOMAIN/$LABEL"
rm -f "$OLD_PLIST_PATH" "$LEGACY_PLIST_PATH"

echo "Installed $APP_DIR"
echo "Installed $CLI_PATH"
echo "Loaded $PLIST_PATH"
