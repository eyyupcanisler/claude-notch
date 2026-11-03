#!/bin/bash
# Records the README demo (docs/demo.gif) with made-up sessions: the app runs in demo mode
# (own settings and socket, no discovery), a neutral backdrop hides the real desktop, events are
# sent the way the hooks send them. The installed app is quit for ~45 s and restarted after.
# Needs ffmpeg. Usage: scripts/demo/record.sh
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
APP="$ROOT/build.noindex/ClaudeNotch.app"
SOCK="$HOME/Library/Application Support/ClaudeNotch/demo.sock"
OUT="$ROOT/docs"
TMP="$(mktemp -d)"
DEMO=com.eyyupcan.claudenotch.demo

ev() { # name session cwd [tool] [json-extra]
  local extra="${5:-}"
  local body="{\"hook_event_name\":\"$1\",\"session_id\":\"$2\",\"cwd\":\"$3\""
  [ -n "${4:-}" ] && body+=",\"tool_name\":\"$4\""
  [ -n "$extra" ] && body+=",$extra"
  body+="}"
  curl -s --unix-socket "$SOCK" -H 'Content-Type: application/json' -H 'X-Term-Program: ghostty' \
    -H "X-Git-Branch: ${BRANCH:-main}" --data-binary "$body" http://localhost/event >/dev/null
}
ui() { curl -s --unix-socket "$SOCK" -X POST -d "$1" http://localhost/debug/ui >/dev/null; }
key() { curl -s --unix-socket "$SOCK" -X POST -d "{\"global\":\"$1\"}" http://localhost/debug/key >/dev/null; }

# Clean demo settings: only Claude, the timer and nothing personal.
defaults delete "$DEMO" >/dev/null 2>&1 || true
defaults write "$DEMO" module.usage -bool false
defaults write "$DEMO" module.battery -bool false
defaults write "$DEMO" peekDuration -string 30
defaults write "$DEMO" shortcutHintSeen -bool true

pkill -x ClaudeNotch 2>/dev/null || true
sleep 1
open --env CLAUDE_NOTCH_DEMO=1 "$APP"
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.25; done

A=/Users/demo/code/api-server
W=/Users/demo/code/web-app
D=/Users/demo/code/docs-site
BRANCH=main ev SessionStart s-api "$A"
BRANCH=feat/checkout ev SessionStart s-web "$W"
BRANCH=main ev SessionStart s-docs "$D"
ev UserPromptSubmit s-api "$A"
ev UserPromptSubmit s-web "$W"
ev UserPromptSubmit s-docs "$D"
# Some work first, so the rhythm strips have bars.
for i in 1 2 3 4 5 6 7 8; do
  ev PreToolUse s-api "$A" Read '"tool_input":{"file_path":"src/routes/orders.ts"}'
  ev PreToolUse s-web "$W" Edit '"tool_input":{"file_path":"app/checkout/page.tsx"}'
  [ $((i % 3)) -eq 0 ] && ev PreToolUse s-docs "$D" Write '"tool_input":{"file_path":"guide/setup.md"}'
  sleep 1.2
done

swift "$ROOT/scripts/demo/backdrop.swift" 40 &
BACK=$!
sleep 2

# Region: the notch and the panel under it (screen points, main display).
# The main display only (Finder's desktop bounds would span every display).
W_SCREEN=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.objectAtIndex(0).frame.size.width')
X=$(( ${W_SCREEN%.*} / 2 - 340 ))
screencapture -x -V 27 -R "$X,0,680,400" "$TMP/demo.mov" &
REC=$!
sleep 1.5

ev PreToolUse s-web "$W" Bash '"tool_input":{"command":"npm test -- checkout"}'
sleep 1.5
# A permission request: the island drops, ⌃⌥Y allows it.
curl -s --unix-socket "$SOCK" -H 'Content-Type: application/json' -H 'X-Term-Program: ghostty' \
  --data-binary "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s-api\",\"cwd\":\"$A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run db:migrate\"}}" \
  http://localhost/permission >/dev/null &
sleep 3.5
key allow
sleep 2
# A question: ⌃⌥2 picks, ⌃⌥Y sends.
curl -s --unix-socket "$SOCK" -H 'Content-Type: application/json' -H 'X-Term-Program: ghostty' \
  --data-binary "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s-web\",\"cwd\":\"$W\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Ödeme sayfasında hangi düzen?\",\"header\":\"Düzen\",\"multiSelect\":false,\"options\":[{\"label\":\"Tek adım\",\"description\":\"\"},{\"label\":\"İki adım\",\"description\":\"\"},{\"label\":\"Sihirbaz\",\"description\":\"\"}]}]}}" \
  http://localhost/question >/dev/null &
ev PreToolUse s-web "$W" AskUserQuestion '"tool_input":{"questions":[{"question":"Ödeme sayfasında hangi düzen?","header":"Düzen","options":[{"label":"Tek adım"},{"label":"İki adım"}]}]}'
sleep 3
key option2
sleep 0.8
key allow
sleep 1.5
ev PostToolUse s-web "$W" AskUserQuestion
ev Stop s-docs "$D" "" '"last_assistant_message":"Kurulum rehberi güncellendi."'
sleep 3.5
key timer
sleep 1
ui '{"pin":true,"mode":"expanded"}'
sleep 5
ui '{"pin":false,"mode":"collapsed"}'
wait "$REC" || true
kill "$BACK" 2>/dev/null || true

mkdir -p "$OUT"
echo "kayıt: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/demo.mov") sn"
ffmpeg -loglevel error -y -i "$TMP/demo.mov" \
  -vf "fps=18,scale=680:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  "$OUT/demo.gif"
rm -rf "$TMP"
pkill -x ClaudeNotch 2>/dev/null || true
sleep 1
open "$HOME/Applications/ClaudeNotch.app" 2>/dev/null || true
ls -la "$OUT/demo.gif"
