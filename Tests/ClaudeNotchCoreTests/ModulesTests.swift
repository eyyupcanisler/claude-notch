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

  func testDueAndWakeWithDefaultLead() {
    let items = [ev("a", start: 900), ev("b", start: 3600)]
    XCTAssertEqual(CalendarReminder.due(items, now: t0, shown: []).items.map(\.id), [])
    XCTAssertEqual(CalendarReminder.nextWake(items, now: t0, shown: []), at(300))
    let d = CalendarReminder.due(items, now: at(300), shown: [])
    XCTAssertEqual(d.items.map(\.id), ["a"])
    XCTAssertEqual(CalendarReminder.due(items, now: at(300), shown: d.keys).items.map(\.id), [])
    XCTAssertEqual(CalendarReminder.nextWake(items, now: at(300), shown: d.keys), at(3000))
    XCTAssertEqual(CalendarReminder.due(items, now: at(1000), shown: []).items.map(\.id), [],
      "a started already: no late reminder")
  }

  func testEventOwnAlerts() {
    var a = ev("a", start: 7200)
    a.alerts = [3600, 600]
    var silent = ev("s", start: 7200)
    silent.alerts = []
    let items = [a, silent]
    XCTAssertEqual(CalendarReminder.nextWake(items, now: t0, shown: []), at(3600))
    let first = CalendarReminder.due(items, now: at(3600), shown: [])
    XCTAssertEqual(first.items.map(\.id), ["a"], "1 h before; the silent event never")
    XCTAssertEqual(CalendarReminder.nextWake(items, now: at(3600), shown: first.keys), at(6600))
    let second = CalendarReminder.due(items, now: at(6600), shown: first.keys)
    XCTAssertEqual(second.items.map(\.id), ["a"], "10 min before, again")
    // App started late: both passed, only one note.
    let late = CalendarReminder.due(items, now: at(6700), shown: [])
    XCTAssertEqual(late.items.count, 1)
    XCTAssertEqual(late.keys.count, 2)
    // Off: always the default lead.
    XCTAssertEqual(
      CalendarReminder.alertTimes(a, useEventAlerts: false), [at(7200 - CalendarReminder.lead)])
  }

  func testUntilText() {
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 600), now: t0).digits, "10")
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 61), now: t0).digits, "2")
    XCTAssertEqual(CalendarReminder.untilText(ev("a", start: 7300), now: t0).unit, "h")
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

final class ShelfTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 9000)
  private func text(_ id: String, _ s: String) -> ShelfItem {
    ShelfItem(id: id, kind: .text(s), addedAt: t0)
  }
  private func image(_ id: String, key: String) -> ShelfItem {
    ShelfItem(
      id: id, kind: .image(file: URL(fileURLWithPath: "/tmp/\(id).png"), key: key, width: 10,
        height: 10), addedAt: t0)
  }

  func testCapacityEvictsOldestAndReturnsIt() {
    var s = Shelf()
    for i in 0..<Shelf.capacity { s.add(image("\(i)", key: "k\(i)")) }
    let gone = s.add(text("new", "merhaba"))
    XCTAssertEqual(s.items.count, Shelf.capacity)
    XCTAssertEqual(s.items.first?.id, "new")
    XCTAssertEqual(gone.map(\.id), ["0"])
  }

  func testDuplicateMovesToFront() {
    var s = Shelf()
    s.add(text("a", "bir"))
    s.add(text("b", "iki"))
    let gone = s.add(text("c", "bir"))
    XCTAssertEqual(s.items.map(\.id), ["c", "b"])
    XCTAssertEqual(gone.map(\.id), [], "text owns no file")
    let goneImage = s.add(image("d", key: "same"))
    XCTAssertTrue(goneImage.isEmpty)
    XCTAssertEqual(s.add(image("e", key: "same")).map(\.id), ["d"], "old temp file can go")
  }

  func testSkipsConcealedAndKeepsText() {
    XCTAssertTrue(
      Shelf.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    XCTAssertFalse(Shelf.shouldSkip(types: ["public.png"]))
    XCTAssertNil(Shelf.keepText("  \n "))
    XCTAssertEqual(Shelf.keepText("\n selam \n"), "selam")
  }

  func testExpiryBoundaryIsThreeDays() {
    let item = text("a", "bir")
    let threeDays: TimeInterval = 3 * 24 * 60 * 60
    XCTAssertEqual(Shelf.lifetime, threeDays)
    XCTAssertFalse(Shelf.isExpired(item, at: t0))
    XCTAssertFalse(Shelf.isExpired(item, at: t0.addingTimeInterval(threeDays - 1)))
    XCTAssertTrue(Shelf.isExpired(item, at: t0.addingTimeInterval(threeDays)))
    XCTAssertTrue(Shelf.isExpired(item, at: t0.addingTimeInterval(threeDays + 3600)))
  }

  func testRemoveExpiredKeepsNewerItems() {
    var s = Shelf()
    let day: TimeInterval = 24 * 60 * 60
    s.add(text("old", "eski"))
    s.add(image("oldImage", key: "k"))
    s.add(ShelfItem(id: "new", kind: .text("yeni"), addedAt: t0.addingTimeInterval(2 * day)))
    XCTAssertTrue(s.removeExpired(at: t0.addingTimeInterval(3 * day - 1)).isEmpty)
    XCTAssertEqual(s.items.count, 3)
    let gone = s.removeExpired(at: t0.addingTimeInterval(3 * day))
    XCTAssertEqual(Set(gone.map(\.id)), ["old", "oldImage"])
    XCTAssertEqual(gone.compactMap(\.ownedFile).count, 1, "the image's temp file can go")
    XCTAssertEqual(s.items.map(\.id), ["new"])
  }
}

