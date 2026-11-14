import CoreGraphics
import XCTest

@testable import ClaudeNotchCore

final class StatusPaletteTests: XCTestCase {
  func testContrastMatchesKnownValues() {
    XCTAssertEqual(StatusPalette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.001)
    XCTAssertEqual(StatusPalette.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
    // Symmetric.
    XCTAssertEqual(
      StatusPalette.contrast(StatusPalette.done, 0x000000),
      StatusPalette.contrast(0x000000, StatusPalette.done), accuracy: 0.0001)
  }

  /// Text on a solid status fill (chips, capsules) is black: the app hardcodes it as
  /// `NotchTheme.onStatus`, so every status color must pick black with at least 4.5:1.
  func testBlackTextOnEveryStatusFillReachesSmallTextContrast() {
    for hex in StatusPalette.all {
      XCTAssertEqual(StatusPalette.ink(on: hex), .black, String(hex, radix: 16))
      XCTAssertGreaterThanOrEqual(
        StatusPalette.contrast(hex, 0x000000), 4.5, String(hex, radix: 16))
    }
    // Yellow needs dark text; white on it would be far below 4.5:1.
    XCTAssertLessThan(StatusPalette.contrast(StatusPalette.needs, 0xFFFFFF), 1.5)
  }

  func testInkPicksWhiteOnDarkFill() {
    XCTAssertEqual(StatusPalette.ink(on: 0x0E0E10), .white)
    XCTAssertEqual(StatusPalette.ink(on: 0xFFFFFF), .black)
  }

  func testDashesSplitTheWidthWithTwoPointGaps() {
    let d = StatusPalette.dashes(width: 40, height: 3)
    XCTAssertEqual(d.count, 3)
    XCTAssertEqual(d[0].width, 12, accuracy: 0.0001)
    XCTAssertEqual(d[1].minX - d[0].maxX, 2, accuracy: 0.0001)
    XCTAssertEqual(d[2].minX - d[1].maxX, 2, accuracy: 0.0001)
    XCTAssertEqual(d[0].minX, 0)
    XCTAssertEqual(d[2].maxX, 40, accuracy: 0.0001)
    XCTAssertTrue(d.allSatisfy { $0.height == 3 && $0.minY == 0 })
  }

  func testDashesResizeWithTheSegment() {
    let narrow = StatusPalette.dashes(width: 22, height: 3)
    let wide = StatusPalette.dashes(width: 100, height: 3)
    XCTAssertEqual(narrow[2].maxX, 22, accuracy: 0.0001)
    XCTAssertEqual(wide[2].maxX, 100, accuracy: 0.0001)
    XCTAssertEqual(narrow[0].width, 6, accuracy: 0.0001)
    XCTAssertEqual(wide[0].width, 32, accuracy: 0.0001)
  }

  func testTinySegmentStillReadsBroken() {
    // Too narrow for 1 pt dashes with 2 pt gaps: dashes and gaps share the width equally.
    let d = StatusPalette.dashes(width: 5, height: 3)
    XCTAssertEqual(d.count, 3)
    XCTAssertEqual(d[0].width, 1, accuracy: 0.0001)
    XCTAssertEqual(d[1].minX - d[0].maxX, 1, accuracy: 0.0001)
    XCTAssertEqual(d[2].maxX, 5, accuracy: 0.0001)
  }

  func testNoDashesWithoutWidth() {
    XCTAssertTrue(StatusPalette.dashes(width: 0, height: 3).isEmpty)
    XCTAssertTrue(StatusPalette.dashes(width: 10, height: 3, count: 0).isEmpty)
  }
}
