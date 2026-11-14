#!/bin/bash
# Builds a downloadable ClaudeNotch-<version>.zip and publishes it as a GitHub release.
# Usage: scripts/make-release.sh <version> [--draft]     e.g. scripts/make-release.sh 1.0.0
# The app is signed with the local "ClaudeNotch Dev" identity, not an Apple Developer ID, so
# macOS asks once before the first launch (README: "Download").
set -eu
# Messages are Turkish (the original) unless CLAUDE_NOTCH_LANG=en; the app passes its own
# language when it runs install-hooks.sh. Usage: say "<Turkish>" "<English>".
say() { if [ "${CLAUDE_NOTCH_LANG:-tr}" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -n "${1:-}" ] || { say "Sürüm gerekli, ör. 1.0.0" "Version required, e.g. 1.0.0" >&2; exit 1; }
VERSION="$1"
DRAFT="${2:-}"
TAG="v$VERSION"
DIST="$ROOT/dist"
ZIP="$DIST/ClaudeNotch-$VERSION.zip"

[ -z "$(git status --porcelain)" ] || { say "Önce değişiklikleri commit'leyin." "Commit your changes first." >&2; exit 1; }
CLAUDE_NOTCH_VERSION="$VERSION" scripts/build-app.sh
mkdir -p "$DIST"
rm -f "$ZIP"
# --sequesterRsrc: extended attributes go to __MACOSX, never inside the bundle (a plain unzip
# would otherwise drop "._" files into it and break the signature).
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build.noindex/ClaudeNotch.app" "$ZIP"
codesign --verify --deep --strict "$ROOT/build.noindex/ClaudeNotch.app"
SUM="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$ZIP  $SUM"

NOTES_FILE="$DIST/notes-$VERSION.md"
if [ "${CLAUDE_NOTCH_LANG:-tr}" = en ]; then
  cat > "$NOTES_FILE" <<NOTES_EOF
**Install**

1. Download \`ClaudeNotch-$VERSION.zip\`, unzip it and move **ClaudeNotch.app** to **Applications** (or ~/Applications).
2. On first launch macOS blocks the app (it is not signed with an Apple Developer ID): **System Settings → Privacy & Security → Open Anyway**. Or in Terminal: \`xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app\`
3. Open **ClaudeNotch** again from Spotlight → Settings → **General → Claude Code connection → Install hooks**.

Requires: macOS 14+ (on macOS 14, \`brew install jq\`), Claude Code.

SHA-256: \`$SUM\`
NOTES_EOF
else
  cat > "$NOTES_FILE" <<NOTES_EOF
**Kurulum / Install**

1. \`ClaudeNotch-$VERSION.zip\` dosyasını indir, aç, **ClaudeNotch.app**'i **Applications** (ya da ~/Applications) klasörüne taşı.
2. İlk açılışta macOS uygulamayı engeller (Apple Developer ID ile imzalı değil): **System Settings → Privacy & Security → Open Anyway**. Ya da Terminal'de: \`xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app\`
3. Spotlight'tan **ClaudeNotch**'ı tekrar aç → Ayarlar → **Genel → Claude Code bağlantısı → Kancaları kur**.

Gereksinim: macOS 14+ (macOS 14'te \`brew install jq\`), Claude Code.

SHA-256: \`$SUM\`
NOTES_EOF
fi
git tag -a "$TAG" -m "ClaudeNotch $VERSION" 2>/dev/null || true
git -c http.postBuffer=157286400 push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "ClaudeNotch $VERSION" --notes-file "$NOTES_FILE" \
  ${DRAFT:+--draft}
