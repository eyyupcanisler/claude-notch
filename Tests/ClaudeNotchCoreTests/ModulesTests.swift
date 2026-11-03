import Foundation
import XCTest

@testable import ClaudeNotchCore

final class ModulesTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 100_000)
  private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  // MARK: Peek planner

  private func note(_ id: String, valid: TimeInterval = 600) -> ModuleNote {
    ModuleNote(source: .calendar, id: id, title: id, validUntil: at(valid))
  }

  func testModuleNeverPreemptsClaudeAndWaits() {
    var p = PeekPlanner()
    p.receive(attention: "done", sessionID: "s", at: at(0))
    XCTAssertFalse(p.receive(module: note("m"), at: at(1)))
    XCTAssertEqual(p.current?.kind, .finished)
    XCTAssertTrue(p.expire(at: at(3)))
    XCTAssertEqual(p.current?.kind, .module, "the waiting note shows once the Claude peek is gone")
    XCTAssertEqual(p.current?.module?.id, "m")
  }

  func testClaudePeekReplacesModuleAtOnce() {
    var p = PeekPlanner()
    p.receive(module: note("m"), at: at(0))
    XCTAssertTrue(p.receive(attention: "permission", sessionID: "s", cardID: "c", at: at(1)))
    XCTAssertEqual(p.current?.kind, .permission)
    XCTAssertNil(p.current?.module)
  }

  func testStaleWaitingNoteIsDropped() {
    var p = PeekPlanner()
    p.receive(attention: "permission", sessionID: "s", cardID: "c", at: at(0))
    p.receive(module: note("m", valid: 5), at: at(1))
    p.clear()
    p.expire(at: at(10))
    XCTAssertNil(p.current)
  }

  func testClearAllDropsWaitingNote() {
    var p = PeekPlanner()
    p.receive(attention: "permission", sessionID: "s", cardID: "c", at: at(0))
    p.receive(module: note("m"), at: at(1))
    p.clearAll()
    p.expire(at: at(2))
    XCTAssertNil(p.current)
  }

  func testModuleExpires() {
    var p = PeekPlanner()
    p.receive(module: note("m"), at: at(0))
    XCTAssertFalse(p.expire(at: at(PeekPlanner.moduleDuration - 0.1)))
    XCTAssertTrue(p.expire(at: at(PeekPlanner.moduleDuration)))
    XCTAssertNil(p.current)
  }

  // MARK: Calendar

  private func ev(_ id: String, start: TimeInterval, len: TimeInterval = 1800, allDay: Bool = false)
    -> CalendarItem
  {
    CalendarItem(id: id, title: id, start: at(start), end: at(start + len), isAllDay: allDay)
  }

  func testNextSkipsAllDayAndEnded() {
    let items = [ev("old", start: -3600), ev("day", start: 60, allDay: true), ev("b", start: 900),
      ev("a", start: 300)]
    XCTAssertEqual(CalendarReminder.next(items, now: t0)?.id, "a")
    XCTAssertNil(CalendarReminder.next([ev("far", start: 13 * 3600)], now: t0))
  }

  func testDueAndWake() {
    let items = [ev("a", start: 900), ev("b", start: 3600)]
    XCTAssertEqual(CalendarReminder.due(items, now: t0, shown: []).map(\.id), [])
    XCTAssertEqual(CalendarReminder.nextWake(items, now: t0, shown: []), at(300))
    XCTAssertEqual(CalendarReminder.due(items, now: at(300), shown: []).map(\.id), ["a"])
    XCTAssertEqual(CalendarReminder.due(items, now: at(300), shown: ["a"]).map(\.id), [])
    XCTAssertEqual(CalendarReminder.nextWake(items, now: at(300), shown: ["a"]), at(3000))
    XCTAssertEqual(CalendarReminder.due(items, now: at(1000), shown: []).map(\.id), [],
      "a started already: no late reminder")
  }

  func testUntilText() {
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 600), now: t0).digits, "10")
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 61), now: t0).digits, "2")
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 7300), now: t0).unit, "sa")
  }

  // MARK: Timer

  func testTimerCycle() {
    var tm = FocusTimer(duration: 100)
    tm.toggle(at: at(0))
    XCTAssertEqual(tm.remaining(at: at(40)), 60)
    tm.toggle(at: at(40))
    XCTAssertEqual(tm.remaining(at: at(500)), 60, "paused time does not run")
    tm.toggle(at: at(500))
    XCTAssertFalse(tm.settle(at: at(559)))
    XCTAssertTrue(tm.settle(at: at(560)))
    XCTAssertFalse(tm.settle(at: at(561)), "the finished edge fires once")
    XCTAssertEqual(tm.progress(at: at(561)), 1)
    tm.reset()
    XCTAssertEqual(tm.state, .idle)
  }

  // MARK: Battery

  func testBatteryEdges() {
    var b = BatteryEdges()
    XCTAssertNil(b.update(PowerReading(onAC: false, charging: false, percent: 30)))
    XCTAssertEqual(b.update(PowerReading(onAC: true, charging: true, percent: 30)),
      .pluggedIn(percent: 30))
    XCTAssertNil(b.update(PowerReading(onAC: true, charging: true, percent: 31)))
    XCTAssertNil(b.update(PowerReading(onAC: false, charging: false, percent: 12)))
    XCTAssertEqual(
      b.update(PowerReading(onAC: false, charging: false, percent: 10)), .low(percent: 10))
    XCTAssertNil(b.update(PowerReading(onAC: false, charging: false, percent: 9)),
      "hovering at the mark does not repeat")
    XCTAssertNil(b.update(PowerReading(onAC: false, charging: false, percent: 11)))
    XCTAssertNil(b.update(PowerReading(onAC: false, charging: false, percent: 10)))
  }
}

final class NowPlayingTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 5000)

  func testParsesNotification() {
    let info: [AnyHashable: Any] = [
      "Player State": "Playing", "Track ID": "spotify:track:1", "Name": "Şarkı",
      "Artist": "Sanatçı", "Duration": NSNumber(value: 200_000),
      "Playback Position": NSNumber(value: 30.5),
    ]
    let n = NowPlaying.spotify(info, at: t0)
    XCTAssertEqual(n?.title, "Şarkı")
    XCTAssertEqual(n?.duration, 200)
    XCTAssertEqual(n?.position(at: t0.addingTimeInterval(10)), 40.5)
    XCTAssertNil(NowPlaying.spotify(["Player State": "Stopped"], at: t0))
  }

  func testPausedDoesNotAdvanceAndClampsToDuration() {
    var n = NowPlaying(
      trackID: "x", title: "", artist: "", duration: 100, position: 95, isPlaying: true,
      readAt: t0)
    XCTAssertEqual(n.position(at: t0.addingTimeInterval(30)), 100)
    n.isPlaying = false
    XCTAssertEqual(n.position(at: t0.addingTimeInterval(30)), 95)
  }

  func testParsesScriptReplyWithDecimalComma() {
    let n = NowPlaying.spotifyScript(
      "playing\nŞarkı\nSanatçı\n215000\n12,75\nspotify:track:9", at: t0)
    XCTAssertEqual(n?.position, 12.75)
    XCTAssertEqual(n?.duration, 215)
    XCTAssertNil(NowPlaying.spotifyScript("stopped", at: t0))
    XCTAssertEqual(NowPlaying.clock(65), "1:05")
  }
}
