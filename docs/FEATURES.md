# ClaudeNotch: every feature in detail

The [README](../README.md) has the short version and the install command. This page is the
long one: what each part does, the settings behind it, and how it works inside.

## What it does

- **Live status under the notch.** One thin segment per Claude Code session. With the default
  **Classic** colors: color means "needs you" and nothing else. Solid grey with a moving shine
  while it works, amber with a slow fade when it needs you, blue when it finished and you
  have not looked yet (it flashes once on arrival), red on an error, faint white when idle.
  Settings → *Genel → Görünüm → Durum renkleri* → **Renk körlüğüne uygun** (General →
  Appearance → Status colors → Colorblind-friendly) switches at once to colors that stay apart for red-green color blindness, plus shape signs:
  grey `#8E8E8E` with a moving shine = working, yellow `#F0E442` with a slow fade = needs you,
  blue `#388BFD` = done (look at it), a broken pink-red `#FB7185` bar (three short dashes) = error,
  faint white = idle; in both palettes color means something for you (needs you, error, a finished chat to look at), and the shapes
  tell the states apart even in grayscale. With Reduce Motion on, the shine and
  the fade stop, so working, needs you and done are told apart by color and brightness only.
- **"Done" means done.** When the chat's turn ends while a workflow or background agent it
  started still runs (Claude Code lists it in the `Stop` hook), the session stays "working",
  shown as "In the background: …", with no done wing or chime, no "quiet for 10 min" note
  and no "waiting for your input". The done comes when that work is back and the turn really
  ends. A background shell or monitor (a dev server, a log watch) does not hold it.
- **Nothing drops down.** Permission requests, questions, plan approvals, finished runs, errors
  and module notes never expand below the menu-bar band, so what is under it (browser tabs)
  stays clickable. The notch grows sideways instead, at the same height ("wings"): for 4 s the
  left wing says who and what, with the project and the terminal tab's title ("claude-notch ·
  Fix tests wants to run"), and the right wing the detail (the command, the question's first
  words); that chat's segment of the status line lights up (a little taller and brighter)
  while its wing shows. Then both shrink to a small colored mark (a dot and a
  shield, ?, ! or check; a count when several are waiting). Only what blocks Claude keeps its
  mark: a permission request, question, plan approval or wait for input stays until handled;
  done, errors and module notes leave none (the status line keeps them). Under a Focus only
  those blocking ones show, and only as the mark (see below). Settings →
  *Bildirimler → Çentiğin yanında yalnızca küçük bir işaret göster* (Notifications → Show only a
  small mark beside the notch; also under General → Appearance; default off) skips the 4 s of
  text. Clicking the wings opens the panel (a terminal-only question jumps to its terminal);
  hovering the notch opens the panel as before (Settings > General > Appearance > **Open the
  panel on hover**; off: the notch only swells under the pointer, and a click opens it).
- **Permission requests in the notch.** The wings show the command; allow or deny
  with **⌃⌥Y / ⌃⌥N** from any app, or click the wings to open the panel. Risky commands (`rm -rf`, `sudo`, `curl … | sh`,
  `git push --force`, `git reset --hard`, uploads of local files…) need a short hold. Nothing is ever allowed by default.
  Optional: Settings → *Bildirimler → Terminali öndeyken kanatları gizle* (Notifications → Hide
  wings while their terminal is in front; default off): while the session's terminal app is
  the front app, whichever of its tabs you are in, its permission requests, plan approvals and
  "waiting for input" notices show no wing: answer them in the terminal. A wing already showing
  goes away when you switch to that terminal. Requests still wait in the panel; one you leave
  unanswered comes back as a small mark once that terminal is no longer in front (never as the
  4 s text).
- **Answer Claude's questions.** `AskUserQuestion` options show up as buttons; pick with a click
  or **⌃⌥1…4**, send with **⌃⌥Y**. Free text and plan approval stay in the terminal.
  Prefer the terminal? Turn off Settings → *Bildirimler → Claude’un sorularını çentikte
  yanıtla* (Notifications → Answer Claude's questions in the notch): the terminal then asks at
  once, and the notch only tells you. The session's segment fades slowly in the "needs you"
  color, the wings say "<project> asks:" with the question's first words, and a click on them
  jumps to that session's terminal tab. If that terminal app (Ghostty, Terminal, iTerm2…; not an
  editor such as VS Code) is the front app when the question arrives, no wing shows: you are
  looking at the question, and **⌃⌥J** still jumps to the tab. A wing already showing goes away
  when you switch to that terminal; leave it unanswered and its small mark comes back.
