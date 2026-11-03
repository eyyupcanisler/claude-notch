import AppKit
import ClaudeNotchCore

/// One notch UI on one screen: the panel, its hosting view and the hover state over it.
@MainActor
final class NotchSurface {
  let state: SurfaceState
  let panel: NotchPanel
  let hostingView: NotchHostingView
  var intent = HoverIntent()
  /// Pointer position when a peek appeared without a hover: while it has not moved, clicks
  /// pass through (a click aimed at the window below is not eaten).
  var pointerAtAppear: NSPoint?

  var displayID: CGDirectDisplayID { state.geometry.displayID }

  init(geometry: NotchGeometry, isPrimary: Bool, makeRoot: (SurfaceState) -> NotchRootView) {
    state = SurfaceState(geometry: geometry, isPrimary: isPrimary)
    panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10))
    hostingView = NotchHostingView(rootView: makeRoot(state))
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    panel.ignoresMouseEvents = true
    layout(geometry)
    panel.orderFrontRegardless()
  }

  func layout(_ g: NotchGeometry) {
    if state.geometry != g { state.geometry = g }
    let w = NotchMetrics.windowWidth(screen: g.screenFrame.width)
    let h = NotchMetrics.windowHeight
    let frame = NSRect(
      x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    hostingView.frame = NSRect(origin: .zero, size: frame.size)
  }

  /// Target outline of the current mode.
  var island: IslandGeometry {
    NotchMetrics.island(
      state.mode, geometry: state.geometry, body: state.bodyHeight, peekWidth: state.peekWidth)
  }

  /// Draws or reacts to anything at all (a hidden synthetic pill does not).
  func isLive(hasSessions: Bool, pill: Bool = false, ears: Bool = false) -> Bool {
    let g = state.geometry
    guard state.visible else { return false }
    return g.hasNotch || state.mode != .collapsed || hasSessions || pill || ears
  }

  /// Screen rectangles that take the pointer (Cocoa, y-up): the notch-wide band part plus the
  /// island under it, or the notch plus the status line while collapsed. Never the menu-bar
  /// band beside the notch, unless the panel is expanded (it then owns that band).
  func hitRects(
    hasSessions: Bool, pill: Bool = false, ears: Bool = false, fullEars: Bool = true
  ) -> [NSRect] {
    guard isLive(hasSessions: hasSessions, pill: pill, ears: ears) else { return [] }
    let g = state.geometry
    let top = g.screenFrame.maxY
    let cx = g.screenFrame.midX
    let i = island
    switch state.mode {
    case .collapsed:
      let depth = NotchMetrics.collapsedDepth(g, sessions: hasSessions, pill: pill)
      let notch = NSRect(
        x: cx - g.notchWidth / 2, y: top - depth, width: g.notchWidth, height: depth)
      guard ears else { return [notch] }
      // The ears take clicks too (they cover the menu bar there anyway).
      let w = NotchMetrics.earWidth(full: fullEars)
      let h = g.bandHeight
      return [
        notch, NSRect(x: cx - g.notchWidth / 2 - w, y: top - h, width: w, height: h),
        NSRect(x: cx + g.notchWidth / 2, y: top - h, width: w, height: h),
      ]
    case .peek:
      let band = NSRect(
        x: cx - i.topWidth / 2, y: top - g.bandHeight, width: i.topWidth, height: g.bandHeight)
      let body = NSRect(
        x: cx - i.bodyWidth / 2, y: top - i.height, width: i.bodyWidth,
        height: max(0, i.height - g.bandHeight))
      return [band, body]
    case .expanded:
      let w = i.topWidth + i.shoulder * 2
      return [NSRect(x: cx - w / 2, y: top - i.height, width: w, height: i.height)]
    }
  }

  /// Bounding box of `hitRects` (debug `rect`, crop rectangles); empty when nothing is live.
  func boundingRect(hasSessions: Bool) -> NSRect {
    let r = hitRects(hasSessions: hasSessions).reduce(NSRect.null) { $0.union($1) }
    return r.isNull ? .zero : r
  }

  func close() {
    panel.orderOut(nil)
    panel.close()
  }
}
