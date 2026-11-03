import XCTest
@testable import ClaudeNotchCore

final class RelativeTimeTests: XCTestCase {
  func testBoundaries() {
    XCTAssertEqual(RelativeTime.short(-5), "şimdi")
    XCTAssertEqual(RelativeTime.short(9), "şimdi")
    XCTAssertEqual(RelativeTime.short(10), "10 sn önce")
    XCTAssertEqual(RelativeTime.short(59), "59 sn önce")
    XCTAssertEqual(RelativeTime.short(60), "1 dk önce")
    XCTAssertEqual(RelativeTime.short(3599), "59 dk önce")
    XCTAssertEqual(RelativeTime.short(3600), "1 sa önce")
    XCTAssertEqual(RelativeTime.short(86_399), "23 sa önce")
    XCTAssertEqual(RelativeTime.short(86_400), "1 gün önce")
  }
}
