import Foundation

/// Parsed Claude Code hook payload (only the fields ClaudeNotch cares about).
public struct HookEvent: Sendable, Equatable {
  public var name: String
  public var sessionID: String
  public var cwd: String
  public var toolName: String?
  public var toolInput: JSONValue?
  public var message: String?
  public var title: String?
  public var notificationType: String?
  public var lastAssistantMessage: String?
  public var errorText: String?
  public var suggestions: [JSONValue]
  /// Set for events fired inside a subagent / teammate; `nil` for the main agent.
  public var agentID: String?
  /// `agent_type` (subagent name such as "Explore"), if present.
  public var agentType: String?
  /// SessionStart `source`: "startup", "resume", "clear", "compact" (nil when absent).
  public var source: String?

  public init(
    name: String, sessionID: String, cwd: String = "", toolName: String? = nil,
    toolInput: JSONValue? = nil, message: String? = nil, title: String? = nil,
    notificationType: String? = nil, lastAssistantMessage: String? = nil,
    errorText: String? = nil, suggestions: [JSONValue] = [], agentID: String? = nil,
    agentType: String? = nil, source: String? = nil
  ) {
    self.name = name
    self.sessionID = sessionID
    self.cwd = cwd
    self.toolName = toolName
    self.toolInput = toolInput
    self.message = message
    self.title = title
    self.notificationType = notificationType
    self.lastAssistantMessage = lastAssistantMessage
    self.errorText = errorText
    self.suggestions = suggestions
    self.agentID = agentID
    self.agentType = agentType
    self.source = source
  }

  public static func parse(_ data: Data) -> HookEvent? {
    guard let root = JSONValue.parse(data), root.objectValue != nil,
      let name = root["hook_event_name"]?.stringValue,
      let sid = root["session_id"]?.stringValue, !sid.isEmpty
    else { return nil }
    let errorParts = [root["error"]?.stringValue, root["error_details"]?.stringValue]
      .compactMap { $0 }.filter { !$0.isEmpty }
    return HookEvent(
      name: name, sessionID: sid, cwd: root["cwd"]?.stringValue ?? "",
      toolName: root["tool_name"]?.stringValue, toolInput: root["tool_input"],
      message: root["message"]?.stringValue, title: root["title"]?.stringValue,
      notificationType: root["notification_type"]?.stringValue,
      lastAssistantMessage: root["last_assistant_message"]?.stringValue,
      errorText: errorParts.isEmpty ? nil : errorParts.joined(separator: ": "),
      suggestions: root["permission_suggestions"]?.arrayValue ?? [],
      agentID: root["agent_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      agentType: root["agent_type"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      source: root["source"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    )
  }

  /// session + tool + canonical tool_input; identifies one tool call across hook events.
  public var callKey: String? {
    guard let toolName else { return nil }
    return CallKey.make(sessionID: sessionID, toolName: toolName, input: toolInput)
  }

  /// AskUserQuestion: first question's text and its option labels (sanitized), if present.
  public var question: (text: String, options: [String])? {
    guard toolName == "AskUserQuestion",
      let first = toolInput?["questions"]?.arrayValue?.first
    else { return nil }
    let raw = first["question"]?.stringValue ?? first["header"]?.stringValue ?? ""
    // Display text, not a security decision: whitespace runs (newlines too) become one space.
    let text = ToolSummary.sanitize(
      raw.split(whereSeparator: \.isWhitespace).joined(separator: " "), limit: 300)
    let options = (first["options"]?.arrayValue ?? []).prefix(8).compactMap { opt -> String? in
      let label = opt["label"]?.stringValue ?? opt.stringValue
      return label.map { ToolSummary.sanitize($0, limit: 80) }
    }
    return (text, options)
  }

  /// ExitPlanMode: first non-empty line of the injected plan, without Markdown heading marks.
  public var planSummary: String? {
    guard toolName == "ExitPlanMode", let plan = toolInput?["plan"]?.stringValue else {
      return nil
    }
    for line in plan.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")).trimmingCharacters(
          in: .whitespaces)
      if !trimmed.isEmpty { return ToolSummary.sanitize(trimmed, limit: 200) }
    }
    return nil
  }

  public var projectName: String {
    let last = (cwd as NSString).lastPathComponent
    return last.isEmpty || last == "/" ? "Oturum" : last
  }
}

public enum CallKey {
  public static func make(sessionID: String, toolName: String, input: JSONValue?) -> String {
    "\(sessionID)\u{1}\(toolName)\u{1}\((input ?? .null).canonical())"
  }
}

public enum ToolSummary {
  public static let maxLength = 400
  /// Hard cap for the full text kept for the expanded view.
  public static let fullLimit = 20_000
  /// Collapsed card text longer than this (display columns) hides part of the request.
  public static let fitLimit = 240

  /// Principal text of the request (command / path / url / MCP tool + args), sanitized and
  /// truncated to `maxLength`.
  public static func make(toolName: String, input: JSONValue?) -> String {
    truncate(fullText(toolName: toolName, input: input))
  }

  /// The same text without the 400 character cut (capped at `fullLimit`), sanitized.
  public static func fullText(toolName: String, input: JSONValue?) -> String {
    sanitize(principal(toolName: toolName, input: input), limit: fullLimit)
  }

