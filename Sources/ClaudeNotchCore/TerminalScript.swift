import Foundation

/// AppleScript sources for jumping to a session's terminal. Built here (pure, testable); the app
/// target runs them with NSAppleScript. Every script returns "focused", "notfound" or
/// "ambiguous" (directory match with several terminals).
public enum TerminalScript {
  /// Seconds an Apple Event may wait for the terminal before giving up.
  public static let timeoutSeconds = 4

  /// AppleScript string literal for `s`: quotes and backslashes escaped, newline / return / tab
  /// as escapes, other control and format characters dropped.
  public static func literal(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        let cat = scalar.properties.generalCategory
        if cat == .control || cat == .format || cat == .lineSeparator
          || cat == .paragraphSeparator
        {
          continue
        }
        out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  private static func wrap(_ app: String, _ body: String) -> String {
    """
    with timeout of \(timeoutSeconds) seconds
      tell application \(literal(app))
    \(body)
      end tell
    end timeout
    """
  }

  /// Ghostty: focus the terminal whose tty matches (raises its window / Space, selects the tab).
  public static func ghosttyFocus(tty: String) -> String? {
    guard let tty = HookContext.validTTY(tty) else { return nil }
    return wrap("Ghostty", """
        set matches to (every terminal whose tty is \(literal(tty)))
        if (count of matches) is 0 then return "notfound"
        focus (item 1 of matches)
        activate
        return "focused"
    """)
  }

  /// Ghostty fallback: focus the only terminal whose working directory is `cwd`.
  public static func ghosttyFocus(directory cwd: String) -> String? {
    guard cwd.hasPrefix("/") else { return nil }
    return wrap("Ghostty", """
        set matches to (every terminal whose working directory is \(literal(cwd)))
        if (count of matches) is 0 then return "notfound"
        if (count of matches) > 1 then return "ambiguous"
        focus (item 1 of matches)
        activate
        return "focused"
    """)
  }

  /// Ghostty: tty of the focused terminal of the front window ("" when there is no window).
  public static let ghosttyFocusedTTY = wrap("Ghostty", """
      if (count of windows) is 0 then return ""
      return tty of (focused terminal of (selected tab of front window))
  """)

  /// Terminal.app: select the tab whose tty matches and bring its window to the front.
  public static func terminalAppFocus(tty: String) -> String? {
    guard let tty = HookContext.validTTY(tty) else { return nil }
    return wrap("Terminal", """
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is \(literal(tty)) then
              set selected tab of w to t
              set index of w to 1
              activate
              return "focused"
            end if
          end repeat
        end repeat
        return "notfound"
    """)
  }

  /// iTerm2: select the session whose tty matches (window, tab, session).
  public static func iTermFocus(tty: String) -> String? {
    guard let tty = HookContext.validTTY(tty) else { return nil }
    return wrap("iTerm2", """
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is \(literal(tty)) then
                select w
                tell t to select
                tell s to select
                activate
                return "focused"
              end if
            end repeat
          end repeat
        end repeat
        return "notfound"
    """)
  }
}

/// Which terminal a TERM_PROGRAM value is, for the focus strategy.
public enum TerminalKind: String, Sendable {
  case ghostty
  case appleTerminal
  case iTerm
  case other

  public init(termProgram: String?) {
    switch termProgram {
    case "ghostty": self = .ghostty
    case "Apple_Terminal": self = .appleTerminal
    case "iTerm.app": self = .iTerm
    default: self = .other
    }
  }

  /// Display name for hints.
  public var appName: String {
    switch self {
    case .ghostty: return "Ghostty"
    case .appleTerminal: return "Terminal"
    case .iTerm: return "iTerm2"
    case .other: return "Terminal"
    }
  }

  /// Script that focuses `tty` in this terminal, nil when the terminal has no tty strategy.
  public func focusScript(tty: String) -> String? {
    switch self {
    case .ghostty: return TerminalScript.ghosttyFocus(tty: tty)
    case .appleTerminal: return TerminalScript.terminalAppFocus(tty: tty)
    case .iTerm: return TerminalScript.iTermFocus(tty: tty)
    case .other: return nil
    }
  }
}

/// Result of "take me to this session's terminal".
public enum FocusOutcome: Sendable, Equatable {
  /// The exact tab / terminal (matched by tty).
  case focusedTerminal
  /// Matched by working directory (no usable tty).
  case focusedByDirectory
  /// Only the terminal app was brought forward.
  case activatedApp
  /// TERM_PROGRAM is unknown: nothing to bring forward.
  case unknownTerminal
  /// macOS denied the Apple Event (-1743): the user must allow it in System Settings.
  case notAuthorized(app: String)
  case failed

  /// Apple Event error: not permitted to send (Privacy > Automation is off for this target).
  public static let errNotPermitted = -1743

  /// The user reached the session: clears its unseen / waiting state.
  public var reachedSession: Bool {
    switch self {
    case .focusedTerminal, .focusedByDirectory, .activatedApp: return true
    case .unknownTerminal, .notAuthorized, .failed: return false
    }
  }

  public var kind: String {
    switch self {
    case .focusedTerminal: return "terminal"
    case .focusedByDirectory: return "directory"
    case .activatedApp: return "app"
    case .unknownTerminal: return "unknown"
    case .notAuthorized: return "not_authorized"
    case .failed: return "failed"
    }
  }

  /// Text to show in the notch, if any.
  public var hint: String? {
    switch self {
    case .notAuthorized(let app):
      // Accusative suffix: "Terminal'i", "Ghostty'yi", "iTerm2'yi".
      let object = app == "Terminal" ? "Terminal'i" : "\(app)'yi"
      return "\(object) kontrol izni gerekli — Sistem Ayarları > Gizlilik > Otomasyon"
    case .failed:
      return "Terminal öne getirilemedi"
    default:
      return nil
    }
  }
}
