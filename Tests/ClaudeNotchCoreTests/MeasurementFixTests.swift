import Darwin
import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Records exit watches so a test can fire them.
final class FakeExitWatches: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [Int32: @Sendable () -> Void] = [:]
  private(set) var cancelled: [Int32] = []

  func watch(_ pid: Int32, _ handler: @escaping @Sendable () -> Void) -> ExitWatch? {
    lock.lock()
    handlers[pid] = handler
    lock.unlock()
    return ExitWatch { [self] in
      lock.lock()
      cancelled.append(pid)
      handlers.removeValue(forKey: pid)
      lock.unlock()
    }
  }

  func fire(_ pid: Int32) {
    lock.lock()
    let h = handlers[pid]
    lock.unlock()
    h?()
  }

  var watched: Set<Int32> {
    lock.lock()
    defer { lock.unlock() }
    return Set(handlers.keys)
  }
}

/// Fixes from the live measurement (M1, M9, S1b, S1c).
@MainActor
final class MeasurementFixTests: XCTestCase {
  private func ev(_ name: String, sid: String) -> HookEvent {
    HookEvent(name: name, sessionID: sid, cwd: "/Users/x/\(sid)", toolName: nil, toolInput: nil,
      message: nil, notificationType: nil, agentID: nil)
  }

  private func ctx(_ tty: String, _ pid: Int32) -> HookContext {
    HookContext(termProgram: "ghostty", tty: tty, pid: pid, branch: nil)
  }

  // MARK: M1: arm delay above the double-click interval

  func testRemovalArmDelayExceedsDoubleClickInterval() {
    XCTAssertEqual(SessionStore.removalArmDelay(doubleClickInterval: 0.2), 0.45)
    XCTAssertEqual(SessionStore.removalArmDelay(doubleClickInterval: 0.5), 0.6, accuracy: 1e-9)
    XCTAssertEqual(SessionStore.removalArmDelay(doubleClickInterval: 2), 2.1, accuracy: 1e-9)
  }

  func testIsArmedUsesInstanceRemovalDelay() {
    let clock = Clock()
    let store = SessionStore(now: { clock.t })
    store.removalArmDelay = SessionStore.removalArmDelay(doubleClickInterval: 0.5)
    let log = ReplyLog()
    func bash(_ cmd: String) -> HookEvent {
      HookEvent(name: "PermissionRequest", sessionID: "s", cwd: "/p", toolName: "Bash",
        toolInput: .object(["command": .string(cmd)]), message: nil, notificationType: nil,
        agentID: nil)
    }
    let a = store.addPermission(bash("echo a"), termProgram: nil) { log.add($0) }
    let b = store.addPermission(bash("echo b"), termProgram: nil) { log.add($0) }
    clock.advance(SessionStore.armDelayNew + 0.01)
    XCTAssertTrue(store.decide(id: a.id, decision: .allow))
    // A second click 0.55 s later (inside a 0.5 s double-click + slack) must not land on b.
    clock.advance(0.55)
    XCTAssertFalse(store.isArmed(b))
    XCTAssertEqual(
      store.armedAt(b).timeIntervalSince(clock.t), 0.05, accuracy: 1e-6)
    clock.advance(0.06)
    XCTAssertTrue(store.isArmed(b))
  }

  // MARK: M1: frozen order swap when the card slot changes session

  func testSwapFrozenKeepsOtherRowsInPlace() {
    let frozen = ["alpha", "beta", "gamma", "delta"]
    let swapped = SessionStore.swapFrozen(frozen, "alpha", "gamma")
    XCTAssertEqual(swapped, ["gamma", "beta", "alpha", "delta"])
    // The list shows every session but the slot one: beta keeps index 0, delta index 2.
    let before = frozen.filter { $0 != "alpha" }
    let after = swapped.filter { $0 != "gamma" }
    XCTAssertEqual(before.firstIndex(of: "beta"), after.firstIndex(of: "beta"))
    XCTAssertEqual(before.firstIndex(of: "delta"), after.firstIndex(of: "delta"))
    // gamma's old place is now alpha's.
    XCTAssertEqual(after[before.firstIndex(of: "gamma") ?? -1], "alpha")
  }

  func testSwapFrozenNoOpCases() {
    let frozen = ["a", "b"]
    XCTAssertEqual(SessionStore.swapFrozen(frozen, "a", "a"), frozen)
    XCTAssertEqual(SessionStore.swapFrozen(frozen, "a", "zzz"), frozen)
    XCTAssertEqual(SessionStore.swapFrozen(frozen, "zzz", "b"), frozen)
  }

  // MARK: S1b / S1c: decision keys need a fresh press

  func testAutoRepeatNeverDecides() {
    var gate = DecisionKeyGate()
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    // Holding ⌘⏎: every auto-repeat is dropped.
    for _ in 0..<20 { XCTAssertFalse(gate.keyDown(keyCode: 36, command: true, isRepeat: true)) }
    gate.keyUp(keyCode: 36)
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
  }

