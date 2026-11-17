import AppKit
import ClaudeNotchCore
import SwiftUI

// The notch "wings": instead of an island dropping out of the notch, the notch grows sideways at
// band height (see `WingPlanner`, `WingMetrics`). For 4 s the wings are wide and carry a short
// text (left: who / what, right: the detail); then they shrink to a small colored mark (left a
// dot, right a glyph or a count). They have no buttons: a click opens the panel (or, for a
// terminal-only question, goes to its terminal), the global shortcuts answer a permission.

/// The long wings' text for one item (style "C"). The controller sizes the wings from the same
/// value the view draws (`contentWidths`), so the shape is at its width from the first frame.
@MainActor
struct WingText: Equatable {
  /// Left wing: who / what ("claude-notch · Fix tests wants to run": project and terminal tab).
  var left: String
  /// Right wing: the detail, one line (the command, the question, a summary).
  var right: String?
  /// The right line is a command or a path: monospaced, shortened in the middle.
  var mono = false
  /// The card this permission text is about (the hold ring follows its global hold).
  var cardID: String?
  /// A risky permission: the right wing keeps room for the hold ring.
  var holdRing = false

  static let leftSize: CGFloat = 12
  static let rightSize: CGFloat = 11
  static let dot: CGFloat = 6
  static let gap: CGFloat = 6
  static let ring = WingMetrics.holdRing

  /// The text of `item`, or nil when there is nothing to say (its card or session is gone):
  /// the wings then show the mark.
  static func make(_ item: PeekItem, store: SessionStore) -> WingText? {
    func name(_ id: String?) -> String {
      id.flatMap { store.sessions[$0] }.map { store.displayName(for: $0) } ?? "Claude"
    }
    func line(_ text: String?, limit: Int = 120) -> String? {
      guard let text, !text.isEmpty else { return nil }
      return TextShortener.oneLine(text, limit: limit)
    }
    switch item.kind {
    case .permission:
      guard let card = item.cardID.flatMap({ store.card(id: $0) }) else { return nil }
      return permission(card, store: store)
    case .attention:
      guard let sid = item.sessionIDs.first, let session = store.sessions[sid] else { return nil }
      if let held = store.question(for: sid) {
        return WingText(
          left: who(session, store: store) { loc("\($0) asks:") },
          right: line(held.questions.first?.question, limit: 60))
      }
      switch session.status {
      case .question(let text, _):
        return WingText(
          left: who(session, store: store) { loc("\($0) asks:") }, right: line(text, limit: 60))
      case .planApproval(let first):
        return WingText(
          left: who(session, store: store) { loc("\($0) has a plan to approve") },
          right: line(first))
      case .waitingInput(let text):
        return WingText(
          left: who(session, store: store) { loc("\($0) is waiting for you") },
          right: line(text) ?? loc("Claude is waiting for a reply"))
      default:
        // The status moved on within the 4 s: no stale detail.
        return WingText(
          left: who(session, store: store) { loc("\($0) is waiting for you") },
          right: loc("Claude is waiting for a reply"))
      }
    case .finished:
      guard item.sessionIDs.count == 1, let sid = item.sessionIDs.first else {
        let names = item.sessionIDs.map(name)
        return WingText(left: PeekPlanner.finishedTitle(names: names, errors: item.errorIDs.count))
      }
      let errored = !item.errorIDs.isEmpty
      let compose: (String) -> String = {
        errored ? loc("\($0) stopped with an error") : loc("\($0) finished")
      }
      let left = store.sessions[sid].map { who($0, store: store, compose) } ?? compose(name(sid))
      return WingText(left: left, right: line(store.sessions[sid]?.status.detail))
    case .module:
      guard let note = item.module else { return nil }
      let value = note.digits.map { d in note.unit.map { "\(d) \($0)" } ?? d }
      return WingText(left: note.title, right: note.subtitle ?? value)
    }
  }

  /// The long text of a permission request: who wants to run / use what, and its one line.
  static func permission(_ card: PendingPermission, store: SessionStore) -> WingText {
    let compose: (String) -> String = {
      card.toolName == "Bash" ? loc("\($0) wants to run") : loc("\($0) wants to use \(card.toolName)")
    }
    let left = store.sessions[card.sessionID].map { who($0, store: store, compose) }
      ?? compose("Claude")
    return WingText(
      left: left, right: card.wingText, mono: true, cardID: card.id, holdRing: card.risk != nil)
  }

