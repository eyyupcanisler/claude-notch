import Foundation
import XCTest

@testable import ClaudeNotchCore

/// macOS's own Do Not Disturb store (~/Library/DoNotDisturb/DB/Assertions.json): a Focus is on
/// while `data[*].storeAssertionRecords` holds at least one record. Anything the app cannot
/// make sense of is "unknown", and then only the Shortcuts value counts.
final class SystemFocusTests: XCTestCase {
  /// One active assertion, shaped like the file macOS 26 writes when Do Not Disturb is turned
  /// on in Control Center (plus an ended one in the invalidation records).
  private let oneRecord = """
    {"data": [{
      "storeAssertionRecords": [{
        "assertionUUID": "7C3426E3-8479-4394-AAA8-C25A316C33D0",
        "assertionSource": {"assertionClientIdentifier": "com.apple.controlcenter.dnd"},
        "assertionStartDateTimestamp": 816593343.455644,
        "assertionDetails": {
          "assertionDetailsIdentifier": "com.apple.controlcenter.dnd",
          "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.default",
          "assertionDetailsReason": "user-action"
        }
      }],
      "storeInvalidationRecords": [{
        "invalidationAssertion": {"assertionUUID": "D34C9FA7-BE66-4317-80CA-35280A0C01FC"},
        "invalidationReason": "user-changed-state"
      }],
      "storeInvalidationRequestRecords": []
    }], "header": {"version": 8, "timestamp": 816593343.457262}}
    """

  private func state(_ json: String) -> SystemFocusState {
    SystemFocus.state(of: Data(json.utf8))
  }

  func testOneAssertionRecordIsOn() {
    XCTAssertEqual(state(oneRecord), .on)
  }

  func testAnyFocusModeCountsNotOnlyDoNotDisturb() {
    let work = """
      {"data": [{"storeAssertionRecords": [{"assertionDetails":
        {"assertionDetailsModeIdentifier": "com.apple.focus.work"}}]}]}
      """
    XCTAssertEqual(state(work), .on)
  }

  func testNoAssertionRecordsIsOff() {
    XCTAssertEqual(state(#"{"data": [{"storeAssertionRecords": []}]}"#), .off)
    // Only ended assertions (Do Not Disturb was on earlier and is off now).
    XCTAssertEqual(
      state(#"{"data": [{"storeInvalidationRecords": [{"invalidationReason": "user-changed-state"}]}]}"#),
      .off, "no storeAssertionRecords key: nothing is asserted")
    XCTAssertEqual(state(#"{"data": []}"#), .off)
  }

  func testRecordsInAnyEntryCount() {
    let json = #"{"data": [{"storeAssertionRecords": []}, {"storeAssertionRecords": [{}]}]}"#
    XCTAssertEqual(state(json), .on)
  }

  func testMissingOrMalformedFileIsUnknown() {
    XCTAssertEqual(SystemFocus.state(of: nil), .unknown, "missing or not readable")
    XCTAssertEqual(state(""), .unknown)
    XCTAssertEqual(state("not json"), .unknown)
    XCTAssertEqual(state("[]"), .unknown, "root is not an object")
    XCTAssertEqual(state(#"{"header": {"version": 8}}"#), .unknown, "no data")
    XCTAssertEqual(state(#"{"data": {"storeAssertionRecords": []}}"#), .unknown, "data not a list")
    XCTAssertEqual(state(#"{"data": ["x"]}"#), .unknown, "an entry is not an object")
    XCTAssertEqual(
      state(#"{"data": [{"storeAssertionRecords": {"a": 1}}]}"#), .unknown,
      "records not a list")
  }

  func testTheFileLivesInTheUsersDoNotDisturbStore() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    XCTAssertEqual(
      SystemFocus.fileURL(home: home).path,
      "/Users/someone/Library/DoNotDisturb/DB/Assertions.json")
    XCTAssertEqual(SystemFocus.recheckInterval, 30)
  }

  /// Focus counts as on when macOS says so or the Shortcuts value does; a file the app cannot
  /// read leaves the Shortcuts value alone in charge.
  func testEffectiveFocusIsTheFileOrTheShortcutsValue() {
    XCTAssertTrue(FocusIslands.effective(system: .on, shortcuts: false))
    XCTAssertTrue(FocusIslands.effective(system: .on, shortcuts: true))
    XCTAssertFalse(FocusIslands.effective(system: .off, shortcuts: false))
    XCTAssertTrue(FocusIslands.effective(system: .off, shortcuts: true), "a manual switch wins")
    XCTAssertFalse(FocusIslands.effective(system: .unknown, shortcuts: false))
    XCTAssertTrue(FocusIslands.effective(system: .unknown, shortcuts: true))
  }

  func testReadableOnlyWhenTheFileSaysSomething() {
    XCTAssertTrue(SystemFocusState.on.readable)
    XCTAssertTrue(SystemFocusState.off.readable)
    XCTAssertFalse(SystemFocusState.unknown.readable)
  }
}
