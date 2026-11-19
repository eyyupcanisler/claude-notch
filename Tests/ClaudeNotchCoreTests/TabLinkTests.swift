import Foundation
import XCTest

@testable import ClaudeNotchCore

/// One chat per tab, as the user's Mac had it on 2026-11-19 with Claude Code 2.1.328:
/// - tab A (ttys001): the old `claude --resume`, stopped by `/restart`, and the new client;
///   the chat itself runs in the background daemon on a hidden terminal (ttys009), carrying
///   tab A's Ghostty surface id; the daemon also keeps a spare on ttys004;
/// - tab B (ttys002): a chat stopped with Ctrl-Z and a running one.
/// Before: tab A showed as two segments (both marked "you are here"), the real chat as a third
/// one tied to no tab, the spare as a fake chat; the extra segments pushed real chats off the
/// six-segment line.
@MainActor
final class TabLinkTests: XCTestCase {
  var procs = FakeProcesses()
  var store: SessionStore!

  let tabA = "/dev/ttys001"
  let tabB = "/dev/ttys002"
  let hidden = "/dev/ttys009"
  let spareTTY = "/dev/ttys004"
  let surfaceA = "0x065b216bc164dd91"
  let surfaceB = "0x6db6699ef02aa66f"
  let version = "/Users/x/.local/share/claude/versions/2.1.328"

  override func setUp() async throws {
    procs = FakeProcesses()
    store = SessionStore(now: { Date(timeIntervalSince1970: 1000) }, probe: procs.probe)
  }

  private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

  /// The process table (only processes on a terminal carry path, argv and environment, as in
  /// `SystemProcesses.list`).
  func records(oldStopped: Bool = true) -> [ProcessRecord] {
    [
      ProcessRecord(pid: 100, ppid: 50, tty: tabA, path: "/bin/zsh", args: ["-zsh"],
        surfaceID: surfaceA),
      ProcessRecord(pid: 101, ppid: 100, tty: tabA, path: version,
        args: ["claude", "--resume", "c2f67864"], cwd: "/Users/x/claude-notch",
        termProgram: "ghostty", startedAt: at(100), stopped: oldStopped, foreground: false,
        surfaceID: surfaceA),
      ProcessRecord(pid: 102, ppid: 100, tty: tabA, path: version, args: ["claude"],
        cwd: "/Users/x/claude-notch", termProgram: "ghostty", startedAt: at(900),
        surfaceID: surfaceA),
      // The daemon and its pty hosts have no terminal: nothing but pid / ppid is read.
      ProcessRecord(pid: 103, ppid: 101),
      ProcessRecord(pid: 104, ppid: 103),
      ProcessRecord(pid: 105, ppid: 104, tty: hidden, path: version,
        args: [version, "--session-id", "6f0a4ce0", "--fork-session"],
        cwd: "/Users/x/claude-notch", startedAt: at(890), surfaceID: surfaceA,
        backgroundSession: true),
      // A tool of that chat on its hidden terminal: same surface id, no "bg" marker.
      ProcessRecord(pid: 106, ppid: 105, tty: hidden, path: "/bin/bash", args: ["bash"],
        surfaceID: surfaceA),
      ProcessRecord(pid: 107, ppid: 103),
      ProcessRecord(pid: 108, ppid: 107, tty: spareTTY, path: version,
        args: ["claude", "bg-spare", "--bg-spare", "/tmp/cc-daemon-501/x/spare/a.claim.sock"],
        startedAt: at(890), surfaceID: surfaceA, backgroundSession: true),
      ProcessRecord(pid: 200, ppid: 50, tty: tabB, path: "/bin/zsh", args: ["-zsh"],
        surfaceID: surfaceB),
      ProcessRecord(pid: 201, ppid: 200, tty: tabB, path: version, args: ["claude"],
        cwd: "/Users/x/tofu", termProgram: "ghostty", startedAt: at(500), stopped: true,
        foreground: false, surfaceID: surfaceB),
      ProcessRecord(pid: 202, ppid: 200, tty: tabB, path: version, args: ["claude", "-c"],
        cwd: "/Users/x/tofu", termProgram: "ghostty", startedAt: at(200), surfaceID: surfaceB),
    ]
  }

  private func hook(_ name: String, _ sid: String, tty: String, pid: Int32, term: String? = nil) {
    procs.set(pid, tty: tty)
    store.handleEvent(
      HookEvent(name: name, sessionID: sid, cwd: "/Users/x/claude-notch"),
      context: HookContext(termProgram: term, tty: tty, pid: pid))
  }

