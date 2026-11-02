import Foundation
import XCTest

@testable import ClaudeNotchCore

/// v4: global approve / deny shortcuts, the peek lifecycle, process discovery, tab titles.
@MainActor
final class V4Tests: XCTestCase {
  var clock = Clock()
  var procs = FakeProcesses()
  var store: SessionStore!

  override func setUp() async throws {
    clock = Clock()
    procs = FakeProcesses()
    let c = clock
    store = SessionStore(now: { c.t }, probe: procs.probe)
  }

  // MARK: - P1 shortcut policy

  private func shown(
    _ id: String = "c1", peek: Bool = true, armed: Bool = true, risky: Bool = false,
    visible: Bool = true, opened: Bool = false
  ) -> ShownRequest {
    ShownRequest(
      cardID: id, inPeek: peek, armed: armed, risky: risky, fullyVisible: visible,
      opened: opened)
  }

  private func act(
    _ key: ShortcutKey, _ s: ShownRequest?, phase: ShortcutPhase = .down,
    oldest: String? = "c0", holding: String? = nil
  ) -> ShortcutAction {
    GlobalShortcutPolicy.action(
      key: key, phase: phase, shown: s, oldestPending: oldest, holding: holding)
  }

  func testNothingShownOnlyReveals() {
    XCTAssertEqual(act(.allow, nil), .reveal("c0"))
    XCTAssertEqual(act(.deny, nil), .reveal("c0"))
    XCTAssertEqual(act(.allow, nil, oldest: nil), .ignore)
  }

  func testActsOnlyOnTheShownArmedRequest() {
    XCTAssertEqual(act(.allow, shown()), .allow("c1"))
    XCTAssertEqual(act(.deny, shown()), .deny("c1"))
    XCTAssertEqual(act(.allow, shown(armed: false)), .ignore)
    XCTAssertEqual(act(.deny, shown(armed: false)), .ignore)
  }

  func testTruncatedAllowOpensFullViewDenyStillDenies() {
    XCTAssertEqual(act(.allow, shown(visible: false)), .openFull("c1"))
    XCTAssertEqual(act(.allow, shown(peek: false, visible: false)), .openFull("c1"))
    XCTAssertEqual(act(.allow, shown(peek: false, visible: false, opened: true)), .pageDown("c1"))
    XCTAssertEqual(act(.deny, shown(visible: false)), .deny("c1"))
  }

  func testRiskyNeedsHold() {
    XCTAssertEqual(act(.allow, shown(risky: true)), .holdStart("c1"))
    XCTAssertEqual(act(.allow, shown(risky: true), phase: .up, holding: "c1"), .holdCancel("c1"))
    XCTAssertEqual(act(.allow, shown(risky: true), phase: .up), .ignore)
    XCTAssertEqual(act(.deny, shown(), phase: .up, holding: "c1"), .ignore)
    // Deny needs no hold.
    XCTAssertEqual(act(.deny, shown(risky: true)), .deny("c1"))
    // A risky request that is not fully visible opens first.
    XCTAssertEqual(act(.allow, shown(risky: true, visible: false)), .openFull("c1"))
  }

  func testLatchDropsRepeatsAndRecoversALostRelease() {
    var latch = GlobalKeyLatch()
    let t = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(latch.pressed(at: t))
    // Auto-repeat: Pressed events while down.
    XCTAssertFalse(latch.pressed(at: t.addingTimeInterval(0.5)))
    XCTAssertFalse(latch.pressed(at: t.addingTimeInterval(0.6)))
    // Held for a long time: repeats keep the latch closed.
    for i in 1...40 {
      XCTAssertFalse(latch.pressed(at: t.addingTimeInterval(0.6 + Double(i) * 0.1)))
    }
    XCTAssertTrue(latch.released())
    XCTAssertFalse(latch.released())
    XCTAssertTrue(latch.pressed(at: t.addingTimeInterval(10)))
    // Released never came: a press long after the last Pressed is a new press.
    XCTAssertTrue(latch.pressed(at: t.addingTimeInterval(10 + GlobalKeyLatch.lostReleaseAfter)))
  }

  // MARK: - P2 peek lifecycle

