import ClaudeNotchCore
import Foundation
import XCTest

/// The UI strings in Resources/Localization (read from the repo, not from a bundle): en and tr
/// must have the same keys, and every translation must take the same format arguments as its
/// key, or a lookup would print garbage or crash.
final class LocalizationTests: XCTestCase {
  private static let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Localization", isDirectory: true)

  private func table(_ lang: String, _ file: String = "Localizable.strings") throws
    -> [String: String]
  {
    let url = Self.folder.appendingPathComponent("\(lang).lproj/\(file)")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: String], "\(lang)/\(file) is not a strings table")
  }

  /// Format specifiers in argument order (`%%` is a literal and not counted). Positional ones
  /// (`%2$@`) are put in their position's place.
  static func specifiers(_ s: String) -> [String] {
    let pattern = #"%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]"#
    let re = try! NSRegularExpression(pattern: pattern)
    var found: [(position: Int, spec: String)] = []
    for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
      let whole = String(s[Range(m.range, in: s)!])
      guard whole != "%%" else { continue }
      let position = Range(m.range(at: 1), in: s).flatMap { Int(s[$0]) } ?? found.count + 1
      let conversion = whole.replacingOccurrences(
        of: #"^%(\d+\$)?[-+ 0#']*\d*(\.\d+)?"#, with: "", options: .regularExpression)
      found.append((position, conversion))
    }
    return found.sorted { $0.position < $1.position }.map(\.spec)
  }

  func testSpecifierParsing() {
    XCTAssertEqual(Self.specifiers("%@ and %lld%% · %.0f"), ["@", "lld", "f"])
    XCTAssertEqual(Self.specifiers("%2$@ ve %1$lld"), ["lld", "@"])
    XCTAssertEqual(Self.specifiers("%%%lld"), ["lld"])
  }

  func testEnglishAndTurkishHaveTheSameKeysAndFormats() throws {
    let en = try table("en")
    let tr = try table("tr")
    XCTAssertGreaterThan(en.count, 300)
    XCTAssertEqual(Set(en.keys).subtracting(tr.keys).sorted(), [], "missing in tr")
    XCTAssertEqual(Set(tr.keys).subtracting(en.keys).sorted(), [], "missing in en")
    for (key, english) in en {
      let spec = Self.specifiers(key)
      XCTAssertEqual(Self.specifiers(english), spec, "en: \(key)")
      if let turkish = tr[key] {
        XCTAssertEqual(Self.specifiers(turkish), spec, "tr: \(key)")
        XCTAssertFalse(turkish.isEmpty, "tr: \(key)")
      }
    }
  }

  func testEnglishPluralsCoverExistingKeys() throws {
    let en = try table("en")
    let url = Self.folder.appendingPathComponent("en.lproj/Localizable.stringsdict")
    let plurals = try XCTUnwrap(
      NSDictionary(contentsOf: url) as? [String: [String: Any]], "stringsdict unreadable")
    XCTAssertFalse(plurals.isEmpty)
    for (key, entry) in plurals {
      XCTAssertNotNil(en[key], "plural for an unknown key: \(key)")
      XCTAssertNotNil(entry["NSStringLocalizedFormatKey"] as? String, key)
    }
  }

  func testTurkishInfoPlistStrings() throws {
    let tr = try table("tr", "InfoPlist.strings")
    XCTAssertEqual(
      Set(tr.keys),
      ["NSAppleEventsUsageDescription", "NSCalendarsFullAccessUsageDescription",
        "NSHumanReadableCopyright"])
  }

  /// Looks the strings up the way the app does, from a throwaway bundle holding the repo's
  /// en.lproj: English plurals read right ("1 day" / "2 days").
  func testEnglishPluralsResolve() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClaudeNotchLoc-\(UUID().uuidString).bundle", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.folder.appendingPathComponent("en.lproj"),
      to: resources.appendingPathComponent("en.lproj"))
    let info: [String: Any] = [
      "CFBundleIdentifier": "test.claudenotch.loc", "CFBundleDevelopmentRegion": "en",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: root.appendingPathComponent("Contents/Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: root))

    func en(_ value: String.LocalizationValue) -> String {
      String(localized: value, bundle: bundle, locale: Locale(identifier: "en"))
    }
    XCTAssertEqual(en("\(1) days ago"), "1 day ago")
    XCTAssertEqual(en("\(3) days ago"), "3 days ago")
    XCTAssertEqual(en("\(1) permissions"), "1 permission")
    XCTAssertEqual(en("\(2) sessions done · \(1) errors"), "2 sessions done · 1 error")
    XCTAssertEqual(en("\(1) sessions done · \(2) errors"), "1 session done · 2 errors")
    XCTAssertEqual(en("content (\(1) characters): \("x")"), "content (1 character): x")
    XCTAssertEqual(en("context \(12)%"), "context 12%")
  }

  /// The Turkish table gives the original Turkish text with the arguments in place.
  func testTurkishLookup() throws {
    let tr = try table("tr")
    let format = try XCTUnwrap(tr["%lld sessions done · %lld errors"])
    XCTAssertEqual(String(format: format, 2, 1), "2 oturum bitti · 1 hata")
    XCTAssertEqual(String(format: try XCTUnwrap(tr["context %lld%%"]), 12), "bağlam %12")
    XCTAssertEqual(tr["Allow"], "İzin ver")
  }

  /// The plan usage alert, the shelf caption and the debug focus error keep the original
  /// (b82423e) Turkish wording.
  func testRestoredOriginalTurkishTexts() throws {
    let tr = try table("tr")
    XCTAssertEqual(tr["5-hour limit at 80%"], "5 saatlik limitin %80’i doldu")
    XCTAssertEqual(tr["5-hour limit almost used up"], "5 saatlik limit dolmak üzere")
    XCTAssertEqual(
      String(format: try XCTUnwrap(tr["Resets at %@"]), "14:30"), "14:30’de sıfırlanır")
    // The debug focus route's error for an unknown session.
    XCTAssertEqual(tr["no such session"], "yok")
    let caption = ShelfExpiry.settingsHelp(expiry: .never, deletePinsWhenOff: false)
      .replacingOccurrences(
        of: " Pinned items stay on disk; turning the shelf off does not delete them.", with: "")
    XCTAssertEqual(
      tr[caption],
      "Pano saniyede bir kontrol edilir; şifre yöneticilerinin gizli kopyaları alınmaz. Raf geçici klasörde durur, kapatınca silinir.")
  }

  /// The sanitizer's long-space marker is localized ("⟨6 spaces⟩" / "⟨6 boşluk⟩"); the risk
  /// check undoes either one, so a command shown in either language is classified the same.
  func testSpaceMarkerIsUndoneInBothLanguages() {
    for marker in ["⟨6 spaces⟩", "⟨6 boşluk⟩"] {
      XCTAssertEqual(
        RiskClassifier.risk(toolName: "Bash", text: "rm\(marker)-rf /tmp/x"), "rm -rf", marker)
    }
  }

  /// Counts of 1000 or more: the sanitizer prints plain digits (String(localized:) would group
  /// an integer argument as "1,234"), and the risk check still undoes a grouped count.
  func testLongSpaceRunMarkerHasPlainDigits() {
    let raw = "rm" + String(repeating: " ", count: 1234) + "-rf /tmp/x"
    let shown = ToolSummary.sanitize(raw)
    XCTAssertEqual(shown, "rm⟨1234 spaces⟩-rf /tmp/x")
    XCTAssertEqual(RiskClassifier.risk(toolName: "Bash", text: shown), "rm -rf")
    for marker in ["⟨1,234 spaces⟩", "⟨1.234 boşluk⟩", "⟨1\u{202F}234 spaces⟩", "⟨1\u{A0}234 boşluk⟩"] {
      XCTAssertEqual(
        RiskClassifier.risk(toolName: "Bash", text: "rm\(marker)-rf /tmp/x"), "rm -rf", marker)
    }
  }

  /// Error codes and image sizes are passed as text, so their keys take `%@` and no locale
  /// adds a thousands separator to them.
  func testCodesAndSizesArePlainText() throws {
    let tr = try table("tr")
    let image = try XCTUnwrap(tr["Image · %@×%@"])
    XCTAssertEqual(String(format: image, String(2940), String(1912)), "Görüntü · 2940×1912")
    let error = try XCTUnwrap(
      tr["The shortcut could not be registered (error %@); the previous one stays."])
    XCTAssertTrue(String(format: error, String(-9878)).contains("(hata -9878)"))
  }

  /// A fresh install (nothing saved) follows the Mac: main.swift writes AppleLanguages = ["tr"]
  /// into the app domain when the Mac's first language is Turkish, ["en"] for any other first
  /// language. Türkçe and English write their own language whatever the Mac uses.
  func testFreshInstallFollowsTheMacLanguage() throws {
    let scratch = try ScratchDefaults("test.claudenotch.language")
    let defaults = scratch.defaults
    defer { scratch.remove() }
    XCTAssertEqual(LanguageChoice.defaultsKey, "language")
    let fresh = LanguageChoice(stored: defaults.string(forKey: LanguageChoice.defaultsKey))
    XCTAssertEqual(fresh, .system)
    XCTAssertEqual(LanguageChoice(stored: "klingon"), .system)
    XCTAssertEqual(LanguageChoice(stored: "system"), .system)

    // Turkish Mac → Turkish.
    fresh.apply(to: defaults, macPreferred: ["tr-TR", "en-US"])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["tr"])
    // English Mac (also one with Turkish second, like en-TR + tr-TR) → English.
    fresh.apply(to: defaults, macPreferred: ["en-TR", "tr-TR"])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    // Any other first language → English, even with Turkish second.
    fresh.apply(to: defaults, macPreferred: ["de-DE", "tr-TR"])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    fresh.apply(to: defaults, macPreferred: [])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

    defaults.set("tr", forKey: LanguageChoice.defaultsKey)
    let turkish = LanguageChoice(stored: defaults.string(forKey: LanguageChoice.defaultsKey))
    XCTAssertEqual(turkish, .turkish)
    turkish.apply(to: defaults, macPreferred: ["en-US"])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["tr"])

    defaults.set("en", forKey: LanguageChoice.defaultsKey)
    let english = LanguageChoice(stored: defaults.string(forKey: LanguageChoice.defaultsKey))
    XCTAssertEqual(english, .english)
    english.apply(to: defaults, macPreferred: ["tr-TR"])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }

  /// Only the first of the Mac's languages counts, in any spelling macOS uses.
  func testSystemCodeReadsTheFirstMacLanguage() {
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["tr"]), "tr")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["tr-TR"]), "tr")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["TR_tr"]), "tr")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["en-GB", "tr-TR"]), "en")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["de-DE"]), "en")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: ["trv"]), "en", "Taroko is not Turkish")
    XCTAssertEqual(LanguageChoice.systemCode(macPreferred: []), "en")
  }

  /// Character counts print plain digits ("12345"), as the original interpolation did; a
  /// plain `loc` would group them for the locale.
  func testCharacterCountsArePlainDigits() {
    XCTAssertEqual(
      locPlainDigits("Show all (\(12345) characters)"), "Show all (12345 characters)")
    let collapsed = ToolSummary.collapsed(String(repeating: "a", count: 1500))
    XCTAssertTrue(collapsed.contains("[1280 characters hidden]"), collapsed)
  }
}
