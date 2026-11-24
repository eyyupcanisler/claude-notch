import Foundation

// Pure rules of the global approve / deny shortcuts (⌃⌥Y / ⌃⌥N by default). The app's
// controller feeds them what is on screen and carries out the action; its single decision path
// re-checks every rule before anything is answered.

/// Which global decision shortcut.
public enum ShortcutKey: String, Sendable, CaseIterable {
  case allow
  case deny
}

public enum ShortcutPhase: String, Sendable {
  case down
  case up
}

/// What a global shortcut press does.
public enum ShortcutAction: Sendable, Equatable {
  case ignore
  /// Nothing was shown: re-open the peek (or the card slot) for this card, decide nothing.
  case reveal(String)
  /// The shown text is not all on screen: open the full view instead of allowing.
  case openFull(String)
  /// The full view is open but not read to the end: scroll one page instead of allowing.
  case pageDown(String)
  /// Risky request: start the hold (the decision comes when the hold completes).
  case holdStart(String)
  /// The allow key came up before the hold completed: only the "Hold" hint.
  case holdCancel(String)
  case allow(String)
  case deny(String)
}

/// The request on screen right now, as the user sees it.
public struct ShownRequest: Sendable, Equatable {
  public var cardID: String
  /// In the peek (one line) rather than in the open panel's card.
  public var inPeek: Bool
  /// The card may be acted on (arm delays after it appeared / after a removal are over).
  public var armed: Bool
  /// Allowing needs a hold (RiskClassifier).
  public var risky: Bool
  /// Every character of the request is visible: the peek's one line is the whole request, or
  /// the panel's card is short enough or its full text was read to the end.
  public var fullyVisible: Bool
  /// Panel only: the full text view is open.
  public var opened: Bool

  public init(
    cardID: String, inPeek: Bool, armed: Bool, risky: Bool, fullyVisible: Bool,
    opened: Bool = false
  ) {
    self.cardID = cardID
    self.inPeek = inPeek
    self.armed = armed
    self.risky = risky
    self.fullyVisible = fullyVisible
    self.opened = opened
  }
}

public enum GlobalShortcutPolicy {
  /// Hold time for a risky request (same as the hold-to-allow button).
  public static let holdDuration: TimeInterval = 0.6

  /// What one fresh (non-repeat) key event does. `shown` is nil when no request is on screen
  /// (the peek went back to the line, or the panel shows no card); `oldestPending` is the card
  /// a first press would reveal; `holding` is the card whose hold is running.
  public static func action(
    key: ShortcutKey, phase: ShortcutPhase, shown: ShownRequest?, oldestPending: String?,
    holding: String?
  ) -> ShortcutAction {
    if phase == .up {
      if key == .allow, let holding { return .holdCancel(holding) }
      return .ignore
    }
    guard let shown else { return oldestPending.map { .reveal($0) } ?? .ignore }
    guard shown.armed else { return .ignore }
    switch key {
    case .deny:
      // Denying is safe on a truncated request, but only on the one on screen.
      return .deny(shown.cardID)
    case .allow:
      if !shown.fullyVisible {
        return shown.inPeek || !shown.opened ? .openFull(shown.cardID) : .pageDown(shown.cardID)
      }
      return shown.risky ? .holdStart(shown.cardID) : .allow(shown.cardID)
    }
  }
}

/// One latch per global shortcut: a key decides once per physical press. Auto-repeat (or a
/// second Pressed event without a Released in between) is dropped; if a Released was lost the
/// latch opens again once no Pressed event came for `lostReleaseAfter` (auto-repeat keeps
/// sending them while the key is really down).
public struct GlobalKeyLatch: Sendable {
  public static let lostReleaseAfter: TimeInterval = 2.5

  public private(set) var isDown = false
  private var lastPressed = Date.distantPast

  public init() {}

  /// A Pressed event. Returns true when it is a fresh press that may act.
  public mutating func pressed(at t: Date) -> Bool {
    defer { lastPressed = t }
    if isDown && t.timeIntervalSince(lastPressed) < Self.lostReleaseAfter { return false }
    isDown = true
    return true
  }

  /// A Released event. Returns true when it ends a press this latch saw.
  @discardableResult
  public mutating func released() -> Bool {
    let was = isDown
    isDown = false
    return was
  }

