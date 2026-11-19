#!/bin/bash
# Builds a downloadable ClaudeNotch-<version>.zip and publishes it as a GitHub release.
# Usage: scripts/make-release.sh <version> [--draft]     e.g. scripts/make-release.sh 1.0.0
# The app is signed with the local "ClaudeNotch Dev" identity, not an Apple Developer ID, so
# macOS asks once before the first launch (README: "Download").
set -eu
# Messages follow CLAUDE_NOTCH_LANG (tr or en), else the Mac's first language:
# Turkish on a Turkish Mac, English otherwise.
# Usage: say "<Turkish>" "<English>". The release notes below stay Turkish unless
# CLAUDE_NOTCH_LANG=en, whatever the Mac uses.
case "${CLAUDE_NOTCH_LANG:-$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z_-]//gp')}" in
  tr | tr[-_]*) NOTCH_LANG=tr ;;
  *) NOTCH_LANG=en ;;
esac
say() { if [ "$NOTCH_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
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
case "${CLAUDE_NOTCH_LANG:-tr}" in en | en[-_]*) NOTES_LANG=en ;; *) NOTES_LANG=tr ;; esac
if [ "$NOTES_LANG" = en ]; then
  cat > "$NOTES_FILE" <<NOTES_EOF
**Install**

The easiest way (downloads this release, connects Claude Code and starts the app):

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/furkanzt/claude-notch/main/install.sh | bash
\`\`\`

By hand: download \`ClaudeNotch-$VERSION.zip\`, unzip it, move **ClaudeNotch.app** to **Applications**, open it (macOS blocks the first launch because the app has no Apple Developer ID: **System Settings → Privacy & Security → Open Anyway**), then open it again from Spotlight → Settings → **General → Claude Code connection → Connect**.

Requires: macOS 14+ (on macOS 14, \`brew install jq\`), Claude Code.

SHA-256: \`$SUM\`
NOTES_EOF
else
  cat > "$NOTES_FILE" <<NOTES_EOF
**Kurulum / Install**

1. \`ClaudeNotch-$VERSION.zip\` dosyasını indir, aç, **ClaudeNotch.app**'i **Applications** (ya da ~/Applications) klasörüne taşı.
2. İlk açılışta macOS uygulamayı engeller (Apple Developer ID ile imzalı değil): **System Settings → Privacy & Security → Open Anyway**. Ya da Terminal'de: \`xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app\`
3. Spotlight'tan **ClaudeNotch**'ı tekrar aç → Ayarlar → **Genel → Claude Code bağlantısı → Bağla**.

En kolayı: \`curl -fsSL https://raw.githubusercontent.com/furkanzt/claude-notch/main/install.sh | bash\` (bu sürümü indirir, Claude Code'u bağlar ve uygulamayı başlatır).

Gereksinim: macOS 14+ (macOS 14'te \`brew install jq\`), Claude Code.

SHA-256: \`$SUM\`
NOTES_EOF
fi
git tag -a "$TAG" -m "ClaudeNotch $VERSION" 2>/dev/null || true
git -c http.postBuffer=157286400 push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "ClaudeNotch $VERSION" --notes-file "$NOTES_FILE" \
  ${DRAFT:+--draft}