  static func principal(toolName: String, input: JSONValue?) -> String {
    switch toolName {
    case "Bash":
      return input?["command"]?.stringValue ?? compact(input)
    case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
      return input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue
        ?? compact(input)
    case "WebFetch":
      return input?["url"]?.stringValue ?? compact(input)
    default:
      guard toolName.hasPrefix("mcp__") else { return compact(input) }
      let parts = toolName.dropFirst(5).components(separatedBy: "__")
      let server = parts.first ?? ""
      let tool = parts.dropFirst().joined(separator: "__")
      let name = tool.isEmpty ? server : "\(server)/\(tool)"
      let args = compact(input)
      return args.isEmpty || args == "{}" ? name : "\(name) \(args)"
    }
  }

  /// Extra detail (written content, edit before/after) that the collapsed card does not show.
  public static func extra(toolName: String, input: JSONValue?) -> String? {
    func field(_ key: String) -> String? { input?[key]?.stringValue }
    switch toolName {
    case "Write":
      guard let content = field("content") else { return nil }
      return sanitize("içerik (\(content.count) karakter): \(content)", limit: 4000)
    case "Edit":
      guard let old = field("old_string"), let new = field("new_string") else { return nil }
      return sanitize("eski: \(old)\nyeni: \(new)", limit: 4000)
    case "MultiEdit":
      guard let edits = input?["edits"], edits != .null else { return nil }
      return sanitize("düzenlemeler: \(edits.canonical())", limit: 4000)
    case "NotebookEdit":
      guard let src = field("new_source") else { return nil }
      return sanitize("yeni kaynak: \(src)", limit: 4000)
    default:
      return nil
    }
  }

  public static func compact(_ input: JSONValue?) -> String {
    guard let input, input != .null else { return "" }
    return input.canonical()
  }

  public static func truncate(_ s: String, _ limit: Int = maxLength) -> String {
    s.count <= limit ? s : String(s.prefix(limit)) + "…"
  }

  /// Approximate display columns (wide / non-ASCII scalars count double).
  public static func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
  }

  /// Text for the collapsed card: whole text when it fits, otherwise head + hidden-count
  /// marker + tail, so a payload appended after a long prefix stays visible.
  public static func collapsed(_ full: String) -> String {
    guard displayWidth(full) > fitLimit else { return full }
    let chars = Array(full)
    let head = 150
    let tail = 70
    guard chars.count > head + tail else { return String(chars.prefix(fitLimit)) + "…" }
    let hidden = chars.count - head - tail
    return String(chars.prefix(head)) + " … [\(hidden) karakter gizli] … "
      + String(chars.suffix(tail))
  }

  /// Makes invisible / deceptive characters visible: newlines and tabs as `\n` `\t`,
  /// control, bidi, zero-width and other format characters as `\u{XXXX}`, long runs of spaces
  /// as `⟨N boşluk⟩`. Output is cut at `limit` characters with a marker.
  public static func sanitize(_ s: String, limit: Int = .max) -> String {
    var out = ""
    var spaces = 0
    var count = 0
    func flushSpaces() {
      if spaces >= 4 {
        out += "⟨\(spaces) boşluk⟩"
      } else {
        out += String(repeating: " ", count: spaces)
      }
      spaces = 0
    }
    for scalar in s.unicodeScalars {
      if count >= limit {
        flushSpaces()
        return out + "… [kesildi]"
      }
      count += 1
      if scalar == " " {
        spaces += 1
        continue
      }
      flushSpaces()
      switch scalar {
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if isDeceptive(scalar) {
          out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    flushSpaces()
    return out
  }

  static func isDeceptive(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator,
      .privateUse, .unassigned, .surrogate:
      return true
    default:
      return false
    }
  }

  /// Human readable description of a permission suggestion (for the "Her zaman" tooltip).
  public static func describeSuggestion(_ s: JSONValue) -> String {
    let type = s["type"]?.stringValue ?? "?"
    let dest = s["destination"]?.stringValue
    var core: String
    switch type {
    case "addRules", "replaceRules", "removeRules":
      let rules = (s["rules"]?.arrayValue ?? []).map { r -> String in
        let tool = r["toolName"]?.stringValue ?? "?"
        if let c = r["ruleContent"]?.stringValue, !c.isEmpty { return "\(tool)(\(c))" }
        return tool
      }
      core = rules.joined(separator: ", ")
    case "setMode":
      core = "mod: \(s["mode"]?.stringValue ?? "?")"
    case "addDirectories", "removeDirectories":
      core = (s["directories"]?.arrayValue ?? []).compactMap { $0.stringValue }
        .joined(separator: ", ")
    default:
      core = type
    }
    if let dest { core += " → \(dest)" }
    // Whole, never cut: "Her zaman" saves exactly this rule, so the user must be able to see
    // all of it (the card scrolls a long rule). Sanitized: newlines / bidi / zero-width
    // characters in raw rule content become visible.
    return sanitize(core)
  }
}

public enum PermissionDecision: Sendable, Equatable {
  case allow
  case always
  case deny(message: String)

  public static let defaultDenyMessage = "Kullanıcı bu isteği ClaudeNotch üzerinden reddetti."

  /// JSON body to print from the PermissionRequest hook.
  public func responseBody(suggestions: [JSONValue]) -> Data {
    var decision: [String: JSONValue]
    switch self {
    case .allow:
      decision = ["behavior": .string("allow")]
    case .always:
      decision = ["behavior": .string("allow")]
      let pick = suggestions.first { $0["type"]?.stringValue == "addRules" } ?? suggestions.first
      if let pick { decision["updatedPermissions"] = .array([pick]) }
    case .deny(let message):
      decision = [
        "behavior": .string("deny"), "message": .string(message), "interrupt": .bool(false)
      ]
    }
    let root: JSONValue = .object([
      "hookSpecificOutput": .object([
        "hookEventName": .string("PermissionRequest"),
        "decision": .object(decision)
      ])
    ])
    return root.encoded()
  }
}
