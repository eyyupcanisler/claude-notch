import AppKit
import ClaudeNotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = SessionStore()
  private var router: RequestRouter?
  private var server: SocketServer?
  private var controller: NotchController?
  private var monitor: SessionMonitor?
  private var pruneTimer: Timer?
  private var signalSources: [DispatchSourceSignal] = []

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

    let router = RequestRouter(
      store: store, debugEnabled: ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DEBUG"] == "1")
    self.router = router
    let server = SocketServer(path: SocketServer.defaultSocketPath()) { request, responder in
      Task { @MainActor in router.handle(request, responder) }
    }
    do {
      try server.start()
      self.server = server
    } catch {
      showStartupError("\(error)")
    }

    let controller = NotchController(store: store)
    self.controller = controller
    let monitor = SessionMonitor(store: store)
    self.monitor = monitor
    controller.onAttention = { [weak monitor] _, _ in monitor?.noteAttention() }
    controller.onExpand = { [weak monitor] in monitor?.refreshTabTitles() }
    router.discoverProvider = { [weak monitor] in await monitor?.discover() }
    router.snapshotProvider = { [weak self] in self?.controller?.snapshotPNG() }
    router.uiCommandProvider = { [weak self] route, json in
      self?.controller?.debugCommand(route, json) ?? .null
    }
    router.uiStateProvider = { [weak self] in
      guard let self, var ui = self.controller?.debugUIState().objectValue else { return .null }
      ui["ghostty_automation"] = self.monitor?.ghosttyAutomation.map { .int(Int($0)) } ?? .null
      return .object(ui)
    }
    router.focusProvider = { [weak self] sessionID, dryRun in
      await self?.debugFocus(sessionID: sessionID, dryRun: dryRun) ?? .null
    }
    pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.store.prune() }
    }
  }

  /// Debug: dry run returns the script and liveness, otherwise focuses and returns the outcome.
  private func debugFocus(sessionID: String, dryRun: Bool) async -> JSONValue {
    guard let s = store.sessions[sessionID] else { return .object(["error": .string("yok")]) }
    if dryRun {
      let kind = TerminalKind(termProgram: s.termProgram)
      return .object([
        "tty": s.tty.map { .string($0) } ?? .null,
        "alive": .bool(store.isAlive(s)),
        "automation": .int(Int(await monitor?.refreshAutomationStatus() ?? -1)),
        "script": s.tty.flatMap { kind.focusScript(tty: $0) }.map { .string($0) } ?? .null
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
    alert.messageText = "ClaudeNotch soketi başlatılamadı"
    alert.informativeText = detail
    alert.addButton(withTitle: "Tamam")
    NSApp.activate()
    alert.runModal()
  }
}
