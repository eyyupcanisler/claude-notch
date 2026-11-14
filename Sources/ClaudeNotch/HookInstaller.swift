import AppKit
import ClaudeNotchCore
import Observation

/// Installs the Claude Code hooks from inside the app, so a downloaded copy needs no checkout:
/// the bridge script bundled in Resources is copied to Application Support (a path that stays
/// put when the app moves or updates) and the bundled `install-hooks.sh` points
/// `~/.claude/settings.json` at it (backing the file up first, keeping everything else).
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
  private(set) var message: String?
  private(set) var busy = false

  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
  static var hookCopy: URL { folder.appendingPathComponent("claude-notch-hook.sh") }
  static var settings: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }
  private static var bundledHook: URL? {
    Bundle.main.url(forResource: "claude-notch-hook", withExtension: "sh")
  }
  private static var bundledInstaller: URL? {
    Bundle.main.url(forResource: "install-hooks", withExtension: "sh")
  }

  init() {
    Self.refreshCopy()
    check()
  }

  /// Reads settings.json: which bridge (if any) the hooks call.
  func check() {
    guard let data = try? Data(contentsOf: Self.settings),
      let text = String(data: data, encoding: .utf8), text.contains("claude-notch-hook.sh")
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

  /// An installed bridge copy is replaced by this version's (app updates bring hook fixes).
  /// Runs at every launch (AppDelegate) and again when Settings opens, so a fixed bridge reaches
  /// the hooks without the user opening Settings first. Does nothing until the hooks are installed.
  static func refreshCopy() {
    guard FileManager.default.fileExists(atPath: hookCopy.path), let src = bundledHook
    else { return }
    copyHook(from: src)
  }

  private static func copyHook(from src: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    try? fm.removeItem(at: Self.hookCopy)
    try? fm.copyItem(at: src, to: Self.hookCopy)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.hookCopy.path)
  }

  func install() { run(uninstall: false) }
  func uninstall() { run(uninstall: true) }

  private func run(uninstall: Bool) {
    guard let installer = Self.bundledInstaller, let hook = Self.bundledHook else {
      message = loc("The setup files were not found inside the app.")
      return
    }
    if !uninstall { Self.copyHook(from: hook) }
    busy = true
    message = nil
    let args = [installer.path, "--hook", Self.hookCopy.path] + (uninstall ? ["--uninstall"] : [])
    Task.detached {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/bash")
      p.arguments = args
      // jq: /usr/bin on macOS 15+, Homebrew elsewhere.
      p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "HOME": NSHomeDirectory()]
      let out = Pipe()
      p.standardOutput = out
      p.standardError = out
      var text = ""
      var code: Int32 = -1
      do {
        try p.run()
        p.waitUntilExit()
        code = p.terminationStatus
        text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      } catch {
        text = error.localizedDescription
      }
      let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let ok = code == 0
      await MainActor.run {
        self.busy = false
        self.check()
        if ok {
          self.message = uninstall
            ? loc("Hooks removed. Open Claude Code sessions are affected once restarted.")
            : loc("Hooks installed. Open Claude Code sessions use them from their next message.")
        } else if result.contains("jq") {
          self.message = loc("jq not found: on macOS 14, run `brew install jq` in Terminal.")
        } else {
          self.message = loc("Could not install: \(result)")
        }
      }
    }
  }
}
