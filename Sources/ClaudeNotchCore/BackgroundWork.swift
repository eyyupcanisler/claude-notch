import Foundation

/// One entry of the Stop hook's `background_tasks`: work the session started that is still in
/// flight when its turn ends (newer Claude Code; older versions send no list).
public struct BackgroundTask: Sendable, Equatable {
  /// Claude Code's label: "workflow", "subagent", "shell", "monitor", or another raw type.
  public var type: String
  /// Workflow name (workflow tasks only).
  public var name: String?
  public var description: String

  public init(type: String, name: String? = nil, description: String = "") {
    self.type = type
    self.name = name
    self.description = description
  }

  /// The entries of a hook payload's `background_tasks` array (empty when absent).
  static func list(_ value: JSONValue?) -> [BackgroundTask] {
    (value?.arrayValue ?? []).compactMap { task in
      guard let type = task["type"]?.stringValue, !type.isEmpty else { return nil }
      return BackgroundTask(
        type: type, name: task["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
        description: task["description"]?.stringValue ?? "")
    }
  }
}

/// A turn that ends while a workflow or a background agent it started still runs is not done:
/// that work wakes the session when it finishes and the turn goes on. So the session keeps
/// working (no "done" wing, chime or done bar), and its real end is the Stop after the work is
/// back. Claude Code lists the work in the Stop hook (`background_tasks`, "lets hooks
/// distinguish 'session is done' from 'session is paused waiting for background work to wake
/// it'"). Meanwhile the session gets no "quiet for 10 min" note, and Claude Code's "waiting for
/// your input" notice neither marks it as needing you nor rings its bell.
public enum BackgroundWork {
  /// Task types that end by themselves and wake the session when they do. A background shell
  /// or monitor is left out: it can run for good (a dev server, a log watch) while the turn is
  /// really over, so a Stop with only those is done, as before.
  public static let continuingTypes: Set<String> = ["workflow", "subagent"]

  /// The tasks that keep the turn going; empty means the Stop is a real end.
  public static func continuing(_ tasks: [BackgroundTask]) -> [BackgroundTask] {
    tasks.filter { continuingTypes.contains($0.type) }
  }

  /// The row's working text: "In the background: review-changes" (a workflow's name, else the
  /// task's description), or "In the background: 3 tasks".
  public static func summary(_ tasks: [BackgroundTask]) -> String {
    guard tasks.count == 1, let task = tasks.first else {
      return loc("In the background: \(tasks.count) tasks")
    }
    // One line: whitespace runs (newlines too) become one space, control characters go.
    let flat = String(
      String.UnicodeScalarView(
        (task.name ?? task.description).unicodeScalars.filter {
          !CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0)
        }))
    let label = ToolSummary.truncate(
      flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), 80)
    return label.isEmpty
      ? loc("In the background: \(task.type)") : loc("In the background: \(label)")
  }
}
