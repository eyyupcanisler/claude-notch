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
piece of work); the unsquashed history is in the local branch
`backup/pre-squash-2026-11-20`.

**How to undo the whole push:** `git revert --no-edit 3928505..main` (new commits that undo
it, safe), or, only if nobody has pulled yet, `git push --force-with-lease origin 3928505:main`.

**A:**

---

## ON13: The app running on your Mac

I did not stop your running notch (the safety checks blocked it, rightly: twice, once for
testing and once for the update). All UI tests ran in a *renamed copy* of the app
(`com.eyyupcan.claudenotch.uitest`) beside yours. **Your notch still runs the old build.**

**Tomorrow, in this order** (do it on your own Mac first: it is the installer's first real
run, before your friend gets the one-liner):

1. Update your notch. In the repo folder: `./install.sh --no-hooks --no-statusline`
   (rebuilds, quits the notch, replaces `~/Applications/ClaudeNotch.app`, starts it; your hooks
   and your own status line script stay as they are). The plain `scripts/install-app.sh` does
   the same with the build that is already there (signed with your "ClaudeNotch Dev"
   identity, so macOS keeps your permissions).
2. Click one Ghostty row (the jump code changed and only its tmux path ran live), then drag
   one row and pin one.
3. If anything is wrong, go back to the old app: `pkill -x ClaudeNotch; rm -rf
   ~/Applications/ClaudeNotch.app; ditto build.noindex/ClaudeNotch-previous.app
   ~/Applications/ClaudeNotch.app; open ~/Applications/ClaudeNotch.app` (I copied your
   installed app there before ending).

**A:**

---

## ON12: The first click asks for permission before jumping

**What:** when macOS has never been asked whether ClaudeNotch may control a terminal, the jump
now asks first and waits for your answer, then selects the tab.
**Why:** a real iTerm2 test showed the old way: the tab script started, macOS showed its prompt,
the 4-second timeout ran out, and the panel said "Its tab may be closed". Wrong message on a
new user's very first click.
**Revert:** `git revert 1889f9c`.

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
  records of that test id: `tccutil reset All com.eyyupcan.claudenotch.uitest`.
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

---

## Final status (20 Nov 2026, about 01:00)

**Review:** a five-angle review of the whole branch (terminal detection, the order model,
the drag UI, the install scripts, settings and docs), each followed by a skeptic that tried
to refute every finding: 19 findings, 15 real, all fixed in `472efb0` (tmux in Ghostty could
select an unrelated tab; the permission question came for jumps that run no script; an old
record could take a pin away on `/clear`; a drop moved the card-slot chat to the bottom; a
long pause of the app dropped pins of live chats; row places could go stale after a drop;
dragging over a question's option buttons could press them; paths with an apostrophe broke
under macOS's bash 3.2; stale button names in docs). 4 were refuted.

**Tests:** 451 unit tests pass (`swift test`). Real iTerm2 and Terminal chats were detected
correctly. The installer was run end to end in a scratch HOME, piped from curl and from a
checkout, with install, update and uninstall; after the push, the published one-liner
(script from raw.githubusercontent, source from GitHub's tarball) ran end to end the same way.

**Public file:** this file sits at the root of a public repo. It says what ran on your Mac
tonight (no secrets, names or personal paths). Move or delete it whenever you like.

**Not checked live (please try them, steps in ON13):**

- The last drag fix (rows measured outside their offset): the Mac locked itself around
  00:50, after which synthetic mouse events land on the lock screen, so I stopped. The drag
  was verified on screen before that change.
- The jump code after its last two changes (asking for permission right before a script,
  skipping the directory guess behind tmux): only the tmux path ran live (21 ms, no prompt).
  The Ghostty path you click all day did not run with this exact code.
- The installer's real-mode steps: tests skip quitting the app, making the signing
  identity, `loginWanted` (Open at login) and starting the app.
- A status line that had none before: the bridge prints nothing (tested), but nobody looked
  at a real Claude Code terminal to see that the bottom line looks unchanged.
- Ask 2 is a slice: detection and the choice of tab script work in all three terminals; the
  selection inside iTerm2 and Terminal needs the macOS permission, which only you can give.

**Pushed bites** on `furkanzt/claude-notch` `main` (oldest first, after `3928505`):

| Bite | What |
| --- | --- |
| `2ea38a4` | fix(terminals): tell which app a chat runs in without TERM_PROGRAM or a tty |
| `8d9459f` | feat(usage): connect the status line for everyone |
| `54674f1` | feat(panel): pin chats and drag rows (+ the 1:1 drag fix) |
| `e9be6a1` | feat(install): one-command install, short README (+ piped-run and uninstall fixes) |
| `c2f627c` | fix(panel): a drag whose row leaves the list is called off |
| `1889f9c` | fix(jump): the first click waits for the macOS permission answer |
| `d0a1b26` | docs: this file |
| `472efb0` | fix(review): everything the review found |
| (this commit) | docs: this final status |

