# Grey "working", notch wings instead of drop-down islands

Date: 2026-11-17. Status: implemented, then changed after review (see "After review" at the
end, which overrides the plan where they differ).

The spec was agreed with the user. This plan adds no new decisions; open points are listed
at the end. Three parts:

1. **Colors.** Color only means "needs the user". Working is a neutral grey and done is a
   near-white. Needs (amber/yellow) and error (red/pink-red) keep their colors. This holds in
   both palettes.
2. **Wings.** No peek drops below the menu-bar band any more. The notch grows sideways at band
   height: long text for 4 s (style C), then a ~30 pt colored mark (style A). Some marks linger.
3. **Settings.** A "mark only" switch in two places, plus at most two mirrored settings.

Build/test: `swift build && swift test`. Core logic lives in `Sources/ClaudeNotchCore` (pure,
tested). The UI lives in `Sources/ClaudeNotch`.

---

## Part 1: grey working, near-white done

### Core (done: API + tests; values still to change)

`Sources/ClaudeNotchCore/StatusPalette.swift`

| Change | Detail |
|---|---|
| `classic` | `working: 0x8E8E8E`, `done: 0xE8E8E8`; needs `0xFFB020`, error `0xFF453A` unchanged |
| `colorblind` | `working: 0x8E8E8E`, `done: 0xE8E8E8`; needs `0xF0E442`, error `0xFB7185` unchanged |
| `lineOpacity(_:)` (new, stub) | `.done` must return **1** (today the bar rests at 0.7). At 0.7, `0xE8E8E8` sinks toward the working grey: about 1.3:1 instead of about 2.7:1 |
| `idleAlpha`, `onBlack`, `lineColor`, `chroma` (new, implemented) | Pure helpers that the tests use to compare what the status line actually shows over the black band |
| Doc comments | Update the "orange / cyan / green / blue" wording in `StatusColorScheme`, `StatusPalette`, `Colors`, and `LineState` (NotchLogic.swift) |

What the numbers give (over black): idle `0x383838` (white at 0.22) → working `0x8E8E8E`
(3.6:1) → done `0xE8E8E8` (2.7:1). Black text on working is 6.4:1, so the existing
`testBlackTextOnEveryStatusFillReachesSmallTextContrast` stays green.

### UI

| File | Where | Change |
|---|---|---|
| `Views.swift` | `StatusLineView.color(_:)` | Idle: `NSColor.white.withAlphaComponent(StatusPalette.idleAlpha)` (no magic 0.22) |
| `Views.swift` | `StatusLineView.style(_:_:arrived:)` | `seg.bar.opacity = Float(StatusPalette.lineOpacity(state))` instead of `state == .done ? 0.7 : 1`. Done's arrival flash keeps its shape but now rests at 1: bar keyframes `[0.55, 1, 1, 1]`, glow bloom unchanged `[0.4, 1, 1, 0.4]`. Working keeps the shimmer (a motion sign, not a color). Consider a lower glow for working (e.g. `seg.glow.opacity = 0.25`) so a grey halo does not read as a light |
| `NotchTheme.swift` | `make(_:)` | Nothing to change: `working` / `done` come from the palette. Update the doc comment ("orange / amber / green / red") |
| `ExpandedViews.swift` | l.89 "N working" `BandChip`, l.614 `statusColor`, l.840 `PulseDot`, l.843 done dot, l.367 "N done" chip | They pick up the greys via `theme.working` / `theme.done`; no code change. Check visually that the done dot at `opacity 0.45` (seen) is still distinct from idle |
| `ModuleViews.swift` | l.205 timer tint, l.249 / l.310 pomodoro focus/break, l.729 usage meter below 80 % | Same: greys via the theme, no code change |
| `PeekViews.swift` | `ModulePeekView.tint` `.timer` (working), `.battery` (done) | Same (the function moves with part 2, see below) |
| `SettingsWindow.swift` | caption under "Status colors" | Today: "Colorblind-friendly: colors that stay apart…". Add: "In both, only what needs you is colored; working is grey and done near-white." (en + tr) |

Tests (written): see "Tests" below.

---

## Part 2: wings instead of drop-down islands

### Behavior (from the spec)

