import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the menu bar around the notch.
final class NotchPanel: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    becomesKeyOnlyIfNeeded = true
    isFloatingPanel = true
    // Must come after isFloatingPanel, which resets the level to .floating.
    level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    hidesOnDeactivate = false
    isMovable = false
    acceptsMouseMovedEvents = true
    animationBehavior = .none
    isReleasedWhenClosed = false
  }

  override var canBecomeKey: Bool { true }
  var onResignKey: (@MainActor () -> Void)?

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
  override var canBecomeMain: Bool { false }

  /// Do not let AppKit push the window below the menu bar.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Hosting view that reacts to the first click, forwards right-clicks and reports pointer
/// moves over the panel (while it takes clicks, the global monitor no longer sees them).
final class NotchHostingView: NSHostingView<NotchRootView> {
  var onRightClick: (@MainActor () -> Void)?
  var onPointerMoved: (@MainActor () -> Void)?
  private var pointerArea: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    guard pointerArea == nil else { return }
    // .activeAlways: the panel is never key in normal use and the app is an accessory.
    let area = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    pointerArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    onPointerMoved?()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    onPointerMoved?()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onPointerMoved?()
  }

  override func rightMouseDown(with event: NSEvent) {
    onRightClick?()
  }

  override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}
