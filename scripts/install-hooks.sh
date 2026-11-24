#!/bin/bash
# Installs/removes ClaudeNotch hooks in a Claude Code settings.json.
# Usage: install-hooks.sh [--uninstall] [--print] [--settings <path>] [--hook <path>]
# --hook: the bridge script the hooks call (default: hooks/ next to this script's folder; the
# app passes its own copy in Application Support).
set -u
set -o pipefail
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
HOOK="$ROOT/hooks/claude-notch-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
ACTION="install"
NAME="claude-notch-hook.sh"
EVENTS="SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure Stop StopFailure Notification SessionEnd"

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION="uninstall" ;;
    --print) ACTION="print" ;;
    --settings)
      shift
      if [ $# -eq 0 ]; then say "--settings bir yol bekliyor" "--settings needs a path" >&2; exit 2; fi
      SETTINGS="$1"
      ;;
    --hook)
      shift
      if [ $# -eq 0 ]; then say "--hook bir yol bekliyor" "--hook needs a path" >&2; exit 2; fi
      HOOK="$1"
      ;;
    -h | --help)
      say "Kullanım: install-hooks.sh [--uninstall] [--print] [--settings <yol>] [--hook <yol>]" "Usage: install-hooks.sh [--uninstall] [--print] [--settings <path>] [--hook <path>]"
      exit 0
      ;;
    *) say "Bilinmeyen argüman: $1" "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  say "jq bulunamadı" "jq not found" >&2
  exit 1
fi

# Quote the path in the command string only if needed.
CMD_PATH="$HOOK"
if [[ "$HOOK" =~ [^A-Za-z0-9_./-] ]]; then
  # The quote and its escape sit in variables: macOS's bash 3.2 keeps the backslashes of a
  # quote escaped inside ${//} literally.
  q="'"
  qe="'\\''"
  CMD_PATH="'${HOOK//$q/$qe}'"
fi

# Our hooks JSON fragment.
hooks_json() {
  jq -n --arg perm "$CMD_PATH permission" --arg ev "$CMD_PATH event" \
    --arg q "$CMD_PATH question" --arg events "$EVENTS" '
    {PermissionRequest: [{hooks: [{type: "command", command: $perm, timeout: 600}]}]}
    + ($events | split(" ") | map({key: ., value: [{hooks: [{type: "command", command: $ev,
        async: true, timeout: 10}]}]}) | from_entries)
    # AskUserQuestion: held until answered in the notch (an empty reply lets the terminal ask).
    # With the "answer questions in the notch" setting off, the app replies empty at once.
    | .PreToolUse = ((.PreToolUse // []) + [{matcher: "AskUserQuestion",
        hooks: [{type: "command", command: $q, timeout: 600}]}])
    | {hooks: .}'
}

if [ "$ACTION" = "print" ]; then
  hooks_json
  exit 0
fi

# Removes previous ClaudeNotch entries (identified by the bridge script name). Tolerant of
# foreign shapes: non-object groups/items and groups without a hooks array are left untouched.
STRIP='
  def clean($n):
    map(
      if type == "object" and (.hooks | type) == "array" then
        .hooks |= map(select(
          (type != "object") or ((((.command // "") | tostring) | contains($n)) | not)))
      else . end)
    | map(select((type != "object") or (has("hooks") | not) or ((.hooks | type) != "array")
        or (.hooks | length) > 0));
  def strip($n):
    if (.hooks | type) == "object" then
      .hooks |= (with_entries(.value |= (if type == "array" then clean($n) else . end))
        | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
    else . end
    | if (.hooks | type) == "object" and (.hooks | length) == 0 then del(.hooks) else . end;
'
ADD='
  strip($name)
  | if $add == null then .
    else .hooks = ((.hooks // {}) as $h
      | reduce ($add.hooks | to_entries[]) as $e ($h;
          .[$e.key] = ((.[$e.key] // []) + $e.value)))
    end'

# Follow a symlinked settings file (dotfile managers) so the link itself is not replaced.
if [ -L "$SETTINGS" ]; then
  RESOLVED="$(realpath "$SETTINGS" 2>/dev/null)" || RESOLVED=""
  if [ -z "$RESOLVED" ]; then
    say "Sembolik bağ çözülemedi: $SETTINGS" "Could not resolve the symbolic link: $SETTINGS" >&2
    exit 1
  fi
  SETTINGS="$RESOLVED"
fi

if [ -e "$SETTINGS" ]; then
  if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    say "Geçersiz JSON (nesne bekleniyor): $SETTINGS" "Invalid JSON (an object is expected): $SETTINGS" >&2
    exit 1
  fi
  CURRENT="$(cat "$SETTINGS")"
else
  if [ "$ACTION" = "uninstall" ]; then
    say "Dosya yok, yapılacak bir şey yok: $SETTINGS" "No file, nothing to do: $SETTINGS"
    exit 0
  fi
  CURRENT="{}"
fi

if [ "$ACTION" = "uninstall" ]; then
  RESULT="$(printf '%s' "$CURRENT" | jq --arg name "$NAME" --argjson add null \
    "$STRIP $ADD")" || { say "jq başarısız, dosyaya dokunulmadı" "jq failed, the file was not touched" >&2; exit 1; }
else
  FRAGMENT="$(hooks_json)" || exit 1
  RESULT="$(printf '%s' "$CURRENT" | jq --arg name "$NAME" --argjson add "$FRAGMENT" \
    "$STRIP $ADD")" || { say "jq başarısız, dosyaya dokunulmadı" "jq failed, the file was not touched" >&2; exit 1; }
fi

# Never write anything that is not a JSON object.
if ! printf '%s' "$RESULT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  say "Sonuç geçerli bir JSON nesnesi değil, dosyaya dokunulmadı" "The result is not a valid JSON object, the file was not touched" >&2
  exit 1
fi

DIR="$(dirname "$SETTINGS")"
if [ -e "$SETTINGS" ]; then
  BACKUP="$(mktemp "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" \
    || { say "Yedek alınamadı" "Could not make a backup" >&2; exit 1; }
  cp -p "$SETTINGS" "$BACKUP" || { say "Yedek alınamadı" "Could not make a backup" >&2; exit 1; }
  say "Yedek: $BACKUP" "Backup: $BACKUP"
else
  mkdir -p "$DIR" || exit 1
fi

TMP="$(mktemp "$DIR/.settings.XXXXXX")" || { say "Geçici dosya oluşturulamadı" "Could not create a temporary file" >&2; exit 1; }
if ! printf '%s\n' "$RESULT" > "$TMP"; then
  rm -f "$TMP"
  say "Yazılamadı: $SETTINGS" "Could not write: $SETTINGS" >&2
  exit 1
fi
# Keep the original permissions (mktemp creates 0600).
if [ -e "$SETTINGS" ]; then
  chmod "$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || echo 600)" "$TMP" 2>/dev/null
fi
if ! mv -f "$TMP" "$SETTINGS"; then
  rm -f "$TMP"
  say "Yazılamadı: $SETTINGS" "Could not write: $SETTINGS" >&2
  exit 1
fi
if [ "$ACTION" = "uninstall" ]; then
  say "ClaudeNotch hook'ları kaldırıldı: $SETTINGS" "ClaudeNotch hooks removed: $SETTINGS"
else
  say "ClaudeNotch hook'ları kuruldu: $SETTINGS" "ClaudeNotch hooks installed: $SETTINGS"
fi
