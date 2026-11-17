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

  func testAnswerBodyEchoesInputAndJoinsMultiSelect() throws {
    let body = PendingQuestion.answerBody(
      toolInput: input, answers: ["Hangi çatı?": ["React"], "Neler?": ["Test", "Lint"]])
    let v = try XCTUnwrap(JSONValue.parse(body))
    let out = try XCTUnwrap(v["hookSpecificOutput"])
    XCTAssertEqual(out["hookEventName"]?.stringValue, "PreToolUse")
    XCTAssertEqual(out["permissionDecision"]?.stringValue, "allow")
    XCTAssertEqual(out["updatedInput"]?["answers"]?["Neler?"]?.stringValue, "Test, Lint")
    XCTAssertEqual(out["updatedInput"]?["questions"]?.arrayValue?.count, 2)
  }

  func testCompleteness() throws {
    let q = PendingQuestion(
      id: "q", sessionID: "s", agentID: nil, questions: try XCTUnwrap(AskedQuestion.parse(input)),
      toolInput: input, createdAt: Date(), reply: PermissionReply { _ in })
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["React"]]))
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["React", "Vue"], "Neler?": ["Test"]]))
    XCTAssertFalse(q.isComplete(["Hangi çatı?": ["Svelte"], "Neler?": ["Test"]]))
    XCTAssertTrue(q.isComplete(["Hangi çatı?": ["Vue"], "Neler?": ["Test", "Lint"]]))
  }
}

/// The question setting: a fresh install answers in the notch (the original behavior).
final class QuestionModeTests: XCTestCase {
  func testFreshInstallAnswersInTheNotch() throws {
    XCTAssertEqual(QuestionMode.defaultsKey, "answerQuestionsInNotch")
    XCTAssertEqual(QuestionMode.fallback, .answerInNotch)
    XCTAssertEqual(QuestionMode(stored: nil), .answerInNotch)
    let scratch = try ScratchDefaults("claudenotch.test")
    let defaults = scratch.defaults
    defer { scratch.remove() }
    XCTAssertEqual(QuestionMode(stored: defaults.object(forKey: QuestionMode.defaultsKey)), .answerInNotch)
    var planner = WingPlanner()
    XCTAssertEqual(planner.questionMode, .answerInNotch)
    planner.receive(attention: "question", sessionID: "s1", at: Date())
    XCTAssertEqual(planner.current?.asking, false)
  }

  func testStoredChoice() throws {
    XCTAssertEqual(QuestionMode(stored: false), .terminalOnly)
    XCTAssertEqual(QuestionMode(stored: true), .answerInNotch)
    XCTAssertEqual(QuestionMode(stored: NSNumber(value: false)), .terminalOnly)
    XCTAssertEqual(QuestionMode(stored: "garbage"), .answerInNotch, "unknown values fall back")
    let scratch = try ScratchDefaults("claudenotch.test")
    let defaults = scratch.defaults
    defer { scratch.remove() }
    defaults.set(false, forKey: QuestionMode.defaultsKey)
    XCTAssertEqual(QuestionMode(stored: defaults.object(forKey: QuestionMode.defaultsKey)), .terminalOnly)
    XCTAssertTrue(QuestionMode(answerInNotch: true).answersInNotch)
    XCTAssertFalse(QuestionMode(answerInNotch: false).answersInNotch)
  }

  func testRouteDecision() {
    let ask = HookEvent(name: "PreToolUse", sessionID: "s1", toolName: "AskUserQuestion")
    let bash = HookEvent(name: "PreToolUse", sessionID: "s1", toolName: "Bash")
    XCTAssertEqual(QuestionRoute.decide(ask, mode: .answerInNotch), .hold)
    XCTAssertEqual(QuestionRoute.decide(bash, mode: .answerInNotch), .badRequest)
    XCTAssertEqual(QuestionRoute.decide(nil, mode: .answerInNotch), .badRequest)
    // Terminal-only: never held, the terminal asks at once (even for an odd body).
    XCTAssertEqual(QuestionRoute.decide(ask, mode: .terminalOnly), .replyEmpty)
    XCTAssertEqual(QuestionRoute.decide(bash, mode: .terminalOnly), .replyEmpty)
    XCTAssertEqual(QuestionRoute.decide(nil, mode: .terminalOnly), .replyEmpty)
  }
}

/// The original mode (default): a question is held by its PreToolUse hook until it is answered
/// in the notch, or handed back to the terminal.
@MainActor
final class HeldQuestionTests: XCTestCase {
  var clock = Clock()
  var procs = FakeProcesses()
  var store: SessionStore!

