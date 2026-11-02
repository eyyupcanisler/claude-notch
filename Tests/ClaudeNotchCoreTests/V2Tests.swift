import Darwin
import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Fake process table for liveness tests.
final class FakeProcesses: @unchecked Sendable {
  private let lock = NSLock()
  private var alive: [Int32: String?] = [:]

  func set(_ pid: Int32, tty: String?) {
    lock.lock()
    alive[pid] = .some(tty)
    lock.unlock()
  }

  func kill(_ pid: Int32) {
    lock.lock()
    alive.removeValue(forKey: pid)
    lock.unlock()
  }

  var probe: ProcessProbe {
    ProcessProbe(
      isAlive: { [self] pid in
        lock.lock()
        defer { lock.unlock() }
        return alive[pid] != nil
      },
      ttyOf: { [self] pid in
        lock.lock()
        defer { lock.unlock() }
        return alive[pid] ?? nil
      })
  }
}

@MainActor
final class V2Tests: XCTestCase {
  var clock = Clock()
  var procs = FakeProcesses()
  var store: SessionStore!
  var effects: [StoreEffect] = []

  override func setUp() async throws {
    clock = Clock()
    procs = FakeProcesses()
    let c = clock
    store = SessionStore(now: { c.t }, probe: procs.probe)
    effects = []
    store.onEffect = { [unowned self] in self.effects.append($0) }
  }

  private func ev(
    _ name: String, sid: String = "s1", cwd: String = "/Users/x/proj", tool: String? = nil,
    input: JSONValue? = nil, ntype: String? = nil, agent: String? = nil
  ) -> HookEvent {
    HookEvent(
      name: name, sessionID: sid, cwd: cwd, toolName: tool, toolInput: input, message: "m",
      notificationType: ntype, agentID: agent)
  }

  private func ctx(_ tty: String?, _ pid: Int32?, branch: String? = nil) -> HookContext {
    HookContext(termProgram: "ghostty", tty: tty, pid: pid, branch: branch)
  }

  private func status(_ sid: String = "s1") -> SessionStatus? { store.sessions[sid]?.status }

  private let questionInput: JSONValue = .object([
    "questions": .array([
      .object([
        "question": .string("Hangi çatı?\nSeç"), "header": .string("Çatı"),
        "options": .array([
          .object(["label": .string("React"), "description": .string("d")]),
          .object(["label": .string("Vue")])
        ])
      ])
    ])
  ])

  // MARK: - C1 header validation

  func testTTYValidation() {
    XCTAssertEqual(HookContext.validTTY("/dev/ttys012"), "/dev/ttys012")
    XCTAssertEqual(HookContext.validTTY("/dev/ttys0"), "/dev/ttys0")
    for bad in [
      "", "/dev/ttys", "/dev/tty012", "/dev/ttys12a", "/dev/ttys1\"; beep", "/dev/ttys123456",
      "/dev/ttys٣", " /dev/ttys1", "/dev/ttys1\n", "ttys001", "/dev/../dev/ttys1"
    ] {
      XCTAssertNil(HookContext.validTTY(bad), bad)
    }
    XCTAssertNil(HookContext.validTTY(nil))
  }

  func testPIDValidation() {
    XCTAssertEqual(HookContext.validPID("4242"), 4242)
    for bad in ["", "0", "1", "-5", "12a", " 12", "99999999999", "0x10", "١٢"] {
      XCTAssertNil(HookContext.validPID(bad), bad)
    }
  }

  func testBranchAndTermValidation() {
    XCTAssertEqual(HookContext.validBranch("feature/notch-v2"), "feature/notch-v2")
    XCTAssertEqual(HookContext.validBranch("özellik/çentik"), "özellik/çentik")
    for bad in ["", "a b", "x\u{202E}y", "x\u{7}", "x\ny", "x\u{200B}"] {
      XCTAssertNil(HookContext.validBranch(bad), bad.debugDescription)
    }
    let long = String(repeating: "b", count: 150)
    XCTAssertEqual(HookContext.validBranch(long)?.count, HookContext.maxBranchLength + 1)
    XCTAssertEqual(HookContext.validTermProgram("iTerm.app"), "iTerm.app")
    XCTAssertEqual(HookContext.validTermProgram("Apple_Terminal"), "Apple_Terminal")
    XCTAssertNil(HookContext.validTermProgram("ghostty\"; x"))
    XCTAssertNil(HookContext.validTermProgram(String(repeating: "a", count: 65)))
  }

