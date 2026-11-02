import Foundation
import XCTest

@testable import ClaudeNotchCore

final class Clock: @unchecked Sendable {
  var t = Date(timeIntervalSince1970: 1_000_000)
  func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
}

/// Collects replies sent to held connections.
final class ReplyLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Data?] = []
  func add(_ d: Data?) {
    lock.lock()
    items.append(d)
    lock.unlock()
  }
  var all: [Data?] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

@MainActor
final class StoreTests: XCTestCase {
  var clock = Clock()
  var store: SessionStore!
  var effects: [StoreEffect] = []

  override func setUp() async throws {
    clock = Clock()
    let c = clock
    store = SessionStore(now: { c.t })
    effects = []
    store.onEffect = { [unowned self] in self.effects.append($0) }
  }

  private func ev(
    _ name: String, tool: String? = nil, input: JSONValue? = nil, sid: String = "s1",
    message: String? = nil, ntype: String? = nil, last: String? = nil
  ) -> HookEvent {
    HookEvent(
      name: name, sessionID: sid, cwd: "/Users/x/proj", toolName: tool, toolInput: input,
      message: message, notificationType: ntype, lastAssistantMessage: last)
  }

  private let bashLS: JSONValue = .object(["command": .string("ls"), "description": .string("d")])
  private let bashPwd: JSONValue = .object(["command": .string("pwd")])

  private func addCard(
    _ input: JSONValue, sid: String = "s1", log: ReplyLog, suggestions: [JSONValue] = []
  ) -> PendingPermission {
    var e = ev("PermissionRequest", tool: "Bash", input: input, sid: sid)
    e.suggestions = suggestions
    return store.addPermission(e, termProgram: "ghostty") { log.add($0) }
  }

