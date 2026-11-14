import AppKit
import Carbon.HIToolbox
import ClaudeNotchCore

/// The global shortcuts.
enum HotKeyRole: UInt32, CaseIterable, Sendable {
  case panel = 1
  case allow = 2
  case deny = 3
  case timer = 4
  case shelf = 5
  /// Focuses the terminal tab of the session that needs the user most (see `JumpTarget`).
  case jump = 6
  /// ⌃⌥1…⌃⌥4: pick an option of the question on screen. Registered only while one is shown
  /// (never in Settings), so the chords stay free for other apps the rest of the time. Fixed
  /// keys: a shortcut preset does not move them.
  case option1 = 11
  case option2 = 12
  case option3 = 13
  case option4 = 14

  /// The roles the user sets in Settings and that are always registered (Settings order).
  static let configurable: [HotKeyRole] = [.panel, .allow, .deny, .jump, .timer, .shelf]

  /// The order the always-on roles are registered in at launch: the original roles first, the
  /// added `jump` last. Two roles cannot hold the same combo (the second RegisterEventHotKey
  /// fails with eventHotKeyExistsErr), and an install from before `jump` existed may have saved
  /// ⌃⌥J for another role; that saved shortcut must keep working, so `jump` loses the clash.
  static let registrationOrder: [HotKeyRole] = [.panel, .allow, .deny, .timer, .shelf, .jump]

  /// 0-based option index of an `optionN` role.
  var optionIndex: Int? {
    switch self {
    case .option1: return 0
    case .option2: return 1
    case .option3: return 2
    case .option4: return 3
    default: return nil
    }
  }

  var title: String {
    switch self {
    case .panel: return loc("Open the panel")
    case .allow: return loc("Allow")
    case .deny: return loc("Deny")
    case .jump: return loc("Jump to the session that needs you")
    case .timer: return loc("Start / pause Pomodoro")
    case .shelf: return loc("Copy the latest shelf item")
    case .option1, .option2, .option3, .option4: return loc("Question option \((optionIndex ?? 0) + 1)")
    }
  }

  /// Decision keys must use a safe chord (see `DecisionChord`); the others may be anything.
  var isDecision: Bool { self == .allow || self == .deny }

  var defaultsKey: String { "hotkey.\(self)" }
}

/// A key plus Carbon modifiers (`controlKey | optionKey ...`), as RegisterEventHotKey takes it.
struct KeyCombo: Equatable, Hashable, Sendable {
  var keyCode: UInt32
  var modifiers: UInt32

  static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

  /// ⌃⌥Space, ⌃⌥Y, ⌃⌥N ... (letters resolved through the current keyboard layout).
  static func defaultCombo(_ role: HotKeyRole) -> KeyCombo {
    presetCombo(role, .standard)
  }

  /// `role`'s default key with the preset's modifiers (⌃⌥ + key, or ⌃⌥⇧⌘ + key for Hyper).
  /// The question option keys are fixed at ⌃⌥1…⌃⌥4 whatever the preset.
  static func presetCombo(_ role: HotKeyRole, _ preset: ShortcutPreset) -> KeyCombo {
    let mods = carbonModifiers(preset.modifiers)
    let fixed = carbonModifiers(ShortcutPreset.standard.modifiers)
    func letter(_ c: String, _ fallback: Int) -> KeyCombo {
      KeyCombo(keyCode: KeyLayout.keyCode(for: c) ?? UInt32(fallback), modifiers: mods)
    }
    switch role {
    case .panel: return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: mods)
    case .allow: return letter("y", kVK_ANSI_Y)
    case .deny: return letter("n", kVK_ANSI_N)
    case .jump: return letter("j", kVK_ANSI_J)
    case .timer: return letter("p", kVK_ANSI_P)
    case .shelf: return letter("v", kVK_ANSI_V)
    case .option1: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: fixed)
    case .option2: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: fixed)
    case .option3: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: fixed)
    case .option4: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: fixed)
    }
  }

  static func carbonModifiers(_ m: ChordModifiers) -> UInt32 {
    var mods: UInt32 = 0
    if m.contains(.control) { mods |= UInt32(controlKey) }
    if m.contains(.option) { mods |= UInt32(optionKey) }
    if m.contains(.shift) { mods |= UInt32(shiftKey) }
    if m.contains(.command) { mods |= UInt32(cmdKey) }
    return mods
  }

  var chordModifiers: ChordModifiers {
    var m: ChordModifiers = []
    if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
    if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
    if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
    if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
    return m
  }

  /// From a key-down in the recorder; nil without ⌃, ⌥ or ⌘ (a bare key or ⇧ + key would
  /// take that key away from every other app).
  init?(event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var mods: UInt32 = 0
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
    self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
  }

  init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers & Self.modifierMask
  }

  /// Why this chord cannot be `role`'s shortcut (localized), or nil. A decision shortcut acts
  /// from every app, so it must not be a chord people type or use for app shortcuts.
  func error(for role: HotKeyRole) -> String? {
    guard role.isDecision else { return nil }
    return DecisionChord.isAllowed(chordModifiers) ? nil : DecisionChord.error
  }

  /// "⌃⌥Y" (Apple's modifier order: ⌃ ⌥ ⇧ ⌘).
  var display: String {
    chordModifiers.symbols + KeyLayout.label(keyCode: keyCode)
  }

  /// Stored as [keyCode, modifiers].
  var stored: [Int] { [Int(keyCode), Int(modifiers)] }

  init?(stored: Any?) {
    guard let a = stored as? [Int], a.count == 2, (0..<512).contains(a[0]), a[1] >= 0 else {
      return nil
    }
    self.init(keyCode: UInt32(a[0]), modifiers: UInt32(a[1]))
  }

  /// A macOS shortcut (Spotlight, screenshots, Mission Control...) that is switched on.
  var isSystemShortcut: Bool {
    var unmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue()
      as? [[String: Any]]
    else { return false }
    for item in list {
      guard item[kHISymbolicHotKeyEnabled as String] as? Bool == true,
        let code = item[kHISymbolicHotKeyCode as String] as? Int,
        let mods = item[kHISymbolicHotKeyModifiers as String] as? Int
      else { continue }
      if UInt32(code) == keyCode && UInt32(mods) & Self.modifierMask == modifiers { return true }
    }
    return false
  }
}

