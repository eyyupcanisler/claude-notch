#!/bin/bash
# Measures ClaudeNotch's memory with a fixed scenario, so a change can be compared before/after.
# Builds nothing: run scripts/build-app.sh first. Launches build.noindex/ClaudeNotch.app in demo
# mode (its own settings suite and demo.sock; the real settings, hooks and sessions are never
# touched), with the modules of a typical setup on (timer, macOS Calendar, Spotify, shelf,
# battery, plan usage; weather off). Scenario: 6 made-up sessions in mixed states (working,
# done, error, question, waiting, one permission request that is allowed), the panel opened and
# closed once, then IDLE seconds of rest. Then it prints the physical footprint and its peak, the
# heap (malloc) part apart from the graphics part (vmmap regions), and the CPU time used. Only
# one ClaudeNotch can run per bundle id, so a running copy (the installed app) is quit first and
# started again on exit, whatever happens.
#
# Usage: scripts/measure-memory.sh [RUNS]          (default 3; prints the median of the runs)
# Env:   IDLE=60          seconds of rest before measuring
#        DETAIL=1         also print the largest heap classes (heap -s) of the last run
#        TRACE=1          also print the numbers after each step of the scenario
#        STACKS=<dir>     run with MallocStackLogging=lite and save heap / malloc_history
#                         reports of the last run into <dir> (inflates the numbers: not for
#                         before/after comparisons)
# Compare runs only under the same conditions (display on or asleep, same screens): window
# backing stores follow the displays.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build.noindex/ClaudeNotch.app"
OWNER_APP="$HOME/Applications/ClaudeNotch.app"
SOCK="$HOME/Library/Application Support/ClaudeNotch/demo.sock"
DEMO=com.eyyupcan.claudenotch.demo
RUNS="${1:-3}"
IDLE="${IDLE:-60}"
STACKS="${STACKS:-}"
PID=""
PERM_CURL=""

if [ ! -x "$APP/Contents/MacOS/ClaudeNotch" ]; then
  echo "No build at $APP: run scripts/build-app.sh first." >&2
  exit 1
fi

owner_was_running=0
pgrep -x ClaudeNotch >/dev/null && owner_was_running=1

stop_demo() {
  [ -n "$PERM_CURL" ] && kill "$PERM_CURL" 2>/dev/null
  PERM_CURL=""
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$PID" 2>/dev/null
  fi
  PID=""
}

restore() {
  stop_demo
  # The installed app comes back even if it was not running: it is the user's normal state.
  if [ -d "$OWNER_APP" ] && ! pgrep -x ClaudeNotch >/dev/null; then
    open "$OWNER_APP" 2>/dev/null || true
  fi
}
trap restore EXIT
trap 'exit 130' INT TERM

ev() { # name session cwd [tool] [json-extra]
  local body="{\"hook_event_name\":\"$1\",\"session_id\":\"$2\",\"cwd\":\"$3\""
  [ -n "${4:-}" ] && body+=",\"tool_name\":\"$4\""
  [ -n "${5:-}" ] && body+=",$5"
  body+="}"
  curl -s -m 5 --unix-socket "$SOCK" -H 'Content-Type: application/json' \
    -H 'X-Term-Program: ghostty' -H "X-Git-Branch: ${BRANCH:-main}" --data-binary "$body" \
    http://localhost/event >/dev/null
}
ui() { curl -s -m 5 --unix-socket "$SOCK" -X POST -d "$1" http://localhost/debug/ui >/dev/null; }
key() {
  curl -s -m 5 --unix-socket "$SOCK" -X POST -d "{\"global\":\"$1\"}" http://localhost/debug/key \
    >/dev/null
}

# One vmmap summary -> "footprint peak heap_dirty heap_alloc graphics" in MB.
parse_vmmap() {
  awk '
    function kb(s,  u, n) {
      u = substr(s, length(s)); n = s + 0
      if (u == "K") return n; if (u == "M") return n * 1024; if (u == "G") return n * 1048576
      return n / 1024
    }
    /^Physical footprint:/ { fp = kb($3) }
    /^Physical footprint \(peak\):/ { peak = kb($4) }
    /^REGION TYPE/ { inreg = 1; next }
    /^MALLOC ZONE/ { inzone = 1; inreg = 0; next }
    inreg && /^TOTAL/ { inreg = 0 }
    inreg && !/^=/ {
      # The name may hold spaces: it ends at the first size column.
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+[KMG]?$/) break
      name = ""; for (j = 1; j < i; j++) name = name (j > 1 ? " " : "") $j
      dirty = kb($(i + 2))
      if (name ~ /^MALLOC/) heap += dirty
      if (name ~ /^(IOSurface|IOAccelerator|CoreAnimation|CG |CoreGraphics|CoreUI|CoreImage|Image IO|ImageIO)/) gfx += dirty
    }
    inzone && /^TOTAL/ { alloc = kb($7); inzone = 0 }
    END { printf "%.1f %.1f %.1f %.1f %.1f\n", fp/1024, peak/1024, heap/1024, alloc/1024, gfx/1024 }'
}

