import Foundation
import XCTest

@testable import ClaudeNotchCore

/// The "jump" shortcut's target: the session that needs the user most.
final class JumpTargetTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  private func session(
    _ id: String, _ status: SessionStatus, at offset: TimeInterval, unseen: Bool = false
  ) -> Session {
    Session(
      id: id, project: id, cwd: "/p/\(id)", termProgram: "ghostty", status: status,
      unseen: unseen, startedAt: t0, lastUpdate: t0.addingTimeInterval(offset),
      statusSince: t0.addingTimeInterval(offset))
  }

  private func pick(cards: [String] = [], _ sessions: [Session]) -> String? {
    JumpTarget.sessionID(permissionSessionIDs: cards, sessions: sessions)
  }

  func testNothingWaits() {
    XCTAssertNil(pick([]))
    XCTAssertNil(
      pick([
        session("w", .working(tool: "Bash"), at: 0), session("i", .idle, at: 1),
        session("d", .done("ok"), at: 2, unseen: false), session("e", .error("x"), at: 3),
        session("q", .quiet, at: 4),
      ]))
  }

  func testOldestPermissionComesFirst() {
    let all = [
      session("q", .question(text: "?", options: []), at: 0),
      session("e", .error("x"), at: 5, unseen: true),
    ]
    XCTAssertEqual(pick(cards: ["b", "a", "b"], all), "b")
  }

  func testOldestQuestionPlanOrInputWaitIsNext() {
    let all = [
      session("plan", .planApproval(nil), at: 20),
      session("ask", .question(text: "?", options: []), at: 30),
      session("input", .waitingInput("m"), at: 10),
      session("err", .error("x"), at: 40, unseen: true),
      session("done", .done("ok"), at: 50, unseen: true),
    ]
    XCTAssertEqual(pick(all), "input")
    XCTAssertEqual(pick(all.filter { $0.id != "input" }), "plan")
    XCTAssertEqual(pick(all.filter { $0.id != "input" && $0.id != "plan" }), "ask")
  }

  func testNewestUnseenErrorThenNewestUnseenDone() {
    let all = [
      session("e1", .error("x"), at: 10, unseen: true),
      session("e2", .error("y"), at: 20, unseen: true),
      session("e3", .error("seen"), at: 30, unseen: false),
      session("d1", .done("a"), at: 40, unseen: true),
      session("d2", .done("b"), at: 50, unseen: true),
      session("d3", .done("seen"), at: 60, unseen: false),
    ]
    XCTAssertEqual(pick(all), "e2")
    let noErrors = all.filter { !$0.id.hasPrefix("e") }
    XCTAssertEqual(pick(noErrors), "d2")
  }

  @MainActor
  func testStoreTargetFollowsEvents() {
    let clock = Clock()
    let store = SessionStore(now: { clock.t })
    func send(_ name: String, _ sid: String, tool: String? = nil) {
      store.handleEvent(
        HookEvent(name: name, sessionID: sid, cwd: "/p/\(sid)", toolName: tool),
        termProgram: "ghostty")
      clock.advance(1)
    }
    XCTAssertNil(store.jumpTarget)
    send("Stop", "done")
    XCTAssertEqual(store.jumpTarget, "done")
    send("PreToolUse", "ask", tool: "AskUserQuestion")
    XCTAssertEqual(store.jumpTarget, "ask")
    store.addPermission(
      HookEvent(name: "PermissionRequest", sessionID: "perm", cwd: "/p/perm", toolName: "Bash"),
      termProgram: "ghostty", reply: { _ in })
    XCTAssertEqual(store.jumpTarget, "perm")
    store.denyAll(sessionID: "perm")
    XCTAssertEqual(store.jumpTarget, "ask")
    send("PostToolUse", "ask", tool: "AskUserQuestion")
    XCTAssertEqual(store.jumpTarget, "done")
    store.markSeen(sessionID: "done")
    XCTAssertNil(store.jumpTarget)
  }
}

/// The one-click shortcut presets: the decision chords (Allow / Deny) must accept them.
final class ShortcutPresetTests: XCTestCase {
  func testPresetModifiers() {
    XCTAssertEqual(ShortcutPreset.standard.modifiers, [.control, .option])
    XCTAssertEqual(ShortcutPreset.hyper.modifiers, [.control, .option, .shift, .command])
    XCTAssertEqual(ShortcutPreset.standard.modifiers.symbols, "⌃⌥")
    XCTAssertEqual(ShortcutPreset.hyper.modifiers.symbols, "⌃⌥⇧⌘")
  }

  func testEveryPresetIsASafeDecisionChord() {
    for preset in ShortcutPreset.allCases {
      XCTAssertTrue(DecisionChord.isAllowed(preset.modifiers), preset.rawValue)
    }
  }

  func testDecisionChordRulesStillHold() {
    XCTAssertFalse(DecisionChord.isAllowed([.option]))
    XCTAssertFalse(DecisionChord.isAllowed([.option, .shift]))
    XCTAssertFalse(DecisionChord.isAllowed([.command]))
    XCTAssertFalse(DecisionChord.isAllowed([.command, .shift]))
    XCTAssertFalse(DecisionChord.isAllowed([.control]))
    XCTAssertTrue(DecisionChord.isAllowed([.command, .option]))
    XCTAssertTrue(DecisionChord.isAllowed([.control, .shift]))
    XCTAssertTrue(DecisionChord.isAllowed([.option, .shift, .command]))
  }
}
