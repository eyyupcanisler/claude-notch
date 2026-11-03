import AppKit
import ClaudeNotchCore
import SwiftUI

enum DecisionSource: Sendable {
  case click
  /// Peek button: only for a request whose whole text the peek shows (`fitsPeek`).
  case peek
  case key
  /// Hold-to-allow completed on the panel's card.
  case hold
  /// Hold-to-allow completed on the peek (peek rules and hold rules both apply).
  case peekHold
  /// Global shortcut (⌃⌥Y / ⌃⌥N): only on the request on screen, peek rules when in the peek.
  case global
  /// Global allow shortcut held for the hold time on a risky request.
  case globalHold

  var fromPeek: Bool { self == .peek || self == .peekHold }
  var isHold: Bool { self == .hold || self == .peekHold || self == .globalHold }
  var isGlobal: Bool { self == .global || self == .globalHold }
}

struct NotchActions {
  var decide: @MainActor (String, PermissionDecision, DecisionSource) -> Void = { _, _, _ in }
  var toggleDetail: @MainActor (String) -> Void = { _ in }
  /// The opened card's text was on screen down to its end (card id, trigger).
  var readToEnd: @MainActor (String, String) -> Void = { _, _ in }
  /// The card's "Her zaman" rule was on screen down to its end (card id, trigger).
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
  /// Selects the oldest card (the "N izin" chip).
  var showCards: @MainActor () -> Void = {}
  var bodyHeight: @MainActor (CGDirectDisplayID, NotchMode, CGFloat) -> Void = { _, _, _ in }
  /// Ghostty Automation: ask (macOS prompt) or open System Settings when denied.
  var ghosttyConsent: @MainActor () -> Void = {}
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
  let surface: SurfaceState
  let actions: NotchActions

  private var theme: NotchTheme { settings.tokens }
  private var mode: NotchMode { surface.mode }
  private var g: NotchGeometry { surface.geometry }

  var body: some View {
    let island = NotchMetrics.island(
      mode, geometry: g, body: surface.bodyHeight, peekWidth: surface.peekWidth)
    let shape = IslandShape(island, band: g.bandHeight)
    let segments = store.statusLine
    // A hidden synthetic pill draws nothing; the hardware notch is black anyway (the collapsed
    // shape stays inside the camera housing).
    let drawn = surface.visible && (g.hasNotch || mode != .collapsed || !segments.isEmpty)
    let windowW = NotchMetrics.windowWidth(screen: g.screenFrame.width)
    ZStack(alignment: .top) {
      NotchBackground(mode: mode, theme: theme, band: g.toolbarHeight)
        .clipShape(shape)
        .opacity(drawn ? 1 : 0)
      VStack(spacing: 0) {
        bandRow(island)
          .frame(width: island.topWidth, height: mode == .expanded ? g.toolbarHeight : g.bandHeight)
        bodyContent
          .frame(width: island.bodyWidth)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: windowW, height: NotchMetrics.windowHeight, alignment: .top)
      .clipShape(shape)
      StatusLineView(segments: segments)
        .frame(width: NotchMetrics.lineWidth(notch: g.notchWidth), height: NotchMetrics.lineHeight)
        .padding(.top, g.notchHeight + NotchMetrics.lineGap)
        .opacity(mode == .collapsed && surface.visible && !segments.isEmpty ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      if mode == .collapsed {
        // The notch and the line open the panel on click (clicking never makes it key).
        Color.clear
          .frame(width: g.notchWidth, height: NotchMetrics.lineZoneDepth(g))
          .contentShape(Rectangle())
          .onTapGesture { actions.expand(g.displayID) }
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { actions.expand(g.displayID) }
      }
    }
    .environment(\.notchTheme, theme)
    .frame(width: windowW, height: NotchMetrics.windowHeight, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(NotchSignals(store: store).accessibilityText)
  }

  @ViewBuilder
  private func bandRow(_ island: IslandGeometry) -> some View {
    if mode == .expanded {
      ExpandedToolbar(
        store: store, ui: ui, actions: actions, notchWidth: g.notchWidth,
        sideWidth: max(0, (island.topWidth - g.notchWidth) / 2))
        .transition(.opacity.animation(Motion.contentOut))
    } else {
      Color.clear
    }
  }

  @ViewBuilder
  private var bodyContent: some View {
    switch mode {
    case .collapsed:
      Color.clear.frame(height: 0)
    case .peek:
      if let peek = ui.peek {
        PeekBody(store: store, ui: ui, peek: peek, displayID: g.displayID, actions: actions)
          .measuredHeight { actions.bodyHeight(g.displayID, .peek, $0) }
          .transition(.opacity.animation(Motion.contentOut))
      }
    case .expanded:
      ExpandedBody(
        store: store, ui: ui, settings: settings, actions: actions, bandHeight: g.toolbarHeight)
        .measuredHeight { actions.bodyHeight(g.displayID, .expanded, $0) }
        .transition(.opacity.animation(Motion.contentOut))
    }
  }
}

/// Solid black in every mode (the "Gösterge" look: the hardware notch simply grows). The open
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
    if working > 0 { parts.append("\(working) oturum çalışıyor") }
    let perms = store.pending.count
    if perms > 0 { parts.append("\(perms) izin bekliyor") }
    let cardSessions = Set(store.pending.map(\.sessionID))
    let others = store.sessions.values.filter { s in
      guard !cardSessions.contains(s.id) else { return false }
      switch s.status {
      case .question, .planApproval, .waitingInput: return true
      default: return false
      }
    }.count
    if others > 0 { parts.append("\(others) oturum yanıt bekliyor") }
    if errorCount > 0 { parts.append("\(errorCount) hata") }
    if store.doneUnseenCount > 0 { parts.append("\(store.doneUnseenCount) oturum bitti") }
    return parts.isEmpty ? "Claude: etkin oturum yok" : "Claude: " + parts.joined(separator: ", ")
  }
}

