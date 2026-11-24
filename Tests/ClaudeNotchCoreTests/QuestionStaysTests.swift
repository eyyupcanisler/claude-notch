import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Hook events are sent async (in parallel), so they can arrive out of order. While a chat is
/// asking (a question or a plan approval), a late event of ANOTHER tool call must not turn its
/// "needs you" segment back to working; only the question's own end, a new prompt or the end
/// of the turn clears it.
@MainActor
final class QuestionStaysTests: XCTestCase {
  var clock = Clock()
  var store: SessionStore!

  override func setUp() async throws {
    clock = Clock()
    let c = clock
    store = SessionStore(now: { c.t })
  }

  private func ev(_ name: String, tool: String? = nil, input: JSONValue? = nil, last: String? = nil)
    -> HookEvent
  {
    HookEvent(
      name: name, sessionID: "s1", cwd: "/Users/x/proj", toolName: tool, toolInput: input,
      lastAssistantMessage: last)
  }

  private let bash: JSONValue = .object(["command": .string("ls")])
  private let ask: JSONValue = .object([
    "questions": .array([
      .object([
        "question": .string("Which one?"),
        "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
      ])
    ])
  ])
  private let plan: JSONValue = .object(["plan": .string("Do it")])

  private func send(_ e: HookEvent) {
    store.handleEvent(e, termProgram: "ghostty")
    clock.advance(0.1)
  }

  private var line: LineState? {
    store.sessions["s1"].map { store.lineState(of: $0) }
  }

  private func asking() {
    send(ev("UserPromptSubmit"))
    send(ev("PreToolUse", tool: "Bash", input: bash))
    send(ev("PreToolUse", tool: "AskUserQuestion", input: ask))
    XCTAssertEqual(line, .needs)
  }

  /// The bug: the earlier Bash call's PostToolUse arrives after the question started.
  func testALatePostToolUseOfAnotherCallKeepsTheQuestion() {
    asking()
    send(ev("PostToolUse", tool: "Bash", input: bash))
    XCTAssertEqual(line, .needs)
    send(ev("PostToolUseFailure", tool: "Bash", input: bash))
    XCTAssertEqual(line, .needs)
  }

  func testALatePreToolUseOfAnotherCallKeepsTheQuestion() {
    asking()
    send(ev("PreToolUse", tool: "Read", input: .object(["file_path": .string("/a")])))
    XCTAssertEqual(line, .needs)
  }

  /// The question's own end (same tool call) clears it; the chat works again.
  func testTheQuestionsOwnPostToolUseClearsIt() {
    asking()
    send(ev("PostToolUse", tool: "AskUserQuestion", input: ask))
    XCTAssertEqual(line, .working)
    send(ev("PreToolUse", tool: "Bash", input: bash))
    XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: "Bash"))
  }

  /// The answers can be added to the input before PostToolUse: still the question's own end.
  func testTheQuestionsEndClearsItEvenWithAnswersInItsInput() {
    asking()
    var answered = ask
    if case .object(var o) = answered {
      o["answers"] = .object(["Which one?": .string("A")])
      answered = .object(o)
    }
    send(ev("PostToolUse", tool: "AskUserQuestion", input: answered))
    XCTAssertEqual(line, .working)
  }

  func testANewPromptOrTheEndOfTheTurnClearsIt() {
    asking()
    send(ev("UserPromptSubmit"))
    XCTAssertEqual(line, .working)
    asking()
    send(ev("Stop", last: "ok"))
    XCTAssertEqual(line, .done)
  }

  func testAPlanApprovalStaysTheSameWay() {
    send(ev("UserPromptSubmit"))
    send(ev("PreToolUse", tool: "Bash", input: bash))
    send(ev("PreToolUse", tool: "ExitPlanMode", input: plan))
    XCTAssertEqual(line, .needs)
    send(ev("PostToolUse", tool: "Bash", input: bash))
    XCTAssertEqual(line, .needs)
    send(ev("PostToolUse", tool: "ExitPlanMode", input: plan))
    XCTAssertEqual(line, .working)
  }
}
