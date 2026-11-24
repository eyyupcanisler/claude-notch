import AppKit
import ClaudeNotchCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = SessionStore()
  private var router: RequestRouter?
  private var server: SocketServer?
  private var controller: NotchController?
  private var monitor: SessionMonitor?
  private var pruneTimer: Timer?
  private var agyWatcher: AgyWatcher?
  private var signalSources: [DispatchSourceSignal] = []

  /// Opening the app again (Spotlight, Finder, Launchpad) while it runs shows Settings: it has
  /// no Dock icon or window of its own, so this is its "front door".
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    controller?.openSettings()
    return false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let id = Bundle.main.bundleIdentifier {
      let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .filter { $0 != NSRunningApplication.current }
      if !others.isEmpty {
        NSApp.terminate(nil)
        return
      }
    }
    installSignalHandlers()
    installMainMenu()
    // Keep the installed hook bridge in step with this build (it used to refresh only when
    // Settings opened). Demo runs never touch the real hook copy.
    if !NotchSettings.isDemo { HookInstaller.refreshCopy() }
    // Pinned chats and dragged rows survive a restart of the app (`ChatOrder`). A demo run
    // shares the app's defaults domain, so it neither reads nor writes the real order.
    if !NotchSettings.isDemo {
      if let data = UserDefaults.standard.data(forKey: ChatOrder.defaultsKey),
        let order = try? JSONDecoder().decode(ChatOrder.self, from: data)
      {
        store.loadChatOrder(order)
      }
      store.onChatOrderChange = { order in
        guard let data = try? JSONEncoder().encode(order) else { return }
        UserDefaults.standard.set(data, forKey: ChatOrder.defaultsKey)
      }
    }
    // A reinstalled bundle loses its login item: register again if the user wanted it.
    if !NotchSettings.isDemo, UserDefaults.standard.bool(forKey: "loginWanted"),
      SMAppService.mainApp.status != .enabled
    {
      try? SMAppService.mainApp.register()
    }

    let env = ProcessInfo.processInfo.environment
    let router = RequestRouter(
      store: store, debugEnabled: env["CLAUDE_NOTCH_DEBUG"] == "1" || NotchSettings.isDemo)
    self.router = router
    // Demo runs on their own socket: real Claude Code hooks never reach them.
    let path = NotchSettings.isDemo
      ? (SocketServer.defaultSocketPath() as NSString).deletingLastPathComponent + "/demo.sock"
      : SocketServer.defaultSocketPath()
    let server = SocketServer(path: path) { request, responder in
      Task { @MainActor in router.handle(request, responder) }
    }
    do {
      try server.start()
      self.server = server
    } catch {
      showStartupError("\(error)")
    }

    let accessibility = AccessibilityAccess()
    let controller = NotchController(store: store, accessibility: accessibility)
    self.controller = controller
    let monitor = SessionMonitor(store: store, accessibility: accessibility)
    self.monitor = monitor
    controller.onAttention = { [weak monitor] _, _ in monitor?.noteAttention() }
    controller.onExpand = { [weak monitor] in monitor?.refreshTabTitles() }
    router.discoverProvider = { [weak monitor] in await monitor?.discover() }
    router.questionMode = { [weak self] in self?.controller?.settings.questionMode ?? .fallback }
    router.snapshotProvider = { [weak self] in self?.controller?.snapshotPNG() }
    router.uiCommandProvider = { [weak self] route, json in
      self?.controller?.debugCommand(route, json) ?? .null
    }
    router.uiStateProvider = { [weak self] in
      guard let self, var ui = self.controller?.debugUIState().objectValue else { return .null }
      ui["ghostty_automation"] = self.monitor?.ghosttyAutomation.map { .int(Int($0)) } ?? .null
      ui["seen"] = self.monitor?.debugSeenState ?? .null
      return .object(ui)
    }
    router.focusProvider = { [weak self] sessionID, dryRun in
      await self?.debugFocus(sessionID: sessionID, dryRun: dryRun) ?? .null
    }
    // agy (Antigravity CLI) chats: their status line snapshots, meters and CLI logs.
    router.agySnapshot = { AgyWatcher.snapshot(pid: $0) }
    let agy = AgyWatcher(store: store, usage: controller.modules.usage)
    agyWatcher = agy
    agy.start()
    pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.store.prune() }
    }
  }

  /// Debug: dry run returns the script and liveness, otherwise focuses and returns the outcome.
  private func debugFocus(sessionID: String, dryRun: Bool) async -> JSONValue {
    // "yok" in Turkish (the original reply), "no such session" in English.
    guard let s = store.sessions[sessionID] else {
      return .object(["error": .string(loc("no such session"))])
    }
    if dryRun {
      let kind = s.terminalKind
      return .object([
        "tty": s.terminal.map { .string($0) } ?? .null,
        "alive": .bool(store.isAlive(s)),
        "automation": .int(Int(await monitor?.refreshAutomationStatus() ?? -1)),
        "script": s.terminal.flatMap { kind.focusScript(tty: $0) }.map { .string($0) } ?? .null
      ])
    }
    guard let outcome = await controller?.focus(sessionID: sessionID) else { return .null }
    return .object([
      "outcome": .string(outcome.kind), "hint": outcome.hint.map { .string($0) } ?? .null
    ])
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
  }

  private func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { NSApp.terminate(nil) }
      source.resume()
      signalSources.append(source)
    }
  }

  private func showStartupError(_ detail: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = loc("The ClaudeNotch socket could not be started")
    alert.informativeText = detail
    alert.addButton(withTitle: loc("OK"))
    NSApp.activate()
    alert.runModal()
  }

  /// A menu bar the app never shows (it has no Dock icon), only for its keys while Settings is
  /// in front: ⌘Q quits, and the text fields get ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z.
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: loc("Quit ClaudeNotch"), action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    appItem.submenu = appMenu
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
  }
}
