import Foundation

/// One question of an `AskUserQuestion` call.
public struct AskedQuestion: Sendable, Equatable {
  public struct Option: Sendable, Equatable {
    public var label: String
    public var description: String
  }

  public var question: String
  public var header: String
  public var options: [Option]
  public var multiSelect: Bool

  /// Parses `tool_input.questions`; nil when the shape is not the documented one.
  public static func parse(_ input: JSONValue?) -> [AskedQuestion]? {
    guard let list = input?["questions"]?.arrayValue, !list.isEmpty else { return nil }
    var out: [AskedQuestion] = []
    for q in list {
      guard let text = q["question"]?.stringValue, !text.isEmpty,
        let opts = q["options"]?.arrayValue, !opts.isEmpty
      else { return nil }
      let options = opts.compactMap { o -> Option? in
        guard let l = o["label"]?.stringValue, !l.isEmpty else { return nil }
        return Option(label: l, description: o["description"]?.stringValue ?? "")
      }
      guard options.count == opts.count else { return nil }
      var multi = false
      if case .bool(let b)? = q["multiSelect"] { multi = b }
      out.append(
        AskedQuestion(
          question: text, header: q["header"]?.stringValue ?? "", options: options,
          multiSelect: multi))
    }
    return out
  }
}

/// An `AskUserQuestion` call held by its PreToolUse hook until it is answered from the notch,
/// or released to the terminal (an empty reply: the terminal shows the question as usual).
public struct PendingQuestion: Sendable, Identifiable {
  public let id: String
  public let sessionID: String
  public let agentID: String?
  public let questions: [AskedQuestion]
  /// The tool input as it arrived (echoed back with the answers: `updatedInput` replaces it).
  public let toolInput: JSONValue
  public let createdAt: Date
  public let reply: PermissionReply

  /// The hook reply that answers it: PreToolUse "allow" with the input plus `answers`, keyed
  /// by question text. Several labels of a multi-select question are joined with ", ".
  public static func answerBody(toolInput: JSONValue, answers: [String: [String]]) -> Data {
    var input = toolInput.objectValue ?? [:]
    input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
    let out: JSONValue = .object([
      "hookSpecificOutput": .object([
        "hookEventName": .string("PreToolUse"),
        "permissionDecision": .string("allow"),
        "permissionDecisionReason": .string(loc("ClaudeNotch: answered from the notch")),
        "updatedInput": .object(input),
      ])
    ])
    return out.encoded()
  }

  /// Every question has at least one label, and only known labels are used.
  public func isComplete(_ answers: [String: [String]]) -> Bool {
    questions.allSatisfy { q in
      guard let picked = answers[q.question], !picked.isEmpty else { return false }
      if !q.multiSelect && picked.count != 1 { return false }
      let labels = Set(q.options.map(\.label))
      return picked.allSatisfy(labels.contains)
    }
  }
}

/// Where Claude's questions (`AskUserQuestion`) are answered: Settings > General > "Answer
/// Claude's questions in the notch". Stored as a Bool under `defaultsKey` (app domain); a fresh
/// install (nothing saved) answers in the notch, the original behavior.
public enum QuestionMode: Sendable, Equatable {
  /// The original: the PreToolUse(AskUserQuestion) hook is held and the question is answered
  /// in the notch (option buttons, ⌃⌥1…4), or handed back to the terminal.
  case answerInNotch
  /// Nothing is held: the terminal asks at once, and the notch only tells you that Claude is
  /// asking and takes you to that tab.
  case terminalOnly

  /// UserDefaults key (app domain): true = answer in the notch, false = terminal only.
  public static let defaultsKey = "answerQuestionsInNotch"
  /// What an install without a saved choice uses: the original behavior.
  public static let fallback: QuestionMode = .answerInNotch

  /// The stored Bool, or the fallback when nothing (or something that is not a Bool) is stored.
  public init(stored: Any?) {
    if let on = stored as? Bool {
      self = on ? .answerInNotch : .terminalOnly
    } else {
      self = Self.fallback
    }
  }

  public init(answerInNotch: Bool) {
    self = answerInNotch ? .answerInNotch : .terminalOnly
  }

  /// The value stored under `defaultsKey`.
  public var answersInNotch: Bool { self == .answerInNotch }
}

/// Terminal-only question mode: whether the "Claude is asking you" peek drops down.
public enum AskingPeek {
  /// TERM_PROGRAM values of apps that are only a terminal: when one is in front, its window
  /// (and the question in it) is what the user sees. Editors with a built-in terminal (VS
  /// Code, Cursor) are left out: the editor can be in front with its terminal panel closed.
  public static let terminalApps: Set<String> = [
    "ghostty", "Apple_Terminal", "iTerm.app", "WarpTerminal", "WezTerm", "kitty", "Hyper"
  ]

  /// Hidden when the question arrives while the asking session's terminal app is the front
  /// app: the user is already looking at that terminal, which shows the question. The band
  /// under the notch still marks the session as waiting and the jump shortcut still works. The
  /// original mode (answer in the notch) always shows its peek: the question is answered
  /// there. An editor's terminal or an unknown terminal (no bundle id) also shows it.
  public static func shows(
    questionMode: QuestionMode, termProgram: String?, terminalBundleID: String?,
    frontmostBundleID: String?
  ) -> Bool {
    guard questionMode == .terminalOnly, let termProgram, terminalApps.contains(termProgram),
      let terminal = terminalBundleID
    else { return true }
    return terminal != frontmostBundleID
  }
}

/// What the `/question` socket route does with a request (the hook bridge's "question" mode).
public enum QuestionRoute: Sendable, Equatable {
  /// Not an `AskUserQuestion` hook event: 400.
  case badRequest
  /// An empty 200 at once: Claude Code asks in the terminal as usual.
  case replyEmpty
  /// Held until it is answered in the notch or released to the terminal.
  case hold

  /// Terminal-only mode never holds (an installed hook entry gets its empty reply at once, so
  /// the terminal is not kept waiting); the original mode holds every valid question.
  public static func decide(_ event: HookEvent?, mode: QuestionMode) -> QuestionRoute {
    guard mode == .answerInNotch else { return .replyEmpty }
    guard let event, event.toolName == "AskUserQuestion" else { return .badRequest }
    return .hold
  }
}
