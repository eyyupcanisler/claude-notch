import Foundation

/// Looks up a UI string in the app's Localizable.strings (Bundle.main). Keys are the English
/// source text, so a missing translation, or a test run where Bundle.main is the test runner,
/// shows English. Interpolations become format specifiers in the key: `loc("\(n) sessions")`
/// looks up "%lld sessions" (plurals come from Localizable.stringsdict).
public func loc(_ value: String.LocalizationValue) -> String {
  String(localized: value, bundle: .main)
}

/// The language the app's UI resolved to: the first of the Mac's preferred languages that the
/// app ships (en or tr), English otherwise. Dates, weekday names and weather place names follow
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
