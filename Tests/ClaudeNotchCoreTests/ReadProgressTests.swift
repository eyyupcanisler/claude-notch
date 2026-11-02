import Foundation
import XCTest

@testable import ClaudeNotchCore

/// S1e / S1c of the live measurement: a long text counts as read only after a real scroll
/// reaches its end, never because a re-render saw a stale frame; the "Her zaman" rule is
/// shown whole.
final class ReadProgressTests: XCTestCase {
  private let maxHeight = 150.0

  /// A SwiftUI re-render of an opened, unscrolled long card (layout passes, the per-second
  /// tick, row changes) leaves it unread, whatever transient sizes the views report.
  func testRerenderOfOpenedUnscrolledLongCardStaysUnread() {
    var tracker = ReadTracker()
    // Before the first layout: no measurable width (nil), a zero-height clip, a zero doc.
    XCTAssertFalse(tracker.observe(
      .layout, contentHeight: nil, visibleMinY: 0, visibleHeight: 0, maxHeight: maxHeight))
    XCTAssertFalse(tracker.observe(
      .layout, contentHeight: 0, visibleMinY: 0, visibleHeight: 150, maxHeight: maxHeight))
    for _ in 0..<200 {
      XCTAssertFalse(tracker.observe(
        .layout, contentHeight: 3_400, visibleMinY: 0, visibleHeight: 150,
        maxHeight: maxHeight))
    }
    // A frame change mid-morph (taller clip than the text's own cap) is not a read either.
    XCTAssertFalse(tracker.observe(
      .layout, contentHeight: 3_400, visibleMinY: 0, visibleHeight: 400, maxHeight: maxHeight))
    // Bounds notifications without movement (resize, re-layout) do not count as scrolling.
    XCTAssertFalse(tracker.observe(
      .scroll, contentHeight: 3_400, visibleMinY: 0, visibleHeight: 150, maxHeight: maxHeight))
    XCTAssertFalse(tracker.reported)
  }

  func testScrollReachingTheEndIsRead() {
    var tracker = ReadTracker()
    XCTAssertFalse(tracker.observe(
      .scroll, contentHeight: 3_400, visibleMinY: 1_200, visibleHeight: 150,
      maxHeight: maxHeight))
    XCTAssertFalse(tracker.observe(
      .layout, contentHeight: 3_400, visibleMinY: 1_200, visibleHeight: 150,
      maxHeight: maxHeight))
    XCTAssertTrue(tracker.observe(
      .scroll, contentHeight: 3_400, visibleMinY: 3_250, visibleHeight: 150,
      maxHeight: maxHeight))
    XCTAssertEqual(tracker.trigger, .scroll)
    // Reported once only.
    XCTAssertFalse(tracker.observe(
      .scroll, contentHeight: 3_400, visibleMinY: 3_000, visibleHeight: 150,
      maxHeight: maxHeight))
    XCTAssertTrue(tracker.reported)
  }

  /// The end must be measured, not taken from a stale small document frame.
  func testScrollWithUnmeasurableTextIsNotRead() {
    var tracker = ReadTracker()
    XCTAssertFalse(tracker.observe(
      .scroll, contentHeight: nil, visibleMinY: 40, visibleHeight: 150, maxHeight: maxHeight))
    XCTAssertFalse(tracker.observe(
      .scroll, contentHeight: 3_400, visibleMinY: 80, visibleHeight: 150, maxHeight: maxHeight))
  }

  func testTextThatFitsIsReadAtOnce() {
    var tracker = ReadTracker()
    XCTAssertTrue(tracker.observe(
      .layout, contentHeight: 42, visibleMinY: 0, visibleHeight: 42, maxHeight: maxHeight))
    XCTAssertEqual(tracker.trigger, .layout)
  }

  func testTextTallerThanItsCapNeverFitsOnLayout() {
    XCTAssertFalse(ReadProgress.reachedEnd(
      contentHeight: 160, visibleMinY: 0, visibleHeight: 200, maxHeight: 150,
      trigger: .layout, originChanged: false))
    // A layout check of a scrolled view is never the "fits" case.
    XCTAssertFalse(ReadProgress.reachedEnd(
      contentHeight: 40, visibleMinY: 8, visibleHeight: 42, maxHeight: 150,
      trigger: .layout, originChanged: true))
  }

  func testResetStartsOver() {
    var tracker = ReadTracker()
    XCTAssertTrue(tracker.observe(
      .layout, contentHeight: 20, visibleMinY: 0, visibleHeight: 21, maxHeight: maxHeight))
    tracker.reset()
    XCTAssertFalse(tracker.reported)
    XCTAssertFalse(tracker.observe(
      .layout, contentHeight: 3_400, visibleMinY: 0, visibleHeight: 150, maxHeight: maxHeight))
  }

  // MARK: - "Her zaman" rule text

  func testLongRuleIsShownWholeWithItsTail() {
    let path = "/Users/me/" + String(repeating: "and/going/", count: 30)
      + "scripts/run-the-thing.sh:*"
    let sugg: JSONValue = .object([
      "type": .string("addRules"),
      "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string(path)])]),
      "behavior": .string("allow"), "destination": .string("localSettings")
    ])
    let text = ToolSummary.describeSuggestion(sugg)
    XCTAssertEqual(text, "Bash(\(path)) → localSettings")
    XCTAssertTrue(text.contains("scripts/run-the-thing.sh:*)"))
    XCTAssertFalse(text.contains("…"))
  }

  func testRuleContentIsSanitized() {
    let sugg: JSONValue = .object([
      "type": .string("addRules"),
      "rules": .array([.object([
        "toolName": .string("Bash"), "ruleContent": .string("ls\nrm -rf ~\u{202E}:*")
      ])])
    ])
    XCTAssertEqual(ToolSummary.describeSuggestion(sugg), "Bash(ls\\nrm -rf ~\\u{202E}:*)")
  }
}
