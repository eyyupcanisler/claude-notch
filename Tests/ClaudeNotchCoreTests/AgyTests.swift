import Foundation
import XCTest

@testable import ClaudeNotchCore

/// agy (Antigravity CLI) support in Core: hook payloads, linking helper conversations to the chat
/// that started them, agy's CLI log lines, the plan meters and the per-process status line
/// snapshot. Plan: docs/plans/2026-11-21-agy-in-the-notch.md. Payload shapes were measured on
/// agy 1.5.14 (2026-11-21).
final class AgyTests: XCTestCase {

  // MARK: - Hook payload

  private func payload(
    _ event: String, conv: String = "c-main", invocation: Int? = nil, tool: String? = nil,
    args: [String: JSONValue] = [:], input: String? = nil, model: String? = "gemini-4-neon-medium",
    step: Int? = nil
  ) -> AgyHookPayload {
    var p = AgyHookPayload(event: event, conversationID: conv, cwd: "/Users/x/proj")
    p.invocationNum = invocation
    p.lastUserInput = input
    p.modelName = model
    p.stepIdx = step
    if let tool {
      p.toolName = tool
      p.toolArgs = .object(args)
    }
    return p
  }

  func testParsesTheCamelCasePayload() throws {
    let json = """
      {"hookEventName":"PreToolUse","conversationId":"8791475c","cwd":"/Users/x/proj",
       "workspacePaths":["/Users/x/proj"],"modelName":"gemini-4-neon-medium",
       "transcriptPath":"/t.jsonl","lastUserInput":"hi","stepIdx":7,
       "toolCall":{"id":"call-1","name":"run_command","args":{"CommandLine":"npm test","Cwd":"/Users/x/proj"}}}
      """
    let p = try XCTUnwrap(AgyHookPayload.parse(Data(json.utf8), fallbackEvent: nil))
    XCTAssertEqual(p.event, "PreToolUse")
    XCTAssertEqual(p.conversationID, "8791475c")
    XCTAssertEqual(p.cwd, "/Users/x/proj")
    XCTAssertEqual(p.modelName, "gemini-4-neon-medium")
    XCTAssertEqual(p.lastUserInput, "hi")
    XCTAssertEqual(p.stepIdx, 7)
    XCTAssertEqual(p.toolName, "run_command")
    XCTAssertEqual(p.toolCallID, "call-1")
    XCTAssertEqual(p.toolArgs?["CommandLine"]?.stringValue, "npm test")
  }

  func testEventNameFallsBackToTheHooksArgument() throws {
    // Older agy builds send no hookEventName; the hook command names its event instead.
    let json = #"{"conversationId":"c1","cwd":"/p","invocationNum":0}"#
    let p = try XCTUnwrap(AgyHookPayload.parse(Data(json.utf8), fallbackEvent: "PreInvocation"))
    XCTAssertEqual(p.event, "PreInvocation")
    XCTAssertEqual(p.invocationNum, 0)
    // The payload's own name wins over the argument.
    let named = #"{"hookEventName":"Stop","conversationId":"c1","cwd":"/p"}"#
    XCTAssertEqual(
      AgyHookPayload.parse(Data(named.utf8), fallbackEvent: "PreInvocation")?.event, "Stop")
  }