  // MARK: - Process scan

  func testHiddenTerminalLinksToItsTab() {
    XCTAssertEqual(ClaudeProcess.tabTTYs(in: records()), [hidden: tabA])
  }

  /// No link when two terminals carry the surface id, or none does.
  func testNoLinkWhenTheTabIsAmbiguousOrUnknown() {
    var twoTabs = records()
    twoTabs.append(ProcessRecord(pid: 300, ppid: 50, tty: "/dev/ttys003", path: "/bin/zsh",
      args: ["-zsh"], surfaceID: surfaceA))
    XCTAssertEqual(ClaudeProcess.tabTTYs(in: twoTabs), [:])
    let noTab = records().filter { $0.tty != tabA }
    XCTAssertEqual(ClaudeProcess.tabTTYs(in: noTab), [:])
  }

  /// One chat per tab: stopped processes and the spare are not chats; in tab A the daemon's
  /// chat wins over the client that shows it; in tab B the running one.
  func testOneChatPerTab() {
    XCTAssertEqual(ClaudeProcess.sessions(in: records()).map(\.pid), [105, 202])
    XCTAssertTrue(ClaudeProcess.isSpare(records()[8]))
    XCTAssertFalse(ClaudeProcess.isSpare(records()[5]))
  }

  /// Two running Claude processes in one tab: the one in the foreground, else the newest.
  func testForegroundThenNewestWinsInATab() {
    let a = ProcessRecord(pid: 11, ppid: 1, tty: tabB, path: version, args: ["claude"],
      startedAt: at(10), foreground: false)
    let b = ProcessRecord(pid: 12, ppid: 1, tty: tabB, path: version, args: ["claude"],
      startedAt: at(5), foreground: true)
    XCTAssertEqual(ClaudeProcess.sessions(in: [a, b]).map(\.pid), [12])
    var c = b
    c.foreground = false
    XCTAssertEqual(ClaudeProcess.sessions(in: [a, c]).map(\.pid), [11])
  }

  func testSurfaceIDIsValidated() {
    XCTAssertEqual(ProcessRecord.validSurfaceID("0x065B216BC164DD91"), "0x065b216bc164dd91")
    XCTAssertNil(ProcessRecord.validSurfaceID("065b216bc164dd91"))
    XCTAssertNil(ProcessRecord.validSurfaceID("0x"))
    XCTAssertNil(ProcessRecord.validSurfaceID("0x12345678901234567"))
    XCTAssertNil(ProcessRecord.validSurfaceID("0xzz"))
    XCTAssertNil(ProcessRecord.validSurfaceID(nil))
  }

  /// KERN_PROCARGS2 as the kernel lays it out. An empty argument (`--append-system-prompt ""`)
  /// must not end the parse: the environment after it carries the tab id and the "bg" marker.
  func testProcArgsKeepsEmptyArgumentsAndTheEnvironment() {
    func buffer(_ argv: [String], _ env: [String]) -> [UInt8] {
      var argc = Int32(argv.count)
      var out = withUnsafeBytes(of: &argc) { Array($0) }
      out += Array(version.utf8) + [0, 0, 0, 0]
      for s in argv + env { out += Array(s.utf8) + [0] }
      return out + [0, 0, 0]
    }
    let (args, env) = ProcArgs.parse(buffer(
      ["claude", "--append-system-prompt", "", "--resume", "x"],
      ["GHOSTTY_SURFACE_ID=0x065b216bc164dd91", "CLAUDE_CODE_SESSION_KIND=bg", "A=b=c"]))
    XCTAssertEqual(args, ["claude", "--append-system-prompt", "", "--resume", "x"])
    XCTAssertEqual(env["GHOSTTY_SURFACE_ID"], "0x065b216bc164dd91")
    XCTAssertEqual(env["CLAUDE_CODE_SESSION_KIND"], "bg")
    XCTAssertEqual(env["A"], "b=c")
    XCTAssertEqual(ProcArgs.parse([1, 0]).0, [])
    XCTAssertEqual(ProcArgs.parse([0, 0, 0, 0, 0]).0, [])
  }

  // MARK: - Store

  /// The scan leaves one chat per tab; the daemon's chat sits in tab A and is a Ghostty chat.
  func testScanGivesOneChatPerTab() throws {
    store.applyDiscovery(records())
    XCTAssertEqual(store.sessions.count, 2)
    let a = try XCTUnwrap(store.sessions["found:105"])
    XCTAssertEqual(a.tty, hidden)
    XCTAssertEqual(a.tabTTY, tabA)
    XCTAssertEqual(a.terminal, tabA)
    XCTAssertEqual(a.termProgram, "ghostty")
    XCTAssertEqual(store.sessions["found:202"]?.terminal, tabB)
  }

