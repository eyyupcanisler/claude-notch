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
/// install (nothing saved) follows the Mac: Turkish when the Mac's first language is Turkish,
/// English otherwise, so a Turkish Mac keeps the app's original Turkish UI. It takes effect at
/// launch: `main.swift` writes the app-domain `AppleLanguages` from it before any string is
/// looked up, so the UI, the texts sent back to Claude, dates, numbers and the weather search
/// all follow.
public enum LanguageChoice: String, CaseIterable, Sendable {
  /// The Mac's first preferred language decides: Turkish → Turkish, anything else → English.
  case system
  case turkish = "tr"
  case english = "en"

  /// UserDefaults key (app domain).
  public static let defaultsKey = "language"
  /// What an install without a saved choice uses: the Mac's language (see `system`).
  public static let fallback: LanguageChoice = .system

  /// The stored raw value, or the fallback when nothing (or something unknown) is stored.
  public init(stored: String?) {
    self = stored.flatMap(Self.init(rawValue:)) ?? Self.fallback
  }

  /// "tr" when the first of the Mac's preferred languages (`macPreferred`, e.g. ["tr-TR",
  /// "en-US"]) is Turkish, otherwise "en". Only the first entry counts: a Mac set to German
  /// with Turkish second gets English.
  public static func systemCode(macPreferred: [String]) -> String {
    guard let first = macPreferred.first?.lowercased() else { return "en" }
    return first == "tr" || first.hasPrefix("tr-") || first.hasPrefix("tr_") ? "tr" : "en"
  }

  /// The Mac's own preferred languages, read from the global domain. Not
  /// `Locale.preferredLanguages`: that also sees the app-domain value this type writes.
  public static var macPreferredLanguages: [String] {
    CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication)
      as? [String] ?? []
  }

  /// The app-domain `AppleLanguages` this choice writes.
  public func appleLanguages(macPreferred: [String]) -> [String] {
    switch self {
    case .turkish: return ["tr"]
    case .english: return ["en"]
    case .system: return [Self.systemCode(macPreferred: macPreferred)]
    }
  }

  /// Writes `AppleLanguages` in `appDomain` (the app's own domain, never the global one). Call
  /// before the first localized lookup; a later change needs a restart.
  public func apply(to appDomain: UserDefaults, macPreferred: [String] = macPreferredLanguages) {
    appDomain.set(appleLanguages(macPreferred: macPreferred), forKey: "AppleLanguages")
  }

  /// Sets `AppleLanguages` for this launch only: in the argument domain of `defaults`, as a
  /// `-AppleLanguages` launch argument would, so nothing is saved. Demo mode uses it: the demo
  /// shares the bundle id, so `apply` would write the installed app's own settings.
  public func applyForThisLaunch(
    to defaults: UserDefaults, macPreferred: [String] = macPreferredLanguages
  ) {
    var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    args["AppleLanguages"] = appleLanguages(macPreferred: macPreferred)
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
  }
}

/// The language the app's UI resolved to: the one `LanguageChoice` set at launch (by default
/// the Mac's: Turkish on a Turkish Mac, English otherwise). Dates, weekday names and weather
/// place names follow it, so they never mix with text in the other language.
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
