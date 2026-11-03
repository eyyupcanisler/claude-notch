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
        "permissionDecisionReason": .string("ClaudeNotch: yanıt çentikten verildi"),
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
