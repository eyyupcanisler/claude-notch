import AppKit
import ClaudeNotchCore
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
    case .automatic: return loc("Automatic")
    case .notchOnly: return loc("Notched screen only")
    case .all: return loc("All screens")
    }
  }
}

enum Density: String, CaseIterable, Sendable {
  case compact
  case rich

  var title: String {
    switch self {
    case .compact: return loc("Compact")
    case .rich: return loc("Rich")
    }
  }
}

extension StatusColorScheme {
  var title: String {
    switch self {
    case .classic: return loc("Classic")
    case .colorblind: return loc("Colorblind-friendly")
    }
  }
}

extension LanguageChoice {
  /// Each language in its own name; "System" in the current UI language.
  var title: String {
    switch self {
    case .turkish: return "Türkçe"
    case .english: return "English"
    case .system: return loc("System (Mac language)")
    }
  }
}

/// Quits and opens the app again (a language change applies at launch).
@MainActor
enum AppRelaunch {
  /// Only a real .app bundle can be opened again (not a `swift run` binary).
  static var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

  /// A detached shell waits (up to ~10 s) for this process to exit, then `open`s the bundle;
  /// the app allows one copy, so the new one must not start before this one is gone.
  static func now() {
    guard available else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    let demo = NotchSettings.isDemo ? "--env CLAUDE_NOTCH_DEMO=1 " : ""
    p.arguments = [
      "-c",
      "i=0; while kill -0 \"$0\" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; "
        + "exec /usr/bin/open \(demo)\"$1\"",
      String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
    ]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
      try p.run()
    } catch {
      return
    }
    NSApp.terminate(nil)
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
    case .permission: return loc("Permission request")
    case .question: return loc("Question or waiting for input")
    case .done: return loc("Done")
    case .error: return loc("Error")
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
    case .short: return loc("8 s")
    case .normal: return loc("15 s")
    case .long: return loc("30 s")
    case .untilAnswered: return loc("Until answered")
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
  /// Status colors; applies at once (the notch theme is built from it). Fresh install: classic.
  var statusColors: StatusColorScheme {
    didSet { defaults.set(statusColors.rawValue, forKey: StatusColorScheme.defaultsKey) }
  }
  /// UI language; takes effect at the next launch (see `main.swift`). Fresh install: the Mac's
  /// (Turkish on a Turkish Mac, English otherwise).
  var language: LanguageChoice {
    didSet { defaults.set(language.rawValue, forKey: LanguageChoice.defaultsKey) }
  }
  /// The chosen language resolves to another language than the running UI's (System on a
  /// Turkish Mac and Türkçe are the same language: no restart needed).
  var languageNeedsRestart: Bool {
    language.appleLanguages(macPreferred: LanguageChoice.macPreferredLanguages).first
      != AppLanguage.code
  }
  private(set) var sounds: [SoundEvent: Bool]
  /// Chosen macOS sound per event (missing: the event's default).
  private(set) var soundNames: [SoundEvent: String]
  /// Silent mode (band 🔕): only permission requests and questions drop and sound. macOS
  /// shares the Focus state only with apps Apple granted it to, so this is the user's switch.
  var silentMode: Bool {
    didSet { defaults.set(silentMode, forKey: "silentMode") }
  }
  /// No sounds between `quietStart` and `quietEnd` (hours, wraps past midnight).
  var quietHours: Bool {
    didSet { defaults.set(quietHours, forKey: "quietHours") }
  }
  var quietStart: Int {
    didSet { defaults.set(quietStart, forKey: "quietStart") }
  }
  var quietEnd: Int {
    didSet { defaults.set(quietEnd, forKey: "quietEnd") }
  }
  static let systemSounds = [
    "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
    "Sosumi", "Submarine", "Tink",
  ]
  var peekDuration: PeekDuration {
    didSet { defaults.set(peekDuration.rawValue, forKey: "peekDuration") }
  }
  /// Claude's questions are held and answered in the notch (the original, default on), or
  /// only told about and answered in the terminal (off). See `QuestionMode`.
  var answerQuestionsInNotch: Bool {
    didSet { defaults.set(answerQuestionsInNotch, forKey: QuestionMode.defaultsKey) }
  }
  var questionMode: QuestionMode { QuestionMode(answerInNotch: answerQuestionsInNotch) }
  /// While a session's terminal is the front app, its permission requests, plan approvals and
  /// waiting notices drop no island (off by default, the original: see `TerminalIslands`).
  var hideIslandsWhileTerminalInFront: Bool {
    didSet {
      defaults.set(hideIslandsWhileTerminalInFront, forKey: TerminalIslands.defaultsKey)
    }
  }
  /// Claude Code notifications ring the session's terminal bell (off by default, the
  /// original: see `TerminalBell`).
  var terminalBell: Bool {
    didSet { defaults.set(terminalBell, forKey: TerminalBell.defaultsKey) }
  }
  /// The 80% / 95% notes also warn for a weekly main window (off by default, the original:
  /// see `WeeklyUsageAlerts`). UsageModule reads the stored value when a status line arrives.
  var weeklyUsageAlerts: Bool {
    didSet { defaults.set(weeklyUsageAlerts, forKey: WeeklyUsageAlerts.defaultsKey) }
  }
  /// Global shortcuts (missing role: the default).
  private(set) var shortcuts: [HotKeyRole: KeyCombo]
  /// The one-time "⌃⌥Y allow · ⌃⌥N deny" line under the peek was used / dismissed.
  var shortcutHintSeen: Bool {
    didSet { defaults.set(shortcutHintSeen, forKey: "shortcutHintSeen") }
  }
  /// Modules. Calendar starts off: turning it on is what asks for calendar access.
  var calendarEnabled: Bool {
    didSet { defaults.set(calendarEnabled, forKey: "module.calendar") }
  }
  /// Where calendar events come from: macOS Calendar (EventKit) or Google's API directly.
  var calendarGoogle: Bool {
    didSet { defaults.set(calendarGoogle, forKey: "module.calendarGoogle") }
  }
  /// Remind at each event's own reminder times (Google reminders / macOS alarms), else always
  /// 10 min before.
  var calendarOwnAlerts: Bool {
    didSet { defaults.set(calendarOwnAlerts, forKey: "module.calendarOwnAlerts") }
  }
  var timerEnabled: Bool {
    didSet { defaults.set(timerEnabled, forKey: "module.timer") }
  }
  var timerMinutes: Int {
    didSet { defaults.set(timerMinutes, forKey: "module.timerMinutes") }
  }
  var batteryEnabled: Bool {
    didSet { defaults.set(batteryEnabled, forKey: "module.battery") }
  }
  /// Spotify starts off: turning it on is what asks for Automation access to Spotify.
  var spotifyEnabled: Bool {
    didSet { defaults.set(spotifyEnabled, forKey: "module.spotify") }
  }
  /// Claude plan usage tile (needs the status line bridge). On: nothing shows without data.
  var usageEnabled: Bool {
    didSet { defaults.set(usageEnabled, forKey: "module.usage") }
  }
  /// Weather for a typed city (Open-Meteo). Off by default (network).
  var weatherEnabled: Bool {
    didSet { defaults.set(weatherEnabled, forKey: "module.weather") }
  }
  /// Clipboard history + dropped files. Off by default (it reads the clipboard).
  var shelfEnabled: Bool {
    didSet { defaults.set(shelfEnabled, forKey: "module.shelf") }
  }
  /// Unpinned shelf items leave this long after they were added (default never, the original).
  var shelfExpiry: ShelfExpiry {
    didSet { defaults.set(shelfExpiry.rawValue, forKey: ShelfExpiry.defaultsKey) }
  }
  /// Turning the shelf off also deletes the pinned items (default off, the original: pins stay).
  var shelfDeletePinsWhenOff: Bool {
    didSet { defaults.set(shelfDeletePinsWhenOff, forKey: ShelfPinsOnOff.defaultsKey) }
  }
  /// With an app in front (its menu might reach the notch), the ears tuck behind the notch.
  var tuckEars: Bool {
    didSet { defaults.set(tuckEars, forKey: "module.spotifyTuck") }
  }
  static let timerChoices = [5, 15, 25, 50]
  /// Pomodoro cycle: focus / short break / long break minutes, focus blocks before a long one.
  var pomoFocus: Int {
    didSet { defaults.set(pomoFocus, forKey: "module.pomoFocus") }
  }
  var pomoShort: Int {
    didSet { defaults.set(pomoShort, forKey: "module.pomoShort") }
  }
  var pomoLong: Int {
    didSet { defaults.set(pomoLong, forKey: "module.pomoLong") }
  }
  var pomoRounds: Int {
    didSet { defaults.set(pomoRounds, forKey: "module.pomoRounds") }
  }

