import AppKit

/// Builds the context menu (right-click / gear) and handles its actions.
@MainActor
final class AppMenuController: NSObject {
  private let openSettings: @MainActor () -> Void
  private let consent: @MainActor () -> GhosttyConsent
  private let askConsent: @MainActor () -> Void

  init(
    openSettings: @escaping @MainActor () -> Void,
    consent: @escaping @MainActor () -> GhosttyConsent,
    askConsent: @escaping @MainActor () -> Void
  ) {
    self.openSettings = openSettings
    self.consent = consent
    self.askConsent = askConsent
  }

  func buildMenu() -> NSMenu {
    let menu = NSMenu()
    switch consent() {
    case .notDetermined:
      addConsentItem(to: menu, title: "Ghostty iznini ver…")
    case .denied:
      addConsentItem(to: menu, title: "Ghostty iznini Sistem Ayarları'nda aç…")
    case .granted, .unknown:
      break
    }
    let settings = NSMenuItem(title: "Ayarlar…", action: #selector(showSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    let hooks = NSMenuItem(
      title: "Claude Code kancaları…", action: #selector(showHookInstall), keyEquivalent: "")
    hooks.target = self
    menu.addItem(hooks)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "ClaudeNotch’tan çık", action: #selector(quit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  private func addConsentItem(to menu: NSMenu, title: String) {
    let item = NSMenuItem(title: title, action: #selector(requestConsent), keyEquivalent: "")
    item.target = self
    item.toolTip = "Oturum satırına tıklayınca Ghostty'de doğru sekmeye geçmek için gerekir."
    menu.addItem(item)
    menu.addItem(.separator())
  }

  @objc private func requestConsent() {
    askConsent()
  }

  @objc private func showSettings() {
    openSettings()
  }

  /// The hooks are set up in Settings → Genel → Claude Code bağlantısı.
  @objc private func showHookInstall() {
    openSettings()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
