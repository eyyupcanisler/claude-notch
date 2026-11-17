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

  /// Color only signals "needs the user": classic keeps its amber and red, working is a
  /// neutral grey and done a near-white; error stays a solid bar.
  func testClassicPaletteGreysWorkingAndDoneKeepsNeedsAndError() {
    let c = StatusPalette.classic
    XCTAssertEqual(c.working, 0x8E8E8E)
    XCTAssertEqual(c.needs, 0xFFB020)
    XCTAssertEqual(c.done, 0xE8E8E8)
    XCTAssertEqual(c.error, 0xFF453A)
    XCTAssertFalse(c.errorDashed)
    XCTAssertEqual(StatusColorScheme.classic.colors, c)
  }

  /// The same rule in the colorblind palette: yellow and pink-red stay, working and done are
  /// the same greys as in classic; error stays a broken bar.
  func testColorblindPaletteGreysWorkingAndDoneKeepsNeedsAndError() {
    let c = StatusPalette.colorblind
    XCTAssertEqual(c.working, 0x8E8E8E)
    XCTAssertEqual(c.needs, 0xF0E442)
    XCTAssertEqual(c.done, 0xE8E8E8)
    XCTAssertEqual(c.error, 0xFB7185)
    XCTAssertTrue(c.errorDashed)
    XCTAssertEqual(StatusColorScheme.colorblind.colors, c)
  }

  /// Working and done carry no hue in either palette (a neutral grey, a near-white).
  func testWorkingAndDoneHaveNoHueInBothPalettes() {
    for c in [StatusPalette.classic, StatusPalette.colorblind] {
      XCTAssertLessThanOrEqual(StatusPalette.chroma(c.working), 0.02, String(c.working, radix: 16))
      XCTAssertLessThanOrEqual(StatusPalette.chroma(c.done), 0.02, String(c.done, radix: 16))
    }
  }

  /// Needs and error are the only states with a clear hue (they are what color signals).
  func testOnlyNeedsAndErrorCarryColor() {
    for c in [StatusPalette.classic, StatusPalette.colorblind] {
      XCTAssertGreaterThanOrEqual(StatusPalette.chroma(c.needs), 0.3, String(c.needs, radix: 16))
      XCTAssertGreaterThanOrEqual(StatusPalette.chroma(c.error), 0.3, String(c.error, radix: 16))
    }
  }

  /// On the status line (over the black band) the three neutral states step up clearly:
  /// idle (white at 0.22) < working grey < done near-white, each step at least 2:1.
  func testWorkingGreyIsBrighterThanIdleAndDarkerThanDone() {
    for c in [StatusPalette.classic, StatusPalette.colorblind] {
      let idle = StatusPalette.lineColor(.idle, in: c)
      let working = StatusPalette.lineColor(.working, in: c)
      let done = StatusPalette.lineColor(.done, in: c)
      XCTAssertLessThan(StatusPalette.luminance(idle), StatusPalette.luminance(working))
      XCTAssertLessThan(StatusPalette.luminance(working), StatusPalette.luminance(done))
      XCTAssertGreaterThanOrEqual(StatusPalette.contrast(idle, working), 2, "idle -> working")
      XCTAssertGreaterThanOrEqual(StatusPalette.contrast(working, done), 2, "working -> done")
    }
  }

  /// The done bar is drawn opaque (it used to rest at 0.7): at 0.7 the near-white would sink
  /// toward the working grey. Working is opaque, idle keeps its faint white.
  func testDoneSegmentIsDrawnOpaque() {
    XCTAssertEqual(StatusPalette.lineOpacity(.done), 1)
    XCTAssertEqual(StatusPalette.lineOpacity(.working), 1)
    XCTAssertEqual(StatusPalette.lineOpacity(.idle), StatusPalette.idleAlpha)
    XCTAssertEqual(StatusPalette.idleAlpha, 0.22)
  }

  func testOnBlackCompositesPerChannel() {
    XCTAssertEqual(StatusPalette.onBlack(0xFFFFFF, opacity: 0.22), 0x383838)
    XCTAssertEqual(StatusPalette.onBlack(0x8E8E8E, opacity: 1), 0x8E8E8E)
    XCTAssertEqual(StatusPalette.onBlack(0xFF0000, opacity: 0), 0x000000)
    XCTAssertEqual(StatusPalette.chroma(0x777777), 0)
    XCTAssertEqual(StatusPalette.chroma(0xFF0000), 1, accuracy: 0.0001)
  }

  /// Classic draws the error segment as one solid bar (no mask); colorblind cuts it in 3.
  func testClassicDrawsErrorWithoutDashes() {
    XCTAssertNil(StatusPalette.errorPieces(StatusPalette.classic, width: 40, height: 3))
    XCTAssertEqual(
      StatusPalette.errorPieces(StatusPalette.colorblind, width: 40, height: 3)?.count, 3)
  }

  /// A fresh install (nothing saved) gets the original look; an unknown value falls back to it.
  func testFreshInstallResolvesToClassic() throws {
    let scratch = try ScratchDefaults("test.claudenotch.palette")
    let defaults = scratch.defaults
    defer { scratch.remove() }
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
