import AppKit
import ClaudeNotchCore

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
      addConsentItem(to: menu, title: loc("Grant Ghostty permission…"))
    case .denied:
      addConsentItem(to: menu, title: loc("Turn on Ghostty permission in System Settings…"))
    case .granted, .unknown:
      break
    }
    let settings = NSMenuItem(title: loc("Settings…"), action: #selector(showSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    let hooks = NSMenuItem(
      title: loc("Claude Code hooks…"), action: #selector(showHookInstall), keyEquivalent: "")
    hooks.target = self
    menu.addItem(hooks)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: loc("Quit ClaudeNotch"), action: #selector(quit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  private func addConsentItem(to menu: NSMenu, title: String) {
    let item = NSMenuItem(title: title, action: #selector(requestConsent), keyEquivalent: "")
    item.target = self
    item.toolTip = loc("Needed to switch to the right Ghostty tab when you click a session row.")
    menu.addItem(item)
    menu.addItem(.separator())
  }

  @objc private func requestConsent() {
    askConsent()
  }

  @objc private func showSettings() {
    openSettings()
  }

  /// The hooks are set up in Settings → General → Claude Code connection.
  @objc private func showHookInstall() {
    openSettings()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
