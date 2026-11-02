import AppKit

extension NSScreen {
  var displayID: CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
  }

  var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }

  /// Built-in screen with a camera housing.
  var hasNotch: Bool { safeAreaInsets.top > 0 }
}

/// Where the notch (or the synthetic pill) is and how large it is, for one screen.
struct NotchGeometry: Equatable {
  var displayID: CGDirectDisplayID
  var screenFrame: CGRect
  var notchWidth: CGFloat
  var notchHeight: CGFloat
  var hasNotch: Bool
  /// Height of the menu-bar band (at least the notch; the menu bar can be a point taller).
  /// The island keeps to the notch's width inside it and only flares out below it.
  var bandHeight: CGFloat

  /// Width of the synthetic notch on a screen without one (a black pill, same model).
  static let syntheticGap: CGFloat = 180

  @MainActor
  static func make(for screen: NSScreen) -> NotchGeometry {
    let frame = screen.frame
    // Real menu bar height (0 when the menu bar auto-hides).
    let bar = frame.maxY - screen.visibleFrame.maxY
    if screen.hasNotch {
      var width: CGFloat = 180
      if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
        width = max(right.minX - left.maxX, 100)
      }
      let notch = screen.safeAreaInsets.top
      return NotchGeometry(
        displayID: screen.displayID, screenFrame: frame, notchWidth: width,
        notchHeight: notch, hasNotch: true,
        bandHeight: bar > notch && bar <= notch + 8 ? bar : notch)
    }
    // No visible menu bar (auto-hide, a full-screen app): no pill over the app's content, the
    // status line and the island hang from the top edge itself.
    let height = bar >= 18 && bar <= 44 ? bar : 0
    return NotchGeometry(
      displayID: screen.displayID, screenFrame: frame, notchWidth: syntheticGap,
      notchHeight: height, hasNotch: false, bandHeight: height)
  }

  /// Height of the toolbar row of the expanded panel (the band, or a row of its own when the
  /// screen shows no menu bar).
  var toolbarHeight: CGFloat { max(bandHeight, 28) }

  static let placeholder = NotchGeometry(
    displayID: 0, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), notchWidth: 180,
    notchHeight: 32, hasNotch: true, bandHeight: 32)
}

/// Which screen the user is working on: the screen holding the frontmost app's frontmost
/// window (CGWindowList bounds need no permission), else the screen under the pointer.
@MainActor
enum ActiveScreen {
  static func current() -> NSScreen? {
    let screens = NSScreen.screens
    guard screens.count > 1 else { return screens.first }
    if let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let rect = frontWindowRect(pid: app.processIdentifier),
      let best = screens.max(by: { overlap($0.frame, rect) < overlap($1.frame, rect) }),
      overlap(best.frame, rect) > 0
    {
      return best
    }
    let m = NSEvent.mouseLocation
    return screens.first { NSMouseInRect(m, $0.frame, false) } ?? screens.first
  }

  private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let r = a.intersection(b)
    return r.isNull ? 0 : r.width * r.height
  }

  /// Frontmost normal-layer window of `pid`, in Cocoa coordinates.
  private static func frontWindowRect(pid: pid_t) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return nil }
    for w in list {
      guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
        (w[kCGWindowLayer as String] as? Int) == 0,
        let b = w[kCGWindowBounds as String] as? [String: CGFloat],
        let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
        width >= 80, height >= 60
      else { continue }
      return CGRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
    }
    return nil
  }
}
