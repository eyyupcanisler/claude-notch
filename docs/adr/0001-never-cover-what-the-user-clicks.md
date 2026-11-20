---
status: accepted (the status line part is proposed)
date: 2026-11-20
---

# Nothing the notch draws may cover something the user clicks

The notch app draws on top of every other app. Anything it puts outside the notch can sit on
top of a browser tab, a menu title or a window's title bar, and when it does, it takes the
click the user meant for that app. A notch that makes you miss your Chrome tab is worse than
no notch: people stop using it. So we decided: **nothing ClaudeNotch draws may cover, or catch
clicks on, something the front app shows the user to click**, unless the user asked for it
(they opened the panel, or chose a style that does it). When a feature cannot follow the rule,
it moves somewhere that can, or it waits.

## What we changed for it

1. **The running timer moved out from under the notch (commit 91539c1).** It used to grow the
   notch down by 22 pt with the time inside, right on top of a maximized Chrome's tab strip.
   It is now an "ear" beside the notch in the menu bar band, the same height as the notch, so
   nothing below the menu bar is covered. The old look stays as an opt-in style ("under the
   notch") in Settings > Modules.
2. **The Pomodoro round ("2/4") sits left of the notch, only when the menus leave room (this
   ADR's commit).** One ear on the right looked lopsided, so the round mirrors it on the left,
   at the same width. Left of the notch is where the front app's menus are, so the app reads
   how far the menu titles reach (Accessibility, re-read on every app switch). The ear shows
   only when the titles end at least 8 pt short of it. When the reach is unknown (no
   Accessibility access) it does not show. It also does not show while Spotify's cover has that
   side.
3. **Spotify's ears tuck into the notch while you work in an app (earlier).** The full ears
   (cover left, waveform right) show only on the desktop or in full screen; with an app in
   front only their edge peeks out of the notch, clear of its menus.
4. **Only what is drawn takes clicks.** The panel window is wide, but its hit test
   (`NotchSurface.hitRects`) is only the shapes on screen: the notch, the ears, the wings, the
   open panel. Never the empty menu bar beside them.

## Known exceptions (the rule does not hold yet)

- **The status line under the notch.** The 3 pt line hangs 2 pt below the notch, and its
  click zone reaches 10 pt below it. On this Mac (notch 32 pt, menu bar 33 pt) that is
  9 pt into whatever window sits under the menu bar, across the notch's width (about 185 pt):
  the top of a maximized Chrome's middle tabs. In a full-screen app the menu bar is gone and
  the line sits right on the app's first row. This exists only while Claude Code chats run.
- **The timer style "under the notch"** (opt-in) and **the timer on a screen without a menu
  bar** (an external screen in full screen) still grow the notch down over the app.
- **The wings in peek mode on a screen without a menu bar** hang from the top edge over the
  app.

## Proposal: the status line in full screen (not built)

When a full-screen app that is not the user's terminal is in front (Chrome in full screen, a
video, Xcode), the menu bar is hidden and the band beside the notch is plain black. The status
line would move up into that band: the same coloured segments, drawn as a short strip right of
the notch at the band's middle height, so it covers no pixel of the app. Clicking it opens the
panel as the line does now. With the terminal in full screen it stays under the notch as
today, because the terminal is where the user watches Claude anyway. Detecting "full screen and
not the terminal" reuses what exists: `DesktopWatch` already knows a full-screen window is in
front, and `TerminalHost.terminalOnly` knows the terminals.

Open points for that proposal:
- When the pointer touches the top edge in full screen, macOS slides the menu bar down over the
  band; the strip should hide while the menu bar shows.
- With the timer's ear on the right, the strip needs a side of its own (left, or between ear
  and notch).
- The same move could fix the windowed case above (the click zone over the tab strip), by
  shrinking the line's click zone to the menu bar band.

## Considered options

- **Hide the status line in full screen.** Simplest, covers nothing, but the user loses the
  at-a-glance state exactly when the terminal is out of sight. The wings still bring news.
  Kept as the fallback if the strip in the band does not read well.
- **Keep the timer under the notch but shorter.** Any height below the menu bar covers tabs;
  rejected.
- **Show the left ear whatever the menus.** Balanced every time, but it would sit on the last
  menu titles of apps with long menus; rejected by this rule.
