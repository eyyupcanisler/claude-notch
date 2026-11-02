import Foundation
import XCTest

@testable import ClaudeNotchCore

final class HTTPParserTests: XCTestCase {
  private func request(_ body: String, extra: String = "") -> Data {
    let head = "POST /event?x=1 HTTP/1.1\r\nHost: localhost\r\nX-Term-Program: ghostty\r\n"
      + "Content-Length: \(body.utf8.count)\r\n\(extra)\r\n"
    return Data((head + body).utf8)
  }

  func testSimpleRequest() {
    var p = HTTPRequestParser()
    guard case .complete(let r) = p.feed(request(#"{"a":1}"#)) else {
      return XCTFail("expected complete")
    }
    XCTAssertEqual(r.method, "POST")
    XCTAssertEqual(r.path, "/event")
    XCTAssertEqual(r.target, "/event?x=1")
    XCTAssertEqual(r.header("x-term-program"), "ghostty")
    XCTAssertEqual(r.header("X-Term-Program"), "ghostty")
    XCTAssertEqual(String(decoding: r.body, as: UTF8.self), #"{"a":1}"#)
  }

  func testGetWithoutBody() {
    var p = HTTPRequestParser()
    let data = Data("GET /debug/state HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    guard case .complete(let r) = p.feed(data) else { return XCTFail("expected complete") }
    XCTAssertEqual(r.method, "GET")
    XCTAssertTrue(r.body.isEmpty)
  }

  func testByteByByteSplit() {
    var p = HTTPRequestParser()
    let data = request(#"{"hello":"world"}"#)
    var result: HTTPRequestParser.Outcome = .needMore
    for (i, b) in data.enumerated() {
      result = p.feed(Data([b]))
      if i < data.count - 1 { XCTAssertEqual(result, .needMore) }
    }
    guard case .complete(let r) = result else { return XCTFail("expected complete") }
    XCTAssertEqual(String(decoding: r.body, as: UTF8.self), #"{"hello":"world"}"#)
  }

  func testLargeBodySplitAcrossReads() {
    let big = String(repeating: "x", count: 200_000)
    let body = #"{"tool_input":{"content":"\#(big)"}}"#
    let data = request(body, extra: "Expect: 100-continue\r\n")
    var p = HTTPRequestParser()
    var result: HTTPRequestParser.Outcome = .needMore
    var offset = 0
    while offset < data.count {
      let end = min(offset + 16 * 1024 + 7, data.count)
      result = p.feed(data.subdata(in: offset..<end))
      offset = end
      if offset < data.count { XCTAssertEqual(result, .needMore) }
    }
    guard case .complete(let r) = result else { return XCTFail("expected complete") }
    XCTAssertEqual(r.body.count, body.utf8.count)
    XCTAssertEqual(r.header("expect"), "100-continue")
  }

  func testSeparatorSplitAcrossReads() {
    var p = HTTPRequestParser()
    XCTAssertEqual(p.feed(Data("POST /event HTTP/1.1\r\nContent-Length: 2\r\n\r".utf8)), .needMore)
    XCTAssertEqual(p.feed(Data("\n{".utf8)), .needMore)
    guard case .complete(let r) = p.feed(Data("}".utf8)) else { return XCTFail("complete") }
    XCTAssertEqual(r.body, Data("{}".utf8))
  }

  func testChunkedBody() {
    var p = HTTPRequestParser()
    let head = "POST /event HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
    XCTAssertEqual(p.feed(Data(head.utf8)), .needMore)
    XCTAssertEqual(p.feed(Data("5\r\nhello\r\n".utf8)), .needMore)
    guard case .complete(let r) = p.feed(Data("6\r\n world\r\n0\r\n\r\n".utf8)) else {
      return XCTFail("complete")
    }
    XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world")
  }

  func testMalformedContentLength() {
    var p = HTTPRequestParser()
    let out = p.feed(Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8))
    XCTAssertEqual(out, .failed(.malformed("content-length")))
  }

  func testHeadersTooLarge() {
    var p = HTTPRequestParser()
    let out = p.feed(Data(repeating: 0x61, count: HTTPRequestParser.maxHeaderBytes + 10))
    XCTAssertEqual(out, .failed(.headersTooLarge))
  }

  func testResponseBuild() {
    let r = String(decoding: HTTPResponse.build(status: 200, body: Data("{}".utf8)), as: UTF8.self)
    XCTAssertTrue(r.hasPrefix("HTTP/1.1 200 OK\r\n"))
    XCTAssertTrue(r.contains("Content-Length: 2\r\n"))
    XCTAssertTrue(r.hasSuffix("\r\n\r\n{}"))
    let empty = String(decoding: HTTPResponse.build(status: 200), as: UTF8.self)
    XCTAssertTrue(empty.contains("Content-Length: 0\r\n"))
  }
}
