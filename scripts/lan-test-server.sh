#!/bin/bash
# Runs macOS's built-in networkQuality server as a LaunchAgent so NodePin can measure LAN speed.
# Use it on a Mac that is wired (Ethernet) to the router and stays on. It advertises itself over
# Bonjour, so "Find" in NodePin's Settings → Diagnostics picks it up.
#
#   scripts/lan-test-server.sh install     # start now and at every login
#   scripts/lan-test-server.sh uninstall
#   scripts/lan-test-server.sh status
set -euo pipefail

LABEL=com.tinyvlogllc.NodePin.lan-test-server
PORT=4443
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
install)
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/networkQuality</string><string>-S</string><string>$PORT</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "Started networkQuality server on port $PORT as \"$(scutil --get ComputerName)\"."
  ;;
uninstall)
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed."
  ;;
status)
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state|pid" || echo "Not running."
  ;;
*)
  echo "usage: $0 install|uninstall|status" >&2
  exit 1
  ;;
esac
