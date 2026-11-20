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
      state.mode, geometry: state.geometry, body: state.bodyHeight, wingSide: state.wingSide)
  }

  /// Draws or reacts to anything at all (a hidden synthetic pill does not).
  func isLive(
    hasSessions: Bool, pill: Bool = false, ears: Bool = false, timerEar: CGFloat = 0
  ) -> Bool {
    let g = state.geometry
    guard state.visible else { return false }
    return g.hasNotch || state.mode != .collapsed || hasSessions || pill || ears || timerEar > 0
  }

  /// Screen rectangles that take the pointer (Cocoa, y-up): the notch plus the status line while
  /// collapsed, the drawn wings (band height only) plus that same notch zone in peek mode, the
  /// whole panel when expanded. Never the menu-bar band beside the notch outside what is drawn,
  /// and in peek mode nothing below the band except the status line under the notch.
  /// `timerEar`: width of the timer's ear right of the notch (0: none, see
  /// `ModuleCenter.timerEar`); it takes clicks while collapsed, and in peek mode beside the
  /// wings' small mark.
  func hitRects(
    hasSessions: Bool, pill: Bool = false, ears: Bool = false, fullEars: Bool = true,
    timerEar: CGFloat = 0
  ) -> [NSRect] {
    guard isLive(hasSessions: hasSessions, pill: pill, ears: ears, timerEar: timerEar)
    else { return [] }
    let g = state.geometry
    let top = g.screenFrame.maxY
    let cx = g.screenFrame.midX
    let i = island
    let h = g.bandHeight
    switch state.mode {
    case .collapsed:
      let depth = NotchMetrics.collapsedDepth(g, sessions: hasSessions, pill: pill)
      let notch = TopEdgeRect.hanging(minX: cx - g.notchWidth / 2, width: g.notchWidth, top: top, depth: depth)
      var rects = [notch]
      // The ears take clicks too (they cover the menu bar there anyway).
      let w = NotchMetrics.earWidth(full: fullEars)
      if ears {
        rects.append(TopEdgeRect.hanging(minX: cx - g.notchWidth / 2 - w, width: w, top: top, depth: h))
      }
      if timerEar > 0 {
        rects.append(
          TopEdgeRect.hanging(
            minX: cx + g.notchWidth / 2, width: timerEar, top: top,
            depth: NotchMetrics.timerEarHeight(g)))
      } else if ears {
        rects.append(TopEdgeRect.hanging(minX: cx + g.notchWidth / 2, width: w, top: top, depth: h))
      }
      return rects
    case .peek:
      let wings = TopEdgeRect.hanging(minX: cx - i.topWidth / 2, width: i.topWidth, top: top, depth: i.height)
      // The status line (and timer extension) under the notch still hovers / clicks.
      let depth = NotchMetrics.collapsedDepth(g, sessions: hasSessions, pill: pill)
      let notch = TopEdgeRect.hanging(minX: cx - g.notchWidth / 2, width: g.notchWidth, top: top, depth: depth)
      // The timer's ear beside the right mark (not while the wings' text is out).
      if timerEar > 0, state.wingSide <= WingMetrics.markWidth + 0.5 {
        let ear = TopEdgeRect.hanging(
          minX: cx + g.notchWidth / 2 + state.wingSide, width: timerEar, top: top,
          depth: NotchMetrics.timerEarHeight(g))
        return [wings, notch, ear]
      }
      return [wings, notch]
    case .expanded:
      let w = i.topWidth + i.shoulder * 2
      return [TopEdgeRect.hanging(minX: cx - w / 2, width: w, top: top, depth: i.height)]
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
