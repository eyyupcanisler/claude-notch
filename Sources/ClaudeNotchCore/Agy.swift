import Foundation

/// One agy hook call (camelCase JSON, measured on agy 1.5.14). Only the fields the notch uses.
public struct AgyHookPayload: Sendable, Equatable {
  public var event: String
  public var conversationID: String
  public var cwd: String
  public var modelName: String?
  public var invocationNum: Int?
  public var lastUserInput: String?
  public var stepIdx: Int?
  public var toolName: String?
  public var toolArgs: JSONValue?
  public var toolCallID: String?
  /// Stop: why the loop ended ("NO_TOOL_CALL", "ERROR", "USER_CANCELED", ...).
  public var terminationReason: String?
  /// Stop: the error text, present when it stopped on an error.
  public var errorText: String?
  /// Stop: false while background work the turn started still runs.
  public var fullyIdle: Bool?

  public init(event: String, conversationID: String, cwd: String) {
    self.event = event
    self.conversationID = conversationID
    self.cwd = cwd
  }

  /// `fallbackEvent` is the event name the hook command passes (older agy builds send none in
  /// the payload). nil when the root is not an object, the conversation or the event is missing.
  public static func parse(_ data: Data, fallbackEvent: String?) -> AgyHookPayload? {
    guard let root = JSONValue.parse(data), root.objectValue != nil else { return nil }
    let event = nonEmpty(root["hookEventName"]?.stringValue) ?? nonEmpty(fallbackEvent)
    guard let event, let conversation = nonEmpty(root["conversationId"]?.stringValue) else {
      return nil
    }
    var p = AgyHookPayload(
      event: event, conversationID: conversation, cwd: root["cwd"]?.stringValue ?? "")
    p.modelName = root["modelName"]?.stringValue
    p.invocationNum = AgyJSON.int(root["invocationNum"])
    p.lastUserInput = root["lastUserInput"]?.stringValue
    p.stepIdx = AgyJSON.int(root["stepIdx"])
    let call = root["toolCall"]
    p.toolName = call?["name"]?.stringValue
    p.toolCallID = call?["id"]?.stringValue
    if let args = call?["args"], args != .null { p.toolArgs = args }
    p.terminationReason = nonEmpty(root["terminationReason"]?.stringValue)
    p.errorText = nonEmpty(root["error"]?.stringValue)
    if case .bool(let idle)? = root["fullyIdle"] { p.fullyIdle = idle }
    return p
  }

  private static func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
  }
}

/// agy's tool names and argument keys, rewritten into Claude Code's shape so the activity text
/// and the summaries work unchanged.
public enum AgyTools {
  public static func claudeShape(name: String, args: JSONValue?) -> (toolName: String, input: JSONValue?) {
    switch name {
    case "run_command":
      return ("Bash", .object(["command": args?["CommandLine"] ?? .null]))
    case "write_file":
      return ("Write", withFilePath(args))
    case "edit_file":
      return ("Edit", withFilePath(args))
    case "read_file":
      return ("Read", withFilePath(args))
    default:
      // Other tools keep their args for the row's summary, unless they are large.
      guard let args, args.encoded().count <= maxArgsBytes else { return (name, nil) }
      return (name, args)
    }
  }

  /// Args of another tool larger than this are dropped (the row needs only a short summary).
  public static let maxArgsBytes = 8 * 1024

  /// Only the path: the row shows which file, and a file's content (write_file can carry a whole
  /// file) is never kept.
  private static func withFilePath(_ args: JSONValue?) -> JSONValue {
    let keys = ["TargetFile", "Path", "AbsolutePath", "FilePath"]
    guard let path = keys.compactMap({ args?[$0]?.stringValue }).first else { return .object([:]) }
    return .object(["file_path": .string(path)])
  }
}

/// Links one agy process (by pid) to its main chat and to the helper conversations it starts,
/// and turns agy's events into `HookEvent`s the session store already understands.
public struct AgyLinker: Sendable {
  private var mainByPid: [Int32: String] = [:]
  private var helpersByPid: [Int32: Set<String>] = [:]
  /// Pids whose main chat is inside a turn (between the prompt and the Stop).
  private var turnActive: Set<Int32> = []