  func testContextFromHeadersDropsInvalidAndUnpairedValues() {
    func req(_ h: [String: String]) -> HTTPRequest {
      HTTPRequest(method: "POST", target: "/event", headers: h, body: Data())
    }
    let ok = HookContext(request: req([
      "x-term-program": "ghostty", "x-claude-tty": "/dev/ttys007", "x-claude-pid": "321",
      "x-git-branch": "main"
    ]))
    XCTAssertEqual(ok, HookContext(termProgram: "ghostty", tty: "/dev/ttys007", pid: 321,
      branch: "main"))
    let noTTY = HookContext(request: req(["x-claude-pid": "321"]))
    XCTAssertNil(noTTY.pid, "pid without tty is useless for liveness")
    let badPID = HookContext(request: req(["x-claude-tty": "/dev/ttys007", "x-claude-pid": "x"]))
    XCTAssertNil(badPID.tty)
    XCTAssertNil(badPID.pid)
    let evil = HookContext(request: req([
      "x-claude-tty": "/dev/ttys1\" & do shell script \"x", "x-claude-pid": "5"
    ]))
    XCTAssertNil(evil.tty)
  }

  func testRouterStoresIdentityFromHeaders() {
    let router = RequestRouter(store: store)
    let body = #"{"hook_event_name":"SessionStart","session_id":"r1","cwd":"/a/repo"}"#
    let req = HTTPRequest(
      method: "POST", target: "/event",
      headers: [
        "x-term-program": "ghostty", "x-claude-tty": "/dev/ttys044", "x-claude-pid": "777",
        "x-git-branch": "dev"
      ],
      body: Data(body.utf8))
    router.handle(req, HTTPResponder { _ in })
    let s = store.sessions["r1"]
    XCTAssertEqual(s?.tty, "/dev/ttys044")
    XCTAssertEqual(s?.pid, 777)
    XCTAssertEqual(s?.branch, "dev")
    XCTAssertEqual(s?.ttySuffix, "s044")
  }

  // MARK: - AppleScript escaping

  func testAppleScriptLiteralEscaping() {
    XCTAssertEqual(TerminalScript.literal("abc"), "\"abc\"")
    XCTAssertEqual(TerminalScript.literal("a\"b\\c"), "\"a\\\"b\\\\c\"")
    XCTAssertEqual(TerminalScript.literal("x\ny\tz"), "\"x\\ny\\tz\"")
    XCTAssertEqual(TerminalScript.literal("a\u{7}b\u{202E}c\u{2028}d"), "\"abcd\"")
    XCTAssertEqual(TerminalScript.literal("/Users/ö/çalışma"), "\"/Users/ö/çalışma\"")
    // A quote cannot end the literal early.
    let evil = "/tmp/\" & (do shell script \"touch /tmp/pwn\") & \""
    let lit = TerminalScript.literal(evil)
    let bare = lit.replacingOccurrences(of: "\\\\", with: "")
      .replacingOccurrences(of: "\\\"", with: "")
    XCTAssertEqual(bare.filter { $0 == "\"" }.count, 2, "only the delimiters are bare quotes")
  }

  func testFocusScriptsValidateInput() throws {
    XCTAssertNil(TerminalScript.ghosttyFocus(tty: "/dev/ttys1\" & beep"))
    XCTAssertNil(TerminalScript.terminalAppFocus(tty: "nope"))
    XCTAssertNil(TerminalScript.iTermFocus(tty: ""))
    XCTAssertNil(TerminalScript.ghosttyFocus(directory: "relative/dir"))
    let g = try XCTUnwrap(TerminalScript.ghosttyFocus(tty: "/dev/ttys012"))
    XCTAssertTrue(g.contains("every terminal whose tty is \"/dev/ttys012\""), g)
    XCTAssertTrue(g.contains("tell application \"Ghostty\""))
    XCTAssertTrue(g.contains("with timeout of"))
    let d = try XCTUnwrap(TerminalScript.ghosttyFocus(directory: "/a/\"b\""))
    XCTAssertTrue(d.contains("working directory is \"/a/\\\"b\\\"\""), d)
    XCTAssertTrue(d.contains("\"ambiguous\""))
    XCTAssertNotNil(TerminalKind(termProgram: "Apple_Terminal").focusScript(tty: "/dev/ttys3"))
    XCTAssertNotNil(TerminalKind(termProgram: "iTerm.app").focusScript(tty: "/dev/ttys3"))
    XCTAssertNil(TerminalKind(termProgram: "vscode").focusScript(tty: "/dev/ttys3"))
  }

