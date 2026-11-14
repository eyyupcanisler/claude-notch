import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Key labels skip the keyboard layout's language only where every language uppercases alike.
final class KeyLabelCaseTests: XCTestCase {
  private let locales = ["en", "tr", "az", "lt", "el", "hy", "nl", "de"].map(Locale.init)

  func testASCIIExceptIUppercasesTheSameInEveryLanguage() {
    let ascii = (32..<127).compactMap(Unicode.Scalar.init).map(String.init)
    for c in ascii where c != "i" {
      XCTAssertFalse(KeyLabelCase.needsLayoutLocale(c), c)
      for locale in locales {
        XCTAssertEqual(c.uppercased(with: locale), c.uppercased(), "\(c) in \(locale.identifier)")
      }
    }
  }

  func testIAndNonASCIIKeepTheLayoutLanguage() {
    XCTAssertTrue(KeyLabelCase.needsLayoutLocale("i"))
    XCTAssertEqual("i".uppercased(with: Locale(identifier: "tr")), "İ")
    for c in ["ı", "ş", "ğ", "ü", "ö", "ç", "ß", "ά", "й", "ﬁ"] {
      XCTAssertTrue(KeyLabelCase.needsLayoutLocale(c), c)
    }
  }
}
