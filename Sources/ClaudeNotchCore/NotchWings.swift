import CoreGraphics
import Foundation

// Pure policy (no AppKit) for the notch "wings": an island no longer drops down under the
// notch. The notch grows sideways at band height instead: for the first 4 s the wings are wide
// and carry a short text (style "long"), then they shrink to a small colored mark (style
// "mark"). Only the marks of what blocks Claude (permission, question, plan, waiting) linger,
// until the user has handled them. Under a Focus only those show, and only as the mark.
//
// See docs/plans/2026-11-17-grey-working-and-notch-wings.md.

// MARK: - Setting

/// Settings > "Show only a small mark beside the notch" (General > Appearance and
/// Notifications > Notification, one stored value). Stored as a Bool under `defaultsKey` (app
/// domain); a fresh install (nothing saved) is off: the long text shows for 4 s first.
public enum NotchWings {
  /// UserDefaults key (app domain), a Bool.
  public static let defaultsKey = "wingsMarkOnly"
  /// What an install without a saved choice uses: off (long text first, then the mark).
  public static let fallback = false
  /// How long the wide wings with text stay before they shrink to the mark (every kind).
  public static let longDuration: TimeInterval = 4

  /// The stored Bool, or the fallback when nothing (or something that is not a Bool) is stored.
  public static func markOnly(stored: Any?) -> Bool {
    stored as? Bool ?? fallback
  }
}

// MARK: - Marks

/// What a mark stands for. Its color: permission / attention = needs, error = error, done =
/// done (light grey), module = the module's tint. Only permission and attention linger.
public enum WingMarkKind: String, Sendable, CaseIterable {
  /// A permission request (glyph: shield).
  case permission
  /// A question, a plan to approve or a wait for input (glyph: "?").
  case attention
  /// A turn that ended with an error (glyph: "!"). Never lingers (the status line keeps it).
  case error
  /// A finished turn (glyph: check). Never lingers.
  case done
  /// A module note. Never lingers.
  case module

  /// The mark drawn when several are on screen: the highest wins (permission > attention >
  /// error > done > module; only the first two linger).
  public var urgency: Int {
    switch self {
    case .permission: return 4
    case .attention: return 3
    case .error: return 2
    case .done: return 1
    case .module: return 0
    }
  }

  /// The mark kind of an attention effect ("permission", "question", "plan", "waiting", "done",
  /// "error"; anything else is attention).
  public static func of(attention: String) -> WingMarkKind {
    switch attention {
    case "permission": return .permission
    case "done": return .done
    case "error": return .error
    default: return .attention
    }
  }
}

/// One mark that stays after its long phase (a request still open).
public struct WingMark: Sendable, Equatable, Identifiable {
  public var kind: WingMarkKind
  /// The session it is about (nil for a module note).
  public var sessionID: String?
  /// The permission card it is about.
  public var cardID: String?
  /// Terminal-only question mode: a question Claude asks in the terminal. A click goes to that
  /// session's terminal tab instead of opening the panel.
  public var asking: Bool
  /// When it arrived (the newest of a kind is the click target).
  public var since: Date

  /// One mark per card (permission) or per session and kind.
  public var id: String { "\(kind.rawValue):\(cardID ?? sessionID ?? "")" }

  public init(
    kind: WingMarkKind, sessionID: String?, cardID: String? = nil, asking: Bool = false,
    since: Date
  ) {
    self.kind = kind
    self.sessionID = sessionID
    self.cardID = cardID
    self.asking = asking
    self.since = since
  }
}

/// How the wings are drawn right now.
public enum WingStyle: String, Sendable {
  /// Style "C": wide wings, left a colored mark plus who / what, right the detail (one line).
  case long
  /// Style "A": ~30 pt per side, left a colored dot, right a glyph (or a count).
  case mark
}

