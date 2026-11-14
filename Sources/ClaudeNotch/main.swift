import AppKit
import ClaudeNotchCore

MainActor.assumeIsolated {
  // The UI language (Settings > General > Language; nothing saved = the Mac's: Turkish on a
  // Turkish Mac, English otherwise) goes into the app's own AppleLanguages before anything looks
  // up a string, so every localized text, the replies sent to Claude, dates and numbers follow
  // it. Only the app domain is written. The demo (CLAUDE_NOTCH_DEMO=1) shares the bundle id and
  // so the app domain: it sets the language for its own launch only and saves nothing.
  let language = LanguageChoice(
    stored: NotchSettings.defaultStore.string(forKey: LanguageChoice.defaultsKey))
  if NotchSettings.isDemo {
    language.applyForThisLaunch(to: .standard)
  } else {
    language.apply(to: .standard)
  }
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(delegate) {
    app.run()
  }
}
