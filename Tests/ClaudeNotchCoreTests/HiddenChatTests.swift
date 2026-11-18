import Foundation
import XCTest

@testable import ClaudeNotchCore

/// A chat the user hid (row button) leaves the panel and the status line, and comes back only
/// when it does something new: the user types in it, a turn really ends, or it needs the user.
@MainActor
final class HiddenChatTests: XCTestCase {
  private let alive = ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil })

  private func ctx(_ tty: String = "/dev/ttys001", _ pid: Int32 = 500) -> HookContext {
    HookContext(termProgram: "ghostty", tty: tty, pid: pid, branch: nil)
  }

  private func ev(
    _ name: String, _ sid: String = "a", tool: String? = nil, notification: String? = nil,
    source: String? = nil, background: [BackgroundTask] = []
  ) -> HookEvent {
    HookEvent(
      name: name, sessionID: sid, cwd: "/Users/x/proj", toolName: tool,
      notificationType: notification, lastAssistantMessage: "All set", source: source,
      backgroundTasks: background)
  }

  /// A finished chat ("done", unseen), as the panel shows it before the user hides it.
  private func finished(_ store: SessionStore, _ sid: String = "a") {
    store.handleEvent(ev("SessionStart", sid), context: ctx())
    store.handleEvent(ev("UserPromptSubmit", sid), context: ctx())
    store.handleEvent(ev("Stop", sid), context: ctx())
  }

  func testHideRemovesTheRowAndTheSegmentAndMarksSeen() {
    let store = SessionStore(probe: alive)
    finished(store)
    store.handleEvent(ev("SessionStart", "b"), context: ctx("/dev/ttys002", 600))
    XCTAssertEqual(store.doneUnseenCount, 1)

    XCTAssertTrue(store.hide(sessionID: "a"))

    XCTAssertEqual(store.displayOrder.map(\.id), ["b"])
    XCTAssertEqual(store.statusLine.map(\.sessionID), ["b"])
    XCTAssertEqual(store.hiddenSessions.map(\.id), ["a"])
    XCTAssertEqual(store.doneUnseenCount, 0, "a hidden chat is not an unseen done")
    XCTAssertTrue(store.hasVisibleSessions)
    XCTAssertNotNil(store.sessions["a"], "hiding keeps the session (its process still runs)")
  }

  func testOnlyHiddenChatsLeftMeansNoVisibleSessions() {
    let store = SessionStore(probe: alive)
    finished(store)
    store.hide(sessionID: "a")
    XCTAssertFalse(store.hasVisibleSessions)
    XCTAssertTrue(store.statusLine.isEmpty)
  }

  func testAChatThatNeedsTheUserCannotBeHidden() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.handleEvent(ev("UserPromptSubmit"), context: ctx())
    store.handleEvent(ev("PreToolUse", tool: "AskUserQuestion"), context: ctx())
    XCTAssertFalse(store.canHide(store.sessions["a"]!))
    XCTAssertFalse(store.hide(sessionID: "a"))
    XCTAssertEqual(store.displayOrder.map(\.id), ["a"])
  }

  func testAPermissionCardBlocksHiding() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.addPermission(ev("PermissionRequest", tool: "Bash"), context: ctx()) { _ in }
    XCTAssertFalse(store.hide(sessionID: "a"))
  }

  func testUnknownChatCannotBeHidden() {
    XCTAssertFalse(SessionStore(probe: alive).hide(sessionID: "nope"))
  }

  // MARK: What does not bring it back

  func testTheWaitingForInputNoticeKeepsItHiddenAndQuiet() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.hide(sessionID: "a")
    var bells = 0
    store.onEffect = { if case .bell = $0 { bells += 1 } }
    // Claude Code's "waiting for your input" a minute after the turn: exactly the dead state.
    store.handleEvent(ev("Notification", notification: "idle_prompt"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, true)
    XCTAssertEqual(store.attentionCount, 0, "no invisible 'needs you'")
    XCTAssertEqual(store.sessions["a"]?.status, .idle)
    XCTAssertEqual(bells, 0)
  }

  /// Hidden while working, then the turn ends without a Stop (Esc): the idle notice settles it
  /// to idle, quietly, instead of leaving it "working" for good.
  func testAHiddenWorkingChatSettlesToIdleOnTheIdleNotice() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.handleEvent(ev("UserPromptSubmit"), context: ctx())
    store.handleEvent(ev("PreToolUse", tool: "Bash"), context: ctx())
    XCTAssertTrue(store.hide(sessionID: "a"))
    XCTAssertEqual(store.workingCount, 0, "a hidden chat is not counted as working")
    XCTAssertEqual(store.activeWorkingCount, 0)
    var effects: [StoreEffect] = []
    store.onEffect = { effects.append($0) }
    store.handleEvent(ev("Notification", notification: "idle_prompt"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.status, .idle)
    XCTAssertEqual(store.sessions["a"]?.hidden, true)
    XCTAssertEqual(store.attentionCount, 0)
    XCTAssertTrue(effects.isEmpty, "no bell, sound or attention for a hidden chat")
  }

  /// A hidden chat that goes silent mid-turn turns quiet without the "quiet for 10 min" note.
  func testAHiddenChatGoingQuietRaisesNoNote() {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let store = SessionStore(now: { clock }, probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.handleEvent(ev("UserPromptSubmit"), context: ctx())
    store.hide(sessionID: "a")
    var notes = 0
    store.onEffect = { if case .attention(_, "quiet") = $0 { notes += 1 } }
    clock = clock.addingTimeInterval(SessionStore.quietAfter + 1)
    store.sweep()
    XCTAssertEqual(store.sessions["a"]?.status, .quiet)
    XCTAssertEqual(notes, 0)
  }

  func testToolCallsAndIdleCompactionKeepItHidden() {
    let store = SessionStore(probe: alive)
    finished(store)
    store.hide(sessionID: "a")
    store.handleEvent(ev("SessionStart", source: "compact"), context: ctx())
    store.handleEvent(ev("PreToolUse", tool: "Bash"), context: ctx())
    store.handleEvent(ev("PostToolUse", tool: "Bash"), context: ctx())
    store.handleEvent(ev("SubagentStop"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, true)
  }

  func testATurnThatLeavesBackgroundWorkKeepsItHidden() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.hide(sessionID: "a")
    let workflow = BackgroundTask(type: "workflow", name: "review-changes")
    store.handleEvent(ev("Stop", background: [workflow]), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, true, "not done yet")
  }

  // MARK: What brings it back

  func testTypingInTheChatBringsItBack() {
    let store = SessionStore(probe: alive)
    finished(store)
    store.hide(sessionID: "a")
    store.handleEvent(ev("UserPromptSubmit"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, false)
    XCTAssertEqual(store.displayOrder.map(\.id), ["a"])
  }

  func testAFinishedOrFailedTurnBringsItBack() {
    for name in ["Stop", "StopFailure"] {
      let store = SessionStore(probe: alive)
      store.handleEvent(ev("SessionStart"), context: ctx())
      store.hide(sessionID: "a")
      store.handleEvent(ev(name), context: ctx())
      XCTAssertEqual(store.sessions["a"]?.hidden, false, name)
    }
  }

  func testAQuestionOrPlanBringsItBack() {
    for tool in ["AskUserQuestion", "ExitPlanMode"] {
      let store = SessionStore(probe: alive)
      store.handleEvent(ev("SessionStart"), context: ctx())
      store.hide(sessionID: "a")
      store.handleEvent(ev("PreToolUse", tool: tool), context: ctx())
      XCTAssertEqual(store.sessions["a"]?.hidden, false, tool)
    }
  }

  func testAPermissionNoticeOrRequestBringsItBack() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.hide(sessionID: "a")
    store.handleEvent(ev("Notification", notification: "permission_prompt"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, false)

    store.markSeen(sessionID: "a")
    store.hide(sessionID: "a")
    store.handleEvent(ev("PermissionRequest", tool: "WebFetch"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, false)
  }

  func testAPermissionCardBringsItBack() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.hide(sessionID: "a")
    store.addPermission(ev("PermissionRequest", tool: "Bash"), context: ctx()) { _ in }
    XCTAssertEqual(store.sessions["a"]?.hidden, false)
  }

  func testAHeldQuestionBringsItBack() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    store.hide(sessionID: "a")
    let input = JSONValue.object([
      "questions": .array([
        .object([
          "question": .string("Which?"), "header": .string("Pick"), "multiSelect": .bool(false),
          "options": .array([
            .object(["label": .string("One"), "description": .string("1")]),
            .object(["label": .string("Two"), "description": .string("2")]),
          ]),
        ])
      ])
    ])
    let e = HookEvent(
      name: "PreToolUse", sessionID: "a", cwd: "/Users/x/proj", toolName: "AskUserQuestion",
      toolInput: input)
    XCTAssertNotNil(store.addQuestion(e) { _ in })
    XCTAssertEqual(store.sessions["a"]?.hidden, false)
  }

  func testANewSessionInTheSameTabIsNotHidden() {
    let store = SessionStore(probe: alive)
    finished(store)
    store.hide(sessionID: "a")
    // /clear in that tab: the same process starts a new session id.
    store.handleEvent(ev("SessionStart", "b"), context: ctx())
    XCTAssertEqual(store.displayOrder.map(\.id), ["b"])
    XCTAssertTrue(store.hiddenSessions.isEmpty)
  }

  func testShowOneAndShowAll() {
    let store = SessionStore(probe: alive)
    finished(store, "a")
    store.handleEvent(ev("SessionStart", "b"), context: ctx("/dev/ttys002", 600))
    store.hide(sessionID: "a")
    store.hide(sessionID: "b")
    store.unhide(sessionID: "a")
    XCTAssertEqual(store.hiddenSessions.map(\.id), ["b"])
    store.unhideAll()
    XCTAssertTrue(store.hiddenSessions.isEmpty)
    XCTAssertEqual(Set(store.displayOrder.map(\.id)), ["a", "b"])
  }

  // MARK: Placeholders found by the process scan

  func testAHiddenPlaceholderStaysHiddenWhenItsHookSessionArrives() {
    let store = SessionStore(probe: alive)
    store.applyDiscovery([
      ProcessRecord(
        pid: 500, ppid: 1, tty: "/dev/ttys001", path: "/usr/local/bin/claude", args: ["claude"],
        cwd: "/Users/x/proj", termProgram: "ghostty")
    ])
    let placeholder = SessionStore.discoveredPrefix + "500"
    XCTAssertTrue(store.hide(sessionID: placeholder))
    // A tool call of the running turn adopts the placeholder: still hidden.
    store.handleEvent(ev("PostToolUse", tool: "Bash"), context: ctx())
    XCTAssertNil(store.sessions[placeholder])
    XCTAssertEqual(store.sessions["a"]?.hidden, true)
    // The next prompt brings it back.
    store.handleEvent(ev("UserPromptSubmit"), context: ctx())
    XCTAssertEqual(store.sessions["a"]?.hidden, false)
  }

  func testAHiddenPlaceholderSurvivesTheNextScan() {
    let store = SessionStore(probe: alive)
    let record = ProcessRecord(
      pid: 500, ppid: 1, tty: "/dev/ttys001", path: "/usr/local/bin/claude", args: ["claude"],
      cwd: "/Users/x/proj", termProgram: "ghostty")
    store.applyDiscovery([record])
    store.hide(sessionID: SessionStore.discoveredPrefix + "500")
    store.applyDiscovery([record])
    XCTAssertEqual(store.hiddenSessions.count, 1)
  }

  // MARK: The chat's title

  func testChatTitleIsTheTabTitleAndNotTheGenericOne() {
    let store = SessionStore(probe: alive)
    store.handleEvent(ev("SessionStart"), context: ctx())
    let s0 = store.sessions["a"]!
    XCTAssertNil(store.chatTitle(for: s0))
    XCTAssertEqual(store.chatLabel(for: s0), "proj")

    store.applyTabTitles(["/dev/ttys001": "Claude Code"])
    XCTAssertNil(store.chatTitle(for: store.sessions["a"]!), "an unnamed chat's tab")

    store.applyTabTitles(["/dev/ttys001": "BTY book QR code mismatch"])
    let s = store.sessions["a"]!
    XCTAssertEqual(store.chatTitle(for: s), "BTY book QR code mismatch")
    XCTAssertEqual(store.chatLabel(for: s), "proj · BTY book QR code mismatch")
  }
}