/// What the wings show at one moment.
public struct WingDisplay: Sendable, Equatable {
  public var style: WingStyle
  /// The item in its 4 s phase (its long text in style C, its own mark when mark-only is on);
  /// nil once only lingering marks remain.
  public var item: PeekItem?
  /// The mark drawn: the item's own kind while the item is up, else the most urgent lingering
  /// one.
  public var mark: WingMarkKind
  /// Lingering marks on screen (hidden ones, e.g. while their terminal is in front, not
  /// counted).
  public var count: Int
  /// The number the right wing draws instead of the mark's glyph: the count once only
  /// lingering marks remain and there are several; 0 (the glyph) otherwise, also while an item
  /// is in its 4 s phase (the count would take that item's color).
  public var badge: Int
  /// What a click acts on: the item's own mark while it is up, else the only lingering mark;
  /// nil with several (a click opens the panel). A target with `asking` goes to its terminal.
  public var target: WingMark?
  /// The chats the wings are about right now, whose segments the status line lights: the
  /// item's sessions while it is up (each one of a merged finished item), else the session of
  /// the mark drawn (with a count, the most urgent one only). Empty for a module note.
  public var sessionIDs: [String]

  public init(
    style: WingStyle, item: PeekItem?, mark: WingMarkKind, count: Int, badge: Int = 0,
    target: WingMark?, sessionIDs: [String] = []
  ) {
    self.style = style
    self.item = item
    self.mark = mark
    self.count = count
    self.badge = badge
    self.target = target
    self.sessionIDs = sessionIDs
  }
}

// MARK: - Planner

/// Decides what the wings show. Pure state machine driven by the store's attention effects and
/// module notes; replaces `PeekPlanner` in the app.
///
/// - Focus off: every arrival has a 4 s phase (`NotchWings.longDuration`): long text, or its
///   mark at once when `markOnly` is on. The newest Claude arrival takes that phase (a module
///   note never replaces a Claude item: it waits, newest note wins, and shows once the phase is
///   over). After the phase a mark lingers only for what blocks Claude (`lingers`: permission,
///   attention = question / plan / waiting) until it is handled; done, error and module notes
///   leave none.
/// - Focus on (`FocusIslands`): only what blocks Claude shows, and only as the mark (no long
///   text, whatever `markOnly` says); the mark stays until handled. Done, error and module
///   notes show nothing.
/// - Done / error arrivals within `PeekPlanner.coalesceWindow` merge into one item.
/// - `sync` makes the marks match what is still open in the store (`openMark` per session, one
///   per pending card): a mark goes when its reason is gone (card answered, question
///   answered, plan / waiting handled), and one is added for something that opened while the
///   panel was up. A mark that is open but should not show right now (its terminal in front,
///   see `TerminalIslands`) stays and is only hidden (`display(at:visible:)`).
public struct WingPlanner: Sendable {
  /// "Show only a small mark": no long text, the mark from the start.
  public var markOnly: Bool
  /// A Focus is on (`FocusIslands`): only what blocks Claude shows, and only as the mark.
  public private(set) var focusActive: Bool
  /// The user's question setting: a question in terminal-only mode is an `asking` item / mark.
  public var questionMode: QuestionMode = .fallback

  /// The item in its 4 s phase.
  public private(set) var current: PeekItem?
  /// Lingering marks, in arrival order (one per `WingMark.id`).
  public private(set) var marks: [WingMark] = []
  /// A module note that arrived while a Claude item was up: shown once that one is gone.
  public private(set) var pendingModule: ModuleNote?

  public init(markOnly: Bool = NotchWings.fallback, focusActive: Bool = FocusIslands.fallback) {
    self.markOnly = markOnly
    self.focusActive = focusActive
  }

  /// Whether a mark of `kind` stays after its 4 s phase: only what blocks Claude (a permission
  /// request; a question, plan or wait for input), with or without a Focus.
  public static func lingers(_ kind: WingMarkKind) -> Bool {
    kind == .permission || kind == .attention
  }

  /// The wings may carry their long text: neither "mark only" nor a Focus is on.
  public var showsText: Bool { !markOnly && !focusActive }

