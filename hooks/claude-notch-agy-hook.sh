#!/bin/bash
# ClaudeNotch hook bridge for agy (Antigravity CLI).
# Usage: claude-notch-agy-hook.sh <agy event name>
#   Forwards agy's hook JSON from stdin to the app (POST /agy/event), with the chat's terminal
#   identity, and decides nothing.
#
# agy runs hooks synchronously and waits for them, so this script is quick and quiet. What it
# prints is agy's "no opinion" answer, never a decision:
#   PreToolUse  prints NOTHING. Measured on agy 1.5.12-1.5.14: `{}` or {"decision":""} DENIES the
#               tool, and bad JSON or a non-zero exit makes the tool call fail.
#   any other   prints {} (agy's neutral answer for those events).
# It always exits 0, also when the app is not running or anything fails.
set -u

EVENT="${1:-}"
case "$EVENT" in
  SessionStart | PreInvocation | PostInvocation | PreToolUse | PostToolUse | Stop) ;;
  *) EVENT="" ;;
esac

neutral() {
  [ "$EVENT" = "PreToolUse" ] || printf '{}'
  exit 0
}
trap neutral HUP INT TERM

SOCK="${CLAUDE_NOTCH_SOCK:-${HOME:-}/Library/Application Support/ClaudeNotch/notch.sock}"
# Read the payload before any early exit: agy is still writing it, and a closed pipe must never
# be what agy sees.
INPUT="$(cat)"
[ -n "$EVENT" ] && [ -S "$SOCK" ] && [ -n "$INPUT" ] || neutral

TERM_NAME="${TERM_PROGRAM:-}"
TERM_BUNDLE="${__CFBundleIdentifier:-}"
case "$TERM_BUNDLE" in
  *[!A-Za-z0-9.-]* | "" | .* | *..*) TERM_BUNDLE="" ;;
esac
[ "${#TERM_BUNDLE}" -le 128 ] || TERM_BUNDLE=""

# The chat's identity: the nearest `agy` ancestor with a real terminal, reached through shell
# wrappers only. Its tty and pid let the app focus the exact tab, notice when the chat ends and
# find its log and status line. An agy run without a terminal, or a print-mode run (`agy -p`,
# `--print`, `--prompt`: scripts, benchmarks, the meter refresh) is not a chat: nothing is sent.
AGY_TTY=""
AGY_PID=""
p="$PPID"
for _ in 1 2 3 4 5 6 7 8; do
  case "$p" in "" | *[!0-9]*) break ;; esac
  [ "$p" -gt 1 ] || break
  line="$(ps -o tty=,ppid=,comm= -p "$p" 2>/dev/null)" || break
  read -r t pp comm <<<"$line"
  [ -n "$t" ] || break
  name="${comm##*/}"
  name="${name#-}"
  case "$name" in
    sh | bash | zsh | dash | fish | ksh | mksh | tcsh | csh)
      p="$pp"
      ;;
    agy)
      args=" $(ps -o args= -p "$p" 2>/dev/null) "
      case "$args" in
        *" -p "* | *" --print "* | *" --prompt "* | *" -p="* | *" --print="* | *" --prompt="*) break ;;
      esac
      if [ "$t" != "??" ]; then
        AGY_TTY="/dev/$t"
        AGY_PID="$p"
      fi
      break
      ;;
    *)
      break
      ;;
  esac
done
case "$AGY_TTY" in
  /dev/ttys[0-9]*) ;;
  *) neutral ;;
esac

HEADERS=(-H 'Expect:' -H 'Content-Type: application/json' -H "X-Agy-Event: $EVENT"
  -H "X-Term-Program: $TERM_NAME" -H "X-Claude-TTY: $AGY_TTY" -H "X-Claude-PID: $AGY_PID")
if [ -n "$TERM_BUNDLE" ]; then
  HEADERS+=(-H "X-Term-Bundle: $TERM_BUNDLE")
fi

post() {
  printf '%s' "$INPUT" | curl -s --unix-socket "$SOCK" --connect-timeout 1 --max-time "$1" \
    "${HEADERS[@]}" --data-binary @- http://localhost/agy/event >/dev/null 2>&1
}
case "$EVENT" in
  SessionStart | Stop)
    # Once per chat / turn: sent before agy goes on, so the store sees them in order (a chat's
    # start before its first prompt, a turn's last tool before its end).
    post 1
    ;;
  *)
    # Every model call and tool call (helpers included) runs this hook and agy waits for it, so
    # these go in the background and the hook returns at once. The job gets its own process
    # group (set -m) and none of agy's pipes, so neither agy's wait nor its clean-up of the
    # hook's group touches it. A quick tool's Pre and Post may arrive swapped; the row then
    # shows the tool a moment longer.
    set -m
    post 3 </dev/null >/dev/null 2>&1 &
    ;;
esac
neutral
