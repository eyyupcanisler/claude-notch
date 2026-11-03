#!/bin/bash
# Builds build.noindex/ClaudeNotch.app (release; ".noindex" keeps this copy out of Spotlight and
# the Apps list, so only the installed one in ~/Applications shows).
# Signing: with the identity $CLAUDE_NOTCH_SIGN_ID (default "ClaudeNotch Dev") from
# ClaudeNotch's own signing keychain (scripts/make-signing-identity.sh), else one of that name
# in another keychain if codesign may use it without a dialog, else ad-hoc. A stable identity
# keeps the Automation permission (focusing terminal tabs) across rebuilds; ad-hoc loses it.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build.noindex/ClaudeNotch.app"
VERSION="3.0.0"
SIGN_ID="${CLAUDE_NOTCH_SIGN_ID:-ClaudeNotch Dev}"
AE_USAGE="ClaudeNotch, bir oturuma tıkladığınızda o oturumun terminal sekmesini (Ghostty,"
AE_USAGE+=" Terminal, iTerm2) öne getirmek ve odaktaki sekmeyi okumak için terminalinizi"
AE_USAGE+=" kontrol eder. Spotify modülü açıksa çalan şarkının kapağını almak ve oynat / duraklat /"
AE_USAGE+=" sonraki / önceki komutlarını vermek için Spotify'ı kontrol eder."
CAL_USAGE="ClaudeNotch, Takvim modülü açıkken yaklaşan toplantıyı çentikte göstermek ve 10 dakika"
CAL_USAGE+=" önce hatırlatmak için önümüzdeki 12 saatin etkinliklerini okur; hiçbir şeyi değiştirmez"
CAL_USAGE+=" ya da dışarı göndermez."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
# App icon (redraw with scripts/make-icon.swift, then iconutil; see that file).
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>CFBundleExecutable</key><string>ClaudeNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.eyyupcan.claudenotch</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ClaudeNotch</string>
  <key>CFBundleDisplayName</key><string>ClaudeNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>$AE_USAGE</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>$CAL_USAGE</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 eyyupcan. Tüm hakları saklıdır.</string>
  <key>ClaudeNotchProjectRoot</key><string>$ROOT</string>
</dict>
</plist>
PLIST

# shellcheck source=signing-lib.sh
. "$ROOT/scripts/signing-lib.sh"
trap cn_search_restore EXIT
trap 'exit 130' INT TERM

SIGNED=""
# 1. The identity in ClaudeNotch's own keychain (scripts/make-signing-identity.sh): no prompt.
if cn_unlock; then
  HASH="$(cn_identity_hash "$SIGN_ID")"
  if [ -n "$HASH" ]; then
    rc=0
    cn_codesign "$HASH" "$APP" || rc=$?
    if [ "$rc" -eq 0 ]; then
      SIGNED="$SIGN_ID ($HASH)"
    else
      echo "\"$SIGN_ID\" ile imzalanamadı (kod $rc); başka bir yol deneniyor." >&2
    fi
  fi
fi
# 2. Without that keychain: an identity of that name elsewhere (e.g. the login keychain), if
#    codesign may use it (may show a keychain dialog; given up after 30 s).
if [ -z "$SIGNED" ] && [ ! -f "$CN_KEYCHAIN" ] \
  && security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  rc=0
  run_limited 30 codesign -s "$SIGN_ID" --force --timestamp=none "$APP" || rc=$?
  if [ "$rc" -eq 0 ]; then
    SIGNED="$SIGN_ID"
  elif [ "$rc" -eq 124 ]; then
    echo "codesign anahtar zinciri izni bekliyor; ad-hoc imzaya geçiliyor." >&2
    echo "Penceresiz kalıcı imza için: scripts/make-signing-identity.sh" >&2
  else
    echo "\"$SIGN_ID\" ile imzalanamadı (kod $rc); ad-hoc imzaya geçiliyor." >&2
  fi
fi
# 3. Ad-hoc.
if [ -z "$SIGNED" ]; then
  codesign -s - --force "$APP"
  echo "Not: ad-hoc imza; her derlemede Otomasyon izni sıfırlanır." >&2
  echo "Kalıcı imza için bir kez: scripts/make-signing-identity.sh" >&2
fi
codesign --verify --strict "$APP"
echo "İmza: ${SIGNED:-ad-hoc}"
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => /Gereksinim: /p'
echo "Hazır: $APP"
