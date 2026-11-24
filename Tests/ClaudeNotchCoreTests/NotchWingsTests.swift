import CoreGraphics
import Foundation
import XCTest

@testable import ClaudeNotchCore

/// The notch wings: no island drops
/// down any more; the notch grows sideways at band height, long text for 4 s, then a small
/// mark that lingers only for what blocks Claude (permission, question, plan, waiting) until
/// it is handled. Under a Focus only those show, and only as the mark.
final class NotchWingsTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 200_000)
  private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
  private let long = NotchWings.longDuration

  private func note(_ id: String, valid: TimeInterval = 600) -> ModuleNote {
    ModuleNote(source: .calendar, id: id, title: id, validUntil: at(valid))
  }

  // MARK: Setting

  func testMarkOnlySettingDefaultsOffAndReadsStoredBool() throws {
    XCTAssertEqual(NotchWings.defaultsKey, "wingsMarkOnly")
    XCTAssertFalse(NotchWings.fallback)
    XCTAssertEqual(NotchWings.longDuration, 4)
    let scratch = try ScratchDefaults("test.claudenotch.wings")
    defer { scratch.remove() }
    let d = scratch.defaults
    XCTAssertFalse(NotchWings.markOnly(stored: d.object(forKey: NotchWings.defaultsKey)))
    d.set(true, forKey: NotchWings.defaultsKey)
    XCTAssertTrue(NotchWings.markOnly(stored: d.object(forKey: NotchWings.defaultsKey)))
    d.set(false, forKey: NotchWings.defaultsKey)
    XCTAssertFalse(NotchWings.markOnly(stored: d.object(forKey: NotchWings.defaultsKey)))
    XCTAssertFalse(NotchWings.markOnly(stored: "yes"), "not a Bool: the fallback")
  }

  // MARK: Two phases

  func testLongPhaseLastsFourSecondsThenMark() {
    var w = WingPlanner()
    XCTAssertTrue(w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0)))
    let first = w.display(at: at(0))
    XCTAssertEqual(first?.style, .long)
    XCTAssertEqual(first?.item?.kind, .permission)
    XCTAssertEqual(first?.item?.cardID, "c1")
    XCTAssertEqual(first?.mark, .permission)
    XCTAssertEqual(w.display(at: at(long - 0.1))?.style, .long)
    XCTAssertEqual(w.nextChange, at(long))
    XCTAssertTrue(w.expire(at: at(long)))
    let mark = w.display(at: at(long))
    XCTAssertEqual(mark?.style, .mark)
    XCTAssertNil(mark?.item)
    XCTAssertEqual(mark?.mark, .permission)
    XCTAssertEqual(mark?.count, 1)
    XCTAssertNil(w.nextChange, "a lingering mark is not timed")
  }

  func testMarkOnlySkipsTheLongText() {
    var w = WingPlanner(markOnly: true)
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    let d = w.display(at: at(0))
    XCTAssertEqual(d?.style, .mark, "the small mark at once")
    XCTAssertEqual(d?.mark, .permission)
    XCTAssertEqual(d?.count, 1)
    w.expire(at: at(long))
    XCTAssertEqual(w.display(at: at(long))?.style, .mark)
    XCTAssertEqual(w.display(at: at(long))?.mark, .permission)
  }

  func testMarkOnlyDoneShowsItsMarkForFourSecondsThenNothing() {
    var w = WingPlanner(markOnly: true)
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(1))?.style, .mark)
    XCTAssertEqual(w.display(at: at(1))?.mark, .done)
    XCTAssertTrue(w.expire(at: at(long)))
    XCTAssertNil(w.display(at: at(long)))
  }

  // MARK: Lingering, Focus off

  func testPermissionMarkLingersUntilAnswered() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.expire(at: at(long))
    XCTAssertEqual(w.display(at: at(600))?.mark, .permission, "still there ten minutes later")
    XCTAssertFalse(w.sync(open: w.marks), "still open: nothing goes")
    XCTAssertTrue(w.sync(open: []), "answered")
    XCTAssertNil(w.display(at: at(601)))
    XCTAssertTrue(w.marks.isEmpty)
  }

  func testQuestionPlanAndWaitingMarksLingerUntilHandled() {
    for attention in ["question", "plan", "waiting"] {
      var w = WingPlanner()
      w.receive(attention: attention, sessionID: "s1", at: at(0))
      w.expire(at: at(long))
      let d = w.display(at: at(300))
      XCTAssertEqual(d?.style, .mark, attention)
      XCTAssertEqual(d?.mark, .attention, attention)
      XCTAssertEqual(d?.target?.sessionID, "s1", attention)
      w.sync(open: [])
      XCTAssertNil(w.display(at: at(301)), attention)
    }
  }

  func testTerminalOnlyQuestionMarkTargetsItsTerminal() {
    var w = WingPlanner()
    w.questionMode = .terminalOnly
    w.receive(attention: "question", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.item?.asking, true)
    XCTAssertEqual(w.display(at: at(0))?.target?.asking, true, "a click jumps to the terminal")
    w.expire(at: at(long))
    let d = w.display(at: at(long))
    XCTAssertEqual(d?.target?.asking, true)
    XCTAssertEqual(d?.target?.sessionID, "s1")
    // The original mode: the question is answered in the panel, the click opens it.
    var o = WingPlanner()
    o.receive(attention: "question", sessionID: "s1", at: at(0))
    XCTAssertEqual(o.display(at: at(0))?.target?.asking, false)
  }

  func testErrorShowsItsTextForFourSecondsThenLeavesNoMark() {
    var w = WingPlanner()
    w.receive(attention: "error", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.style, .long)
    XCTAssertEqual(w.display(at: at(0))?.mark, .error)
    XCTAssertTrue(w.expire(at: at(long)))
    XCTAssertNil(w.display(at: at(long)), "an error does not block Claude: the bar shows it")
    XCTAssertTrue(w.marks.isEmpty)
    // Mark only: its mark for the 4 s, then nothing.
    var m = WingPlanner(markOnly: true)
    m.receive(attention: "error", sessionID: "s1", at: at(0))
    XCTAssertEqual(m.display(at: at(1))?.style, .mark)
    XCTAssertEqual(m.display(at: at(1))?.mark, .error)
    m.expire(at: at(long))
    XCTAssertNil(m.display(at: at(long)))
  }

  func testDoneAndModuleNotesLeaveNoMark() {
    var w = WingPlanner()
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.style, .long)
    XCTAssertEqual(w.display(at: at(0))?.mark, .done)
    XCTAssertTrue(w.expire(at: at(long)))
    XCTAssertNil(w.display(at: at(long)), "done vanishes after its 4 s")
    XCTAssertTrue(w.marks.isEmpty)

    var m = WingPlanner()
    XCTAssertTrue(m.receive(module: note("meeting"), at: at(0)))
    XCTAssertEqual(m.display(at: at(0))?.item?.kind, .module)
    XCTAssertEqual(m.display(at: at(0))?.mark, .module)
    XCTAssertTrue(m.expire(at: at(long)))
    XCTAssertNil(m.display(at: at(long)), "a module note vanishes after its 4 s")
  }

  /// Only what blocks Claude keeps a mark, with or without a Focus.
  func testOnlyBlockingKindsLinger() {
    let lingers: [WingMarkKind: Bool] = [
      .permission: true, .attention: true, .error: false, .done: false, .module: false,
    ]
    for kind in WingMarkKind.allCases {
      XCTAssertEqual(WingPlanner.lingers(kind), lingers[kind], kind.rawValue)
    }
  }

  // MARK: Focus on

  func testFocusOnShowsNothingForDoneErrorAndModuleNotes() {
    var w = WingPlanner(focusActive: true)
    XCTAssertFalse(w.receive(attention: "done", sessionID: "d", at: at(0)))
    XCTAssertNil(w.display(at: at(0)), "done: bar only")
    XCTAssertFalse(w.receive(attention: "error", sessionID: "e", at: at(1)))
    XCTAssertNil(w.display(at: at(1)), "error: bar only")
    XCTAssertFalse(w.receive(module: note("meeting"), at: at(2)))
    XCTAssertNil(w.display(at: at(2)), "module note: nothing")
    XCTAssertNil(w.current)
    XCTAssertNil(w.pendingModule)
    XCTAssertTrue(w.marks.isEmpty)
  }

  func testFocusOnShowsBlockingKindsOnlyAsAMarkUntilHandled() {
    for attention in ["permission", "question", "plan", "waiting"] {
      // The mark-only setting is off: under a Focus the long text never shows anyway.
      var w = WingPlanner(markOnly: false, focusActive: true)
      XCTAssertFalse(w.showsText)
      let card = attention == "permission" ? "c1" : nil
      XCTAssertTrue(w.receive(attention: attention, sessionID: "s1", cardID: card, at: at(0)))
      let first = w.display(at: at(0))
      XCTAssertEqual(first?.style, .mark, "no long text under Focus: \(attention)")
      XCTAssertEqual(first?.mark, WingMarkKind.of(attention: attention), attention)
      w.expire(at: at(long))
      let later = w.display(at: at(600))
      XCTAssertEqual(later?.style, .mark, attention)
      XCTAssertEqual(later?.mark, WingMarkKind.of(attention: attention), "stays: \(attention)")
      w.sync(open: [])
      XCTAssertNil(w.display(at: at(601)), "handled: gone (\(attention))")
    }
  }

  func testFocusOnShowsATerminalOnlyQuestionAsAMarkThatJumpsToTheTerminal() {
    var w = WingPlanner(focusActive: true)
    w.questionMode = .terminalOnly
    w.receive(attention: "question", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.style, .mark)
    w.expire(at: at(long))
    XCTAssertEqual(w.display(at: at(long))?.target?.asking, true)
  }

  func testTurningFocusOnEndsANonBlockingItemAndKeepsBlockingMarks() {
    var w = WingPlanner()
    w.receive(attention: "error", sessionID: "e", at: at(0))
    w.receive(attention: "waiting", sessionID: "q", at: at(1))
    w.receive(attention: "permission", sessionID: "p", cardID: "c", at: at(2))
    w.expire(at: at(2 + long))
    XCTAssertEqual(w.display(at: at(2 + long))?.count, 2, "the error left no mark")
    w.receive(attention: "done", sessionID: "d", at: at(10))
    w.receive(module: note("m"), at: at(11))
    XCTAssertEqual(w.display(at: at(11))?.item?.kind, .finished)
    w.setFocusActive(true)
    XCTAssertTrue(w.focusActive)
    XCTAssertNil(w.current, "the done text goes at once")
    XCTAssertNil(w.pendingModule, "the waiting module note too")
    XCTAssertEqual(w.marks.map(\.kind), [.attention, .permission])
    let d = w.display(at: at(11))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.count, 2)
  }

  func testTurningFocusOnShrinksABlockingItemToItsMark() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "p", cardID: "c", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.style, .long)
    w.setFocusActive(true)
    XCTAssertEqual(w.display(at: at(0))?.style, .mark)
    XCTAssertEqual(w.display(at: at(0))?.mark, .permission)
    w.setFocusActive(false)
    XCTAssertTrue(w.showsText)
    XCTAssertEqual(w.display(at: at(1))?.style, .long, "Focus off: the text again")
  }

  // MARK: Several at once

  func testNewestArrivalTakesTheLongPhase() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    XCTAssertTrue(w.receive(attention: "done", sessionID: "s2", at: at(1)))
    let d = w.display(at: at(1))
    XCTAssertEqual(d?.style, .long)
    XCTAssertEqual(d?.item?.kind, .finished, "the newest shows its text")
    XCTAssertEqual(d?.item?.sessionIDs, ["s2"])
    XCTAssertEqual(d?.count, 1, "the permission waits as a mark")
    w.expire(at: at(1 + long))
    let after = w.display(at: at(1 + long))
    XCTAssertEqual(after?.style, .mark)
    XCTAssertEqual(after?.mark, .permission)
    XCTAssertEqual(after?.count, 1)
  }

  func testSeveralLingeringMarksShowACountAndTheMostUrgent() {
    var w = WingPlanner()
    // The permission is the oldest: the drawn mark is the most urgent, not the newest.
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.receive(attention: "error", sessionID: "s2", at: at(1))
    w.receive(attention: "question", sessionID: "s3", at: at(2))
    w.receive(attention: "plan", sessionID: "s5", at: at(3))
    w.receive(attention: "done", sessionID: "s4", at: at(4))
    w.expire(at: at(4 + long))
    let d = w.display(at: at(4 + long))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.count, 3, "done and error never linger")
    XCTAssertEqual(d?.badge, 3, "the right wing draws the count")
    XCTAssertEqual(d?.mark, .permission, "the most urgent mark is drawn, not the newest")
    XCTAssertNil(d?.target, "several: a click opens the panel")
  }

  func testAnItemInItsPhaseDrawsItsOwnGlyphNotTheCount() {
    var w = WingPlanner(markOnly: true)
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.receive(attention: "permission", sessionID: "s2", cardID: "c2", at: at(1))
    w.receive(attention: "done", sessionID: "s3", at: at(2))
    let d = w.display(at: at(2))
    XCTAssertEqual(d?.mark, .done)
    XCTAssertEqual(d?.count, 2, "two permissions linger")
    XCTAssertEqual(d?.badge, 0, "the done mark draws its check, not a grey \"2\"")
    w.expire(at: at(2 + long))
    let after = w.display(at: at(2 + long))
    XCTAssertEqual(after?.mark, .permission)
    XCTAssertEqual(after?.badge, 2, "afterwards the count")
    // One lingering mark: its glyph, no count.
    var one = WingPlanner()
    one.receive(attention: "waiting", sessionID: "s1", at: at(0))
    one.expire(at: at(long))
    XCTAssertEqual(one.display(at: at(long))?.badge, 0)
  }

  func testMarkOnlyModuleNoteShowsItsMarkThenNothing() {
    var w = WingPlanner(markOnly: true)
    w.receive(module: note("meeting"), at: at(0))
    let d = w.display(at: at(1))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.mark, .module)
    XCTAssertTrue(w.expire(at: at(long)))
    XCTAssertNil(w.display(at: at(long)), "no lingering mark")
  }

  func testMarkUrgencyOrder() {
    let order: [WingMarkKind] = [.permission, .attention, .error, .done, .module]
    for (a, b) in zip(order, order.dropFirst()) {
      XCTAssertGreaterThan(a.urgency, b.urgency, "\(a.rawValue) > \(b.rawValue)")
    }
  }

  func testAttentionKindsMapToMarks() {
    XCTAssertEqual(WingMarkKind.of(attention: "permission"), .permission)
    XCTAssertEqual(WingMarkKind.of(attention: "question"), .attention)
    XCTAssertEqual(WingMarkKind.of(attention: "plan"), .attention)
    XCTAssertEqual(WingMarkKind.of(attention: "waiting"), .attention)
    XCTAssertEqual(WingMarkKind.of(attention: "done"), .done)
    XCTAssertEqual(WingMarkKind.of(attention: "error"), .error)
  }

  func testSingleLingeringMarkIsTheClickTarget() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.expire(at: at(long))
    let target = w.display(at: at(long))?.target
    XCTAssertEqual(target?.kind, .permission)
    XCTAssertEqual(target?.cardID, "c1")
    XCTAssertEqual(target?.asking, false, "a permission click opens the panel")
  }

  func testRepeatedAttentionForTheSameSessionKeepsOneMark() {
    var w = WingPlanner()
    w.receive(attention: "waiting", sessionID: "s1", at: at(0))
    w.receive(attention: "waiting", sessionID: "s1", at: at(10))
    w.expire(at: at(10 + long))
    XCTAssertEqual(w.marks.count, 1)
    XCTAssertEqual(w.marks.first?.since, at(10), "the newest arrival time")
  }

  func testFinishedArrivalsWithinTheCoalesceWindowMerge() {
    var w = WingPlanner()
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    w.receive(attention: "error", sessionID: "s2", at: at(1))
    let d = w.display(at: at(1))
    XCTAssertEqual(d?.item?.sessionIDs, ["s1", "s2"])
    XCTAssertEqual(d?.item?.errorIDs, ["s2"])
    XCTAssertEqual(d?.mark, .error, "an error in the batch colors the mark")
    XCTAssertEqual(w.nextChange, at(1 + long), "the merge restarts the 4 s")
    w.expire(at: at(1 + long))
    XCTAssertTrue(w.marks.isEmpty, "neither done nor error lingers")
    XCTAssertNil(w.display(at: at(1 + long)))
  }

  // MARK: Module notes

  func testModuleNoteWaitsBehindAClaudeItemThenShows() {
    var w = WingPlanner()
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    XCTAssertFalse(w.receive(module: note("m"), at: at(1)))
    XCTAssertEqual(w.display(at: at(1))?.item?.kind, .finished)
    XCTAssertTrue(w.expire(at: at(long)))
    XCTAssertEqual(w.display(at: at(long))?.item?.module?.id, "m")
    XCTAssertEqual(w.display(at: at(long))?.style, .long)
  }

  func testClaudeArrivalReplacesAModuleNoteAtOnce() {
    var w = WingPlanner()
    w.receive(module: note("m"), at: at(0))
    XCTAssertTrue(w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(1)))
    XCTAssertEqual(w.display(at: at(1))?.item?.kind, .permission)
  }

  // MARK: App paths

  func testOpeningThePanelKeepsLingeringMarks() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.receive(module: note("m"), at: at(1))
    w.clearAll()
    XCTAssertNil(w.current)
    XCTAssertNil(w.pendingModule)
    XCTAssertEqual(w.marks.map(\.cardID), ["c1"], "unanswered: the mark stays")
    XCTAssertEqual(w.display(at: at(2))?.style, .mark)
  }

  func testClearEndsTheLongPhaseOnly() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.clear()
    XCTAssertNil(w.current)
    XCTAssertEqual(w.display(at: at(0))?.style, .mark)
    XCTAssertEqual(w.display(at: at(0))?.count, 1)
  }

  func testHoverHoldExtendsTheLongPhase() {
    var w = WingPlanner()
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    w.hold(at: at(3.5), seconds: 1.5)
    XCTAssertFalse(w.expire(at: at(long)))
    XCTAssertEqual(w.display(at: at(long + 0.5))?.style, .long)
    XCTAssertEqual(w.nextChange, at(5))
  }

  func testShowBringsBackThePermissionText() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.expire(at: at(long))
    XCTAssertEqual(w.display(at: at(30))?.style, .mark)
    w.show(cardID: "c1", sessionID: "s1", at: at(30))
    let d = w.display(at: at(30))
    XCTAssertEqual(d?.style, .long)
    XCTAssertEqual(d?.item?.cardID, "c1")
    XCTAssertEqual(d?.count, 1, "still one mark for that card")
    XCTAssertEqual(w.nextChange, at(30 + long))
  }

  // MARK: Marks follow the store

  func testSyncAddsWhatOpenedWhileThePanelWasUp() {
    var w = WingPlanner()
    // The panel was open: no arrival reached the planner.
    let open = [
      WingMark(kind: .permission, sessionID: "s1", cardID: "c1", since: at(5)),
      WingMark(kind: .attention, sessionID: "s2", since: at(6)),
    ]
    XCTAssertTrue(w.sync(open: open))
    let d = w.display(at: at(10))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.mark, .permission)
    XCTAssertEqual(d?.count, 2)
    XCTAssertFalse(w.sync(open: open), "nothing new")
  }

  func testSyncKeepsTheArrivalTimeAndDropsWhatIsHandled() {
    var w = WingPlanner()
    w.receive(attention: "waiting", sessionID: "s1", at: at(0))
    w.expire(at: at(long))
    w.sync(open: [WingMark(kind: .attention, sessionID: "s1", since: at(50))])
    XCTAssertEqual(w.marks.first?.since, at(0), "the mark already there keeps its time")
    w.sync(open: [])
    XCTAssertTrue(w.marks.isEmpty, "handled: gone")
  }

  func testSyncLeavesOutKindsThatDoNotLinger() {
    for focus in [false, true] {
      var w = WingPlanner(focusActive: focus)
      w.sync(open: [
        WingMark(kind: .permission, sessionID: "s1", cardID: "c1", since: at(0)),
        WingMark(kind: .attention, sessionID: "s2", since: at(0)),
        WingMark(kind: .error, sessionID: "s3", since: at(0)),
        WingMark(kind: .done, sessionID: "s4", since: at(0)),
      ])
      XCTAssertEqual(Set(w.marks.map(\.kind)), [.permission, .attention], "Focus \(focus)")
    }
  }

  func testAHiddenMarkStaysAndShowsAgain() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.expire(at: at(long))
    // Its terminal is in front: hidden, not dropped.
    XCTAssertNil(w.display(at: at(10)) { _ in false })
    XCTAssertEqual(w.marks.count, 1)
    XCTAssertEqual(w.display(at: at(20))?.mark, .permission, "back once the terminal is not")
    // Count and target are of the marks on screen.
    w.receive(attention: "waiting", sessionID: "s2", at: at(30))
    w.expire(at: at(30 + long))
    let d = w.display(at: at(40)) { $0.kind != .permission }
    XCTAssertEqual(d?.count, 1)
    XCTAssertEqual(d?.badge, 0)
    XCTAssertEqual(d?.target?.kind, .attention)
  }

  func testOpenMarkOfASession() {
    func mark(
      _ status: String, held: Bool = false, mode: QuestionMode = .answerInNotch,
      silent: Bool = false
    ) -> WingMark? {
      WingPlanner.openMark(
        sessionID: "s1", statusKind: status, heldQuestion: held, questionMode: mode,
        silent: silent, since: at(0))
    }
    XCTAssertEqual(mark("question")?.kind, .attention)
    XCTAssertEqual(mark("question")?.asking, false)
    XCTAssertEqual(mark("question", mode: .terminalOnly)?.asking, true)
    XCTAssertEqual(mark("working", held: true)?.kind, .attention, "a question held in the notch")
    XCTAssertEqual(mark("working", held: true)?.asking, false)
    XCTAssertEqual(mark("plan")?.kind, .attention)
    XCTAssertEqual(mark("waiting")?.kind, .attention)
    XCTAssertNil(mark("error"), "an error does not block Claude: no mark, seen or not")
    XCTAssertNil(mark("done"), "done never lingers")
    XCTAssertNil(mark("working"))
    XCTAssertNil(mark("idle"))
    // Silent mode: only what needs an answer.
    XCTAssertNotNil(mark("question", silent: true))
    XCTAssertNotNil(mark("working", held: true, silent: true))
    XCTAssertNil(mark("plan", silent: true))
    XCTAssertNil(mark("waiting", silent: true))
    XCTAssertNil(mark("error", silent: true))
  }

  func testIslandKindOfAMark() {
    func kind(_ m: WingMark, _ status: String? = "waiting", held: Bool = false) -> String? {
      WingPlanner.islandKind(of: m, statusKind: status, heldQuestion: held)
    }
    let perm = WingMark(kind: .permission, sessionID: "s1", cardID: "c1", since: at(0))
    XCTAssertEqual(kind(perm), "permission")
    let attention = WingMark(kind: .attention, sessionID: "s1", since: at(0))
    XCTAssertEqual(kind(attention, "plan"), "plan")
    XCTAssertEqual(kind(attention, "waiting"), "waiting")
    XCTAssertNil(kind(attention, "question", held: true), "answered in the notch: always shows")
    let asking = WingMark(kind: .attention, sessionID: "s1", asking: true, since: at(0))
    XCTAssertEqual(kind(asking, "question"), "question")
    XCTAssertNil(kind(WingMark(kind: .error, sessionID: "s1", since: at(0))), "never hidden")
  }

  // MARK: Geometry

  func testMarkWingIsThirtyPointsPerSide() {
    let side = WingMetrics.sideWidth(
      style: .mark, leftContent: 400, rightContent: 400, notchWidth: 185, screenWidth: 1512)
    XCTAssertEqual(side, 30)
    XCTAssertEqual(WingMetrics.totalWidth(side: side, notchWidth: 185), 245)
  }

  func testLongWingFitsTheWiderContentWithinItsBounds() {
    func long(_ l: CGFloat, _ r: CGFloat) -> CGFloat {
      WingMetrics.sideWidth(
        style: .long, leftContent: l, rightContent: r, notchWidth: 185, screenWidth: 1512)
    }
    XCTAssertEqual(long(140, 90), 140 + 2 * WingMetrics.padding, "the wider side sets both")
    XCTAssertEqual(long(10, 20), WingMetrics.minLongWidth, "short text: still wings")
    XCTAssertEqual(long(900, 30), WingMetrics.maxLongWidth, "long text is truncated at the cap")
  }

  func testLongWingsStayWithinNotchPlusTwoTimes220OnA1280Screen() {
    let notch: CGFloat = 185
    for content in stride(from: CGFloat(0), through: 1200, by: 50) {
      let side = WingMetrics.sideWidth(
        style: .long, leftContent: content, rightContent: content, notchWidth: notch,
        screenWidth: 1280)
      XCTAssertLessThanOrEqual(side, 220)
      XCTAssertLessThanOrEqual(
        WingMetrics.totalWidth(side: side, notchWidth: notch), notch + 2 * 220)
    }
  }

  func testLongWingsShrinkOnANarrowScreen() {
    // (600 - 180) / 2 - 8 = 202 pt of room beside the notch.
    let side = WingMetrics.sideWidth(
      style: .long, leftContent: 500, rightContent: 500, notchWidth: 180, screenWidth: 600)
    XCTAssertEqual(side, 202)
  }

  func testWingsKeepTheBandHeight() {
    XCTAssertEqual(WingMetrics.height(bandHeight: 32), 32, "never below the band")
    XCTAssertEqual(WingMetrics.height(bandHeight: 24), 24, "an external screen's menu bar")
    XCTAssertEqual(WingMetrics.height(bandHeight: 0), WingMetrics.bandlessHeight)
  }
}