- **Jump to what needs you.** **⌃⌥J** brings forward the terminal tab of the session that needs
  you most: a permission request first, then a question, plan approval or input wait, then an
  unseen error, then an unseen finished run.
- **Seen when you look (Ghostty; Accessibility optional).** A finished or waiting chat's
  segment clears when you switch to its Ghostty tab or split. By default, while Ghostty is in
  front and any Ghostty chat exists, the notch asks Ghostty for its focused terminal every 0.5 s
  and after each click. Settings → *Bildirimler → Anında güncelleme (Erişilebilirlik)*
  (Notifications → Instant updates (Accessibility)) → **Allow Accessibility…** lets the app
  watch Ghostty's focus, window and title changes instead: the segment clears the moment you
  switch, and the 0.5 s check and the click monitor stop. The permission is used for nothing
  else; the app never asks for it on its own, and without it everything works as before.
- **You are here (Ghostty).** The segment of the chat whose Ghostty tab or split you are in
  grows 1.5 pt downward, and that bottom strip is white, joined to the bar as one piece, so you
  can tell which segment is the chat in front of you. The bar keeps its own color, so the sign
  is the same whether that chat is working, idle, waiting for you or failed; no state uses solid
  white, so it never reads as a status. It moves at once when you switch tabs and goes away
  when another app comes to the front. It uses the same
  focused-terminal check as "Seen when you look" (Automation for Ghostty; Accessibility makes it
  instant), which therefore runs whenever a Ghostty chat exists, not only while one is unseen or
  waiting. Terminal and iTerm2 tabs get no mark.
- **One segment per tab.** A Claude process that is stopped (Ctrl-Z, or the old process
  `/restart` leaves behind) or a spare that Claude Code's background daemon starts ahead of
  time is not a chat. A chat that daemon runs (after `/restart` in Claude Code 2.1.328) has its
  process on a hidden terminal; the notch links it to its Ghostty tab through the tab id the
  process inherits (`GHOSTTY_SURFACE_ID`), so its colors, mark, click and "seen" stay on its tab.
  With more than 10 chats, the line keeps the chat you are in, then the most urgent ones.
- **Terminal bell (optional).** Settings → *Bildirimler → Claude Code bildirim gönderince
  terminal zilini çal* (Notifications → Ring the terminal bell when Claude Code notifies;
  default off) rings that session's terminal bell on every Claude Code notification
  (permission, question, waiting for input): Ghostty puts 🔔 on the tab until you look at it,
  Terminal and iTerm2 mark the tab (and beep, unless their bell is set to visual). In silent
  mode only what needs an answer rings. Nothing rings while the app is not running. If Claude
  Code itself is set to ring the bell (`preferredNotifChannel`: `terminal_bell`), each
  notification rings twice.
- **The panel.** Hover the notch: every session with its status, the turn's elapsed time in
  dot-matrix digits, a rhythm strip of its tool calls, subagents, and context left. Each row
  leads with the chat's title (its terminal tab's title, known for Ghostty) and shows the
  project after it in grey; a chat without a title yet shows the project first. Click
  anywhere on a row to jump to its Ghostty / Terminal / iTerm2 tab, and the panel closes so
  the tab is in sight (a pinned panel stays open; a permission card, or a question you answer
  in the notch, keeps its clicks for its own buttons). If the tab cannot
  be reached (it was closed, or the terminal did not answer), the panel says so with the
  chat's title instead of only bringing the terminal app forward. The panel comes to the
  front each time it opens, so another app's window at the same level cannot cover it.
- **Pin and order the chats.** Hover a row and click the pin: the chat moves to the top of
  the panel and a small pin shows beside its title (click again to unpin). Press a row and
  drag it to put it anywhere among the others (pinned rows move among the pinned ones): the
  rows it passes make room, and it stays where you drop it. Without pins or drags the panel
  follows the terminal tabs as before; the status line under the notch always does, since
  its segments stand for the tabs. Pins and places survive `/clear`, `/resume` and a restart
  of the app; a chat is forgotten a day after it ended. A row with a permission card or a
  question answered in the notch is not dragged (its buttons keep their presses).
