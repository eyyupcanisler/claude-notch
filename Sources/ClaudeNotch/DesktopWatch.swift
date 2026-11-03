import AppKit
import Observation

/// "The menu bar has room for the full ears": the desktop is in front (Finder active, none of
/// its windows on screen) or the active app is full screen (its menu bar is hidden). Re-checked
/// on every app or Space switch, and every 2 s only while Finder is active (a Finder window can
/// open or close without a switch). Window bounds and owners need no permission.
@MainActor
@Observable
final class DesktopWatch {
  private(set) var isRoomy = false
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var poll: Timer?

  @ObservationIgnored private var spaceObserver: NSObjectProtocol?

  init() {
    let nc = NSWorkspace.shared.notificationCenter
    observer = nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.check() }
    }
    spaceObserver = nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // The full-screen window settles a moment after the Space switch.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        self?.check()
      }
    }
    check()
  }

  private func check() {
    let front = NSWorkspace.shared.frontmostApplication
    let finderFront = front?.bundleIdentifier == "com.apple.finder"
    let windows = Self.windows()
    let desktop = finderFront && !windows.contains { $0.owner == "Finder" && $0.height > 60 }
    let screen = NSScreen.screens.first?.frame.size ?? .zero
    let fullScreen = windows.contains { w in
      w.pid == front?.processIdentifier && abs(w.width - screen.width) < 1
        && abs(w.height - screen.height) < 1
    }
    let now = desktop || fullScreen
    if now != isRoomy { isRoomy = now }
    if finderFront, poll == nil {
      poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.check() }
      }
    } else if !finderFront {
      poll?.invalidate()
      poll = nil
    }
  }

  private struct Win {
    var owner: String
    var pid: pid_t
    var width: Double
    var height: Double
  }

  /// Normal-level windows on screen (the desktop itself sits below level 0).
  private static func windows() -> [Win] {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { w in
      guard w[kCGWindowLayer as String] as? Int == 0,
        let b = w[kCGWindowBounds as String] as? [String: Any]
      else { return nil }
      return Win(
        owner: w[kCGWindowOwnerName as String] as? String ?? "",
        pid: (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
        width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
    }
  }
}
