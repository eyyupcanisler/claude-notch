import Darwin
import Foundation

/// One process as the discovery pass sees it. Only processes with a controlling terminal carry
/// the expensive fields (path, argv, cwd, TERM_PROGRAM).
public struct ProcessRecord: Sendable, Equatable {
  public var pid: Int32
  public var ppid: Int32
  /// Validated controlling terminal ("/dev/ttysNNN"), nil when it has none.
  public var tty: String?
  /// Executable path (`proc_pidpath`).
  public var path: String?
  /// Command line (argv); argv[0] first.
  public var args: [String]
  /// Current directory (`PROC_PIDVNODEPATHINFO`).
  public var cwd: String?
  /// TERM_PROGRAM from the process environment (validated), if readable.
  public var termProgram: String?
  /// `__CFBundleIdentifier` from the process environment: the app it was started in
  /// (validated, see `TerminalHost`).
  public var termBundle: String?
  /// When the process started (`pbi_start_tvsec` / `pbi_start_tvusec`).
  public var startedAt: Date?
  /// Stopped (Ctrl-Z, or the old process `/restart` leaves behind): it runs nothing.
  public var stopped: Bool
  /// In its terminal's foreground process group (what the tab is showing).
  public var foreground: Bool
  /// GHOSTTY_SURFACE_ID from the environment: the Ghostty tab or split it was started in
  /// (validated). Inherited by everything started there, even by a daemon's processes.
  public var surfaceID: String?
  /// CLAUDE_CODE_SESSION_KIND is "bg": a chat Claude Code's background daemon runs, on a
  /// hidden terminal of its own.
  public var backgroundSession: Bool

  public init(
    pid: Int32, ppid: Int32, tty: String? = nil, path: String? = nil, args: [String] = [],
    cwd: String? = nil, termProgram: String? = nil, startedAt: Date? = nil,
    stopped: Bool = false, foreground: Bool = true, surfaceID: String? = nil,
    backgroundSession: Bool = false, termBundle: String? = nil
  ) {
    self.pid = pid
    self.ppid = ppid
    self.tty = tty
    self.path = path
    self.args = args
    self.cwd = cwd
    self.termProgram = termProgram
    self.termBundle = termBundle
    self.startedAt = startedAt
    self.stopped = stopped
    self.foreground = foreground
    self.surfaceID = surfaceID
    self.backgroundSession = backgroundSession
  }

  /// A Ghostty surface id as it appears in GHOSTTY_SURFACE_ID ("0x" and 1-16 hex digits).
  public static func validSurfaceID(_ raw: String?) -> String? {
    guard let raw, raw.hasPrefix("0x") else { return nil }
    let digits = raw.dropFirst(2)
    guard (1...16).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
    return raw.lowercased()
  }
}

/// Lists processes in-process (libproc / sysctl, no `ps`), injectable for tests.
public struct ProcessLister: Sendable {
  public var list: @Sendable () -> [ProcessRecord]

  public init(list: @escaping @Sendable () -> [ProcessRecord]) {
    self.list = list
  }

  public static let system = ProcessLister { SystemProcesses.list() }
}

public enum ClaudeProcess {
  /// The process is Claude Code: the native build (`~/.local/share/claude/versions/<v>`, started
  /// as `claude`), a `claude` executable, or node running Claude Code's cli.js.
  public static func isClaude(_ r: ProcessRecord) -> Bool {
    let exe = r.path.map { ($0 as NSString).lastPathComponent } ?? ""
    let arg0 = r.args.first.map { ($0 as NSString).lastPathComponent } ?? ""
    if exe == "claude" || arg0 == "claude" { return true }
    if let path = r.path, path.contains("/claude/versions/") { return true }
    if exe == "node" || arg0 == "node" {
      return r.args.dropFirst().contains {
        $0.hasSuffix("@anthropic-ai/claude-code/cli.js") || $0.hasSuffix("/bin/claude")
      }
    }
    return false
  }

