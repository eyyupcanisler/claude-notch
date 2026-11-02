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
  /// When the process started (`pbi_start_tvsec` / `pbi_start_tvusec`).
  public var startedAt: Date?

  public init(
    pid: Int32, ppid: Int32, tty: String? = nil, path: String? = nil, args: [String] = [],
    cwd: String? = nil, termProgram: String? = nil, startedAt: Date? = nil
  ) {
    self.pid = pid
    self.ppid = ppid
    self.tty = tty
    self.path = path
    self.args = args
    self.cwd = cwd
    self.termProgram = termProgram
    self.startedAt = startedAt
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

  /// Interactive top-level Claude Code processes: Claude, on a terminal, and its parent is not
  /// a Claude process. Shell wrappers in between are looked through (`zsh -c claude` run by
  /// another session's tool still has that session as its real parent), like the hook bridge
  /// does when it looks for the claude process.
  public static func sessions(in records: [ProcessRecord]) -> [ProcessRecord] {
    let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    return records.filter { r in
      guard r.tty != nil, isClaude(r) else { return false }
      var p = r.ppid
      for _ in 0..<8 {
        guard p > 1, let parent = byPID[p] else { return true }
        if isClaude(parent) { return false }
        guard isShell(parent) else { return true }
        p = parent.ppid
      }
      return true
    }.sorted { $0.pid < $1.pid }
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
    let data = buf.prefix(size)
    let argc = data.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    guard argc > 0, argc < 4096 else { return ([], [:]) }
    var i = 4
    // Exec path, then NUL padding.
    while i < size, data[i] != 0 { i += 1 }
    while i < size, data[i] == 0 { i += 1 }
    var strings: [String] = []
    var start = i
    while i < size {
      if data[i] == 0 {
        if i == start { break }
        strings.append(String(decoding: data[start..<i], as: UTF8.self))
        start = i + 1
      }
      i += 1
    }
    let args = Array(strings.prefix(argc))
    var env: [String: String] = [:]
    for item in strings.dropFirst(argc) {
      guard let eq = item.firstIndex(of: "=") else { continue }
      env[String(item[..<eq])] = String(item[item.index(after: eq)...])
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

  /// Applies one process scan: every top-level Claude Code process on a terminal that no hook
  /// session owns (same tty or pid) gets an idle "discovered" session; placeholders whose
  /// process is gone, or that a hook session now owns, are dropped.
  public func applyDiscovery(_ records: [ProcessRecord]) {
    let t = now()
    let found = ClaudeProcess.sessions(in: records)
    endedPIDs = endedPIDs.filter { t.timeIntervalSince($0.value) < Self.endedGrace }
    let hook = sessions.values.filter { !$0.isDiscovered }
    let ownedTTYs = Set(hook.compactMap(\.tty))
    let ownedPIDs = Set(hook.compactMap(\.pid))
    var wanted: Set<String> = []
    for r in found {
      guard let tty = r.tty, !ownedTTYs.contains(tty), !ownedPIDs.contains(r.pid),
        endedPIDs[r.pid] == nil
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
          sessions[id] = s
        }
        continue
      }
      sessions[id] = Session(
        id: id, project: project, cwd: cwd, termProgram: r.termProgram, tty: tty, pid: r.pid,
        status: .idle, isDiscovered: true, startedAt: Self.discoveredStart(r, scan: t),
        lastUpdate: t)
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
