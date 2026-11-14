#!/bin/bash
# Installs the built app to ~/Applications (Spotlight, Launchpad and Finder find it there) and
# starts it from there. Run scripts/build-app.sh first. Opening the app again while it runs
# shows its Settings.
set -eu
# Messages follow CLAUDE_NOTCH_LANG (tr or en; the app passes its own language when it
# runs install-hooks.sh), else the Mac's first language: Turkish on a Turkish Mac, English
# otherwise.
# Usage: say "<Turkish>" "<English>".
case "${CLAUDE_NOTCH_LANG:-$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z_-]//gp')}" in
  tr | tr[-_]*) NOTCH_LANG=tr ;;
  *) NOTCH_LANG=en ;;
esac
say() { if [ "$NOTCH_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build.noindex/ClaudeNotch.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/ClaudeNotch.app"

[ -d "$SRC" ] || { say "Önce derleyin: scripts/build-app.sh" "Build it first: scripts/build-app.sh" >&2; exit 1; }
mkdir -p "$DEST_DIR"
pkill -x ClaudeNotch 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
open "$DEST"
say "Kuruldu ve başlatıldı: $DEST" "Installed and started: $DEST"
say "Spotlight'ta “ClaudeNotch” yazarak Ayarlar'ı açabilirsiniz." "Type “ClaudeNotch” in Spotlight to open Settings."
say "Girişte başlatma açıksa Ayarlar > Başlangıç'ta bir kez kapatıp açın (yeni konumu kaydeder)." "If Open at login is on, turn it off and on once in Settings > Startup (saves the new location)."
