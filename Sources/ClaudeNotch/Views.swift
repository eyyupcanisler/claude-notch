import AppKit
import ClaudeNotchCore
import SwiftUI

enum DecisionSource: Sendable {
  case click
  case key
  /// Hold-to-allow completed on the panel's card.
  case hold
  /// Global shortcut (⌃⌥Y / ⌃⌥N): only on the request on screen; with the panel closed, the
  /// wings' rules (allowing needs the whole request in the wing, `fitsWing`).
  case global
  /// Global allow shortcut held for the hold time on a risky request.
  case globalHold

  var isHold: Bool { self == .hold || self == .globalHold }
  var isGlobal: Bool { self == .global || self == .globalHold }
}

struct NotchActions {
  var decide: @MainActor (String, PermissionDecision, DecisionSource) -> Void = { _, _, _ in }
  var toggleDetail: @MainActor (String) -> Void = { _ in }
  /// The opened card's text was on screen down to its end (card id, trigger).
  var readToEnd: @MainActor (String, String) -> Void = { _, _ in }
  /// The card's "Always" rule was on screen down to its end (card id, trigger).
  var ruleRead: @MainActor (String, String) -> Void = { _, _ in }
  var toggleMore: @MainActor (String) -> Void = { _ in }
  var pager: @MainActor (Int) -> Void = { _ in }
  var selectCard: @MainActor (String) -> Void = { _ in }
  var focus: @MainActor (String) -> Void = { _ in }
  var markSeen: @MainActor (String) -> Void = { _ in }
  var markAllSeen: @MainActor () -> Void = {}
  var copyMessage: @MainActor (String) -> Void = { _ in }
  var denyAll: @MainActor (String) -> Void = { _ in }
  var togglePin: @MainActor () -> Void = {}
  var openSettings: @MainActor () -> Void = {}
  var expand: @MainActor (CGDirectDisplayID) -> Void = { _ in }
  /// A click on the wings: the panel opens, or a terminal-only question's terminal comes up.
  var wingTap: @MainActor (CGDirectDisplayID) -> Void = { _ in }
  /// Selects the oldest card (the "N permissions" chip).
  var showCards: @MainActor () -> Void = {}
  var bodyHeight: @MainActor (CGDirectDisplayID, NotchMode, CGFloat) -> Void = { _, _, _ in }
  /// Ghostty Automation: ask (macOS prompt) or open System Settings when denied.
  var ghosttyConsent: @MainActor () -> Void = {}
  /// A held question answered in the notch (question id, labels by question text).
  var answerQuestion: @MainActor (String, [String: [String]]) -> Void = { _, _ in }
  /// Hand a held question to the terminal and focus it.
  var releaseQuestion: @MainActor (String) -> Void = { _ in }
  /// Picks / un-picks option `index` of the question on screen (same path as ⌃⌥1…4).
  var pickOption: @MainActor (String, Int) -> Void = { _, _ in }
  /// "Next" / "Send" (same as ⌃⌥Y), and "Back".
  var questionNext: @MainActor (String) -> Void = { _ in }
  var questionBack: @MainActor (String) -> Void = { _ in }
  /// A shelf chip dropped on a session row: copy it and focus that session's tab.
  /// Returns false when nothing from the shelf was being dragged.
  var dropShelf: @MainActor (String) -> Bool = { _ in false }
}

// MARK: - Shape

/// The island outline (SwiftUI y-down, in the window's coordinates, centered on it):
/// `topWidth` inside the menu-bar band, flaring out with concave fillets right under the band
/// to `bodyWidth`, continuous bottom corners. An expanded panel has concave shoulders where it
/// meets the top edge of the screen. Every parameter animates, so one spring drives the shape.
struct IslandShape: Shape {
  var topWidth: CGFloat
  var bodyWidth: CGFloat
  var height: CGFloat
  var shoulder: CGFloat
  var radius: CGFloat
  /// Menu-bar band height (notch height); not animated.
  let band: CGFloat