  /// The daemon's chat reports from its hidden terminal, without TERM_PROGRAM: it takes the
  /// placeholder's place, and the tab's order, "you are here" and "seen" all reach it.
  func testHookChatFromTheDaemonBelongsToItsTab() throws {
    store.applyDiscovery(records())
    hook("UserPromptSubmit", "6f0a4ce0", tty: hidden, pid: 105)
    XCTAssertEqual(store.sessions.count, 2)
    let s = try XCTUnwrap(store.sessions["6f0a4ce0"])
    XCTAssertEqual(s.terminal, tabA)
    XCTAssertEqual(s.termProgram, "ghostty")
    store.applyTabOrder([tabB: 0, tabA: 1])
    XCTAssertEqual(store.tabOrdered.map(\.id), ["found:202", "6f0a4ce0"])
    store.setFocusedTTY(tabA)
    XCTAssertEqual(store.hereSessionIDs, ["6f0a4ce0"])
    hook("Stop", "6f0a4ce0", tty: hidden, pid: 105)
    XCTAssertEqual(store.sessions["6f0a4ce0"]?.unseen, true)
    XCTAssertTrue(store.markSeen(tty: tabA))
    XCTAssertEqual(store.sessions["6f0a4ce0"]?.unseen, false)
  }

  /// The link follows the scan: gone while the tab's processes are gone (the tab was closed),
  /// back when they are seen again.
  func testLinkFollowsTheScan() {
    store.applyDiscovery(records())
    hook("UserPromptSubmit", "6f0a4ce0", tty: hidden, pid: 105)
    XCTAssertEqual(store.sessions["6f0a4ce0"]?.terminal, tabA)
    store.applyDiscovery(records().filter { $0.tty != tabA })
    XCTAssertEqual(store.sessions["6f0a4ce0"]?.terminal, hidden)
    store.applyDiscovery(records())
    XCTAssertEqual(store.sessions["6f0a4ce0"]?.terminal, tabA)
  }

  /// The old chat of tab A (its hook session from before `/restart`) leaves once its process is
  /// stopped and another Claude runs in its tab; a stopped chat alone in its tab stays.
  func testStoppedChatLeavesWhenAnotherRunsInItsTab() {
    hook("UserPromptSubmit", "c2f67864", tty: tabA, pid: 101, term: "ghostty")
    store.applyDiscovery(records(oldStopped: false))
    XCTAssertNotNil(store.sessions["c2f67864"])
    store.applyDiscovery(records())
    XCTAssertNil(store.sessions["c2f67864"])
    XCTAssertNotNil(store.sessions["found:105"])
    // Alone in its tab: it stays (Ctrl-Z, `fg` later).
    let alone = SessionStore(now: { Date(timeIntervalSince1970: 1000) }, probe: procs.probe)
    alone.handleEvent(
      HookEvent(name: "UserPromptSubmit", sessionID: "solo", cwd: "/Users/x/tofu"),
      context: HookContext(termProgram: "ghostty", tty: tabB, pid: 201))
    procs.set(201, tty: tabB)
    alone.applyDiscovery(records().filter { $0.pid != 202 })
    XCTAssertNotNil(alone.sessions["solo"])
  }

  /// More chats than segments: the chat you are in keeps its segment even when it is the
  /// least urgent and the last in the tab order.
  func testChatYouAreInKeepsItsSegment() {
    var recs: [ProcessRecord] = []
    for i in 0..<(SessionStore.maxLineSegments + 1) {
      let tty = "/dev/ttys0\(20 + i)"
      recs.append(ProcessRecord(pid: Int32(400 + i), ppid: 1, tty: tty, path: version,
        args: ["claude"], cwd: "/Users/x/p\(i)", termProgram: "ghostty", startedAt: at(Double(i))))
    }
    store.applyDiscovery(recs)
    let last = "found:\(400 + SessionStore.maxLineSegments)"
    XCTAssertFalse(store.statusLine.map(\.sessionID).contains(last))
    store.setFocusedTTY("/dev/ttys0\(20 + SessionStore.maxLineSegments)")
    XCTAssertTrue(store.statusLine.map(\.sessionID).contains(last))
    XCTAssertEqual(store.statusLine.count, SessionStore.maxLineSegments)
  }
}