/// Key labels through the current keyboard layout (Carbon key codes are physical positions).
enum KeyLayout {
  private static let special: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
    kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
    kVK_F11: "F11", kVK_F12: "F12"
  ]

  static func label(keyCode: UInt32) -> String {
    if let s = special[Int(keyCode)] { return s }
    guard let c = character(keyCode: keyCode), !c.isEmpty else { return "#\(keyCode)" }
    return c.uppercased(with: layoutLocale)
  }

  /// Casing follows the keyboard layout's language, not the UI language: on Turkish-Q the `i`
  /// key reads `İ` and the `ı` key reads `I`, whichever language the app shows.
  private static var layoutLocale: Locale {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
      let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String],
      let first = languages.first
    else { return Locale.current }
    return Locale(identifier: first)
  }

  /// Key code that types `char` with no modifiers in the current layout.
  static func keyCode(for char: String) -> UInt32? {
    for code in UInt32(0)..<128 where special[Int(code)] == nil {
      if character(keyCode: code) == char { return code }
    }
    return nil
  }

  private static func character(keyCode: UInt32) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return data.withUnsafeBytes { buf -> String? in
      guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return nil
      }
      var dead: UInt32 = 0
      var chars = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: chars, count: length)
    }
  }
}

/// Global shortcuts through Carbon `RegisterEventHotKey` (no Accessibility permission). One
/// event handler receives Pressed and Released of every registered key and dispatches on the
/// hot key id; nothing here activates the app or takes the keyboard.
@MainActor
final class HotKeyCenter {
  private var handler: EventHandlerRef?
  private var refs: [HotKeyRole: EventHotKeyRef] = [:]
  /// Last registration result per role (`noErr` when registered).
  private(set) var status: [HotKeyRole: OSStatus] = [:]
  private(set) var combos: [HotKeyRole: KeyCombo] = [:]
  private let onEvent: @MainActor (HotKeyRole, Bool) -> Void
  static let signature = OSType(0x434E_4F54)  // "CNOT"

  init(onEvent: @escaping @MainActor (HotKeyRole, Bool) -> Void) {
    self.onEvent = onEvent
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    ]
    let me = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let got = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard got == noErr, id.signature == HotKeyCenter.signature,
          let role = HotKeyRole(rawValue: id.id)
        else { return OSStatus(eventNotHandledErr) }
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { center.onEvent(role, pressed) }
        return noErr
      }, specs.count, &specs, me, &handler)
  }

  /// Registers `combo` for `role` (replacing its previous key). Returns the Carbon status.
  @discardableResult
  func register(_ role: HotKeyRole, _ combo: KeyCombo) -> OSStatus {
    unregister(role)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: role.rawValue)
    let result = RegisterEventHotKey(
      combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    status[role] = result
    if result == noErr, let ref {
      refs[role] = ref
      combos[role] = combo
    }
    return result
  }

  func unregister(_ role: HotKeyRole) {
    if let ref = refs.removeValue(forKey: role) { UnregisterEventHotKey(ref) }
    combos.removeValue(forKey: role)
  }

  func unregisterAll() {
    for role in HotKeyRole.allCases { unregister(role) }
  }

  func isRegistered(_ role: HotKeyRole) -> Bool { refs[role] != nil }
}
