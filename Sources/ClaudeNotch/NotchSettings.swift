import Foundation
import Observation

enum DisplayMode: String, CaseIterable, Sendable {
  /// Built-in notch, plus a pill on the active screen when that is another one.
  case automatic
  /// Only the built-in notch (the primary screen when the lid is closed).
  case notchOnly
  /// Built-in notch plus a pill on every other screen.
  case all

  var title: String {
    switch self {
    case .automatic: return "Otomatik"
    case .notchOnly: return "Sadece çentikli"
    case .all: return "Tümü"
    }
  }
}

enum Density: String, CaseIterable, Sendable {
  case compact
  case rich

  var title: String {
    switch self {
    case .compact: return "Kompakt"
    case .rich: return "Zengin"
    }
  }
}

/// Sound categories of the attention kinds.
enum SoundEvent: String, CaseIterable, Sendable {
  case permission
  case question
  case done
  case error

  var title: String {
    switch self {
    case .permission: return "İzin isteği"
    case .question: return "Soru ve girdi bekleme"
    case .done: return "Bitti"
    case .error: return "Hata"
    }
  }

  var soundName: String {
    switch self {
    case .permission, .question: return "Ping"
    case .done: return "Glass"
    case .error: return "Basso"
    }
  }

  /// permission <- permission; question <- question / plan / waiting; done; error.
  init?(attention kind: String) {
    switch kind {
    case "permission": self = .permission
    case "question", "plan", "waiting": self = .question
    case "done": self = .done
    case "error": self = .error
    default: return nil
    }
  }
}

/// How long an unanswered permission peek stays under the notch.
enum PeekDuration: String, CaseIterable, Sendable {
  case short = "8"
  case normal = "15"
  case long = "30"
  case untilAnswered = "answered"

  var seconds: TimeInterval? {
    switch self {
    case .short: return 8
    case .normal: return 15
    case .long: return 30
    case .untilAnswered: return nil
    }
  }

  var title: String {
    switch self {
    case .short: return "8 sn"
    case .normal: return "15 sn"
    case .long: return "30 sn"
    case .untilAnswered: return "Yanıtlanana kadar"
    }
  }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class NotchSettings {
  @ObservationIgnored private let defaults: UserDefaults

  var displayMode: DisplayMode {
    didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
  }
  var density: Density {
    didSet { defaults.set(density.rawValue, forKey: "density") }
  }
  private(set) var sounds: [SoundEvent: Bool]
  var peekDuration: PeekDuration {
    didSet { defaults.set(peekDuration.rawValue, forKey: "peekDuration") }
  }
  /// Global shortcuts (missing role: the default).
  private(set) var shortcuts: [HotKeyRole: KeyCombo]
  /// The one-time "⌃⌥Y izin ver · ⌃⌥N reddet" line under the peek was used / dismissed.
  var shortcutHintSeen: Bool {
    didSet { defaults.set(shortcutHintSeen, forKey: "shortcutHintSeen") }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "")
      ?? .automatic
    density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .compact
    // v1 had a single switch: it seeds every category.
    let legacy = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    var map: [SoundEvent: Bool] = [:]
    for e in SoundEvent.allCases {
      map[e] = defaults.object(forKey: "sound.\(e.rawValue)") as? Bool ?? legacy
    }
    sounds = map
    peekDuration = PeekDuration(rawValue: defaults.string(forKey: "peekDuration") ?? "")
      ?? .normal
    var keys: [HotKeyRole: KeyCombo] = [:]
    for role in HotKeyRole.allCases {
      keys[role] = KeyCombo(stored: defaults.array(forKey: role.defaultsKey))
        ?? KeyCombo.defaultCombo(role)
    }
    shortcuts = keys
    shortcutHintSeen = defaults.bool(forKey: "shortcutHintSeen")
  }

  /// A stored decision chord that is no longer allowed (see `KeyCombo.error(for:)`) falls back
  /// to the default.
  func shortcut(_ role: HotKeyRole) -> KeyCombo {
    guard let combo = shortcuts[role], combo.error(for: role) == nil else {
      return KeyCombo.defaultCombo(role)
    }
    return combo
  }

  func setShortcut(_ role: HotKeyRole, _ combo: KeyCombo) {
    shortcuts[role] = combo
    defaults.set(combo.stored, forKey: role.defaultsKey)
  }

  func resetShortcuts() {
    for role in HotKeyRole.allCases {
      shortcuts[role] = KeyCombo.defaultCombo(role)
      defaults.removeObject(forKey: role.defaultsKey)
    }
  }

  func soundEnabled(_ e: SoundEvent) -> Bool { sounds[e] ?? true }

  func setSound(_ e: SoundEvent, _ on: Bool) {
    sounds[e] = on
    defaults.set(on, forKey: "sound.\(e.rawValue)")
  }

  var tokens: NotchTheme { .dark }
}
