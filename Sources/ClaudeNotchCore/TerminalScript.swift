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

  /// The same from the app's bundle id (a chat whose TERM_PROGRAM is missing or another, see
  /// `TerminalHost`).
  public init(bundleID: String?) {
    switch bundleID {
    case TerminalHost.ghostty: self = .ghostty
    case TerminalHost.appleTerminal: self = .appleTerminal
    case TerminalHost.iTerm: self = .iTerm
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
  /// Only the terminal app was brought forward (a terminal without a tab strategy).
  case activatedApp
  /// The terminal app came forward, but the chat's own tab could not be selected: the tab
  /// script found no such terminal, or failed with Apple Event error `code`. The user is not at
  /// the chat, so it stays unseen and the panel says so (it used to look like a dead click).
  case tabMissed(app: String, code: Int?)
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
    case .unknownTerminal, .notAuthorized, .tabMissed, .failed: return false
    }
  }

  public var kind: String {
    switch self {
    case .focusedTerminal: return "terminal"
    case .focusedByDirectory: return "directory"
    case .activatedApp: return "app"
    case .unknownTerminal: return "unknown"
    case .notAuthorized: return "not_authorized"
    case .tabMissed: return "tab_missed"
    case .failed: return "failed"
    }
  }

  /// Text to show in the notch, if any.
  public var hint: String? { hint(chat: nil) }

  /// Text to show in the notch, naming the chat (its title, see `SessionStore.chatLabel`) when
  /// the jump did not reach it.
  public func hint(chat: String?) -> String? {
    switch self {
    case .tabMissed(let app, let code):
      // The code is passed as text: no thousands separator in "-1712".
      let error = code.map { loc(" (error \(String($0)))") } ?? ""
      guard let chat else {
        return loc("Couldn’t switch to the chat’s tab in \(app)\(error). Its tab may be closed.")
      }
      return loc("Couldn’t switch to “\(chat)” in \(app)\(error). Its tab may be closed.")
    case .unknownTerminal:
      guard let chat else { return loc("Can’t tell which terminal this chat runs in") }
      return loc("Can’t tell which terminal “\(chat)” runs in")
    case .notAuthorized(let app):
      // Two keys: Turkish puts an accusative suffix on the name ("Terminal'i", "Ghostty'yi").
      return app == "Terminal"
        ? loc("Terminal needs control permission — System Settings > Privacy & Security > Automation")
        : loc("\(app) needs control permission — System Settings > Privacy & Security > Automation")
    case .failed:
      return loc("Could not bring the terminal to the front")
    default:
      return nil
    }
  }
}