  /// A Focus started or ended. Turning it on ends an item that does not block Claude (done,
  /// error, module note) at once and drops a waiting module note; a blocking item keeps its
  /// phase, drawn as its mark. The lingering marks are all blocking ones and stay.
  public mutating func setFocusActive(_ on: Bool) {
    focusActive = on
    guard on else { return }
    pendingModule = nil
    if let cur = current, !Self.lingers(Self.markKind(of: cur)) { current = nil }
  }

  /// Keeps `mark` after its phase when its kind lingers (one per id, the newest arrival).
  private mutating func addMark(_ mark: WingMark) {
    guard Self.lingers(mark.kind) else { return }
    marks.removeAll { $0.id == mark.id }
    marks.append(mark)
  }

  private func phaseEnd(from t: Date) -> Date {
    t.addingTimeInterval(NotchWings.longDuration)
  }

  /// Feeds one attention effect ("permission", "question", "plan", "waiting", "done",
  /// "error"). The app filters with `FocusIslands` / `TerminalIslands` first; under a Focus a
  /// kind that does not block Claude is ignored here too. Returns true when the wings changed.
  @discardableResult
  public mutating func receive(
    attention: String, sessionID: String, cardID: String? = nil, at t: Date
  ) -> Bool {
    guard FocusIslands.shows(kind: attention, focusActive: focusActive) else { return false }
    let kind = PeekPlanner.kind(for: attention)
    let asking = attention == "question" && questionMode == .terminalOnly
    addMark(
      WingMark(
        kind: WingMarkKind.of(attention: attention), sessionID: sessionID, cardID: cardID,
        asking: asking, since: t))
    if let cur = current, cur.until > t, cur.kind == .finished, kind == .finished,
      t.timeIntervalSince(cur.startedAt) <= PeekPlanner.coalesceWindow
    {
      var merged = cur
      if !merged.sessionIDs.contains(sessionID) { merged.sessionIDs.append(sessionID) }
      if attention == "error" { merged.errorIDs.insert(sessionID) }
      merged.until = phaseEnd(from: t)
      current = merged
      return true
    }
    current = PeekItem(
      kind: kind, sessionIDs: [sessionID], errorIDs: attention == "error" ? [sessionID] : [],
      cardID: cardID, startedAt: t, until: phaseEnd(from: t), asking: asking)
    return true
  }

  /// Feeds a module note. Shown at once unless a Claude item is in its phase; then it waits
  /// (one slot, the newest wins). Under a Focus it is dropped. Returns true when the wings
  /// changed.
  @discardableResult
  public mutating func receive(module note: ModuleNote, at t: Date) -> Bool {
    guard !focusActive else { return false }
    if let cur = current, cur.until > t, cur.kind != .module {
      pendingModule = note
      return false
    }
    if current?.module?.id == note.id { return false }
    present(note, at: t)
    return true
  }

  private mutating func present(_ note: ModuleNote, at t: Date) {
    current = PeekItem(
      kind: .module, sessionIDs: [], errorIDs: [], cardID: nil, startedAt: t,
      until: phaseEnd(from: t), module: note)
  }

  /// Brings the permission item for `cardID` back for a new 4 s phase (a global shortcut
  /// pressed while only its mark showed, or the next card after a decision).
  public mutating func show(cardID: String, sessionID: String, at t: Date) {
    current = PeekItem(
      kind: .permission, sessionIDs: [sessionID], errorIDs: [], cardID: cardID, startedAt: t,
      until: phaseEnd(from: t))
    addMark(WingMark(kind: .permission, sessionID: sessionID, cardID: cardID, since: t))
  }

  /// Keeps the item's phase at least until `t + seconds` (pointer over the wings).
  public mutating func hold(at t: Date, seconds: TimeInterval = 1.5) {
    guard var cur = current else { return }
    cur.until = max(cur.until, t.addingTimeInterval(seconds))
    current = cur
  }

