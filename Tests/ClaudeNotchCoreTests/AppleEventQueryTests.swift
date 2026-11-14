import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Raw Apple Event reads: the specifiers AppleScript sends for the same expressions, and the
/// reply flattening the old script runner did.
final class AppleEventQueryTests: XCTestCase {
  private func code(_ s: String) -> FourCharCode { AEQuery.code(s) }

  /// (desired class, key form, key data as a four-char code) of each level, innermost last.
  private func chain(_ spec: NSAppleEventDescriptor) -> [(String, String, String)] {
    var out: [(String, String, String)] = []
    var d: NSAppleEventDescriptor? = spec
    while let s = d, s.descriptorType == code("obj ") {
      let want = s.forKeyword(code("want"))?.typeCodeValue ?? 0
      let form = s.forKeyword(code("form"))?.enumCodeValue ?? 0
      let seld = s.forKeyword(code("seld"))
      var key: FourCharCode = 0
      if let data = seld?.data, data.count == 4 { key = data.withUnsafeBytes { $0.load(as: FourCharCode.self) } }
      out.append((fourCC(want), fourCC(form), fourCC(key)))
      d = s.forKeyword(code("from"))
    }
    XCTAssertEqual(d?.descriptorType, code("null"), "the chain ends at the application")
    return out
  }

  private func fourCC(_ c: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
  }

  func testCode() {
    XCTAssertEqual(code("core"), 0x636F_7265)
    XCTAssertEqual(code("----"), 0x2D2D_2D2D)
  }

  func testGhosttyTitlesAskTtyAndNameOfEveryTerminalOfEveryTabOfEveryWindow() {
    let specs = GhosttyQuery.titles()
    XCTAssertEqual(specs.count, 2)
    for (spec, prop) in zip(specs, ["Gtty", "pnam"]) {
      let c = chain(spec)
      XCTAssertEqual(c.map(\.0), ["prop", "Gtrm", "Gtab", "Gwnd"])
      XCTAssertEqual(c.map(\.1), ["prop", "indx", "indx", "indx"])
      XCTAssertEqual(c.map(\.2), [prop, "all ", "all ", "all "])
      XCTAssertEqual(spec.forKeyword(code("from"))?.forKeyword(code("seld"))?.descriptorType, code("abso"))
    }
  }

  func testGhosttyFocusedTTY() {
    let c = chain(GhosttyQuery.focusedTTY())
    XCTAssertEqual(c.map(\.0), ["prop", "prop", "prop", "prop"])
    XCTAssertEqual(c.map(\.1), ["prop", "prop", "prop", "prop"])
    XCTAssertEqual(c.map(\.2), ["Gtty", "GTfT", "GWsT", "GFWn"])
  }

  func testGetEvent() {
    let spec = GhosttyQuery.focusedTTY()
    let event = AEQuery.get(spec, bundleID: "com.mitchellh.ghostty")
    XCTAssertEqual(event.eventClass, code("core"))
    XCTAssertEqual(event.eventID, code("getd"))
    let direct = event.paramDescriptor(forKeyword: code("----"))
    XCTAssertEqual(direct?.descriptorType, code("obj "))
    XCTAssertEqual(direct?.data, spec.data)
  }

  func testTextsFlattenNestedListsDepthFirst() {
    let list = NSAppleEventDescriptor.list()
    let window1 = NSAppleEventDescriptor.list()
    let tab = NSAppleEventDescriptor.list()
    tab.insert(NSAppleEventDescriptor(string: "/dev/ttys001"), at: 1)
    tab.insert(NSAppleEventDescriptor(typeCode: code("msng")), at: 2)
    window1.insert(tab, at: 1)
    window1.insert(NSAppleEventDescriptor(string: "/dev/ttys002"), at: 2)
    list.insert(window1, at: 1)
    list.insert(NSAppleEventDescriptor.list(), at: 2)
    list.insert(NSAppleEventDescriptor(string: "ş ğ ı"), at: 3)
    let texts = AEQuery.texts(of: list)
    XCTAssertEqual(texts.count, 4)
    XCTAssertEqual(texts[0], "/dev/ttys001")
    XCTAssertEqual(texts[1], "", "a missing value becomes an empty text")
    XCTAssertEqual(texts[2], "/dev/ttys002")
    XCTAssertEqual(texts[3], "ş ğ ı")
    XCTAssertEqual(AEQuery.texts(of: NSAppleEventDescriptor(string: "/dev/ttys9")), ["/dev/ttys9"])
    XCTAssertEqual(AEQuery.texts(of: NSAppleEventDescriptor.list()), [])
  }
}