final class WeatherTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func testParsesForecastAndRainSoon() {
    let json = """
      {"current":{"temperature_2m":13.6,"weather_code":2,"is_day":1},
       "hourly":{"time":[1800000000,1800003600,1800007200,1800010800],
                 "precipitation_probability":[10,30,70,null]}}
      """
    let w = WeatherNow.openMeteo(Data(json.utf8), at: t0)
    XCTAssertEqual(w?.degrees, "14°")
    XCTAssertEqual(w?.rainChances.count, 3)
    XCTAssertEqual(w?.rainSoon(now: t0)?.1, 70)
    XCTAssertNil(w?.rainSoon(now: t0, window: 3600))
    XCTAssertEqual(WeatherNow.describe(code: 63, isDay: true).text, "Rainy")
  }

  func testNoRainAlertWhileAlreadyWet() {
    let w = WeatherNow(
      temperature: -2.4, code: 61, isDay: false,
      rainChances: [(t0.addingTimeInterval(1800), 90)], readAt: t0)
    XCTAssertNil(w.rainSoon(now: t0))
    XCTAssertEqual(w.degrees, "-2°")
  }

  func testGeocoding() {
    let json = #"{"results":[{"name":"İstanbul","latitude":41.01,"longitude":28.95}]}"#
    XCTAssertEqual(WeatherPlace.geocoding(Data(json.utf8))?.name, "İstanbul")
    XCTAssertNil(WeatherPlace.geocoding(Data("{}".utf8)))
  }
}

