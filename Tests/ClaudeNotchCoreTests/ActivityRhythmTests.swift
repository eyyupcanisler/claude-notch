import Foundation
import XCTest

@testable import ClaudeNotchCore

final class ActivityRhythmTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1000)

  func testCountsIntoSlots() {
    var r = ActivityRhythm(start: t0)
    r.record(at: t0)
    r.record(at: t0.addingTimeInterval(1))
    r.record(at: t0.addingTimeInterval(12))
    XCTAssertEqual(Array(r.counts.prefix(3)), [2, 0, 1])
    XCTAssertEqual(r.total, 3)
    XCTAssertEqual(r.reading(at: t0.addingTimeInterval(12)).used, 3)
  }

  func testLongTurnMergesSlotsAndKeepsTotal() {
    var r = ActivityRhythm(start: t0)
    for i in 0..<130 { r.record(at: t0.addingTimeInterval(Double(i) * 8.6)) }
    XCTAssertEqual(r.total, 130)
    XCTAssertEqual(r.counts.reduce(0, +), 130)
    XCTAssertEqual(r.counts.count, ActivityRhythm.slots)
    XCTAssertEqual(r.slotWidth, 40)
  }

  func testReadingAdvancesWithoutEvents() {
    var r = ActivityRhythm(start: t0)
    r.record(at: t0)
    let later = r.reading(at: t0.addingTimeInterval(200))
    XCTAssertEqual(later.counts.reduce(0, +), 1)
    XCTAssertEqual(later.used, 21, "200 s at 10 s per slot after one merge")
    XCTAssertEqual(r.slotWidth, 5, "reading never mutates the stored rhythm")
  }

  func testDistinctAgents() {
    var r = ActivityRhythm(start: t0)
    r.record(at: t0, agentID: "a")
    r.record(at: t0, agentID: "a")
    r.record(at: t0, agentID: "b")
    r.record(at: t0)
    XCTAssertEqual(r.agentIDs.count, 2)
  }
}
