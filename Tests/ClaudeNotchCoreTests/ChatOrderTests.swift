import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Pinned chats and dragged rows (`ChatOrder`, `SessionStore.panelOrder`): the panel's own
/// order, kept when a chat's session id changes and after the app restarts.
@MainActor
final class ChatOrderTests: XCTestCase {
  private var clock = Date(timeIntervalSince1970: 1_800_000_000)
  private let alive = ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil })

  private func makeStore() -> SessionStore {
    SessionStore(now: { [unowned self] in self.clock }, probe: alive)
  }

  private func ev(_ name: String, _ sid: String) -> HookEvent {
    HookEvent(name: name, sessionID: sid, cwd: "/Users/x/\(sid)")
  }

  private func ctx(_ n: Int) -> HookContext {
    HookContext(termProgram: "ghostty", tty: "/dev/ttys\(String(format: "%03d", n))", pid: Int32(500 + n))
  }

  /// Four chats in tabs 1...4 (tab order a, b, c, d).
  private func fourChats() -> SessionStore {
    let store = makeStore()
    for (i, id) in ["a", "b", "c", "d"].enumerated() {
      clock += 1
      store.handleEvent(ev("SessionStart", id), context: ctx(i + 1))
    }
    store.applyTabOrder([
      "/dev/ttys001": 0, "/dev/ttys002": 1, "/dev/ttys003": 2, "/dev/ttys004": 3,
    ])
    return store
  }

  private func ids(_ store: SessionStore) -> [String] { store.panelOrder.map(\.id) }

  func testWithoutPinsOrDragsThePanelFollowsTheTabs() {
    let store = fourChats()
    XCTAssertEqual(ids(store), ["a", "b", "c", "d"])
  }

  func testPinnedChatsComeFirstInPinOrder() {
    let store = fourChats()
    store.togglePin(sessionID: "c")
    store.togglePin(sessionID: "a")
    XCTAssertEqual(ids(store), ["c", "a", "b", "d"])
    XCTAssertTrue(store.isPinned("c"))
    store.togglePin(sessionID: "c")
    XCTAssertEqual(ids(store), ["a", "b", "c", "d"], "unpinned, it goes back to its tab's place")
    XCTAssertEqual(store.statusLine.map(\.sessionID), ["a", "b", "c", "d"], "the line keeps tabs")
  }

  func testDraggedRowsKeepTheirPlaceAndNewChatsTakeTheirTabsPlace() {
    let store = fourChats()
    store.reorder(group: ["d", "a", "b", "c"])
    XCTAssertEqual(ids(store), ["d", "a", "b", "c"])
    // A new chat in a fifth tab comes in where the tab order puts it (last).
    clock += 1
    store.handleEvent(ev("SessionStart", "e"), context: ctx(5))
    store.applyTabOrder([
      "/dev/ttys001": 0, "/dev/ttys002": 1, "/dev/ttys003": 2, "/dev/ttys004": 3,
      "/dev/ttys005": 4,
    ])
    XCTAssertEqual(ids(store), ["d", "a", "b", "c", "e"])
  }

  func testDraggingAmongPinnedRowsOnlyMovesPinnedRows() {
    let store = fourChats()
    store.togglePin(sessionID: "a")
    store.togglePin(sessionID: "b")
    store.reorder(group: ["b", "a"])
    XCTAssertEqual(ids(store), ["b", "a", "c", "d"])
    // A group that mixes pinned and unpinned ids moves only the first row's group.
    store.reorder(group: ["a", "d", "b"])
    XCTAssertEqual(ids(store), ["a", "b", "c", "d"])
  }

  func testHiddenChatsAreLeftOutAndKeepTheirEntry() {
    let store = fourChats()
    store.togglePin(sessionID: "b")
    store.reorder(group: ["d", "c", "a"])
    XCTAssertEqual(ids(store), ["b", "d", "c", "a"])
    XCTAssertTrue(store.hide(sessionID: "b"))
    XCTAssertEqual(ids(store), ["d", "c", "a"])
    store.unhide(sessionID: "b")
    XCTAssertEqual(ids(store), ["b", "d", "c", "a"])
  }

  /// /clear: a new session id in the same process. The pin moves with it, whichever comes
  /// first (the old session's SessionEnd, or the new one's first event).
  func testClearKeepsThePin() {
    let store = fourChats()
    store.togglePin(sessionID: "c")
    // The new session's event first: the old one is retired.
    store.handleEvent(ev("SessionStart", "c2"), context: ctx(3))
    XCTAssertNil(store.sessions["c"])
    XCTAssertTrue(store.isPinned("c2"))
    XCTAssertEqual(ids(store).first, "c2")
    // SessionEnd first, then the new session in the same process and terminal.
    store.handleEvent(ev("SessionEnd", "c2"), context: ctx(3))
    store.handleEvent(ev("SessionStart", "c3"), context: ctx(3))
    XCTAssertTrue(store.isPinned("c3"))
    XCTAssertEqual(ids(store).first, "c3")
  }

  /// After a restart of the app, the process scan finds the chat before any hook event: the
  /// placeholder is pinned, and so is the hook session that adopts it.
  func testRestartFindsThePinnedChatAgain() {
    let store = fourChats()
    store.togglePin(sessionID: "d")
    let saved = store.chatOrder

    let fresh = makeStore()
    fresh.loadChatOrder(saved)
    fresh.applyDiscovery([
      ProcessRecord(pid: 501, ppid: 1, tty: "/dev/ttys001", path: "/x/claude", args: ["claude"],
        cwd: "/Users/x/a"),
      ProcessRecord(pid: 504, ppid: 1, tty: "/dev/ttys004", path: "/x/claude", args: ["claude"],
        cwd: "/Users/x/d"),
    ])
    XCTAssertTrue(fresh.isPinned("found:504"))
    XCTAssertEqual(fresh.panelOrder.first?.id, "found:504")
    fresh.handleEvent(ev("UserPromptSubmit", "d"), context: ctx(4))
    XCTAssertTrue(fresh.isPinned("d"))
    XCTAssertNil(fresh.sessions["found:504"])
    XCTAssertEqual(fresh.panelOrder.first?.id, "d")
  }

  func testOldEntriesAreForgottenAndChangesAreReported() {
    let store = fourChats()
    var reports = 0
    store.onChatOrderChange = { _ in reports += 1 }
    store.togglePin(sessionID: "a")
    XCTAssertEqual(reports, 1)
    store.togglePin(sessionID: "nope")
    XCTAssertEqual(reports, 1, "an unknown chat changes nothing")
    let saved = store.chatOrder
    XCTAssertEqual(saved.pruned(now: clock + 3600).pinned, ["a"])
    XCTAssertEqual(saved.pruned(now: clock + ChatOrder.keepFor + 1).pinned, [])
    // Round trip through JSON (how the app saves it).
    let data = try? JSONEncoder().encode(saved)
    XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(ChatOrder.self, from: $0) }, saved)
  }

  /// A drop leaves the chats that are not in the list where they were: the one whose card
  /// has the slot above the list, and hidden ones.
  func testDropKeepsTheCardSlotChatInItsPlace() {
    var order = ChatOrder()
    order.pinned = ["A", "B", "C"]
    order.reorder(["C", "B"])  // A has the card slot: the list showed B and C
    XCTAssertEqual(order.pinned, ["A", "C", "B"])
    order.manual = ["a", "b", "c", "d"]
    order.reorder(["d", "c", "b"])  // a in the slot
    XCTAssertEqual(order.manual, ["a", "d", "c", "b"])
    order.manual = []
    order.reorder(["y", "x"])  // a first drag: everything shown is listed
    XCTAssertEqual(order.manual, ["y", "x"])
  }

  /// An unpinned chat's old record is gone, so it can never be matched for another chat.
  func testUnpinnedRecordsAreNeverMatched() {
    let store = fourChats()
    store.togglePin(sessionID: "c")
    store.togglePin(sessionID: "c")
    XCTAssertTrue(store.chatOrder.identity.isEmpty)
    var order = ChatOrder()
    order.identity["stale"] = ChatOrder.Identity(pid: 9, tty: "/dev/ttys009")
    XCTAssertNil(order.entry(pid: 9, tty: "/dev/ttys009", live: []))
    order.pinned = ["stale"]
    XCTAssertEqual(order.entry(pid: 9, tty: "/dev/ttys009", live: []), "stale")
  }

  /// Old entries go only when their chat is gone: a chat still running after a long pause of
  /// the app keeps its pin; the hourly pass drops entries of chats that ended a day ago.
  func testPruneKeepsLiveChatsAndDropsEndedOnes() {
    final class Alive: @unchecked Sendable { var pids: Set<Int32> = [] }
    let alive = Alive()
    let probe = ProcessProbe(isAlive: { alive.pids.contains($0) }, ttyOf: { _ in nil })
    let store = SessionStore(now: { [unowned self] in self.clock }, probe: probe)
    alive.pids = [501, 502]
    store.handleEvent(ev("SessionStart", "a"), context: ctx(1))
    store.handleEvent(ev("SessionStart", "b"), context: ctx(2))
    store.togglePin(sessionID: "a")
    store.togglePin(sessionID: "b")
    let saved = store.chatOrder
    // Three days later, only a's process still runs.
    alive.pids = [501]
    let later = clock + 3 * 24 * 3600
    XCTAssertEqual(saved.pruned(now: later) { v in alive.pids.contains(v.pid) }.pinned, ["a"])
    // While running: b's process ends, a day and an hour pass.
    _ = store.sweep()
    XCTAssertNil(store.sessions["b"])
    XCTAssertEqual(store.chatOrder.pinned, ["a", "b"], "kept for a day after the chat ends")
    clock += ChatOrder.keepFor + 3700
    _ = store.sweep()
    XCTAssertEqual(store.chatOrder.pinned, ["a"])
  }

  func testArrangeIsStableForUnknownIDs() {
    var order = ChatOrder()
    order.pinned = ["gone"]
    order.manual = ["x", "gone2"]
    let s = { (id: String) in
      Session(id: id, project: id, cwd: "/", termProgram: nil, status: .idle,
        startedAt: Date(), lastUpdate: Date())
    }
    XCTAssertEqual(order.arrange([s("a"), s("x"), s("b")]).map(\.id), ["a", "x", "b"])
  }
}