  public init() {}

  public func mainConversation(pid: Int32) -> String? {
    mainByPid[pid]
  }

  public mutating func forget(pid: Int32) {
    mainByPid[pid] = nil
    helpersByPid[pid] = nil
    turnActive.remove(pid)
  }

  /// Decides whether the conversation is the process's main chat or a helper of it, then maps
  /// the event. `shownConversation` is the chat the status line shows (empty when unknown).
  public mutating func translate(
    _ p: AgyHookPayload, pid: Int32?, shownConversation: String? = nil
  ) -> HookEvent? {
    guard let pid else { return mainEvent(p, pid: nil) }
    let c = p.conversationID
    var isMain: Bool
    if mainByPid[pid] == c {
      // The known main chat stays main: the status line file can be stale (a pid reused within
      // the day agy-bridge keeps it, or a /new before the status line redraws).
      isMain = true
    } else if let shown = shownConversation, !shown.isEmpty {
      isMain = c == shown
    } else if helpersByPid[pid]?.contains(c) == true {
      isMain = false
    } else if mainByPid[pid] == nil || !turnActive.contains(pid) {
      isMain = true
    } else {
      isMain = false
    }
    let main = mainByPid[pid]
    if !isMain && main == nil { isMain = true }

    if isMain {
      if main != c { mainByPid[pid] = c }
      _ = helpersByPid[pid]?.remove(c)
      return mainEvent(p, pid: pid)
    }
    helpersByPid[pid, default: []].insert(c)
    guard let main else { return nil }
    return helperEvent(p, main: main)
  }

  /// The store event for a line of agy's CLI log, shown on the process's main chat.
  public func storeEvent(for e: AgyLogEvent, pid: Int32) -> HookEvent? {
    guard let main = mainByPid[pid] else { return nil }
    switch e {
    case .permissionShown(let tool, _):
      return HookEvent(
        name: "Notification", sessionID: main,
        message: loc("agy asks for permission: \(tool)"), notificationType: "permission_prompt")
    case .permissionAnswered:
      return HookEvent(name: "PostToolUse", sessionID: main)
    case .questionShown:
      return HookEvent(
        name: "Notification", sessionID: main, message: loc("agy is asking a question"),
        notificationType: "agent_needs_input")
    }
  }

  private mutating func mainEvent(_ p: AgyHookPayload, pid: Int32?) -> HookEvent? {
    let c = p.conversationID
    switch p.event {
    case "SessionStart":
      setTurn(pid, active: false)
      return HookEvent(name: "SessionStart", sessionID: c, cwd: p.cwd, source: "startup")
    case "PreInvocation":
      // protojson leaves zero values out: no invocationNum is the turn's first model call.
      guard (p.invocationNum ?? 0) == 0 else { return nil }
      setTurn(pid, active: true)
      return HookEvent(name: "UserPromptSubmit", sessionID: c, cwd: p.cwd)
    case "PreToolUse":
      setTurn(pid, active: true)
      return toolEvent("PreToolUse", p, sessionID: c, agentID: nil, agentType: nil, cwd: p.cwd)
    case "PostToolUse":
      return toolEvent("PostToolUse", p, sessionID: c, agentID: nil, agentType: nil, cwd: p.cwd)
    case "Stop":
      if p.terminationReason == "ERROR" {
        setTurn(pid, active: false)
        return HookEvent(name: "StopFailure", sessionID: c, cwd: p.cwd, errorText: p.errorText)
      }
      // Background work still running: shown as finished (a background shell such as a dev
      // server can run for good), but the turn stays open, so a helper that a background
      // workflow starts later is still linked to this chat.
      // protojson leaves `false` out, so only an explicit `fullyIdle: true` closes the turn.
      setTurn(pid, active: p.fullyIdle != true)
      return HookEvent(name: "Stop", sessionID: c, cwd: p.cwd)
    default:
      return nil
    }
  }