  func testDecisionLatchesUntilKeyUp() {
    var gate = DecisionKeyGate()
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    // A key-down without a key-up in between (missed up / synthetic) does not decide again.
    XCTAssertFalse(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    XCTAssertFalse(gate.keyDown(keyCode: 51, command: true, isRepeat: false))
    // Releasing another key does not unlatch.
    gate.keyUp(keyCode: 51)
    XCTAssertFalse(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    // Enter (76) belongs to the Return group.
    gate.keyUp(keyCode: 76)
    XCTAssertTrue(gate.keyDown(keyCode: 51, command: true, isRepeat: false))
    gate.keyUp(keyCode: 117)
    XCTAssertNil(gate.latchedKey)
  }

  func testReleasingCommandClearsLatch() {
    var gate = DecisionKeyGate()
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    gate.modifiersChanged(command: true)
    XCTAssertFalse(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
    // The Return key-up was lost, but ⌘ came up: the next chord is a fresh press.
    gate.modifiersChanged(command: false)
    XCTAssertNil(gate.latchedKey)
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: true, isRepeat: false))
  }

  func testNonDecisionKeys() {
    var gate = DecisionKeyGate()
    // Arrows repeat freely and never latch.
    XCTAssertTrue(gate.keyDown(keyCode: 124, command: false, isRepeat: true))
    XCTAssertNil(gate.latchedKey)
    // Space and plain Return act on fresh presses only.
    XCTAssertTrue(gate.keyDown(keyCode: 49, command: false, isRepeat: false))
    XCTAssertFalse(gate.keyDown(keyCode: 49, command: false, isRepeat: true))
    XCTAssertTrue(gate.keyDown(keyCode: 36, command: false, isRepeat: false))
    XCTAssertFalse(gate.keyDown(keyCode: 36, command: false, isRepeat: true))
    XCTAssertNil(gate.latchedKey)
    // ⌘⇧⏎ is a decision key too.
    XCTAssertTrue(DecisionKeyGate.isDecision(keyCode: 36, command: true))
    XCTAssertFalse(DecisionKeyGate.isDecision(keyCode: 36, command: false))
    var g2 = DecisionKeyGate()
    XCTAssertTrue(g2.keyDown(keyCode: 36, command: true, isRepeat: false))
    g2.reset()
    XCTAssertTrue(g2.keyDown(keyCode: 36, command: true, isRepeat: false))
  }

  // MARK: M9: exit watch and zombies

  func testExitWatchRemovesSessionAtOnce() async {
    let watches = FakeExitWatches()
    let procs = FakeProcesses()
    let probe = ProcessProbe(
      isAlive: procs.probe.isAlive, ttyOf: procs.probe.ttyOf,
      watchExit: { watches.watch($0, $1) })
    let store = SessionStore(probe: probe)
    procs.set(4242, tty: "/dev/ttys004")
    store.handleEvent(ev("UserPromptSubmit", sid: "s1"), context: ctx("/dev/ttys004", 4242))
    procs.set(4343, tty: "/dev/ttys005")
    store.handleEvent(ev("UserPromptSubmit", sid: "s2"), context: ctx("/dev/ttys005", 4343))
    XCTAssertEqual(watches.watched, [4242, 4343])
    // Same pid again: no new watch.
    store.handleEvent(ev("PreToolUse", sid: "s1"), context: ctx("/dev/ttys004", 4242))
    XCTAssertTrue(watches.cancelled.isEmpty)

    let log = ReplyLog()
    let perm = HookEvent(name: "PermissionRequest", sessionID: "s1", cwd: "/Users/x/s1",
      toolName: "Bash", toolInput: .object(["command": .string("ls")]), message: nil,
      notificationType: nil, agentID: nil)
    store.addPermission(perm, context: ctx("/dev/ttys004", 4242)) { log.add($0) }

    procs.kill(4242)
    watches.fire(4242)
    await Task.yield()
    for _ in 0..<20 where store.sessions["s1"] != nil { await Task.yield() }
    XCTAssertNil(store.sessions["s1"])
    XCTAssertNotNil(store.sessions["s2"])
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertEqual(log.all.count, 1)
    XCTAssertNil(log.all.first ?? Data())
  }

  func testExitOfOldPidDoesNotRemoveRebound() {
    let watches = FakeExitWatches()
    let probe = ProcessProbe(
      isAlive: { _ in true }, ttyOf: { _ in nil }, watchExit: { watches.watch($0, $1) })
    let store = SessionStore(probe: probe)
    store.handleEvent(ev("UserPromptSubmit", sid: "s1"), context: ctx("/dev/ttys004", 100))
    store.handleEvent(ev("UserPromptSubmit", sid: "s1"), context: ctx("/dev/ttys006", 200))
    XCTAssertEqual(watches.cancelled, [100])
    store.processExited(sessionID: "s1", pid: 100)
    XCTAssertNotNil(store.sessions["s1"])
    store.removeSession("s1")
    XCTAssertEqual(watches.cancelled, [100, 200])
  }

  /// A real child killed with SIGKILL and not reaped is a zombie: the system probe calls it dead
  /// (kill(pid, 0) still succeeds for it) and the exit watch fires.
  func testSystemProbeTreatsZombieAsDead() throws {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
    defer { argv.forEach { free($0) } }
    guard posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0 else {
      throw XCTSkip("posix_spawn failed")
    }
    defer {
      var status: Int32 = 0
      kill(pid, SIGKILL)
      waitpid(pid, &status, 0)
    }
    XCTAssertTrue(ProcessProbe.system.isAlive(pid))
    let fired = expectation(description: "exit watch")
    let watch = ProcessProbe.system.watchExit(pid) { fired.fulfill() }
    XCTAssertNotNil(watch)
    kill(pid, SIGKILL)
    wait(for: [fired], timeout: 3)
    // Not reaped yet: a zombie.
    XCTAssertEqual(kill(pid, 0), 0)
    XCTAssertEqual(ProcessProbe.isZombie(pid), true)
    XCTAssertFalse(ProcessProbe.system.isAlive(pid))
    XCTAssertFalse(ProcessProbe.system.owns(pid: pid, tty: "/dev/ttys001"))
    _ = watch
  }
}
