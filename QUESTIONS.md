# Questions from the 19-20 Nov 2026 unattended session

You asked for three things (from your friend's screenshots) and said I could act on my own
and grill you later. This file has my judgment calls (ON entries: what I decided, why, how to
undo it) and, at the end, the questions to grill you on. Each ON entry ends with a blank
**A:** line for your answer.

---

## ON0: Summary (read this first)

**Done, tested, committed:**

1. **Pin and drag in the panel** (ask 1). Hover a row → pin button (the row goes to the top,
   a small pin shows beside its title). Press a row and drag it → it moves among the others.
   Pins and places survive `/clear`, `/resume` and an app restart. Unit tests + checked on
   screen with real mouse events in a test copy of the app.
2. **"Can't tell which terminal"** (ask 2). The terminal table was never the problem: iTerm2
   and Terminal were supported. Your friend's chats reached the app with *no identity at all*
   (no tty, no TERM_PROGRAM). The rows show this: a tag like `all · db2247` only appears when a
   chat has no tty. Now the hook also sends the app's bundle id (macOS gives it to every
   process), accepts every shell, and trusts Claude Code's own `CLAUDE_PID`. Proven in a
   **real** iTerm2 and a **real** Terminal: both arrive with the right terminal, tty and pid.
   I also fixed the first click into a new terminal (it used to say "tab may be closed"
   while macOS was still asking for permission).
3. **One-command install + short README** (ask 3). `curl … | bash` builds, installs, connects
   hooks **and the status line** (so plan usage works for everyone, also people with no status
   line), turns on Open at login and starts the app. `--uninstall` puts everything back. The
   README is short now; the long text moved to `docs/FEATURES.md`.

**Not done (honest list):**

- iTerm2 / Terminal still have no tab titles, "seen when you look", "you are here" or tab
  order (Ghostty only). The README says "not yet". See Q1.
- The jump *inside* iTerm2 (selecting the exact tab) is not verified live: it needs a macOS
  permission that is yours to grant. Detection and the choice of iTerm2's script are verified.
- Why your friend's chats had no identity is **not confirmed**. See ON1.
- No GitHub release (see ON9). The installer builds from source until there is one.

**Your live app:** see ON13 (whether I updated `~/Applications/ClaudeNotch.app`).
**Push:** see ON14.

**A:**

---

## ON14: Push

Pushed to `origin` (`furkanzt/claude-notch`) only, never `upstream`, no force: see the
final status at the bottom of this file. Commits were squashed into bites first (one per
piece of work), with a backup branch.

**How to revert:** `git push origin <backup-branch>:main --force-with-lease` brings `main`
back (the backup branch name is in the final status).

**A:**

---

## ON13: The app running on your Mac

I did not stop your running notch during testing (the safety checks blocked it, rightly). All UI
tests ran in a *renamed copy* of the app (`com.eyyupcan.claudenotch.uitest`) beside yours.
The final status at the bottom says whether I swapped in the new build.

**To update it yourself:** `./install.sh` in the repo (it builds this checkout, keeps your
hooks, leaves your own status line script alone because it already feeds the notch, and
restarts the app).

**A:**

---

## ON12: The first click asks for permission before jumping

**What:** when macOS has never been asked whether ClaudeNotch may control a terminal, the jump
now asks first and waits for your answer, then selects the tab.
**Why:** a real iTerm2 test showed the old way: the tab script started, macOS showed its prompt,
the 4-second timeout ran out, and the panel said "Its tab may be closed". Wrong message on a
new user's very first click.
**Revert:** `git revert 4b629e8` (hash before squashing; search the log for "fix(jump)").

**A:**

---

## ON11: iTerm2 / Terminal parity is not built