- Every arrival (permission, attention = question / plan / waiting, finished = done / error,
  module note) gets **4 s** (`NotchWings.longDuration`):
  - Style C (default): wide wings. Left: colored mark + who/what. Right: one-line detail.
  - Mark-only setting on: style A from the first frame.
- After the 4 s, a mark **lingers** only when `WingPlanner.lingers(kind, focusActive:)` says so:

  | Kind | Focus off | Focus on |
  |---|---|---|
  | permission | until answered | until answered |
  | attention (question / plan / waiting) | until handled | no mark |
  | error | until seen | no mark |
  | done | no mark | no mark |
  | module | no mark | no mark |

  The existing filters stay in front of all this: `FocusIslands.shows` and
  `TerminalIslands.shows` (in `NotchController.islandShows`), and `silentMode` (in
  `handle(_:)`).
- **Newest wins:** each Claude arrival takes the 4 s phase, even over a permission. The earlier
  item stays as a mark. Module notes never replace a Claude item: they wait in one slot (the
  newest note wins), as today.
- **Several marks:** the most urgent kind is drawn (permission > attention > error > done >
  module). With more than one, the right wing shows the count instead of the glyph.
- **Click on the wings:** `WingDisplay.target`. When it has `asking == true` (terminal-only
  question), go to that session's terminal (`actions.focus(sid)`). Otherwise open the panel
  (`actions.expand(displayID)`). With several marks, `target == nil` and the panel opens.
- Hovering the notch still opens the panel (unchanged). The pointer over the wings during the
  4 s phase holds that phase (`WingPlanner.hold`).

### Core API (done: stubs + tests)

New file `Sources/ClaudeNotchCore/NotchWings.swift`:

```swift
public enum NotchWings {
  public static let defaultsKey = "wingsMarkOnly"     // UserDefaults Bool, app domain
  public static let fallback = false                  // fresh install: style C
  public static let longDuration: TimeInterval = 4
  public static func markOnly(stored: Any?) -> Bool
}

public enum WingMarkKind: String, Sendable, CaseIterable {
  case permission, attention, error, done, module
  public var urgency: Int                              // permission > attention > error > done > module
  public static func of(attention: String) -> WingMarkKind
}

public struct WingMark: Sendable, Equatable, Identifiable {
  public var kind: WingMarkKind
  public var sessionID: String?
  public var cardID: String?
  public var asking: Bool                              // terminal-only question: click -> terminal
  public var since: Date
  public var id: String                                // "<kind>:<cardID ?? sessionID>"
  public init(kind:sessionID:cardID:asking:since:)
}

public enum WingStyle: String, Sendable { case long, mark }

public struct WingDisplay: Sendable, Equatable {
  public var style: WingStyle
  public var item: PeekItem?                           // the item in its 4 s phase
  public var mark: WingMarkKind                        // item's kind, else most urgent mark
  public var count: Int                                // lingering marks
  public var target: WingMark?                         // click target; nil = open the panel
}

public struct WingPlanner: Sendable {
  public var markOnly: Bool
  public private(set) var focusActive: Bool
  public var questionMode: QuestionMode
  public private(set) var current: PeekItem?
  public private(set) var marks: [WingMark]
  public private(set) var pendingModule: ModuleNote?
  public init(markOnly: Bool = NotchWings.fallback, focusActive: Bool = FocusIslands.fallback)
  public static func lingers(_ kind: WingMarkKind, focusActive: Bool) -> Bool
  public mutating func setFocusActive(_ on: Bool)      // on: drops all non-permission marks
  @discardableResult public mutating func receive(attention: String, sessionID: String, cardID: String? = nil, at t: Date) -> Bool
  @discardableResult public mutating func receive(module note: ModuleNote, at t: Date) -> Bool
  public mutating func show(cardID: String, sessionID: String, at t: Date)
  public mutating func hold(at t: Date, seconds: TimeInterval = 1.5)
  @discardableResult public mutating func expire(at t: Date) -> Bool
  @discardableResult public mutating func prune(isOpen: (WingMark) -> Bool) -> Bool
  public mutating func clear()                         // ends the 4 s phase; marks stay
  public mutating func clearAll()                      // + pending module; marks stay (panel opened)
  public func display(at t: Date) -> WingDisplay?
  public var nextChange: Date?                         // end of the 4 s phase
}

public enum WingMetrics {
  public static let markWidth: CGFloat = 30            // style A, per side
  public static let maxLongWidth: CGFloat = 220        // style C cap, per side
  public static let minLongWidth: CGFloat = 96
  public static let padding: CGFloat = 12              // each end of a long wing
  public static let screenMargin: CGFloat = 8
  public static let bandlessHeight: CGFloat = 24       // screen without a visible menu bar
  public static func sideWidth(style: WingStyle, leftContent: CGFloat, rightContent: CGFloat, notchWidth: CGFloat, screenWidth: CGFloat) -> CGFloat
  public static func totalWidth(side: CGFloat, notchWidth: CGFloat) -> CGFloat
  public static func height(bandHeight: CGFloat) -> CGFloat
}

extension PendingPermission {
  public static let wingLimit = 28                     // mono 11 pt in 220 - 2 x 12 pt
  public var wingText: String                          // TextShortener.oneLine(..., limit: wingLimit)
  public var fitsWing: Bool                            // like fitsPeek, with wingLimit
}
```

