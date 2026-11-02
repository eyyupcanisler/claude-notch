#!/bin/bash
# ClaudeNotch hook bridge.
# Usage: claude-notch-hook.sh <event|permission>
#   event      fire-and-forget: forwards the hook JSON from stdin to the app.
#   permission blocking: waits for the user's decision in the notch and prints it.
# Never prints a decision on failure/timeout; the terminal dialog stays authoritative.
set -u

MODE="${1:-event}"
SOCK="${CLAUDE_NOTCH_SOCK:-$HOME/Library/Application Support/ClaudeNotch/notch.sock}"
TERM_NAME="${TERM_PROGRAM:-}"
if [ -n "${CURSOR_TRACE_ID:-}" ]; then TERM_NAME="cursor"; fi
PERMISSION_MAX_TIME="${CLAUDE_NOTCH_PERMISSION_MAX_TIME:-590}"

if [ ! -S "$SOCK" ]; then
  exit 0
fi

INPUT="$(cat)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Session identity. Claude Code runs hooks detached (our tty is "??"); the hook's parent is the
# claude process, possibly behind `sh -c` wrappers. Walk up through shell wrappers only and take
# the tty + pid of the first non-shell ancestor if that is claude (or node) and has a tty. A
# claude started without a terminal (e.g. `claude -p` from another session's Bash tool) sends
# no identity: walking further would attach it to the OUTER session's tty and pid.
# The tty + pid let the app focus the exact terminal tab and notice when the session dies.
CLAUDE_TTY=""
CLAUDE_PID=""
p="$PPID"
for _ in 1 2 3 4 5; do
  case "$p" in "" | *[!0-9]*) break ;; esac
  [ "$p" -gt 1 ] || break
  line="$(ps -o tty=,ppid=,comm= -p "$p" 2>/dev/null)" || break
  read -r t pp comm <<<"$line"
  [ -n "$t" ] || break
  name="${comm##*/}"
  name="${name#-}"
  case "$name" in
    sh | bash | zsh | dash)
      p="$pp"
      ;;
    claude | node)
      if [ "$t" != "??" ]; then
        CLAUDE_TTY="/dev/$t"
        CLAUDE_PID="$p"
      fi
      break
      ;;
    *)
      break
      ;;
  esac
done
case "$CLAUDE_TTY" in
  /dev/ttys[0-9]*) ;;
  *) CLAUDE_TTY="" CLAUDE_PID="" ;;
esac

# Git branch of the session's cwd, only on SessionStart / UserPromptSubmit, capped at 300 ms.
git_branch() {
  local dir="$1" tmp gp i b
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-notch-git.XXXXXX" 2>/dev/null)" || return 0
  GIT_OPTIONAL_LOCKS=0 git -C "$dir" branch --show-current >"$tmp" 2>/dev/null &
  gp=$!
  for i in 1 2 3 4 5 6; do
    kill -0 "$gp" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$gp" 2>/dev/null; then
    kill "$gp" 2>/dev/null
    wait "$gp" 2>/dev/null
    rm -f "$tmp"
    return 0
  fi
  wait "$gp" 2>/dev/null
  b="$(head -n 1 "$tmp" | LC_ALL=C tr -d '\000-\037\177')"
  rm -f "$tmp"
  printf '%s' "${b:0:200}"
}

BRANCH=""
if [ "$MODE" != "permission" ] && command -v jq >/dev/null 2>&1; then
  case "$INPUT" in
    *SessionStart* | *UserPromptSubmit*)
      EV_NAME="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
      case "$EV_NAME" in
        SessionStart | UserPromptSubmit)
          EV_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
          BRANCH="$(git_branch "$EV_CWD")"
          ;;
      esac
      ;;
  esac
fi

HEADERS=(-H 'Expect:' -H 'Content-Type: application/json' -H "X-Term-Program: $TERM_NAME")
if [ -n "$CLAUDE_TTY" ]; then
  HEADERS+=(-H "X-Claude-TTY: $CLAUDE_TTY" -H "X-Claude-PID: $CLAUDE_PID")
fi
if [ -n "$BRANCH" ]; then
  HEADERS+=(-H "X-Git-Branch: $BRANCH")
fi

send_event() {
  printf '%s' "$INPUT" | curl -s --unix-socket "$SOCK" --connect-timeout 1 --max-time 3 \
    "${HEADERS[@]}" --data-binary @- http://localhost/event >/dev/null 2>&1
}

if [ "$MODE" != "permission" ]; then
  send_event
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$TOOL" in
  AskUserQuestion | ExitPlanMode)
    # Needs terminal interaction: only tell the notch, never decide.
    send_event
    exit 0
    ;;
  "")
    exit 0
    ;;
esac

OUT="$(mktemp "${TMPDIR:-/tmp}/claude-notch.XXXXXX" 2>/dev/null)" || exit 0
PID=""
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; fi
  rm -f "$OUT"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

curl -s -f --unix-socket "$SOCK" --connect-timeout 1 --max-time "$PERMISSION_MAX_TIME" \
  "${HEADERS[@]}" --data-binary @- -o "$OUT" http://localhost/permission <<<"$INPUT" \
  >/dev/null 2>&1 &
PID=$!
wait "$PID"
RC=$?
PID=""
if [ "$RC" -ne 0 ] || [ ! -s "$OUT" ]; then
  exit 0
fi

if jq -e 'type == "object" and has("hookSpecificOutput")' "$OUT" >/dev/null 2>&1; then
  jq -c . "$OUT"
fi
exit 0
