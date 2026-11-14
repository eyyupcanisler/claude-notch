import Foundation

/// Looks up a UI string in the app's Localizable.strings (Bundle.main). Keys are the English
/// source text, so a missing translation, or a test run where Bundle.main is the test runner,
/// shows English. Interpolations become format specifiers in the key: `loc("\(n) sessions")`
/// looks up "%lld sessions" (plurals come from Localizable.stringsdict).
public func loc(_ value: String.LocalizationValue) -> String {
  String(localized: value, bundle: .main)
}

/// `loc` with integers printed as plain digits ("1234", not "1.234" / "1,234"), as plain Swift
/// interpolation printed them. The plural rules of the stringsdict still apply: the POSIX
/// locale only changes how the numbers are formatted, not which table is read.
public func locPlainDigits(_ value: String.LocalizationValue) -> String {
  String(localized: value, bundle: .main, locale: Locale(identifier: "en_US_POSIX"))
}

/// The UI language choice (Settings > General > Language). Stored under `defaultsKey`; a fresh
/// install (nothing saved) is Turkish, the app's original language. It takes effect at launch:
/// `main.swift` writes the app-domain `AppleLanguages` from it before any string is looked up,
/// so the UI, the texts sent back to Claude, dates, numbers and the weather search all follow.
public enum LanguageChoice: String, CaseIterable, Sendable {
  case turkish = "tr"
  case english = "en"
  /// The Mac's own preferred languages (no app override).
  case system

  /// UserDefaults key (app domain).
  public static let defaultsKey = "language"
  /// What an install without a saved choice uses: Turkish, the original UI.
  public static let fallback: LanguageChoice = .turkish

  /// The stored raw value, or the fallback when nothing (or something unknown) is stored.
  public init(stored: String?) {
    self = stored.flatMap(Self.init(rawValue:)) ?? Self.fallback
  }

  /// The app-domain `AppleLanguages` this choice writes; nil removes the app's override.
  public var appleLanguages: [String]? {
    switch self {
    case .turkish: return ["tr"]
    case .english: return ["en"]
    case .system: return nil
    }
  }

  /// Writes (or removes) `AppleLanguages` in `appDomain` (the app's own domain, never the
  /// global one). Call before the first localized lookup; a later change needs a restart.
  public func apply(to appDomain: UserDefaults) {
    if let langs = appleLanguages {
      appDomain.set(langs, forKey: "AppleLanguages")
    } else {
      appDomain.removeObject(forKey: "AppleLanguages")
    }
  }
}

/// The language the app's UI resolved to: the one `LanguageChoice` set at launch (Turkish by
/// default), or with "System" the first of the Mac's preferred languages that the app ships
/// (en or tr), English otherwise. Dates, weekday names and weather place names follow
/// it, so they never mix with text in the other language.
public enum AppLanguage {
  /// "en" or "tr".
  public static var code: String {
    let first = Bundle.main.preferredLocalizations.first ?? "en"
    return first.hasPrefix("tr") ? "tr" : "en"
  }

  /// Locale for formatting: the user's own locale (region settings included) when it speaks the
  /// app's language, otherwise the plain language.
  public static var locale: Locale {
    let lang = code
    if Locale.current.language.languageCode?.identifier == lang { return Locale.current }
    return Locale(identifier: lang)
  }
}
