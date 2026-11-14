import CoreGraphics
import XCTest

@testable import ClaudeNotchCore

final class StatusPaletteTests: XCTestCase {
  func testContrastMatchesKnownValues() {
    XCTAssertEqual(StatusPalette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.001)
    XCTAssertEqual(StatusPalette.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
    // Symmetric.
    XCTAssertEqual(
      StatusPalette.contrast(StatusPalette.colorblind.done, 0x000000),
      StatusPalette.contrast(0x000000, StatusPalette.colorblind.done), accuracy: 0.0001)
  }

  /// Text on a solid status fill (chips, capsules) is black in both palettes (as it always
  /// was): the app hardcodes it as `NotchTheme.onStatus`, so every status color must pick black
  /// with at least 4.5:1.
  func testBlackTextOnEveryStatusFillReachesSmallTextContrast() {
    for hex in StatusPalette.classic.all + StatusPalette.colorblind.all {
      XCTAssertEqual(StatusPalette.ink(on: hex), .black, String(hex, radix: 16))
      XCTAssertGreaterThanOrEqual(
        StatusPalette.contrast(hex, 0x000000), 4.5, String(hex, radix: 16))
    }
    // Yellow needs dark text; white on it would be far below 4.5:1.
    XCTAssertLessThan(StatusPalette.contrast(StatusPalette.colorblind.needs, 0xFFFFFF), 1.5)
  }

  /// The original look, exactly: Claude orange, amber, green, red; error a solid bar.
  func testClassicPaletteHoldsTheOriginalColors() {
    let c = StatusPalette.classic
    XCTAssertEqual(c.working, 0xD97757)
    XCTAssertEqual(c.needs, 0xFFB020)
    XCTAssertEqual(c.done, 0x34C759)
    XCTAssertEqual(c.error, 0xFF453A)
    XCTAssertFalse(c.errorDashed)
    XCTAssertEqual(StatusColorScheme.classic.colors, c)
  }

  func testColorblindPaletteHoldsItsColors() {
    let c = StatusPalette.colorblind
    XCTAssertEqual(c.working, 0x22D3EE)
    XCTAssertEqual(c.needs, 0xF0E442)
    XCTAssertEqual(c.done, 0x388BFD)
    XCTAssertEqual(c.error, 0xFB7185)
    XCTAssertTrue(c.errorDashed)
    XCTAssertEqual(StatusColorScheme.colorblind.colors, c)
  }

  /// Classic draws the error segment as one solid bar (no mask); colorblind cuts it in 3.
  func testClassicDrawsErrorWithoutDashes() {
    XCTAssertNil(StatusPalette.errorPieces(StatusPalette.classic, width: 40, height: 3))
    XCTAssertEqual(
      StatusPalette.errorPieces(StatusPalette.colorblind, width: 40, height: 3)?.count, 3)
  }

  /// A fresh install (nothing saved) gets the original look; an unknown value falls back to it.
  func testFreshInstallResolvesToClassic() throws {
    let suite = "test.claudenotch.palette.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(StatusColorScheme.defaultsKey, "statusColors")
    XCTAssertEqual(
      StatusColorScheme(stored: defaults.string(forKey: StatusColorScheme.defaultsKey)), .classic)
    XCTAssertEqual(StatusColorScheme(stored: "neon"), .classic)
    defaults.set("colorblind", forKey: StatusColorScheme.defaultsKey)
    XCTAssertEqual(
      StatusColorScheme(stored: defaults.string(forKey: StatusColorScheme.defaultsKey)),
      .colorblind)
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