  /// `CLAUDE_NOTCH_DEMO=1`: a recording run (README demo). Its own clean settings, its own
  /// socket, no process discovery: nothing of the user's real sessions or modules shows.
  nonisolated static let isDemo = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DEMO"] == "1"

  static var defaultStore: UserDefaults {
    isDemo ? UserDefaults(suiteName: "com.eyyupcan.claudenotch.demo") ?? .standard : .standard
  }

  init(defaults: UserDefaults = NotchSettings.defaultStore) {
    self.defaults = defaults
    displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "")
      ?? .automatic
    density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .compact
    statusColors = StatusColorScheme(stored: defaults.string(forKey: StatusColorScheme.defaultsKey))
    let lang = LanguageChoice(stored: defaults.string(forKey: LanguageChoice.defaultsKey))
    language = lang
    // v1 had a single switch: it seeds every category.
    let legacy = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    var map: [SoundEvent: Bool] = [:]
    for e in SoundEvent.allCases {
      map[e] = defaults.object(forKey: "sound.\(e.rawValue)") as? Bool ?? legacy
    }
    sounds = map
    var names: [SoundEvent: String] = [:]
    for e in SoundEvent.allCases {
      if let n = defaults.string(forKey: "soundName.\(e.rawValue)"), Self.systemSounds.contains(n) {
        names[e] = n
      }
    }
    soundNames = names
    quietHours = defaults.bool(forKey: "quietHours")
    silentMode = defaults.bool(forKey: "silentMode")
    quietStart = defaults.object(forKey: "quietStart") as? Int ?? 23
    quietEnd = defaults.object(forKey: "quietEnd") as? Int ?? 8
    peekDuration = PeekDuration(rawValue: defaults.string(forKey: "peekDuration") ?? "")
      ?? .normal
    answerQuestionsInNotch =
      QuestionMode(stored: defaults.object(forKey: QuestionMode.defaultsKey)).answersInNotch
    hideIslandsWhileTerminalInFront =
      TerminalIslands.hides(stored: defaults.object(forKey: TerminalIslands.defaultsKey))
    terminalBell = TerminalBell.enabled(stored: defaults.object(forKey: TerminalBell.defaultsKey))
    weeklyUsageAlerts =
      WeeklyUsageAlerts.enabled(stored: defaults.object(forKey: WeeklyUsageAlerts.defaultsKey))
    var keys: [HotKeyRole: KeyCombo] = [:]
    for role in HotKeyRole.allCases {
      keys[role] = KeyCombo(stored: defaults.array(forKey: role.defaultsKey))
        ?? KeyCombo.defaultCombo(role)
    }
    shortcuts = keys
    shortcutHintSeen = defaults.bool(forKey: "shortcutHintSeen")
    calendarEnabled = defaults.bool(forKey: "module.calendar")
    timerEnabled = defaults.object(forKey: "module.timer") as? Bool ?? true
    calendarGoogle = defaults.bool(forKey: "module.calendarGoogle")
    calendarOwnAlerts = defaults.object(forKey: "module.calendarOwnAlerts") as? Bool ?? true
    let minutes = defaults.integer(forKey: "module.timerMinutes")
    timerMinutes = (1...180).contains(minutes) ? minutes : 25
    func stored(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
      let v = defaults.integer(forKey: key)
      return range.contains(v) ? v : fallback
    }
    pomoFocus = stored("module.pomoFocus", 5...180, 25)
    pomoShort = stored("module.pomoShort", 1...60, 5)
    pomoLong = stored("module.pomoLong", 1...90, 15)
    pomoRounds = stored("module.pomoRounds", 1...8, 4)
    batteryEnabled = defaults.object(forKey: "module.battery") as? Bool ?? true
    spotifyEnabled = defaults.bool(forKey: "module.spotify")
    tuckEars = defaults.object(forKey: "module.spotifyTuck") as? Bool ?? true
    shelfEnabled = defaults.bool(forKey: "module.shelf")
    shelfExpiry = ShelfExpiry(stored: defaults.object(forKey: ShelfExpiry.defaultsKey))
    shelfDeletePinsWhenOff =
      ShelfPinsOnOff.deletesPins(stored: defaults.object(forKey: ShelfPinsOnOff.defaultsKey))
    weatherEnabled = defaults.bool(forKey: "module.weather")
    usageEnabled = defaults.object(forKey: "module.usage") as? Bool ?? true
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

  func soundName(_ e: SoundEvent) -> String { soundNames[e] ?? e.soundName }

  func setSoundName(_ e: SoundEvent, _ name: String) {
    soundNames[e] = name
    defaults.set(name, forKey: "soundName.\(e.rawValue)")
  }

  /// Inside the quiet hours now.
  func isQuiet(at date: Date = Date()) -> Bool {
    guard quietHours, quietStart != quietEnd else { return false }
    let h = Calendar.current.component(.hour, from: date)
    return quietStart < quietEnd ? (h >= quietStart && h < quietEnd)
      : (h >= quietStart || h < quietEnd)
  }

  /// Plays `name` unless the quiet hours are on (every ClaudeNotch sound goes through here).
  func play(_ name: String) {
    guard !isQuiet() else { return }
    NSSound(named: NSSound.Name(name))?.play()
  }

  func setSound(_ e: SoundEvent, _ on: Bool) {
    sounds[e] = on
    defaults.set(on, forKey: "sound.\(e.rawValue)")
  }

  var tokens: NotchTheme { .scheme(statusColors) }
}
