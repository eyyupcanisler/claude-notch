import Foundation

/// Which app a chat runs in. Two clues, both from the chat's environment: TERM_PROGRAM (what the
/// terminal says it is) and `__CFBundleIdentifier` (the bundle id macOS gives every app it
/// launches; everything started inside inherits it). TERM_PROGRAM alone misses a chat behind
/// tmux (`tmux`), in an editor that calls itself VS Code (Cursor, Windsurf), in Claude's
/// desktop app or in a terminal that sets none (Alacritty, kitty): the bundle id names the app
/// in those cases.
public enum TerminalHost {
  public static let ghostty = "com.mitchellh.ghostty"
  public static let appleTerminal = "com.apple.Terminal"
  public static let iTerm = "com.googlecode.iterm2"

  /// TERM_PROGRAM -> the app's bundle id.
  public static let byTermProgram: [String: String] = [
    "Apple_Terminal": appleTerminal,
    "iTerm.app": iTerm,
    "vscode": "com.microsoft.VSCode",
    "ghostty": ghostty,
    "WarpTerminal": "dev.warp.Warp-Stable",
    "cursor": "com.todesktop.230313mzl4w4u92",
    "WezTerm": "com.github.wez.wezterm",
    "kitty": "net.kovidgoyal.kitty",
    "Hyper": "co.zeit.hyper",
  ]

  /// Apps that are only a terminal: when one is in front, its window (and the chat in it) is
  /// what the user sees. Editors with a built-in terminal are left out: the editor can be in
  /// front with its terminal panel closed.
  public static let terminalOnly: Set<String> = [
    ghostty, appleTerminal, iTerm, "dev.warp.Warp-Stable", "dev.warp.Warp",
    "com.github.wez.wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper",
    "org.alacritty", "io.alacritty", "org.tabby", "com.raphaelamorim.rio",
  ]

  /// The chat's app: TERM_PROGRAM's when it names a terminal-only app (it is the most direct
  /// clue), else the inherited bundle id (it tells Cursor from VS Code and sees through tmux),
  /// else TERM_PROGRAM's app. nil when neither says anything.
  public static func bundleID(termProgram: String?, termBundle: String?) -> String? {
    let named = termProgram.flatMap { byTermProgram[$0] }
    if let named, terminalOnly.contains(named) { return named }
    return validBundleID(termBundle) ?? named
  }

  /// A bundle id as `__CFBundleIdentifier` carries it: reverse-DNS, letters, digits, `.` and
  /// `-`, at least two parts, up to 128 characters.
  public static func validBundleID(_ raw: String?) -> String? {
    guard let raw, (3...128).contains(raw.utf8.count), !raw.hasPrefix("."),
      !raw.hasSuffix("."), !raw.contains(".."), raw.contains(".")
    else { return nil }
    let ok = raw.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
    }
    return ok ? raw : nil
  }

  /// Whether `bundleID` is a terminal-only app (`terminalOnly`).
  public static func isTerminalOnly(_ bundleID: String?) -> Bool {
    bundleID.map(terminalOnly.contains) ?? false
  }
}

extension Session {
  /// The app the chat runs in (see `TerminalHost.bundleID`); nil when unknown.
  public var hostBundleID: String? {
    TerminalHost.bundleID(termProgram: termProgram, termBundle: termBundle)
  }

  /// The terminal's kind, for the tab strategies: from TERM_PROGRAM, else from the host app.
  public var terminalKind: TerminalKind {
    let byName = TerminalKind(termProgram: termProgram)
    return byName == .other ? TerminalKind(bundleID: hostBundleID) : byName
  }

  /// Behind tmux (TERM_PROGRAM is tmux): the chat's tty is a tmux pane's, which no terminal
  /// tab owns, so a tab script cannot find it; the host app is only brought forward.
  public var behindTmux: Bool { termProgram == "tmux" }
}