**What:** only detection + jump were fixed. Tab titles, "seen when you look", "you are here"
and tab order stay Ghostty-only.
**Why:** that code is tuned for Ghostty, your daily terminal; changing it unattended risked
breaking what you use every day, and testing it needs a macOS permission only you can grant.
Titles matter most for your friend (three rows called "all" are hard to tell apart; until
then they show the terminal's short name, like `all · s003`).
**Plan if you say yes:** iTerm2 gives `tty` and `name` for every session (raw Apple Events,
like Ghostty's); Terminal gives `tty` and `custom title` per tab. One merged title map for
all terminals (otherwise one terminal's update would erase the other's titles).

**A:**

---

## ON10: README links and the Turkish README

**What:** every link now points at `furkanzt/claude-notch` (your fork). Before, clone and
download links went to `eyyupcanisler/claude-notch`, whose release (1.0.2) lacks all of this
fork's work. `README.tr.md` got the same one-line install section, **in Turkish**.
**Why Turkish there:** the file exists to be the Turkish translation; an English section in it
would read oddly. This is an exception to your "docs are English" rule, so I flag it.
**Revert:** edit the two links back, or ask me.

**A:**

---

## ON9: No GitHub release was made

**What:** the fork has no releases, so the one-liner builds from source (1-3 minutes, needs
Apple's Command Line Tools; the installer opens their install window if they are missing).
**Why I did not make one:** publishing a binary goes past "push"; it is a deploy.
**When you want one:** `scripts/make-release.sh 1.1.0` (needs a clean tree; it tags, builds,
zips and runs `gh release create`). The installer picks the release up automatically from
then on (download instead of build, no Command Line Tools needed). Check first that
`gh repo set-default furkanzt/claude-notch` is set, so the release lands on the fork.

**A:**

---

## ON8: What the installer does without asking

- Installs to `~/Applications` (no admin password), or replaces the copy where an earlier
  install put it (`/Applications` too).
- Changes `~/.claude/settings.json` (hooks + status line) after a backup, without a yes/no
  question: running the command is the yes. `--no-hooks` / `--no-statusline` skip each part.
- Turns on **Open at login** (`--no-login` skips it).
- Builds with your own local signing identity (`ClaudeNotch Dev`, its own keychain, no
  password prompt), so macOS keeps the permissions across updates.

**A:**

---

## ON7: One "Connect" button for hooks and status line

**What:** Settings → General → *Claude Code connection*: **Connect** sets up both; **Remove**
removes both and puts your old status line back. A second row shows the status line state,
with its own Connect button. The Modules tab's usage note offers Connect too.

**A:**

---

## ON6: How plan usage reaches the notch now

**Concept:** Claude Code tells the 5-hour and weekly limits only to the *status line command*
(the program that draws the line under the prompt). The notch needs a copy.

**Before:** a script added one line to *your own* status line script. It only worked if you
had a script with a line written exactly `input=$(cat)`. Your friend had no status line, so
he got nothing. (Your own script writes `INPUT=$(cat)`, so it would have failed too; you
have a hand-written ClaudeNotch line instead.)

**Now:** the status line command becomes the notch's small bridge. The bridge copies the
input for the notch, then runs **the status line you had, unchanged**, and prints its output.
With no status line before, it prints nothing, so the terminal looks the same. Your previous
command is saved in `~/Library/Application Support/ClaudeNotch/` and `--uninstall` / Remove
puts it back exactly. A status line that already copies to the notch (like yours) is left
alone.

**Example:** your friend had no status line → after install, `statusLine.command` is the
bridge, and the panel shows his limits after his next message.

**A:**

---

## ON5: Drag on the whole row, no auto-scroll

**What:** press anywhere on a row and move 6 points to drag; a click without movement still
jumps to the terminal. No drag handle. A long list does not scroll by itself while dragging.
**Why:** a handle is one more icon on a busy row; the whole row is how macOS lists work
(Finder sidebar, Reminders). Auto-scroll is extra work for lists that rarely scroll.

**A:**

---

## ON4: Drag stays inside its group; new pins go to the bottom of the pins

**What:** pinned rows move among pinned rows, others among others. To move a row between
groups you use the pin button. A newly pinned chat goes *below* the chats already pinned.
**Example:** pins A, B; you pin C → order A, B, C (not C, A, B).

**A:**

---

## ON3: How a pin remembers its chat

**What:** pins are saved by session id, with the chat's pid and terminal, in the app's
settings. They follow the chat through `/clear`, `/resume`, the hook session replacing the
process-scan placeholder, and an app restart. A chat is forgotten a day after it ended (a chat
still running after a long pause of the app keeps its pin); at most 100 are kept.
**Limit:** a chat with no tty (like your friend's) keeps its pin across an app restart (same
session id) but not across `/clear` (nothing ties the new id to the old one).

**A:**

---

## ON2: Pins and drags change the panel only, not the status line

**What:** the colored status line under the notch keeps the tab order. Only the panel list
follows your pins and drags.
**Why:** each segment stands for a tab, left to right, so you can find the tab. If pinning
moved segments, segment 1 would no longer be tab 1.
**Other option:** the line follows the panel order too.

**A:**

---

## ON1: Why did your friend's chats have no identity? (not confirmed)

**Facts:** in a real iTerm2 and a real Terminal, chats arrive fine with the old *and* new
bridge (the old one worked there too). So something in your friend's setup hid the chat's
process from the hook. Candidates, from most to least likely:

1. His chats ran outside a terminal (Claude's desktop app, VS Code / Cursor extension). Then
   there is no tab to jump to; the new code brings that app forward instead of the error.
2. His shell is fish (or another shell the old bridge did not walk through). Fixed now.
3. Something else wraps `claude` (an alias to `bun`, a launcher). The new `CLAUDE_PID` check
   covers that.

**To confirm:** after he updates (run the install command again), ask him to click one row,
then run this and send you the output (it has no chat names or paths, only ids and codes):

```sh
log show --last 10m --style compact --predicate 'subsystem == "com.eyyupcan.claudenotch"' | grep jump
```

**A:**

---

## Testing side effects on your Mac (all harmless, listed so nothing surprises you)

- A renamed test copy of the app ran beside yours: bundle id
  `com.eyyupcan.claudenotch.uitest`, from the session scratchpad (deleted with it). macOS asked
  it for Calendar access once; I clicked **Don't Allow** for that test id only. To clear the
  record: `tccutil reset Calendar com.eyyupcan.claudenotch.uitest`.
- It also asked to control iTerm2. The safety check stopped me from answering (permissions
  are yours), and the prompt went away when I closed the test copy. If it ever shows up
  again for "ClaudeNotchUITest", choose **Don't Allow**.
- The demo's own settings domain (`com.eyyupcan.claudenotch.demo`) got calendar off and
  language English. It is only used by demo recordings.
- I opened iTerm2 and Terminal to run real test chats, then quit both (neither was running
  before). iTerm2 offered an update: I chose **Remind Me Later**, nothing was installed.
- Test chats ran with `--setting-sources local`, so your own hooks did not fire for them.

---

## Grill questions (one decision each; my recommendation first)

1. **iTerm2 / Terminal parity** (ON11): build tab titles (and maybe "seen" and "you are here")
   for iTerm2 and Terminal next? *Recommended: titles first, they help your friend most.*
2. **Status line order** (ON2): should pins and drags also reorder the status line under the
   notch? *Recommended: no, the line mirrors the tabs.*
3. **New pin position** (ON4): bottom of the pinned group, or top?
4. **Drag handle** (ON5): whole-row drag is fine, or do you want a visible grip?
5. **Release** (ON9): cut `1.1.0` on the fork now, so new users download instead of build?
6. **Open at login by default** (ON8): keep it on in the installer?
7. **Turkish README** (ON10): keep its install section Turkish, or make the whole repo's
   docs English?
8. **Your friend** (ON1): can you get the `log show … | grep jump` line from him?
9. **Upstream**: should any of this go back to `eyyupcanisler/claude-notch` as a pull request?