  /// The left text of one chat: its project and terminal tab (`WingLabel`: the tab title the
  /// panel's rows show, `Session.tabTitle`), the tab cut first so the whole sentence fits the
  /// widest left wing (`WingMetrics.maxLongWidth`). A narrower screen still truncates the end.
  static func who(
    _ session: Session, store: SessionStore, _ compose: (String) -> String
  ) -> String {
    let part = WingLabel.tabPart(
      project: session.project, tabTitle: session.tabTitle,
      disambiguator: store.disambiguator(for: session))
    return WingLabel.label(
      project: session.project, tabPart: part, compose: compose, fits: fitsWidestLeft)
  }

  /// `left` (with its dot) fits a left wing at its widest.
  static func fitsWidestLeft(_ left: String) -> Bool {
    measure(left, leftFont) + dot + gap + 2 * WingMetrics.padding <= WingMetrics.maxLongWidth
  }

  static var leftFont: NSFont { .systemFont(ofSize: leftSize, weight: .semibold) }

  /// Drawn width of `s` in `font`, rounded up, plus the 1 pt the text views need.
  static func measure(_ s: String, _ font: NSFont) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: font]).width) + 1
  }

  /// The right line (and the hold ring) fits its wing on `g`'s screen, nothing truncated.
  func showsWholeRight(_ g: NotchGeometry) -> Bool {
    contentWidths.right + 2 * WingMetrics.padding <= side(g)
  }

  /// Widths of the left and right content (text plus the dot / ring), without padding.
  var contentWidths: (left: CGFloat, right: CGFloat) {
    let left = Self.measure(left, Self.leftFont) + Self.dot + Self.gap
    var right = right.map {
      Self.measure(
        $0,
        mono
          ? .monospacedSystemFont(ofSize: Self.rightSize, weight: .regular)
          : .systemFont(ofSize: Self.rightSize))
    } ?? 0
    if holdRing { right += Self.ring + WingMetrics.ringGap }
    return (left, right)
  }

  /// Width of each long wing for this text on `g`'s screen.
  func side(_ g: NotchGeometry) -> CGFloat {
    let c = contentWidths
    return WingMetrics.sideWidth(
      style: .long, leftContent: c.left, rightContent: c.right, notchWidth: g.notchWidth,
      screenWidth: g.screenFrame.width)
  }
}