/// A jump that brought the terminal forward but not the chat's tab is reported, not silent.
final class TabMissedTests: XCTestCase {
  func testTabMissedDoesNotCountAsReachingTheChat() {
    XCTAssertFalse(FocusOutcome.tabMissed(app: "Ghostty", code: nil).reachedSession)
    XCTAssertEqual(FocusOutcome.tabMissed(app: "Ghostty", code: -1712).kind, "tab_missed")
    XCTAssertTrue(FocusOutcome.activatedApp.reachedSession)
  }

  func testHintsNameTheChat() {
    let missed = FocusOutcome.tabMissed(app: "Ghostty", code: nil).hint(chat: "Kitai · BTY")
    XCTAssertEqual(missed, "Couldn’t switch to “Kitai · BTY” in Ghostty. Its tab may be closed.")
    let coded = FocusOutcome.tabMissed(app: "Ghostty", code: -1712).hint(chat: "Kitai · BTY")
    XCTAssertEqual(
      coded, "Couldn’t switch to “Kitai · BTY” in Ghostty (error -1712). Its tab may be closed.")
    XCTAssertEqual(
      FocusOutcome.tabMissed(app: "Ghostty", code: nil).hint,
      "Couldn’t switch to the chat’s tab in Ghostty. Its tab may be closed.")
    XCTAssertEqual(
      FocusOutcome.unknownTerminal.hint(chat: "tofu"), "Can’t tell which terminal “tofu” runs in")
    XCTAssertNil(FocusOutcome.focusedTerminal.hint(chat: "tofu"))
  }

  /// The Turkish table puts the chat first and the app second with positional specifiers.
  func testTurkishOrderOfTheMissedTabHint() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Localization/tr.lproj/Localizable.strings")
    let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    let format = try XCTUnwrap(table["Couldn’t switch to “%@” in %@%@. Its tab may be closed."])
    let error = try XCTUnwrap(table[" (error %@)"])
    let text = String(format: format, "Kitai · BTY", "Ghostty", String(format: error, "-1712"))
    XCTAssertEqual(
      text, "Ghostty içinde “Kitai · BTY” sohbetine geçilemedi (hata -1712). Sekmesi kapanmış olabilir.")
  }
}