  /// A spare Claude Code process the background daemon starts ahead of time (`claude bg-spare`):
  /// not a chat.
  public static func isSpare(_ r: ProcessRecord) -> Bool {
    r.args.contains("--bg-spare") || r.args.dropFirst().first == "bg-spare"
  }

  /// Interactive top-level Claude Code processes, at most one per tab: Claude, on a terminal,
  /// running (not stopped), not a daemon spare, and its parent is not a Claude process. Shell
  /// wrappers in between are looked through (`zsh -c claude` run by another session's tool
  /// still has that session as its real parent), like the hook bridge does when it looks for
  /// the claude process. Several left in one tab (its terminal, or a hidden terminal linked to
  /// it by `tabTTYs`): the daemon's chat (the tab only shows it through a client), else the one
  /// in the foreground, else the newest.
  public static func sessions(in records: [ProcessRecord]) -> [ProcessRecord] {
    let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    let candidates = records.filter { r in
      guard r.tty != nil, isClaude(r), !r.stopped, !isSpare(r) else { return false }
      var p = r.ppid
      for _ in 0..<8 {
        guard p > 1, let parent = byPID[p] else { return true }
        if isClaude(parent) { return false }
        guard isShell(parent) else { return true }
        p = parent.ppid
      }
      return true
    }
    let tabs = tabTTYs(in: records)
    let byTab = Dictionary(grouping: candidates) { r in r.tty.map { tabs[$0] ?? $0 } ?? "" }
    let rank = { (r: ProcessRecord) in
      (r.backgroundSession ? 1 : 0, r.foreground ? 1 : 0, r.startedAt ?? .distantPast, r.pid)
    }
    return byTab.values.compactMap { group in group.max { rank($0) < rank($1) } }
      .sorted { $0.pid < $1.pid }
  }

  /// Which tab each hidden terminal belongs to (hidden terminal -> the tab's terminal). A chat
  /// Claude Code's background daemon runs (`backgroundSession`) sits on a terminal no tab
  /// shows; the tab is the one terminal whose processes carry the same Ghostty tab id. No link
  /// when that is ambiguous or unknown. Terminals that host a daemon chat or a spare never count
  /// as the tab (that chat's own tools carry the id too), and a spare is never linked: it
  /// carries the id of whichever tab started the daemon, not of the tab that later uses it.
  public static func tabTTYs(in records: [ProcessRecord]) -> [String: String] {
    let daemonChats = records.filter { $0.backgroundSession && isClaude($0) && !isSpare($0) }
    let hidden = Set(
      records.filter { ($0.backgroundSession && isClaude($0)) || isSpare($0) }.compactMap(\.tty))
    var bySurface: [String: Set<String>] = [:]
    for r in records {
      guard let tty = r.tty, !hidden.contains(tty), let id = r.surfaceID else { continue }
      bySurface[id, default: []].insert(tty)
    }
    var out: [String: String] = [:]
    for r in daemonChats {
      guard let tty = r.tty, let id = r.surfaceID, let tabs = bySurface[id], tabs.count == 1,
        let tab = tabs.first
      else { continue }
      out[tty] = tab
    }
    return out
  }

  static func isShell(_ r: ProcessRecord) -> Bool {
    let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]
    let exe = r.path.map { ($0 as NSString).lastPathComponent } ?? ""
    var arg0 = r.args.first.map { ($0 as NSString).lastPathComponent } ?? ""
    if arg0.hasPrefix("-") { arg0.removeFirst() }
    return shells.contains(exe) || shells.contains(arg0)
  }
}