  func testAppleScriptsCompile() throws {
    // osacompile parses the generated sources (no Apple Event is sent).
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("cn-osa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sources = [
      TerminalScript.ghosttyFocus(tty: "/dev/ttys012"),
      TerminalScript.ghosttyFocus(directory: "/tmp/a \"b\""),
      TerminalScript.ghosttyFocusedTTY,
      TerminalScript.terminalAppFocus(tty: "/dev/ttys012")
    ]
    for (i, src) in sources.enumerated() {
      let file = dir.appendingPathComponent("s\(i).applescript")
      try XCTUnwrap(src).write(to: file, atomically: true, encoding: .utf8)
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
      p.arguments = ["-o", dir.appendingPathComponent("s\(i).scpt").path, file.path]
      p.standardError = FileHandle.nullDevice
      try p.run()
      p.waitUntilExit()
      XCTAssertEqual(p.terminationStatus, 0, "script \(i) does not compile")
    }
  }

  func testFocusOutcomeHint() {
    XCTAssertEqual(
      FocusOutcome.notAuthorized(app: "Ghostty").hint,
      "Ghostty'yi kontrol izni gerekli — Sistem Ayarları > Gizlilik > Otomasyon")
    XCTAssertTrue(FocusOutcome.notAuthorized(app: "Terminal").hint?.hasPrefix("Terminal'i") == true)
    XCTAssertNil(FocusOutcome.focusedTerminal.hint)
    XCTAssertTrue(FocusOutcome.focusedTerminal.reachedSession)
    XCTAssertFalse(FocusOutcome.notAuthorized(app: "Ghostty").reachedSession)
  }

  // MARK: - C2 identity and disambiguator

  func testIdentityKeptAcrossEvents() {
    store.handleEvent(ev("SessionStart"), context: ctx("/dev/ttys010", 100, branch: "main"))
    store.handleEvent(ev("PreToolUse", tool: "Read"), context: ctx(nil, nil))
    var s = store.sessions["s1"]
    XCTAssertEqual(s?.tty, "/dev/ttys010")
    XCTAssertEqual(s?.pid, 100)
    XCTAssertEqual(s?.branch, "main", "absent header keeps the branch")
    store.handleEvent(ev("UserPromptSubmit"), context: ctx("/dev/ttys011", 200, branch: "dev"))
    s = store.sessions["s1"]
    XCTAssertEqual(s?.tty, "/dev/ttys011")
    XCTAssertEqual(s?.pid, 200)
    XCTAssertEqual(s?.branch, "dev")
  }

  func testDisambiguator() {
    store.handleEvent(ev("SessionStart", sid: "a"), context: ctx("/dev/ttys001", 11))
    XCTAssertNil(store.disambiguator(for: store.sessions["a"]!), "unique project name")
    XCTAssertEqual(store.displayName(for: store.sessions["a"]!), "proj")
    store.handleEvent(ev("SessionStart", sid: "b"), context: ctx("/dev/ttys012", 12))
    XCTAssertEqual(store.disambiguator(for: store.sessions["a"]!), "s001")
    XCTAssertEqual(store.disambiguator(for: store.sessions["b"]!), "s012")
    store.handleEvent(ev("UserPromptSubmit", sid: "a"), context: ctx(nil, nil, branch: "main"))
    store.handleEvent(ev("UserPromptSubmit", sid: "b"), context: ctx(nil, nil, branch: "dev"))
    XCTAssertEqual(store.displayName(for: store.sessions["a"]!), "proj · main")
    XCTAssertEqual(store.disambiguator(for: store.sessions["b"]!), "dev")
    store.handleEvent(ev("UserPromptSubmit", sid: "b"), context: ctx(nil, nil, branch: "main"))
    XCTAssertEqual(store.disambiguator(for: store.sessions["b"]!), "main · s012")
    store.handleEvent(ev("SessionStart", sid: "c", cwd: "/other"), context: ctx(nil, nil))
    XCTAssertNil(store.disambiguator(for: store.sessions["c"]!))
  }

  // MARK: - C3 liveness

