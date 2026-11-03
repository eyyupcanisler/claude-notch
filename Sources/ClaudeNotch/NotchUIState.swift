import AppKit
import ClaudeNotchCore
import Observation
import SwiftUI

/// The three shapes: collapsed (exactly the notch, plus the status line while sessions exist),
/// peek (an island dropping out of the notch) and the expanded panel.
enum NotchMode: String, Sendable {
  case collapsed
  case peek
  case expanded
}

/// View state shared by every surface (one per screen).
@MainActor
@Observable
final class NotchUIState {
  /// Live activity shown on the active surface (nil: none).
  var peek: PeekItem?
  /// Keeps the expanded panel open (header pin).
  var pinned = false
  /// The panel is key (opened with the hotkey): keyboard shortcuts apply.
  var keyMode = false
  var selectedCardID: String?
  var selectedSessionID: String?
  /// Session order captured when the pointer entered the panel (no reordering under it).
  var frozenOrder: [String]?
  /// Sessions drawn as rich (needs-you) rows at freeze time: a session that starts or stops
  /// needing the user while the pointer is over the list keeps its row shape.
  var frozenRich: Set<String> = []
  /// No card was pending at freeze time: a new card does not push the list down under the
  /// pointer (the "N izin" chip shows it instead).
  var slotFrozenEmpty = false
  /// Card ids whose full text the user opened (allowing a long request needs that first).
  var openedCards: Set<String> = []
  /// Card whose ⋯ section ("Her zaman" rule) is open.
  var moreCardID: String?
  /// "Her zaman" (click or ⌘⇧⏎) is accepted from then on: the rule it adds must have been on
  /// screen for a moment.
  var moreArmedAt = Date.distantPast
  /// Opened cards whose full text was scrolled to its end (allowing a long request needs it).
  var readToEnd: Set<String> = []
  /// Page-down requests for an opened card's text (Space while it is not read to the end).
  var detailPage: [String: Int] = [:]
  /// Cards whose "Her zaman" rule has been on screen down to its end (saving it needs that).
  var ruleRead: Set<String> = []
  /// Page-down requests for a card's rule text (Space while the rule is not read).
  var rulePage: [String: Int] = [:]
  /// Debug: what saw the end of a text ("text:<id>" / "rule:<id>" -> "layout" / "scroll").
  var readTrigger: [String: String] = [:]
  /// Shown under the header after a failed jump to a terminal (e.g. Automation not allowed).
  var focusHint: String?
  /// Bumped when a card becomes clickable (time passing is not observable by itself).
  var tick = Date()
  /// Card buttons ignore input until then (after a pager change: the card under the pointer
  /// changed).
  var pagerArmedAt = Date.distantPast
  /// Keyboard decisions are accepted from then on (the panel must have been visible a moment).
  var keysArmedAt = Date.distantPast
  /// Hold-to-allow progress (0...1) of the card held with the global allow shortcut.
  var holdProgress: [String: Double] = [:]
  /// Card whose hold runs with the global allow shortcut (label "Tutun…", set without motion).
  var keyHoldCardID: String?
  /// A tap (not a hold) of the global allow shortcut on this risky card: "Basılı tutun".
  var holdHintCardID: String?
  /// The panel was opened by a global shortcut (full text of a request) while the pointer was
  /// elsewhere: it stays open until the pointer has been over it, a decision, or the peek time.
  var shortcutOpen = false
  /// Keycaps of the registered global shortcuts ("⌃⌥Y"), nil when not registered.
  var allowKey: String?
  var denyKey: String?
  /// One-time line under the permission peek ("⌃⌥Y izin ver · ⌃⌥N reddet"), nil once used.
  var shortcutHint: String?
  /// Last known Automation status towards Ghostty (see `GhosttyConsent`).
  var ghosttyAutomation: Int32?
  /// A consent request is on screen (the macOS prompt waits for the user).
  var consentAsking = false

  var ghosttyConsent: GhosttyConsent { GhosttyConsent(status: ghosttyAutomation) }
}

/// Automation (Apple Events) permission towards Ghostty, from
/// `AEDeterminePermissionToAutomateTarget`.
enum GhosttyConsent: Equatable {
  case granted
  /// -1744: macOS would ask.
  case notDetermined
  /// -1743: the user said no; only System Settings can change it.
  case denied
  /// Not checked yet, or Ghostty not running (-600).
  case unknown

  init(status: Int32?) {
    switch status {
    case 0: self = .granted
    case -1744: self = .notDetermined
    case -1743: self = .denied
    default: self = .unknown
    }
  }

  /// The band icon / menu item is offered.
  var missing: Bool { self == .notDetermined || self == .denied }

  static let settingsURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

/// Per-screen state.
@MainActor
@Observable
final class SurfaceState {
  var geometry: NotchGeometry
  var mode: NotchMode = .collapsed
  /// Built-in notch surface (full UI) or a synthetic pill on another screen.
  var isPrimary: Bool
  /// Measured height of the content under the band, per mode.
  var bodyHeight: [NotchMode: CGFloat] = [.peek: 52, .expanded: 220]
  /// Island width of the current peek (one line for done / error, two lines for a card).
  var peekWidth: CGFloat = NotchMetrics.finishedWidth
  /// The pill is shown at all (a synthetic pill with nothing to show is hidden).
  var visible = true

