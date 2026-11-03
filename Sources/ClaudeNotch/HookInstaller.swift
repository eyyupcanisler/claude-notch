import AppKit
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
    refreshCopy()
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
      state = .other(path?.components(separatedBy: " ").first ?? "başka bir kopya")
    }
  }

  /// An installed bridge copy is replaced by this version's (app updates bring hook fixes).
  private func refreshCopy() {
    guard FileManager.default.fileExists(atPath: Self.hookCopy.path), let src = Self.bundledHook
    else { return }
    copyHook(from: src)
  }

  private func copyHook(from src: URL) {
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
      message = "Uygulamanın içinde kurulum dosyaları bulunamadı."
      return
    }
    if !uninstall { copyHook(from: hook) }
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
            ? "Kancalar kaldırıldı. Açık Claude Code oturumları yeniden başlatılınca etkilenir."
            : "Kancalar kuruldu. Açık Claude Code oturumlarında bir sonraki mesajdan itibaren çalışır."
        } else if result.contains("jq") {
          self.message = "jq bulunamadı: macOS 14’te Terminal’de `brew install jq` çalıştır."
        } else {
          self.message = "Kurulamadı: \(result)"
        }
      }
    }
  }
}