  public mutating func reset() {
    isDown = false
    lastPressed = .distantPast
  }
}

/// Which modifier sets a decision shortcut (Allow / Deny) may use. Such a chord acts from
/// every app, so it must never be something people type or press for other reasons:
/// - ⌥ / ⌥⇧ alone types characters (⌥Q is @ on Turkish-Q),
/// - ⌘ / ⌘⇧ alone is an app shortcut (⌘V, ⌘⇧Z ...),
/// - ⌃ alone is a terminal control key (⌃C, ⌃D, ⌃R ...).
/// Allowed: ⌃ with at least one more modifier, or ⌘⌥.
public enum DecisionChord {
  public static func isAllowed(control: Bool, option: Bool, shift: Bool, command: Bool) -> Bool {
    if control { return option || shift || command }
    return command && option
  }

  public static func isAllowed(_ m: ChordModifiers) -> Bool {
    isAllowed(
      control: m.contains(.control), option: m.contains(.option), shift: m.contains(.shift),
      command: m.contains(.command))
  }

  public static var error: String {
    loc("For Allow and Deny, use ⌃ with one more modifier (e.g. ⌃⌥) or ⌘⌥; ⌥ alone types characters, ⌘ alone is an app shortcut, ⌃ alone is a terminal key.")
  }
}

/// Modifier keys of a shortcut, without the Carbon / AppKit bit values.
public struct ChordModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let control = ChordModifiers(rawValue: 1 << 0)
  public static let option = ChordModifiers(rawValue: 1 << 1)
  public static let shift = ChordModifiers(rawValue: 1 << 2)
  public static let command = ChordModifiers(rawValue: 1 << 3)

  /// "⌃⌥⇧⌘" in Apple's order.
  public var symbols: String {
    (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
      + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
  }
}

/// One-click shortcut sets: every role keeps its default key, only the modifiers change.
public enum ShortcutPreset: String, Sendable, CaseIterable {
  /// ⌃⌥ + key: the defaults of a new install.
  case standard
  /// ⌃⌥⇧⌘ + key: one Caps Lock press when a tool (Raycast, Hyperkey, Karabiner-Elements)
  /// turns Caps Lock into all four modifiers.
  case hyper

  public var modifiers: ChordModifiers {
    switch self {
    case .standard: return [.control, .option]
    case .hyper: return [.control, .option, .shift, .command]
    }
  }
}

// MARK: - Jump shortcut

/// Which session the "jump" shortcut (⌃⌥J by default) brings forward: the one that needs the
/// user most. In order: the oldest permission request; else the oldest question, plan approval
/// or input wait; else the newest unseen error; else the newest unseen "done". nil: nothing
/// waits, the shortcut does nothing.
public enum JumpTarget {
  /// `permissionSessionIDs`: the sessions of the pending cards, oldest card first.
  public static func sessionID(permissionSessionIDs: [String], sessions: [Session]) -> String? {
    if let first = permissionSessionIDs.first { return first }
    let asking = sessions.filter {
      switch $0.status {
      case .question, .planApproval, .waitingInput: return true
      default: return false
      }
    }
    if let oldest = asking.min(by: { ($0.statusSince, $0.id) < ($1.statusSince, $1.id) }) {
      return oldest.id
    }
    func newestUnseen(_ match: (SessionStatus) -> Bool) -> String? {
      sessions.filter { $0.unseen && match($0.status) }
        .max(by: { ($0.statusSince, $0.id) < ($1.statusSince, $1.id) })?.id
    }
    if let id = newestUnseen({ if case .error = $0 { return true } else { return false } }) {
      return id
    }
    return newestUnseen { if case .done = $0 { return true } else { return false } }
  }
}

// MARK: - Key labels

/// Uppercasing a key's character for its label. Every language uppercases ASCII the same way
/// except `i` (Turkish and Azeri give `İ`); other scripts have their own rules (Greek accents,
/// Lithuanian, Armenian). Only those need the keyboard layout's language, whose lookup makes
/// macOS build ICU character sets (about 0.6 MB, kept for the life of the process).
public enum KeyLabelCase {
  public static func needsLayoutLocale(_ character: String) -> Bool {
    character.unicodeScalars.contains { !$0.isASCII || $0 == "i" }
  }
}
