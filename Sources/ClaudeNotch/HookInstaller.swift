import AppKit
import ClaudeNotchCore
import Observation

/// Connects Claude Code to the app from inside it, so a downloaded copy needs no checkout. Two
/// parts, set up and removed together:
/// - the hooks: the bridge script bundled in Resources is copied to Application Support (a
///   path that stays put when the app moves or updates) and the bundled `install-hooks.sh`
///   points `~/.claude/settings.json` at it (backing the file up first, keeping everything
///   else);
/// - the status line: plan usage and context left reach the app only through it, so the
///   bundled `install-statusline.sh` makes the notch's status line bridge the command; the
///   status line the user had keeps running behind it, unchanged.
@MainActor
@Observable
final class HookInstaller {
  enum State: Equatable {
    case installed
    case notInstalled
    /// Installed, but pointing at another copy of the bridge (a source checkout).
    case other(String)
  }

  private(set) var state: State = .notInstalled
  /// Claude Code's status line hands its input to the app (`StatusLineLink`).
  private(set) var statusLineConnected = false
  private(set) var message: String?
  private(set) var busy = false

  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
  static var hookCopy: URL { folder.appendingPathComponent("claude-notch-hook.sh") }
  static var statusLineCopy: URL { folder.appendingPathComponent(StatusLineLink.bridgeName) }
  static var settings: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }
  private static var bundledHook: URL? {
    Bundle.main.url(forResource: "claude-notch-hook", withExtension: "sh")
  }
  private static var bundledInstaller: URL? {
    Bundle.main.url(forResource: "install-hooks", withExtension: "sh")
  }
  private static var bundledStatusLine: URL? {
    Bundle.main.url(forResource: "claude-notch-statusline", withExtension: "sh")
  }
  private static var bundledStatusLineInstaller: URL? {
    Bundle.main.url(forResource: "install-statusline", withExtension: "sh")
  }

  init() {
    Self.refreshCopy()
    check()
  }

  /// Hooks and status line both connected to this app.
  var connected: Bool { state == .installed && statusLineConnected }

  /// Reads settings.json: which bridge (if any) the hooks call, and whether the status line
  /// reaches the app.
  func check() {
    let data = try? Data(contentsOf: Self.settings)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    statusLineConnected = StatusLineLink.isConnected(
      command: data.flatMap(StatusLineLink.command(settings:)), home: home,
      read: { path in
        // A status line script, not a large file: read at most 256 KB.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
          size < 256 * 1024
        else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
      })
    guard let data, let text = String(data: data, encoding: .utf8),
      text.contains("claude-notch-hook.sh")
    else {
      state = .notInstalled
      return
    }
    if text.contains(Self.hookCopy.path) {
      state = .installed
    } else {
      let path = text.components(separatedBy: "\"").first { $0.contains("claude-notch-hook.sh") }
      state = .other(path?.components(separatedBy: " ").first ?? loc("another copy"))
    }
  }

  /// Installed bridge copies are replaced by this version's (app updates bring their fixes).
  /// Runs at every launch (AppDelegate) and again when Settings opens, so a fixed bridge reaches
  /// Claude Code without the user opening Settings first. Does nothing for a bridge that is
  /// not installed.
  static func refreshCopy() {
    if FileManager.default.fileExists(atPath: hookCopy.path), let src = bundledHook {
      copy(src, to: hookCopy)
    }
    if FileManager.default.fileExists(atPath: statusLineCopy.path), let src = bundledStatusLine {
      copy(src, to: statusLineCopy)
    }
  }

  /// Replaces `dest` atomically: the status line runs the bridge many times a minute, and a
  /// half-copied script must never run.
  private static func copy(_ src: URL, to dest: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    let tmp = dest.deletingLastPathComponent()
      .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString.prefix(8))")
    guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
    if rename(tmp.path, dest.path) != 0 { try? fm.removeItem(at: tmp) }
  }

  /// Hooks and status line.
  func install() { run(uninstall: false, hooks: true) }
  /// Only the status line (the hooks are already there).
  func connectStatusLine() { run(uninstall: false, hooks: false) }
  /// Hooks and status line (the status line the user had comes back).
  func uninstall() { run(uninstall: true, hooks: true) }

  private func run(uninstall: Bool, hooks: Bool) {
    guard let installer = Self.bundledInstaller, let hook = Self.bundledHook,
      let lineInstaller = Self.bundledStatusLineInstaller, let line = Self.bundledStatusLine
    else {
      message = loc("The setup files were not found inside the app.")
      return
    }
    if !uninstall, hooks { Self.copy(hook, to: Self.hookCopy) }
    busy = true
    message = nil
    var steps: [[String]] = []
    if hooks {
      steps.append(
        [installer.path, "--hook", Self.hookCopy.path] + (uninstall ? ["--uninstall"] : []))
    }
    steps.append(
      [lineInstaller.path] + (uninstall ? ["--uninstall"] : ["--bridge", line.path]))
    // The installers' messages (shown below when one fails) follow the app's language.
    let lang = AppLanguage.code
    Task.detached {
      var results: [(ok: Bool, text: String)] = []
      for args in steps { results.append(Self.runScript(args, lang: lang)) }
      await MainActor.run {
        self.busy = false
        self.check()
        self.message = Self.message(uninstall: uninstall, hooks: hooks, results: results)
      }
    }
  }

  nonisolated private static func runScript(_ args: [String], lang: String) -> (ok: Bool, text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = args
    // jq: /usr/bin on macOS 15+, Homebrew elsewhere.
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": NSHomeDirectory(), "CLAUDE_NOTCH_LANG": lang]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do {
      try p.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      let text = String(data: data, encoding: .utf8) ?? ""
      return (p.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      return (false, error.localizedDescription)
    }
  }

  private static func message(
    uninstall: Bool, hooks: Bool, results: [(ok: Bool, text: String)]
  ) -> String {
    if let failed = results.first(where: { !$0.ok }) {
      // install-hooks.sh / install-statusline.sh say exactly this when jq is missing.
      if failed.text.contains("jq not found") || failed.text.contains("jq bulunamadı") {
        return loc("jq not found: on macOS 14, run `brew install jq` in Terminal.")
      }
      return loc("Could not install: \(failed.text)")
    }
    if uninstall {
      return loc("Hooks removed and your status line put back. Open Claude Code sessions are affected once restarted.")
    }
    return hooks
      ? loc("Connected. Open Claude Code sessions use it from their next message; plan usage shows once Claude Code next updates its status line.")
      : loc("Status line connected. Plan usage shows once Claude Code next updates its status line.")
  }
}
