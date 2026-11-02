import Foundation

/// What made a scrollable text (an opened request, a long "Her zaman" rule) check whether its
/// end is on screen.
public enum ReadTrigger: String, Sendable {
  /// After a SwiftUI update / a frame change of the text's scroll view.
  case layout
  /// The clip view's bounds changed (wheel, trackpad, scroller, Space paging).
  case scroll
}

/// When a scrollable text counts as read down to its end. Pure: the view passes measurements
/// and the trigger, nothing here reads live view state.
///
/// - `contentHeight` is the laid-out text height from the layout manager, `nil` while it can
///   not be measured (no width yet, container width not equal to the visible width, empty
///   text). A re-render with a stale or zero document frame therefore never counts.
/// - `.layout` counts only when the whole text fits (in the visible part and in `maxHeight`)
///   and the view sits at its top: the text is on screen without scrolling.
/// - `.scroll` counts only when the scroll offset actually changed, the text is taller than
///   the visible part, and the bottom of the text is inside the visible part.
public enum ReadProgress {
  public static func reachedEnd(
    contentHeight: Double?, visibleMinY: Double, visibleHeight: Double, maxHeight: Double,
    trigger: ReadTrigger, originChanged: Bool
  ) -> Bool {
    guard let height = contentHeight, height > 0, visibleHeight > 1 else { return false }
    switch trigger {
    case .layout:
      return visibleMinY <= 0.5 && height <= min(visibleHeight, maxHeight) + 1
    case .scroll:
      return originChanged && height > visibleHeight + 1
        && visibleMinY + visibleHeight >= height - 2
    }
  }
}

/// One text's read state: latches once its end has been on screen (`ReadProgress`), and works
/// out from successive observations whether the scroll offset really changed.
public struct ReadTracker: Sendable, Equatable {
  public private(set) var reported = false
  public private(set) var trigger: ReadTrigger?
  private var lastMinY: Double = 0

  public init() {}

  /// Feeds one observation; returns true exactly once, when the end is first seen.
  public mutating func observe(
    _ trigger: ReadTrigger, contentHeight: Double?, visibleMinY: Double, visibleHeight: Double,
    maxHeight: Double
  ) -> Bool {
    let changed = abs(visibleMinY - lastMinY) > 0.5
    lastMinY = visibleMinY
    guard !reported else { return false }
    guard ReadProgress.reachedEnd(
      contentHeight: contentHeight, visibleMinY: visibleMinY, visibleHeight: visibleHeight,
      maxHeight: maxHeight, trigger: trigger, originChanged: changed)
    else { return false }
    reported = true
    self.trigger = trigger
    return true
  }

  /// The text changed (and the view went back to its top).
  public mutating func reset() {
    self = ReadTracker()
  }
}
