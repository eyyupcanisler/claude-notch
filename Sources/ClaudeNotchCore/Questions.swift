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

/// Terminal-only question mode: the question's wing ("<project> asks:") stays hidden while the
/// asking session's terminal app is in front: the user is already looking at that terminal,
/// which shows the question. The band under the notch still marks the session as waiting and the jump
/// shortcut still works. The original mode (answer in the notch) always shows its island: the
/// question is answered there. An editor's terminal or an unknown terminal (no bundle id) also
/// shows it. The rule itself is `TerminalIslands.shows` (kind "question").
public enum AskingPeek {
  /// TERM_PROGRAM values of apps that are only a terminal: when one is in front, its window
  /// (and the question in it) is what the user sees. Editors with a built-in terminal (VS
  /// Code, Cursor) are left out: the editor can be in front with its terminal panel closed.
  public static let terminalApps: Set<String> = [
    "ghostty", "Apple_Terminal", "iTerm.app", "WarpTerminal", "WezTerm", "kitty", "Hyper"
  ]

  /// The session's terminal is a terminal-only app (`terminalApps`) with a known bundle id,
  /// and that app is the front app.
  public static func terminalInFront(
    termProgram: String?, terminalBundleID: String?, frontmostBundleID: String?
  ) -> Bool {
    guard let termProgram, terminalApps.contains(termProgram), let terminal = terminalBundleID
    else { return false }
    return terminal == frontmostBundleID
  }
}

/// Settings > Notifications > "Hide islands while their terminal is in front". Stored as a
/// Bool under `defaultsKey` (app domain); a fresh install (nothing saved) is off, the original
/// behavior: every permission request, plan approval and waiting notice drops its island.
public enum TerminalIslands {
  /// UserDefaults key (app domain), a Bool.
  public static let defaultsKey = "hideIslandsWhileTerminalInFront"
  /// What an install without a saved choice uses: the islands always show (the original).
  public static let fallback = false

  /// The stored Bool, or the fallback when nothing (or something that is not a Bool) is stored.
  public static func hides(stored: Any?) -> Bool {
    stored as? Bool ?? fallback
  }

  /// Attention kinds the option hides: each asks for something the terminal shows too (a
  /// permission prompt, the plan to approve, the input Claude waits for). Finished runs and
  /// errors are left alone.
  public static let kinds: Set<String> = ["permission", "plan", "waiting"]

  /// Whether a Claude island of attention `kind` ("permission", "question", "plan",
  /// "waiting"...) may be on screen while `frontmostBundleID` is the front app. While the
  /// session's terminal app is in front (`AskingPeek.terminalInFront`, whichever of its tabs):
  /// a terminal-only question never shows (`AskingPeek`), and with the option on neither does
  /// a permission request, plan approval or waiting notice. The app checks it when an island
  /// would drop down and again when an app comes to the front, so an island already up goes
  /// once you switch to that terminal. Nothing hidden drops down later by itself: the band
  /// under the notch (and the terminal bell, when on) still marks the session.
  public static func shows(
    kind: String, hideWhileTerminalInFront: Bool, questionMode: QuestionMode,
    termProgram: String?, terminalBundleID: String?, frontmostBundleID: String?
  ) -> Bool {
    let hidden =
      kind == "question"
      ? questionMode == .terminalOnly : hideWhileTerminalInFront && kinds.contains(kind)
    guard hidden else { return true }
    return !AskingPeek.terminalInFront(
      termProgram: termProgram, terminalBundleID: terminalBundleID,
      frontmostBundleID: frontmostBundleID)
  }

  /// The attention kind of an island on screen, to check with `shows` when an app comes to the
  /// front: nil for one that never hides (a finished run, a module note, a question waiting
  /// for its answer in the notch). An attention peek that is not a terminal-only question
  /// takes its session's status kind (`statusKind`), "plan" or "waiting".
  public static func kind(of peek: PeekItem, statusKind: String?, heldInNotch: Bool) -> String? {
    switch peek.kind {
    case .permission: return "permission"
    case .attention:
      guard !heldInNotch else { return nil }
      return peek.asking ? "question" : statusKind
    case .finished, .module: return nil
    }
  }
}

/// A Focus such as Do Not Disturb. The app reads macOS's own state (`SystemFocus`) and, as a
/// backup, a Bool that two Shortcuts automations (or Settings > Notifications > "Treat Focus as
/// on") store under `defaultsKey` (app domain) while posting the Darwin notification
/// `notifyName`, so the running app reads it at once (`command(on:)`). Focus counts as on when
/// either says so (`effective`). Nothing saved is off.
///
/// Under a Focus only what blocks Claude shows (`shows`): a permission request, a question, a
/// plan to approve or a wait for input, and only as the small mark (`WingPlanner`), until it is
/// handled. Finished runs, errors and module notes show nothing beside the notch; the status
/// line still has them.
public enum FocusIslands {
  /// UserDefaults key (app domain), a Bool.
  public static let defaultsKey = "focusActive"
  /// Posted after the key is written (`notifyutil -p`): the running app reads it again.
  public static let notifyName = "com.eyyupcan.claudenotch.focus"
  /// What an install without a saved choice uses: off (the original).
  public static let fallback = false
  /// The attention kinds that block Claude until the user acts: the only ones a Focus lets
  /// through, in either question mode.
  public static let blockingKinds: Set<String> = ["permission", "question", "plan", "waiting"]

  /// The stored Bool, or the fallback when nothing (or something that is not a Bool) is stored.
  public static func active(stored: Any?) -> Bool {
    stored as? Bool ?? fallback
  }

  /// Whether Focus counts as on: macOS says so, or the Shortcuts value does. A file the app
  /// cannot read (`.unknown`) leaves the Shortcuts value alone in charge.
  public static func effective(system: SystemFocusState, shortcuts: Bool) -> Bool {
    system == .on || shortcuts
  }

  /// Whether an island of attention `kind` shows: without a Focus every kind does; under one
  /// only the kinds in `blockingKinds`.
  public static func shows(kind: String, focusActive: Bool) -> Bool {
    !focusActive || blockingKinds.contains(kind)
  }

  /// The shell command a Shortcuts automation runs ("Run Shell Script") when a Focus turns on
  /// (`on` true) or off.
  public static func command(on: Bool, domain: String = "com.eyyupcan.claudenotch") -> String {
    "/usr/bin/defaults write \(domain) \(defaultsKey) -bool \(on ? "true" : "false"); "
      + "/usr/bin/notifyutil -p \(notifyName)"
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