/// libproc / sysctl readers behind `ProcessLister.system`.
enum SystemProcesses {
  static func list() -> [ProcessRecord] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(count) + 64)
    let got = pids.withUnsafeMutableBytes { buf in
      proc_listallpids(buf.baseAddress, Int32(buf.count))
    }
    guard got > 0 else { return [] }
    var out: [ProcessRecord] = []
    out.reserveCapacity(Int(got))
    for pid in pids.prefix(Int(got)) where pid > 0 {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
      var r = ProcessRecord(pid: pid, ppid: Int32(bitPattern: info.pbi_ppid))
      r.stopped = info.pbi_status == UInt32(SSTOP)
      r.foreground = info.pbi_pgid == info.e_tpgid
      if info.pbi_start_tvsec > 0 {
        r.startedAt = Date(
          timeIntervalSince1970: Double(info.pbi_start_tvsec)
            + Double(info.pbi_start_tvusec) / 1_000_000)
      }
      let dev = dev_t(bitPattern: info.e_tdev)
      if dev != -1, let tty = ttyName(dev) {
        r.tty = tty
        r.path = path(pid)
        r.cwd = cwd(pid)
        let (args, env) = arguments(pid)
        r.args = args
        r.termProgram = HookContext.validTermProgram(env["TERM_PROGRAM"])
        r.termBundle = TerminalHost.validBundleID(env["__CFBundleIdentifier"])
        r.surfaceID = ProcessRecord.validSurfaceID(env["GHOSTTY_SURFACE_ID"])
        r.backgroundSession = env["CLAUDE_CODE_SESSION_KIND"] == "bg"
      }
      out.append(r)
    }
    return out
  }

  static func ttyName(_ dev: dev_t) -> String? {
    var buf = [CChar](repeating: 0, count: 64)
    guard let name = devname_r(dev, S_IFCHR, &buf, Int32(buf.count)) else { return nil }
    return HookContext.validTTY("/dev/" + String(cString: name))
  }

  static func path(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func cwd(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
      let bytes = raw.prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }
    return path.hasPrefix("/") ? path : nil
  }

  /// argv and the environment from KERN_PROCARGS2 (only readable for the user's own
  /// processes): argc, the exec path, padding, argv, then the environment.
  static func arguments(_ pid: Int32) -> ([String], [String: String]) {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 4 << 20 else {
      return ([], [:])
    }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
    return ProcArgs.parse(Array(buf.prefix(size)))
  }
}

