import AppKit
import ClaudeNotchCore
import Observation

/// Claude plan usage (5-hour and weekly limits). The only place Claude Code reports these is the
/// status line's input, so one line in the user's status line script copies that input to
/// `statusline.json` in the app's folder (scripts/install-statusline.sh). This module watches the
/// folder (kernel file events, no polling) and reads the small file when it is replaced. The
/// 80% / 95% notes follow the main window (`PlanUsage.primaryKind`): the 5-hour one when the
/// input has it (the original), else the weekly one (newer Claude Code sends only that), which
/// warns only with Settings > Modules > weekly warnings on (`WeeklyUsageAlerts`, off by
/// default).
@MainActor
@Observable
final class UsageModule {
  private(set) var usage: PlanUsage?
  /// Context window left per session id (each status line refresh writes one session's; empty
  /// when the status line passes only `rate_limits`). Holds the `contextKept` sessions that
  /// wrote last, so it does not gain an entry per session for as long as the app runs.
  private(set) var contextLeft: [String: Double] = [:]
  /// Session ids of `contextLeft`, the one that wrote last at the end.
  @ObservationIgnored private var contextOrder: [String] = []
  static let contextKept = 32
  /// A session's context fell under the alert mark (session id, percent left).
  @ObservationIgnored var onContextLow: (@MainActor (String, Double) -> Void)?

  @ObservationIgnored var onNote: (@MainActor (ModuleNote) -> Void)?
  @ObservationIgnored private var source: DispatchSourceFileSystemObject?
  /// Warned "<reset>:<mark>" keys, kept across launches: a window stays at 80% until its reset
  /// (a weekly one for days) and must not warn again after every restart. Keys of passed resets
  /// are dropped.
  @ObservationIgnored private var warned: Set<String>
  @ObservationIgnored private let defaults = NotchSettings.defaultStore
  private static let warnedKey = "usage.warned"

  /// agy (Antigravity CLI) plan meters as % used, fed by `AgyWatcher` from agy-bridge's
  /// meters.json. nil: no agy-bridge on this Mac, or this module is off.
  private(set) var agy: AgyUsage?
  /// Warned agy keys ("agy:<pool>:<5h|week>:<mark>"), kept across launches. meters.json has no
  /// reset times, so a key is dropped once its window is back under the mark (`liveWarnings`).
  @ObservationIgnored private var agyWarned: Set<String>
  /// The last agy reading, kept while this module is off, so turning it on shows it at once.
  @ObservationIgnored private var lastAgy: AgyUsage?
  private static let agyWarnedKey = "usage.agyWarned"

  init() {
    let stored = Set(defaults.stringArray(forKey: Self.warnedKey) ?? [])
    warned = PlanUsage.liveWarnings(stored, at: Date())
    if warned != stored { defaults.set(Array(warned), forKey: Self.warnedKey) }
    agyWarned = Set(defaults.stringArray(forKey: Self.agyWarnedKey) ?? [])
  }

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
      if let u = lastAgy { setAgy(u) }
    } else if !on, let src = source {
      src.cancel()
      source = nil
      usage = nil
      agy = nil
    }
  }

  /// One chat's context window left: Claude's from the status line file, agy's from its
  /// per-process status line snapshot (`AgyWatcher`). Same row badge and low-context note.
  func recordContext(_ c: ContextLeft) {
    let previous = contextLeft[c.sessionID]
    if previous != c.percent { contextLeft[c.sessionID] = c.percent }
    if contextOrder.last != c.sessionID {
      contextOrder.removeAll { $0 == c.sessionID }
      contextOrder.append(c.sessionID)
      let extra = contextOrder.count - Self.contextKept
      if extra > 0 {
        for id in contextOrder.prefix(extra) { contextLeft[id] = nil }
        contextOrder.removeFirst(extra)
      }
    }
    if c.crossesAlert(from: previous) { onContextLow?(c.sessionID, c.percent) }
  }

  /// A new agy meters reading (nil: agy-bridge's file is gone). Warns like Claude's meters:
  /// 80% and 95% of each 5-hour window, weekly windows only with the weekly setting on, and
  /// never from a reading older than 15 minutes (`AgyUsage.alerts`).
  func setAgy(_ u: AgyUsage?) {
    lastAgy = u
    guard source != nil else { return }
    guard u != agy else { return }
    agy = u
    guard let u else { return }
    let now = Date()
    let weekly = WeeklyUsageAlerts.enabled(
      stored: defaults.object(forKey: WeeklyUsageAlerts.defaultsKey))
    var shown = u.liveWarnings(agyWarned)
    for a in u.alerts(shown: shown, at: now, weekly: weekly) {
      shown.insert(a.key)
      let pool = u.pools.first { $0.label == a.poolLabel }
      let percent = (a.kind == .fiveHour ? pool?.fiveHour : pool?.weekly) ?? Double(a.mark)
      onNote?(
        ModuleNote(
          source: .usage, id: "usage:\(a.key)", title: a.title,
          digits: "\(Int(percent.rounded()))", unit: "%",
          validUntil: now.addingTimeInterval(30 * 60)))
    }
    if shown != agyWarned {
      agyWarned = shown
      defaults.set(Array(shown), forKey: Self.agyWarnedKey)
    }
  }

  private func read() {
    guard let data = try? Data(contentsOf: Self.file) else { return }
    if let c = ContextLeft.statusLine(data) { recordContext(c) }
    let now = Date()
    guard let u = PlanUsage.statusLine(data, at: now) else { return }
    guard u != usage else { return }
    usage = u
    // Only a running window warns: a file older than its reset (Claude Code not run since)
    // must not show a past window's 80%.
    let weekly = WeeklyUsageAlerts.enabled(
      stored: defaults.object(forKey: WeeklyUsageAlerts.defaultsKey))
    if let a = u.alert(shown: warned, at: now, weekly: weekly) {
      let w = a.window
      warned = PlanUsage.liveWarnings(warned, at: now)
      warned.insert(a.key)
      defaults.set(Array(warned), forKey: Self.warnedKey)
      let subtitle =
        a.kind == .fiveHour
        ? loc("Resets at \(ModuleCenter.clock(w.resetsAt))")
        : loc("Resets \(BandUsage.day(w.resetsAt))")
      onNote?(
        ModuleNote(
          source: .usage, id: "usage:\(a.key)", title: a.title, subtitle: subtitle,
          digits: "\(Int(w.percent.rounded()))", unit: "%", validUntil: w.resetsAt))
    }
  }
}