  init(_ island: IslandGeometry, band: CGFloat) {
    topWidth = island.topWidth
    bodyWidth = island.bodyWidth
    height = island.height
    shoulder = island.shoulder
    radius = island.bottomRadius
    self.band = band
  }

  var animatableData:
    AnimatablePair<
      AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>
    >
  {
    get {
      AnimatablePair(
        AnimatablePair(topWidth, bodyWidth),
        AnimatablePair(height, AnimatablePair(shoulder, radius)))
    }
    set {
      topWidth = newValue.first.first
      bodyWidth = newValue.first.second
      height = newValue.second.first
      shoulder = newValue.second.second.first
      radius = newValue.second.second.second
    }
  }

  func path(in rect: CGRect) -> Path {
    // Nothing to draw (a synthetic notch on a screen without a visible menu bar).
    guard height >= 0.5 else { return Path() }
    let cx = rect.midX
    let top = rect.minY
    let h = height
    let a = max(1, topWidth / 2)
    let b = max(a, bodyWidth / 2)
    let s = max(0, min(shoulder, a / 2, h / 3))
    let flare = b - a
    let hasFlare = flare > 0.5 && h > band + 1
    let below = max(0, h - band)
    // Concave fillet (band -> island) and the island's convex top-outer corner.
    let f = hasFlare ? min(NotchMetrics.fillet, flare / 2, band - s) : 0
    let rc = hasFlare ? max(0, min(NotchMetrics.islandTopRadius, flare - f, below / 2)) : 0
    let side = hasFlare ? b : a
    let bodyTop = hasFlare ? top + band : top + s
    // Continuous bottom corner: starts earlier (1.28 r) and eases in.
    let k = max(0, min(radius * 1.28, side, (top + h - bodyTop - rc) * 0.9))
    let c = k * 0.38
    let bottom = top + h

    var p = Path()
    p.move(to: CGPoint(x: cx - a - s, y: top))
    p.addLine(to: CGPoint(x: cx + a + s, y: top))
    if s > 0 {
      p.addCurve(
        to: CGPoint(x: cx + a, y: top + s),
        control1: CGPoint(x: cx + a + s * 0.45, y: top),
        control2: CGPoint(x: cx + a, y: top + s * 0.55))
    }
    if hasFlare {
      p.addLine(to: CGPoint(x: cx + a, y: top + band - f))
      p.addQuadCurve(
        to: CGPoint(x: cx + a + f, y: top + band), control: CGPoint(x: cx + a, y: top + band))
      p.addLine(to: CGPoint(x: cx + b - rc, y: top + band))
      p.addQuadCurve(
        to: CGPoint(x: cx + b, y: top + band + rc), control: CGPoint(x: cx + b, y: top + band))
    }
    p.addLine(to: CGPoint(x: cx + side, y: bottom - k))
    p.addCurve(
      to: CGPoint(x: cx + side - k, y: bottom), control1: CGPoint(x: cx + side, y: bottom - c),
      control2: CGPoint(x: cx + side - c, y: bottom))
    p.addLine(to: CGPoint(x: cx - side + k, y: bottom))
    p.addCurve(
      to: CGPoint(x: cx - side, y: bottom - k), control1: CGPoint(x: cx - side + c, y: bottom),
      control2: CGPoint(x: cx - side, y: bottom - c))
    if hasFlare {
      p.addLine(to: CGPoint(x: cx - b, y: top + band + rc))
      p.addQuadCurve(
        to: CGPoint(x: cx - b + rc, y: top + band), control: CGPoint(x: cx - b, y: top + band))
      p.addLine(to: CGPoint(x: cx - a - f, y: top + band))
      p.addQuadCurve(
        to: CGPoint(x: cx - a, y: top + band - f), control: CGPoint(x: cx - a, y: top + band))
    }
    p.addLine(to: CGPoint(x: cx - a, y: top + s))
    if s > 0 {
      p.addCurve(
        to: CGPoint(x: cx - a - s, y: top),
        control1: CGPoint(x: cx - a, y: top + s * 0.55),
        control2: CGPoint(x: cx - a - s * 0.45, y: top))
    }
    p.closeSubpath()
    return p
  }
}