/// The KERN_PROCARGS2 layout: argc (Int32), the exec path, NUL padding, argc NUL-terminated
/// argv strings (empty ones included), then NUL-terminated environment strings up to an empty
/// one or the end. Pure, so it is tested without a process.
public enum ProcArgs {
  public static func parse(_ data: [UInt8]) -> ([String], [String: String]) {
    let size = data.count
    guard size > 4 else { return ([], [:]) }
    let argc = data.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    guard argc > 0, argc < 4096 else { return ([], [:]) }
    var i = 4
    // Exec path, then NUL padding.
    while i < size, data[i] != 0 { i += 1 }
    while i < size, data[i] == 0 { i += 1 }
    var args: [String] = []
    var start = i
    while i < size, args.count < argc {
      if data[i] == 0 {
        args.append(String(decoding: data[start..<i], as: UTF8.self))
        start = i + 1
      }
      i += 1
    }
    var env: [String: String] = [:]
    start = i
    while i < size {
      if data[i] == 0 {
        if i == start { break }
        let item = String(decoding: data[start..<i], as: UTF8.self)
        if let eq = item.firstIndex(of: "=") {
          env[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        start = i + 1
      }
      i += 1
    }
    return (args, env)
  }
}

// MARK: - Store: discovered sessions

extension SessionStore {
  /// Id prefix of a session found by the process scan (no hook event seen yet).
  public static let discoveredPrefix = "found:"
  /// How often the app scans for Claude Code processes.
  public static let discoveryInterval: TimeInterval = 5
  /// A process whose session just ended (SessionEnd) is not re-discovered for this long: it is
  /// usually exiting, or about to start a new session (/clear).
  public static let endedGrace: TimeInterval = 10

  /// Applies one process scan: every top-level Claude Code process in a tab that no hook
  /// session owns (same tab, tty or pid) gets an idle "discovered" session; placeholders whose
  /// process is gone, or that a hook session now owns, are dropped. A chat on a hidden terminal
  /// (Claude Code's background daemon) is linked to its tab (`ClaudeProcess.tabTTYs`). A hook
  /// chat whose process is stopped while another Claude runs in its tab leaves: the tab shows
  /// the other one (Ctrl-Z, or the old process `/restart` leaves behind).
  public func applyDiscovery(_ records: [ProcessRecord]) {
    let t = now()
    let found = ClaudeProcess.sessions(in: records)
    let tabs = ClaudeProcess.tabTTYs(in: records)
    if tabTTYs != tabs { tabTTYs = tabs }
    for (id, s) in sessions {
      var linked = s
      link(&linked)
      if linked != s { sessions[id] = linked }
    }
    endedPIDs = endedPIDs.filter { t.timeIntervalSince($0.value) < Self.endedGrace }
    let stopped = Set(records.filter(\.stopped).map(\.pid))
    let runningTabs = Set(found.compactMap { r in r.tty.map { tabs[$0] ?? $0 } })
    for s in sessions.values where !s.isDiscovered {
      guard let pid = s.pid, stopped.contains(pid), let tab = s.terminal,
        runningTabs.contains(tab), !found.contains(where: { $0.pid == pid })
      else { continue }
      removeSession(s.id)
    }
    let hook = sessions.values.filter { !$0.isDiscovered }
    let ownedTTYs = Set(hook.compactMap(\.tty)).union(hook.compactMap(\.terminal))
    let ownedPIDs = Set(hook.compactMap(\.pid))
    var wanted: Set<String> = []
    for r in found {
      guard let tty = r.tty, !ownedTTYs.contains(tty), !ownedTTYs.contains(tabs[tty] ?? tty),
        !ownedPIDs.contains(r.pid), endedPIDs[r.pid] == nil
      else { continue }
      let id = Self.discoveredPrefix + String(r.pid)
      wanted.insert(id)
      let cwd = r.cwd ?? ""
      let project = cwd.isEmpty ? "claude" : (cwd as NSString).lastPathComponent
      if var s = sessions[id] {
        if s.cwd != cwd || s.tty != tty {
          s.cwd = cwd
          s.project = project
          s.tty = tty
          link(&s)
          sessions[id] = s
        }
        continue
      }
      var placeholder = Session(
        id: id, project: project, cwd: cwd, termProgram: r.termProgram,
        termBundle: r.termBundle, tty: tty, pid: r.pid,
        status: .idle, isDiscovered: true, startedAt: Self.discoveredStart(r, scan: t),
        lastUpdate: t)
      link(&placeholder)
      sessions[id] = placeholder
      carryOrder(toPlaceholder: id, pid: r.pid, tty: tty)
      watchDiscoveredExit(sessionID: id, pid: r.pid)
    }
    for (id, s) in sessions where s.isDiscovered && !wanted.contains(id) {
      removeSession(id)
    }
  }

  /// A placeholder's place in the line: its process's real start time, so placeholders of one
  /// scan never tie (a tie would sort by id, and a merge into a UUID-named hook session would
  /// move it). Without a start time: the scan time plus a pid-ordered microsecond offset.
  static func discoveredStart(_ r: ProcessRecord, scan t: Date) -> Date {
    if let start = r.startedAt, start <= t { return start }
    return t.addingTimeInterval(Double(r.pid) / 1_000_000)
  }

  /// Links a session on a hidden terminal to its tab (`tabTTYs`), or unlinks it. A linked chat
  /// is a Ghostty one: the tab id that linked it is Ghostty's (the daemon's process may lack
  /// TERM_PROGRAM).
  func link(_ s: inout Session) {
    let tab = s.tty.flatMap { tabTTYs[$0] }
    if s.tabTTY != tab { s.tabTTY = tab }
    if tab != nil, s.termProgram == nil { s.termProgram = "ghostty" }
  }

  /// Placeholders a hook session with this identity replaces (same pid or same tty).
  func discoveredMatches(_ context: HookContext) -> [Session] {
    guard context.pid != nil || context.tty != nil else { return [] }
    return sessions.values.filter { s in
      s.isDiscovered
        && ((context.pid != nil && s.pid == context.pid)
          || (context.tty != nil && s.tty == context.tty))
    }
  }
}
