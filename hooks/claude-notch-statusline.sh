#!/bin/bash
# ClaudeNotch status line bridge.
# Claude Code hands plan usage (the 5-hour and weekly limits) and the context window only to
# the status line command. This command takes that place: it copies the input for the notch
# (statusline.json in the app's folder, 0600, written atomically), then runs the status line you
# had before with the same input and prints what it prints. Without one it prints nothing, so
# the terminal looks as it did.
# scripts/install-statusline.sh puts it in ~/.claude/settings.json and keeps your previous
# status line command in statusline-command next to this file; --uninstall puts it back.
set -u

DIR="${CLAUDE_NOTCH_DIR:-$HOME/Library/Application Support/ClaudeNotch}"
input="$(cat)"

# The notch's copy. Never in the way of the status line itself: no folder (the app is not
# installed), no space or a read-only disk, and the line below still runs.
if [ -d "$DIR" ]; then
  t="$(mktemp "$DIR/.sl.XXXXXX" 2>/dev/null)" \
    && printf '%s' "$input" >"$t" 2>/dev/null \
    && mv -f "$t" "$DIR/statusline.json" 2>/dev/null \
    || rm -f "${t:-}" 2>/dev/null
fi

# The previous status line, as Claude Code would have run it (through sh, so `~`, pipes and
# `bash script.sh` keep working).
CMD_FILE="$DIR/statusline-command"
if [ -s "$CMD_FILE" ]; then
  cmd="$(cat "$CMD_FILE")"
  printf '%s' "$input" | /bin/sh -c "$cmd"
  exit $?
fi
exit 0
