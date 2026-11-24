import Foundation
import XCTest

@testable import ClaudeNotchCore

/// The Accessibility path that marks a Ghostty chat seen: when events replace the 0.5 s poll,
/// and how bursts of events become single focused-terminal checks.
final class SeenWatchTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func testEventsOnlyWhenTrustedRunningAndAttached() {
    XCTAssertEqual(SeenWatch.mode(trusted: true, ghosttyRunning: true, attached: true), .events)
    XCTAssertEqual(SeenWatch.mode(trusted: false, ghosttyRunning: true, attached: true), .polling)
    XCTAssertEqual(SeenWatch.mode(trusted: true, ghosttyRunning: false, attached: true), .polling)
    XCTAssertEqual(SeenWatch.mode(trusted: true, ghosttyRunning: true, attached: false), .polling)
    XCTAssertEqual(
      SeenWatch.mode(trusted: false, ghosttyRunning: false, attached: false), .polling)
  }

  /// Spinner frames of one title compare equal; another title does not.
  func testTitleKeyIgnoresTheSpinnerGlyph() {
    let frames = ["⠂ Fix the build", "⠐ Fix the build", "✳ Fix the build", "* Fix the build",
      "Fix the build", "  ◐  Fix the build"]
    for frame in frames {
      XCTAssertEqual(SeenWatch.titleKey(frame), "Fix the build", frame)
    }
    XCTAssertNotEqual(SeenWatch.titleKey("⠂ Fix the build"), SeenWatch.titleKey("⠂ Write docs"))
    // Only leading glyphs go; one inside the text stays.
    XCTAssertEqual(SeenWatch.titleKey("✳ a ✳ b"), "a ✳ b")
    XCTAssertEqual(SeenWatch.titleKey("⠂"), "")
  }

  /// A burst of focus events (window + focused element + main window for one tab switch) is
  /// one check, ~50 ms after the first.
  func testFocusBurstIsOneCheck() throws {
    var gate = SeenEventGate()
    let first = try XCTUnwrap(gate.event(.focus, now: t0, busy: false))
    XCTAssertEqual(first.delay, SeenEventGate.focusDelay, accuracy: 0.0001)
    XCTAssertNil(gate.event(.focus, now: t0.addingTimeInterval(0.01), busy: false))
    XCTAssertNil(gate.event(.title, now: t0.addingTimeInterval(0.02), busy: false))
    XCTAssertTrue(gate.fire(first.token, busy: false))
    XCTAssertNil(gate.due)
    // The same token never fires twice.
    XCTAssertFalse(gate.fire(first.token, busy: false))
    // After the check, a new event schedules a new one.
    XCTAssertNil(gate.checkEnded(answered: true, now: t0.addingTimeInterval(0.08)))
    XCTAssertNotNil(gate.event(.focus, now: t0.addingTimeInterval(0.1), busy: false))
  }

  /// A title change waits 0.5 s (a spinner in the tab title must not check faster than the
  /// poll would); a focus event in that time moves the check sooner and the old timer does
  /// nothing.
  func testTitleWaitsAndFocusMovesItSooner() throws {
    var gate = SeenEventGate()
    let title = try XCTUnwrap(gate.event(.title, now: t0, busy: false))
    XCTAssertEqual(title.delay, SeenEventGate.titleDelay, accuracy: 0.0001)
    XCTAssertNil(gate.event(.title, now: t0.addingTimeInterval(0.1), busy: false))
    let focus = try XCTUnwrap(gate.event(.focus, now: t0.addingTimeInterval(0.2), busy: false))
    XCTAssertEqual(focus.delay, SeenEventGate.focusDelay, accuracy: 0.0001)
    XCTAssertNotEqual(focus.token, title.token)
    XCTAssertTrue(gate.fire(focus.token, busy: false))
    XCTAssertFalse(gate.fire(title.token, busy: false), "replaced timer")
  }

  /// An event while a check is in flight is not dropped: the check runs once more after it
  /// ends, however many events came.
  func testEventWhileBusyRerunsOnceAfterTheCheck() throws {
    var gate = SeenEventGate()
    XCTAssertNil(gate.event(.focus, now: t0, busy: true))
    XCTAssertNil(gate.event(.focus, now: t0.addingTimeInterval(0.01), busy: true))
    XCTAssertEqual(gate.rerun, .focus)
    let rerun = try XCTUnwrap(gate.checkEnded(answered: true, now: t0.addingTimeInterval(0.1)))
    XCTAssertEqual(rerun.delay, SeenEventGate.focusDelay, accuracy: 0.0001)
    XCTAssertNil(gate.rerun)
    XCTAssertTrue(gate.fire(rerun.token, busy: false))
    // Nothing more is owed.
    XCTAssertNil(gate.checkEnded(answered: true, now: t0.addingTimeInterval(0.2)))
  }

  /// A timer that goes off while another caller's check (activation, the 10 s tick) is in
  /// flight becomes a re-run after that check.
  func testFireWhileBusyBecomesRerun() throws {
    var gate = SeenEventGate()
    let s = try XCTUnwrap(gate.event(.focus, now: t0, busy: false))
    XCTAssertFalse(gate.fire(s.token, busy: true))
    XCTAssertEqual(gate.rerun, .focus)
    XCTAssertNotNil(gate.checkEnded(answered: nil, now: t0.addingTimeInterval(0.1)))
  }

  /// Title events while busy re-run at the title pace; a focus event among them wins.
  func testRerunKeepsTheSoonestTrigger() throws {
    var gate = SeenEventGate()
    _ = gate.event(.title, now: t0, busy: true)
    XCTAssertEqual(gate.rerun, .title)
    let titleRerun = try XCTUnwrap(gate.checkEnded(answered: true, now: t0))
    XCTAssertEqual(titleRerun.delay, SeenEventGate.titleDelay, accuracy: 0.0001)

    var mixed = SeenEventGate()
    _ = mixed.event(.title, now: t0, busy: true)
    _ = mixed.event(.focus, now: t0, busy: true)
    _ = mixed.event(.title, now: t0, busy: true)
    XCTAssertEqual(mixed.rerun, .focus)
  }

  /// No answer from Ghostty (hung, no window): checks wait 2 s; an answer ends the wait.
  func testQuietAfterNoAnswer() throws {
    var gate = SeenEventGate()
    XCTAssertNil(gate.checkEnded(answered: false, now: t0))
    let s = try XCTUnwrap(gate.event(.focus, now: t0.addingTimeInterval(0.5), busy: false))
    XCTAssertEqual(s.delay, 1.5, accuracy: 0.0001)
    XCTAssertTrue(gate.fire(s.token, busy: false))
    XCTAssertNil(gate.checkEnded(answered: true, now: t0.addingTimeInterval(2.1)))
    let next = try XCTUnwrap(gate.event(.focus, now: t0.addingTimeInterval(2.2), busy: false))
    XCTAssertEqual(next.delay, SeenEventGate.focusDelay, accuracy: 0.0001)
  }

  /// A check that did not ask Ghostty (no grant, nothing to clear) leaves the wait as it was.
  func testCheckWithoutAnswerKeepsQuiet() throws {
    var gate = SeenEventGate()
    _ = gate.checkEnded(answered: false, now: t0)
    _ = gate.checkEnded(answered: nil, now: t0.addingTimeInterval(1))
    let s = try XCTUnwrap(gate.event(.focus, now: t0.addingTimeInterval(1), busy: false))
    XCTAssertEqual(s.delay, 1, accuracy: 0.0001)
  }
}