  override func setUp() async throws {
    clock = Clock()
    procs = FakeProcesses()
    procs.set(100, tty: "/dev/ttys010")
    let c = clock
    store = SessionStore(now: { c.t }, probe: procs.probe)
  }

  private let body = #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","header":"H","options":[{"label":"A"},{"label":"B"}]}]}}"#

  private func post(_ router: RequestRouter, _ body: String, log: ReplyLog) {
    router.handle(
      HTTPRequest(method: "POST", target: "/question", headers: [:], body: Data(body.utf8)),
      HTTPResponder { log.add($0) })
  }

  private func text(_ d: Data??) throws -> String {
    String(decoding: try XCTUnwrap(try XCTUnwrap(d)), as: UTF8.self)
  }

  func testDefaultRouterHoldsUntilAnswered() throws {
    let router = RequestRouter(store: store)
    let sent = ReplyLog()
    post(router, body, log: sent)
    XCTAssertTrue(sent.all.isEmpty, "held: the terminal waits for the notch")
    let q = try XCTUnwrap(store.question(for: "s1"))
    XCTAssertEqual(q.questions.first?.options.map(\.label), ["A", "B"])
    XCTAssertFalse(store.answerQuestion(id: q.id, answers: ["Q?": ["C"]]), "unknown label")
    XCTAssertTrue(store.answerQuestion(id: q.id, answers: ["Q?": ["B"]]))
    XCTAssertNil(store.question(for: "s1"))
    XCTAssertEqual(sent.all.count, 1)
    let reply = try text(sent.all.first)
    XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"))
    XCTAssertTrue(reply.contains("hookSpecificOutput"))
    XCTAssertTrue(reply.contains(#""answers":{"Q?":"B"}"#), reply)
  }

  func testBadBodyIsRejectedAndOddInputGoesToTheTerminal() throws {
    let router = RequestRouter(store: store)
    let sent = ReplyLog()
    post(router, #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash"}"#, log: sent)
    XCTAssertTrue(try text(sent.all.first).hasPrefix("HTTP/1.1 400"))
    let odd = ReplyLog()
    post(router, #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#, log: odd)
    XCTAssertEqual(odd.all.count, 1)
    let reply = try text(odd.all.first)
    XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"))
    XCTAssertFalse(reply.contains("hookSpecificOutput"))
    XCTAssertTrue(store.questions.isEmpty)
  }

  func testReleasedToTheTerminal() throws {
    let router = RequestRouter(store: store)
    // Released by hand ("Answer in terminal" / ⌃⌥N).
    let a = ReplyLog()
    post(router, body, log: a)
    store.releaseQuestion(id: try XCTUnwrap(store.question(for: "s1")).id)
    XCTAssertEqual(a.all.count, 1)
    XCTAssertFalse(try text(a.all.first).contains("hookSpecificOutput"))
    // A new prompt (or SessionStart) flushes it.
    let b = ReplyLog()
    post(router, body, log: b)
    store.handleEvent(HookEvent(name: "UserPromptSubmit", sessionID: "s1"), termProgram: nil)
    XCTAssertEqual(b.all.count, 1)
    XCTAssertTrue(store.questions.isEmpty)
    // The user goes to that terminal tab.
    store.handleEvent(
      HookEvent(name: "UserPromptSubmit", sessionID: "s1"),
      context: HookContext(termProgram: "ghostty", tty: "/dev/ttys010", pid: 100))
    let c = ReplyLog()
    post(router, body, log: c)
    XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys010")
    store.markSeen(tty: "/dev/ttys010")
    XCTAssertEqual(c.all.count, 1)
    XCTAssertTrue(store.questions.isEmpty)
    // A new question of the same session replaces the older one.
    let d = ReplyLog()
    let e = ReplyLog()
    post(router, body, log: d)
    post(router, body, log: e)
    XCTAssertEqual(d.all.count, 1)
    XCTAssertTrue(e.all.isEmpty)
    XCTAssertEqual(store.questions.count, 1)
    // Switching to terminal-only releases every held question.
    store.releaseAllQuestions()
    XCTAssertEqual(e.all.count, 1)
    XCTAssertTrue(store.questions.isEmpty)
  }

  func testDroppedConnectionForgetsTheQuestion() throws {
    let router = RequestRouter(store: store)
    post(router, body, log: ReplyLog())
    store.connectionDropped(id: try XCTUnwrap(store.question(for: "s1")).id)
    XCTAssertTrue(store.questions.isEmpty)
  }

  func testOriginalQuestionItemKeepsTheLongTime() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var p = WingPlanner()
    p.receive(attention: "question", sessionID: "s1", at: t0)
    XCTAssertEqual(p.current?.kind, .attention)
    XCTAssertEqual(p.current?.asking, false)
    XCTAssertTrue(p.expire(at: t0.addingTimeInterval(NotchWings.longDuration)))
    XCTAssertEqual(p.marks.first?.asking, false, "its mark opens the panel on a click")
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

/// Terminal-only question mode (the setting off): Claude asks in the terminal, and the notch
/// only tells the user. The session is in the needs-you state while the question is open, and
/// leaves it when the question is answered or the turn moves on (the same in both modes).
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

  /// The installed /question hook gets an empty reply at once (the terminal asks) and nothing
  /// is held.
  func testQuestionRouteRepliesEmptyAtOnce() throws {
    let router = RequestRouter(store: store)
    router.questionMode = { .terminalOnly }
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
    XCTAssertTrue(store.questions.isEmpty)
    XCTAssertTrue(store.sessions.isEmpty, "the async PreToolUse event reports it, not this route")
  }



  /// Shorthand for `TerminalIslands.shows`: a session running in Ghostty by default.
  private func islandShows(
    _ kind: String, hide: Bool = true, _ mode: QuestionMode = .terminalOnly,
    term: String? = "ghostty", bundle: String? = "com.mitchellh.ghostty", front: String?
  ) -> Bool {
    TerminalIslands.shows(
      kind: kind, hideWhileTerminalInFront: hide, questionMode: mode, termProgram: term,
      terminalBundleID: bundle, frontmostBundleID: front)
  }

  /// Terminal-only mode: no "Claude is asking you" island while the asking session's terminal
  /// app is in front, with or without the hide option; it shows from any other app. An
  /// editor's terminal, an unknown terminal and the original mode always show it.
  func testAskingIslandStaysHiddenWhileItsTerminalIsInFront() {
    let ghostty = "com.mitchellh.ghostty"
    for hide in [false, true] {
      XCTAssertFalse(islandShows("question", hide: hide, front: ghostty))
      XCTAssertFalse(islandShows("question", hide: hide, term: "iTerm.app",
        bundle: "com.googlecode.iterm2", front: "com.googlecode.iterm2"))
      XCTAssertTrue(islandShows("question", hide: hide, front: "com.google.Chrome"))
      XCTAssertTrue(islandShows("question", hide: hide, front: nil))
      // Another terminal in front (the session runs in Ghostty): it shows.
      XCTAssertTrue(islandShows("question", hide: hide, front: "com.apple.Terminal"))
      // An editor in front may have its terminal panel closed: it shows.
      XCTAssertTrue(islandShows("question", hide: hide, term: "vscode",
        bundle: "com.microsoft.VSCode", front: "com.microsoft.VSCode"))
      // Unknown terminal: it shows.
      XCTAssertTrue(islandShows("question", hide: hide, term: nil, bundle: nil, front: ghostty))
      XCTAssertTrue(islandShows("question", hide: hide, term: "tmux", bundle: nil, front: ghostty))
      // Answering in the notch (the original): always shows, the answer UI lives there.
      XCTAssertTrue(islandShows("question", hide: hide, .answerInNotch, front: ghostty))
    }
  }

  /// The option hides permission requests, plan approvals and waiting notices while their
  /// terminal is in front; finished runs and errors always show, and a fresh install hides
  /// nothing.
  func testTerminalIslandsHideOnlyWhenAskedAndTheirTerminalIsInFront() {
    XCTAssertFalse(TerminalIslands.fallback, "a fresh install always shows the islands")
    XCTAssertFalse(TerminalIslands.hides(stored: nil))
    XCTAssertFalse(TerminalIslands.hides(stored: 1), "not a Bool: the fallback")
    XCTAssertTrue(TerminalIslands.hides(stored: true))
    let ghostty = "com.mitchellh.ghostty"
    for kind in ["permission", "plan", "waiting"] {
      XCTAssertTrue(islandShows(kind, hide: false, front: ghostty), "option off: \(kind) shows")
      XCTAssertFalse(islandShows(kind, front: ghostty), kind)
      XCTAssertFalse(islandShows(kind, .answerInNotch, front: ghostty), "either question mode")
      XCTAssertTrue(islandShows(kind, front: "com.google.Chrome"), kind)
      XCTAssertTrue(islandShows(kind, front: nil), kind)
      XCTAssertTrue(islandShows(kind, front: "com.apple.Terminal"), "another terminal in front")
      XCTAssertTrue(
        islandShows(kind, term: "vscode", bundle: "com.microsoft.VSCode",
          front: "com.microsoft.VSCode"),
        "an editor's terminal panel may be closed")
      XCTAssertTrue(islandShows(kind, term: nil, bundle: nil, front: ghostty), "unknown terminal")
    }
    for kind in ["done", "error", "quiet", ""] {
      XCTAssertTrue(islandShows(kind, front: ghostty), "never hidden: \(kind)")
    }
  }

  /// A Focus on lets through only what blocks Claude: a permission request, a question
  /// (whichever question mode), a plan approval, a wait for input. Finished runs, errors and
  /// the "quiet" note show nothing (the status line still has them). A fresh install has no
  /// Focus, and without one every kind shows.
  func testFocusShowsOnlyWhatBlocksClaude() {
    XCTAssertFalse(FocusIslands.fallback)
    XCTAssertFalse(FocusIslands.active(stored: nil))
    XCTAssertFalse(FocusIslands.active(stored: "yes"), "not a Bool: the fallback")
    XCTAssertTrue(FocusIslands.active(stored: true))
    XCTAssertEqual(FocusIslands.blockingKinds, ["permission", "question", "plan", "waiting"])
    func shows(_ kind: String, focus: Bool = true) -> Bool {
      FocusIslands.shows(kind: kind, focusActive: focus)
    }
    for kind in ["permission", "question", "plan", "waiting"] {
      XCTAssertTrue(shows(kind), "blocks Claude: \(kind) shows under Focus")
      XCTAssertTrue(shows(kind, focus: false), kind)
    }
    for kind in ["done", "error", "quiet", ""] {
      XCTAssertFalse(shows(kind), "does not block Claude: \(kind) hidden under Focus")
      XCTAssertTrue(shows(kind, focus: false), "no Focus: \(kind) shows")
    }
  }

  /// The command an automation runs writes the key and wakes the running app.
  func testFocusCommandWritesTheKeyAndPostsTheNotification() {
    XCTAssertEqual(
      FocusIslands.command(on: true),
      "/usr/bin/defaults write com.eyyupcan.claudenotch focusActive -bool true; "
        + "/usr/bin/notifyutil -p com.eyyupcan.claudenotch.focus")
    XCTAssertTrue(FocusIslands.command(on: false).contains("focusActive -bool false;"))
  }

  /// When an app comes to the front, the island on screen is checked by its kind: a permission
  /// card, a terminal-only question, or the status of the session it waits for. Finished runs,
  /// module notes and questions answered in the notch are never taken away.
  func testIslandOnScreenIsCheckedByWhatItShows() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var p = WingPlanner()
    p.questionMode = .terminalOnly
    func kind(statusKind: String? = "waiting", heldInNotch: Bool = false) -> String? {
      p.current.flatMap {
        TerminalIslands.kind(of: $0, statusKind: statusKind, heldInNotch: heldInNotch)
      }
    }
    p.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: t0)
    XCTAssertEqual(kind(), "permission")
    p.clear()
    p.receive(attention: "question", sessionID: "s1", at: t0)
    XCTAssertEqual(kind(statusKind: "question"), "question")
    XCTAssertEqual(kind(statusKind: "waiting"), "question", "an asking island stays a question")
    p.clear()
    p.receive(attention: "plan", sessionID: "s1", at: t0)
    XCTAssertEqual(kind(statusKind: "plan"), "plan")
    p.clear()
    p.receive(attention: "waiting", sessionID: "s1", at: t0)
    XCTAssertEqual(kind(statusKind: "waiting"), "waiting")
    XCTAssertEqual(kind(statusKind: "working"), "working", "moved on: shows until its time")
    XCTAssertNil(kind(statusKind: "question", heldInNotch: true), "answered in the notch")
    p.clear()
    p.receive(attention: "done", sessionID: "s1", at: t0)
    XCTAssertNil(kind())
    p.clear()
    p.receive(
      module: ModuleNote(
        source: .claude, id: "n", title: "t", subtitle: nil, digits: nil, unit: nil,
        validUntil: t0.addingTimeInterval(60)),
      at: t0)
    XCTAssertNil(kind())
  }

  func testPlanAndWaitingItemsAreNeverAsking() {
    let t0 = Date(timeIntervalSince1970: 1000)
    for attention in ["plan", "waiting"] {
      var p = WingPlanner()
      p.questionMode = .terminalOnly
      p.receive(attention: attention, sessionID: "s1", at: t0)
      XCTAssertEqual(p.current?.asking, false, attention)
      XCTAssertTrue(p.expire(at: t0.addingTimeInterval(NotchWings.longDuration)), attention)
    }
  }

}