final class PlanUsageTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_738_400_000)

  func testParsesRateLimits() {
    let json = """
      {"model":{"id":"x"},
       "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
       "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
      """
    let u = PlanUsage.statusLine(Data(json.utf8), at: t0)
    XCTAssertEqual(u?.fiveHour?.percent, 23.5)
    XCTAssertEqual(u?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
    XCTAssertNil(PlanUsage.statusLine(Data(#"{"model":{}}"#.utf8), at: t0))
    let later = u?.live(at: Date(timeIntervalSince1970: 1_738_500_000))
    XCTAssertNil(later?.fiveHour, "a passed reset drops the window")
    XCTAssertNotNil(later?.sevenDay)
  }

  /// Claude Code 2.1.325's status line: only the weekly window, nothing else.
  private let weeklyOnly =
    #"{"rate_limits":{"seven_day":{"used_percentage":38,"resets_at":1795068000}}}"#

  func testParsesWeeklyOnlyPayload() {
    let u = PlanUsage.statusLine(Data(weeklyOnly.utf8), at: t0)
    XCTAssertEqual(u?.sevenDay?.percent, 38)
    XCTAssertEqual(u?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_795_068_000))
    XCTAssertNil(u?.fiveHour, "five_hour is absent")
    XCTAssertEqual(u?.primary, u?.sevenDay)
    XCTAssertNil(u?.newMark(shown: []), "38% warns for nothing")
    XCTAssertNil(ContextLeft.statusLine(Data(weeklyOnly.utf8)), "no session, no context")
  }

  func testUnknownKeysAreIgnoredAndWeeklyIsPrimary() {
    let json = """
      {"rate_limits":{"seven_day":{"used_percentage":12,"resets_at":1795068000,"extra":1},
       "five_hour":{"used_percentage":90,"resets_at":1738425600},"seven_day_opus":{}},
       "something_new":{"a":[1,2]}}
      """
    let u = PlanUsage.statusLine(Data(json.utf8), at: t0)
    XCTAssertEqual(u?.primary?.percent, 12, "the weekly window is the main number")
    XCTAssertEqual(u?.fiveHour?.percent, 90, "an older 5-hour window stays as a second value")
    XCTAssertNil(u?.newMark(shown: []), "the 5-hour window never warns")
    let fiveOnly = PlanUsage(
      fiveHour: .init(percent: 40, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
      sevenDay: nil, readAt: t0)
    XCTAssertEqual(fiveOnly.primary?.percent, 40)
  }

  func testWeeklyWarningMarksOncePerWindow() {
    let r = Date(timeIntervalSince1970: 1_795_068_000)
    var u = PlanUsage(fiveHour: nil, sevenDay: .init(percent: 79.9, resetsAt: r), readAt: t0)
    XCTAssertNil(u.newMark(shown: []))
    u.sevenDay?.percent = 80
    let first = u.newMark(shown: [])
    XCTAssertEqual(first?.mark, 80)
    XCTAssertNil(u.newMark(shown: [first!.key]))
    u.sevenDay?.percent = 94.9
    XCTAssertNil(u.newMark(shown: [first!.key]))
    u.sevenDay?.percent = 95
    XCTAssertEqual(u.newMark(shown: [first!.key])?.mark, 95)
    u.sevenDay?.percent = 50
    XCTAssertNil(u.newMark(shown: []))
    u.sevenDay = .init(percent: 85, resetsAt: r.addingTimeInterval(7 * 24 * 3600))
    XCTAssertEqual(u.newMark(shown: [first!.key])?.mark, 80, "a new week warns again")
  }

  /// A file left from before the weekly reset (Claude Code not run since) never warns.
  func testStaleWeeklyWindowGivesNoMark() {
    let r = Date(timeIntervalSince1970: 1_795_068_000)
    let u = PlanUsage(fiveHour: nil, sevenDay: .init(percent: 85, resetsAt: r), readAt: t0)
    XCTAssertEqual(u.live(at: r.addingTimeInterval(-1)).newMark(shown: [])?.mark, 80)
    XCTAssertNil(u.live(at: r).newMark(shown: []), "the reset has passed")
  }

  func testLiveWarningsDropPassedResets() {
    let keys: Set<String> = ["1795068000:80", "1795068000:95", "1738425600:80", "junk"]
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    XCTAssertEqual(PlanUsage.liveWarnings(keys, at: now), ["1795068000:80", "1795068000:95"])
    XCTAssertEqual(
      PlanUsage.liveWarnings(keys, at: Date(timeIntervalSince1970: 1_795_068_000)), [])
  }
}

final class PomodoroTests: XCTestCase {
  func testCycle() {
    var p = Pomodoro()
    XCTAssertEqual(p.round, 1)
    var phases: [Pomodoro.Phase] = []
    for _ in 0..<8 { phases.append(p.advance()) }
    XCTAssertEqual(
      phases,
      [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
    XCTAssertEqual(p.round, 1, "a new set starts after the long break")
    p.advance()
    p.advance()
    XCTAssertEqual(p.round, 2)
    XCTAssertEqual(p.minutes(.longBreak), 15)
    p.reset()
    XCTAssertEqual(p.phase, .focus)
  }
}

final class ContextLeftTests: XCTestCase {
  func testParseAndAlertEdge() {
    let json = #"{"session_id":"s1","context_window":{"remaining_percentage":18.4}}"#
    let c = ContextLeft.statusLine(Data(json.utf8))
    XCTAssertEqual(c, ContextLeft(sessionID: "s1", percent: 18.4))
    XCTAssertNil(ContextLeft.statusLine(Data(#"{"session_id":"s1"}"#.utf8)))
    let low = ContextLeft(sessionID: "s1", percent: 9)
    XCTAssertTrue(low.crossesAlert(from: 12))
    XCTAssertFalse(low.crossesAlert(from: 9.5), "already under the mark")
    XCTAssertFalse(low.crossesAlert(from: nil), "first reading never alerts")
  }
}