  /// A helper conversation shows as a subagent of the main chat; `cwd` stays empty so it never
  /// renames the row.
  private func helperEvent(_ p: AgyHookPayload, main: String) -> HookEvent? {
    let c = p.conversationID
    switch p.event {
    case "SessionStart", "PreInvocation":
      return HookEvent(
        name: "SubagentStart", sessionID: main, agentID: c, agentType: "helper")
    case "PreToolUse", "PostToolUse":
      return toolEvent(p.event, p, sessionID: main, agentID: c, agentType: "helper", cwd: "")
    case "Stop":
      return HookEvent(name: "SubagentStop", sessionID: main, agentID: c, agentType: "helper")
    default:
      return nil
    }
  }

  private func toolEvent(
    _ name: String, _ p: AgyHookPayload, sessionID: String, agentID: String?,
    agentType: String?, cwd: String
  ) -> HookEvent {
    let shape = p.toolName.map { AgyTools.claudeShape(name: $0, args: p.toolArgs) }
    return HookEvent(
      name: name, sessionID: sessionID, cwd: cwd, toolName: shape?.toolName,
      toolInput: shape?.input, agentID: agentID, agentType: agentType)
  }

  private mutating func setTurn(_ pid: Int32?, active: Bool) {
    guard let pid else { return }
    if active {
      turnActive.insert(pid)
    } else {
      turnActive.remove(pid)
    }
  }
}

/// One line of agy's CLI log that the notch reacts to.
public enum AgyLogEvent: Sendable, Equatable {
  case permissionShown(tool: String, step: Int)
  case permissionAnswered(conversationID: String, step: Int, approved: Bool)
  case questionShown(step: Int)

  /// Finds the three known phrases anywhere in the line; nil for every other line.
  public static func parse(_ line: String) -> AgyLogEvent? {
    if let r = line.range(of: "Surfacing tool confirmation: \"") {
      let rest = line[r.upperBound...]
      guard let close = rest.firstIndex(of: "\"") else { return nil }
      let tool = rest[..<close]
      guard !tool.isEmpty,
        let step = leadingNumber(rest[rest.index(after: close)...], prefix: " at step ")
      else { return nil }
      // Display text: sanitized, and at most 80 characters after the escapes.
      let clean = String(ToolSummary.sanitize(String(tool), limit: 80).prefix(80))
      return .permissionShown(tool: clean, step: step.value)
    }
    if let r = line.range(of: "Responding to tool confirmation: convID=") {
      let rest = line[r.upperBound...]
      guard let comma = rest.firstIndex(of: ",") else { return nil }
      let id = rest[..<comma]
      guard !id.isEmpty,
        let step = leadingNumber(rest[comma...], prefix: ", stepIdx=")
      else { return nil }
      if step.rest.hasPrefix(", approved=true") {
        return .permissionAnswered(conversationID: String(id), step: step.value, approved: true)
      }
      if step.rest.hasPrefix(", approved=false") {
        return .permissionAnswered(conversationID: String(id), step: step.value, approved: false)
      }
      return nil
    }
    if let r = line.range(of: "Surfacing ask_question at step ") {
      guard let step = Int(line[r.upperBound...].prefix { $0.isASCII && $0.isNumber }) else {
        return nil
      }
      return .questionShown(step: step)
    }
    return nil
  }

  /// The digits that follow `prefix` at the start of `s`, with the text after them.
  private static func leadingNumber(
    _ s: Substring, prefix: String
  ) -> (value: Int, rest: Substring)? {
    guard s.hasPrefix(prefix) else { return nil }
    let body = s.dropFirst(prefix.count)
    let digits = body.prefix { $0.isASCII && $0.isNumber }
    guard let value = Int(digits) else { return nil }
    return (value, body.dropFirst(digits.count))
  }
}

/// agy's plan meters (agy-bridge's meters.json, which stores percent LEFT). Shown as percent used.
public struct AgyUsage: Sendable, Equatable {
  public struct Pool: Sendable, Equatable {
    public let key: String
    public let label: String
    /// Percent used in the five-hour window, nil when the pool has none.
    public let fiveHour: Double?
    /// Percent used in the weekly window, nil when the pool has none.
    public let weekly: Double?

