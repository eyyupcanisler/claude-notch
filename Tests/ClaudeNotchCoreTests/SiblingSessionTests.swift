import Foundation
import XCTest

@testable import ClaudeNotchCore

@MainActor
final class SiblingSessionTests: XCTestCase {
  private func ev(_ name: String, _ sid: String) -> HookEvent {
    HookEvent(name: name, sessionID: sid, cwd: "/Users/x/proj")
  }

  private let alive = ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil })

  private func ctx(_ tty: String, _ pid: Int32) -> HookContext {
    HookContext(termProgram: "ghostty", tty: tty, pid: pid, branch: nil)
  }

  func testClearWithMissedSessionEndLeavesOneRow() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart", "old"), context: ctx("/dev/ttys001", 500))
    store.handleEvent(ev("Stop", "old"), context: ctx("/dev/ttys001", 500))
    // /clear: SessionEnd for "old" never arrived; the same process starts "new".
    store.handleEvent(ev("SessionStart", "new"), context: ctx("/dev/ttys001", 500))
    XCTAssertEqual(Set(store.sessions.keys), ["new"])
  }

  func testOtherProcessesKeepTheirSessions() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart", "a"), context: ctx("/dev/ttys001", 500))
    store.handleEvent(ev("SessionStart", "b"), context: ctx("/dev/ttys002", 600))
    store.handleEvent(ev("UserPromptSubmit", "b"), context: ctx("/dev/ttys002", 600))
    XCTAssertEqual(Set(store.sessions.keys), ["a", "b"])
  }
}
