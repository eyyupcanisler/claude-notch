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
      title: "Hook kurulumunu göster", action: #selector(showHookInstall), keyEquivalent: "")
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

  @objc private func showHookInstall() {
    let script = Self.installScriptPath()
    let command = "\"\(script)\""
    let alert = NSAlert()
    alert.messageText = "Hook kurulumu"
    alert.informativeText = """
      Claude Code hook'larını kurmak için Terminal'de çalıştırın:

      \(command)

      Kaldırmak için sonuna --uninstall ekleyin. Yalnızca hook'lar yazdırılsın isterseniz --print.
      """
    alert.addButton(withTitle: "Komutu kopyala")
    alert.addButton(withTitle: "Kapat")
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
    }
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  static func installScriptPath() -> String {
    if let root = Bundle.main.object(forInfoDictionaryKey: "ClaudeNotchProjectRoot") as? String,
      !root.isEmpty {
      return root + "/scripts/install-hooks.sh"
    }
    let guess = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return guess.appendingPathComponent("scripts/install-hooks.sh").path
  }
}
