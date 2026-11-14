#!/bin/bash
# Adds one line to your Claude Code status line script so ClaudeNotch can show your plan usage
# (5-hour and weekly limits). Claude Code reports these only to the status line; the line copies
# that input to ~/Library/Application Support/ClaudeNotch/statusline.json (local, 0600).
# Usage: install-statusline.sh [--uninstall] [--script <path>]
set -eu
# Messages are Turkish (the original) unless CLAUDE_NOTCH_LANG=en; the app passes its own
# language when it runs install-hooks.sh. Usage: say "<Turkish>" "<English>".
say() { if [ "${CLAUDE_NOTCH_LANG:-tr}" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }

SCRIPT=""
MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --script) SCRIPT="$2"; shift ;;
    *) say "Bilinmeyen seçenek: $1" "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

SETTINGS="$HOME/.claude/settings.json"
if [ -z "$SCRIPT" ]; then
  CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)"
  # "bash /path/to/script.sh" -> /path/to/script.sh
  SCRIPT="$(printf '%s' "$CMD" | awk '{print $NF}')"
fi
if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
  say "Durum satırı betiği bulunamadı (settings.json > statusLine.command)." "Status line script not found (settings.json > statusLine.command)." >&2
  say "Elle vermek için: $0 --script <betik>" "To give it by hand: $0 --script <script>" >&2
  exit 1
fi

MARK="# ClaudeNotch: plan kullanımını çentiğe ilet"
if [ "$MODE" = uninstall ]; then
  if grep -qF "$MARK" "$SCRIPT"; then
    cp "$SCRIPT" "$SCRIPT.bak.$(date +%Y%m%d-%H%M%S)"
    awk -v m="$MARK" '$0 == m { skip = 1; next } skip { skip = 0; next } { print }' "$SCRIPT" \
      > "$SCRIPT.tmp" && mv "$SCRIPT.tmp" "$SCRIPT"
    say "Kaldırıldı: $SCRIPT" "Removed: $SCRIPT"
  else
    say "Zaten yok: $SCRIPT" "Not there: $SCRIPT"
  fi
  exit 0
fi

if grep -qF "$MARK" "$SCRIPT"; then
  say "Zaten kurulu: $SCRIPT" "Already installed: $SCRIPT"
  exit 0
fi
if ! grep -qE '^input=\$\(cat\)' "$SCRIPT"; then
  say "Betikte 'input=\$(cat)' satırı yok; satırı elle ekleyin (README)." "The script has no 'input=\$(cat)' line; add the line by hand (README)." >&2
  exit 1
fi
BACKUP="$SCRIPT.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SCRIPT" "$BACKUP"
LINE='d="$HOME/Library/Application Support/ClaudeNotch"; [ -d "$d" ] && t=$(mktemp "$d/.sl.XXXXXX") && printf '"'"'%s'"'"' "$input" > "$t" && mv -f "$t" "$d/statusline.json"'
awk -v m="$MARK" -v l="$LINE" '{ print } /^input=\$\(cat\)/ && !done { print m; print l; done = 1 }' \
  "$SCRIPT" > "$SCRIPT.tmp" && mv "$SCRIPT.tmp" "$SCRIPT"
chmod +x "$SCRIPT" 2>/dev/null || true
say "Kuruldu: $SCRIPT (yedek: $BACKUP)" "Installed: $SCRIPT (backup: $BACKUP)"