/// The right wing's one line decides whether the global allow shortcut may allow from the
/// collapsed notch.
@MainActor
final class WingFitTests: XCTestCase {
  var clock = Clock()
  var store: SessionStore!

  override func setUp() async throws {
    clock = Clock()
    let c = clock
    store = SessionStore(now: { c.t }, probe: FakeProcesses().probe)
  }

  private func perm(_ sid: String, _ command: String) -> PendingPermission {
    store.addPermission(
      HookEvent(
        name: "PermissionRequest", sessionID: sid, cwd: "/Users/x/\(sid)", toolName: "Bash",
        toolInput: .object(["command": .string(command)])),
      termProgram: "ghostty"
    ) { _ in }
  }

  func testWingColumnsFollowTheWidestLongWing() {
    XCTAssertEqual(PendingPermission.wingLimit, 28)
    XCTAssertEqual(PendingPermission.riskyWingLimit, 25, "the hold ring takes three columns")
    for ring in [false, true] {
      let n = CGFloat(WingMetrics.monoColumns(ring: ring))
      // As WingText measures: ceil(text) + 1, plus the ring, plus the padding at both ends.
      let text = ceil(n * WingMetrics.monoAdvance) + 1
      let needed = text + (ring ? WingMetrics.holdRing + WingMetrics.ringGap : 0)
        + 2 * WingMetrics.padding
      XCTAssertLessThanOrEqual(needed, WingMetrics.maxLongWidth, "ring \(ring)")
      XCTAssertGreaterThan(
        needed + WingMetrics.monoAdvance, WingMetrics.maxLongWidth, "one more column would not fit")
    }
  }

