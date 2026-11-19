import Foundation
import Observation
import XCTest

@testable import ClaudeNotchCore

/// The white "you are here" base: which chats are in the terminal the user is in, the base's
/// color staying apart from every status color, and bar + base drawn as one piece.
@MainActor
final class HereBaseTests: XCTestCase {
  var procs = FakeProcesses()
  var store: SessionStore!

  override func setUp() async throws {
    procs = FakeProcesses()
    store = SessionStore(now: { Date(timeIntervalSince1970: 1000) }, probe: procs.probe)
  }

  private func start(_ sid: String, tty: String, pid: Int32) {
    procs.set(pid, tty: tty)
    store.handleEvent(
      HookEvent(name: "UserPromptSubmit", sessionID: sid, cwd: "/Users/x/\(sid)"),
      context: HookContext(termProgram: "ghostty", tty: tty, pid: pid))
  }

  func testHereFollowsTheFocusedTTY() {
    start("a", tty: "/dev/ttys010", pid: 100)
    start("b", tty: "/dev/ttys011", pid: 101)
    XCTAssertNil(store.focusedTTY)
    XCTAssertEqual(store.hereSessionIDs, [])
    store.setFocusedTTY("/dev/ttys011")
    XCTAssertEqual(store.hereSessionIDs, ["b"])
    store.setFocusedTTY("/dev/ttys010")
    XCTAssertEqual(store.hereSessionIDs, ["a"])
    // A terminal without a chat: no segment is marked.
    store.setFocusedTTY("/dev/ttys099")
    XCTAssertEqual(store.hereSessionIDs, [])
    store.setFocusedTTY(nil)
    XCTAssertNil(store.focusedTTY)
    XCTAssertEqual(store.hereSessionIDs, [])
  }

  /// Two chats on one tty (an old one not swept yet) are both "here".
  func testEveryChatOnTheTTYIsHere() {
    start("old", tty: "/dev/ttys010", pid: 100)
    start("new", tty: "/dev/ttys010", pid: 100)
    start("other", tty: "/dev/ttys011", pid: 101)
    store.setFocusedTTY("/dev/ttys010")
    XCTAssertEqual(store.hereSessionIDs, Set(store.sessions.values.filter {
      $0.tty == "/dev/ttys010"
    }.map(\.id)))
    XCTAssertFalse(store.hereSessionIDs.contains("other"))
  }

  /// Only a real tty is taken; anything else counts as none.
  func testInvalidTTYCountsAsNone() {
    store.setFocusedTTY("/dev/ttys010")
    store.setFocusedTTY("/dev/null")
    XCTAssertNil(store.focusedTTY)
    store.setFocusedTTY("")
    XCTAssertNil(store.focusedTTY)
  }

  /// Counts observation callbacks (the callback is `@Sendable`; it fires synchronously here).
  private final class Changes: @unchecked Sendable {
    var count = 0
  }

  /// The 0.5 s poll gets the same answer over and over: only a change wakes the views.
  func testSameTTYDoesNotNotify() {
    store.setFocusedTTY("/dev/ttys010")
    let changes = Changes()
    withObservationTracking {
      _ = store.focusedTTY
    } onChange: {
      changes.count += 1
    }
    store.setFocusedTTY("/dev/ttys010")
    XCTAssertEqual(changes.count, 0)
    store.setFocusedTTY("/dev/ttys011")
    XCTAssertEqual(changes.count, 1)
  }

  // MARK: - Color

  /// White has no hue, so it cannot be mistaken for a status color by hue, with any color
  /// vision; it is brighter than every status color (so it stands out in grayscale too), and
  /// clearly apart from the two hueless states: the working grey and faint white idle.
  func testBaseIsWhiteAndApartFromEveryState() {
    let base = StatusPalette.hereBase
    XCTAssertEqual(StatusPalette.chroma(base), 0)
    XCTAssertNotEqual(base, StatusPalette.doneBlue, "not the done blue any more")
    for c in [StatusPalette.classic, StatusPalette.colorblind] {
      for hex in c.all {
        XCTAssertLessThan(StatusPalette.luminance(hex), StatusPalette.luminance(base),
          String(hex, radix: 16))
      }
      let working = StatusPalette.lineColor(.working, in: c)
      let idle = StatusPalette.lineColor(.idle, in: c)
      XCTAssertGreaterThanOrEqual(StatusPalette.contrast(base, working), 3, "apart from working")
      XCTAssertGreaterThanOrEqual(StatusPalette.contrast(base, idle), 7, "apart from idle")
    }
  }

  // MARK: - Shape

  /// Bar 3 pt + base 1.5 pt, 19 pt wide (six segments under a 179 pt notch).
  private let w: CGFloat = 19.33
  private let h: CGFloat = 3

