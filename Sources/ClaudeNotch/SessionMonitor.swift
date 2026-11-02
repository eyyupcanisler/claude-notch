import AppKit
import ClaudeNotchCore
import Observation

/// Background upkeep of the store: the liveness sweep (only while sessions exist), the process
/// scan that finds Claude Code sessions without hook events, Ghostty tab titles, and clearing
/// "done" when its Ghostty terminal becomes the focused one.
@MainActor
final class SessionMonitor {
  let store: SessionStore
  /// Last known Automation status towards Ghostty (0 = granted), nil before the first check.
  private(set) var ghosttyAutomation: Int32?
  private var loop: Task<Void, Never>?
  private var discovery: Task<Void, Never>?
  private var titleLoop: Task<Void, Never>?
  private var checking = false
  private var readingTitles = false
  let lister: ProcessLister
  /// How often tab titles are read while sessions exist.
  static let titleInterval: TimeInterval = 15
  private var observer: NSObjectProtocol?

  init(store: SessionStore, lister: ProcessLister = .system) {
    self.store = store
    self.lister = lister
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let isGhostty = app?.bundleIdentifier == Terminals.ghosttyBundleID
      Task { @MainActor in
        if isGhostty { self?.checkFocusedTerminal() }
      }
    }
    updateLoop()
    Task { await refreshAutomationStatus() }
    discovery = Task { [weak self] in
      while !Task.isCancelled {
        await self?.discover()
        try? await Task.sleep(for: .seconds(SessionStore.discoveryInterval))
      }
    }
  }

  /// One process scan (off the main thread), applied to the store.
  func discover() async {
    let lister = self.lister
    let records = await Task.detached(priority: .utility) { lister.list() }.value
    store.applyDiscovery(records)
  }

  /// Reads Ghostty's tab titles, only while Automation is already granted (never prompts).
  func refreshTabTitles() {
    guard !readingTitles, !store.sessions.isEmpty else { return }
    readingTitles = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.readingTitles = false }
      guard await self.refreshAutomationStatus() == 0,
        let titles = await Terminals.ghosttyTitles()
      else { return }
      self.store.applyTabTitles(titles)
    }
  }

  /// Runs `sweep()` every `livenessInterval` while there are sessions; stops when empty.
  private func updateLoop() {
    withObservationTracking {
      _ = store.sessions.isEmpty
    } onChange: { [weak self] in
      Task { @MainActor in self?.updateLoop() }
    }
    if store.sessions.isEmpty {
      loop?.cancel()
      loop = nil
      titleLoop?.cancel()
      titleLoop = nil
    } else if loop == nil {
      titleLoop = Task { [weak self] in
        while !Task.isCancelled {
          self?.refreshTabTitles()
          try? await Task.sleep(for: .seconds(Self.titleInterval))
        }
      }
      loop = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(SessionStore.livenessInterval))
          guard !Task.isCancelled, let self else { return }
          self.tick()
        }
      }
    }
  }

  private func tick() {
    store.sweep()
    // Switching tabs inside Ghostty sends no activation notification: poll while it is front.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Terminals.ghosttyBundleID {
      checkFocusedTerminal()
    }
  }

  /// A session just finished or asked: maybe the user is already looking at its terminal.
  func noteAttention() {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self else { return }
      if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Terminals.ghosttyBundleID {
        self.checkFocusedTerminal()
      }
    }
  }

  /// Sessions that focusing their terminal would clear.
  private var seenCandidates: [Session] {
    store.sessions.values.filter {
      $0.tty != nil && $0.termProgram == "ghostty" && ($0.unseen || $0.status.kind == "waiting")
    }
  }

  /// Asks Ghostty for its focused terminal and marks that session seen. Never runs without the
  /// Automation grant, so it cannot raise the consent prompt on its own.
  func checkFocusedTerminal() {
    guard !checking, !seenCandidates.isEmpty else { return }
    checking = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.checking = false }
      let status = await self.refreshAutomationStatus()
      guard status == 0, let tty = await Terminals.focusedGhosttyTTY() else { return }
      self.store.markSeen(tty: tty)
    }
  }

  @discardableResult
  func refreshAutomationStatus() async -> Int32 {
    let status = await Terminals.automationStatus(bundleID: Terminals.ghosttyBundleID)
    // -600: Ghostty not running, says nothing about the grant.
    if status != -600 { ghosttyAutomation = status }
    return status
  }
}
