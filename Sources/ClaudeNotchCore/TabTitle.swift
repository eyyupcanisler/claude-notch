import Foundation

/// Terminal tab titles (Ghostty `name of terminal`), cleaned for display.
public enum TabTitle {
  public static let maxLength = 48

  /// Display text for a raw title: control, format (bidi, zero width), private-use and other
  /// invisible characters dropped, every kind of space folded into one, Claude Code's leading
  /// spinner / status glyph removed (it animates, the title should not), head…tail when long.
  /// nil when nothing readable is left.
  public static func clean(_ raw: String) -> String? {
    var out = ""
    var pendingSpace = false
    for scalar in raw.unicodeScalars.prefix(1000) {
      let cat = scalar.properties.generalCategory
      if scalar.properties.isWhitespace || cat == .spaceSeparator {
        pendingSpace = !out.isEmpty
        continue
      }
      if ToolSummary.isDeceptive(scalar) { continue }
      if out.isEmpty && isStatusGlyph(scalar) { continue }
      if pendingSpace {
        out.append(" ")
        pendingSpace = false
      }
      out.unicodeScalars.append(scalar)
    }
    guard !out.isEmpty else { return nil }
    return TextShortener.middle(out, limit: maxLength)
  }

  /// Braille spinner frames, geometric shapes (◐ ◓ ◑ ◒ ●), dingbat stars / asterisks
  /// (✳ ✻ ✽ ✶), bullets and middle dots.
  static func isStatusGlyph(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x2800...0x28FF, 0x25A0...0x25FF, 0x2700...0x27BF,
      0x2022, 0x00B7, 0x2219, 0x22C5, 0x002A:
      return true
    default:
      return false
    }
  }

  /// Pairs `tty of every terminal` with `name of every terminal` (one Apple Event each, same
  /// order). Invalid ttys and empty titles are skipped; the first title of a tty wins.
  public static func map(ttys: [String], names: [String]) -> [String: String] {
    var out: [String: String] = [:]
    for (tty, name) in zip(ttys, names) {
      guard let tty = HookContext.validTTY(tty), out[tty] == nil, let title = clean(name)
      else { continue }
      out[tty] = title
    }
    return out
  }
}

extension TerminalScript {
  /// Ghostty: the ttys and the titles of every terminal, as a list of two lists.
  public static let ghosttyTitles = """
    with timeout of \(timeoutSeconds) seconds
      tell application "Ghostty"
        return {tty of every terminal, name of every terminal}
      end tell
    end timeout
    """
}
