#!/bin/bash
# Creates the self-signed code-signing identity "ClaudeNotch Dev", once.
# A stable identity keeps the app's designated requirement ("certificate leaf = H...") the same
# across rebuilds, so macOS keeps the Automation (Apple Events) grant for Ghostty / Terminal.
#
# Where: its own keychain (~/Library/Keychains/claude-notch-signing.keychain-db, random
# password in ~/Library/Application Support/ClaudeNotch/signing-keychain.pass, mode 0600),
# NOT the login keychain. In the login keychain codesign can use the key only after
# `security set-key-partition-list`, which needs the login password (a dialog / manual step);
# with a keychain whose password the script knows, that step runs without any prompt. See
# scripts/signing-lib.sh. Never adds trust settings (that would need a password prompt).
# Idempotent.
# Usage: make-signing-identity.sh [identity name]   (default: $CLAUDE_NOTCH_SIGN_ID or
#        "ClaudeNotch Dev"). CLAUDE_NOTCH_KEYCHAIN / CLAUDE_NOTCH_KEYCHAIN_PASS_FILE: other
#        files (tests).
set -eu
set -o pipefail
# Messages are Turkish (the original) unless CLAUDE_NOTCH_LANG=en; the app passes its own
# language when it runs install-hooks.sh. Usage: say "<Turkish>" "<English>".
say() { if [ "${CLAUDE_NOTCH_LANG:-tr}" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=signing-lib.sh
. "$ROOT/scripts/signing-lib.sh"

NAME="${1:-${CLAUDE_NOTCH_SIGN_ID:-ClaudeNotch Dev}}"
# LibreSSL: its PKCS#12 defaults (3DES / SHA-1 MAC) are what `security import` understands.
OPENSSL=/usr/bin/openssl

WORK=""
cleanup() {
  cn_search_restore
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

random_secret() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1" || true
}

# Signs a scratch copy of /usr/bin/true: proves codesign can use the key without a dialog.
check_signing() {
  local hash="$1" dir rc=0 first
  dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-notch-sign.XXXXXX")"
  cp /usr/bin/true "$dir/probe"
  cn_codesign "$hash" "$dir/probe" >/dev/null 2>"$dir/err" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    first="$(head -n 1 "$dir/err")"
    say "codesign deneme imzası başarısız: $first" "codesign test signature failed: $first" >&2
  fi
  rm -rf "$dir"
  return "$rc"
}

# 1. The keychain and its password file.
if [ ! -f "$CN_KEYCHAIN" ]; then
  if [ -e "$CN_PASS_FILE" ]; then
    say "Parola dosyası var ama anahtar zinciri yok; eski dosya değiştiriliyor." "The password file exists but the keychain does not; replacing the old file." >&2
  fi
  umask 077
  mkdir -p "$(dirname "$CN_PASS_FILE")"
  random_secret 32 >"$CN_PASS_FILE"
  chmod 600 "$CN_PASS_FILE"
  security create-keychain -p "$(cat "$CN_PASS_FILE")" "$CN_KEYCHAIN"
  # No auto-lock timeout (build-app.sh unlocks it before every signing anyway).
  security set-keychain-settings "$CN_KEYCHAIN"
  say "İmza anahtar zinciri oluşturuldu: $CN_KEYCHAIN" "Signing keychain created: $CN_KEYCHAIN"
fi
if ! cn_unlock; then
  {
    say "İmza anahtar zinciri açılamadı (parola dosyası eksik ya da yanlış):" \
      "Could not unlock the signing keychain (password file missing or wrong):"
    printf '  %s\n  %s\n' "$CN_KEYCHAIN" "$CN_PASS_FILE"
    say "Bu iki dosyayı silip betiği yeniden çalıştırın (yalnızca ClaudeNotch imzası içindir)." \
      "Delete these two files and run the script again (they are only for signing ClaudeNotch)."
  } >&2
  exit 1
fi

# 2. The identity.
HASH="$(cn_identity_hash "$NAME")"
if [ -n "$HASH" ]; then
  say "İmza kimliği zaten var: $NAME ($HASH)" "Signing identity already exists: $NAME ($HASH)"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-notch-id.XXXXXX")"
  chmod 700 "$WORK"
  cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
  P12PASS="$(random_secret 24)"
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1
  rc=0
  run_limited 30 security import "$WORK/id.p12" -k "$CN_KEYCHAIN" -f pkcs12 -P "$P12PASS" \
    -T /usr/bin/codesign >/dev/null || rc=$?
  rm -rf "$WORK"
  WORK=""
  if [ "$rc" -ne 0 ]; then
    say "security import başarısız oldu (kod $rc)." "security import failed (code $rc)." >&2
    exit 1
  fi
  HASH="$(cn_identity_hash "$NAME")"
  if [ -z "$HASH" ]; then
    say "İçe aktarıldı ama kod imzalama kimliği görünmüyor: $NAME" "Imported, but the code signing identity does not show up: $NAME" >&2
    exit 1
  fi
  say "İmza kimliği oluşturuldu: $NAME ($HASH)" "Signing identity created: $NAME ($HASH)"
fi

# 3. Let codesign use the key without a dialog (needs the keychain password, which we have).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$(cat "$CN_PASS_FILE")" "$CN_KEYCHAIN" >/dev/null 2>&1

rc=0
check_signing "$HASH" || rc=$?
if [ "$rc" -eq 124 ]; then
  say "codesign bir anahtar zinciri penceresi bekledi; durduruldu." "codesign waited for a keychain dialog; stopped." >&2
  exit 2
elif [ "$rc" -ne 0 ]; then
  say "Kimlik hazır, ancak deneme imzası çalışmadı." "The identity is ready, but the test signature did not work." >&2
  exit 2
fi
say "codesign bu kimlikle penceresiz imzalayabiliyor." "codesign can sign with this identity without a dialog."