  init(geometry: NotchGeometry, isPrimary: Bool) {
    self.geometry = geometry
    self.isPrimary = isPrimary
  }
}

/// Target outline of the island: the band part (notch height) and the body under it.
struct IslandGeometry: Equatable {
  /// Width inside the menu-bar band (notch width, or the whole panel when expanded).
  var topWidth: CGFloat
  /// Width under the band.
  var bodyWidth: CGFloat
  /// Total height from the top of the screen.
  var height: CGFloat
  /// Concave shoulders where an expanded panel meets the top edge of the screen.
  var shoulder: CGFloat
  var bottomRadius: CGFloat
}

enum NotchMetrics {
  /// Status line: inset from each notch edge, gap under the notch, thickness, segment gap.
  static let lineInset: CGFloat = 24
  static let lineGap: CGFloat = 2
  static let lineHeight: CGFloat = 3
  static let lineSegmentGap: CGFloat = 3
  /// Hover / click slack under the line.
  static let lineHitSlack: CGFloat = 5
  /// Spotify ears beside the notch (collapsed, while playing): width of each.
  static let earWidth: CGFloat = 34
  /// Tucked ears (another app in front): only this much of the cover peeks out of the notch.
  static let thinEarWidth: CGFloat = 7

  static func earWidth(full: Bool) -> CGFloat { full ? earWidth : thinEarWidth }

  /// Running timer (collapsed only): the notch grows down by this much, the time inside.
  static let pillHeight: CGFloat = 22
  /// Done / error peek: one line.
  static let finishedWidth: CGFloat = 300
  static let moduleWidth: CGFloat = 340
  /// Permission / question peek: two lines and compact buttons.
  static let permissionMinWidth: CGFloat = 380
  static let peekPadding: CGFloat = 14
  static let expandedWidth: CGFloat = 600
  static let maxHeight: CGFloat = 560
  static let windowWidth: CGFloat = 660
  static let windowHeight: CGFloat = 600
  /// Concave fillet where the island flares out of the notch-wide band.
  static let fillet: CGFloat = 8
  /// Convex top-outer corner of the island under the band.
  static let islandTopRadius: CGFloat = 10
  static let expandedShoulder: CGFloat = 10
  /// Height of the black-to-material blend under the band (expanded).
  static let bandBlend: CGFloat = 24

  /// Window width on a screen (never wider than the screen).
  static func windowWidth(screen: CGFloat) -> CGFloat { min(windowWidth, screen) }

  /// Expanded panel width, clamped to the screen with a margin.
  static func expandedWidth(screen: CGFloat) -> CGFloat {
    max(320, min(expandedWidth, screen - 2 * (expandedShoulder + 12)))
  }

  /// A permission peek wide enough for `PendingPermission.peekLimit` monospaced columns.
  @MainActor
  static let permissionWidth: CGFloat = {
    let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    let text = ceil(advance * CGFloat(PendingPermission.peekLimit)) + 4
    return max(permissionMinWidth, text + peekPadding * 2)
  }()

  /// Status line width (notch minus the insets; never negative).
  static func lineWidth(notch: CGFloat) -> CGFloat { max(24, notch - lineInset * 2) }

  /// Bottom of the hover / click zone under the notch, measured from the top of the screen.
  static func lineZoneDepth(_ g: NotchGeometry) -> CGFloat {
    g.notchHeight + lineGap + lineHeight + lineHitSlack
  }

  /// The extension starts this far up inside the notch, so its straight sides cover the
  /// notch's rounded bottom corners (no step where the two meet).
  static let pillOverlap: CGFloat = 12

  /// Top of the timer extension view (hidden part included).
  static func pillTop(_ g: NotchGeometry) -> CGFloat { g.notchHeight - pillOverlap }

  /// Top of the status line: under the notch, or under the timer extension.
  static func lineTop(_ g: NotchGeometry, pill: Bool) -> CGFloat {
    g.notchHeight + (pill ? pillHeight - 2 : 0) + lineGap
  }

  /// Hover / click zone while the timer extension shows (notch, extension and line).
  static func pillZoneDepth(_ g: NotchGeometry) -> CGFloat {
    lineTop(g, pill: true) + lineHeight + lineHitSlack
  }

  /// Depth of the collapsed hover / click zone.
  static func collapsedDepth(_ g: NotchGeometry, sessions: Bool, pill: Bool) -> CGFloat {
    if pill { return pillZoneDepth(g) }
    return sessions ? lineZoneDepth(g) : g.notchHeight
  }

  @MainActor
  static func island(
    _ mode: NotchMode, geometry g: NotchGeometry, body: [NotchMode: CGFloat], peekWidth: CGFloat
  ) -> IslandGeometry {
    switch mode {
    case .collapsed:
      // On the hardware notch the collapsed shape stays a point inside the camera housing
      // (invisible); the synthetic pill is drawn at full size.
      let inset: CGFloat = g.hasNotch ? 1 : 0
      return IslandGeometry(
        topWidth: g.notchWidth - inset * 2, bodyWidth: g.notchWidth - inset * 2,
        height: g.notchHeight - inset, shoulder: 0,
        bottomRadius: g.hasNotch ? 10 : min(10, g.notchHeight / 2))
    case .peek:
      return IslandGeometry(
        topWidth: g.notchWidth, bodyWidth: max(g.notchWidth, peekWidth),
        height: g.bandHeight + (body[.peek] ?? 52), shoulder: 0, bottomRadius: 20)
    case .expanded:
      let w = expandedWidth(screen: g.screenFrame.width)
      let h = min(g.toolbarHeight + (body[.expanded] ?? 220), maxHeight)
      return IslandGeometry(
        topWidth: w, bodyWidth: w, height: h, shoulder: expandedShoulder, bottomRadius: 24)
    }
  }
}
