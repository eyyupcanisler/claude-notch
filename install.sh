#!/bin/bash
# ClaudeNotch installer and updater: one command does everything.
#
#   curl -fsSL https://raw.githubusercontent.com/eyyupcanisler/claude-notch/main/install.sh | bash
#
# It gets the app (the latest GitHub release when there is one, else it builds this repo from
# source), puts it in Applications, connects Claude Code (hooks + the status line for plan
# usage, both after a backup of ~/.claude/settings.json), turns on Open at login and starts
# it. Running it again updates. Remove everything again with:
#
#   curl -fsSL https://raw.githubusercontent.com/eyyupcanisler/claude-notch/main/install.sh | bash -s -- --uninstall
#
# Options: --uninstall, --from-source (build even when a release exists), --no-hooks,
# --no-statusline, --no-login, --ref <branch> (source to build, default main).
#
# The whole script is one function, called on the last line: piped into bash, it is read to
# the end before anything runs, so no command can swallow the rest of it from stdin.

main() {
  set -euo pipefail

  local REPO="${CLAUDE_NOTCH_REPO:-eyyupcanisler/claude-notch}"
  local REF="${CLAUDE_NOTCH_REF:-main}"
  local BUNDLE_ID="com.eyyupcan.claudenotch"
  local SUPPORT="$HOME/Library/Application Support/ClaudeNotch"
  # Tests: no app is stopped or started, no defaults or keychain written.
  local TESTING="${CLAUDE_NOTCH_INSTALL_TEST:-}"
  local MODE=install FROM_SOURCE="" HOOKS=1 STATUSLINE=1 LOGIN=1
  # The checkout this script runs from, if it is one: only when the script is a real file
  # (piped from curl it is not, and the current folder may be an old clone of anything).
  local HERE=""
  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ ! -f "$HERE/Package.swift" ] || [ ! -x "$HERE/scripts/build-app.sh" ]; then HERE=""; fi
  fi

  # Messages follow CLAUDE_NOTCH_LANG (tr or en), else the Mac's first language: Turkish on a
  # Turkish Mac, English otherwise. Usage: say "<Turkish>" "<English>".
  local NOTCH_LANG=en
  case "${CLAUDE_NOTCH_LANG:-$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z_-]//gp')}" in
    tr | tr[-_]*) NOTCH_LANG=tr ;;
  esac
  say() { if [ "$NOTCH_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
  step() { printf '\n\033[1m==> %s\033[0m\n' "$(say "$1" "$2")"; }
  fail() { printf '\n\033[31m%s\033[0m\n' "$(say "$1" "$2")" >&2; exit 1; }

  while [ $# -gt 0 ]; do
    case "$1" in
      --uninstall) MODE=uninstall ;;
      --from-source) FROM_SOURCE=1 ;;
      --no-hooks) HOOKS="" ;;
      --no-statusline) STATUSLINE="" ;;
      --no-login) LOGIN="" ;;
      --ref)
        shift
        [ $# -gt 0 ] || fail "--ref bir dal adı bekliyor" "--ref needs a branch name"
        REF="$1"
        ;;
      -h | --help)
        sed -n '2,14p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) fail "Bilinmeyen seçenek: $1" "Unknown option: $1" ;;
    esac
    shift
  done

  # The installed copy: where an earlier install put it (also /Applications, where the
  # release notes used to say), else ~/Applications (no admin rights needed).
  local PLACES=("$HOME/Applications/ClaudeNotch.app")
  [ -n "$TESTING" ] || PLACES+=("/Applications/ClaudeNotch.app")
  local DEST=""
  for d in "${PLACES[@]}"; do
    if [ -d "$d" ]; then DEST="$d"; break; fi
  done

  stop_app() {
    [ -z "$TESTING" ] || return 0
    # SIGTERM (the app quits cleanly on it); an Apple Event "quit" would ask for Automation.
    if pkill -x ClaudeNotch 2>/dev/null; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x ClaudeNotch >/dev/null 2>&1 || break
        sleep 0.3
      done
      pkill -9 -x ClaudeNotch 2>/dev/null || true
    fi
  }

  if [ "$MODE" = uninstall ]; then
    step "ClaudeNotch kaldırılıyor" "Removing ClaudeNotch"
    # Settings first: the hooks and the status line must stop pointing at the app's files
    # before those files go. Nothing is deleted unless that worked.
    command -v jq >/dev/null 2>&1 \
      || fail "jq gerekli (~/.claude/settings.json'u geri almak için); hiçbir şey silinmedi." \
        "jq is needed (to undo ~/.claude/settings.json); nothing was removed."
    local SCRIPTS=""
    if [ -n "$DEST" ] && [ -f "$DEST/Contents/Resources/install-statusline.sh" ]; then
      SCRIPTS="$DEST/Contents/Resources"
    elif [ -n "$HERE" ]; then
      SCRIPTS="$HERE/scripts"
    else
      CN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-notch-install.XXXXXX")"
      trap 'rm -rf "${CN_WORK:-}"' EXIT
      SCRIPTS="$CN_WORK"
      local raw="https://raw.githubusercontent.com/$REPO/$REF/scripts"
      curl -fsSL -o "$SCRIPTS/install-hooks.sh" "$raw/install-hooks.sh" \
        && curl -fsSL -o "$SCRIPTS/install-statusline.sh" "$raw/install-statusline.sh" \
        || fail "Kaldırma betikleri indirilemedi; hiçbir şey silinmedi." \
          "Could not download the removal scripts; nothing was removed."
    fi
    stop_app
    CLAUDE_NOTCH_LANG="$NOTCH_LANG" bash "$SCRIPTS/install-hooks.sh" --uninstall </dev/null \
      || fail "Kancalar kaldırılamadı; hiçbir şey silinmedi." "Could not remove the hooks; nothing was removed."
    CLAUDE_NOTCH_LANG="$NOTCH_LANG" bash "$SCRIPTS/install-statusline.sh" --uninstall </dev/null \
      || fail "Durum satırı geri alınamadı; uygulama dosyaları silinmedi." \
        "Could not put the status line back; the app's files were not removed."
    if [ -z "$TESTING" ]; then
      defaults delete "$BUNDLE_ID" loginWanted >/dev/null 2>&1 || true
    fi
    for d in "${PLACES[@]}"; do
      if [ -d "$d" ]; then rm -rf "$d" && say "Silindi: $d" "Removed: $d"; fi
    done
    # Everything in the app's folder but the signing keychain's password (a later build from
    # source signs with the same identity, so macOS keeps the permissions).
    if [ -d "$SUPPORT" ]; then
      find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name 'signing-keychain.pass' -exec rm -rf {} +
    fi
    say "Bitti. Ayarlar (defaults) ve imza anahtar zinciri kaldı; bir sonraki kurulum onları kullanır." \
      "Done. The app's settings (defaults) and its signing keychain stay; a later install reuses them."
    return 0
  fi

  # --- Checks
  step "Kontroller" "Checking this Mac"
  local MACOS
  MACOS="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  [ "${MACOS%%.*}" -ge 14 ] 2>/dev/null \
    || fail "ClaudeNotch macOS 14 ya da üstünü ister (bu Mac: $MACOS)." "ClaudeNotch needs macOS 14 or later (this Mac: $MACOS)."
  if ! command -v jq >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      say "jq kuruluyor (Homebrew)..." "Installing jq (Homebrew)..."
      brew install jq </dev/null || fail "jq kurulamadı: brew install jq" "Could not install jq: brew install jq"
    else
      fail "jq gerekli (macOS 15 ile gelir). macOS 14'te: Homebrew kurun, sonra brew install jq." \
        "jq is needed (macOS 15 ships it). On macOS 14: install Homebrew, then brew install jq."
    fi
  fi
  if [ ! -d "$HOME/.claude" ] && ! command -v claude >/dev/null 2>&1; then
    say "Not: Claude Code bulunamadı. Uygulama yine kurulur; Claude Code'u kurduktan sonra bu komutu bir kez daha çalıştırın." \
      "Note: Claude Code was not found. The app is installed anyway; run this command once more after installing Claude Code."
  fi
  say "macOS $MACOS, jq: $(command -v jq)" "macOS $MACOS, jq: $(command -v jq)"

  # Global, not local: the EXIT trap runs after main has returned.
  CN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-notch-install.XXXXXX")"
  trap 'rm -rf "${CN_WORK:-}"' EXIT
  local WORK="$CN_WORK"
  local APP=""

  # --- The app: a release when there is one
  if [ -z "$FROM_SOURCE" ]; then
    local ZIP_URL="${CLAUDE_NOTCH_ZIP_URL:-}"
    if [ -z "$ZIP_URL" ]; then
      ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | jq -r '[.assets[]? | select(.name | test("^ClaudeNotch-.*\\.zip$")) | .browser_download_url][0] // empty' \
          2>/dev/null || true)"
    fi
    if [ -n "$ZIP_URL" ]; then
      step "Sürüm indiriliyor" "Downloading the release"
      say "$ZIP_URL" "$ZIP_URL"
      curl -fL --progress-bar -o "$WORK/app.zip" "$ZIP_URL" \
        || fail "İndirilemedi: $ZIP_URL" "Download failed: $ZIP_URL"
      ditto -x -k "$WORK/app.zip" "$WORK/release" || fail "Zip açılamadı." "Could not unzip the release."
      APP="$WORK/release/ClaudeNotch.app"
      [ -d "$APP" ] || fail "Zip'te ClaudeNotch.app yok." "The zip has no ClaudeNotch.app."
      codesign --verify --deep --strict "$APP" 2>/dev/null \
        || fail "İndirilen uygulamanın imzası geçersiz; kurulmadı." "The downloaded app's signature is not valid; nothing was installed."
    else
      say "Bu depoda henüz sürüm yok: kaynaktan derleniyor." "No release in this repository yet: building from source."
    fi
  fi

  # --- The app: built from source
  if [ -z "$APP" ]; then
    step "Kaynaktan derleniyor (1-3 dakika)" "Building from source (1-3 minutes)"
    if ! xcrun --find swift >/dev/null 2>&1; then
      xcode-select --install >/dev/null 2>&1 || true
      fail "Derlemek için Apple'ın Komut Satırı Araçları gerekli. Açılan pencereden kurun, sonra bu komutu tekrar çalıştırın." \
        "Building needs Apple's Command Line Tools. Install them from the window that opened, then run this command again."
    fi
    local SWIFT_MAJOR
    SWIFT_MAJOR="$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\).*/\1/p' | head -n 1)"
    [ "${SWIFT_MAJOR:-0}" -ge 6 ] 2>/dev/null \
      || fail "Swift 6 gerekli (bulunan: ${SWIFT_MAJOR:-yok}). Komut Satırı Araçları'nı güncelleyin: softwareupdate --list" \
        "Swift 6 is needed (found: ${SWIFT_MAJOR:-none}). Update the Command Line Tools: softwareupdate --list"
    local SRC
    # Run from a checkout: build that checkout. Piped from curl: download the source.
    if [ -n "$HERE" ]; then
      SRC="$HERE"
      say "Bu kopya derleniyor: $SRC" "Building this checkout: $SRC"
    else
      SRC="$WORK/src"
      mkdir -p "$SRC"
      local SRC_URL="${CLAUDE_NOTCH_SRC_URL:-https://github.com/$REPO/archive/refs/heads/$REF.tar.gz}"
      curl -fsSL "$SRC_URL" | tar -xz -C "$SRC" --strip-components 1 \
        || fail "Kaynak indirilemedi: $REPO ($REF)" "Could not download the source: $REPO ($REF)"
    fi
    # A stable signing identity of its own (no password prompt), so macOS keeps the
    # permissions you grant across updates.
    if [ -z "$TESTING" ]; then
      (cd "$SRC" && scripts/make-signing-identity.sh </dev/null >/dev/null 2>&1) \
        || say "Kalıcı imza kurulamadı; ad-hoc imzalanacak (izinler her güncellemede tekrar sorulur)." \
          "Could not set up a lasting signature; signing ad-hoc (permissions are asked again after each update)."
    fi
    (cd "$SRC" && CLAUDE_NOTCH_LANG="$NOTCH_LANG" scripts/build-app.sh </dev/null) \
      || fail "Derleme başarısız (yukarıdaki çıktıya bakın)." "The build failed (see the output above)."
    APP="$SRC/build.noindex/ClaudeNotch.app"
  fi

  # --- Install
  step "Kuruluyor" "Installing"
  [ -n "$DEST" ] || DEST="$HOME/Applications/ClaudeNotch.app"
  stop_app
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST"
  ditto "$APP" "$DEST" || fail "Kopyalanamadı: $DEST" "Could not copy to: $DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  say "Uygulama: $DEST" "App: $DEST"

  # --- Connect Claude Code (what Settings > General > Connect does)
  mkdir -p "$SUPPORT" && chmod 700 "$SUPPORT"
  local RES="$DEST/Contents/Resources"
  if [ -n "$HOOKS" ]; then
    step "Claude Code'a bağlanıyor: kancalar" "Connecting Claude Code: hooks"
    cp "$RES/claude-notch-hook.sh" "$SUPPORT/claude-notch-hook.sh.tmp.$$" \
      && chmod 755 "$SUPPORT/claude-notch-hook.sh.tmp.$$" \
      && mv -f "$SUPPORT/claude-notch-hook.sh.tmp.$$" "$SUPPORT/claude-notch-hook.sh"
    CLAUDE_NOTCH_LANG="$NOTCH_LANG" bash "$RES/install-hooks.sh" --hook "$SUPPORT/claude-notch-hook.sh" </dev/null \
      || fail "Kancalar kurulamadı." "Could not install the hooks."
  fi
  if [ -n "$STATUSLINE" ] && [ -f "$RES/install-statusline.sh" ]; then
    step "Claude Code'a bağlanıyor: durum satırı (plan kullanımı)" "Connecting Claude Code: status line (plan usage)"
    CLAUDE_NOTCH_LANG="$NOTCH_LANG" bash "$RES/install-statusline.sh" --bridge "$RES/claude-notch-statusline.sh" </dev/null \
      || say "Durum satırı bağlanamadı; Ayarlar > Genel > Bağla ile tekrar deneyin." \
        "Could not connect the status line; try again in Settings > General > Connect."
  elif [ -n "$STATUSLINE" ]; then
    say "Bu sürümde durum satırı köprüsü yok; plan kullanımı için daha yeni bir sürüm gerekir." \
      "This version has no status line bridge; plan usage needs a newer one."
  fi

  # --- Start
  if [ -z "$TESTING" ]; then
    # The app registers itself as a login item when it starts with this set.
    if [ -n "$LOGIN" ]; then defaults write "$BUNDLE_ID" loginWanted -bool true; fi
    open "$DEST"
  fi

  step "Hazır" "Done"
  say "ClaudeNotch çalışıyor. Bir sonraki Claude Code mesajınız çentikte görünür (açık sohbetler kancaları sonraki mesajlarında alır)." \
    "ClaudeNotch is running. Your next Claude Code message shows up in the notch (open chats pick up the hooks with their next message)."
  say "Bir satıra tıklayınca macOS bir kez terminalinizi kontrol etme izni ister (Otomasyon): İzin Ver deyin." \
    "The first click on a chat makes macOS ask once to let it control your terminal (Automation): click Allow."
  say "Ayarlar: Spotlight'ta ClaudeNotch'ı tekrar açın. Güncellemek için bu komutu yeniden çalıştırın." \
    "Settings: open ClaudeNotch again from Spotlight. To update, run this command again."
}

main "$@"