  func testDeadProcessRemovesSessionAndFlushesCards() {
    procs.set(100, tty: "/dev/ttys010")
    store.handleEvent(ev("UserPromptSubmit"), context: ctx("/dev/ttys010", 100))
    store.handleEvent(ev("SessionStart", sid: "legacy"), termProgram: "ghostty")
    let log = ReplyLog()
    store.addPermission(
      ev("PermissionRequest", tool: "Bash", input: .object(["command": .string("ls")])),
      context: ctx("/dev/ttys010", 100)
    ) { log.add($0) }
    XCTAssertEqual(store.sweep(), [])
    XCTAssertNotNil(store.sessions["s1"])
    procs.kill(100)
    XCTAssertEqual(store.sweep(), ["s1"])
    XCTAssertNil(store.sessions["s1"])
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertEqual(log.all.count, 1)
    XCTAssertNil(log.all[0] as Data?, "dead session's card gets an empty reply")
    XCTAssertNotNil(store.sessions["legacy"], "no pid: never removed by liveness")
  }

  func testTTYReuseCountsAsDead() {
    procs.set(100, tty: "/dev/ttys010")
    store.handleEvent(ev("UserPromptSubmit"), context: ctx("/dev/ttys010", 100))
    procs.set(100, tty: nil)  // unknown tty: keep
    store.sweep()
    XCTAssertNotNil(store.sessions["s1"])
    procs.set(100, tty: "")  // lost its terminal
    store.sweep()
    XCTAssertNil(store.sessions["s1"])
    procs.set(200, tty: "/dev/ttys020")
    store.handleEvent(ev("UserPromptSubmit", sid: "s2"), context: ctx("/dev/ttys020", 200))
    procs.set(200, tty: "/dev/ttys021")  // pid reused elsewhere
    XCTAssertFalse(store.isAlive(store.sessions["s2"]!))
    store.sweep()
    XCTAssertNil(store.sessions["s2"])
  }

  func testSystemProbe() {
    let probe = ProcessProbe.system
    XCTAssertTrue(probe.isAlive(getpid()))
    XCTAssertFalse(probe.isAlive(0))
    XCTAssertFalse(probe.isAlive(1), "launchd is never a claude session")
    XCTAssertFalse(probe.isAlive(99_999_999))
    let mine = probe.ttyOf(getpid())
    XCTAssertNotNil(mine)
    if let mine, !mine.isEmpty { XCTAssertTrue(mine.hasPrefix("/dev/"), mine) }
    XCTAssertTrue(probe.owns(pid: getpid(), tty: mine))
  }

  func testQuietAfterTenMinutesWithoutEvents() {
    store.handleEvent(ev("PreToolUse", tool: "Bash"), context: ctx(nil, nil))
    clock.advance(SessionStore.quietAfter - 1)
    store.sweep()
    XCTAssertEqual(status(), .working(tool: "Bash"))
    clock.advance(2)
    store.sweep()
    XCTAssertEqual(status(), .quiet)
    XCTAssertEqual(status()?.label, "Sessiz")
    XCTAssertFalse(store.anyWorking)
    store.handleEvent(ev("PostToolUse", tool: "Bash"), context: ctx(nil, nil))
    XCTAssertEqual(status(), .working(tool: nil))
  }

  func testNoQuietWhileCardPending() {
    store.addPermission(ev("PermissionRequest", tool: "Bash"), context: ctx(nil, nil)) { _ in }
    clock.advance(SessionStore.quietAfter + 5)
    store.sweep()
    XCTAssertTrue(status()?.isWorking == true)
  }

  // MARK: - C4 status semantics

  func testDoneStaysUntilSeenAndIdlePromptDoesNotOverride() {
    store.handleEvent(ev("UserPromptSubmit"), context: ctx("/dev/ttys010", 100))
    store.handleEvent(ev("Stop"), context: ctx(nil, nil))
    XCTAssertTrue(store.sessions["s1"]?.isDoneUnseen == true)
    clock.advance(60)
    store.handleEvent(ev("Notification", ntype: "idle_prompt"), context: ctx(nil, nil))
    XCTAssertEqual(status(), .done("Tamamlandı"))
    XCTAssertTrue(store.sessions["s1"]?.unseen == true)
    XCTAssertEqual(store.attentionCount, 0, "done-unseen is not amber attention")
    XCTAssertEqual(store.doneUnseenCount, 1)
    XCTAssertTrue(store.anyDone)
    XCTAssertFalse(store.markSeen(tty: "/dev/ttys099"))
    XCTAssertTrue(store.markSeen(tty: "/dev/ttys010"))
    XCTAssertEqual(status(), .done("Tamamlandı"))
    XCTAssertEqual(store.doneUnseenCount, 0)
    XCTAssertFalse(store.anyDone)
  }