    public init(key: String, label: String, fiveHour: Double?, weekly: Double?) {
      self.key = key
      self.label = label
      self.fiveHour = fiveHour
      self.weekly = weekly
    }
  }

  public let pools: [Pool]
  public let readAt: Date

  public init(pools: [Pool], readAt: Date) {
    self.pools = pools
    self.readAt = readAt
  }

  private static let knownOrder = ["gemini", "claude", "argon"]
  /// Marks the notch warns at, highest first.
  private static let marks = [95, 80]

  /// nil without `ts` or without a pool that has a numeric window.
  public static func parse(_ data: Data) -> AgyUsage? {
    guard let root = JSONValue.parse(data), let ts = AgyJSON.number(root["ts"]),
      let meters = root["meters"]?.objectValue
    else { return nil }
    var pools: [Pool] = []
    for (key, value) in meters {
      guard let obj = value.objectValue else { continue }
      let five = used(obj["five_hour"])
      let week = used(obj["weekly"])
      guard five != nil || week != nil else { continue }
      pools.append(Pool(key: key, label: label(for: key), fiveHour: five, weekly: week))
    }
    guard !pools.isEmpty else { return nil }
    pools.sort { a, b in
      (rank(a.key), a.key) < (rank(b.key), b.key)
    }
    return AgyUsage(pools: pools, readAt: Date(timeIntervalSince1970: ts))
  }

  /// The highest used window over all pools (weekly is `.sevenDay`).
  public var fullest: (pool: Pool, kind: PlanUsage.WindowKind, percent: Double)? {
    let all = pools.flatMap { pool in
      Self.windows(of: pool).map { (pool: pool, kind: $0.kind, percent: $0.percent) }
    }
    return all.max { $0.percent < $1.percent }
  }

  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(readAt) > 15 * 60
  }

  /// Alerts for windows that reached 80% or 95% and whose key is not in `shown`. Only the
  /// highest reached mark counts, so a window at 97% never falls back to its 80% note.
  public func alerts(shown: Set<String>, at now: Date, weekly: Bool) -> [AgyUsageAlert] {
    guard !isStale(at: now) else { return [] }
    var out: [AgyUsageAlert] = []
    for pool in pools {
      for window in Self.windows(of: pool) where weekly || window.kind == .fiveHour {
        guard let mark = Self.marks.first(where: { window.percent >= Double($0) }) else {
          continue
        }
        let key = Self.alertKey(pool: pool.key, kind: window.kind, mark: mark)
        guard !shown.contains(key) else { continue }
        out.append(
          AgyUsageAlert(poolLabel: pool.label, kind: window.kind, mark: mark, key: key))
      }
    }
    return out
  }

  /// The warned keys whose window is still at or above the key's mark. meters.json has no
  /// reset times, so a window that dropped back is forgotten and can warn again.
  public func liveWarnings(_ keys: Set<String>) -> Set<String> {
    // A key goes only when its window is in this reading and back under the mark; a window the
    // reading lacks keeps its key, so a partial reading never makes a note repeat.
    var below = Set<String>()
    for pool in pools {
      for window in Self.windows(of: pool) {
        for mark in Self.marks where window.percent < Double(mark) {
          below.insert(Self.alertKey(pool: pool.key, kind: window.kind, mark: mark))
        }
      }
    }
    return keys.subtracting(below)
  }

  public static func alertKey(pool: String, kind: PlanUsage.WindowKind, mark: Int) -> String {
    let window = kind == .fiveHour ? "5h" : "week"
    return "agy:\(pool):\(window):\(mark)"
  }

  private static func windows(of pool: Pool) -> [(kind: PlanUsage.WindowKind, percent: Double)] {
    var out: [(kind: PlanUsage.WindowKind, percent: Double)] = []
    if let v = pool.fiveHour { out.append((kind: .fiveHour, percent: v)) }
    if let v = pool.weekly { out.append((kind: .sevenDay, percent: v)) }
    return out
  }

  /// Percent used from a percent-left value, clamped to 0...100.
  private static func used(_ v: JSONValue?) -> Double? {
    guard let left = AgyJSON.number(v) else { return nil }
    return 100 - min(max(left, 0), 100)
  }

  private static func rank(_ key: String) -> Int {
    knownOrder.firstIndex(of: key) ?? knownOrder.count
  }

  private static func label(for key: String) -> String {
    switch key {
    case "gemini": return "Gemini"
    case "claude": return "Claude+GPT"
    case "argon": return "Argon"
    default: break
    }
    let words = key.split(separator: " ").map(String.init)
    guard let first = words.first else { return key }
    if first == "Gemini", words.count > 1 { return "\(words[0]) \(words[1])" }
    return first
  }
}

