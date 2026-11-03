import XCTest
@testable import ClaudeNotchCore

final class DotClockTests: XCTestCase {
  func testMinutesAndSeconds() {
    XCTAssertEqual(DotClock.reading(-3), .init(digits: "00:00", unit: nil))
    XCTAssertEqual(DotClock.reading(33), .init(digits: "00:33", unit: nil))
    XCTAssertEqual(DotClock.reading(134), .init(digits: "02:14", unit: nil))
    XCTAssertEqual(DotClock.reading(3599), .init(digits: "59:59", unit: nil))
  }

  func testCoarse() {
    XCTAssertEqual(DotClock.coarse(20), .init(digits: "1", unit: "dk"))
    XCTAssertEqual(DotClock.coarse(754), .init(digits: "12", unit: "dk"))
    XCTAssertEqual(DotClock.coarse(7200), .init(digits: "2", unit: "sa"))
  }

  func testHoursAndDays() {
    XCTAssertEqual(DotClock.reading(3600), .init(digits: "1", unit: "sa"))
    XCTAssertEqual(DotClock.reading(86_399), .init(digits: "23", unit: "sa"))
    XCTAssertEqual(DotClock.reading(86_400), .init(digits: "1", unit: "gün"))
  }
}