Implementation notes for the builder. A reference implementation that passes all 310 tests
was written in a throwaway copy:
`/private/tmp/claude-501/-Users-fozates-Desktop-impark-pulled-projects-claude-notch/1fc1b752-bf34-4ff3-8db6-1f71473aa13b/scratchpad/proof/Sources/ClaudeNotchCore/NotchWings.swift`.
It lives in tmp, so it can disappear.

- `receive(attention:)`: add the mark first (only when it lingers; dedupe by `id`, newest
  `since`). Then either merge into the current finished item (done/error within
  `PeekPlanner.coalesceWindow`, restarting the 4 s) or replace `current` with a fresh item
  (`until = t + 4`, `asking = question && questionMode == .terminalOnly`).
- `display`: while `current.until > t`, return the style (`markOnly ? .mark : .long`), the
  item, the item's own mark kind (finished: `.error` when `errorIDs` is not empty, else
  `.done`), `count = marks.count`, and the item's own mark as `target`. After that, return the
  most urgent mark (newest within a kind), the count, and `target = marks.count == 1 ? marks[0]
  : nil`.
- `sideWidth`: the room beside the notch is `(screen - notch) / 2 - screenMargin`. Mark style is
  `min(markWidth, room)`. Long style is `min(room, clamp(max(left, right) + 2 * padding,
  minLongWidth, maxLongWidth))`. The two sides are symmetric (the `IslandShape` is symmetric).

### Wing geometry

- **Height:** `WingMetrics.height(bandHeight: g.bandHeight)`, i.e. the band. When a screen
  shows no menu bar (bandHeight 0), the height is 24 pt.
- **Long phase, per side:** the measured content plus 2 × 12 pt, kept between 96 and 220 pt.
  The shape is at most notch + 440 pt (MacBook 13"/14": about 185 + 440 = 625 pt). That fits
  `NotchMetrics.windowWidth` (660). On a 1280 pt wide screen it leaves about 320 pt of menu bar
  on each side, so Chrome's menus stay mostly clickable during the 4 s.
- **Text:** the left wing shows a 6 pt colored dot, then 12 pt semibold text, `lineLimit(1)`,
  `.truncationMode(.tail)`. The right wing shows 11 pt text, monospaced for a permission
  (`card.wingText`), `.truncationMode(.middle)`. The view measures both texts with the same
  fonts (`NSAttributedString.size()`; cache it per item id) to get `leftContent` /
  `rightContent`.
- **Mark phase:** 30 pt per side. Left: a 7 pt dot in the mark color. Right: an SF Symbol in the
  mark color: permission `shield.fill`, attention `questionmark`, error `exclamationmark`, done
  `checkmark`, module the module's tint dot. When `count > 1`, the right wing shows the count
  in bold rounded 11 pt in the mark color instead of the glyph.
- **Colors:** permission / attention use `theme.needs`, error `theme.error`, done `theme.done`
  (the new near-white), module `ModulePeekView.tint` (move that function into the wings view
  file).
- **Hold progress:** while `ui.keyHoldCardID == card.id`, draw `ui.holdProgress[id]` as a ring
  around the right wing's shield. The global hold then has visible feedback (the peek's
  AllowButton ring used to give it).