/// The wings beside the notch, at band height: left wing, the notch's own width (empty), right
/// wing. The whole row is one button.
struct WingsView: View {
  let display: WingDisplay
  /// The long text (nil: the mark is drawn, also in style "long" when the item has no text).
  let text: WingText?
  let store: SessionStore
  let ui: NotchUIState
  let actions: NotchActions
  let geometry: NotchGeometry
  /// Current width of each wing (`SurfaceState.wingSide`).
  let side: CGFloat
  let height: CGFloat
  @Environment(\.notchTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var long: WingText? { display.style == .long ? text : nil }

  var body: some View {
    let tint = Self.color(display, theme: theme)
    HStack(spacing: 0) {
      ZStack(alignment: .trailing) {
        if let long {
          leftLong(long, tint: tint).id(contentKey).transition(textTransition)
        } else {
          Circle().fill(tint).frame(width: 7, height: 7)
            .frame(width: WingMetrics.markWidth, height: height)
            .id(contentKey).transition(markTransition)
        }
      }
      .frame(width: side, height: height, alignment: .trailing)
      Color.clear.frame(width: geometry.notchWidth, height: height)
      ZStack(alignment: .leading) {
        if let long {
          rightLong(long, tint: tint).id(contentKey).transition(textTransition)
        } else {
          markGlyph(tint: tint)
            .frame(width: WingMetrics.markWidth, height: height)
            .id(contentKey).transition(markTransition)
        }
      }
      .frame(width: side, height: height, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { actions.wingTap(geometry.displayID) }
    .help(helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { actions.wingTap(geometry.displayID) }
  }

  /// A new item (or a mark that changed) replaces the content instead of morphing it.
  private var contentKey: String {
    if let item = display.item, long != nil {
      return "long:\(item.kind.rawValue):\(item.startedAt.timeIntervalSince1970)"
    }
    return "mark:\(display.mark.rawValue):\(display.badge)"
  }

  /// Text arrives once the wings are mostly out (strong ease-out) and leaves before they
  /// shrink. Reduce Motion: a plain crossfade.
  private var textTransition: AnyTransition {
    if reduceMotion { return .opacity.animation(Motion.crossfade) }
    return .asymmetric(
      insertion: .opacity.animation(Motion.wingContentIn.delay(Motion.contentDelay)),
      removal: .opacity.animation(Motion.contentOut))
  }

  /// The mark fades in once the wings have mostly shrunk to it (the shrink waits for the text
  /// to leave first).
  private var markTransition: AnyTransition {
    if reduceMotion { return .opacity.animation(Motion.crossfade) }
    return .asymmetric(
      insertion: .opacity.animation(
        Motion.wingContentIn.delay(Motion.wingShrinkDelay + Motion.contentDelay * 2)),
      removal: .opacity.animation(Motion.contentOut))
  }

  /// Long text laid out at its own long width (not the animated one), trailing at the notch:
  /// the shape reveals it as the wings grow and clips it as they shrink, nothing re-wraps.
  private func leftLong(_ t: WingText, tint: Color) -> some View {
    HStack(spacing: WingText.gap) {
      Circle().fill(tint).frame(width: WingText.dot, height: WingText.dot)
      Text(t.left)
        .font(.system(size: WingText.leftSize, weight: .semibold))
        .foregroundStyle(theme.ink)
        .lineLimit(1).truncationMode(.tail)
    }
    .padding(.horizontal, WingMetrics.padding)
    .frame(width: t.side(geometry), height: height, alignment: .trailing)
  }

  private func rightLong(_ t: WingText, tint: Color) -> some View {
    HStack(spacing: WingText.gap) {
      if let right = t.right {
        Text(right)
          .font(t.mono
            ? .system(size: WingText.rightSize, design: .monospaced) : .system(size: WingText.rightSize))
          .foregroundStyle(theme.secondary)
          .lineLimit(1).truncationMode(t.mono ? .middle : .tail)
      }
      if t.holdRing, let id = t.cardID { HoldRing(cardID: id, ui: ui, tint: tint) }
    }
    .padding(.horizontal, WingMetrics.padding)
    .frame(width: t.side(geometry), height: height, alignment: .leading)
  }

  @ViewBuilder
  private func markGlyph(tint: Color) -> some View {
    if display.badge > 1 {
      Text(verbatim: String(display.badge))
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
    } else if let symbol = Self.symbol(display.mark) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(tint)
    } else {
      Circle().fill(tint).frame(width: 7, height: 7)
    }
  }

  private var helpText: String {
    guard display.item?.kind == .permission || display.mark == .permission,
      let allow = ui.allowKey, let deny = ui.denyKey
    else { return "" }
    return loc("\(allow) allow · \(deny) deny")
  }

  private var accessibilityText: String {
    if let long { return [long.left, long.right].compactMap { $0 }.joined(separator: " ") }
    let name: String
    switch display.mark {
    case .permission: name = loc("Permission request")
    case .attention: name = loc("Waiting for a reply")
    case .error: name = loc("Error")
    case .done: name = loc("Done")
    case .module: name = display.item?.module?.title ?? ""
    }
    return display.count > 1 ? "\(name), " + loc("\(display.count) waiting") : name
  }

  /// SF Symbol of a mark (nil: a module note draws its tint dot).
  static func symbol(_ kind: WingMarkKind) -> String? {
    switch kind {
    case .permission: return "shield.fill"
    case .attention: return "questionmark"
    case .error: return "exclamationmark"
    case .done: return "checkmark"
    case .module: return nil
    }
  }

  /// The mark's color: what needs the user is amber / yellow, an error red / pink, done the
  /// near-white, a module note its module's tint.
  static func color(_ d: WingDisplay, theme: NotchTheme) -> Color {
    switch d.mark {
    case .permission, .attention: return theme.needs
    case .error: return theme.error
    case .done: return theme.done
    case .module: return d.item?.module.map { moduleTint($0, theme: theme) } ?? theme.idle
    }
  }

  static func moduleTint(_ note: ModuleNote, theme: NotchTheme) -> Color {
    switch note.source {
    case .calendar: return Color(hex: 0x8FA6FF)
    case .timer: return theme.working
    case .battery: return (note.level ?? 1) <= 0.1 ? theme.error : theme.done
    case .shelf: return Color(hex: 0xC3A8FF)
    case .weather: return Color(hex: 0x56CFE3)
    case .claude: return theme.needs
    case .usage: return (note.digits.flatMap(Int.init) ?? 0) >= 95 ? theme.error : theme.needs
    }
  }
}

/// The global allow shortcut held on a risky request: a ring around a shield fills over the hold
/// (the controller animates `holdProgress` linearly), so the hold has feedback in the wing.
private struct HoldRing: View {
  let cardID: String
  let ui: NotchUIState
  let tint: Color
  @Environment(\.notchTheme) private var theme

  var body: some View {
    let progress = ui.holdProgress[cardID] ?? 0
    let tapped = ui.holdHintCardID == cardID
    ZStack {
      Circle().stroke(tint.opacity(tapped ? 0.9 : 0.3), lineWidth: 1.5)
      Circle().trim(from: 0, to: progress)
        .stroke(theme.error, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Image(systemName: "shield.fill").font(.system(size: 6.5, weight: .bold)).foregroundStyle(tint)
    }
    .frame(width: WingText.ring, height: WingText.ring)
  }
}
