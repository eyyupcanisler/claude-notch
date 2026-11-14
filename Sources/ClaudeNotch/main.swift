import AppKit
import ClaudeNotchCore

MainActor.assumeIsolated {
  // The UI language (Settings > General > Language, Turkish when nothing is saved) goes into the
  // app's own AppleLanguages before anything looks up a string, so every localized text, the
  // replies sent to Claude, dates and numbers follow it. Only the app domain is written.
  LanguageChoice(stored: NotchSettings.defaultStore.string(forKey: LanguageChoice.defaultsKey))
    .apply(to: .standard)
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(delegate) {
    app.run()
  }
}
