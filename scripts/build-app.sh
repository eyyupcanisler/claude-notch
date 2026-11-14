#!/bin/bash
# Builds build.noindex/ClaudeNotch.app (release; ".noindex" keeps this copy out of Spotlight and
# the Apps list, so only the installed one in ~/Applications shows).
# Signing: with the identity $CLAUDE_NOTCH_SIGN_ID (default "ClaudeNotch Dev") from
# ClaudeNotch's own signing keychain (scripts/make-signing-identity.sh), else one of that name
# in another keychain if codesign may use it without a dialog, else ad-hoc. A stable identity
# keeps the Automation permission (focusing terminal tabs) across rebuilds; ad-hoc loses it.
set -eu
# Messages follow CLAUDE_NOTCH_LANG (tr or en; the app passes its own language when it
# runs install-hooks.sh), else the Mac's first language: Turkish on a Turkish Mac, English
# otherwise.
# Usage: say "<Turkish>" "<English>".
case "${CLAUDE_NOTCH_LANG:-$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z_-]//gp')}" in
  tr | tr[-_]*) NOTCH_LANG=tr ;;
  *) NOTCH_LANG=en ;;
esac
say() { if [ "$NOTCH_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build.noindex/ClaudeNotch.app"
VERSION="${CLAUDE_NOTCH_VERSION:-1.0.0}"
SIGN_ID="${CLAUDE_NOTCH_SIGN_ID:-ClaudeNotch Dev}"
# Info.plist texts are Turkish, as they always were: macOS shows them in its own permission
# prompts and picks the language itself, so with no en.lproj/InfoPlist.strings they read the
# same on every Mac (the in-app Language setting cannot reach them). The English versions, for
# reference: AE "ClaudeNotch controls your terminal (Ghostty, Terminal, iTerm2) to bring a
# session's tab to the front when you click that session, and to read which tab is focused.
# With the Spotify module on, it controls Spotify to get the playing track's cover and to send
# play / pause / next / previous." CAL "With the Calendar module on, ClaudeNotch reads the next
# 12 hours of events to show the upcoming meeting in the notch and remind you 10 minutes before;
# it never changes or sends anything."
AE_USAGE="ClaudeNotch, bir oturuma tıkladığınızda o oturumun terminal sekmesini (Ghostty,"
AE_USAGE+=" Terminal, iTerm2) öne getirmek ve odaktaki sekmeyi okumak için terminalinizi"
AE_USAGE+=" kontrol eder. Spotify modülü açıksa çalan şarkının kapağını almak ve oynat / duraklat /"
AE_USAGE+=" sonraki / önceki komutlarını vermek için Spotify'ı kontrol eder."
CAL_USAGE="ClaudeNotch, Takvim modülü açıkken yaklaşan toplantıyı çentikte göstermek ve 10 dakika"
CAL_USAGE+=" önce hatırlatmak için önümüzdeki 12 saatin etkinliklerini okur; hiçbir şeyi değiştirmez"
CAL_USAGE+=" ya da dışarı göndermez."
# MallocSpaceEfficient=1 (LSEnvironment: every launch through LaunchServices, i.e. Finder, open,
# the login item): malloc hands freed pages back to macOS soon instead of keeping them dirty.
# Short bursts (the first AppleScript compile runs an XProtect scan with ~14 MB of throwaway
# heap; opening the panel builds and drops a SwiftUI tree) otherwise stay in the footprint.
# Measured with scripts/measure-memory.sh: about half the idle footprint, same CPU.

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
# Debug and local symbols out: smaller, and no build-machine paths inside the shipped binary.
strip -S -x "$APP/Contents/MacOS/ClaudeNotch"
# App icon (redraw with scripts/make-icon.swift, then iconutil; see that file).
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The hook bridge and its installer travel inside the app (Settings → General installs them).
cp "$ROOT/hooks/claude-notch-hook.sh" "$ROOT/scripts/install-hooks.sh" "$APP/Contents/Resources/"
# UI strings (en, tr) for Bundle.main. main.swift sets the app's AppleLanguages from the
# Language setting (default "System": Turkish when the Mac's first language is Turkish, English
# otherwise). Plain .lproj folders, not a SwiftPM resource bundle (one at the app root would
# break code signing).
for lproj in "$ROOT"/Resources/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
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
  <key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict>
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
      say "\"$SIGN_ID\" ile imzalanamadı (kod $rc); başka bir yol deneniyor." "Could not sign with \"$SIGN_ID\" (code $rc); trying another way." >&2
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
    say "codesign anahtar zinciri izni bekliyor; ad-hoc imzaya geçiliyor." "codesign is waiting for keychain permission; falling back to ad-hoc signing." >&2
    say "Penceresiz kalıcı imza için: scripts/make-signing-identity.sh" "For a lasting signature without a dialog: scripts/make-signing-identity.sh" >&2
  else
    say "\"$SIGN_ID\" ile imzalanamadı (kod $rc); ad-hoc imzaya geçiliyor." "Could not sign with \"$SIGN_ID\" (code $rc); falling back to ad-hoc signing." >&2
  fi
fi
# 3. Ad-hoc.
if [ -z "$SIGNED" ]; then
  codesign -s - --force "$APP"
  say "Not: ad-hoc imza; her derlemede Otomasyon izni sıfırlanır." "Note: ad-hoc signature; the Automation permission resets on every build." >&2
  say "Kalıcı imza için bir kez: scripts/make-signing-identity.sh" "For a lasting signature, run once: scripts/make-signing-identity.sh" >&2
fi
codesign --verify --strict "$APP"
say "İmza: ${SIGNED:-ad-hoc}" "Signature: ${SIGNED:-ad-hoc}"
REQ_LABEL=$(say "Gereksinim" "Requirement")
codesign -d -r- "$APP" 2>/dev/null | sed -n "s/^#* *designated => /$REQ_LABEL: /p"
say "Hazır: $APP" "Ready: $APP"