- **External displays (synthetic pill):** the same `.peek` geometry around the pill.
  `notchWidth = NotchGeometry.syntheticGap` (180).

### UI changes, file by file

**`NotchUIState.swift`**
- `NotchMode.peek` stays as the name; it now means "wings are out". Update the doc comment.
- `NotchUIState`: add `var wings: WingDisplay?` next to `peek`. Keep `peek: PeekItem?`
  (= `wings?.item`). `TerminalIslands.kind(of:)`, the debug JSON and `shownQuestion` still use
  it.
- `SurfaceState`: replace `peekWidth` with `wingSide: CGFloat = WingMetrics.markWidth`. Drop
  `bodyHeight[.peek]`, since a peek has no body any more.
- `NotchMetrics.island(.peek, ...)`: return
  `IslandGeometry(topWidth: notch + 2 * side, bodyWidth: notch + 2 * side, height:
  WingMetrics.height(bandHeight: g.bandHeight), shoulder: 0, bottomRadius: min(10, h / 2))`.
  With `bodyWidth == topWidth` and `height == band`, `IslandShape` draws no flare (a plain band
  with rounded bottom corners).
- Remove `finishedWidth`, `moduleWidth`, `permissionMinWidth`, `permissionWidth`,
  `peekPadding` once nothing in the UI uses them. Keep the Core
  `PendingPermission.peekLimit` / `peekText` / `fitsPeek` for now: ReviewFixTests and V4Tests
  cover them (see open point 4).

**`NotchSurface.swift`, `hitRects`**
- `.peek` returns the wings rect: `NSRect(x: cx - total/2, y: top - h, width: total, height: h)`,
  plus the collapsed line zone under the notch (`NotchMetrics.collapsedDepth`, notch width
  only) so the status line still hovers / clicks. Nothing else lies below the band. The
  existing `pointerAtAppear` click-through stays, so a click aimed at a menu item that a wing
  just covered is not eaten.

**`Views.swift`, `NotchRootView`**
- `bandRow` for `.peek`: `WingsView(display: ui.wings, ...)` (new, see below), framed to
  `island.topWidth × height`.
- `bodyContent` for `.peek`: `Color.clear.frame(height: 0)` (no `PeekBody`).
- Status line and timer pill: they show in `.peek` as well as in `.collapsed` (today they are
  collapsed-only). Marks can linger for a long time, and hiding the session state that long is
  wrong. The Spotify ears give way to the wings (they share the space): no ears in `.peek`.
- The collapsed click zone (`Color.clear … onTapGesture expand`) also covers `.peek`, for the
  notch part.
- `DecisionSource`: remove `.peek`, `.peekHold` and `fromPeek`. `isHold` becomes
  `self == .hold || self == .globalHold`.

**New `Sources/ClaudeNotch/WingViews.swift`** (replaces `PeekBody`)
- `WingsView(display:store:ui:theme:actions:displayID:)` holds the left wing, a clear gap of
  the notch width, and the right wing, at band height. Tapping anywhere goes to
  `actions.wingTap(displayID)`.
- Text per item (all `loc`, en + tr):

  | Item | Left wing | Right wing |
  |---|---|---|
  | permission, Bash | "%@ wants to run" (project) | `card.wingText` (mono) |
  | permission, other tool | "%@ wants to use %@" (project, tool) | `card.wingText` |
  | question (held or terminal-only) | "%@ asks:" | first question text, `TextShortener.oneLine(…, limit: 60)` |
  | plan | "%@ has a plan to approve" | `session.status.detail` |
  | waiting | "%@ is waiting for you" | `session.status.detail ?? loc("Claude is waiting for a reply")` |
  | done, single | "%@ finished" | status detail (summary) |
  | done/error, several | `PeekPlanner.finishedTitle(names:errors:)` | none |
  | error, single | "%@ stopped with an error" | status detail |
  | module | `note.title` | `note.subtitle` or `digits + unit` |

- Accessibility: one element whose label is the left text + right text (long phase), or the
  mark's name + count ("Permission request", "2 waiting"…). Add `.isButton`.