  func testStatusTransitions() {
    store.handleEvent(ev("SessionStart"), termProgram: "ghostty")
    XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    XCTAssertEqual(store.sessions["s1"]?.project, "proj")
    XCTAssertEqual(store.sessions["s1"]?.termProgram, "ghostty")
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: nil))
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: "Bash"))
    store.handleEvent(ev("Stop", last: "  tamam bitti \n"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .done("tamam bitti"))
    XCTAssertTrue(effects.contains(.sound("Glass")))
    XCTAssertTrue(effects.contains(.autoExpand(seconds: SessionStore.autoExpandSeconds)))
    // v2: done is not amber attention; it stays done (unseen) until seen
    XCTAssertEqual(store.attentionCount, 0)
    XCTAssertEqual(store.doneUnseenCount, 1)
    store.dismiss(sessionID: "s1")
    XCTAssertEqual(store.sessions["s1"]?.status, .done("tamam bitti"))
    XCTAssertEqual(store.doneUnseenCount, 0)
    store.handleEvent(ev("SessionEnd"), termProgram: nil)
    XCTAssertNil(store.sessions["s1"])
  }

  func testStopFailureAndNotifications() {
    store.handleEvent(ev("StopFailure"), termProgram: nil)
    if case .error = store.sessions["s1"]?.status {} else { XCTFail("expected error") }
    // v2: idle_prompt keeps the error (it says more than "waiting")
    let idle = ev("Notification", message: "bekliyor", ntype: "idle_prompt")
    store.handleEvent(idle, termProgram: nil)
    if case .error = store.sessions["s1"]?.status {} else { XCTFail("error must stay") }
    store.handleEvent(ev("SessionStart"), termProgram: nil)
    store.handleEvent(idle, termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput("bekliyor"))
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    store.handleEvent(ev("Notification", message: "x", ntype: "auth_success"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: nil))
  }

  func testPermissionPromptNotificationIgnoredWhenCardPending() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    store.handleEvent(ev("Notification", message: "m", ntype: "permission_prompt"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .working(tool: "Bash"))
    store.flushPending("s1")
    store.handleEvent(ev("Notification", message: "m", ntype: "permission_prompt"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput("m"))
  }

  func testInteractiveToolForwardedAsEventShowsWaiting() {
    store.handleEvent(ev("PermissionRequest", tool: "AskUserQuestion"), termProgram: nil)
    // v2: AskUserQuestion is a question (no payload here: generic text)
    XCTAssertEqual(
      store.sessions["s1"]?.status, .question(text: "Claude bir soru soruyor", options: []))
    XCTAssertEqual(store.sessions["s1"]?.status.label, "Soru soruyor")
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testDecideSendsBodyOnce() throws {
    let log = ReplyLog()
    let sugg = JSONValue.object(["type": .string("addRules")])
    let card = addCard(bashLS, log: log, suggestions: [sugg])
    XCTAssertEqual(store.pending.count, 1)
    XCTAssertEqual(card.summary, "ls")
    XCTAssertTrue(store.decide(id: card.id, decision: .always))
    XCTAssertFalse(store.decide(id: card.id, decision: .allow))
    XCTAssertEqual(log.all.count, 1)
    let body = try XCTUnwrap(log.all[0])
    let json = JSONValue.parse(body)
    XCTAssertEqual(json?["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue, "allow")
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testPostToolUseSameKeyResolvesCard() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    store.handleEvent(ev("PostToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1, "different key must not resolve")
    // key order differs on purpose
    let reordered: JSONValue = .object(["description": .string("d"), "command": .string("ls")])
    store.handleEvent(ev("PostToolUse", tool: "Bash", input: reordered), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertEqual(log.all.count, 1)
    XCTAssertNil(log.all[0] as Data?)
  }

  func testPostToolUseFailureResolvesCard() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    store.handleEvent(ev("PostToolUseFailure", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testPreToolUseSameKeyAfterPermissionRequestDoesNotFlush() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(3)  // even well past the grace window
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
    XCTAssertTrue(log.all.isEmpty)
  }

  func testPreToolUseSameKeyBeforePermissionRequestDoesNotFlush() {
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    clock.advance(0.05)
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(3)
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
  }

  func testDifferentPreToolUseJustAfterCardIsIgnoredWithinGrace() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(0.3)  // racing parallel call
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
  }

  func testDifferentPreToolUseJustBeforeCardDoesNotFlushLater() {
    // PreToolUse(pwd) arrives, then card for ls is created, then pwd's duplicate arrives.
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    clock.advance(0.1)
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(5)
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1, "key already seen before the card -> not a new call")
  }

  func testDifferentPreToolUseLongAfterCardFlushes() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(5)  // user denied in terminal; Claude moved to another call
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertEqual(log.all.count, 1)
  }

  func testPreToolUseInOtherSessionDoesNotFlush() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    clock.advance(5)
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd, sid: "s2"), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
  }

  func testFlushingEvents() {
    for name in ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"] {
      let log = ReplyLog()
      _ = addCard(bashLS, log: log)
      _ = addCard(bashPwd, log: log)
      store.handleEvent(ev(name), termProgram: nil)
      XCTAssertTrue(store.pending.isEmpty, name)
      XCTAssertEqual(log.all.count, 2, name)
    }
  }

  func testConnectionDroppedRemovesCard() {
    let log = ReplyLog()
    let card = addCard(bashLS, log: log)
    store.connectionDropped(id: card.id)
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertFalse(store.decide(id: card.id, decision: .allow))
  }

  func testPruneOldSessions() {
    store.handleEvent(ev("SessionStart", sid: "old"), termProgram: nil)
    clock.advance(SessionStore.pruneAge + 1)
    store.handleEvent(ev("SessionStart", sid: "new"), termProgram: nil)
    store.prune()
    XCTAssertNil(store.sessions["old"])
    XCTAssertNotNil(store.sessions["new"])
  }

  func testRouterEventAndPermissionRoundTrip() {
    let router = RequestRouter(store: store, debugEnabled: true)
    let body = #"{"hook_event_name":"PermissionRequest","session_id":"s9","cwd":"/a/b","tool_name":"Bash","tool_input":{"command":"ls"}}"#
    let req = HTTPRequest(
      method: "POST", target: "/permission", headers: ["x-term-program": "iTerm.app"],
      body: Data(body.utf8))
    let sent = ReplyLog()
    router.handle(req, HTTPResponder { sent.add($0) })
    XCTAssertEqual(store.pending.count, 1)
    XCTAssertTrue(sent.all.isEmpty, "must be held")
    XCTAssertEqual(store.sessions["s9"]?.termProgram, "iTerm.app")
    let id = store.pending[0].id
    let dec = HTTPRequest(
      method: "POST", target: "/debug/decide", headers: [:],
      body: Data(#"{"id":"\#(id)","decision":"deny","message":"no way"}"#.utf8))
    router.handle(dec, HTTPResponder { _ in })
    XCTAssertEqual(sent.all.count, 1)
    let text = String(decoding: sent.all[0] ?? Data(), as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
    XCTAssertTrue(text.contains("no way"))
  }

  // MARK: - Hardening

  func testRetriedCallRetiresStaleCardWithSameKey() {
    let log = ReplyLog()
    let first = addCard(bashLS, log: log)
    clock.advance(2)
    let second = addCard(bashLS, log: log)
    XCTAssertEqual(store.pending.map(\.id), [second.id])
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(log.all.count, 1, "stale card gets an empty reply")
    store.handleEvent(ev("PostToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testPostToolUseResolvesAllCardsWithKey() {
    let log = ReplyLog()
    _ = addCard(bashLS, sid: "s1", log: log)
    _ = addCard(bashPwd, sid: "s1", log: log)
    store.handleEvent(ev("PostToolUse", tool: "Bash", input: bashLS), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
  }

  func testIdlePromptFlushesOldCardsButNotFreshOnes() {
    let log = ReplyLog()
    _ = addCard(bashLS, log: log)
    store.handleEvent(ev("Notification", message: "m", ntype: "idle_prompt"), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1, "fresh card survives the ordering race")
    clock.advance(5)
    store.handleEvent(ev("Notification", message: "m", ntype: "idle_prompt"), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertEqual(log.all.count, 1)
  }

  func testIdlePromptDoesNotTouchOtherSessions() {
    let log = ReplyLog()
    _ = addCard(bashLS, sid: "s2", log: log)
    clock.advance(5)
    store.handleEvent(ev("Notification", message: "m", ntype: "idle_prompt"), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
  }

  private func subagentCard(_ input: JSONValue, agent: String?, log: ReplyLog) {
    var e = ev("PermissionRequest", tool: "Bash", input: input)
    e.agentID = agent
    store.addPermission(e, termProgram: nil) { log.add($0) }
  }

  func testSubagentPreToolUseDoesNotFlushOtherAgentsCard() {
    let log = ReplyLog()
    subagentCard(bashLS, agent: "agent-A", log: log)
    clock.advance(5)
    var other = ev("PreToolUse", tool: "Read", input: .object(["file_path": .string("/x")]))
    other.agentID = "agent-B"
    store.handleEvent(other, termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
    // the main agent moving on does not flush a subagent card either
    store.handleEvent(ev("PreToolUse", tool: "Bash", input: bashPwd), termProgram: nil)
    XCTAssertEqual(store.pending.count, 1)
    // but the same agent moving on does
    var same = ev("PreToolUse", tool: "Bash", input: bashPwd)
    same.agentID = "agent-A"
    store.handleEvent(same, termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testMainAgentStopKeepsSubagentCardsButPromptSubmitFlushesAll() {
    let log = ReplyLog()
    subagentCard(bashLS, agent: "agent-A", log: log)
    subagentCard(bashPwd, agent: nil, log: log)
    store.handleEvent(ev("Stop"), termProgram: nil)
    XCTAssertEqual(store.pending.map(\.agentID), ["agent-A"])
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    XCTAssertTrue(store.pending.isEmpty)
  }

  func testAgentIDParsedFromPayload() {
    let body = #"{"hook_event_name":"PreToolUse","session_id":"s","agent_id":"agent-7"}"#
    XCTAssertEqual(HookEvent.parse(Data(body.utf8))?.agentID, "agent-7")
    let none = #"{"hook_event_name":"PreToolUse","session_id":"s"}"#
    XCTAssertNil(HookEvent.parse(Data(none.utf8))?.agentID)
  }

  func testArmingDelaysClicks() {
    let log = ReplyLog()
    let a = addCard(bashLS, log: log)
    XCTAssertFalse(store.isArmed(a))
    clock.advance(SessionStore.armDelayNew + 0.01)
    XCTAssertTrue(store.isArmed(a))
    let b = addCard(bashPwd, log: log)
    clock.advance(SessionStore.armDelayNew + 0.01)
    XCTAssertTrue(store.isArmed(b))
    // removing card a shifts b: b is disarmed for a moment
    XCTAssertTrue(store.decide(id: a.id, decision: .allow))
    XCTAssertFalse(store.isArmed(b))
    clock.advance(SessionStore.armDelayAfterRemoval + 0.01)
    XCTAssertTrue(store.isArmed(b))
  }

  func testDebugRoutesOffByDefault() {
    let router = RequestRouter(store: store)
    let state = HTTPRequest(method: "GET", target: "/debug/state", headers: [:], body: Data())
    let sent = ReplyLog()
    router.handle(state, HTTPResponder { sent.add($0) })
    let text = String(decoding: sent.all.first.flatMap { $0 } ?? Data(), as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("HTTP/1.1 404"), text)
    let dec = HTTPRequest(
      method: "POST", target: "/debug/decide", headers: [:],
      body: Data(#"{"id":"x","decision":"allow"}"#.utf8))
    router.handle(dec, HTTPResponder { sent.add($0) })
    let last = String(decoding: sent.all.last.flatMap { $0 } ?? Data(), as: UTF8.self)
    XCTAssertTrue(last.hasPrefix("HTTP/1.1 404"))
  }
}
