<div align="center">

<img src="docs/icon.png" width="128" alt="ClaudeNotch icon">

# ClaudeNotch

**Your MacBook notch, watching your Claude Code sessions.**
Know when a run finishes, answer permission prompts and questions without going back to the
terminal, and keep a few handy tools one glance away.

**English** · [Türkçe](README.tr.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)

<img src="docs/demo.gif" width="680" alt="ClaudeNotch: a permission request, a question and a finished run in the notch">

</div>

> The interface follows your Mac: Turkish when the Mac's first language is Turkish, English
> otherwise. Settings → *Genel → Dil* (General → Language) sets Türkçe or English instead, after
> a restart. Settings paths below give the Turkish label first, with the English one in
> parentheses. ClaudeNotch is a personal open-source project, not an Anthropic product.

## What it does

- **Live status under the notch.** One thin segment per Claude Code session. With the default
  **Classic** colors: Claude orange with a moving shine while it works, amber with a slow fade
  when it needs you, green when it finished and you have not looked yet (it flashes once on
  arrival), red on an error, faint white when idle.
  Settings → *Genel → Görünüm → Durum renkleri* → **Renk körlüğüne uygun** (General →
  Appearance → Status colors → Colorblind-friendly) switches at once to colors that stay apart for red-green color blindness, plus shape signs: cyan `#22D3EE`
  with a moving shine = working, yellow `#F0E442` with a slow fade = needs you, solid blue
  `#388BFD` = done, a broken pink-red `#FB7185` bar (three short dashes) = error, faint white =
  idle; the shapes tell the states apart even in grayscale. With Reduce Motion on, the shine and
  the fade stop, so working, needs you and done are told apart by color and brightness only.
- **Permission requests in the notch.** An island drops down with the command; allow or deny
  with a click or **⌃⌥Y / ⌃⌥N** from any app. Risky commands (`rm -rf`, `sudo`, `curl … | sh`,
  `git push --force`, `git reset --hard`, uploads of local files…) need a short hold. Nothing is ever allowed by default.
  Optional: Settings → *Bildirimler → Terminali öndeyken adaları gizle* (Notifications → Hide
  islands while their terminal is in front; default off): while the session's terminal app is
  the front app, whichever of its tabs you are in, its permission requests, plan approvals and
  "waiting for input" notices drop no island: answer them in the terminal. An island already up
  goes away when you switch to that terminal. Requests still wait in the panel, and nothing
  drops down later by itself.
- **Answer Claude's questions.** `AskUserQuestion` options show up as buttons; pick with a click
  or **⌃⌥1…4**, send with **⌃⌥Y**. Free text and plan approval stay in the terminal.
  Prefer the terminal? Turn off Settings → *Bildirimler → Claude’un sorularını çentikte
  yanıtla* (Notifications → Answer Claude's questions in the notch): the terminal then asks at
  once, and the notch only tells you. The session's segment fades slowly in the "needs you"
  color, an island drops down with "Claude is asking you" and the question text, and a click on
  it jumps to that session's terminal tab. If that terminal app (Ghostty, Terminal, iTerm2…; not
  an editor such as VS Code) is the front app when the question arrives, the island stays
  hidden: you are looking at the question, and **⌃⌥J** still jumps to the tab. An island
  already up goes away when you switch to that terminal.
- **Jump to what needs you.** **⌃⌥J** brings forward the terminal tab of the session that needs
  you most: a permission request first, then a question, plan approval or input wait, then an
  unseen error, then an unseen finished run.
- **Terminal bell (optional).** Settings → *Bildirimler → Claude Code bildirim gönderince
  terminal zilini çal* (Notifications → Ring the terminal bell when Claude Code notifies;
  default off) rings that session's terminal bell on every Claude Code notification
  (permission, question, waiting for input): Ghostty puts 🔔 on the tab until you look at it,
  Terminal and iTerm2 mark the tab (and beep, unless their bell is set to visual). In silent
  mode only what needs an answer rings. Nothing rings while the app is not running. If Claude
  Code itself is set to ring the bell (`preferredNotifChannel`: `terminal_bell`), each
  notification rings twice.
- **The panel.** Hover the notch: every session with its status, the turn's elapsed time in
  dot-matrix digits, a rhythm strip of its tool calls, subagents, and context left. Click a row
  to jump to its Ghostty / Terminal / iTerm2 tab.
- **Small tools, all optional:** Pomodoro / focus timer (it grows out of the notch while it
  runs), calendar reminders with a **Join** button (macOS Calendar or Google Calendar directly),
  Spotify cover and controls, a clipboard shelf with pinning, weather, plan usage, battery,
  quiet hours and a silent mode.
- **Light on the machine.** Event-driven: no polling loops while idle, ~40 MB with the panel
  closed. Works on external displays too (a pill stands in for the notch).

## Install

You need a Mac on **macOS 14 or later** (a notch is nice, not required) and
[Claude Code](https://claude.com/claude-code). On macOS 14 also `brew install jq` (macOS 15+
ships it).

### Option 1: download the app