- **Every terminal.** The notch learns which app a chat runs in from the chat itself:
  TERM_PROGRAM, else the app's bundle id that macOS passes to everything started inside it
  (so iTerm2 behind tmux, Cursor, Alacritty, kitty and Claude's desktop app are known too),
  else the app found above the claude process. A click on a row selects the exact tab in
  Ghostty, iTerm2 and Terminal; any other app comes to the front, as does the terminal of a
  chat inside tmux (the pane is not selected). The first click into a terminal waits for
  macOS's "may ClaudeNotch control …?" answer before it selects the tab.
- **Plan usage for everyone.** Claude Code reports the 5-hour and weekly limits only to its
  status line, so *Connect* (Settings → General, or the installer) makes the notch's small
  bridge the status line command: it hands the numbers to the notch and then runs the
  status line you had, unchanged (none: it prints nothing). Remove puts your old one back.
- **Hide a chat.** Hover a row and click the crossed-out eye: the chat leaves the panel and the
  status line, and its terminal and process stay as they are. It comes back by itself when it
  does something new: you type in it, a turn ends or fails, or it needs you (a permission
  request, a question, a plan approval). Claude Code's "waiting for your input" notice a minute
  after a turn does not bring it back. A chat with a permission request, a question, a plan approval or an unread error cannot be hidden; one only waiting for its next prompt can. Under the rows,
  **Hidden** lists the hidden chats by title: click one to show it again, or **Show all**.
- **Small tools, all optional:** Pomodoro / focus timer (it grows out of the notch while it
  runs), calendar reminders with a **Join** button (macOS Calendar or Google Calendar directly),
  Spotify cover and controls, a clipboard shelf with pinning (one folded line in the panel:
  click it to see the copied items), weather, plan usage, battery,
  quiet hours and a silent mode.
- **Light on the machine.** Event-driven: no polling loops while idle, ~40 MB with the panel
  closed. Works on external displays too (a pill stands in for the notch).

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

## Do Not Disturb and other Focus modes

ClaudeNotch follows macOS's own Focus state by itself: it reads
`~/Library/DoNotDisturb/DB/Assertions.json` (every Focus that is on, Do Not Disturb or another,
by hand or by a schedule, is a record there) and watches it for changes. The rules for the
wings are two sentences:

- **Focus off:** everything (permission requests, questions, plan approvals, waits for input,
  finished runs, errors, module notes) shows its text for 4 s, or its mark at once with *Show
  only a small mark*; afterwards only what blocks Claude (permission, question, plan, waiting)
  keeps a mark, until you handle it.
- **Focus on:** only what blocks Claude shows (in either question mode), and only as the small
  mark, never the 4 s text; it stays until you handle it. Finished runs, errors and module
  notes show nothing beside the notch; the status line still shows them.

Sounds follow the same rule: under a Focus only what blocks Claude plays its sound (permission
requests, questions, plan approvals, waits for input); finished runs, errors and the module
chimes (timer, calendar reminder) are silent.

Settings → *Bildirimler → Odağı açık say* (Notifications → Treat Focus as on; default off) is a
backup: Focus counts as on when macOS or this switch says so. If the app cannot read that file
(missing, or blocked by privacy settings; the Notifications tab then says *macOS Odak durumu
okunamıyor* (Can't read the macOS Focus state)), two Shortcuts automations can switch it for you:

1. Shortcuts → Settings → Advanced: turn on **Allow Running Scripts**.
2. Automation → New Automation → **Focus** → Do Not Disturb → **When Turning On**, Run
   Immediately. Add the action **Run Shell Script** with:
   ```sh
   /usr/bin/defaults write com.eyyupcan.claudenotch focusActive -bool true; /usr/bin/notifyutil -p com.eyyupcan.claudenotch.focus
   ```
3. A second automation for **When Turning Off**, with `-bool false` in the same command.

The app reads the new value at once. Other Focus modes work the same way. With
`CLAUDE_NOTCH_DEBUG=1`, `/debug/state` shows what the app sees under `ui.focus` (`file`: on /
off / unknown, `file_readable`, `file_error` (why it can't be read), `shortcuts`, `on`).

## Google Calendar (optional)

ClaudeNotch can read Google Calendar directly with **your own** OAuth client (read-only):
create a Google Cloud project, enable the Calendar API, add an OAuth consent screen and a
**Desktop app** client, download its JSON and pick it in Settings → *Modüller* → *Takvim* (Modules → Calendar). The
step-by-step guide is in the [Turkish README](../README.tr.md#google-takvim-doğrudan-bağlantı).
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

When a click on the notch seems to do nothing, the unified log says where it stopped: whether
the press reached the panel or went to another app, and how each jump to a terminal ended
(`terminal`, `directory`, `tab_missed` with the Apple Event error, ...). It holds no chat
names or paths.

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.eyyupcan.claudenotch"'
```
