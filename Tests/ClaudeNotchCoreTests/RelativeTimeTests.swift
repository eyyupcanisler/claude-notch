import XCTest
@testable import ClaudeNotchCore

final class RelativeTimeTests: XCTestCase {
  func testBoundaries() {
    XCTAssertEqual(RelativeTime.short(-5), "now")
    XCTAssertEqual(RelativeTime.short(9), "now")
    XCTAssertEqual(RelativeTime.short(10), "10 s ago")
    XCTAssertEqual(RelativeTime.short(59), "59 s ago")
    XCTAssertEqual(RelativeTime.short(60), "1 min ago")
    XCTAssertEqual(RelativeTime.short(3599), "59 min ago")
    XCTAssertEqual(RelativeTime.short(3600), "1 h ago")
    XCTAssertEqual(RelativeTime.short(86_399), "23 h ago")
    // Key form without the stringsdict; LocalizationTests checks "1 day ago".
    XCTAssertEqual(RelativeTime.short(86_400), "1 days ago")
  }
}