// MARK: - Root

struct NotchRootView: View {
  let store: SessionStore
  let ui: NotchUIState
  let settings: NotchSettings
  let modules: ModuleCenter
  let surface: SurfaceState
  let actions: NotchActions

  private var theme: NotchTheme { settings.tokens }
  private var mode: NotchMode { surface.mode }
  private var g: NotchGeometry { surface.geometry }

  var body: some View {
    let island = NotchMetrics.island(
      mode, geometry: g, body: surface.bodyHeight, wingSide: surface.wingSide)
    let shape = IslandShape(island, band: g.bandHeight)
    let segments = store.statusLine
    // A hidden synthetic pill draws nothing; the hardware notch is black anyway (the collapsed
    // shape stays inside the camera housing).
    let drawn = surface.visible && (g.hasNotch || mode != .collapsed || !segments.isEmpty)
    let windowW = NotchMetrics.windowWidth(screen: g.screenFrame.width)
    // The status line and the timer stay while the wings are out (a mark can linger for long);
    // on a screen without a menu bar the wings sit where the line would be, so it waits.
    let lineMode = mode == .collapsed || (mode == .peek && g.bandHeight > 0)
    let pillShown = lineMode && surface.visible && modules.timerPillVisible
      && (g.hasNotch || !segments.isEmpty)
    ZStack(alignment: .top) {
      NotchBackground(mode: mode, theme: theme, band: g.toolbarHeight)
        .clipShape(shape)
        // Pointer on the collapsed notch: it swells a few points at once (feedback before the
        // dwell opens the panel).
        .scaleEffect(
          mode == .collapsed && surface.primed ? CGSize(width: 1.05, height: 1.18) : CGSize(
            width: 1, height: 1), anchor: .top)
        .opacity(drawn ? 1 : 0)
      VStack(spacing: 0) {
        bandRow(island)
          .frame(width: island.topWidth, height: bandRowHeight(island))
        bodyContent
          .frame(width: island.bodyWidth)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: windowW, height: NotchMetrics.windowHeight, alignment: .top)
      .clipShape(shape)
      StatusLineView(
        segments: segments, colors: settings.statusColors.colors,
        // The chat the wings are about lights up, so the wing reads as that segment's.
        lit: mode == .peek ? Set(ui.wings?.sessionIDs ?? []) : [])
        .frame(width: NotchMetrics.lineWidth(notch: g.notchWidth), height: NotchMetrics.lineHeight)
        .padding(.top, NotchMetrics.lineTop(g, pill: pillShown))
        .opacity(lineMode && surface.visible && !segments.isEmpty ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      // The ears also flank an external screen's pill: the middle of a notchless menu bar is
      // free, so they are always full there.
      if mode == .collapsed && surface.visible && modules.earsVisible
        && (g.hasNotch || !segments.isEmpty)
      {
        SpotifyEars(
          spotify: modules.spotify, full: modules.earsFull || !g.hasNotch,
          notchWidth: g.notchWidth, height: g.bandHeight)
          .onTapGesture { actions.expand(g.displayID) }
          .transition(.opacity)
      }
      if pillShown {
        TimerPill(modules: modules)
          .frame(
            width: g.notchWidth,
            height: NotchMetrics.pillHeight - 2 + NotchMetrics.pillOverlap)
          .padding(.top, NotchMetrics.pillTop(g))
          .transition(.opacity)
          .allowsHitTesting(false)
      }
      if mode == .collapsed || mode == .peek {
        // The notch and the line (and the timer pill) open the panel on click (clicking never
        // makes it key); with the wings out, the notch is part of the wings' button.
        let tap = { mode == .peek ? actions.wingTap(g.displayID) : actions.expand(g.displayID) }
        Color.clear
          .frame(
            width: g.notchWidth,
            height: modules.timerPillVisible
              ? NotchMetrics.pillZoneDepth(g) : NotchMetrics.lineZoneDepth(g))
          .contentShape(Rectangle())
          .onTapGesture { tap() }
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { tap() }
      }
    }
    .environment(\.notchTheme, theme)
    .frame(width: windowW, height: NotchMetrics.windowHeight, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(NotchSignals(store: store).accessibilityText)
  }

  private func bandRowHeight(_ island: IslandGeometry) -> CGFloat {
    switch mode {
    case .expanded: return g.toolbarHeight
    case .peek: return island.height
    case .collapsed: return g.bandHeight
    }
  }

  @ViewBuilder
  private func bandRow(_ island: IslandGeometry) -> some View {
    if mode == .peek, let wings = ui.wings {
      WingsView(
        // No menu bar on this screen: only the mark (see `NotchController.wingsFit`).
        display: wings,
        text: g.bandHeight > 0 ? wings.item.flatMap { WingText.make($0, store: store) } : nil,
        store: store, ui: ui, actions: actions, geometry: g, side: surface.wingSide,
        height: island.height)
    } else if mode == .expanded {
      ExpandedToolbar(
        store: store, ui: ui, settings: settings, modules: modules, actions: actions,
        notchWidth: g.notchWidth,
        sideWidth: max(0, (island.topWidth - g.notchWidth) / 2))
        .transition(.opacity.animation(Motion.contentOut))
    } else {
      Color.clear
    }
  }

  @ViewBuilder
  private var bodyContent: some View {
    switch mode {
    case .collapsed, .peek:
      // The wings live in the band row: nothing is drawn below the band.
      Color.clear.frame(height: 0)
    case .expanded:
      ExpandedBody(
        store: store, ui: ui, settings: settings, modules: modules, actions: actions,
        bandHeight: g.toolbarHeight)
        .measuredHeight { actions.bodyHeight(g.displayID, .expanded, $0) }
        .transition(.opacity.animation(Motion.contentOut))
    }
  }
}

/// Solid black in every mode (the "Gauge" look: the hardware notch simply grows). The open
/// panel adds the matte grain below the band; its opacity changes in the shape's transaction,
/// so it arrives with the same spring.
struct NotchBackground: View {
  let mode: NotchMode
  let theme: NotchTheme
  let band: CGFloat

  var body: some View {
    let open = mode == .expanded
    ZStack(alignment: .top) {
      Color.black
      if let grain = Grain.image {
        grain.resizable(resizingMode: .tile)
          .opacity(open ? theme.grainOpacity : 0)
          .blendMode(.plusLighter)
          .padding(.top, band)
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Signals

/// Counts behind the chips and the accessibility summary.
@MainActor
struct NotchSignals {
  let store: SessionStore

  /// Sessions actually running (a session blocked on a card / question is not "working").
  var working: Int { store.activeWorkingCount }

  /// Sessions asking in the terminal (question / plan approval / input), cards excluded.
  var questions: Int {
    store.sessions.values.filter {
      switch $0.status {
      case .question, .planApproval, .waitingInput: return true
      default: return false
      }
    }.count
  }

  var errorCount: Int {
    store.sessions.values.filter { s in
      if case .error = s.status { return s.unseen }
      return false
    }.count
  }

  var accessibilityText: String {
    var parts: [String] = []
    if working > 0 { parts.append(loc("\(working) sessions working")) }
    let perms = store.pending.count
    if perms > 0 { parts.append(loc("\(perms) permissions waiting")) }
    let cardSessions = Set(store.pending.map(\.sessionID))
    let others = store.sessions.values.filter { s in
      guard !cardSessions.contains(s.id) else { return false }
      switch s.status {
      case .question, .planApproval, .waitingInput: return true
      default: return false
      }
    }.count
    if others > 0 { parts.append(loc("\(others) sessions awaiting reply")) }
    if errorCount > 0 { parts.append(loc("\(errorCount) errors")) }
    if store.doneUnseenCount > 0 { parts.append(loc("\(store.doneUnseenCount) sessions done")) }
    return parts.isEmpty ? loc("Claude: no active sessions") : "Claude: " + parts.joined(separator: ", ")
  }
}

// MARK: - Status line

/// The only persistent visual: a 3 pt line under the notch, one segment per session (creation
/// order), each colored by its state from the chosen palette (`StatusColorScheme`): moving
/// shine = working, slow fade = needs you, solid = done, faint = idle. Error is a solid bar in
/// the classic palette (the original look) and a broken bar (3 dashes) in the colorblind one,
/// where every state then reads without color. With Reduce Motion on, the shine and the fade
/// stop, so working, needs you and done differ by color and brightness only. Core Animation
/// runs the shimmer / breathing / flash in the render server, so an always-on line costs the
/// app no frames. While the wings are out, the segment of the chat they are about is lit
/// (`lit`): 1.5 pt taller, growing downward, with a stronger halo in its own color, so the
/// colors keep their meaning.
struct StatusLineView: NSViewRepresentable {
  let segments: [LineSegment]
  let colors: StatusPalette.Colors
  /// Sessions whose segment is lit (`WingDisplay.sessionIDs`).
  var lit: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> StatusLineLayerView { StatusLineLayerView() }

  func updateNSView(_ view: StatusLineLayerView, context: Context) {
    view.update(segments, colors: colors, lit: lit, reduceMotion: reduceMotion)
  }
}

@MainActor
final class StatusLineLayerView: NSView {
  private final class Segment {
    /// The lit segment's halo (opacity 0 while not lit), under the glow.
    let halo = CALayer()
    let glow = CALayer()
    let bar = CALayer()
    let shine = CAGradientLayer()
    /// The wings are about this chat (`StatusLineView.lit`).
    var lit = false
    /// Masks the bar into dashes while the state is `.error` and the palette draws error broken
    /// (nil otherwise).
    var dashMask: CAShapeLayer?
    var state: LineState?
  }

  private var segments: [String: Segment] = [:]
  private var order: [LineSegment] = []
  private var reduceMotion = false
  private var colors = StatusPalette.classic

  /// The lit segment: this much taller, growing downward from the line's top (the line stays
  /// tied to the notch; nothing of the bar reaches more than 1.5 pt below today's).
  static let litLift: CGFloat = 1.5
  /// The lit segment's halo: the segment's own color, a tighter blur than the glow (4 pt) so
  /// it brightens the bar rather than spreading further, at this opacity (idle: `litIdleHalo`,
  /// a faint white bar should not turn into a bright one). It is a shadow only (no fill, shaped
  /// by `shadowPath`) and breathes / flashes with the bar, so a lit "needs you" bar still pulses
  /// and a lit "done" bar still flashes on arrival.
  static let litHaloRadius: CGFloat = 3
  static let litHalo: Float = 0.85
  static let litIdleHalo: Float = 0.3
  /// Lighting up: a strong ease-out, short (wings show many times a day). Going dark: quicker.
  /// Reduce Motion: no growth, the halo only crossfades (`litFade`).
  static let litIn = (duration: 0.2, curve: CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
  static let litOut = (duration: 0.14, curve: CAMediaTimingFunction(name: .easeOut))
  static let litFade = (duration: 0.16, curve: CAMediaTimingFunction(name: .easeOut))

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    place()
  }

  func update(
    _ list: [LineSegment], colors: StatusPalette.Colors, lit: Set<String> = [],
    reduceMotion: Bool
  ) {
    // A palette switch (Settings) restyles every segment in place, without an arrival flash.
    let restyle = reduceMotion != self.reduceMotion || colors != self.colors
    self.reduceMotion = reduceMotion
    self.colors = colors
    order = list
    let ids = Set(list.map(\.sessionID))
    for (id, seg) in segments where !ids.contains(id) {
      seg.halo.removeFromSuperlayer()
      seg.glow.removeFromSuperlayer()
      seg.bar.removeFromSuperlayer()
      segments.removeValue(forKey: id)
    }
    var created: Set<String> = []
    for item in list {
      if segments[item.sessionID] == nil { created.insert(item.sessionID) }
      let seg = segments[item.sessionID] ?? makeSegment(item.sessionID)
      if seg.state != item.state || restyle {
        let arrived = seg.state != nil && seg.state != item.state
        style(seg, item.state, arrived: arrived || seg.state == nil)
      }
    }
    var changed: Set<String> = []
    for item in list {
      guard let seg = segments[item.sessionID] else { continue }
      let on = lit.contains(item.sessionID)
      if seg.lit != on {
        seg.lit = on
        // A segment that only now arrives is placed lit at once (nothing to grow from).
        if !created.contains(item.sessionID) { changed.insert(item.sessionID) }
      }
    }
    place(animating: changed)
  }

  private func makeSegment(_ id: String) -> Segment {
    let seg = Segment()
    seg.bar.cornerRadius = NotchMetrics.lineHeight / 2
    seg.bar.masksToBounds = true
    seg.glow.cornerRadius = NotchMetrics.lineHeight / 2
    seg.shine.startPoint = CGPoint(x: 0, y: 0.5)
    seg.shine.endPoint = CGPoint(x: 1, y: 0.5)
    seg.shine.colors = [
      NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.85).cgColor,
      NSColor.white.withAlphaComponent(0).cgColor
    ]
    seg.bar.addSublayer(seg.shine)
    seg.halo.shadowOffset = .zero
    seg.halo.shadowOpacity = 1
    seg.halo.shadowRadius = Self.litHaloRadius
    seg.halo.opacity = 0
    layer?.addSublayer(seg.halo)
    layer?.addSublayer(seg.glow)
    layer?.addSublayer(seg.bar)
    segments[id] = seg
    return seg
  }

  private func color(_ state: LineState) -> NSColor {
    func rgb(_ hex: UInt32) -> NSColor {
      let c = StatusPalette.components(hex)
      return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    switch state {
    case .working: return rgb(colors.working)
    case .needs: return rgb(colors.needs)
    case .done: return rgb(colors.done)
    case .error: return rgb(colors.error)
    // Plain white: the faintness comes from the bar's opacity (`StatusPalette.lineOpacity`).
    // Putting idleAlpha here too would apply it twice (0.22 x 0.22, an invisible bar).
    case .idle: return NSColor.white
    }
  }

  /// The colorblind palette's error sign: the bar masked into short dashes and the glow cast
  /// from the same dashes (a plain glow would light the gaps), static. Any other state, and
  /// the classic palette (a solid error bar, as originally), removes both.
  private func applyDashes(_ seg: Segment, _ state: LineState) {
    let bounds = seg.bar.bounds
    guard state == .error,
      let pieces = StatusPalette.errorPieces(colors, width: bounds.width, height: bounds.height)
    else {
      seg.bar.mask = nil
      seg.dashMask = nil
      seg.glow.shadowPath = nil
      seg.halo.shadowPath = Self.pill(seg.halo.bounds)
      return
    }
    let mask = seg.dashMask ?? CAShapeLayer()
    seg.dashMask = mask
    seg.bar.mask = mask
    let path = CGMutablePath()
    for r in pieces {
      let radius = min(r.height, r.width) / 2
      path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
    }
    mask.frame = bounds
    mask.path = path
    seg.glow.shadowPath = path
    seg.halo.shadowPath = path
    // The glow's own fill would show through the gaps; only its shadow (shaped by the path) stays.
    seg.glow.backgroundColor = nil
  }

  /// A rounded bar shape filling `rect` (the halo's shadow outside the error dashes).
  private static func pill(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
  }

  private func style(_ seg: Segment, _ state: LineState, arrived: Bool) {
    seg.state = state
    // Only the state's own animations: a running light-up ("lit.*", `light`) keeps going.
    for l in [seg.bar, seg.glow, seg.halo] {
      l.removeAnimation(forKey: "breathe")
      l.removeAnimation(forKey: "flash")
    }
    seg.shine.removeAnimation(forKey: "shimmer")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let c = color(state)
    seg.bar.backgroundColor = c.cgColor
    seg.glow.backgroundColor = c.cgColor
    seg.glow.shadowColor = c.cgColor
    seg.glow.shadowOffset = .zero
    seg.glow.shadowRadius = 4
    seg.glow.shadowOpacity = state == .idle ? 0 : 1
    seg.glow.opacity = state == .idle ? 0 : 0.4
    seg.halo.shadowColor = c.cgColor
    seg.bar.opacity = Float(StatusPalette.lineOpacity(state))
    seg.shine.isHidden = state != .working || reduceMotion
    applyDashes(seg, state)
    CATransaction.commit()
    guard !reduceMotion else { return }
    switch state {
    case .working:
      shimmer(seg, width: seg.bar.bounds.width)
    case .needs:
      for l in [seg.bar, seg.glow] {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = l === seg.bar ? 1.0 : 0.4
        breathe.toValue = l === seg.bar ? 0.55 : 0.12
        breathe.duration = 1.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(breathe, forKey: "breathe")
      }
      // The halo (seen only while lit) breathes with them, as deep as the glow (to 0.3 of
      // itself), so a lit bar keeps its pulse. Its `opacity` stays free for lighting up.
      let breathe = CABasicAnimation(keyPath: "shadowOpacity")
      breathe.fromValue = 1.0
      breathe.toValue = 0.3
      breathe.duration = 1.2
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      seg.halo.add(breathe, forKey: "breathe")
    case .done where arrived:
      let flash = CAKeyframeAnimation(keyPath: "opacity")
      flash.values = [0.4, 1, 1, 1]
      flash.keyTimes = [0, 0.12, 0.35, 1]
      flash.duration = 0.9
      seg.bar.add(flash, forKey: "flash")
      let bloom = CAKeyframeAnimation(keyPath: "opacity")
      bloom.values = [0.4, 1, 1, 0.4]
      bloom.keyTimes = [0, 0.12, 0.35, 1]
      bloom.duration = 0.9
      seg.glow.add(bloom, forKey: "flash")
      // A segment that finishes while lit flashes through its halo too.
      let halo = CAKeyframeAnimation(keyPath: "shadowOpacity")
      halo.values = flash.values
      halo.keyTimes = flash.keyTimes
      halo.duration = flash.duration
      seg.halo.add(halo, forKey: "flash")
    default:
      break
    }
  }

  /// A highlight crossing the segment once every 1.6 s (constant motion: linear).
  private func shimmer(_ seg: Segment, width w: CGFloat) {
    guard w > 0 else { return }
    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = -Double(w)
    sweep.toValue = Double(w)
    sweep.duration = 1.6
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .linear)
    seg.shine.add(sweep, forKey: "shimmer")
    seg.shine.setValue(w, forKey: "sweepWidth")
  }

  /// Lays the segments out. Those in `animating` just lit up or went dark: they move to their
  /// new height and halo (`light`); the rest are set at once.
  private func place(animating: Set<String> = []) {
    let n = order.count
    guard n > 0 else { return }
    let gap = NotchMetrics.lineSegmentGap
    let w = max(1, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
    let h = NotchMetrics.lineHeight
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (i, item) in order.enumerated() {
      guard let seg = segments[item.sessionID] else { continue }
      let height = seg.lit ? h + Self.litLift : h
      let frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: height)
      let halo: Float = seg.lit ? (seg.state == .idle ? Self.litIdleHalo : Self.litHalo) : 0
      if animating.contains(item.sessionID) {
        light(seg, frame: frame, halo: halo)
      } else {
        for l in [seg.bar, seg.glow] {
          l.frame = frame
          l.cornerRadius = height / 2
        }
        seg.halo.opacity = halo
      }
      // The halo takes its new shape at once: it only fades (`light`), and 1.5 pt under a
      // 3 pt blur does not show.
      seg.halo.frame = frame
      seg.halo.shadowPath = Self.pill(seg.halo.bounds)
      // Tall enough for the lit height; the bar clips it.
      seg.shine.frame = CGRect(x: 0, y: 0, width: w, height: h + Self.litLift)
      if seg.state == .error, colors.errorDashed { applyDashes(seg, .error) }
      if seg.state == .working, !reduceMotion,
        (seg.shine.value(forKey: "sweepWidth") as? CGFloat) != w
      {
        shimmer(seg, width: w)
      }
    }
    CATransaction.commit()
  }

  /// A segment lighting up (or going dark): its bar and glow take `frame` (taller or back)
  /// and the halo `halo` opacity (`place` sets the halo's shape). Each animation starts from
  /// what is on screen now, so a wing that changes mid-way turns back without a jump. Lighting
  /// up uses `litIn`, going dark `litOut`; with Reduce Motion the height is set at once and
  /// only the halo fades.
  private func light(_ seg: Segment, frame: CGRect, halo: Float) {
    let up = seg.lit
    let timing = reduceMotion ? Self.litFade : (up ? Self.litIn : Self.litOut)
    func animate(_ l: CALayer, _ key: String, from: Any?) {
      guard let from else { return }
      let a = CABasicAnimation(keyPath: key)
      a.fromValue = from
      a.duration = timing.duration
      a.timingFunction = timing.curve
      l.add(a, forKey: "lit.\(key)")
    }
    for l in [seg.bar, seg.glow] {
      let now = l.presentation() ?? l
      let (bounds, position, radius) = (now.bounds, now.position, now.cornerRadius)
      l.frame = frame
      l.cornerRadius = frame.height / 2
      guard !reduceMotion else { continue }
      animate(l, "bounds", from: NSValue(rect: bounds))
      animate(l, "position", from: NSValue(point: position))
      animate(l, "cornerRadius", from: radius)
    }
    let from = (seg.halo.presentation() ?? seg.halo).opacity
    seg.halo.opacity = halo
    animate(seg.halo, "opacity", from: from)
  }
}

// MARK: - Content entrance

/// Opacity + scale 0.97 -> 1 + blur 6 -> 0 (strong ease-out), once the shape is ~60% there,
/// staggered 30 ms. Reduce motion: a plain crossfade.
struct NotchEnter: ViewModifier {
  let index: Int
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let curve = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.3)

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
      .blur(radius: shown || reduceMotion ? 0 : 6)
      .onAppear {
        let delay = Motion.contentDelay + Double(index) * Motion.stagger
        let anim = reduceMotion ? Motion.crossfade : Self.curve.delay(delay)
        withAnimation(anim) { shown = true }
      }
  }
}

extension View {
  func notchEnter(_ index: Int) -> some View { modifier(NotchEnter(index: index)) }

  /// Reports the view's own height whenever it changes. Measured on the body view itself, not
  /// on a wrapper around the mode switch: a wrapper's geometry callback was seen to miss a
  /// later growth of the expanded body (rows measured after the first layout), which left the
  /// island shorter than its content and clipped the last row.
  func measuredHeight(_ report: @escaping @MainActor (CGFloat) -> Void) -> some View {
    onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
  }
}