- Delete from `PeekViews.swift`: `PeekBody` (permission card, `QuestionAnswerView` in the peek,
  asking view, finished line). Keep `ModulePeekView.tint` (move it) and `BatteryGlyph` if
  something else still uses it (grep). `CountdownRing(compact:)` and `ActionButton(compact:)`
  may lose their only compact caller: check, and leave the parameter in place if unsure.

**`NotchController.swift`**
- `private var planner = PeekPlanner()` becomes `private var wings = WingPlanner()`. `init`
  sets `wings.markOnly = settings.wingsMarkOnly`, `wings.setFocusActive(settings.focusActive)`
  and `wings.questionMode = settings.questionMode`. The `planner.permissionHold` lines go.
- `refresh()`:
  - Replace `planner.dropAnswered` and the stale-card check with
    `wings.prune { isOpen($0) }`. If `wings.current` is a permission whose card is gone, call
    `wings.clear()`.
  - `isOpen(mark)`:
    - permission: `store.card(id:) != nil`.
    - attention: `store.question(for: sid) != nil` or the status kind is in
      `["question", "plan", "waiting"]` (and `TerminalIslands` / `FocusIslands` still show it,
      so switching to that terminal clears the mark; this replaces `dropHiddenIsland` for
      marks).
    - error: `session.unseen && session.status.kind == "error"`.
  - `if !debugFreeze { wings.expire(at: now) }`.
  - `ui.wings = wings.display(at: now)` and `ui.peek = ui.wings?.item`. The mode is `.peek`
    when `expandedID == nil && ui.wings != nil` on `peekSurfaceID`.
  - Width: `s.state.wingSide = WingMetrics.sideWidth(style:…)` from the measured contents
    (the view reports them through a new `actions.wingContent(displayID, left, right)`, the way
    `bodyHeight` is reported today). Animate the change with the wing motion (below).
- `schedulePeekExpiry()` uses `wings.nextChange`.
- `expand()`: `peekCard` is `wings.current` when it is a permission. `planner.clearAll()`
  becomes `wings.clearAll()` (marks stay).
- `updatePointer()` `.peek` case: `wings.hold(at:)` only while `ui.wings?.item != nil` (a
  lingering mark has no timer to hold). The notch dwell still expands.
- New `wingTap(displayID)`: `if let t = ui.wings?.target, t.asking, let sid = t.sessionID {
  focus(sid) } else { expand(displayID, reason: .click) }`.
- `handle(_:)`, `moduleNote(_:)`, `syncQuestionPeek()`, `answerQuestion`, `releaseQuestion`,
  `denyAll`, `applyQuestionMode`: replace `planner.` with `wings.`. In `syncQuestionPeek`, drop
  the `planner.hold(… peekDuration …)` for a held question, because the lingering attention
  mark replaces it.
- `trackPeekSettings()`: also observe `settings.wingsMarkOnly` (sets `wings.markOnly`) and
  `settings.focusActive` (calls `wings.setFocusActive`).
- Debug JSON (`/debug/state`): keep `"peek"` (from `ui.peek`) for `Tests/e2e/drive.py`. Add
  `"wings": {style, mark, count}`. `peek_until` becomes `wings.nextChange`.

### Decision paths: what changes