  func testRiskyRequestUsesTheNarrowerLine() {
    let risky = perm("r", "rm -rf ./build && echo done1")
    XCTAssertNotNil(risky.risk)
    XCTAssertEqual(risky.fullText.count, 28)
    XCTAssertEqual(risky.wingColumns, PendingPermission.riskyWingLimit)
    XCTAssertFalse(risky.fitsWing, "28 columns plus the ring would be cut")
    XCTAssertEqual(risky.wingText.count, PendingPermission.riskyWingLimit)
  }

  func testFitsWingOnlyWhenTheWholeCommandFitsTheWing() {
    let short = perm("a", "npm test")
    XCTAssertTrue(short.fitsWing)
    XCTAssertEqual(short.wingText, "npm test")
    XCTAssertTrue(perm("b", String(repeating: "x", count: PendingPermission.wingLimit)).fitsWing)
    let over = perm("c", String(repeating: "x", count: PendingPermission.wingLimit + 1))
    XCTAssertFalse(over.fitsWing)
    XCTAssertEqual(over.wingText.count, PendingPermission.wingLimit, "head…tail in the limit")
    XCTAssertTrue(over.wingText.contains("…"))
    XCTAssertFalse(perm("d", "ls\nrm x").fitsWing, "folded newline")
    XCTAssertFalse(perm("e", String(repeating: "界", count: 20)).fitsWing, "wide characters")
    XCTAssertFalse(perm("f", String(repeating: "y", count: 40)).fitsWing)
  }
}
