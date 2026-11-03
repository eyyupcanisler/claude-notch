import Foundation
import XCTest

@testable import ClaudeNotchCore

@MainActor
final class TurnToolCountTests: XCTestCase {
  private func ev(_ name: String, tool: String? = nil) -> HookEvent {
    HookEvent(name: name, sessionID: "s", cwd: "/p/s", toolName: tool)
  }

  func testCountsToolCallsPerTurn() {
    let store = SessionStore(now: { Date(timeIntervalSince1970: 1000) })
    store.handleEvent(ev("SessionStart"), termProgram: nil)
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    for tool in ["Read", "Edit", "Bash"] {
      store.handleEvent(ev("PreToolUse", tool: tool), termProgram: nil)
      store.handleEvent(ev("PostToolUse", tool: tool), termProgram: nil)
    }
    XCTAssertEqual(store.sessions["s"]?.turnToolCount, 3)
    store.handleEvent(ev("Stop"), termProgram: nil)
    XCTAssertEqual(store.sessions["s"]?.turnToolCount, 3, "a finished turn keeps its count")
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    XCTAssertEqual(store.sessions["s"]?.turnToolCount, 0, "a new turn starts from zero")
  }
}
