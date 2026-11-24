# agy (Antigravity CLI) in the notch

Date: 2026-11-21. Status: steps 1-4 built and tested (the agy commits, up to the "guarded entry" fix);
step 5 (install) waits for the user's go; step 6 (the Allow/Deny card) is deferred (decision 18).

The notch shows Antigravity CLI (`agy`) chats and plan meters next to Claude Code's, and answers
the few agy permission prompts it can answer through agy's official hook reply. Facts come from
agy 1.5.14 on this Mac, measured by this session and by the antigravity-agenting session (which
owns agy-bridge, `~/.gemini/config/agy-bridge/`). Unmeasured points are listed at the end. Build
them as facts only after measuring.

Build/test: `swift build && swift test` (one heavy job at a time, per memguard). Core logic lives
in `Sources/ClaudeNotchCore` (pure, tested); UI in `Sources/ClaudeNotch`.

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Scope | agy chat rows, agy plan meters, and answering agy permissions from the notch |
| 2 | Audience | The user's Mac first. Read agy-bridge's files; the agy part stays off when they are missing. No README or `install.sh` change yet |
| 3 | Meter direction | % **used**, like Claude (`meters.json` stores % left: show `100 - x`) |
| 4 | Row details | Model + effort and context % from agy-bridge's per-process status-line snapshot; a "context low" note like Claude's. (Cost was chosen too, but agy's status line carries no cost field, measured 2026-11-21) |
| 5 | Hook owner | The notch: its own script in this repo, its own `claude-notch-*` key in `~/.gemini/config/hooks.json` |
| 6 | Meter warnings | Same rules as Claude: 80% and 95% per 5-hour window, with the pool named; weekly notes follow the existing weekly setting |
| 7 | "Needs you" signal | Read agy's own CLI log (exact; re-check after agy updates) |
| 8 | Helper (workflow) chats | Folded into the row of the chat that started them, like Claude's subagents |
| 9 | `agy -p` runs | Ignored: only agy chats in a terminal tab become rows |
| 10 | Old meter reading | After 15 min: greyed, with its age (`2 h ago`); no warnings from an old reading |
| 11 | Layout | One list: agy rows mixed with Claude rows, with a small `agy` mark; one `agy NN%` ring in the band (the fullest agy window), all five windows in its tooltip |
| 12 | Answer channel | agy's official PreToolUse reply only. Never keystrokes into a tab |
| 13 | Install | Yes, once built and tested: back up `hooks.json`, add only the notch's key, show the antigravity-agenting session the exact entry first |
| 15 | Which calls the notch holds | Only kinds agy always asks about: file writes outside the workspace, commands that ask to leave the sandbox. Auto mode decides the rest. On this Mac the sandbox is off (`sandbox.enabled: false` in the status line), so in practice only outside-workspace writes |
| 16 | Hold time | If the chat's agy tab is in front, step aside at once (agy asks in its terminal). Otherwise hold 60 s, then step aside |
| 17 | Workflows (`RunWorkflow`) | Not hooked by the notch: the agenting plugin's guard answers them (auto mode: `auto_approve` for routed workflows; manual: `force_ask`) |
| 18 | Allow/Deny card for agy | **Deferred.** After 15 and 17 it would cover only outside-workspace writes, which never prompted. Build it (the hold entry, step 6) only when agy's log shows such a prompt; until then every agy prompt is amber + jump |
| 19 | Shared understanding | Confirmed by the user on 2026-11-21: build steps 1-5 |

Handed to the antigravity-agenting session at the user's request: how often agy asks at all
("agy should behave almost the same as Claude Code; prompts shouldn't bother me much in the
first place"). On 2026-11-21 there is no rule list on either side (Claude Code `defaultMode:
auto`, no allow/ask/deny; agy runs its default Auto mode), and since 2026-11-19 agy prompted only
twice, both `RunWorkflow`.

Mocks the user chose from (offline, in the session scratchpad, not kept): the panel layouts and
old-meter states (decisions 10, 11), and the hold-time timeline (decision 16).

## How it works

### Sources

| What | Where | Notes |
|---|---|---|
| Meters | `~/.gemini/config/agy-bridge/meters.json`: `{ts, meters: {gemini: {five_hour, weekly}, claude: {...}, argon: {weekly}}}` | % **left**. Refreshed only while an agy status line renders (at most every 5 min). Unknown pools are keyed by their full name |
| Per-chat status line | `~/.gemini/config/agy-bridge/statusline-<agyPid>.json` (agy-bridge e175655) | Raw agy status-line stdin, 0600, atomic, pruned after 24 h. Captured 2026-11-21 (agy 1.5.14): `conversation_id` (empty before the first turn), `model {id, display_name, effort}`, `context_window {used_percentage, remaining_percentage, context_window_size, ...}`, `quota {gemini-5h, gemini-weekly, 3p-5h, 3p-weekly, gemini-argon-wtu-weekly}` each with `remaining_fraction`, `reset_time`, `agent_state`, `cycle_mode`, `sandbox.enabled`, `version`. **No cost field.** It also carries the account email and plan tier: never log or show them |
| Events | Notch hook under `claude-notch-*` in `~/.gemini/config/hooks.json` | camelCase payload: conversationId, cwd, workspacePaths, modelName, transcriptPath, lastUserInput, hookEventName, stepIdx, toolCall {id, name, args} |
| Needs you | agy CLI log, one file per agy process: `~/.gemini/antigravity-cli/log/cli-<start>.log` | Lines below |
| agy version | `~/.gemini/config/agy-bridge/watch.json` `version` | Re-check the log lines when it changes |

Log lines (agy 1.5.14):

```
tool_confirmation_manager.go:237] Surfacing tool confirmation: "RunWorkflow" at step 36
input_loop.go:821] Responding to tool confirmation: convID=<id>, stepIdx=36, approved=true, ...
conversation_manager.go:1596] Surfacing ask_question at step 11
```

"Surfacing" has no conversation id. Match it by the log's process and the step (`stepIdx` from
the PreToolUse payload of the same chat). Each interactive agy keeps its own log open: `lsof -p
<agyPid>` lists `cli-<start>.log` (measured 2026-11-21 on two running agy chats).

### Hook rules (agy PreToolUse, measured)

- Printing **nothing** is neutral. `{}` or `{"decision":""}` **denies**. Bad JSON or a non-zero
  exit makes the tool **fail**. So: always exit 0, and print only an explicit decision.
- The user's Deny → `{"decision":"deny","reason":"Denied in the notch"}`. The user's Allow → `allow`
  or `auto_approve`, chosen by measurement 1b below (agy-bridge's bridge.py never passes `allow`
  on, because `allow` was measured to skip agy's own check). No answer, notch not running, any
  error → print nothing.
- Hooks run one after another, and PreToolUse runs **before** agy decides whether to prompt. So
  the notch cannot show its card side by side with agy's prompt, as it does for Claude.
- Default hook timeout is 30 s; 150 s is accepted. What a timed-out PreToolUse does is unknown,
  so treat it as fail-closed: the script stops waiting at 60 s, well under its own timeout.

### Identity

Like the Claude hook: walk up from the hook to the nearest `agy` ancestor with a real tty. That
gives the row its tty (jump to the tab) and its pid (process alive, status-line snapshot, log
file). No `agy` ancestor with a tty → the event is dropped. An `agy -p` started from a terminal
has a tty too, so also drop an ancestor whose argv has `-p`, `--print` or `--prompt`. Helper
conversations: link them to the parent through the shared agy pid when they share one; else
through the parent's `brain/<parentId>/.system_generated/tasks/task-<n>.log`, which names the
child.

## Measured since (2026-11-21, agy 1.5.14)

- Real payloads, captured with a capture-only hook in a throwaway git dir (one `agy -p` turn):
  a turn's first PreInvocation carries `invocationNum: 0` (later ones 1, 2, ...); a normal Stop
  carries `fullyIdle: true`, `terminationReason: "NO_TOOL_CALL"` and an empty `error`; the
  file tools are `read_file` and `write_file` with the path in `Path` (and the whole file in
  `Content`). A fixture test (`AgyRealPayloadTests`) holds them, paths and ids replaced.
- The matcher `"*"` (and `".*"`, `""`) fires for every tool. A hooks.json without a hook-name
  key around its events fires nothing, silently.
- The hook returns in about 30 ms on the frequent events even when the app answers after 2 s
  (background send); SessionStart and Stop are sent in order and wait at most 1 s.
- The app side ran in a demo-mode copy of the new build: a real agy chat's event made an agy
  row with the status line's model, and the band showed Claude's ring and the agy ring side by
  side without crowding the chips.

## To measure before relying on it

1. **Deny vs allow from two hooks.** For example, agy-bridge-squash denies `git push` while the
   notch allows it. Test in a throwaway git dir with `.agents/hooks.json` (agy finds workspace
   hooks by walking up to the git root), in both orders. Until then, the notch steps aside
   (prints nothing) for any call another guard might deny: `git push`, commits, test-file writes.
1b. **`allow` vs `auto_approve`** on a call agy really prompts for: which one ends the prompt as
   the user's terminal "Yes" would, and whether either carries what that answer carries
   (`sandboxOverride` in the "Responding" log line). If neither lifts the sandbox, sandbox
   prompts cannot be answered from the notch at all (moot while the sandbox is off).
2. **What a PreToolUse timeout does** (runs, denied, or fails).
3. **How "writes outside the workspace" shows in the payload** (target path vs
   `workspacePaths`), and how "asks to leave the sandbox" does if the sandbox is ever on (a
   `BypassSandbox` arg on `run_command`, as an agy error message suggests?).
4. **Whether helper conversations share the parent's agy process.**
5. ~~The real status-line payload~~: captured, see Sources.
6. **Whether model-free `agy -p /usage` fires hooks** (dropped anyway: no tty, or `-p` in argv).

Also: the app speaks English and Turkish. Add every new string through `Localization.swift`
and its tests.

## Build order

Each step is committed when its tests pass; there is no stop between steps.

The hook is two `hooks.json` entries, so that most of the feature goes live without waiting on
the riskiest part:

- **events** (`claude-notch-events`): fire-and-forget on every event, prints nothing, short
  timeout. It cannot block or deny anything.
- **hold** (`claude-notch-hold`): PreToolUse with a `write_file|edit_file` matcher (plus
  `run_command` if the sandbox is ever on), the 60 s hold. Added later, and only if decided
  (see the closing round in the grill).

1. Core: agy meters model (`% used`, fullest window, age, warnings), with tests.
2. Events hook script + installer (dry run first), payload decoding in Core, rows with the `agy`
   mark, helpers folded, `agy -p` dropped.
3. Log watcher: amber for permission prompts and questions, cleared on "Responding".
4. Per-chat model, effort and context % from the per-pid snapshot.
5. Install the events entry: show it to antigravity-agenting, back up, add the key, tell the
   user with the undo command.
6. Hold entry: the held kinds, step-aside when the tab is in front, 60 s, the risky-command hold
   UI reused (after measurements 1, 1b, 2, 3), then its own install, shown and confirmed the same way.

agy's questions (`ask_question`) are amber + jump only. A PreToolUse reply can allow, deny or
rewrite args, but nothing measured lets a hook supply the user's answer.