  /// Each part fills its own band: the bar its 3 pt, the base its 1.5 pt (own coordinates).
  func testPartsFillTheirBands() {
    let piece = StatusPalette.herePiece(width: w, height: h)
    let top = piece.top.boundingBoxOfPath
    let bottom = piece.bottom.boundingBoxOfPath
    XCTAssertEqual(top.minY, 0, accuracy: 0.01)
    XCTAssertEqual(top.maxY, h, accuracy: 0.01)
    XCTAssertEqual(top.width, w, accuracy: 0.01)
    XCTAssertEqual(bottom.minY, 0, accuracy: 0.01)
    XCTAssertEqual(bottom.maxY, StatusPalette.hereLift, accuracy: 0.01)
    // The capsule's ends already curve in where the base starts: at the split it is narrower
    // than the bar by the curve's inset on each side.
    let r = (h + StatusPalette.hereLift) / 2
    let inset = r - (r * r - (h - r) * (h - r)).squareRoot()
    XCTAssertEqual(bottom.width, w - 2 * inset, accuracy: 0.01)
    XCTAssertTrue(piece.top.contains(CGPoint(x: w / 2, y: h - 0.01)))
    XCTAssertTrue(piece.bottom.contains(CGPoint(x: w / 2, y: 0.01)))
  }

  /// One capsule split by a straight line: just above and just below the split, close to the
  /// left end, both parts are filled (no notch where they meet), while the outer corners are
  /// rounded. The bar alone (its own 1.5 pt rounding) would leave that spot empty.
  func testBarAndBaseJoinAsOnePiece() {
    let piece = StatusPalette.herePiece(width: w, height: h)
    XCTAssertTrue(piece.top.contains(CGPoint(x: 0.3, y: h - 0.05)))
    XCTAssertTrue(piece.bottom.contains(CGPoint(x: 0.3, y: 0.05)))
    XCTAssertTrue(piece.top.contains(CGPoint(x: w - 0.3, y: h - 0.05)))
    XCTAssertTrue(piece.bottom.contains(CGPoint(x: w - 0.3, y: 0.05)))
    XCTAssertFalse(piece.top.contains(CGPoint(x: 0.05, y: 0.05)), "rounded top corner")
    XCTAssertFalse(
      piece.bottom.contains(CGPoint(x: 0.05, y: StatusPalette.hereLift - 0.05)),
      "rounded bottom corner")
    let ownEnds = CGPath(
      roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: h / 2,
      cornerHeight: h / 2, transform: nil)
    XCTAssertFalse(ownEnds.contains(CGPoint(x: 0.3, y: h - 0.05)))
  }

  /// The colorblind palette's broken error bar in the chat you are in: every dash meets the
  /// base flat (its lower corners filled just above the split), while its top corners stay
  /// rounded. Plain dashes would leave those lower corners empty.
  func testErrorDashesMeetTheBaseFlat() throws {
    let pieces = try XCTUnwrap(StatusPalette.errorPieces(StatusPalette.colorblind, width: w, height: h))
    let top = StatusPalette.herePiece(width: w, height: h).top
    let flat = StatusPalette.dashOutline(pieces, flatBottom: true).intersection(top)
    let plain = StatusPalette.dashOutline(pieces).intersection(top)
    for r in pieces {
      for x in [r.minX + 0.2, r.maxX - 0.2] {
        XCTAssertTrue(flat.contains(CGPoint(x: x, y: h - 0.1)), "lower corner at \(x)")
        XCTAssertFalse(plain.contains(CGPoint(x: x, y: h - 0.1)), "plain dash is round at \(x)")
      }
      XCTAssertFalse(flat.contains(CGPoint(x: r.minX + 0.05, y: 0.05)), "top corner rounded")
      XCTAssertFalse(flat.contains(CGPoint(x: r.midX, y: h + 0.1)), "nothing below the split")
    }
    // Outside the error bar's own dashes, the default stays the plain pill outline.
    XCTAssertEqual(
      StatusPalette.dashOutline(pieces).boundingBoxOfPath.maxY, h, accuracy: 0.01)
  }

  /// A lit bar (4.5 pt) keeps its base under its new bottom edge; a tiny or empty segment does
  /// not crash.
  func testLitAndDegenerateSizes() {
    let lit = StatusPalette.herePiece(width: w, height: 4.5)
    XCTAssertEqual(lit.top.boundingBoxOfPath.maxY, 4.5, accuracy: 0.01)
    XCTAssertEqual(lit.bottom.boundingBoxOfPath.height, StatusPalette.hereLift, accuracy: 0.01)
    _ = StatusPalette.herePiece(width: 1, height: h)
    _ = StatusPalette.herePiece(width: 0, height: 0)
  }
}
