import CoreGraphics
import XCTest

@testable import ClaudeNotchCore

final class TopEdgeRectTests: XCTestCase {
  /// The topmost pixel row (y == top) is inside; a rect ending at the top edge would miss it.
  func testTopRowCounts() {
    let r = TopEdgeRect.hanging(minX: 100, width: 200, top: 956, depth: 37)
    XCTAssertTrue(r.contains(CGPoint(x: 150, y: 956)))
    XCTAssertFalse(CGRect(x: 100, y: 956 - 37, width: 200, height: 37).contains(CGPoint(x: 150, y: 956)))
  }

  /// The bottom edge and the sides stay where they were.
  func testBottomAndSidesUnchanged() {
    let r = TopEdgeRect.hanging(minX: 100, width: 200, top: 956, depth: 37)
    XCTAssertTrue(r.contains(CGPoint(x: 100, y: 919)))
    XCTAssertFalse(r.contains(CGPoint(x: 150, y: 918.5)))
    XCTAssertFalse(r.contains(CGPoint(x: 99.5, y: 940)))
    XCTAssertFalse(r.contains(CGPoint(x: 300, y: 940)))
  }
}