// MARK: - Status line

/// The only persistent visual: a 3 pt line under the notch, one segment per session (creation
/// order), each colored by its state. Core Animation runs the shimmer / breathing / flash in
/// the render server, so an always-on line costs the app no frames.
struct StatusLineView: NSViewRepresentable {
  let segments: [LineSegment]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> StatusLineLayerView { StatusLineLayerView() }

  func updateNSView(_ view: StatusLineLayerView, context: Context) {
    view.update(segments, reduceMotion: reduceMotion)
  }
}

@MainActor
final class StatusLineLayerView: NSView {
  private final class Segment {
    let glow = CALayer()
    let bar = CALayer()
    let shine = CAGradientLayer()
    var state: LineState?
  }

  private var segments: [String: Segment] = [:]
  private var order: [LineSegment] = []
  private var reduceMotion = false

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

  func update(_ list: [LineSegment], reduceMotion: Bool) {
    let motionChanged = reduceMotion != self.reduceMotion
    self.reduceMotion = reduceMotion
    order = list
    let ids = Set(list.map(\.sessionID))
    for (id, seg) in segments where !ids.contains(id) {
      seg.glow.removeFromSuperlayer()
      seg.bar.removeFromSuperlayer()
      segments.removeValue(forKey: id)
    }
    for item in list {
      let seg = segments[item.sessionID] ?? makeSegment(item.sessionID)
      if seg.state != item.state || motionChanged {
        let arrived = seg.state != nil && seg.state != item.state
        style(seg, item.state, arrived: arrived || seg.state == nil)
      }
    }
    place()
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
    layer?.addSublayer(seg.glow)
    layer?.addSublayer(seg.bar)
    segments[id] = seg
    return seg
  }

  private func color(_ state: LineState) -> NSColor {
    switch state {
    case .working:
      return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    case .needs: return NSColor(srgbRed: 1, green: 0xB0 / 255, blue: 0x20 / 255, alpha: 1)
    case .done: return NSColor(srgbRed: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, alpha: 1)
    case .error: return NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    case .idle: return NSColor.white.withAlphaComponent(0.22)
    }
  }

  private func style(_ seg: Segment, _ state: LineState, arrived: Bool) {
    seg.state = state
    for l in [seg.bar, seg.glow, seg.shine] { l.removeAllAnimations() }
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
    seg.bar.opacity = state == .done ? 0.7 : 1
    seg.shine.isHidden = state != .working || reduceMotion
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
    case .done where arrived:
      let flash = CAKeyframeAnimation(keyPath: "opacity")
      flash.values = [0.7, 1, 1, 0.7]
      flash.keyTimes = [0, 0.12, 0.35, 1]
      flash.duration = 0.9
      seg.bar.add(flash, forKey: "flash")
      let bloom = CAKeyframeAnimation(keyPath: "opacity")
      bloom.values = [0.4, 1, 1, 0.4]
      bloom.keyTimes = [0, 0.12, 0.35, 1]
      bloom.duration = 0.9
      seg.glow.add(bloom, forKey: "flash")
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

  private func place() {
    let n = order.count
    guard n > 0 else { return }
    let gap = NotchMetrics.lineSegmentGap
    let w = max(1, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
    let h = NotchMetrics.lineHeight
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (i, item) in order.enumerated() {
      guard let seg = segments[item.sessionID] else { continue }
      let frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
      seg.bar.frame = frame
      seg.glow.frame = frame
      seg.shine.frame = CGRect(x: 0, y: 0, width: w, height: h)
      if seg.state == .working, !reduceMotion,
        (seg.shine.value(forKey: "sweepWidth") as? CGFloat) != w
      {
        shimmer(seg, width: w)
      }
    }
    CATransaction.commit()
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
