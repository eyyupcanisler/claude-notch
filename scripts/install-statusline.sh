#!/bin/bash
# Connects Claude Code's status line to ClaudeNotch, so the notch can show your plan usage (the
# 5-hour and weekly limits) and each chat's context left: Claude Code reports these only to the
# status line command.
#
# How: the status line command in ~/.claude/settings.json becomes ClaudeNotch's small bridge
# (hooks/claude-notch-statusline.sh, copied to the app's folder). The bridge copies its input
# for the notch, then runs the status line you had before, unchanged; with none, it prints
# nothing. Your previous command is kept in the app's folder and --uninstall puts it back.
# A status line that already copies its input for ClaudeNotch is left as it is.
#
# Usage: install-statusline.sh [--uninstall] [--check] [--settings <path>] [--bridge <path>]
#   --check     exit 0 when connected, 3 when not (prints nothing else)
#   --bridge    the bridge script to install (default: hooks/ next to this script's folder; the
#               app passes its own copy)
set -u
set -o pipefail
# Messages follow CLAUDE_NOTCH_LANG (tr or en; the app passes its own language), else the Mac's
# first language: Turkish on a Turkish Mac, English otherwise.
# Usage: say "<Turkish>" "<English>".
case "${CLAUDE_NOTCH_LANG:-$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z_-]//gp')}" in
  tr | tr[-_]*) NOTCH_LANG=tr ;;
  *) NOTCH_LANG=en ;;
esac
say() { if [ "$NOTCH_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
DIR="${CLAUDE_NOTCH_DIR:-$HOME/Library/Application Support/ClaudeNotch}"
SRC_BRIDGE="$ROOT/hooks/claude-notch-statusline.sh"
NAME="claude-notch-statusline.sh"
MODE=install

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --check) MODE=check ;;
    --settings)
      shift
      [ $# -gt 0 ] || { say "--settings bir yol bekliyor" "--settings needs a path" >&2; exit 2; }
      SETTINGS="$1"
      ;;
    --bridge)
      shift
      [ $# -gt 0 ] || { say "--bridge bir yol bekliyor" "--bridge needs a path" >&2; exit 2; }
      SRC_BRIDGE="$1"
      ;;
    # The old option: a script is no longer edited.
    --script) shift ;;
    -h | --help)
      say "Kullanım: install-statusline.sh [--uninstall] [--check] [--settings <yol>] [--bridge <yol>]" \
        "Usage: install-statusline.sh [--uninstall] [--check] [--settings <path>] [--bridge <path>]"
      exit 0
      ;;
    *) say "Bilinmeyen seçenek: $1" "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  say "jq bulunamadı" "jq not found" >&2
  exit 1
fi

BRIDGE="$DIR/$NAME"
CMD_FILE="$DIR/statusline-command"
PREV_FILE="$DIR/statusline-previous.json"

# Follow a symlinked settings file (dotfile managers) so the link itself is not replaced.
if [ -L "$SETTINGS" ]; then
  RESOLVED="$(realpath "$SETTINGS" 2>/dev/null)" || RESOLVED=""
  [ -n "$RESOLVED" ] || { say "Sembolik bağ çözülemedi: $SETTINGS" "Could not resolve the symbolic link: $SETTINGS" >&2; exit 1; }
  SETTINGS="$RESOLVED"
fi
if [ -e "$SETTINGS" ]; then
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || { say "Geçersiz JSON (nesne bekleniyor): $SETTINGS" "Invalid JSON (an object is expected): $SETTINGS" >&2; exit 1; }
  CURRENT="$(cat "$SETTINGS")"
else
  CURRENT="{}"
fi
STATUS_LINE="$(printf '%s' "$CURRENT" | jq -c '.statusLine // null')"
COMMAND="$(printf '%s' "$CURRENT" | jq -r '.statusLine.command // empty | tostring')"

# The bridge is the status line now.
ours() { case "$COMMAND" in *"$NAME"*) return 0 ;; esac; return 1; }

# A status line of its own that already hands its input to ClaudeNotch (an earlier version of
# this script added a line to it, or it was written that way): looks at each file the command
# names.
copies_already() {
  local word path rc=1
  set -f
  for word in $COMMAND; do
    path="${word/#\~/$HOME}"
    path="${path#\'}"; path="${path%\'}"; path="${path#\"}"; path="${path%\"}"
    [ -f "$path" ] || continue
    if grep -qF "ClaudeNotch" "$path" 2>/dev/null && grep -qF "statusline.json" "$path" 2>/dev/null; then
      rc=0
      break
    fi
  done
  set +f
  return "$rc"
}