  /// Ends the item's phase once its time is over, then shows a waiting module note (if still
  /// valid). Returns true when the wings changed.
  @discardableResult
  public mutating func expire(at t: Date) -> Bool {
    var changed = false
    if let cur = current, cur.until <= t {
      current = nil
      changed = true
    }
    if current == nil, let note = pendingModule {
      pendingModule = nil
      if note.validUntil > t {
        present(note, at: t)
        changed = true
      }
    }
    return changed
  }

  /// Makes the lingering marks match `open`, everything still waiting for the user (the app
  /// builds it from the store: `openMark` per session, one permission mark per pending card).
  /// A mark already there keeps its arrival time; a new one (opened while the panel was up,
  /// or before launch) is added; a mark not in `open` goes. Kinds that do not linger
  /// (`lingers`) are left out. Returns true when the marks changed.
  @discardableResult
  public mutating func sync(open: [WingMark]) -> Bool {
    var next: [WingMark] = []
    var seen = Set<String>()
    for var mark in open where Self.lingers(mark.kind) {
      guard seen.insert(mark.id).inserted else { continue }
      if let old = marks.first(where: { $0.id == mark.id }) { mark.since = old.since }
      next.append(mark)
    }
    next.sort { ($0.since, $0.id) < ($1.since, $1.id) }
    guard next != marks else { return false }
    marks = next
    return true
  }

  /// The lingering mark a session stands for now, from plain facts of the store; nil when it
  /// stands for none. A question held in the notch or asked in the terminal, a plan to approve
  /// and a wait for input are `.attention` (`asking` for a terminal-only question). An error,
  /// seen or not, blocks nothing and has no mark (the status line keeps it). Silent mode keeps
  /// only what needs an answer (questions; permission marks come from the cards).
  public static func openMark(
    sessionID: String, statusKind: String, heldQuestion: Bool, questionMode: QuestionMode,
    silent: Bool, since: Date
  ) -> WingMark? {
    if heldQuestion {
      return WingMark(kind: .attention, sessionID: sessionID, since: since)
    }
    switch statusKind {
    case "question":
      return WingMark(
        kind: .attention, sessionID: sessionID, asking: questionMode == .terminalOnly,
        since: since)
    case "plan", "waiting":
      return silent ? nil : WingMark(kind: .attention, sessionID: sessionID, since: since)
    default:
      return nil
    }
  }

  /// The island kind whose rule (`TerminalIslands.shows`, `FocusIslands.shows`) decides
  /// whether an open mark may show right now; nil for one that always shows (a question held
  /// in the notch). An attention mark takes its session's status kind, or
  /// "question" when it is a terminal-only question.
  public static func islandKind(
    of mark: WingMark, statusKind: String?, heldQuestion: Bool
  ) -> String? {
    switch mark.kind {
    case .permission: return "permission"
    case .attention:
      guard !heldQuestion else { return nil }
      return mark.asking ? "question" : statusKind
    case .error, .done, .module: return nil
    }
  }

  /// Ends the item's phase now (answered, its terminal came to the front). Marks stay.
  public mutating func clear() {
    current = nil
  }

  /// Panel opened: the item and a waiting module note go (the panel shows everything). Marks
  /// stay until `prune` drops them.
  public mutating func clearAll() {
    current = nil
    pendingModule = nil
  }

  /// What the wings draw at `t` (nil: nothing, the notch is collapsed). `visible` hides an
  /// open mark for now without dropping it (its terminal is in front). The item in its phase
  /// is drawn as its mark when `showsText` is false ("mark only", or a Focus).
  public func display(
    at t: Date, visible: (WingMark) -> Bool = { _ in true }
  ) -> WingDisplay? {
    let shown = marks.filter(visible)
    if let cur = current, cur.until > t {
      let kind = Self.markKind(of: cur)
      let own = WingMark(
        kind: kind, sessionID: cur.sessionIDs.last, cardID: cur.cardID, asking: cur.asking,
        since: cur.startedAt)
      return WingDisplay(
        style: showsText ? .long : .mark, item: cur, mark: kind, count: shown.count, target: own,
        sessionIDs: cur.sessionIDs)
    }
    guard
      let top = shown.max(by: { ($0.kind.urgency, $0.since) < ($1.kind.urgency, $1.since) })
    else { return nil }
    return WingDisplay(
      style: .mark, item: nil, mark: top.kind, count: shown.count,
      badge: shown.count > 1 ? shown.count : 0, target: shown.count == 1 ? shown[0] : nil,
      sessionIDs: top.sessionID.map { [$0] } ?? [])
  }

