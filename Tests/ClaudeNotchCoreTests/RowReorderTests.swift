import XCTest

@testable import ClaudeNotchCore

/// Dragging a panel row (`RowReorder`): rows of different heights, a 6 pt gap.
final class RowReorderTests: XCTestCase {
  private let group = ["a", "b", "c", "d"]
  // a: 62 high, b: 122 (a question row), c and d: 62; 6 pt apart.
  private let spans: [String: RowReorder.Span] = [
    "a": .init(top: 0, bottom: 62), "b": .init(top: 68, bottom: 190),
    "c": .init(top: 196, bottom: 258), "d": .init(top: 264, bottom: 326),
  ]

  func testTargetFollowsTheMiddleOfTheDraggedRow() {
    func target(_ id: String, _ t: Double) -> Int {
      RowReorder.target(dragged: id, group: group, spans: spans, translation: t)
    }
    XCTAssertEqual(target("a", 0), 0)
    XCTAssertEqual(target("a", 90), 0, "a's middle (121) is still above b's (129)")
    XCTAssertEqual(target("a", 100), 1)
    XCTAssertEqual(target("a", 400), 3)
    XCTAssertEqual(target("d", -400), 0)
    XCTAssertEqual(target("c", -70), 2, "c (mid 157) is still below b (129)")
    XCTAssertEqual(target("c", -100), 1)
  }

  func testMovedAndShift() {
    XCTAssertEqual(RowReorder.moved(group, dragged: "a", to: 2), ["b", "c", "a", "d"])
    XCTAssertEqual(RowReorder.moved(group, dragged: "d", to: 0), ["d", "a", "b", "c"])
    XCTAssertEqual(RowReorder.moved(group, dragged: "x", to: 0), group)
    // a dragged down past b and c: both move up by a's height and the gap.
    for (id, want) in [("b", -68.0), ("c", -68), ("d", 0), ("a", 0)] {
      XCTAssertEqual(
        RowReorder.shift(of: id, dragged: "a", group: group, target: 2, height: 62, spacing: 6),
        want, id)
    }
    // d dragged up to the top: a, b and c move down.
    for id in ["a", "b", "c"] {
      XCTAssertEqual(
        RowReorder.shift(of: id, dragged: "d", group: group, target: 0, height: 62, spacing: 6),
        68, id)
    }
  }

  func testResistancePastTheEnds() {
    func resisted(_ t: Double) -> Double {
      RowReorder.resisted(translation: t, dragged: "b", group: group, spans: spans)
    }
    XCTAssertEqual(resisted(-50), -50, "inside: 1:1")
    XCTAssertEqual(resisted(136), 136, "b's bottom reaches d's bottom exactly")
    let past = resisted(-68 - 100)
    XCTAssertLessThan(past, -68)
    XCTAssertGreaterThan(past, -168, "past the top it follows less than 1:1")
    XCTAssertLessThan(resisted(-68 - 400) - resisted(-68 - 200), 0)
    XCTAssertGreaterThan(resisted(136 + 100), 136)
    XCTAssertLessThan(resisted(136 + 100), 236)
  }
}
