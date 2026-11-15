import Foundation

/// Settings > Notifications > "Ring the terminal bell when Claude Code notifies". When Claude
/// Code sends a Notification hook event (a permission prompt, a question, an input wait, the
/// idle prompt after a finished turn), the app writes one BEL character to that session's
/// terminal. The terminal decides what a bell looks like: Ghostty puts 🔔 in the tab title
/// until you look at the tab, Terminal and iTerm2 mark the tab. So with the notch island hidden
/// (the terminal is in front), the tab still says which session waits.
///
/// Stored as a Bool under `defaultsKey` (app domain); a fresh install (nothing saved) is off,
/// the original behavior: the app never writes to a terminal.
public enum TerminalBell {
  /// UserDefaults key (app domain), a Bool.
  public static let defaultsKey = "terminalBell"
  /// What an install without a saved choice uses: no bell (the original).
  public static let fallback = false

  /// The stored Bool, or the fallback when nothing (or something that is not a Bool) is stored.
  public static func enabled(stored: Any?) -> Bool {
    stored as? Bool ?? fallback
  }

  /// Every Notification event rings except a login confirmation, which needs nothing from
  /// you. An event without a type rings too.
  public static func rings(notificationType: String?) -> Bool {
    notificationType != "auth_success"
  }

  /// Notification types that need an answer (a permission prompt, a question or another
  /// dialog), unlike the idle prompt after a finished turn.
  public static let answerTypes: Set<String> = [
    "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
  ]

  /// Whether this notification rings now. Silent mode (the band's 🔔 button) lets only what
  /// needs an answer through, as it does for islands and sounds.
  public static func ringsNow(notificationType: String?, silentMode: Bool) -> Bool {
    guard rings(notificationType: notificationType) else { return false }
    guard silentMode else { return true }
    return notificationType.map(answerTypes.contains) ?? false
  }

  /// A terminal device path the bell may be written to: the same rule as the tty a hook
  /// reports (`HookContext.validTTY`, "/dev/ttys" and 1-5 digits), so nothing else under
  /// /dev, and no other file, is ever opened.
  public static func isTerminalPath(_ path: String) -> Bool {
    HookContext.validTTY(path) != nil
  }

  /// Writes one BEL to `tty`. Non-blocking and without taking the terminal as controlling
  /// terminal; false when the path is not a terminal path, does not open as a terminal, or the
  /// write fails (the terminal was closed, or its output is full).
  @discardableResult
  public static func ring(tty: String) -> Bool {
    guard isTerminalPath(tty) else { return false }
    let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard isatty(fd) == 1 else { return false }
    var bel: UInt8 = 0x07
    return write(fd, &bel, 1) == 1
  }
}
