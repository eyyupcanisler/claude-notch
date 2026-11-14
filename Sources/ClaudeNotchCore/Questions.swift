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
