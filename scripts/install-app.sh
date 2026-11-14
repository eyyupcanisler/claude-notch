#!/bin/bash
# Installs the built app to ~/Applications (Spotlight, Launchpad and Finder find it there) and
# starts it from there. Run scripts/build-app.sh first. Opening the app again while it runs
# shows its Settings.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build.noindex/ClaudeNotch.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/ClaudeNotch.app"

[ -d "$SRC" ] || { echo "Build it first: scripts/build-app.sh" >&2; exit 1; }
mkdir -p "$DEST_DIR"
pkill -x ClaudeNotch 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
open "$DEST"
echo "Installed and started: $DEST"
echo "Type “ClaudeNotch” in Spotlight to open Settings."
echo "If Open at login is on, turn it off and on once in Settings > Startup (saves the new location)."