  /// The mark of an item in its phase (a merged finished item with an error is an error).
  public static func markKind(of item: PeekItem) -> WingMarkKind {
    switch item.kind {
    case .permission: return .permission
    case .attention: return .attention
    case .finished: return item.errorIDs.isEmpty ? .done : .error
    case .module: return .module
    }
  }

  /// When the display next changes by itself (the end of the item's phase); nil when nothing
  /// is timed.
  public var nextChange: Date? {
    current?.until
  }
}

// MARK: - Who, in the long text

/// The long text's "who": the project and the terminal tab of the chat ("kutie-games · Fix
/// reward tiers asks:"), so several chats of one project read apart in the wings. The tab is
/// `Session.tabTitle` (Ghostty's tab name, cleaned by `TabTitle.clean`), the same title the
/// panel's rows show. A merged item (several chats) keeps its own wording.
public enum WingLabel {
  /// A cut tab keeps at least this many characters (before "…"); with less room the label
  /// names the project only.
  public static let minTabCharacters = 3

  /// What follows the project: the tab title, unless it is missing or is the project's own
  /// name (case and surrounding spaces ignored). When the title alone does not tell chats of
  /// the same project apart, the disambiguator (`SessionStore.disambiguator`: branch, tty...)
  /// follows it; without a title the disambiguator alone (today's name). nil: nothing to add.
  public static func tabPart(project: String, tabTitle: String?, disambiguator: String?)
    -> String?
  {
    func useful(_ s: String?) -> String? {
      guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
        t.caseInsensitiveCompare(project.trimmingCharacters(in: .whitespacesAndNewlines))
          != .orderedSame
      else { return nil }
      return t
    }
    let tab = useful(tabTitle)
    let d = useful(disambiguator)
    switch (tab, d) {
    case (nil, let d): return d
    case (let tab?, nil): return tab
    case (let tab?, let d?): return d == tab ? tab : "\(tab) · \(d)"
    }
  }