  func testMarkSeenClearsWaitingButNotQuestion() {
    store.handleEvent(ev("Notification", ntype: "idle_prompt"), context: ctx(nil, nil))
    XCTAssertEqual(store.attentionCount, 1)
    store.markSeen(sessionID: "s1")
    XCTAssertEqual(status(), .idle)
    XCTAssertEqual(store.attentionCount, 0)
    store.handleEvent(ev("PreToolUse", tool: "AskUserQuestion", input: questionInput),
      context: ctx(nil, nil))
    store.markSeen(sessionID: "s1")
    XCTAssertEqual(status()?.kind, "question", "a question waits for an answer, not a look")
  }

  func testErrorCountsUntilSeen() {
    store.handleEvent(ev("StopFailure"), context: ctx(nil, nil))
    XCTAssertEqual(store.attentionCount, 1)
    XCTAssertTrue(store.anyError)
    store.markSeen(sessionID: "s1")
    XCTAssertEqual(status()?.kind, "error")
    XCTAssertEqual(store.attentionCount, 0)
    XCTAssertFalse(store.anyError)
  }

  func testAskUserQuestionBecomesQuestion() {
    store.handleEvent(ev("UserPromptSubmit"), context: ctx(nil, nil))
    store.handleEvent(ev("PreToolUse", tool: "AskUserQuestion", input: questionInput),
      context: ctx(nil, nil))
    XCTAssertEqual(status(), .question(text: "Hangi çatı? Seç", options: ["React", "Vue"]))
    XCTAssertEqual(status()?.label, "Soru soruyor")
    XCTAssertEqual(store.attentionCount, 1)
    XCTAssertTrue(store.anyWaiting)
    // the forwarded PermissionRequest for the same call does not announce twice
    store.handleEvent(ev("PermissionRequest", tool: "AskUserQuestion", input: questionInput),
      context: ctx(nil, nil))
    let peeks = effects.filter { $0 == .attention(sessionID: "s1", kind: "question") }
    XCTAssertEqual(peeks.count, 1)
    // the generic "needs permission" notification does not hide the question
    store.handleEvent(ev("Notification", ntype: "permission_prompt"), context: ctx(nil, nil))
    XCTAssertEqual(status()?.kind, "question")
    // idle_prompt racing the dialog (within the grace window) does not hide it
    store.handleEvent(ev("Notification", ntype: "idle_prompt"), context: ctx(nil, nil))
    XCTAssertEqual(status()?.kind, "question")
    // a subagent's tool event does not hide it either
    store.handleEvent(ev("PreToolUse", tool: "Read", agent: "ag1"), context: ctx(nil, nil))
    XCTAssertEqual(status()?.kind, "question")
    store.handleEvent(ev("PostToolUse", tool: "AskUserQuestion", input: questionInput),
      context: ctx(nil, nil))
    XCTAssertEqual(status(), .working(tool: nil))
  }

  func testIdlePromptEndsDismissedQuestionAndPlan() {
    for tool in ["AskUserQuestion", "ExitPlanMode"] {
      store.handleEvent(ev("PreToolUse", tool: tool, input: questionInput), context: ctx(nil, nil))
      XCTAssertEqual(store.attentionCount, 1, tool)
      clock.advance(60)  // Esc in the terminal, user walked away
      store.handleEvent(ev("Notification", ntype: "idle_prompt"), context: ctx(nil, nil))
      XCTAssertEqual(status(), .waitingInput("m"), tool)
      store.markSeen(sessionID: "s1")
      XCTAssertEqual(store.attentionCount, 0, tool)
    }
  }