/// One usage note: a window reached a mark (80 or 95).
public struct AgyUsageAlert: Sendable, Equatable {
  public let poolLabel: String
  public let kind: PlanUsage.WindowKind
  public let mark: Int
  public let key: String

  public init(poolLabel: String, kind: PlanUsage.WindowKind, mark: Int, key: String) {
    self.poolLabel = poolLabel
    self.kind = kind
    self.mark = mark
    self.key = key
  }

  public var title: String {
    let label = poolLabel
    switch (kind, mark >= 95) {
    case (.fiveHour, false): return loc("agy \(label): 5-hour limit at 80%")
    case (.fiveHour, true): return loc("agy \(label): 5-hour limit almost used up")
    case (.sevenDay, false): return loc("agy \(label): weekly limit at 80%")
    case (.sevenDay, true): return loc("agy \(label): weekly limit almost used up")
    }
  }
}

/// What the status line tells about one agy process: its chat, model and context left.
public struct AgyStatusSnapshot: Sendable, Equatable {
  public let conversationID: String?
  public let modelLabel: String?
  public let contextLeft: Double?

  public init(conversationID: String?, modelLabel: String?, contextLeft: Double?) {
    self.conversationID = conversationID
    self.modelLabel = modelLabel
    self.contextLeft = contextLeft
  }

  private static let efforts = ["low", "medium", "high", "xhigh", "max"]

  /// nil unless the root is an object.
  public static func parse(_ data: Data) -> AgyStatusSnapshot? {
    guard let root = JSONValue.parse(data), root.objectValue != nil else { return nil }
    let conversation = root["conversation_id"]?.stringValue
    let model = root["model"]
    let name = model?["display_name"]?.stringValue ?? ""
    let effort = model?["effort"]?.stringValue ?? ""
    var label: String? = nil
    if !name.isEmpty {
      label = effort.isEmpty ? name : "\(withoutGroup(name)) · \(effort)"
    }
    let window = root["context_window"]
    let left =
      AgyJSON.number(window?["remaining_percentage"])
      ?? AgyJSON.number(window?["used_percentage"]).map { 100 - $0 }
    return AgyStatusSnapshot(
      conversationID: conversation.flatMap { $0.isEmpty ? nil : $0 },
      modelLabel: label, contextLeft: left)
  }

  /// The model name from a hook payload, with a trailing effort word shown after " · ".
  public static func label(forModelName name: String) -> String? {
    guard !name.isEmpty else { return nil }
    guard let dash = name.range(of: "-", options: .backwards) else { return name }
    let effort = String(name[dash.upperBound...])
    let rest = name[..<dash.lowerBound]
    guard efforts.contains(effort), !rest.isEmpty else { return name }
    return "\(rest) · \(effort)"
  }

  /// "Gemini 4 Neon (Medium)" becomes "Gemini 4 Neon".
  private static func withoutGroup(_ s: String) -> String {
    guard s.hasSuffix(")"), let open = s.range(of: " (", options: .backwards) else { return s }
    return String(s[..<open.lowerBound])
  }
}

/// Number reading shared by the agy parsers (JSON may carry an int or a double).
fileprivate enum AgyJSON {
  static func number(_ v: JSONValue?) -> Double? {
    switch v {
    case .int(let i)?: return Double(i)
    case .double(let d)?: return d.isFinite ? d : nil
    default: return nil
    }
  }

  static func int(_ v: JSONValue?) -> Int? {
    switch v {
    case .int(let i)?: return i
    case .double(let d)?: return d.isFinite && abs(d) < 1e15 ? Int(d) : nil
    default: return nil
    }
  }
}