  func testRejectsPayloadsWithoutConversationOrEvent() {
    XCTAssertNil(AgyHookPayload.parse(Data(#"{"hookEventName":"Stop","cwd":"/p"}"#.utf8), fallbackEvent: nil))
    XCTAssertNil(AgyHookPayload.parse(Data(#"{"hookEventName":"Stop","conversationId":""}"#.utf8), fallbackEvent: nil))
    XCTAssertNil(AgyHookPayload.parse(Data(#"{"conversationId":"c1"}"#.utf8), fallbackEvent: nil))
    XCTAssertNil(AgyHookPayload.parse(Data("[1,2]".utf8), fallbackEvent: "Stop"))
    XCTAssertNil(AgyHookPayload.parse(Data("not json".utf8), fallbackEvent: "Stop"))
  }

  // MARK: - Tool names in Claude Code's shape (so activity text and summaries work unchanged)

  func testToolsMapToClaudeShapes() {
    let bash = AgyTools.claudeShape(name: "run_command", args: .object(["CommandLine": .string("ls -la")]))
    XCTAssertEqual(bash.toolName, "Bash")
    XCTAssertEqual(bash.input?["command"]?.stringValue, "ls -la")

    let write = AgyTools.claudeShape(name: "write_file", args: .object(["TargetFile": .string("/p/a.swift")]))
    XCTAssertEqual(write.toolName, "Write")
    XCTAssertEqual(write.input?["file_path"]?.stringValue, "/p/a.swift")

    let edit = AgyTools.claudeShape(name: "edit_file", args: .object(["AbsolutePath": .string("/p/b.swift")]))
    XCTAssertEqual(edit.toolName, "Edit")
    XCTAssertEqual(edit.input?["file_path"]?.stringValue, "/p/b.swift")

    let read = AgyTools.claudeShape(name: "read_file", args: .object(["Path": .string("/p/c.md")]))
    XCTAssertEqual(read.toolName, "Read")
    XCTAssertEqual(read.input?["file_path"]?.stringValue, "/p/c.md")

    let other = AgyTools.claudeShape(name: "run_workflow", args: .object(["Name": .string("w")]))
    XCTAssertEqual(other.toolName, "run_workflow")
    XCTAssertEqual(other.input?["Name"]?.stringValue, "w")
  }

  func testLargeArgsAreNeverKept() {
    // write_file can carry a whole file: only its path is kept.
    let big = String(repeating: "x", count: 100_000)
    let write = AgyTools.claudeShape(
      name: "write_file", args: .object(["TargetFile": .string("/p/a"), "CodeContent": .string(big)]))
    XCTAssertEqual(write.input, .object(["file_path": .string("/p/a")]))
    let other = AgyTools.claudeShape(name: "mcp_tool", args: .object(["blob": .string(big)]))
    XCTAssertEqual(other.toolName, "mcp_tool")
    XCTAssertNil(other.input)
  }

  // MARK: - Linking: one agy process, its main chat and its helpers

  func testMainChatEventsMapToClaudeEvents() throws {
    var l = AgyLinker()
    let start = try XCTUnwrap(l.translate(payload("SessionStart"), pid: 100))
    XCTAssertEqual(start.name, "SessionStart")
    XCTAssertEqual(start.sessionID, "c-main")
    XCTAssertEqual(start.source, "startup")
    XCTAssertEqual(start.cwd, "/Users/x/proj")
    XCTAssertNil(start.agentID)

    let prompt = try XCTUnwrap(l.translate(payload("PreInvocation", invocation: 0, input: "fix it"), pid: 100))
    XCTAssertEqual(prompt.name, "UserPromptSubmit")
    XCTAssertEqual(prompt.sessionID, "c-main")

    // Later model calls of the same turn carry nothing for the store.
    XCTAssertNil(l.translate(payload("PreInvocation", invocation: 3), pid: 100))
    // agy's payloads are protojson, which leaves zero values out: no invocationNum is the
    // turn's first call (agy-bridge reads it the same way).
    XCTAssertEqual(l.translate(payload("PreInvocation"), pid: 100)?.name, "UserPromptSubmit")
    XCTAssertNil(l.translate(payload("PostInvocation", invocation: 3), pid: 100))

    let pre = try XCTUnwrap(
      l.translate(payload("PreToolUse", tool: "run_command", args: ["CommandLine": .string("npm test")]), pid: 100))
    XCTAssertEqual(pre.name, "PreToolUse")
    XCTAssertEqual(pre.toolName, "Bash")
    XCTAssertEqual(pre.toolInput?["command"]?.stringValue, "npm test")

    let post = try XCTUnwrap(
      l.translate(payload("PostToolUse", tool: "run_command", args: ["CommandLine": .string("npm test")]), pid: 100))
    XCTAssertEqual(post.name, "PostToolUse")
    XCTAssertEqual(post.toolName, "Bash")

    let stop = try XCTUnwrap(l.translate(payload("Stop"), pid: 100))
    XCTAssertEqual(stop.name, "Stop")
    XCTAssertEqual(stop.sessionID, "c-main")
    XCTAssertNil(l.translate(payload("SomethingNew"), pid: 100))
    XCTAssertEqual(l.mainConversation(pid: 100), "c-main")
  }

  func testStopCarriesErrorsAndBackgroundWork() throws {
    let json = """
      {"hookEventName":"Stop","conversationId":"c1","cwd":"/p","terminationReason":"ERROR",
       "error":"quota exhausted","fullyIdle":false}
      """
    let p = try XCTUnwrap(AgyHookPayload.parse(Data(json.utf8), fallbackEvent: nil))
    XCTAssertEqual(p.terminationReason, "ERROR")
    XCTAssertEqual(p.errorText, "quota exhausted")
    XCTAssertEqual(p.fullyIdle, false)

    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)
    var failed = payload("Stop")
    failed.terminationReason = "ERROR"
    failed.errorText = "quota exhausted"
    let e = try XCTUnwrap(l.translate(failed, pid: 100))
    XCTAssertEqual(e.name, "StopFailure")
    XCTAssertEqual(e.errorText, "quota exhausted")

    // A Stop while background work still runs reads as finished (a background dev server could
    // otherwise keep the row "working" for good), but the turn stays open: a helper that the
    // background workflow starts later is still a helper, not a new chat.
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)
    var paused = payload("Stop")
    paused.fullyIdle = false
    XCTAssertEqual(l.translate(paused, pid: 100)?.name, "Stop")
    let late = try XCTUnwrap(l.translate(payload("SessionStart", conv: "c-bg"), pid: 100))
    XCTAssertEqual(late.sessionID, "c-main")
    XCTAssertEqual(late.agentID, "c-bg")
  }

  func testHelperDuringATurnBecomesASubagentOfTheMainChat() throws {
    var l = AgyLinker()
    _ = l.translate(payload("SessionStart"), pid: 100)
    _ = l.translate(payload("PreInvocation", invocation: 0, input: "run the workflow"), pid: 100)

    let hStart = try XCTUnwrap(l.translate(payload("SessionStart", conv: "c-helper"), pid: 100))
    XCTAssertEqual(hStart.name, "SubagentStart")
    XCTAssertEqual(hStart.sessionID, "c-main")
    XCTAssertEqual(hStart.agentID, "c-helper")
    XCTAssertEqual(hStart.agentType, "helper")

    let hPrompt = try XCTUnwrap(l.translate(payload("PreInvocation", conv: "c-helper", invocation: 0), pid: 100))
    XCTAssertEqual(hPrompt.name, "SubagentStart")
    XCTAssertEqual(hPrompt.agentID, "c-helper")

    let hTool = try XCTUnwrap(
      l.translate(payload("PreToolUse", conv: "c-helper", tool: "read_file", args: ["Path": .string("/p/a")]), pid: 100))
    XCTAssertEqual(hTool.name, "PreToolUse")
    XCTAssertEqual(hTool.sessionID, "c-main")
    XCTAssertEqual(hTool.agentID, "c-helper")
    XCTAssertEqual(hTool.toolName, "Read")

    let hStop = try XCTUnwrap(l.translate(payload("Stop", conv: "c-helper"), pid: 100))
    XCTAssertEqual(hStop.name, "SubagentStop")
    XCTAssertEqual(hStop.sessionID, "c-main")
    XCTAssertEqual(hStop.agentID, "c-helper")
    XCTAssertEqual(l.mainConversation(pid: 100), "c-main")
  }

  func testAKnownHelperStaysAHelperAfterTheMainTurnEnds() throws {
    // A workflow can outlive the turn that started it.
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)
    _ = l.translate(payload("SessionStart", conv: "c-helper"), pid: 100)
    _ = l.translate(payload("Stop"), pid: 100)
    let late = try XCTUnwrap(
      l.translate(payload("PreToolUse", conv: "c-helper", tool: "run_command", args: ["CommandLine": .string("ls")]), pid: 100))
    XCTAssertEqual(late.sessionID, "c-main")
    XCTAssertEqual(late.agentID, "c-helper")
  }

  func testANewConversationBetweenTurnsReplacesTheMainChat() throws {
    // /new or /resume in the same agy process: the row moves to the new conversation.
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)
    var idle = payload("Stop")
    idle.fullyIdle = true  // a real turn end: nothing left in the background
    _ = l.translate(idle, pid: 100)
    let next = try XCTUnwrap(l.translate(payload("SessionStart", conv: "c-new"), pid: 100))
    XCTAssertEqual(next.name, "SessionStart")
    XCTAssertEqual(next.sessionID, "c-new")
    XCTAssertNil(next.agentID)
    XCTAssertEqual(l.mainConversation(pid: 100), "c-new")
  }

  func testTheStatusLineConversationDecidesWhichChatIsMain() throws {
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)
    // A turn is running, so without the status line "c-new" would look like a helper; the
    // status line shows "c-new", so it is the chat the user sees.
    let e = try XCTUnwrap(
      l.translate(payload("PreInvocation", conv: "c-new", invocation: 0), pid: 100, shownConversation: "c-new"))
    XCTAssertEqual(e.name, "UserPromptSubmit")
    XCTAssertEqual(e.sessionID, "c-new")
    XCTAssertNil(e.agentID)
    XCTAssertEqual(l.mainConversation(pid: 100), "c-new")
    // And a conversation the status line does not show is a helper of it, even between turns.
    _ = l.translate(payload("Stop", conv: "c-new"), pid: 100, shownConversation: "c-new")
    let h = try XCTUnwrap(
      l.translate(payload("SessionStart", conv: "c-x"), pid: 100, shownConversation: "c-new"))
    XCTAssertEqual(h.sessionID, "c-new")
    XCTAssertEqual(h.agentID, "c-x")
    // An empty status line conversation (before the first turn) is ignored.
    var fresh = AgyLinker()
    let first = try XCTUnwrap(fresh.translate(payload("SessionStart", conv: "c1"), pid: 7, shownConversation: ""))
    XCTAssertEqual(first.sessionID, "c1")
    XCTAssertNil(first.agentID)
  }

  func testProcessesAreLinkedSeparately() throws {
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", conv: "a", invocation: 0), pid: 100)
    let b = try XCTUnwrap(l.translate(payload("PreInvocation", conv: "b", invocation: 0), pid: 200))
    XCTAssertEqual(b.sessionID, "b")
    XCTAssertNil(b.agentID)
    XCTAssertEqual(l.mainConversation(pid: 100), "a")
    XCTAssertEqual(l.mainConversation(pid: 200), "b")
    l.forget(pid: 100)
    XCTAssertNil(l.mainConversation(pid: 100))
    XCTAssertEqual(l.mainConversation(pid: 200), "b")
  }

  func testWithoutAPidEveryConversationIsItsOwnChat() throws {
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", conv: "a", invocation: 0), pid: nil)
    let b = try XCTUnwrap(l.translate(payload("SessionStart", conv: "b"), pid: nil))
    XCTAssertEqual(b.sessionID, "b")
    XCTAssertNil(b.agentID)
  }

  // MARK: - agy's CLI log

  func testParsesThePermissionAndQuestionLines() {
    XCTAssertEqual(
      AgyLogEvent.parse(
        #"I1121 18:57:57.763500    3170 tool_confirmation_manager.go:237] Surfacing tool confirmation: "RunWorkflow" at step 36"#),
      .permissionShown(tool: "RunWorkflow", step: 36))
    XCTAssertEqual(
      AgyLogEvent.parse(
        "I1121 18:58:23.011851     187 input_loop.go:821] Responding to tool confirmation: convID=3deb8246-4fbd-479b-bb5b-facb0e9a2a0d, stepIdx=36, approved=true, sandboxOverride=false, scope=PERMISSION_SCOPE_UNSPECIFIED, persistGrants=[],"),
      .permissionAnswered(conversationID: "3deb8246-4fbd-479b-bb5b-facb0e9a2a0d", step: 36, approved: true))
    XCTAssertEqual(
      AgyLogEvent.parse(
        "I1121 19:05:24.177469     187 input_loop.go:821] Responding to tool confirmation: convID=abc, stepIdx=53, approved=false, sandboxOverride=false"),
      .permissionAnswered(conversationID: "abc", step: 53, approved: false))
    XCTAssertEqual(
      AgyLogEvent.parse("I1121 18:50:25.918715    3170 conversation_manager.go:1596] Surfacing ask_question at step 11"),
      .questionShown(step: 11))
  }

  func testIgnoresEveryOtherLine() {
    for line in [
      "",
      #"I1121 18:57:56.670308   14494 runner.go:957] Monitor agy_tool_safety FINISHED: triggered=true, reason="unsupported_tool: run_workflow""#,
      "I1121 18:58:23.012010   14617 server.go:2852] Tool confirmation for conversation 3deb step 36 (type=*gemini_coder_go_proto.Step_Generic approved=true)",
      #"Surfacing tool confirmation: "" at step 4"#,
      #"Surfacing tool confirmation: "X" at step many"#,
      "Responding to tool confirmation: convID=, stepIdx=3, approved=true",
    ] {
      XCTAssertNil(AgyLogEvent.parse(line), line)
    }
  }

  func testATooLongOrOddToolNameIsCleaned() {
    let long = String(repeating: "A", count: 300)
    guard case .permissionShown(let tool, _)? = AgyLogEvent.parse(#"Surfacing tool confirmation: "\#(long)" at step 1"#)
    else { return XCTFail("not parsed") }
    XCTAssertLessThanOrEqual(tool.count, 80)
    guard case .permissionShown(let odd, _)? = AgyLogEvent.parse("Surfacing tool confirmation: \"Run\u{202E}Me\" at step 2")
    else { return XCTFail("not parsed") }
    XCTAssertFalse(odd.unicodeScalars.contains("\u{202E}"))
  }

  func testLogEventsBecomeStoreEventsForThatProcessesMainChat() throws {
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", invocation: 0), pid: 100)

    let asked = try XCTUnwrap(l.storeEvent(for: .permissionShown(tool: "RunWorkflow", step: 36), pid: 100))
    XCTAssertEqual(asked.name, "Notification")
    XCTAssertEqual(asked.sessionID, "c-main")
    XCTAssertEqual(asked.notificationType, "permission_prompt")
    XCTAssertTrue(asked.message?.contains("RunWorkflow") ?? false)

    let answered = try XCTUnwrap(
      l.storeEvent(for: .permissionAnswered(conversationID: "c-helper", step: 36, approved: true), pid: 100))
    XCTAssertEqual(answered.name, "PostToolUse")
    XCTAssertEqual(answered.sessionID, "c-main")
    XCTAssertNil(answered.agentID)

    let question = try XCTUnwrap(l.storeEvent(for: .questionShown(step: 11), pid: 100))
    XCTAssertEqual(question.name, "Notification")
    XCTAssertEqual(question.notificationType, "agent_needs_input")
    XCTAssertEqual(question.sessionID, "c-main")

    // A process with no known chat yet: nothing to show it on.
    XCTAssertNil(l.storeEvent(for: .questionShown(step: 1), pid: 999))
  }

  // MARK: - Plan meters (agy-bridge's meters.json stores % LEFT; the notch shows % used)

  private let metersJSON = """
    {"ts": 1795282415.0, "meters": {"gemini": {"weekly": 98, "five_hour": 94},
     "claude": {"weekly": 34, "five_hour": 100}, "argon": {"weekly": 100},
     "Gemini 5 Xenon": {"five_hour": 80, "weekly": 95}, "Veo Video": {"weekly": 60}}}
    """

  func testMetersAreShownAsPercentUsedInAFixedOrder() throws {
    let u = try XCTUnwrap(AgyUsage.parse(Data(metersJSON.utf8)))
    XCTAssertEqual(u.readAt, Date(timeIntervalSince1970: 1_795_282_415))
    XCTAssertEqual(u.pools.map(\.key), ["gemini", "claude", "argon", "Gemini 5 Xenon", "Veo Video"])
    XCTAssertEqual(u.pools.map(\.label), ["Gemini", "Claude+GPT", "Argon", "Gemini 5", "Veo"])
    XCTAssertEqual(u.pools[0].fiveHour, 6)
    XCTAssertEqual(u.pools[0].weekly, 2)
    XCTAssertEqual(u.pools[1].fiveHour, 0)
    XCTAssertEqual(u.pools[1].weekly, 66)
    XCTAssertNil(u.pools[2].fiveHour)
    XCTAssertEqual(u.pools[2].weekly, 0)
    XCTAssertEqual(u.pools[4].weekly, 40)
  }

  func testTheRingShowsTheFullestWindow() throws {
    let u = try XCTUnwrap(AgyUsage.parse(Data(metersJSON.utf8)))
    let f = try XCTUnwrap(u.fullest)
    XCTAssertEqual(f.pool.key, "claude")
    XCTAssertEqual(f.kind, .sevenDay)
    XCTAssertEqual(f.percent, 66)
  }

  func testBadMetersAreRejectedAndValuesClamped() throws {
    XCTAssertNil(AgyUsage.parse(Data("{}".utf8)))
    XCTAssertNil(AgyUsage.parse(Data(#"{"ts": 1, "meters": {}}"#.utf8)))
    XCTAssertNil(AgyUsage.parse(Data(#"{"meters": {"gemini": {"weekly": 50}}}"#.utf8)))
    let odd = try XCTUnwrap(
      AgyUsage.parse(Data(#"{"ts": 1, "meters": {"gemini": {"weekly": 140, "five_hour": -5}, "x": "y"}}"#.utf8)))
    XCTAssertEqual(odd.pools.count, 1)
    XCTAssertEqual(odd.pools[0].weekly, 0)
    XCTAssertEqual(odd.pools[0].fiveHour, 100)
  }

  func testAReadingOlderThanFifteenMinutesIsStale() throws {
    let u = try XCTUnwrap(AgyUsage.parse(Data(metersJSON.utf8)))
    XCTAssertFalse(u.isStale(at: u.readAt.addingTimeInterval(14 * 60)))
    XCTAssertTrue(u.isStale(at: u.readAt.addingTimeInterval(15 * 60 + 1)))
  }

  private func usage(_ meters: String, ts: Double = 1000) -> AgyUsage {
    AgyUsage.parse(Data(#"{"ts": \#(ts), "meters": \#(meters)}"#.utf8))!
  }

  func testFiveHourWindowsWarnAtEightyAndNinetyFiveOnce() {
    let now = Date(timeIntervalSince1970: 1060)
    let u = usage(#"{"gemini": {"five_hour": 15, "weekly": 90}, "claude": {"five_hour": 50, "weekly": 40}}"#)
    let alerts = u.alerts(shown: [], at: now, weekly: false)
    XCTAssertEqual(alerts.count, 1)
    XCTAssertEqual(alerts[0].poolLabel, "Gemini")
    XCTAssertEqual(alerts[0].kind, .fiveHour)
    XCTAssertEqual(alerts[0].mark, 80)
    XCTAssertTrue(alerts[0].title.contains("Gemini"))
    // Already shown: no second note for the same mark.
    XCTAssertTrue(u.alerts(shown: [alerts[0].key], at: now, weekly: false).isEmpty)
    // 95 is a new mark.
    let worse = usage(#"{"gemini": {"five_hour": 3}}"#)
    let next = worse.alerts(shown: [alerts[0].key], at: now, weekly: false)
    XCTAssertEqual(next.map(\.mark), [95])
  }

  func testWeeklyWindowsWarnOnlyWithTheWeeklySetting() {
    let now = Date(timeIntervalSince1970: 1060)
    let u = usage(#"{"claude": {"five_hour": 100, "weekly": 10}, "argon": {"weekly": 4}}"#)
    XCTAssertTrue(u.alerts(shown: [], at: now, weekly: false).isEmpty)
    let on = u.alerts(shown: [], at: now, weekly: true)
    XCTAssertEqual(on.map(\.poolLabel), ["Claude+GPT", "Argon"])
    XCTAssertEqual(on.map(\.mark), [80, 95])
    XCTAssertTrue(on.allSatisfy { $0.kind == .sevenDay })
  }

  func testAStaleReadingNeverWarns() {
    let u = usage(#"{"gemini": {"five_hour": 1}}"#, ts: 1000)
    XCTAssertTrue(u.alerts(shown: [], at: Date(timeIntervalSince1970: 1000 + 16 * 60), weekly: true).isEmpty)
  }

  func testAWindowThatDroppedBackForgetsItsWarnings() {
    // No reset times in meters.json: a warned key is kept only while its window is still at or
    // above the mark, so the next time it fills up it warns again.
    let warned: Set<String> = [
      AgyUsage.alertKey(pool: "gemini", kind: .fiveHour, mark: 80),
      AgyUsage.alertKey(pool: "gemini", kind: .fiveHour, mark: 95),
      AgyUsage.alertKey(pool: "claude", kind: .sevenDay, mark: 80),
    ]
    let u = usage(#"{"gemini": {"five_hour": 15}, "claude": {"weekly": 10}}"#)
    XCTAssertEqual(
      u.liveWarnings(warned),
      [AgyUsage.alertKey(pool: "gemini", kind: .fiveHour, mark: 80),
       AgyUsage.alertKey(pool: "claude", kind: .sevenDay, mark: 80)])
  }

  // MARK: - Per-process status line snapshot

  func testSnapshotGivesModelEffortContextAndConversation() throws {
    let json = """
      {"cwd":"/p","session_id":"8791","conversation_id":"8791",
       "model":{"id":"Gemini 4 Neon (Medium)","display_name":"Gemini 4 Neon (Medium)","effort":"medium"},
       "context_window":{"used_percentage":42,"remaining_percentage":58,"context_window_size":1048576},
       "agent_state":"idle","sandbox":{"enabled":false}}
      """
    let s = try XCTUnwrap(AgyStatusSnapshot.parse(Data(json.utf8)))
    XCTAssertEqual(s.conversationID, "8791")
    XCTAssertEqual(s.modelLabel, "Gemini 4 Neon · medium")
    XCTAssertEqual(s.contextLeft, 58)
  }

  func testSnapshotEdgeCases() throws {
    let empty = try XCTUnwrap(
      AgyStatusSnapshot.parse(Data(#"{"conversation_id":"","model":{"display_name":"Claude Opus 5.5"}}"#.utf8)))
    XCTAssertNil(empty.conversationID)
    XCTAssertEqual(empty.modelLabel, "Claude Opus 5.5")
    XCTAssertNil(empty.contextLeft)
    let usedOnly = try XCTUnwrap(
      AgyStatusSnapshot.parse(Data(#"{"context_window":{"used_percentage":30}}"#.utf8)))
    XCTAssertEqual(usedOnly.contextLeft, 70)
    XCTAssertNil(AgyStatusSnapshot.parse(Data("[]".utf8)))
  }

  func testHookModelNameIsTheFallbackLabel() {
    XCTAssertEqual(AgyStatusSnapshot.label(forModelName: "gemini-4-neon-medium"), "gemini-4-neon · medium")
    XCTAssertEqual(AgyStatusSnapshot.label(forModelName: "claude-opus-5-5-high"), "claude-opus-5-5 · high")
    XCTAssertEqual(AgyStatusSnapshot.label(forModelName: "gpt-oss-120b"), "gpt-oss-120b")
    XCTAssertNil(AgyStatusSnapshot.label(forModelName: ""))
  }
}

/// agy events through the session store: rows, helpers, the log's "needs you" and the model.
@MainActor
final class AgyStoreTests: XCTestCase {
  private let alive = ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil })
  private let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys006", pid: 4242)

  private func send(
    _ store: SessionStore, _ json: String, event: String? = nil, context: HookContext? = nil,
    snapshot: AgyStatusSnapshot? = nil
  ) {
    XCTAssertTrue(
      store.handleAgyEvent(
        Data(json.utf8), context: context ?? ctx, event: event, snapshot: snapshot))
  }

  func testAnAgyChatBecomesAMarkedRowWithItsModel() throws {
    let store = SessionStore(probe: alive)
    send(store, #"{"hookEventName":"SessionStart","conversationId":"c1","cwd":"/Users/x/agenting","modelName":"gemini-4-neon-medium"}"#)
    let s = try XCTUnwrap(store.sessions["c1"])
    XCTAssertEqual(s.tool, .agy)
    XCTAssertEqual(s.project, "agenting")
    XCTAssertEqual(s.tty, "/dev/ttys006")
    XCTAssertEqual(s.pid, 4242)
    XCTAssertEqual(s.modelLabel, "gemini-4-neon · medium")
    XCTAssertEqual(store.agyChats.map(\.sessionID), ["c1"])

    send(store, #"{"conversationId":"c1","cwd":"/Users/x/agenting","invocationNum":0}"#, event: "PreInvocation")
    XCTAssertTrue(store.sessions["c1"]?.status.isWorking ?? false)

    // The status line names the model better than the hook does.
    store.applyAgySnapshot(
      AgyStatusSnapshot(conversationID: "c1", modelLabel: "Gemini 4 Neon · medium", contextLeft: 58),
      pid: 4242)
    XCTAssertEqual(store.sessions["c1"]?.modelLabel, "Gemini 4 Neon · medium")

    send(store, #"{"hookEventName":"Stop","conversationId":"c1","cwd":"/Users/x/agenting"}"#)
    XCTAssertEqual(store.sessions["c1"]?.status.kind, "done")
  }

  func testHelpersFoldIntoTheRowThatStartedThem() throws {
    let store = SessionStore(probe: alive)
    send(store, #"{"hookEventName":"PreInvocation","conversationId":"c1","cwd":"/p","invocationNum":0}"#)
    send(store, #"{"hookEventName":"SessionStart","conversationId":"h1","cwd":"/p","modelName":"gemini-3.8-flash-low"}"#)
    send(store, #"{"hookEventName":"PreToolUse","conversationId":"h1","cwd":"/p","toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#)
    XCTAssertEqual(Array(store.sessions.keys), ["c1"])
    let s = try XCTUnwrap(store.sessions["c1"])
    XCTAssertEqual(s.activeAgents.map(\.id), ["h1"])
    XCTAssertEqual(s.activeAgents.first?.type, "helper")
    // A helper's model does not replace the chat's.
    XCTAssertNotEqual(s.modelLabel, "gemini-3.8-flash · low")
    send(store, #"{"hookEventName":"Stop","conversationId":"h1","cwd":"/p"}"#)
    XCTAssertTrue(store.sessions["c1"]?.activeAgents.isEmpty ?? false)
  }

  func testTheLogTurnsTheRowAmberAndBack() throws {
    let store = SessionStore(probe: alive)
    send(store, #"{"hookEventName":"PreInvocation","conversationId":"c1","cwd":"/p","invocationNum":0}"#)
    store.handleAgyLog(.permissionShown(tool: "RunWorkflow", step: 36), pid: 4242)
    let waiting = try XCTUnwrap(store.sessions["c1"])
    XCTAssertEqual(waiting.status.kind, "waiting")
    XCTAssertTrue(waiting.needsAttention)
    XCTAssertTrue(waiting.status.detail?.contains("RunWorkflow") ?? false)
    store.handleAgyLog(.permissionAnswered(conversationID: "c1", step: 36, approved: true), pid: 4242)
    XCTAssertTrue(store.sessions["c1"]?.status.isWorking ?? false)
    store.handleAgyLog(.questionShown(step: 40), pid: 4242)
    XCTAssertEqual(store.sessions["c1"]?.status.kind, "waiting")
    // Another process's log changes nothing here.
    store.handleAgyLog(.questionShown(step: 1), pid: 999)
    XCTAssertEqual(store.sessions.count, 1)
  }

  func testEventsWithoutATerminalAreIgnoredAndBadPayloadsRejected() {
    let store = SessionStore(probe: alive)
    send(store, #"{"hookEventName":"SessionStart","conversationId":"c1","cwd":"/p"}"#, context: HookContext())
    XCTAssertTrue(store.sessions.isEmpty)
    XCTAssertFalse(store.handleAgyEvent(Data("{}".utf8), context: ctx, event: "Stop", snapshot: nil))
  }

  func testANewConversationInTheSameProcessReplacesTheRow() {
    let store = SessionStore(probe: alive)
    send(store, #"{"hookEventName":"PreInvocation","conversationId":"c1","cwd":"/p","invocationNum":0}"#)
    send(store, #"{"hookEventName":"Stop","conversationId":"c1","cwd":"/p","fullyIdle":true}"#)
    send(store, #"{"hookEventName":"SessionStart","conversationId":"c2","cwd":"/p"}"#)
    XCTAssertEqual(Array(store.sessions.keys), ["c2"])
    XCTAssertEqual(store.sessions["c2"]?.tool, .agy)
  }

  func testClaudeEventsKeepTheirTool() {
    let store = SessionStore(probe: alive)
    store.handleEvent(
      HookEvent(name: "SessionStart", sessionID: "cl", cwd: "/p"),
      context: HookContext(termProgram: "ghostty", tty: "/dev/ttys001", pid: 77))
    XCTAssertEqual(store.sessions["cl"]?.tool, .claude)
    XCTAssertNil(store.sessions["cl"]?.modelLabel)
  }
}

/// Fixes from the 2026-11-21 review of the agy build.
final class AgyReviewFixTests: XCTestCase {
  private func payload(_ event: String, conv: String, invocation: Int? = nil) -> AgyHookPayload {
    var p = AgyHookPayload(event: event, conversationID: conv, cwd: "/p")
    p.invocationNum = invocation
    return p
  }

  func testTheKnownMainChatStaysMainWhateverAStaleStatusLineSays() throws {
    // statusline-<pid>.json is kept a day: a new agy that reuses a pid can find a dead chat's id.
    var l = AgyLinker()
    let first = try XCTUnwrap(l.translate(payload("SessionStart", conv: "c1"), pid: 5, shownConversation: "dead"))
    XCTAssertNil(first.agentID)
    let next = try XCTUnwrap(l.translate(payload("PreInvocation", conv: "c1", invocation: 0), pid: 5, shownConversation: "dead"))
    XCTAssertEqual(next.name, "UserPromptSubmit")
    XCTAssertNil(next.agentID)
    let stop = try XCTUnwrap(l.translate(payload("Stop", conv: "c1"), pid: 5, shownConversation: "dead"))
    XCTAssertEqual(stop.name, "Stop")
  }

  func testAStopWithoutFullyIdleKeepsTheTurnOpen() throws {
    // protojson leaves `fullyIdle: false` out, so a Stop without it may still have background
    // work running: a helper that starts afterwards must not take over the row.
    var l = AgyLinker()
    _ = l.translate(payload("PreInvocation", conv: "c1", invocation: 0), pid: 5)
    _ = l.translate(payload("Stop", conv: "c1"), pid: 5)
    let h = try XCTUnwrap(l.translate(payload("SessionStart", conv: "h1"), pid: 5))
    XCTAssertEqual(h.sessionID, "c1")
    XCTAssertEqual(h.agentID, "h1")
    // A Stop that says everything is idle closes it: the next new conversation is a new chat.
    var done = payload("Stop", conv: "c1")
    done.fullyIdle = true
    _ = l.translate(done, pid: 5)
    let fresh = try XCTUnwrap(l.translate(payload("SessionStart", conv: "c2"), pid: 5))
    XCTAssertEqual(fresh.sessionID, "c2")
    XCTAssertNil(fresh.agentID)
  }

  func testAMissingWindowKeepsItsWarning() {
    let warned: Set<String> = [AgyUsage.alertKey(pool: "gemini", kind: .fiveHour, mark: 80)]
    let partial = AgyUsage.parse(Data(#"{"ts": 1, "meters": {"claude": {"weekly": 50}}}"#.utf8))!
    XCTAssertEqual(partial.liveWarnings(warned), warned)
  }
}

@MainActor
final class AgyStoreReviewFixTests: XCTestCase {
  func testAPidWhoseRowIsGoneStartsFresh() throws {
    // The liveness sweep can drop a row before its exit watch fires; a new agy that reuses the
    // pid must not be linked to the dead chat.
    let store = SessionStore(probe: ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil }))
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys006", pid: 4242)
    store.handleAgyEvent(Data(#"{"hookEventName":"PreInvocation","conversationId":"old","cwd":"/p"}"#.utf8), context: ctx, event: nil, snapshot: nil)
    store.removeSession("old")
    store.handleAgyEvent(Data(#"{"hookEventName":"SessionStart","conversationId":"new","cwd":"/p"}"#.utf8), context: ctx, event: nil, snapshot: nil)
    XCTAssertEqual(Array(store.sessions.keys), ["new"])
    XCTAssertNil(store.sessions["new"]?.activeAgents.first)
  }
}

/// Real agy 1.5.14 payloads (captured 2026-11-21 with a capture-only hook in a throwaway git dir,
/// paths and ids replaced): what the translator was written against.
final class AgyRealPayloadTests: XCTestCase {
  static let preInvocation = #"{"artifactDirectoryPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/artifactDirectoryPath", "conversationId": "conv-1", "cwd": "/Users/x/proj", "hookEventName": "PreInvocation", "initialNumSteps": 1, "invocationNum": 0, "lastUserInput": "read probe.txt, then write out.txt", "modelName": "gemini-3.8-flash-low", "transcriptPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/transcriptPath", "workspacePaths": ["/Users/x/proj"]}"#
  static let preToolUseWrite = #"{"artifactDirectoryPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/artifactDirectoryPath", "conversationId": "conv-1", "cwd": "/Users/x/proj", "hookEventName": "PreToolUse", "lastUserInput": "read probe.txt, then write out.txt", "modelName": "gemini-3.8-flash-low", "stepIdx": 6, "toolCall": {"args": {"Content": "ok", "Path": "/Users/x/proj/out.txt"}, "id": "call_14721999088354938201", "name": "write_file"}, "transcriptPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/transcriptPath", "workspacePaths": ["/Users/x/proj"]}"#
  static let stop = #"{"artifactDirectoryPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/artifactDirectoryPath", "continuationActive": false, "conversationId": "conv-1", "cwd": "/Users/x/proj", "error": "", "executionNum": 0, "fullyIdle": true, "hookEventName": "Stop", "lastUserInput": "read probe.txt, then write out.txt", "modelName": "gemini-3.8-flash-low", "terminationReason": "NO_TOOL_CALL", "transcriptPath": "/Users/x/.gemini/antigravity-cli/brain/conv-1/transcriptPath", "workspacePaths": ["/Users/x/proj"]}"#

  func testRealPayloadsTranslate() throws {
    var l = AgyLinker()
    let turn = try XCTUnwrap(AgyHookPayload.parse(Data(Self.preInvocation.utf8), fallbackEvent: nil))
    XCTAssertEqual(turn.invocationNum, 0)
    XCTAssertEqual(l.translate(turn, pid: 9)?.name, "UserPromptSubmit")

    let write = try XCTUnwrap(AgyHookPayload.parse(Data(Self.preToolUseWrite.utf8), fallbackEvent: nil))
    let e = try XCTUnwrap(l.translate(write, pid: 9))
    XCTAssertEqual(e.toolName, "Write")
    XCTAssertEqual(e.toolInput, .object(["file_path": .string("/Users/x/proj/out.txt")]))

    let stop = try XCTUnwrap(AgyHookPayload.parse(Data(Self.stop.utf8), fallbackEvent: nil))
    XCTAssertEqual(stop.fullyIdle, true)
    XCTAssertEqual(stop.terminationReason, "NO_TOOL_CALL")
    XCTAssertNil(stop.errorText)
    XCTAssertEqual(l.translate(stop, pid: 9)?.name, "Stop")
    // A real turn end closes the turn: the next new conversation is a new chat.
    let next = try XCTUnwrap(
      l.translate(AgyHookPayload(event: "SessionStart", conversationID: "conv-2", cwd: "/p"), pid: 9))
    XCTAssertNil(next.agentID)
  }
}

/// An agy row next to the store's claude-made machinery: the liveness sweep and the process scan.
@MainActor
final class AgySurvivalTests: XCTestCase {
  func testAnAgyRowSurvivesTheSweepAndTheProcessScan() throws {
    let store = SessionStore(probe: ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in "/dev/ttys006" }))
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys006", pid: 4242)
    store.handleAgyEvent(
      Data(#"{"hookEventName":"PreInvocation","conversationId":"c1","cwd":"/p","invocationNum":0}"#.utf8),
      context: ctx, event: nil, snapshot: nil)
    XCTAssertEqual(store.sweep(), [])
    // The scan sees the agy process (not a claude) and a claude in another tab.
    store.applyDiscovery([
      ProcessRecord(pid: 4242, ppid: 1, tty: "/dev/ttys006", path: "/x/agy", args: ["agy"],
        cwd: "/p", termProgram: "ghostty"),
      ProcessRecord(pid: 501, ppid: 1, tty: "/dev/ttys001", path: "/x/claude", args: ["claude"],
        cwd: "/q", termProgram: "ghostty"),
    ])
    XCTAssertEqual(store.sessions["c1"]?.tool, .agy)
    XCTAssertEqual(store.sessions["c1"]?.tty, "/dev/ttys006")
    // The claude in the other tab gets its placeholder; the agy tab gets none.
    XCTAssertEqual(store.sessions.values.filter(\.isDiscovered).map(\.tty), ["/dev/ttys001"])
    // The agy process dies: the sweep removes its row like a claude row's.
    let gone = SessionStore(probe: ProcessProbe(isAlive: { _ in false }, ttyOf: { _ in nil }))
    gone.handleAgyEvent(
      Data(#"{"hookEventName":"SessionStart","conversationId":"c1","cwd":"/p"}"#.utf8),
      context: ctx, event: nil, snapshot: nil)
    XCTAssertEqual(gone.sweep(), ["c1"])
  }
}
