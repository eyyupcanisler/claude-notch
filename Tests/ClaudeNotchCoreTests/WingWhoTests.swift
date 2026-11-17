import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Which chat a wing is about: the long text names the terminal tab beside the project
/// (`WingLabel`), the status line lights that chat's segment (`WingDisplay.sessionIDs`), and
/// under a Focus only what blocks Claude makes a sound (`FocusIslands.playsSound`).
final class WingWhoTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 300_000)
  private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
  private let long = NotchWings.longDuration

  /// "Fits" when the whole label is at most `limit` characters (stands in for the app's font
  /// measurement).
  private func fits(_ limit: Int) -> (String) -> Bool { { $0.count <= limit } }
  private let asks: (String) -> String = { "\($0) asks:" }

  // MARK: Tab part

  func testTabPartIsTheTabTitle() {
    XCTAssertEqual(
      WingLabel.tabPart(project: "kutie-games", tabTitle: "Fix reward tiers", disambiguator: nil),
      "Fix reward tiers")
  }

  func testNoTabTitleKeepsTodaysDisambiguator() {
    XCTAssertNil(WingLabel.tabPart(project: "kutie-games", tabTitle: nil, disambiguator: nil))
    XCTAssertEqual(
      WingLabel.tabPart(project: "kutie-games", tabTitle: nil, disambiguator: "main"), "main",
      "two chats in one project without tab titles still read apart (branch / tty)")
  }

  func testTabTitleEqualToTheProjectIsSkipped() {
    XCTAssertNil(
      WingLabel.tabPart(project: "kutie-games", tabTitle: "kutie-games", disambiguator: nil))
    XCTAssertNil(
      WingLabel.tabPart(project: "kutie-games", tabTitle: " Kutie-Games ", disambiguator: nil),
      "case and surrounding spaces do not make it a different name")
    XCTAssertEqual(
      WingLabel.tabPart(
        project: "kutie-games", tabTitle: "kutie-games", disambiguator: "kutie-games"),
      nil, "the disambiguator is the same title: nothing new to say")
    XCTAssertEqual(
      WingLabel.tabPart(project: "kutie-games", tabTitle: "kutie-games", disambiguator: "main"),
      "main")
    XCTAssertNil(WingLabel.tabPart(project: "kutie-games", tabTitle: "  ", disambiguator: nil))
  }

  func testTitleThatDoesNotTellPeersApartKeepsTheDisambiguator() {
    XCTAssertEqual(
      WingLabel.tabPart(project: "app", tabTitle: "Fix", disambiguator: "Fix"), "Fix",
      "the title is the disambiguator: once")
    XCTAssertEqual(
      WingLabel.tabPart(project: "app", tabTitle: "Fix", disambiguator: "main"), "Fix · main")
  }

  // MARK: Label

  func testLabelNamesProjectAndTab() {
    XCTAssertEqual(
      WingLabel.label(
        project: "kutie-games", tabPart: "Fix reward tiers", compose: asks, fits: fits(100)),
      "kutie-games · Fix reward tiers asks:")
    XCTAssertEqual(
      WingLabel.label(project: "arrow-escape", tabPart: nil, compose: { "\($0) finished" }, fits: fits(100)),
      "arrow-escape finished")
  }

  func testLongTabIsCutAtItsEndFirst() {
    // "kutie-games · " (14) + tab + " asks:" (6): 30 characters leave 10 for the tab.
    let label = WingLabel.label(
      project: "kutie-games", tabPart: "Fix reward tiers", compose: asks, fits: fits(30))
    XCTAssertEqual(label, "kutie-games · Fix rewar… asks:")
    XCTAssertTrue(label.count <= 30)
  }

  func testCutTabDropsTrailingSpacesBeforeTheEllipsis() {
    // Room for 4 characters of the tab: "Fix " would end in a space; 3 still read.
    let label = WingLabel.label(
      project: "kutie-games", tabPart: "Fix reward tiers", compose: asks, fits: fits(25))
    XCTAssertEqual(label, "kutie-games · Fix… asks:")
  }

  func testNoRoomForAUsefulTabFallsBackToTheProject() {
    let label = WingLabel.label(
      project: "kutie-games", tabPart: "Fix reward tiers", compose: asks, fits: fits(22))
    XCTAssertEqual(label, "kutie-games asks:", "a stub of fewer than 3 characters says nothing")
  }

  func testNothingFitsReturnsTheProjectLabelForTheViewToTruncate() {
    XCTAssertEqual(
      WingLabel.label(project: "kutie-games", tabPart: "Fix", compose: asks, fits: fits(5)),
      "kutie-games asks:")
  }

  func testCutKeepsWholeCharacters() {
    XCTAssertEqual(
      WingLabel.label(
        project: "p", tabPart: "Çeldirici düzeltmeleri", compose: asks, fits: fits(22)),
      "p · Çeldirici d… asks:")
    XCTAssertEqual(
      WingLabel.label(project: "p", tabPart: "🎯🎯🎯🎯🎯 hedef", compose: asks, fits: fits(16)),
      "p · 🎯🎯🎯🎯🎯… asks:", "an emoji is never split")
  }

  func testShortTabThatFitsIsNeverCut() {
    XCTAssertEqual(
      WingLabel.label(project: "kutie-games", tabPart: "UI", compose: asks, fits: fits(22)),
      "kutie-games · UI asks:")
  }

  // MARK: Segment to light

  func testLongPhaseLightsTheItemsSession() {
    var w = WingPlanner()
    w.receive(attention: "question", sessionID: "s1", at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.sessionIDs, ["s1"])
  }

  func testMergedFinishedItemLightsEachOfItsSessions() {
    var w = WingPlanner()
    w.receive(attention: "done", sessionID: "s1", at: at(0))
    w.receive(attention: "error", sessionID: "s2", at: at(0.5))
    XCTAssertEqual(w.display(at: at(1))?.sessionIDs, ["s1", "s2"])
  }

  func testItemInItsPhaseLightsOnlyItsOwnSessionNotOtherMarks() {
    var w = WingPlanner()
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    w.receive(attention: "question", sessionID: "s2", at: at(1))
    let d = w.display(at: at(1))
    XCTAssertEqual(d?.count, 2)
    XCTAssertEqual(d?.sessionIDs, ["s2"])
  }

  func testLingeringMarkLightsItsTarget() {
    var w = WingPlanner()
    w.receive(attention: "question", sessionID: "s1", at: at(0))
    w.expire(at: at(long))
    let d = w.display(at: at(long))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.sessionIDs, ["s1"])
  }

  func testWithACountOnlyTheMostUrgentMarkIsLit() {
    var w = WingPlanner()
    w.receive(attention: "question", sessionID: "s1", at: at(0))
    w.receive(attention: "permission", sessionID: "s2", cardID: "c2", at: at(1))
    w.receive(attention: "question", sessionID: "s3", at: at(2))
    w.expire(at: at(2 + long))
    let d = w.display(at: at(2 + long))
    XCTAssertEqual(d?.badge, 3)
    XCTAssertNil(d?.target)
    XCTAssertEqual(d?.sessionIDs, ["s2"], "permission is the most urgent")
    let hidden = w.display(at: at(2 + long)) { $0.sessionID != "s2" }
    XCTAssertEqual(hidden?.sessionIDs, ["s3"], "a hidden mark is not lit; the newest of a kind wins")
  }

  func testModuleNoteLightsNothing() {
    var w = WingPlanner()
    w.receive(module: ModuleNote(source: .calendar, id: "n", title: "n", validUntil: at(600)), at: at(0))
    XCTAssertEqual(w.display(at: at(0))?.sessionIDs, [])
  }

  func testUnderAFocusTheItemShownAsItsMarkLightsItsSession() {
    var w = WingPlanner(focusActive: true)
    w.receive(attention: "permission", sessionID: "s1", cardID: "c1", at: at(0))
    let d = w.display(at: at(0))
    XCTAssertEqual(d?.style, .mark)
    XCTAssertEqual(d?.sessionIDs, ["s1"])
  }

  // MARK: Sounds under a Focus

  func testWithoutAFocusEverySoundPlays() {
    for kind in ["permission", "question", "plan", "waiting", "done", "error"] {
      XCTAssertTrue(FocusIslands.playsSound(kind: kind, focusActive: false), kind)
    }
  }

  func testUnderAFocusOnlyWhatBlocksClaudeSounds() {
    for kind in ["permission", "question", "plan", "waiting"] {
      XCTAssertTrue(FocusIslands.playsSound(kind: kind, focusActive: true), kind)
    }
    for kind in ["done", "error"] {
      XCTAssertFalse(FocusIslands.playsSound(kind: kind, focusActive: true), kind)
    }
  }

  func testSoundsFollowTheSameRuleAsTheWings() {
    for kind in ["permission", "question", "plan", "waiting", "done", "error", "other"] {
      for focus in [false, true] {
        XCTAssertEqual(
          FocusIslands.playsSound(kind: kind, focusActive: focus),
          FocusIslands.shows(kind: kind, focusActive: focus), "\(kind) focus=\(focus)")
      }
    }
  }

  func testAModuleChimeFollowsItsNote() {
    XCTAssertTrue(FocusIslands.playsModuleSound(focusActive: false))
    XCTAssertFalse(FocusIslands.playsModuleSound(focusActive: true))
    // Under a Focus the note itself is dropped, so the chime is silent with it.
    var w = WingPlanner()
    w.setFocusActive(true)
    let note = ModuleNote(source: .timer, id: "t", title: "t", validUntil: at(600))
    XCTAssertFalse(w.receive(module: note, at: at(0)))
    XCTAssertNil(w.display(at: at(0)))
  }
}
