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
VERSION="${CLAUDE_NOTCH_VERSION:-1.0.0}"
SIGN_ID="${CLAUDE_NOTCH_SIGN_ID:-ClaudeNotch Dev}"
# Info.plist texts are English (the development language); the Turkish ones are in
# Resources/Localization/tr.lproj/InfoPlist.strings.
AE_USAGE="ClaudeNotch controls your terminal (Ghostty, Terminal, iTerm2) to bring a session's"
AE_USAGE+=" tab to the front when you click that session, and to read which tab is focused. With"
AE_USAGE+=" the Spotify module on, it controls Spotify to get the playing track's cover and to send"
AE_USAGE+=" play / pause / next / previous."
CAL_USAGE="With the Calendar module on, ClaudeNotch reads the next 12 hours of events to show the"
CAL_USAGE+=" upcoming meeting in the notch and remind you 10 minutes before; it never changes or"
CAL_USAGE+=" sends anything."

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
# UI strings (en, tr) for Bundle.main; macOS picks the first of the user's preferred languages
# the app has, English otherwise. Plain .lproj folders, not a SwiftPM resource bundle (one at
# the app root would break code signing).
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
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 eyyupcan. All rights reserved.</string>
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
      echo "Could not sign with \"$SIGN_ID\" (code $rc); trying another way." >&2
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
    echo "codesign is waiting for keychain permission; falling back to ad-hoc signing." >&2
    echo "For a lasting signature without a dialog: scripts/make-signing-identity.sh" >&2
  else
    echo "Could not sign with \"$SIGN_ID\" (code $rc); falling back to ad-hoc signing." >&2
  fi
fi
# 3. Ad-hoc.
if [ -z "$SIGNED" ]; then
  codesign -s - --force "$APP"
  echo "Note: ad-hoc signature; the Automation permission resets on every build." >&2
  echo "For a lasting signature, run once: scripts/make-signing-identity.sh" >&2
fi
codesign --verify --strict "$APP"
echo "Signature: ${SIGNED:-ad-hoc}"
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => /Requirement: /p'
echo "Ready: $APP"