  func testPermissionPeekDurationSetting() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var p = PeekPlanner(permissionHold: 15)
    p.receive(attention: "permission", sessionID: "a", cardID: "c1", at: t0)
    XCTAssertFalse(p.expire(at: t0.addingTimeInterval(14.9)))
    XCTAssertTrue(p.expire(at: t0.addingTimeInterval(15)))
    // "Yanıtlanana kadar": never expires on its own.
    p.permissionHold = nil
    p.receive(attention: "permission", sessionID: "a", cardID: "c1", at: t0)
    XCTAssertFalse(p.expire(at: t0.addingTimeInterval(100_000)))
    XCTAssertEqual(p.current?.until, .distantFuture)
    // Re-shown for an older card (reveal / next card after a decision).
    p.permissionHold = 8
    p.show(cardID: "c0", sessionID: "b", at: t0)
    XCTAssertEqual(p.current?.cardID, "c0")
    XCTAssertEqual(p.current?.kind, .permission)
    XCTAssertEqual(p.current?.until, t0.addingTimeInterval(8))
    // Other kinds keep their own times.
    var q = PeekPlanner(permissionHold: nil)
    q.receive(attention: "done", sessionID: "a", at: t0)
    XCTAssertTrue(q.expire(at: t0.addingTimeInterval(PeekPlanner.finishedDuration)))
  }

  // MARK: - P4 discovery

  private func rec(
    _ pid: Int32, ppid: Int32 = 500, tty: String? = "/dev/ttys004", arg0: String = "claude",
    path: String = "/Users/x/.local/share/claude/versions/2.1.316", cwd: String = "/Users/x/api",
    term: String? = "ghostty"
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: ppid, tty: tty, path: path, args: [arg0], cwd: cwd, termProgram: term)
  }

  private let shell = ProcessRecord(
    pid: 500, ppid: 1, tty: "/dev/ttys004", path: "/bin/zsh", args: ["-zsh"])

  func testWhichProcessesQualify() {
    XCTAssertTrue(ClaudeProcess.isClaude(rec(10)))
    XCTAssertTrue(ClaudeProcess.isClaude(rec(10, arg0: "/usr/local/bin/claude", path: "/x/y")))
    XCTAssertTrue(ClaudeProcess.isClaude(ProcessRecord(
      pid: 11, ppid: 1, path: "/opt/homebrew/bin/node",
      args: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])))
    XCTAssertFalse(ClaudeProcess.isClaude(ProcessRecord(
      pid: 12, ppid: 1, path: "/opt/homebrew/bin/node", args: ["node", "server.js"])))
    XCTAssertFalse(ClaudeProcess.isClaude(ProcessRecord(
      pid: 13, ppid: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude",
      args: ["/Applications/Claude.app/Contents/MacOS/Claude"])))
    // No tty, or a claude started by another claude (e.g. from its Bash tool): not a session.
    let records = [
      shell, rec(20), rec(21, tty: nil), rec(22, ppid: 23, tty: "/dev/ttys009"),
      ProcessRecord(pid: 23, ppid: 20, tty: "/dev/ttys009", path: "/bin/bash", args: ["bash"])
    ]
    XCTAssertEqual(ClaudeProcess.sessions(in: records).map(\.pid), [20])
    // Started in its own terminal by a program (a pty harness, an editor): its parent is that
    // program, not claude, so it is a session of its own.
    let viaProgram = [
      shell, rec(20), rec(40, ppid: 41, tty: "/dev/ttys011"),
      ProcessRecord(pid: 41, ppid: 23, path: "/usr/bin/python3", args: ["python3"]),
      ProcessRecord(pid: 23, ppid: 20, tty: "/dev/ttys004", path: "/bin/zsh", args: ["zsh"])
    ]
    XCTAssertEqual(ClaudeProcess.sessions(in: viaProgram).map(\.pid), [20, 40])
  }

  func testDiscoveredSessionIsIdleAndRemovedWithItsProcess() {
    procs.set(20, tty: "/dev/ttys004")
    store.applyDiscovery([shell, rec(20)])
    let s = store.sessions["found:20"]
    XCTAssertEqual(s?.project, "api")
    XCTAssertEqual(s?.status, .idle)
    XCTAssertEqual(s?.status.label, "Boşta")
    XCTAssertEqual(s?.isDiscovered, true)
    XCTAssertEqual(s?.tty, "/dev/ttys004")
    XCTAssertEqual(s?.pid, 20)
    XCTAssertEqual(s?.termProgram, "ghostty")
    // A second scan does not duplicate it.
    store.applyDiscovery([shell, rec(20)])
    XCTAssertEqual(store.sessions.count, 1)
    // Gone from the scan: gone from the list; dead per liveness: swept.
    store.applyDiscovery([shell])
    XCTAssertTrue(store.sessions.isEmpty)
    store.applyDiscovery([shell, rec(20)])
    procs.kill(20)
    store.sweep()
    XCTAssertTrue(store.sessions.isEmpty)
  }

  func testHookEventMergesIntoHookSession() {
    procs.set(20, tty: "/dev/ttys004")
    store.applyDiscovery([shell, rec(20)])
    let placeholderStart = store.sessions["found:20"]?.startedAt
    clock.advance(30)
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys004", pid: 20)
    store.handleEvent(
      HookEvent(name: "UserPromptSubmit", sessionID: "real-1", cwd: "/Users/x/api"), context: ctx)
    XCTAssertEqual(Array(store.sessions.keys), ["real-1"])
    XCTAssertEqual(store.sessions["real-1"]?.isDiscovered, false)
    XCTAssertEqual(store.sessions["real-1"]?.status.kind, "working")
    // Keeps the placeholder's place in the status line.
    XCTAssertEqual(store.sessions["real-1"]?.startedAt, placeholderStart)
    XCTAssertEqual(store.statusLine.count, 1)
    // Later scans see the tty owned by the hook session: no placeholder comes back.
    store.applyDiscovery([shell, rec(20)])
    XCTAssertEqual(Array(store.sessions.keys), ["real-1"])
  }

  func testPermissionRequestAlsoMerges() {
    procs.set(20, tty: "/dev/ttys004")
    store.applyDiscovery([shell, rec(20)])
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys004", pid: 20)
    let e = HookEvent(
      name: "PermissionRequest", sessionID: "real-2", cwd: "/Users/x/api", toolName: "Bash",
      toolInput: .object(["command": .string("ls")]))
    store.addPermission(e, context: ctx) { _ in }
    XCTAssertEqual(Array(store.sessions.keys), ["real-2"])
    XCTAssertEqual(store.pending.count, 1)
  }

  func testOwnedTTYIsNotDiscoveredAndEndedSessionIsNotReAdded() {
    procs.set(20, tty: "/dev/ttys004")
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys004", pid: 20)
    store.handleEvent(
      HookEvent(name: "SessionStart", sessionID: "real-3", cwd: "/Users/x/api"), context: ctx)
    store.applyDiscovery([shell, rec(20), rec(30, tty: "/dev/ttys007", cwd: "/Users/x/web")])
    XCTAssertEqual(Set(store.sessions.keys), ["real-3", "found:30"])
    // /clear: SessionEnd then a new SessionStart from the same process.
    store.handleEvent(
      HookEvent(name: "SessionEnd", sessionID: "real-3", cwd: "/Users/x/api"), context: ctx)
    store.applyDiscovery([shell, rec(20), rec(30, tty: "/dev/ttys007", cwd: "/Users/x/web")])
    XCTAssertNil(store.sessions["found:20"])
    clock.advance(SessionStore.endedGrace + 1)
    store.applyDiscovery([shell, rec(20), rec(30, tty: "/dev/ttys007", cwd: "/Users/x/web")])
    XCTAssertNotNil(store.sessions["found:20"])
  }

  func testSystemListerSeesThisProcess() {
    let records = ProcessLister.system.list()
    let me = ProcessInfo.processInfo.processIdentifier
    XCTAssertTrue(records.contains { $0.pid == me })
    XCTAssertGreaterThan(records.count, 10)
  }

  // MARK: - P5 tab titles

  func testTabTitleCleaning() {
    XCTAssertEqual(TabTitle.clean("✳ Fix login bug"), "Fix login bug")
    XCTAssertEqual(TabTitle.clean("⠂ Fix login bug"), "Fix login bug")
    XCTAssertEqual(TabTitle.clean("◐ Kod üretimi"), "Kod üretimi")
    XCTAssertEqual(TabTitle.clean("a\u{202E}b\u{200B}c\u{7}d"), "abcd")
    XCTAssertEqual(TabTitle.clean("  a \t\n b  "), "a b")
    XCTAssertNil(TabTitle.clean("✳ \u{202E}"))
    let long = TabTitle.clean(String(repeating: "x", count: 100) + "END")
    XCTAssertEqual(long?.count, TabTitle.maxLength)
    XCTAssertEqual(long?.hasSuffix("END"), true)
    XCTAssertEqual(
      TabTitle.map(
        ttys: ["/dev/ttys004", "bad", "/dev/ttys005", "/dev/ttys004"],
        names: ["✳ api work", "x", "", "dup"]),
      ["/dev/ttys004": "api work"])
  }

  func testTabTitleDisambiguatesSameProject() {
    for (pid, tty) in [(Int32(20), "/dev/ttys004"), (21, "/dev/ttys005")] {
      procs.set(pid, tty: tty)
      store.handleEvent(
        HookEvent(name: "SessionStart", sessionID: "s\(pid)", cwd: "/Users/x/api"),
        context: HookContext(termProgram: "ghostty", tty: tty, pid: pid))
    }
    guard let a0 = store.sessions["s20"] else { return XCTFail("no session") }
    XCTAssertEqual(store.disambiguator(for: a0), "s004")
    store.applyTabTitles(["/dev/ttys004": "Login fix", "/dev/ttys005": "Docs"])
    guard let a = store.sessions["s20"] else { return XCTFail("no session") }
    XCTAssertEqual(store.disambiguator(for: a), "Login fix")
    XCTAssertEqual(store.secondaryText(for: a), "Login fix")
    XCTAssertEqual(store.displayName(for: a), "api · Login fix")
    // Same title on both: the tty suffix still tells them apart.
    store.applyTabTitles(["/dev/ttys004": "Claude Code", "/dev/ttys005": "Claude Code"])
    guard let b = store.sessions["s20"] else { return XCTFail("no session") }
    XCTAssertEqual(store.secondaryText(for: b), "Claude Code · s004")
    store.applyTabTitles([:])
    XCTAssertNil(store.sessions["s20"]?.tabTitle)
  }

  // MARK: - Review fixes

  func testDecisionChordsMustNotBeTypedOrAppShortcuts() {
    func ok(_ c: Bool, _ o: Bool, _ s: Bool, _ m: Bool) -> Bool {
      DecisionChord.isAllowed(control: c, option: o, shift: s, command: m)
    }
    XCTAssertTrue(ok(true, true, false, false), "⌃⌥ (default)")
    XCTAssertTrue(ok(true, false, true, false), "⌃⇧")
    XCTAssertTrue(ok(true, false, false, true), "⌃⌘")
    XCTAssertTrue(ok(false, true, false, true), "⌘⌥")
    XCTAssertFalse(ok(false, true, false, false), "⌥ types characters (⌥Q = @)")
    XCTAssertFalse(ok(false, true, true, false), "⌥⇧ types characters")
    XCTAssertFalse(ok(false, false, false, true), "⌘V, ⌘C ...")
    XCTAssertFalse(ok(false, false, true, true), "⌘⇧Z ...")
    XCTAssertFalse(ok(true, false, false, false), "⌃C in a terminal")
    XCTAssertFalse(ok(false, false, true, false))
  }

  func testWrittenContentIsNeverFullyVisibleCollapsed() {
    let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys004", pid: 20)
    procs.set(20, tty: "/dev/ttys004")
    let write = store.addPermission(
      HookEvent(
        name: "PermissionRequest", sessionID: "w", cwd: "/Users/x", toolName: "Write",
        toolInput: .object([
          "file_path": .string("/Users/x/.zshrc"), "content": .string("curl x | sh")
        ])),
      context: ctx) { _ in }
    XCTAssertNotNil(write.extra)
    XCTAssertFalse(write.fitsPeek, "the peek shows only the path")
    XCTAssertTrue(write.needsExpansion, "allowing needs the content on screen, to its end")
    let edit = store.addPermission(
      HookEvent(
        name: "PermissionRequest", sessionID: "w", cwd: "/Users/x", toolName: "Edit",
        toolInput: .object([
          "file_path": .string("/a"), "old_string": .string("x"), "new_string": .string("y")
        ])),
      context: ctx) { _ in }
    XCTAssertFalse(edit.fitsPeek)
    XCTAssertTrue(edit.needsExpansion)
  }

  func testMergingKeepsTheLineOrderOfOneScan() {
    let base = clock.t
    // Same scan, with and without a readable process start time.
    for withStart in [true, false] {
      do {
        clock = Clock()
        procs = FakeProcesses()
        let c = clock
        store = SessionStore(now: { c.t }, probe: procs.probe)
      }
      let pids: [Int32] = [60734, 2584, 33378, 52568]
      var records = [shell]
      for (i, pid) in pids.enumerated() {
        let tty = "/dev/ttys0\(10 + i)"
        procs.set(pid, tty: tty)
        var r = rec(pid, tty: tty, cwd: "/Users/x/p\(pid)")
        // Older processes have lower start times here, not lower pids.
        if withStart { r.startedAt = base.addingTimeInterval(-Double(1000 - i * 100)) }
        records.append(r)
      }
      store.applyDiscovery(records)
      let pidOf = { (id: String) in self.store.sessions[id]?.pid }
      let before = store.statusLine.map { pidOf($0.sessionID) }
      XCTAssertEqual(before.count, 4)
      if withStart { XCTAssertEqual(before, pids.map { Optional($0) }) }
      clock.advance(20)
      // The third one gets a hook event: its UUID id sorts before "found:".
      let ctx = HookContext(termProgram: "ghostty", tty: "/dev/ttys012", pid: 33378)
      store.handleEvent(
        HookEvent(name: "UserPromptSubmit", sessionID: "0e1f", cwd: "/Users/x/p33378"),
        context: ctx)
      XCTAssertNotNil(store.sessions["0e1f"])
      XCTAssertNil(store.sessions["found:33378"])
      XCTAssertEqual(store.statusLine.map { pidOf($0.sessionID) }, before, "start \(withStart)")
      XCTAssertEqual(
        store.displayOrder.map(\.pid).filter { $0 != 33378 },
        before.filter { $0 != 33378 })
    }
  }
}
