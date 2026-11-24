import Foundation

/// Whether Claude Code's status line hands its input to the notch. Plan usage (the 5-hour and
/// weekly limits) and each chat's context left reach the app only that way: through the
/// notch's own status line bridge (scripts/install-statusline.sh), or through a status line
/// script that copies its input to the app's `statusline.json` itself (an earlier version of
/// that installer added such a line, and some people wrote one by hand).
public enum StatusLineLink {
  /// The bridge script's file name, as the installed command names it.
  public static let bridgeName = "claude-notch-statusline.sh"

  /// `statusLine.command` from a Claude Code settings file; nil when there is none.
  public static func command(settings data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let line = root["statusLine"] as? [String: Any], let command = line["command"] as? String,
      !command.isEmpty
    else { return nil }
    return command
  }

  /// The command is the bridge, or one of the files it names (`~` is the home folder) copies
  /// its input for ClaudeNotch. `read` returns a file's text (nil when it cannot).
  public static func isConnected(
    command: String?, home: String, read: (String) -> String?
  ) -> Bool {
    guard let command else { return false }
    if command.contains(bridgeName) { return true }
    for word in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
      var path = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
      guard path.hasPrefix("/"), let text = read(path) else { continue }
      if text.contains("ClaudeNotch") && text.contains("statusline.json") { return true }
    }
    return false
  }
}