| Path | Today | After |
|---|---|---|
| `DecisionSource.peek` (peek Deny / Allow buttons) | `PeekBody.permission` | **Removed.** The wings have no buttons |
| `DecisionSource.peekHold` (hold-to-allow in the peek) | `AllowButton` when `source.fromPeek` | **Removed.** `AllowButton` (CardViews.swift l.491) always sends `.hold`; its `source` parameter can go once nothing passes `.peek` |
| `fromPeek` in `decide` / `finish` | `source.fromPeek \|\| (global && expandedID == nil)` | `source.isGlobal && expandedID == nil` ("inWings") |
| Allow gate while collapsed | `inPeek && !card.fitsPeek` opens the panel | `inWings && !card.fitsWing` opens the panel (the wing shows ~28 columns instead of 50) |
| `shownRequest()` while collapsed | permission peek in `.peek` mode, `fullyVisible: fitsPeek` | Only while `ui.wings?.style == .long` and `ui.wings?.item?.kind == .permission`: `ShownRequest(inPeek: true, fullyVisible: card.fitsWing)`. In the mark phase, nothing of the request is on screen, so it returns nil |
| ⌃⌥Y with only a mark showing | n/a | `GlobalShortcutPolicy` → `.reveal(oldest)` → `showPeek` → `wings.show(cardID:…)` brings the long text back for 4 s. The next press then allows (if it fits and is not risky), starts the hold (risky), or opens the panel (does not fit) |
| ⌃⌥Y with mark-only on | n/a | `reveal` would only bring back a mark (still nothing to read). In `reveal`, when `wings.markOnly`, call `openFull(id)` instead of `showPeek`: the panel opens unfocused with the request, and the next press decides there |
| Global hold (risky) | `startKeyHold` → `decide(.globalHold)`; cancelled when `shownRequest()?.cardID` changes | Unchanged. The long phase must not end mid-hold: `startKeyHold` calls `wings.hold(at: now, seconds: GlobalShortcutPolicy.holdDuration + 0.5)`. Progress ring on the right wing (see geometry) |
| ⌃⌥N | denies the shown request | Unchanged (long phase); in the mark phase it reveals first, as ⌃⌥Y does |
| ⌃⌥1…4 (held question options) | registered while a held question peek shows | `shownQuestion()` returns a question only when the panel is open: the options are not on screen in the wings. Clicking the wing opens the panel, where ⌃⌥1…4 work as today |
| Next card after a decision | `scheduleNextPeek` after a peek / shortcut decision | Unchanged: it now calls `wings.show`, so the next request gets its 4 s of text |

### Motion (wings grow / shrink)

**The builder loads the `taste-detector:agents-with-taste` skill (Skill tool) before writing
this animation** (spec requirement). Starting point, to be checked against the skill:

- Grow (collapsed → long, or collapsed → mark): `Motion.peek` (spring 0.34 / 0.86) on
  `wingSide` and the shape. Text fades in after `Motion.contentDelay` (0.06 s).
- Long → mark: text out with `Motion.contentOut` (0.12 s), then the width shrinks with
  `Motion.retract` (no overshoot), and the glyph fades in at about 60 %.
- Mark → collapsed: `Motion.retract`.
- Reduce Motion (`Motion.reduce`): `Motion.crossfade` only, no width spring (the same rule as
  `Motion.shape`).
- Respect `Motion.shape(from:to:)` for mode changes. A width change inside `.peek` is a new
  `withAnimation` in `refresh()`, like today's `peekWidth` resize.

---

## Part 3: settings

### Storage
`NotchSettings.swift`: `var wingsMarkOnly: Bool { didSet { defaults.set(wingsMarkOnly, forKey:
NotchWings.defaultsKey) } }`, init
`NotchWings.markOnly(stored: defaults.object(forKey: NotchWings.defaultsKey))`. Also set it in
the debug `/debug/settings` handler (next to `peek_duration`), so e2e can switch it.

### The switch in two places, one binding (`$settings.wingsMarkOnly`)
- **General > Appearance**, right after the "Status colors" picker and its caption.
- **Notifications > Notification**, right after the "Focus is on…" toggle and its caption.
  Note: the brief said "General next to the question mode / Focus options", but those options
  are in the **Notifications** tab (SettingsWindow.swift around l.276–290). The switch goes
  where they actually are.

Label (en/tr): "Show only a small mark beside the notch" / "Çentiğin yanında yalnızca küçük bir
işaret göster". Caption: "Off: for 4 s the notch grows sideways with a short text, then shrinks
to a small colored mark. On: only the mark. Nothing ever drops down over the page." / "Kapalı:
çentik 4 sn boyunca yana doğru büyür ve kısa bir metin gösterir, sonra küçük renkli bir işarete
döner. Açık: yalnızca işaret. Sayfanın üzerine hiçbir şey açılmaz."

### Mirrors (at most 2, both justified)
(After review: only the Status colors mirror stayed. Silent mode ended up twice in the same
Notifications tab, which is clutter, not findability, so the copy was removed.)
1. **Silent mode** ("Silent mode: only permission requests and questions"), today only under
   Notifications > Notification sounds. Mirror it into Notifications > Notification next to
   Focus. It decides which islands/wings appear at all, not only sounds, and users looking for
   "why did no wing show" look in that section.
