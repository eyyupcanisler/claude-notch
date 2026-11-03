import AppKit
import ClaudeNotchCore
import Observation

/// Claude plan usage (5-hour and weekly limits). The only place Claude Code reports these is the
/// status line's input, so one line in the user's status line script copies that input to
/// `statusline.json` in the app's folder (scripts/install-statusline.sh). This module watches the
/// folder (kernel file events, no polling) and reads the small file when it is replaced.
@MainActor
@Observable
final class UsageModule {
  private(set) var usage: PlanUsage?
  /// Context window left per session id (each status line refresh writes one session's).
  private(set) var contextLeft: [String: Double] = [:]
  /// A session's context fell under the alert mark (session id, percent left).
  @ObservationIgnored var onContextLow: (@MainActor (String, Double) -> Void)?

  @ObservationIgnored var onNote: (@MainActor (ModuleNote) -> Void)?
  @ObservationIgnored private var source: DispatchSourceFileSystemObject?
  @ObservationIgnored private var warned: Set<String> = []

  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
  static var file: URL { folder.appendingPathComponent("statusline.json") }

  /// The status line script writes the file (the bridge line is installed).
  var hasData: Bool { usage != nil }

  func setEnabled(_ on: Bool) {
    if on, source == nil {
      let fd = open(Self.folder.path, O_EVTONLY)
      guard fd >= 0 else { return }
      let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
      src.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.read() }
      }
      src.setCancelHandler { close(fd) }
      src.resume()
      source = src
      read()
    } else if !on, let src = source {
      src.cancel()
      source = nil
      usage = nil
    }
  }

  private func read() {
    guard let data = try? Data(contentsOf: Self.file) else { return }
    if let c = ContextLeft.statusLine(data) {
      let previous = contextLeft[c.sessionID]
      if previous != c.percent { contextLeft[c.sessionID] = c.percent }
      if c.crossesAlert(from: previous) { onContextLow?(c.sessionID, c.percent) }
    }
    guard let u = PlanUsage.statusLine(data, at: Date()) else { return }
    guard u != usage else { return }
    usage = u
    if let mark = u.newMark(shown: warned), let w = u.fiveHour {
      warned.insert(mark.key)
      onNote?(
        ModuleNote(
          source: .usage, id: "usage:\(mark.key)",
          title: mark.mark >= 95 ? "5 saatlik limit dolmak üzere" : "5 saatlik limitin %80’i doldu",
          subtitle: "\(ModuleCenter.clock(w.resetsAt))’de sıfırlanır",
          digits: "\(Int(w.percent.rounded()))", unit: "%", validUntil: w.resetsAt))
    }
  }
}
