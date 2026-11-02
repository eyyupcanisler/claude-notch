#!/bin/bash
# Debug: saves a PNG render of the notch panel via the app's debug socket.
# Usage: shot.sh <out.png>   (the app must run with CLAUDE_NOTCH_DEBUG=1)
set -u
SOCK="${CLAUDE_NOTCH_SOCK:-$HOME/Library/Application Support/ClaudeNotch/notch.sock}"
curl -s --unix-socket "$SOCK" http://localhost/debug/snapshot -o "${1:-notch-shot.png}"