2. **Status colors** picker, today only under General > Appearance. Mirror it into
   Notifications > Notification next to the new mark-only switch. In mark style, color and
   glyph are the only signal, so the colorblind choice belongs where the marks are configured.

### Caption texts that mention "drop down" (en + tr), to reword
- "Focus is on…" caption: "…permission requests still drop down." becomes "…permission
  requests still show beside the notch."
- "Answer Claude's questions in the notch" captions: "Claude waits while a question is in the
  island: pick its options there (or with ⌃⌥1…4)…" becomes "…click the notch to open the
  panel and pick its options there (or with ⌃⌥1…4)…". The terminal-only caption: "no island
  drops down" becomes "no wing shows".
- "Hide islands while their terminal is in front" caption: "drop no island" becomes "show no
  wing".
- "Silent mode" caption, "Quiet hours" caption ("islands still drop"), and the Modules footer
  ("Module islands never get ahead…"): reword "drop"/"island" accordingly.
- "Keep permission requests visible" picker: see open point 1.

Every new or changed string needs an entry in both `Resources/Localization/en.lproj/Localizable.strings`
and `tr.lproj/Localizable.strings` (`LocalizationTests` checks parity and format specifiers).
Turkish domain word for the wings: "kanat"; for the mark: "işaret".

---

## Tests

### Written, failing now (35)
`Tests/ClaudeNotchCoreTests/NotchWingsTests.swift` (new):
- `NotchWingsTests`: `testMarkOnlySettingDefaultsOffAndReadsStoredBool`,
  `testLongPhaseLastsFourSecondsThenMark`, `testMarkOnlySkipsTheLongText`,
  `testMarkOnlyDoneShowsItsMarkForFourSecondsThenNothing`,
  `testPermissionMarkLingersUntilAnswered`, `testQuestionPlanAndWaitingMarksLingerUntilHandled`,
  `testTerminalOnlyQuestionMarkTargetsItsTerminal`, `testErrorMarkLingersUntilSeen`,
  `testDoneAndModuleNotesLeaveNoMark`, `testLingeringRulesByKindAndFocus`,
  `testFocusOnOnlyPermissionLingers`, `testTurningFocusOnDropsNonBlockingMarks`,
  `testNewestArrivalTakesTheLongPhase`, `testSeveralLingeringMarksShowACountAndTheMostUrgent`,
  `testMarkUrgencyOrder`, `testAttentionKindsMapToMarks`, `testSingleLingeringMarkIsTheClickTarget`,
  `testRepeatedAttentionForTheSameSessionKeepsOneMark`,
  `testFinishedArrivalsWithinTheCoalesceWindowMerge`,
  `testModuleNoteWaitsBehindAClaudeItemThenShows`, `testClaudeArrivalReplacesAModuleNoteAtOnce`,
  `testOpeningThePanelKeepsLingeringMarks`, `testClearEndsTheLongPhaseOnly`,
  `testHoverHoldExtendsTheLongPhase`, `testShowBringsBackThePermissionText`,
  `testMarkWingIsThirtyPointsPerSide`, `testLongWingFitsTheWiderContentWithinItsBounds`,
  `testLongWingsShrinkOnANarrowScreen`, `testWingsKeepTheBandHeight`
- `WingFitTests` (`@MainActor`): `testFitsWingOnlyWhenTheWholeCommandFitsTheWing`

`Tests/ClaudeNotchCoreTests/StatusPaletteTests.swift` (changed):
- Renamed and rewritten: `testClassicPaletteGreysWorkingAndDoneKeepsNeedsAndError` (was
  `testClassicPaletteHoldsTheOriginalColors`), `testColorblindPaletteGreysWorkingAndDoneKeepsNeedsAndError`
  (was `testColorblindPaletteHoldsItsColors`).
- New, failing: `testWorkingAndDoneHaveNoHueInBothPalettes`,
  `testWorkingGreyIsBrighterThanIdleAndDarkerThanDone`, `testDoneSegmentIsDrawnOpaque`.

### Written, passing now (regression guards)
- `testOnlyNeedsAndErrorCarryColor`, `testOnBlackCompositesPerChannel` (helpers are
  implemented).
- `testLongWingsStayWithinNotchPlusTwoTimes220OnA1280Screen`: it passes against the stub only
  because the stub returns 0. It becomes meaningful once `sideWidth` is real.

