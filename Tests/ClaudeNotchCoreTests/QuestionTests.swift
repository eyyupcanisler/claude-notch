import Foundation
import XCTest

@testable import ClaudeNotchCore

final class QuestionTests: XCTestCase {
  private let input = JSONValue.parse(Data("""
    {"questions":[
      {"question":"Hangi çatı?","header":"Çatı","multiSelect":false,
       "options":[{"label":"React","description":"a"},{"label":"Vue","description":"b"}]},
      {"question":"Neler?","header":"Özellik","multiSelect":true,
       "options":[{"label":"Test","description":""},{"label":"Lint","description":""}]}]}
    """.utf8))!

  func testParse() {
    let qs = AskedQuestion.parse(input)
    XCTAssertEqual(qs?.count, 2)
    XCTAssertEqual(qs?[1].multiSelect, true)
    XCTAssertEqual(qs?[0].options.map(\.label), ["React", "Vue"])
    XCTAssertNil(AskedQuestion.parse(JSONValue.parse(Data(#"{"questions":[]}"#.utf8))))
  }
}

final class QuestionActivityTests: XCTestCase {
  func testActivityShowsTheQuestionNotJSON() {
    let json = #"{"questions":[{"question":"Hangi düzen?","header":"D","options":[{"label":"A"}]}]}"#
    let input = JSONValue.parse(Data(json.utf8))
    XCTAssertEqual(
      ToolSummary.target(toolName: "AskUserQuestion", input: input), "Question: Hangi düzen?")
  }
}

/// Questions are never held: Claude asks in the terminal, and the notch only tells the user.
/// The session is in the needs-you state while the question is open, and leaves it when the
/// question is answered or the turn moves on.
@MainActor
final class QuestionNoticeTests: XCTestCase {
  var clock = Clock()
  var store: SessionStore!
  var effects: [StoreEffect] = []

  override func setUp() async throws {
    clock = Clock()
    setUpStore()
  }

  private func setUpStore() {
    let c = clock
    store = SessionStore(now: { c.t })
    effects = []
    store.onEffect = { [unowned self] in self.effects.append($0) }
  }

  private let input: JSONValue = .object([
    "questions": .array([
      .object([
        "question": .string("Hangi düzen?"), "header": .string("Düzen"),
        "options": .array([.object(["label": .string("Tek adım")])]),
      ])
    ])
  ])

  private func ev(_ name: String, tool: String? = nil, ntype: String? = nil) -> HookEvent {
    HookEvent(
      name: name, sessionID: "s1", cwd: "/Users/x/web", toolName: tool,
      toolInput: tool == "AskUserQuestion" ? input : nil, message: "m",
      notificationType: ntype)
  }

  private func send(_ e: HookEvent) { store.handleEvent(e, termProgram: "ghostty") }
  private var kind: String? { store.sessions["s1"]?.status.kind }

  /// Asks: the forwarded PermissionRequest alone (no PreToolUse event) is enough.
  private func ask(viaPermissionRequest: Bool = false) {
    send(ev("UserPromptSubmit"))
    send(ev(viaPermissionRequest ? "PermissionRequest" : "PreToolUse", tool: "AskUserQuestion"))
  }

  func testAskingPutsTheSessionInNeedsYou() throws {
    for viaPermission in [false, true] {
      setUpStore()
      ask(viaPermissionRequest: viaPermission)
      XCTAssertEqual(store.sessions["s1"]?.status, .question(text: "Hangi düzen?", options: ["Tek adım"]))
      XCTAssertTrue(store.needsAttention(try XCTUnwrap(store.sessions["s1"])))
      XCTAssertEqual(store.attentionCount, 1)
      XCTAssertEqual(store.activeWorkingCount, 0, "a waiting session does not shine as working")
      XCTAssertTrue(store.pending.isEmpty, "nothing is held: no card, no reply owed")
      XCTAssertEqual(effects.filter { $0 == .attention(sessionID: "s1", kind: "question") }.count, 1)
    }
  }

  func testNotificationsKeepTheQuestion() {
    ask()
    send(ev("Notification", ntype: "permission_prompt"))
    XCTAssertEqual(kind, "question")
    send(ev("PermissionRequest", tool: "AskUserQuestion"))
    XCTAssertEqual(kind, "question")
  }

  func testAnsweredQuestionClears() {
    for end in ["PostToolUse", "PostToolUseFailure"] {
      ask()
      send(ev(end, tool: "AskUserQuestion"))
      XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: nil), end)
      XCTAssertEqual(store.attentionCount, 0, end)
    }
  }

  func testTurnMovingOnClears() {
    ask()
    send(ev("UserPromptSubmit"))
    XCTAssertEqual(kind, "working")
    ask()
    send(ev("Stop"))
    XCTAssertEqual(kind, "done")
    XCTAssertEqual(store.attentionCount, 0)
    ask()
    send(ev("SessionEnd"))
    XCTAssertNil(store.sessions["s1"])
    XCTAssertEqual(store.attentionCount, 0)
  }

  func testPlanApprovalIsUnchanged() {
    send(ev("UserPromptSubmit"))
    send(ev("PreToolUse", tool: "ExitPlanMode"))
    XCTAssertEqual(kind, "plan")
    XCTAssertEqual(effects.filter { $0 == .attention(sessionID: "s1", kind: "plan") }.count, 1)
    send(ev("PostToolUse", tool: "ExitPlanMode"))
    XCTAssertEqual(kind, "working")
  }

  /// An old settings entry still calling /question gets an empty reply at once (the terminal
  /// asks) and nothing is held.
  func testQuestionRouteRepliesEmptyAtOnce() throws {
    let router = RequestRouter(store: store)
    let body = #"{"hook_event_name":"PreToolUse","session_id":"s9","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A"}]}]}}"#
    let sent = ReplyLog()
    router.handle(
      HTTPRequest(method: "POST", target: "/question", headers: [:], body: Data(body.utf8)),
      HTTPResponder { sent.add($0) })
    XCTAssertEqual(sent.all.count, 1)
    let text = String(decoding: try XCTUnwrap(sent.all.first ?? nil), as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
    XCTAssertFalse(text.contains("hookSpecificOutput"), "no decision, no answer")
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertTrue(store.sessions.isEmpty, "the async PreToolUse event reports it, not this route")
  }

  // MARK: - Peek

  func testQuestionPeekStaysLikeAPermissionPeek() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var p = PeekPlanner(permissionHold: 15)
    p.receive(attention: "question", sessionID: "s1", at: t0)
    XCTAssertEqual(p.current?.kind, .attention)
    XCTAssertEqual(p.current?.asking, true)
    XCTAssertFalse(p.expire(at: t0.addingTimeInterval(PeekPlanner.attentionDuration + 1)))
    XCTAssertTrue(p.expire(at: t0.addingTimeInterval(15)))
    // "Until answered" setting: until the session stops asking.
    p.permissionHold = nil
    p.receive(attention: "question", sessionID: "s1", at: t0)
    XCTAssertEqual(p.current?.until, .distantFuture)
    XCTAssertFalse(p.dropAnswered { _ in true })
    XCTAssertNotNil(p.current)
    XCTAssertTrue(p.dropAnswered { _ in false })
    XCTAssertNil(p.current)
  }

  func testPlanAndWaitingPeeksKeepTheirTime() {
    let t0 = Date(timeIntervalSince1970: 1000)
    for attention in ["plan", "waiting"] {
      var p = PeekPlanner(permissionHold: nil)
      p.receive(attention: attention, sessionID: "s1", at: t0)
      XCTAssertEqual(p.current?.asking, false, attention)
      XCTAssertFalse(p.dropAnswered { _ in false }, "only a question peek goes with its question")
      XCTAssertTrue(p.expire(at: t0.addingTimeInterval(PeekPlanner.attentionDuration)), attention)
    }
  }
}
