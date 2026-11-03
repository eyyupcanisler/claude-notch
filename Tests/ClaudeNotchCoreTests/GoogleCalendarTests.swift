import Foundation
import XCTest

@testable import ClaudeNotchCore

final class GoogleCalendarTests: XCTestCase {
  func testClientJSON() {
    let json =
      #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","client_secret":"s"}}"#
    XCTAssertEqual(
      GoogleCalendar.Client.parse(Data(json.utf8)),
      .init(clientID: "123-abc.apps.googleusercontent.com", clientSecret: "s"))
    XCTAssertNil(GoogleCalendar.Client.parse(Data(#"{"installed":{"client_id":"x"}}"#.utf8)))
  }

  func testPKCEMatchesRFCExample() {
    // RFC 7636 appendix B.
    XCTAssertEqual(
      GoogleCalendar.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    XCTAssertGreaterThanOrEqual(GoogleCalendar.makeVerifier().count, 43)
  }

  func testCallback() {
    XCTAssertEqual(
      GoogleCalendar.callback(requestLine: "GET /?state=abc&code=4%2F0X HTTP/1.1", state: "abc"),
      .code("4/0X"))
    XCTAssertEqual(
      GoogleCalendar.callback(requestLine: "GET /?state=zzz&code=c HTTP/1.1", state: "abc"),
      .error("state_mismatch"))
    XCTAssertEqual(
      GoogleCalendar.callback(requestLine: "GET /?error=access_denied HTTP/1.1", state: "abc"),
      .error("access_denied"))
    XCTAssertEqual(
      GoogleCalendar.callback(requestLine: "GET /favicon.ico HTTP/1.1", state: "abc"), .ignore)
  }

  func testTokensKeepRefresh() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let r = #"{"access_token":"a2","expires_in":3599,"token_type":"Bearer"}"#
    let t = GoogleCalendar.Tokens.parse(Data(r.utf8), at: t0, keeping: "r1")
    XCTAssertEqual(t?.refreshToken, "r1")
    XCTAssertEqual(t?.isFresh(at: t0.addingTimeInterval(3000)), true)
    XCTAssertEqual(t?.isFresh(at: t0.addingTimeInterval(3560)), false)
  }

  func testEventsParse() {
    let json = """
      {"items":[
        {"id":"e1","summary":"Tasarım","status":"confirmed",
         "start":{"dateTime":"2026-11-03T11:00:00+03:00"},
         "end":{"dateTime":"2026-11-03T11:30:00+03:00"},
         "hangoutLink":"https://meet.google.com/abc-defg-hij"},
        {"id":"e2","summary":"İzin","start":{"date":"2026-11-04"},"end":{"date":"2026-11-05"}},
        {"id":"e3","status":"cancelled","start":{"dateTime":"2026-11-03T12:00:00Z"},
         "end":{"dateTime":"2026-11-03T13:00:00Z"}},
        {"id":"e4","summary":"Reddettim","start":{"dateTime":"2026-11-03T14:00:00Z"},
         "end":{"dateTime":"2026-11-03T15:00:00Z"},
         "attendees":[{"self":true,"responseStatus":"declined"}]},
        {"id":"e5","summary":"Zoom","start":{"dateTime":"2026-11-03T16:00:00Z"},
         "end":{"dateTime":"2026-11-03T17:00:00Z"},
         "conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://zoom.us/j/1"}]}}
      ]}
      """
    let items = GoogleCalendar.events(Data(json.utf8), calendarID: "me@x.com")
    XCTAssertEqual(items.map(\.title), ["Tasarım", "İzin", "Zoom"])
    XCTAssertEqual(items[0].joinURL?.host, "meet.google.com")
    XCTAssertEqual(items[0].start, Date(timeIntervalSince1970: 1_793_692_800))
    XCTAssertTrue(items[1].isAllDay)
    XCTAssertEqual(items[2].joinURL?.host, "zoom.us")
    XCTAssertEqual(items[0].id, "g:me@x.com:e1")
  }

  func testReminders() {
    let json = """
      {"items":[
        {"id":"d","summary":"Varsayılan","start":{"dateTime":"2026-11-03T11:00:00Z"},
         "end":{"dateTime":"2026-11-03T12:00:00Z"},"reminders":{"useDefault":true}},
        {"id":"o","summary":"Özel","start":{"dateTime":"2026-11-03T11:00:00Z"},
         "end":{"dateTime":"2026-11-03T12:00:00Z"},
         "reminders":{"useDefault":false,"overrides":[{"method":"popup","minutes":60},
           {"method":"email","minutes":1440}]}},
        {"id":"n","summary":"Yok","start":{"dateTime":"2026-11-03T11:00:00Z"},
         "end":{"dateTime":"2026-11-03T12:00:00Z"},"reminders":{"useDefault":false}}
      ]}
      """
    let items = GoogleCalendar.events(Data(json.utf8), calendarID: "c", defaultReminders: [10])
    XCTAssertEqual(items.map(\.alerts), [[600], [3600], []])
    let list =
      #"{"items":[{"id":"c","primary":true,"defaultReminders":[{"method":"popup","minutes":30}]}]}"#
    XCTAssertEqual(GoogleCalendar.calendars(Data(list.utf8)).first?.defaultReminders, [30])
  }

  func testCalendarList() {
    let json = #"{"items":[{"id":"a","primary":true},{"id":"b","selected":true},{"id":"c"}]}"#
    XCTAssertEqual(GoogleCalendar.calendarIDs(Data(json.utf8)), ["a", "b"])
  }
}
