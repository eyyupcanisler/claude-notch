#!/bin/bash
# Shared by make-signing-identity.sh and build-app.sh (sourced, not run).
#
# The "ClaudeNotch Dev" identity lives in its own keychain, not in the login keychain: codesign
# may use a private key only when the key's partition list allows it, and changing that list
# needs the keychain password. For the login keychain that is the user's login password (a
# dialog or a manual `security set-key-partition-list`); for this keychain it is a random
# password kept in a 0600 file, so setup and every build run without any prompt.
# The keychain is not kept in the user's search list: it is added only while codesign runs and
# the list is restored right after (also on errors / Ctrl-C).

CN_KEYCHAIN_DEFAULT="$HOME/Library/Keychains/claude-notch-signing.keychain-db"
CN_PASS_DEFAULT="$HOME/Library/Application Support/ClaudeNotch/signing-keychain.pass"
CN_KEYCHAIN="${CLAUDE_NOTCH_KEYCHAIN:-$CN_KEYCHAIN_DEFAULT}"
CN_PASS_FILE="${CLAUDE_NOTCH_KEYCHAIN_PASS_FILE:-$CN_PASS_DEFAULT}"

# Runs "$@" with a time limit; returns 124 on timeout (e.g. a keychain dialog waiting for the
# user). macOS has no `timeout` binary.
run_limited() {
  local secs="$1" pid i=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
}

# Unlocks the signing keychain with its stored password (never printed). 1 if unavailable.
cn_unlock() {
  [ -f "$CN_KEYCHAIN" ] && [ -f "$CN_PASS_FILE" ] || return 1
  local pass
  pass="$(cat "$CN_PASS_FILE")"
  [ -n "$pass" ] || return 1
  security unlock-keychain -p "$pass" "$CN_KEYCHAIN" >/dev/null 2>&1
}

# SHA-1 of the code-signing identity named $1 in the signing keychain (empty if none).
cn_identity_hash() {
  [ -f "$CN_KEYCHAIN" ] || return 0
  security find-identity -p codesigning "$CN_KEYCHAIN" 2>/dev/null \
    | awk -v n="\"$1\"" 'index($0, n) { print $2; exit }'
}

CN_SAVED_LIST=()
CN_LIST_CHANGED=0

# Puts the user's keychain search list back as it was before cn_search_add.
cn_search_restore() {
  if [ "$CN_LIST_CHANGED" -eq 1 ] && [ "${#CN_SAVED_LIST[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${CN_SAVED_LIST[@]}"
    CN_LIST_CHANGED=0
  fi
}

# Adds the signing keychain to the user's search list (codesign only finds identities there).
# Callers restore it with cn_search_restore, from their EXIT trap too.
cn_search_add() {
  local line present=0
  CN_SAVED_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    [ -n "$line" ] || continue
    CN_SAVED_LIST+=("$line")
    [ "$line" = "$CN_KEYCHAIN" ] && present=1
  done < <(security list-keychains -d user)
  [ "$present" -eq 1 ] && return 0
  [ "${#CN_SAVED_LIST[@]}" -gt 0 ] || return 1
  CN_LIST_CHANGED=1
  security list-keychains -d user -s "${CN_SAVED_LIST[@]}" "$CN_KEYCHAIN"
}

# Signs $2 with the identity hash $1 from the signing keychain (no prompt; 124 on timeout).
cn_codesign() {
  local hash="$1" target="$2" rc=0
  cn_search_add || return 1
  run_limited 30 codesign -s "$hash" --keychain "$CN_KEYCHAIN" --force --timestamp=none \
    "$target" || rc=$?
  cn_search_restore
  return "$rc"
}
