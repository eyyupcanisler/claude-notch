#!/bin/bash
# Installs/removes ClaudeNotch's agy (Antigravity CLI) hook in agy's hooks.json.
# Usage: install-agy-hook.sh [--print | --uninstall] [--hooks-file <path>] [--hook <path>]
#   (default) copy hooks/claude-notch-agy-hook.sh to the app's folder and add the
#             `claude-notch-events` key to the hooks file (a backup is written first)
#   --print   show the entry and where it would go; change nothing
#   --uninstall  remove the key and the copied script
#
# Only the `claude-notch-events` key is ever written or removed: every other key (agy-bridge's
# `agy-bridge-*`, plugins) stays as it is. The entry only reports events: its script prints agy's
# neutral answer and never allows, denies or blocks anything (see the script's header).
# agy reads hooks.json when a chat starts, so chats started afterwards use it.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/hooks/claude-notch-agy-hook.sh"
APP_DIR="$HOME/Library/Application Support/ClaudeNotch"
HOOK="$APP_DIR/claude-notch-agy-hook.sh"
HOOKS_FILE="$HOME/.gemini/config/hooks.json"
ACTION="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --print) ACTION="print" ;;
    --uninstall) ACTION="uninstall" ;;
    --hooks-file)
      shift
      [ $# -gt 0 ] || { echo "--hooks-file needs a path" >&2; exit 2; }
      HOOKS_FILE="$1"
      ;;
    --hook)
      shift
      [ $# -gt 0 ] || { echo "--hook needs a path" >&2; exit 2; }
      HOOK="$1"
      ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3)" || { echo "python3 not found" >&2; exit 1; }

if [ "$ACTION" = "install" ]; then
  [ -f "$SRC" ] || { echo "Missing $SRC" >&2; exit 1; }
  mkdir -p "$(dirname "$HOOK")" || exit 1
  tmp="$(mktemp "$(dirname "$HOOK")/.agy-hook.XXXXXX")" || exit 1
  cp "$SRC" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$HOOK" || { rm -f "$tmp"; exit 1; }
fi

"$PY" -I - "$ACTION" "$HOOKS_FILE" "$HOOK" <<'PY'
import json, os, shlex, shutil, sys, time

action, hooks_file, hook = sys.argv[1:4]
# Write through a symlinked hooks.json to the file it points at, never over the link.
hooks_file = os.path.realpath(hooks_file)
KEY = "claude-notch-events"
TIMEOUT = 5


def handler(event):
    # The command checks that the script is there: a missing one (the notch removed, its folder
    # deleted) must still answer agy's neutral way, since a failing PreToolUse hook makes the
    # tool call fail. Nothing on PreToolUse, {} on the other events, exit 0.
    q = shlex.quote(hook)
    fallback = "" if event == "PreToolUse" else "; else printf '{}'"
    return {"type": "command", "timeout": TIMEOUT,
            "command": f"if [ -x {q} ]; then {q} {event}{fallback}; fi"}


entry = {
    "SessionStart": [handler("SessionStart")],
    "PreInvocation": [handler("PreInvocation")],
    "PreToolUse": [{"matcher": "*", "hooks": [handler("PreToolUse")]}],
    "PostToolUse": [{"matcher": "*", "hooks": [handler("PostToolUse")]}],
    "Stop": [handler("Stop")],
}

if action == "print":
    print(f"Hooks file: {hooks_file}")
    print(f"Key: {KEY}")
    print(json.dumps({KEY: entry}, indent=2))
    sys.exit(0)

try:
    with open(hooks_file) as f:
        text = f.read()
    data = json.loads(text) if text.strip() else {}
except FileNotFoundError:
    text, data = None, {}
except ValueError as e:
    sys.exit(f"{hooks_file} is not valid JSON ({e}); nothing changed")
if not isinstance(data, dict):
    sys.exit(f"{hooks_file} is not a JSON object; nothing changed")

if action == "uninstall":
    if KEY not in data:
        print(f"No {KEY} key in {hooks_file}; nothing to remove")
    else:
        del data[KEY]
else:
    data[KEY] = entry

if action == "uninstall" and KEY not in json.loads(text or "{}"):
    pass
else:
    os.makedirs(os.path.dirname(hooks_file) or ".", exist_ok=True)
    if text is not None:
        backup = f"{hooks_file}.bak-claude-notch-{time.strftime('%Y%m%d-%H%M%S')}"
        n = 1
        while os.path.exists(backup):
            n += 1
            backup = f"{hooks_file}.bak-claude-notch-{time.strftime('%Y%m%d-%H%M%S')}-{n}"
        with open(backup, "w") as f:
            f.write(text)
        print(f"Backup: {backup}")
    tmp = hooks_file + ".claude-notch.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if text is not None:
        shutil.copymode(hooks_file, tmp)  # keep the file's permissions
    os.replace(tmp, hooks_file)
    print(("Removed" if action == "uninstall" else "Added") + f" {KEY} in {hooks_file}")
PY
rc=$?

if [ "$ACTION" = "uninstall" ] && [ $rc -eq 0 ]; then
  rm -f "$HOOK"
fi
exit $rc
