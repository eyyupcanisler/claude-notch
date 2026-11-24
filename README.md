<div align="center">

<img src="docs/icon.png" width="128" alt="ClaudeNotch icon">

# ClaudeNotch

**Your MacBook notch, watching your Claude Code sessions.**
See when a chat finishes or needs you, answer permission prompts without going back to the
terminal, and jump to the right tab with one click.

**English** · [Türkçe](README.tr.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)

<img src="docs/demo.gif" width="680" alt="ClaudeNotch: a permission request, a question and a finished run in the notch">

</div>

## Install

Paste this into Terminal (any terminal):

```sh
curl -fsSL https://raw.githubusercontent.com/eyyupcanisler/claude-notch/main/install.sh | bash
```

That one command:

1. gets the app (it builds it on your Mac, 1-3 minutes) and puts it in `~/Applications`;
2. connects Claude Code: hooks for status and permission requests, and the status line for
   your plan usage (it backs up `~/.claude/settings.json` first; your other settings, and
   any status line you already have, keep working as they are);
3. turns on *Open at login* and starts the app.

Your next Claude Code message shows up in the notch. Run the same command again to update.

**You need:** macOS 14 or later and [Claude Code](https://claude.com/claude-code). The build
needs Apple's Command Line Tools; if they are missing, the installer opens their install
window, and you run the command again afterwards. On macOS 14 it also needs `jq` (it installs
it with Homebrew when Homebrew is there; macOS 15 and later have it).

**First click on a chat:** macOS asks once whether ClaudeNotch may control your terminal
(*Automation*). Click **Allow**, or the click cannot select the chat's tab.

**Settings:** ClaudeNotch has no Dock icon. Open it again from Spotlight to see its Settings.

**Quit:** the power button in the panel's top bar (click it, then click the red **Quit**), or
Settings → General → **Quit ClaudeNotch** (⌘Q works there too). Open it from Spotlight to
start it again.

**Uninstall:**

```sh
curl -fsSL https://raw.githubusercontent.com/eyyupcanisler/claude-notch/main/install.sh | bash -s -- --uninstall
```

This removes the app, the hooks and the status line bridge, and puts your old status line back.

## What you get

- **A status line under the notch:** one segment per chat. Grey = working, amber = needs you,
  blue = finished and not looked at yet, red = error.
- **Wings beside the notch** say which chat wants what (a permission, a question, a finished
  run) for 4 seconds, then shrink to a small mark. Nothing ever drops down over your tabs.
- **Permission requests in the notch:** allow or deny with **⌃⌥Y / ⌃⌥N** from any app. Risky
  commands need a short hold.
- **Answer Claude's questions** with a click or **⌃⌥1…4**.
- **The panel** (hover the notch): every chat with its status and time. Click a row to jump to
  its terminal tab. **Pin** a chat to keep it on top, **drag** rows into your own order, or
  **hide** one until it does something new.
- **Plan usage:** your 5-hour and weekly limits in the panel, with a warning at 80% and 95%
  of the 5-hour limit (and of the weekly one, if you turn that on).
- **Small extras, all optional:** focus timer (a small ear beside the notch while it runs, so
  your browser tabs stay free), calendar reminders with a Join button, Spotify,
  clipboard shelf, weather, quiet hours, Do Not Disturb awareness.

The app speaks English and Turkish: it follows your Mac's language (Settings → General →
Language changes it). Every feature in detail, with its settings:
[docs/FEATURES.md](docs/FEATURES.md).

## Terminals

| Terminal | Click a chat | Tab titles, "seen when you look", "you are here", tab order |
| --- | --- | --- |
| Ghostty | selects the exact tab or split | yes |
| iTerm2 | selects the exact tab and pane | not yet |
| Terminal | selects the exact tab | not yet |
| Anything else (Warp, WezTerm, kitty, VS Code, Cursor…) | brings the app to the front | no |

ClaudeNotch learns the terminal from each chat itself, also when the terminal sets no
`TERM_PROGRAM`. A chat inside tmux brings its terminal app to the front (the tmux pane is not
selected).

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌃⌥Space | Open the panel with the keyboard |
| ⌃⌥Y / ⌃⌥N | Allow / deny the request on screen (questions: send / answer in terminal) |
| ⌃⌥1 … ⌃⌥4 | Pick an option of the question on screen |
| ⌃⌥J | Jump to the chat that needs you |
| ⌃⌥P | Start / pause the focus timer |
| ⌃⌥V | Copy the newest shelf item back |

Change them in Settings → Shortcuts (there is a Caps Lock "Hyper key" preset too).

## Something is off?

- **"Can't tell which terminal …"**: the chat started before ClaudeNotch was connected, or
  with an old hook. Run the install command again, then send one message in that chat.
- **No plan usage %**: Settings → General → *Claude Code connection* → *Status line* →
  **Connect**. The numbers appear
  after Claude Code next updates its status line (send any message).
- **A click does nothing**: System Settings → Privacy & Security → Automation → ClaudeNotch →
  turn your terminal on.
- **See what happened**: `log show --last 1h --style compact --predicate 'subsystem == "com.eyyupcan.claudenotch"'`

## Build it yourself

```sh
git clone https://github.com/eyyupcanisler/claude-notch.git
cd claude-notch
./install.sh                  # builds this checkout and does everything the one-liner does
swift build && swift test     # the Core library holds the logic and the tests
```

`./install.sh --help` lists its options (`--no-statusline`, `--no-login`, …).

## Privacy

Everything runs on your Mac. Claude Code talks to the app through a local socket (no network
port). The network is used only by the modules you turn on (weather, Google Calendar, Spotify
artwork). Details: [docs/FEATURES.md#privacy](docs/FEATURES.md#privacy).

## License

[MIT](LICENSE) © 2026 Eyyupcan Isler. ClaudeNotch is a personal open-source project, not an
Anthropic product.