  func testQuestionParsedFromPayload() throws {
    let body = #"""
      {"hook_event_name":"PreToolUse","session_id":"q","tool_name":"AskUserQuestion",
       "tool_input":{"questions":[{"question":"Devam?","header":"H",
       "options":[{"label":"Evet"},{"label":"Hayır"}],"multiSelect":false}]}}
      """#
    let e = try XCTUnwrap(HookEvent.parse(Data(body.utf8)))
    XCTAssertEqual(e.question?.text, "Devam?")
    XCTAssertEqual(e.question?.options, ["Evet", "Hayır"])
  }

  func testExitPlanModeBecomesPlanApproval() {
    let input: JSONValue = .object(["plan": .string("\n## Kimlik doğrulamayı ayır\n1. ...")])
    store.handleEvent(ev("PreToolUse", tool: "ExitPlanMode", input: input), context: ctx(nil, nil))
    XCTAssertEqual(status(), .planApproval("Kimlik doğrulamayı ayır"))
    XCTAssertEqual(status()?.label, "Plan onayı bekliyor")
    XCTAssertEqual(store.attentionCount, 1)
    store.handleEvent(ev("PermissionRequest", tool: "ExitPlanMode"), context: ctx(nil, nil))
    XCTAssertEqual(status(), .planApproval(nil))
  }

  func testPermissionPromptStillShowsWithoutCard() {
    store.handleEvent(ev("Notification", ntype: "permission_prompt"), context: ctx(nil, nil))
    XCTAssertEqual(status(), .waitingInput("m"))
  }

  // MARK: - C5 queue

  func testQueueIsOldestFirstAndPerSession() {
    var ids: [String] = []
    for (i, sid) in ["a", "b", "a", "c"].enumerated() {
      let input: JSONValue = .object(["command": .string("cmd\(i)")])
      let card = store.addPermission(
        ev("PermissionRequest", sid: sid, tool: "Bash", input: input), context: ctx(nil, nil)
      ) { _ in }
      ids.append(card.id)
      clock.advance(1)
    }
    XCTAssertEqual(store.queue.map(\.id), ids)
    XCTAssertEqual(store.cards(for: "a").map(\.id), [ids[0], ids[2]])
    XCTAssertEqual(store.firstCard(for: "c")?.id, ids[3])
    XCTAssertNil(store.firstCard(for: "zzz"))
    XCTAssertEqual(store.queuePosition(of: ids[2])?.index, 2)
    XCTAssertEqual(store.queuePosition(of: ids[2])?.total, 4)
    XCTAssertEqual(store.card(id: ids[1])?.sessionID, "b")
    XCTAssertEqual(store.attentionCount, 3)
    XCTAssertTrue(effects.contains(.attention(sessionID: "b", kind: "permission")))
    store.decide(id: ids[0], decision: .allow)
    XCTAssertEqual(store.queue.map(\.id), [ids[1], ids[2], ids[3]])
  }

  func testOrderedSessionsGroupsStably() {
    store.handleEvent(ev("SessionStart", sid: "idle"), context: ctx(nil, nil))
    clock.advance(1)
    store.handleEvent(ev("UserPromptSubmit", sid: "work"), context: ctx(nil, nil))
    clock.advance(1)
    store.handleEvent(ev("Stop", sid: "done"), context: ctx(nil, nil))
    clock.advance(1)
    store.handleEvent(ev("Notification", sid: "wait", ntype: "idle_prompt"), context: ctx(nil, nil))
    clock.advance(1)
    store.handleEvent(ev("UserPromptSubmit", sid: "work2"), context: ctx(nil, nil))
    XCTAssertEqual(store.orderedSessions.map(\.id), ["wait", "done", "work", "work2", "idle"])
    // activity does not reorder inside a group
    store.handleEvent(ev("PreToolUse", sid: "work2", tool: "Read"), context: ctx(nil, nil))
    XCTAssertEqual(store.orderedSessions.map(\.id), ["wait", "done", "work", "work2", "idle"])
  }

  // MARK: - Agent state

  func testSubagentsTracked() {
    var e = ev("PreToolUse", tool: "Grep", agent: "ag1")
    e.agentType = "Explore"
    store.handleEvent(e, context: ctx(nil, nil))
    XCTAssertEqual(store.sessions["s1"]?.activeAgents.map(\.type), ["Explore"])
    XCTAssertEqual(store.sessions["s1"]?.activeAgents.first?.lastTool, "Grep")
    store.handleEvent(ev("PostToolUse", tool: "Grep", agent: "ag2"), context: ctx(nil, nil))
    XCTAssertEqual(store.sessions["s1"]?.agents.count, 2)
    store.handleEvent(ev("SubagentStop", agent: "ag2"), context: ctx(nil, nil))
    XCTAssertEqual(store.sessions["s1"]?.agents.keys.sorted(), ["ag1"])
    clock.advance(SessionStore.agentStaleAfter + 1)
    store.sweep()
    XCTAssertEqual(store.sessions["s1"]?.agents.count, 0)
  }
}