# Writes RESULT (a JSON object) to the settings file: a backup first, the same permissions,
# atomically.
write_settings() {
  printf '%s' "$RESULT" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { say "Sonuç geçerli bir JSON nesnesi değil, dosyaya dokunulmadı" "The result is not a valid JSON object, the file was not touched" >&2; exit 1; }
  local dir tmp backup
  dir="$(dirname "$SETTINGS")"
  if [ -e "$SETTINGS" ]; then
    backup="$(mktemp "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" \
      || { say "Yedek alınamadı" "Could not make a backup" >&2; exit 1; }
    cp -p "$SETTINGS" "$backup" || { say "Yedek alınamadı" "Could not make a backup" >&2; exit 1; }
    say "Yedek: $backup" "Backup: $backup"
  else
    mkdir -p "$dir" || exit 1
  fi
  tmp="$(mktemp "$dir/.settings.XXXXXX")" || { say "Geçici dosya oluşturulamadı" "Could not create a temporary file" >&2; exit 1; }
  printf '%s\n' "$RESULT" >"$tmp" || { rm -f "$tmp"; say "Yazılamadı: $SETTINGS" "Could not write: $SETTINGS" >&2; exit 1; }
  if [ -e "$SETTINGS" ]; then
    chmod "$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null
  fi
  mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; say "Yazılamadı: $SETTINGS" "Could not write: $SETTINGS" >&2; exit 1; }
}

if [ "$MODE" = check ]; then
  if ours || copies_already; then exit 0; fi
  exit 3
fi

if [ "$MODE" = uninstall ]; then
  if ! ours; then
    say "ClaudeNotch durum satırında değil: $SETTINGS" "ClaudeNotch is not in the status line: $SETTINGS"
    exit 0
  fi
  PREV="null"
  if [ -s "$PREV_FILE" ] && jq -e . "$PREV_FILE" >/dev/null 2>&1; then
    PREV="$(jq -c . "$PREV_FILE")"
  fi
  RESULT="$(printf '%s' "$CURRENT" | jq --argjson prev "$PREV" \
    'if $prev == null then del(.statusLine) else .statusLine = $prev end')" \
    || { say "jq başarısız, dosyaya dokunulmadı" "jq failed, the file was not touched" >&2; exit 1; }
  write_settings
  rm -f "$CMD_FILE" "$PREV_FILE"
  say "Durum satırı eski haline döndü: $SETTINGS" "The status line is back as it was: $SETTINGS"
  exit 0
fi

# Install.
[ -f "$SRC_BRIDGE" ] || { say "Köprü betiği bulunamadı: $SRC_BRIDGE" "Bridge script not found: $SRC_BRIDGE" >&2; exit 1; }
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null
if [ "$SRC_BRIDGE" != "$BRIDGE" ]; then
  cp "$SRC_BRIDGE" "$BRIDGE.tmp.$$" && chmod 755 "$BRIDGE.tmp.$$" && mv -f "$BRIDGE.tmp.$$" "$BRIDGE" \
    || { say "Köprü kopyalanamadı: $BRIDGE" "Could not copy the bridge: $BRIDGE" >&2; exit 1; }
fi

if ours; then
  say "Zaten bağlı: $SETTINGS" "Already connected: $SETTINGS"
  exit 0
fi
if copies_already; then
  say "Durum satırınız zaten ClaudeNotch'a iletiyor; dokunulmadı." "Your status line already hands its input to ClaudeNotch; left as it is."
  exit 0
fi

# Keep what was there, for the bridge (the command) and for --uninstall (the whole entry).
printf '%s\n' "$STATUS_LINE" >"$PREV_FILE.tmp.$$" && mv -f "$PREV_FILE.tmp.$$" "$PREV_FILE" \
  || { say "Önceki durum satırı kaydedilemedi" "Could not save the previous status line" >&2; exit 1; }
if [ -n "$COMMAND" ]; then
  printf '%s' "$COMMAND" >"$CMD_FILE.tmp.$$" && mv -f "$CMD_FILE.tmp.$$" "$CMD_FILE" \
    || { say "Önceki komut kaydedilemedi" "Could not save the previous command" >&2; exit 1; }
else
  rm -f "$CMD_FILE"
fi

# The command as Claude Code runs it (through a shell): the path quoted, since "Application
# Support" has a space.
# The quote and its escape sit in variables: macOS's bash 3.2 keeps the backslashes of a
# quote escaped inside ${//} literally.
q="'"
qe="'\\''"
QUOTED="'${BRIDGE//$q/$qe}'"
RESULT="$(printf '%s' "$CURRENT" | jq --arg cmd "$QUOTED" \
  '.statusLine = ((if (.statusLine | type) == "object" then .statusLine else {} end)
     + {type: "command", command: $cmd})')" \
  || { say "jq başarısız, dosyaya dokunulmadı" "jq failed, the file was not touched" >&2; exit 1; }
write_settings
if [ -n "$COMMAND" ]; then
  say "Bağlandı; önceki durum satırınız aynen çalışmaya devam ediyor: $SETTINGS" \
    "Connected; your previous status line keeps running as it was: $SETTINGS"
else
  say "Bağlandı: $SETTINGS" "Connected: $SETTINGS"
fi
