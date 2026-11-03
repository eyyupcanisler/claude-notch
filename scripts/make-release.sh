#!/bin/bash
# Builds a downloadable ClaudeNotch-<version>.zip and publishes it as a GitHub release.
# Usage: scripts/make-release.sh <version> [--draft]     e.g. scripts/make-release.sh 1.0.0
# The app is signed with the local "ClaudeNotch Dev" identity, not an Apple Developer ID, so
# macOS asks once before the first launch (README: "Download").
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?Sürüm gerekli, ör. 1.0.0}"
DRAFT="${2:-}"
TAG="v$VERSION"
DIST="$ROOT/dist"
ZIP="$DIST/ClaudeNotch-$VERSION.zip"

[ -z "$(git status --porcelain)" ] || { echo "Önce değişiklikleri commit'leyin." >&2; exit 1; }
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
cat > "$NOTES_FILE" <<NOTES_EOF
**Kurulum / Install**

1. \`ClaudeNotch-$VERSION.zip\` dosyasını indir, aç, **ClaudeNotch.app**'i **Applications** (ya da ~/Applications) klasörüne taşı.
2. İlk açılışta macOS uygulamayı engeller (Apple Developer ID ile imzalı değil): **System Settings → Privacy & Security → Open Anyway**. Ya da Terminal'de: \`xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app\`
3. Spotlight'tan **ClaudeNotch**'ı tekrar aç → Ayarlar → **Genel → Claude Code bağlantısı → Kancaları kur**.

Gereksinim: macOS 14+ (macOS 14'te \`brew install jq\`), Claude Code.

SHA-256: \`$SUM\`
NOTES_EOF
git tag -a "$TAG" -m "ClaudeNotch $VERSION" 2>/dev/null || true
git -c http.postBuffer=157286400 push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "ClaudeNotch $VERSION" --notes-file "$NOTES_FILE" \
  ${DRAFT:+--draft}
