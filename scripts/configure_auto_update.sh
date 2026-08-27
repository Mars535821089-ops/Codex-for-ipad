#!/usr/bin/env bash
set -euo pipefail

# Automatic application updates are intentionally disabled. Release builds are
# published and installed manually so the iPad app never downloads, replaces,
# or removes an upgrade package in the background.
AUTOMATIC_UPDATE_DISABLED=1

LABEL="dev.codexforipad.autoupdate"
REQUEST_LABEL="dev.codexforipad.ipad-request-poller"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
REQUEST_AGENT="$HOME/Library/LaunchAgents/$REQUEST_LABEL.plist"

if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$REQUEST_AGENT" >/dev/null 2>&1 || true
fi

rm -f "$AGENT" "$REQUEST_AGENT"

echo "AUTOMATIC_UPDATE_DISABLED: Codex for ipad background updates are disabled"
echo "Manual release scripts remain available; no LaunchAgents are installed"
