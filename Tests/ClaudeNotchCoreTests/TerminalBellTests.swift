import Darwin
import Foundation
import XCTest

@testable import ClaudeNotchCore

@MainActor
final class TerminalBellTests: XCTestCase {
  func testFreshInstallNeverRings() {
    XCTAssertFalse(TerminalBell.fallback)
    XCTAssertFalse(TerminalBell.enabled(stored: nil))
    XCTAssertFalse(TerminalBell.enabled(stored: "yes"), "not a Bool: the fallback")
    XCTAssertTrue(TerminalBell.enabled(stored: true))
    XCTAssertFalse(TerminalBell.enabled(stored: false))
  }

  func testEveryNotificationRingsButALoginConfirmation() {
    for type in ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"] {
      XCTAssertTrue(TerminalBell.rings(notificationType: type), type)
    }
    XCTAssertTrue(TerminalBell.rings(notificationType: nil))
    XCTAssertFalse(TerminalBell.rings(notificationType: "auth_success"))
  }

  /// Silent mode lets only what needs an answer ring, as it does for islands and sounds.
  func testSilentModeRingsOnlyWhatNeedsAnAnswer() {
    for type in ["permission_prompt", "agent_needs_input", "elicitation_dialog"] {
      XCTAssertTrue(TerminalBell.ringsNow(notificationType: type, silentMode: true), type)
    }
    XCTAssertFalse(TerminalBell.ringsNow(notificationType: "idle_prompt", silentMode: true))
    XCTAssertFalse(TerminalBell.ringsNow(notificationType: nil, silentMode: true))
    XCTAssertTrue(TerminalBell.ringsNow(notificationType: "idle_prompt", silentMode: false))
    XCTAssertTrue(TerminalBell.ringsNow(notificationType: nil, silentMode: false))
    XCTAssertFalse(TerminalBell.ringsNow(notificationType: "auth_success", silentMode: false))
  }

  func testOnlyTerminalDevicePathsAreWritten() {
    for ok in ["/dev/ttys012", "/dev/ttys0", "/dev/ttys12345"] {
      XCTAssertTrue(TerminalBell.isTerminalPath(ok), ok)
    }
    for bad in [
      "/dev/tty", "/dev/ttys", "/dev/ttys01a", "/dev/tty.usbserial", "/dev/null", "ttys012",
      "/dev/ttys012/../../etc/hosts", "/tmp/dev/ttys012", "/dev/ttys٣", "", "/dev/tty1",
      "/dev/ttyp3", "/dev/ttys123456", "/dev/ttys012\n",
    ] {
      XCTAssertFalse(TerminalBell.isTerminalPath(bad), bad)
      XCTAssertFalse(TerminalBell.ring(tty: bad), bad)
    }
  }

  /// A real pseudo terminal: the bell written to its device path arrives as one BEL.
  func testRingWritesOneBellToTheTerminal() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var name = [CChar](repeating: 0, count: 128)
    guard openpty(&master, &slave, &name, nil, nil) == 0 else {
      throw XCTSkip("no pseudo terminal available")
    }
    defer {
      close(master)
      close(slave)
    }
    let path = String(cString: name)
    XCTAssertTrue(TerminalBell.isTerminalPath(path), path)
    XCTAssertTrue(TerminalBell.ring(tty: path))
    var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
    XCTAssertEqual(poll(&poller, 1, 1000), 1, "the bell reaches the terminal")
    var buffer = [UInt8](repeating: 0, count: 8)
    let count = read(master, &buffer, buffer.count)
    XCTAssertEqual(Array(buffer.prefix(max(0, count))), [0x07])
  }

  func testNotificationEventsAskForTheBell() {
    let store = SessionStore(now: { Date(timeIntervalSince1970: 1_000_000) })
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    func ev(_ name: String, ntype: String? = nil) -> HookEvent {
      HookEvent(
        name: name, sessionID: "s1", cwd: "/Users/x/proj", toolName: nil, toolInput: nil,
        message: "Claude needs your permission", notificationType: ntype,
        lastAssistantMessage: nil)
    }
    store.handleEvent(ev("SessionStart"), termProgram: "ghostty")
    store.handleEvent(ev("UserPromptSubmit"), termProgram: nil)
    store.handleEvent(ev("Stop"), termProgram: nil)
    func bells() -> [StoreEffect] {
      effects.filter { if case .bell = $0 { return true } else { return false } }
    }
    XCTAssertEqual(bells(), [], "only Notification events ring")
    store.handleEvent(ev("Notification", ntype: "auth_success"), termProgram: nil)
    XCTAssertEqual(bells(), [])
    store.handleEvent(ev("Notification", ntype: "idle_prompt"), termProgram: nil)
    XCTAssertEqual(bells(), [.bell(sessionID: "s1", notificationType: "idle_prompt")])
    store.handleEvent(ev("Notification", ntype: "permission_prompt"), termProgram: nil)
    XCTAssertEqual(bells().last, .bell(sessionID: "s1", notificationType: "permission_prompt"))
    XCTAssertEqual(bells().count, 2)
  }

  /// The controller rings the tty it reads from the store when the effect arrives, so the
  /// effect must go out after the event (and the tty in its header) is stored.
  func testBellGoesOutAfterTheSessionAndItsTTYAreStored() {
    let store = SessionStore(now: { Date(timeIntervalSince1970: 1_000_000) })
    var ttyAtBell: String??
    store.onEffect = { [store] effect in
      if case .bell(let id, _) = effect { ttyAtBell = .some(store.sessions[id]?.tty) }
    }
    let notification = HookEvent(
      name: "Notification", sessionID: "fresh", cwd: "/Users/x/proj", toolName: nil,
      toolInput: nil, message: "Claude needs your permission",
      notificationType: "permission_prompt", lastAssistantMessage: nil)
    store.handleEvent(
      notification, context: HookContext(termProgram: "ghostty", tty: "/dev/ttys042", pid: 4242))
    XCTAssertEqual(ttyAtBell, .some("/dev/ttys042"), "a session first seen in this event")
  }
}
