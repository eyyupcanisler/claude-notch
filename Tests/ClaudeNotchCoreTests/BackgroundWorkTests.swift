import Foundation
import XCTest

@testable import ClaudeNotchCore

@MainActor
final class BackgroundWorkTests: XCTestCase {
  /// A clock the test moves forward.
  private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
  }

  private func ev(
    _ name: String, ntype: String? = nil, background: [BackgroundTask] = [],
    agentID: String? = nil, tool: String? = nil
  ) -> HookEvent {
    HookEvent(
      name: name, sessionID: "s1", cwd: "/Users/x/proj", toolName: tool,
      message: "Claude is waiting for your input", notificationType: ntype,
      lastAssistantMessage: "Running the review workflow in the background.", agentID: agentID,
      backgroundTasks: background)
  }

  private let workflow = BackgroundTask(
    type: "workflow", name: "review-changes", description: "Review changed files")

  func testStopPayloadListsItsBackgroundTasks() throws {
    let json = """
      {"hook_event_name":"Stop","session_id":"s1","cwd":"/p","stop_hook_active":false,
       "background_tasks":[
         {"id":"w1","type":"workflow","status":"running","description":"Review","name":"review-changes"},
         {"id":"b2","type":"shell","status":"running","description":"npm run dev","command":"npm run dev"},
         {"id":"x","status":"running","description":"no type"}],
       "session_crons":[]}
      """
    let e = try XCTUnwrap(HookEvent.parse(Data(json.utf8)))
    XCTAssertEqual(
      e.backgroundTasks,
      [
        BackgroundTask(type: "workflow", name: "review-changes", description: "Review"),
        BackgroundTask(type: "shell", description: "npm run dev"),
      ])
    let old = try XCTUnwrap(
      HookEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)))
    XCTAssertEqual(old.backgroundTasks, [], "older Claude Code sends no list")
  }

  /// Workflows and background agents keep the turn going; a shell or monitor can run for good.
  func testOnlyWorkThatWakesTheSessionKeepsItGoing() {
    let shell = BackgroundTask(type: "shell", description: "npm run dev")
    let monitor = BackgroundTask(type: "monitor", description: "tail -f log")
    let agent = BackgroundTask(type: "subagent", description: "Audit the parser")
    XCTAssertEqual(BackgroundWork.continuing([shell, monitor]), [])
    XCTAssertEqual(BackgroundWork.continuing([shell, workflow, agent]), [workflow, agent])
    XCTAssertEqual(BackgroundWork.summary([workflow]), "In the background: review-changes")
    XCTAssertEqual(BackgroundWork.summary([agent]), "In the background: Audit the parser")
    XCTAssertEqual(
      BackgroundWork.summary([BackgroundTask(type: "subagent", description: " \n ")]),
      "In the background: subagent")
    XCTAssertEqual(BackgroundWork.summary([workflow, agent]), "In the background: 2 tasks")
    XCTAssertEqual(
      BackgroundWork.summary([BackgroundTask(type: "subagent", description: "a\nb")]),
      "In the background: a b", "one line")
  }

  /// The main chat stops while its workflow runs: no "done" (wing, chime, done bar), and the real
  /// end comes with the Stop after the workflow woke the session.
  func testAStopThatLeavesAWorkflowRunningIsNotDone() {
    let store = SessionStore(now: { Date(timeIntervalSince1970: 1_000_000) })
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    store.handleEvent(ev("UserPromptSubmit"), termProgram: "ghostty")
    store.handleEvent(ev("Stop", background: [workflow]), termProgram: nil)
    let s = store.sessions["s1"]
    XCTAssertEqual(s?.status, .working(tool: "In the background: review-changes"))
    XCTAssertEqual(s?.waitsForBackground, true)
    XCTAssertEqual(s?.unseen, false)
    XCTAssertFalse(effects.contains(.attention(sessionID: "s1", kind: "done")))
    XCTAssertFalse(effects.contains(.sound("Glass")))
    // The workflow's own agents keep working in the session.
    store.handleEvent(ev("PreToolUse", agentID: "a1", tool: "Read"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status.isWorking, true)
    // The workflow is back: Claude Code wakes the session, which ends its turn for real.
    store.handleEvent(ev("Stop"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status.kind, "done")
    XCTAssertEqual(store.sessions["s1"]?.waitsForBackground, false)
    XCTAssertEqual(store.sessions["s1"]?.unseen, true)
    XCTAssertEqual(effects.filter { $0 == .attention(sessionID: "s1", kind: "done") }.count, 1)
  }

  func testAStopWithOnlyAServerRunningIsDoneAsBefore() {
    let store = SessionStore(now: { Date(timeIntervalSince1970: 1_000_000) })
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    store.handleEvent(ev("UserPromptSubmit"), termProgram: "ghostty")
    let server = BackgroundTask(type: "shell", description: "npm run dev")
    store.handleEvent(ev("Stop", background: [server]), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.status.kind, "done")
    XCTAssertTrue(effects.contains(.attention(sessionID: "s1", kind: "done")))
  }

  /// While the workflow runs, Claude Code's idle notice neither marks the session as needing
  /// you, nor rings its bell, nor drops a workflow agent's permission card.
  func testIdleNoticeWhileAWorkflowRunsIsIgnored() {
    let clock = Clock()
    let store = SessionStore(now: { clock.now })
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    store.handleEvent(ev("UserPromptSubmit"), termProgram: "ghostty")
    store.handleEvent(ev("Stop", background: [workflow]), termProgram: nil)
    let ask = HookEvent(
      name: "PermissionRequest", sessionID: "s1", cwd: "/Users/x/proj", toolName: "Bash",
      toolInput: .object(["command": .string("swift test")]), agentID: "a1")
    store.addPermission(ask, termProgram: nil) { _ in }
    clock.now += 120
    effects = []
    store.handleEvent(ev("Notification", ntype: "idle_prompt"), termProgram: nil)
    XCTAssertTrue(store.sessions["s1"]?.status.isWorking == true)
    XCTAssertEqual(store.pending.count, 1, "the workflow agent's request still waits")
    XCTAssertEqual(effects.filter { if case .bell = $0 { true } else { false } }, [])
    XCTAssertFalse(effects.contains(.attention(sessionID: "s1", kind: "waiting")))
    // A request for an answer still rings and shows.
    store.handleEvent(ev("Notification", ntype: "permission_prompt"), termProgram: nil)
    XCTAssertEqual(
      effects.filter { if case .bell = $0 { true } else { false } },
      [.bell(sessionID: "s1", notificationType: "permission_prompt")])
  }

  func testAWorkflowThatRunsLongIsNotQuiet() {
    let clock = Clock()
    let store = SessionStore(now: { clock.now })
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    store.handleEvent(ev("UserPromptSubmit"), termProgram: "ghostty")
    store.handleEvent(ev("Stop", background: [workflow]), termProgram: nil)
    clock.now += SessionStore.quietAfter + 60
    store.sweep()
    XCTAssertFalse(effects.contains(.attention(sessionID: "s1", kind: "quiet")))
    XCTAssertEqual(store.sessions["s1"]?.status.isWorking, true)
    // A new prompt ends the wait: a turn that then goes silent is quiet again.
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    XCTAssertEqual(store.sessions["s1"]?.waitsForBackground, false)
    clock.now += SessionStore.quietAfter + 60
    store.sweep()
    XCTAssertTrue(effects.contains(.attention(sessionID: "s1", kind: "quiet")))
  }
}