1. Download `ClaudeNotch-<version>.zip` from the
   [latest release](https://github.com/eyyupcanisler/claude-notch/releases/latest), unzip it and
   move **ClaudeNotch.app** to **Applications**.
2. Open it. macOS blocks the first launch because the app is not signed with an Apple Developer
   ID: go to **System Settings → Privacy & Security** and click **Open Anyway**.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app`.)
3. Open **ClaudeNotch** again from Spotlight to get its Settings, then
   **Genel → Claude Code bağlantısı → Kancaları kur** (General → Claude Code connection →
   Install hooks). It adds the hooks to
   `~/.claude/settings.json` after backing it up and leaves the rest of the file alone.

That's it: your next Claude Code message shows up in the notch.

### Option 2: build from source

Needs Xcode or the Command Line Tools (`xcode-select --install`) and `jq`.

```sh
git clone https://github.com/eyyupcanisler/claude-notch.git
cd claude-notch
scripts/make-signing-identity.sh   # once: a local signing identity, so macOS permissions stick
scripts/build-app.sh               # builds build.noindex/ClaudeNotch.app
scripts/install-app.sh             # copies it to ~/Applications and starts it
scripts/install-hooks.sh           # adds the hooks to ~/.claude/settings.json (backs it up first)
```

Either way: ClaudeNotch has no Dock icon, launching it again opens its Settings. Turn on
*Oturum açılışında başlat* (Open at login) in the *Genel* (General) tab.

Optional:

- `scripts/install-statusline.sh` adds one line to your status line script so the notch can show
  your plan usage (Claude Code only reports it to the status line). The ring shows the fuller of
  the 5-hour and weekly windows, and the notch warns at 80% and 95% of the 5-hour limit. When the
  status line passes only the weekly window (`rate_limits.seven_day`, as newer Claude Code
  does), the ring follows the weekly limit; the warnings then come only with Settings →
  *Modüller → Haftalık limit %80’e, sonra %95’e gelince uyar* (Modules → Warn when the weekly
  limit reaches 80%, then 95%; default off).
- `scripts/install-hooks.sh --uninstall` removes the hooks again.

## How it works

```
Claude Code ── hook ──▶ hooks/claude-notch-hook.sh ── curl ──▶ Unix socket ──▶ ClaudeNotch.app
                                              ~/Library/Application Support/ClaudeNotch/notch.sock
```

- The socket lives in a `0700` folder, the socket itself is `0600`; there is no TCP port.
- `PermissionRequest` waits for your answer (up to ~10 min) side by side with the terminal
  prompt; answering in either place wins. If the app is not running the hook exits silently and
  Claude Code asks in the terminal as usual.
- A `PreToolUse` hook on `AskUserQuestion` holds the question until you answer it in the notch;
  switching to that session's terminal tab hands it back to the terminal. With *Claude’un
  sorularını çentikte yanıtla* (Answer Claude's questions in the notch) off, the app answers that hook empty at once, so Claude Code asks in
  the terminal as usual and the fire-and-forget `PreToolUse` / `PermissionRequest` events only
  tell the notch that Claude is asking.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌃⌥Space | Open the panel with the keyboard |
| ⌃⌥Y / ⌃⌥N | Allow / deny the request on screen (questions: send / answer in terminal) |
| ⌃⌥1 … ⌃⌥4 | Pick an option of the question on screen (only while one is shown) |
| ⌃⌥J | Jump to the terminal tab of the session that needs you |
| ⌃⌥P | Start / pause a Pomodoro |
| ⌃⌥V | Copy the newest shelf item back to the clipboard |

All of them except ⌃⌥1 … ⌃⌥4 can be changed in Settings → *Kısayollar* (Shortcuts); the option
keys stay ⌃⌥1 … ⌃⌥4 with every preset. **Caps Lock kullan (Hyper tuşu)** (Use Caps Lock (Hyper
key)) there switches every shortcut to ⌃⌥⇧⌘ + the same key (Caps Lock + Y allows, Caps Lock + J
jumps...), and **Varsayılana dön** (Reset to defaults) goes back to ⌃⌥. Nothing changes until
you press one of them. The Hyper preset needs a tool that turns Caps Lock
into ⌃⌥⇧⌘: Raycast (Settings → Advanced → Hyper Key), Hyperkey or Karabiner-Elements.

## Google Calendar (optional)

ClaudeNotch can read Google Calendar directly with **your own** OAuth client (read-only):
create a Google Cloud project, enable the Calendar API, add an OAuth consent screen and a
**Desktop app** client, download its JSON and pick it in Settings → *Modüller* → *Takvim* (Modules → Calendar). The
step-by-step guide is in the [Turkish README](README.tr.md#google-takvim-doğrudan-bağlantı).
Your client and tokens stay on your Mac in a `0600` file; nothing is sent anywhere but Google.

## Privacy

Everything runs locally. ClaudeNotch talks to Claude Code through a local socket and to the
network only for the modules you turn on (weather from Open-Meteo, Google Calendar, Spotify
artwork). The clipboard shelf never keeps items marked concealed by password managers.
Unpinned shelf items live in a temporary folder and are deleted when the shelf is turned off or
the app restarts; pinned items stay on disk. Settings → *Modüller* (Modules) has two opt-in
options: *Sabitlenmemiş öğeleri sil* (Remove unpinned items after) 1, 3 or 7 days (default:
never) and *Raf kapatılınca sabitlenenleri de sil* (Delete pinned items when the shelf is turned
off; default: off).

## Development

```sh
swift build && swift test   # the Core library has the logic and the tests
scripts/demo/record.sh      # re-records docs/demo.gif with made-up sessions (needs ffmpeg)
scripts/make-release.sh 1.0.1  # builds the zip and publishes a GitHub release
```

`CLAUDE_NOTCH_DEBUG=1` enables `/debug/*` routes on the socket for UI tests; see the Turkish
README for the details.

## License

[MIT](LICENSE) © 2026 Eyyupcan Isler