### Existing tests that stay valid
`PeekPlanner` tests (NotchLogicTests, ModulesTests, QuestionTests, V4Tests) still test
`PeekPlanner`, which stays in Core. `fitsPeek` tests (ReviewFixTests, V4Tests) stay too. See
open point 4.

### Manual / e2e checks for the builder
- Chrome tab strip under the band stays clickable while wings are out, and with marks
  lingering.
- A risky Bash request (e.g. `rm -rf x`) with a short command: ⌃⌥Y (reveal) → ⌃⌥Y hold → it
  allows after 0.6 s, and the ring fills on the right wing.
- A long command: ⌃⌥Y opens the panel unfocused.
- Mark-only on: ⌃⌥Y opens the panel directly.
- External display: wings around the pill.
- Reduce Motion: a crossfade only.

---

## Open points (for the lead / user)

1. **"Keep permission requests visible" (`peekDuration`)** loses its meaning: the spec makes
   the permission mark stay until it is answered. Recommendation: remove the picker from
   Notifications. Keep the stored key and its last use, `scheduleShortcutPanelTimeout` (a panel
   a shortcut opened closes after that time).
2. **Held question under Focus.** The spec says only permission lingers under Focus. A question
   held in the notch (answer-in-notch mode) also blocks Claude, but per the spec it leaves no
   mark under Focus (the status line still breathes amber). Implemented and tested literally;
   flag it if the user meant "blocking" to include it.
3. **Newest wins over a permission.** A done arriving 1 s after a permission takes the long
   text. The permission stays as a mark, and ⌃⌥Y brings its text back. This follows the spec;
   the old island did the opposite (priority).
4. **Dead code after the switch.** `PeekPlanner` (with `permissionHold`, `dropAnswered`) and
   `PendingPermission.peekLimit/peekText/fitsPeek` will have no app callers. Recommendation:
   remove them in a separate follow-up commit with their tests, once the wings are verified.
   Don't delete them in the same change.
5. **Settings tab name.** The brief says "Settings > General" for the question/Focus options;
   they are in the Notifications tab. The plan uses the real location.

## After review

Three reviews of the first implementation led to these changes:

1. **Marks follow the store.** `WingPlanner.prune` is replaced by `sync(open:)`. On every
   `refresh` the controller builds the open marks from the store (one per pending card, plus
   `WingPlanner.openMark` per session: held or terminal question, plan, waiting, unseen
   error; silent mode keeps only questions). So a request that arrived while the panel was
   open, or before launch, gets its mark when the panel closes. A mark already there keeps its
   arrival time.
2. **Hidden, not dropped.** A mark whose island is hidden right now (its terminal in front,
   `WingPlanner.islandKind` + `islandShows`) stays in the planner and is filtered out by
   `display(at:visible:)`. It shows again once the user leaves that terminal, until handled.
   The 4 s text still goes for good when the terminal comes to the front.
3. **Count only after the phase.** `WingDisplay.badge` is the number drawn; it is 0 while an
   item is in its 4 s (that item draws its own glyph in its own color).
4. **Wing fit is measured.** `PendingPermission.wingLimit` comes from
   `WingMetrics.monoColumns(ring:)`: 28 columns, 25 for a risky request (the hold ring takes
   room). The controller also measures the line against the wing on the real screen
   (`WingText.showsWholeRight`) before the global allow shortcut may allow from the wings.
5. **No menu bar, no wings over content.** On a screen without a menu bar (`bandHeight == 0`)
   the wings show only an item's 4 s, as a mark, never the long text and never a lingering
   mark. A global shortcut there opens the panel instead of bringing back the text.
6. **Dead code removed.** `PeekPlanner` is now a namespace (`coalesceWindow`, `kind(for:)`,
   `finishedTitle`); its state machine and `PendingPermission.peekLimit/peekText/fitsPeek`
   are gone. Their tests were ported to `WingPlanner` / `fitsWing` or dropped where the
   behavior no longer exists (permission hold time, priority over newer arrivals).
7. **Strings.** The orphan keys of the deleted PeekViews.swift are gone. The two setting labels
   say "wings" instead of "islands", and the mark-only caption defines the word.