  /// The whole left label: `compose` turns a "who" into the sentence ("%@ asks:"). With a tab
  /// part, "project · tab" when that fits (`fits`: the app measures it against the wing's
  /// widest text); else the tab cut at its end ("Fix rewar…", whole characters, no trailing
  /// space) to the longest that fits; else, with fewer than `minTabCharacters` left, the
  /// project alone (the view truncates that one if even it does not fit).
  public static func label(
    project: String, tabPart: String?, compose: (String) -> String, fits: (String) -> Bool
  ) -> String {
    let plain = compose(project)
    guard let tabPart, !tabPart.isEmpty else { return plain }
    let whole = compose("\(project) · \(tabPart)")
    if fits(whole) { return whole }
    let chars = Array(tabPart)
    func cut(_ n: Int) -> String? {
      let head = String(chars.prefix(n)).trimmingCharacters(in: .whitespaces)
      guard head.count >= minTabCharacters else { return nil }
      return compose("\(project) · \(head)…")
    }
    // Longest cut that fits (wider with every character kept): binary search.
    var lo = minTabCharacters
    var hi = chars.count - 1
    var best: String?
    while lo <= hi {
      let mid = (lo + hi) / 2
      guard let text = cut(mid) else {
        // Too few characters once its trailing spaces go: only a longer cut can do.
        lo = mid + 1
        continue
      }
      if fits(text) {
        best = text
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    return best ?? plain
  }
}

// MARK: - Geometry

/// Wing sizes (points). The wings stay inside the menu-bar band: nothing is drawn below it.
public enum WingMetrics {
  /// Style "A": each side of the notch.
  public static let markWidth: CGFloat = 30
  /// Style "C": each side at most (a 1280 pt screen with Chrome's menus on the left keeps most
  /// of its menu bar: the whole shape is at most notch + 2 × 220 pt).
  public static let maxLongWidth: CGFloat = 220
  /// Style "C": each side at least (a short text still reads as wings, not as a mark).
  public static let minLongWidth: CGFloat = 96
  /// Inner padding at each end of a long wing (notch side and outer end).
  public static let padding: CGFloat = 12
  /// Room kept free at each screen edge.
  public static let screenMargin: CGFloat = 8
  /// Height of the wings on a screen whose menu bar is hidden (no band to grow into). There
  /// they show only the mark, and only for an item's 4 s (no long text, no lingering mark over
  /// the app's content; the status line still marks the session).
  public static let bandlessHeight: CGFloat = 24
  /// Advance of one column of the right wing's monospaced 11 pt text (SF Mono: 6.8 pt).
  public static let monoAdvance: CGFloat = 6.8
  /// The hold ring beside a risky request's text, and the gap before it.
  public static let holdRing: CGFloat = 14
  public static let ringGap: CGFloat = 6

  /// Monospaced columns that fit one long right wing at its widest (`maxLongWidth` less the
  /// padding and the 1 pt the app adds when it measures), less the hold ring on a risky
  /// request: 28, or 25 with the ring.
  public static func monoColumns(ring: Bool) -> Int {
    let room = maxLongWidth - 2 * padding - 1 - (ring ? holdRing + ringGap : 0)
    return Int((room / monoAdvance).rounded(.down))
  }

  /// Width of each side (the shape is symmetric). Mark style: `markWidth`. Long style: the
  /// wider of the two measured contents plus `padding` at both ends, within
  /// `minLongWidth...maxLongWidth` and never past `screenMargin` from the screen edge.
  public static func sideWidth(
    style: WingStyle, leftContent: CGFloat, rightContent: CGFloat, notchWidth: CGFloat,
    screenWidth: CGFloat
  ) -> CGFloat {
    let room = max(markWidth, (screenWidth - notchWidth) / 2 - screenMargin)
    switch style {
    case .mark:
      return min(markWidth, room)
    case .long:
      let wanted = max(leftContent, rightContent) + 2 * padding
      return min(room, min(maxLongWidth, max(minLongWidth, wanted)))
    }
  }

  /// Whole width of the shape: the notch plus both sides.
  public static func totalWidth(side: CGFloat, notchWidth: CGFloat) -> CGFloat {
    notchWidth + 2 * side
  }

  /// Height of the wings: the band, or `bandlessHeight` when the screen shows no menu bar.
  public static func height(bandHeight: CGFloat) -> CGFloat {
    bandHeight > 0 ? bandHeight : bandlessHeight
  }
}

// MARK: - Permission text in the right wing

extension PendingPermission {
  /// Display columns of the right wing's one line (monospaced 11 pt in a 220 - 2 × 12 pt wing).
  public static let wingLimit = WingMetrics.monoColumns(ring: false)
  /// The same for a risky request, whose wing also holds the hold ring.
  public static let riskyWingLimit = WingMetrics.monoColumns(ring: true)

  /// Columns of this request's right wing line.
  public var wingColumns: Int { risk == nil ? Self.wingLimit : Self.riskyWingLimit }

  /// The right wing's one line (head…tail when long).
  public var wingText: String {
    TextShortener.oneLine(fullText.isEmpty ? toolName : fullText, limit: wingColumns)
  }

  /// The right wing shows the whole request (nothing folded, cut or elided, no written content /
  /// edit behind it): only then may the global allow shortcut allow it while the panel is
  /// closed. Otherwise the shortcut opens the panel. The app also measures the drawn line
  /// against the wing on that screen (a narrow screen has narrower wings).
  public var fitsWing: Bool {
    extra == nil && !fullText.isEmpty && wingText == fullText
      && ToolSummary.displayWidth(fullText) <= wingColumns
  }
}