# TRACE=1: the numbers at one step of the scenario.
stage() {
  [ "${TRACE:-0}" = 1 ] || return 0
  # shellcheck disable=SC2046
  set -- "$1" $(vmmap --summary "$PID" 2>/dev/null | parse_vmmap)
  printf '  %-22s footprint %s MB, peak %s MB, heap dirty %s MB (allocated %s MB), graphics %s MB\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

median() { # numbers on stdin -> median
  sort -n | awk '{ a[NR] = $1 } END { if (NR % 2) print a[(NR + 1) / 2]; else printf "%.1f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

one_run() {
  local n="$1"
  # Demo settings: a typical module set, sounds off, nothing personal.
  defaults delete "$DEMO" >/dev/null 2>&1 || true
  defaults write "$DEMO" module.timer -bool true
  defaults write "$DEMO" module.calendar -bool true
  defaults write "$DEMO" module.calendarGoogle -bool false
  defaults write "$DEMO" module.spotify -bool true
  defaults write "$DEMO" module.shelf -bool true
  defaults write "$DEMO" module.battery -bool true
  defaults write "$DEMO" module.usage -bool true
  defaults write "$DEMO" module.weather -bool false
  defaults write "$DEMO" shortcutHintSeen -bool true
  for s in permission question done error; do defaults write "$DEMO" "sound.$s" -bool false; done

  pkill -x ClaudeNotch 2>/dev/null
  for _ in $(seq 1 40); do pgrep -x ClaudeNotch >/dev/null || break; sleep 0.25; done
  local envs=(--env CLAUDE_NOTCH_DEMO=1)
  [ -n "$STACKS" ] && envs+=(--env MallocStackLogging=lite)
  open -g "${envs[@]}" "$APP"
  for _ in $(seq 1 80); do
    PID="$(pgrep -x ClaudeNotch | head -1)"
    [ -n "$PID" ] && curl -s -m 1 --unix-socket "$SOCK" http://localhost/debug/state >/dev/null \
      && break
    sleep 0.25
  done
  if [ -z "$PID" ] || ! ps -o command= -p "$PID" | grep -q "$APP"; then
    echo "run $n: the demo app did not start" >&2
    return 1
  fi
  sleep 2
  stage launched

  local A=/Users/demo/code/api-server W=/Users/demo/code/web-app D=/Users/demo/code/docs-site
  local M=/Users/demo/code/ml-pipeline I=/Users/demo/code/ios-app F=/Users/demo/code/infra
  BRANCH=main ev SessionStart s-api "$A"
  BRANCH=feat/checkout ev SessionStart s-web "$W"
  BRANCH=main ev SessionStart s-docs "$D"
  BRANCH=train-v2 ev SessionStart s-ml "$M"
  BRANCH=main ev SessionStart s-ios "$I"
  BRANCH=ops/dns ev SessionStart s-infra "$F"
  for s in "s-api $A" "s-web $W" "s-docs $D" "s-ml $M" "s-ios $I" "s-infra $F"; do
    # shellcheck disable=SC2086
    ev UserPromptSubmit $s
  done
  for i in $(seq 1 10); do
    ev PreToolUse s-api "$A" Read '"tool_input":{"file_path":"src/routes/orders.ts"}'
    ev PreToolUse s-web "$W" Edit '"tool_input":{"file_path":"app/checkout/page.tsx"}'
    ev PreToolUse s-ml "$M" Bash '"tool_input":{"command":"python train.py --epochs 3"}'
    [ $((i % 3)) -eq 0 ] && ev PreToolUse s-docs "$D" Write '"tool_input":{"file_path":"guide/setup.md"}'
    [ $((i % 2)) -eq 0 ] && ev PreToolUse s-ios "$I" Grep '"tool_input":{"pattern":"TODO"}'
    [ $((i % 4)) -eq 0 ] && ev PreToolUse s-infra "$F" Read '"tool_input":{"file_path":"dns/zones.tf"}'
    sleep 0.3
  done
  stage sessions
  ev PreToolUse s-web "$W" Bash '"tool_input":{"command":"npm test -- checkout"}'
  # A permission request, allowed with the global shortcut once it is armed.
  curl -s -m 30 --unix-socket "$SOCK" -H 'Content-Type: application/json' \
    -H 'X-Term-Program: ghostty' --data-binary \
    "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s-api\",\"cwd\":\"$A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run db:migrate\"}}" \
    http://localhost/permission >/dev/null &
  PERM_CURL=$!
  sleep 3.5
  key allow
  sleep 1
  kill "$PERM_CURL" 2>/dev/null
  PERM_CURL=""
  ev PostToolUse s-api "$A" Bash
  ev Stop s-docs "$D" "" '"last_assistant_message":"Updated the setup guide and fixed two broken links."'
  ev StopFailure s-ml "$M" "" '"error":"rate_limit","error_details":"Request was rate limited."'
  ev PreToolUse s-ios "$I" AskUserQuestion '"tool_input":{"questions":[{"question":"Which layout for the settings screen?","header":"Layout","options":[{"label":"One page"},{"label":"Tabs"}]}]}'
  ev Notification s-infra "$F" "" '"notification_type":"idle_prompt","message":"Claude is waiting for your input"'
  sleep 2
  stage "mixed states"
  # The panel, opened and closed once.
  ui '{"pin":true,"mode":"expanded"}'
  sleep 3
  stage "panel open"
  ui '{"pin":false,"mode":"collapsed"}'
  sleep 2
  stage "panel closed"
  sleep "$IDLE"

  local summary
  summary="$(vmmap --summary "$PID" 2>/dev/null)"
  local vals cpu
  vals="$(printf '%s\n' "$summary" | parse_vmmap)"
  # CPU time used since launch ("m:ss.cc"), so a memory change can be checked for a CPU cost.
  cpu="$(ps -o time= -p "$PID" | awk -F: '{ printf "%.2f", $1 * 60 + $2 }')"
  echo "$vals $cpu" >>"$RESULTS"
  # shellcheck disable=SC2086
  set -- $vals $cpu
  printf 'run %d: footprint %s MB, peak %s MB, heap dirty %s MB (allocated %s MB), graphics %s MB, CPU %s s\n' \
    "$n" "$1" "$2" "$3" "$4" "$5" "$6"
  if [ "$n" -eq "$RUNS" ]; then
    if [ "${DETAIL:-0}" = 1 ]; then
      echo "--- footprint -p (last run)"
      footprint -p "$PID" 2>/dev/null | sed -n '/Dirty/,/TOTAL/p' | head -30
      echo "--- largest heap classes (last run)"
      heap -q -s -H "$PID" 2>/dev/null | sed -n '1,40p'
    fi
    if [ -n "$STACKS" ]; then
      mkdir -p "$STACKS"
      printf '%s\n' "$summary" >"$STACKS/vmmap.txt"
      heap -q -s "$PID" >"$STACKS/heap.txt" 2>/dev/null
      malloc_history "$PID" -allBySize >"$STACKS/malloc-by-size.txt" 2>/dev/null
      malloc_history "$PID" -callTree -invert -showContent >"$STACKS/malloc-tree.txt" 2>/dev/null
      echo "stack reports: $STACKS"
    fi
  fi
  stop_demo
}

# Running apps change the numbers: the Ghostty tab-title refresh and the Spotify module run
# AppleScript only while those apps are open.
running() { ps -axo comm= | grep -q "/$1.app/Contents/MacOS/"; }
yesno() { if "$@"; then echo yes; else echo no; fi; }
echo "conditions: Ghostty running: $(yesno running Ghostty), Spotify running:" \
  "$(yesno running Spotify), displays: $(system_profiler SPDisplaysDataType 2>/dev/null \
  | grep -c 'Resolution:'), idle ${IDLE} s"
RESULTS="$(mktemp -t claudenotch-measure)"
for n in $(seq 1 "$RUNS"); do
  one_run "$n" || exit 1
done
for col in 1 2 3 4 5 6; do
  m[$col]="$(awk -v c="$col" '{ print $c }' "$RESULTS" | median)"
done
rm -f "$RESULTS"
printf 'median of %d: footprint %s MB, peak %s MB, heap dirty %s MB (allocated %s MB), graphics %s MB, CPU %s s\n' \
  "$RUNS" "${m[1]}" "${m[2]}" "${m[3]}" "${m[4]}" "${m[5]}" "${m[6]}"
[ "$owner_was_running" = 1 ] || echo "(the installed app was not running before; it was started)"
