#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/Applications/Codex Monitor.app"
OLD_APP_DIR="/Applications/Sol Usage Monitor.app"
OLD_HOME_APP_DIR="$HOME/Applications/Sol Usage Monitor.app"
CLI_PATH="$HOME/.local/bin/codex-monitor"
LEGACY_CLI_PATH="$HOME/.local/bin/sol-usage"
PLIST_PATH="$HOME/Library/LaunchAgents/com.pkheisig.codex-monitor.plist"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/com.pkheisig.sol-usage-monitor.plist"
LABEL="com.pkheisig.codex-monitor"
OLD_LABEL="com.pkheisig.sol-usage-monitor"
REMOVE_SOURCE=false

if [[ "${1:-}" == "--remove-source" ]]; then
    REMOVE_SOURCE=true
elif [[ -n "${1:-}" ]]; then
    print -u2 "Usage: $0 [--remove-source]"
    exit 2
fi

UID_VALUE="$(id -u)"
launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE/$OLD_LABEL" >/dev/null 2>&1 || true

rm -rf "$APP_DIR"
rm -rf "$OLD_APP_DIR"
rm -rf "$OLD_HOME_APP_DIR"
rm -f "$CLI_PATH"
rm -f "$LEGACY_CLI_PATH"
rm -f "$PLIST_PATH"
rm -f "$OLD_PLIST_PATH"

if $REMOVE_SOURCE; then
    rm -rf "$PROJECT_DIR"
else
    echo "Removed installed app, CLI, and LaunchAgent. Source remains at $PROJECT_DIR"
fi
