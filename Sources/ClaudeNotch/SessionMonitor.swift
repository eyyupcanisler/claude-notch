import AppKit
import ClaudeNotchCore
import Observation

/// Background upkeep of the store: the liveness sweep (only while sessions exist), the process
/// scan that finds Claude Code sessions without hook events, Ghostty tab titles, and following
/// which Ghostty terminal is the focused one: it clears that chat's "done" and gives its status
/// line segment the white "you are here" base (`SessionStore.focusedTTY`).
///
/// Noticing a tab or split switch inside Ghostty (it sends no workspace notification) runs in
/// one of two modes (`SeenWatchMode`): with the Accessibility grant, an `AXObserver` on Ghostty
/// (`GhosttyFocusEvents`) triggers the focused-terminal check at once and nothing polls;
/// without it (or while Ghostty is not running, or attaching failed) the 0.5 s poll and the
/// click monitor do it, as before.
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
  /// How often the focused Ghostty terminal is asked for while Ghostty is in front and a
  /// Ghostty chat exists (a tab switch inside Ghostty sends no notification; keyboard switches
  /// reach no monitor without extra permissions). Idle otherwise.
  static let seenInterval: TimeInterval = 0.5
  /// After a click while Ghostty is in front: long enough for Ghostty to switch the tab.
  static let clickDelay: TimeInterval = 0.1
  /// After Ghostty launches, attaching is tried again this soon (its AX may not answer yet).
  static let launchAttachDelays: [TimeInterval] = [1, 3]
  /// After a failed attach, the 10 s tick tries again only this much later: a hung Ghostty
  /// stalls each attempt up to the AX messaging timeout.
  static let attachRetryInterval: TimeInterval = 30
  /// The same after Ghostty did not answer at all (timed out): it is likely hung, and each
  /// attempt blocks the main thread up to the timeout.
  static let attachRetryAfterTimeout: TimeInterval = 120
  private var observers: [NSObjectProtocol] = []
  private var seenLoop: Task<Void, Never>?
  private var clickMonitor: Any?
  /// Fast checks to skip after Ghostty gave no focused terminal (hung, no window): a stuck
  /// Ghostty must not keep the shared Apple Event queue busy back to back.
  private var fastBackoff = 0
  /// Accessibility trust (shared with Settings).
  let accessibility: AccessibilityAccess
  private let focusEvents = GhosttyFocusEvents()
  /// Bursts of AX events → single checks (see `SeenEventGate`).
  private var gate = SeenEventGate()
  private(set) var seenMode: SeenWatchMode = .polling
  /// No attach attempt from the tick before this (after a failed one).
  private var attachRetryAt = Date.distantPast
  /// `watchesFocus` when `trackFocusWatch` last looked.
  private var watchedFocus = false

  init(
    store: SessionStore, lister: ProcessLister = .system,
    accessibility: AccessibilityAccess = AccessibilityAccess()
  ) {
    self.store = store
    self.lister = lister
    self.accessibility = accessibility
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append(workspace.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let isGhostty = app?.bundleIdentifier == Terminals.ghosttyBundleID
      Task { @MainActor in
        if isGhostty {
          self?.checkFocusedTerminal()
        } else {
          // Another app in front: the user is in no Ghostty tab now.
          self?.leaveFocusedTerminal()
        }
      }
    })
    // Ghostty starting or quitting: attach to the new process, or fall back to polling.
    observers.append(workspace.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard app?.bundleIdentifier == Terminals.ghosttyBundleID else { return }
      Task { @MainActor in self?.ghosttyLaunched() }
    })
    observers.append(workspace.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard app?.bundleIdentifier == Terminals.ghosttyBundleID else { return }
      let pid = app?.processIdentifier
      Task { @MainActor in self?.ghosttyTerminated(pid: pid) }
    })
    focusEvents.onEvent = { [weak self] trigger in self?.noteGhosttyEvent(trigger) }
    accessibility.onChange = { [weak self] in self?.updateSeenMode(force: true) }
    updateLoop()
    trackFocusWatch()
    updateSeenMode(force: true)
    Task { await refreshAutomationStatus() }
    discovery = Task { [weak self] in
      while !Task.isCancelled && !NotchSettings.isDemo {
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

  /// Reads Ghostty's tab titles and tab order, only while Automation is already granted (never
  /// prompts).
  func refreshTabTitles() {
    guard !readingTitles, !store.sessions.isEmpty else { return }
    readingTitles = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.readingTitles = false }
      guard await self.refreshAutomationStatus() == 0,
        let tabs = await Terminals.ghosttyTitles()
      else { return }
      self.store.applyTabTitles(tabs.titles)
      self.store.applyTabOrder(tabs.order)
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

  /// Follows `watchesFocus` (one observation registration at a time) and applies it.
  private func trackFocusWatch() {
    let watches = withObservationTracking {
      watchesFocus
    } onChange: { [weak self] in
      Task { @MainActor in self?.trackFocusWatch() }
    }
    applySeenPolling()
    // The first Ghostty chat just appeared (a chat started in the tab already focused, or found
    // at launch): in events mode no Ghostty event may follow, so look now. Polling mode's loop
    // starts above and looks within 0.5 s. Only on the change: this runs on every hook event.
    if watches, !watchedFocus { noteGhosttyEvent(.focus) }
    watchedFocus = watches
  }

  /// Runs the fast focused-terminal poll only in polling mode and while a Ghostty chat exists;
  /// the click monitor exists only in polling mode.
  private func applySeenPolling() {
    let polling = !NotchSettings.isDemo && seenMode == .polling
    // A click in Ghostty (a tab, a split) is checked at once instead of at the next poll.
    // Mouse-up monitoring needs no permission; it does nothing unless Ghostty is in front and
    // a Ghostty chat exists.
    if polling, clickMonitor == nil {
      clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
        MainActor.assumeIsolated { self?.noteClick() }
      }
    } else if !polling, let monitor = clickMonitor {
      NSEvent.removeMonitor(monitor)
      clickMonitor = nil
    }
    let needed = polling && watchesFocus
    if !needed {
      seenLoop?.cancel()
      seenLoop = nil
    } else if seenLoop == nil {
      // A backoff left from before (a check in events mode, an earlier loop) is stale.
      fastBackoff = 0
      seenLoop = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(Self.seenInterval))
          guard !Task.isCancelled, let self else { return }
          guard Self.ghosttyInFront else { continue }
          if self.fastBackoff > 0 {
            self.fastBackoff -= 1
          } else {
            self.checkFocusedTerminal(fast: true)
          }
        }
      }
    }
  }

  private static var ghosttyInFront: Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Terminals.ghosttyBundleID
  }

  // MARK: - Accessibility events

  /// Ghostty's running process, if any.
  private static var ghosttyPID: pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: Terminals.ghosttyBundleID)
      .first { !$0.isTerminated }?.processIdentifier
  }

  /// Attaches or detaches the AX observer for the current trust and Ghostty state, then picks
  /// the mode. `force` tries to attach even inside the retry wait (launch, trust change).
  func updateSeenMode(force: Bool = false) {
    let trusted = accessibility.trusted
    let pid = NotchSettings.isDemo ? nil : Self.ghosttyPID
    if trusted, let pid {
      // Still attached to an earlier Ghostty process (relaunched): that one is gone.
      if let old = focusEvents.pid, old != pid { focusEvents.detach(processAlive: false) }
      if !focusEvents.attached, force || Date() >= attachRetryAt {
        if !focusEvents.attach(pid: pid) {
          let timedOut = focusEvents.lastFailure?.timedOut == true
          attachRetryAt = Date().addingTimeInterval(
            timedOut ? Self.attachRetryAfterTimeout : Self.attachRetryInterval)
        }
      }
    } else if focusEvents.attached {
      focusEvents.detach(processAlive: pid != nil)
    }
    let mode = SeenWatch.mode(
      trusted: trusted, ghosttyRunning: pid != nil, attached: focusEvents.attached)
    guard mode != seenMode else { return }
    seenMode = mode
    applySeenPolling()
    // Whatever happened while switching over is looked at once.
    if mode == .events { noteGhosttyEvent(.focus) }
  }

  private func ghosttyLaunched() {
    updateSeenMode(force: true)
    for delay in Self.launchAttachDelays {
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard let self, !self.focusEvents.attached else { return }
        self.updateSeenMode(force: true)
      }
    }
  }

  private func ghosttyTerminated(pid: pid_t?) {
    if let pid, focusEvents.pid == pid { focusEvents.detach(processAlive: false) }
    leaveFocusedTerminal()
    updateSeenMode()
  }

  /// The user is in no Ghostty terminal any more (another app in front, Ghostty quit): no
  /// segment keeps the "you are here" base. The demo keeps what /debug/ui set.
  private func leaveFocusedTerminal() {
    guard !NotchSettings.isDemo else { return }
    store.setFocusedTTY(nil)
  }

  /// An AX event from Ghostty: schedules a focused-terminal check (bursts coalesced). Only
  /// while Ghostty is the front app (a background focus change is not the user looking) and a
  /// Ghostty chat exists.
  private func noteGhosttyEvent(_ trigger: SeenEventGate.Trigger) {
    guard seenMode == .events, Self.ghosttyInFront, watchesFocus else { return }
    schedule(gate.event(trigger, now: Date(), busy: checking))
  }

  private func schedule(_ s: SeenEventGate.Schedule?) {
    guard let s else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(s.delay))
      guard let self, self.gate.fire(s.token, busy: self.checking) else { return }
      guard Self.ghosttyInFront else { return }
      self.checkFocusedTerminal(fast: true)
    }
  }

  /// For GET /debug/state (`ui.seen`).
  var debugSeenState: JSONValue {
    .object([
      "ax_trusted": .bool(accessibility.trusted),
      "ax_observing": .bool(focusEvents.attached),
      "polling": .bool(seenMode == .polling && !NotchSettings.isDemo),
      "mode": .string(seenMode.rawValue),
      "ax_attach_error": focusEvents.lastFailure.map { .string($0.description) } ?? .null,
      "poll_loop_running": .bool(seenLoop != nil),
      "click_monitor": .bool(clickMonitor != nil),
      "focused_tty": store.focusedTTY.map { .string($0) } ?? .null,
    ])
  }

  private func noteClick() {
    guard Self.ghosttyInFront, watchesFocus else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.clickDelay))
      self?.checkFocusedTerminal(fast: true)
    }
  }

  private func tick() {
    store.sweep()
    // Backup for a missed trust notification, and a retry of a failed attach.
    accessibility.refresh()
    updateSeenMode()
    // Switching tabs inside Ghostty sends no activation notification: poll while it is front.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Terminals.ghosttyBundleID {
      checkFocusedTerminal()
    } else {
      // Backup for a missed activation notification.
      leaveFocusedTerminal()
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

  /// A Ghostty chat with a known tty exists: the focused terminal is worth asking for, to clear
  /// a finished or waiting chat when its tab is focused and to mark the segment of the chat
  /// the user is in. (Clearing alone needed it only while a chat was unseen or waiting; the
  /// mark needs it for every Ghostty chat.)
  private var watchesFocus: Bool {
    store.sessions.values.contains { $0.terminal != nil && $0.terminalKind == .ghostty }
  }

  /// Sessions that focusing their terminal would clear. Marking seen (which also hands a held
  /// question back to the terminal) still happens only while one exists, as before the mark:
  /// the wider `watchesFocus` only decides whether the focused terminal is looked up.
  private var seenCandidates: [Session] {
    store.sessions.values.filter {
      $0.terminal != nil && $0.terminalKind == .ghostty
        && ($0.unseen || $0.status.kind == "waiting")
    }
  }

  /// Asks Ghostty for its focused terminal, marks that session seen (only while some chat could
  /// be cleared, `seenCandidates`) and records it as the one the user is in
  /// (`SessionStore.focusedTTY`). Never runs without the Automation grant, so it cannot raise
  /// the consent prompt on its own.
  ///
  /// `fast` (the 0.5 s loop, clicks, AX events) trusts the cached Automation grant: it skips
  /// the permission lookup when granted and does nothing when it is known not to be (the 10 s
  /// `tick` re-checks the grant). With nothing cached yet (Ghostty was not running when last
  /// looked up) it looks the grant up once, without prompting. In polling mode it backs off a
  /// few polls when Ghostty answers nothing.
  ///
  /// A call while a check is in flight is dropped in polling mode (the next poll comes in
  /// 0.5 s); in events mode nothing would come, so it becomes a re-run after that check.
  func checkFocusedTerminal(fast: Bool = false) {
    guard watchesFocus else { return }
    if checking {
      if seenMode == .events { _ = gate.event(.focus, now: Date(), busy: true) }
      return
    }
    if fast, let granted = ghosttyAutomation, granted != 0 { return }
    let lookUp = !fast || ghosttyAutomation == nil
    checking = true
    Task { [weak self] in
      guard let self else { return }
      var answered: Bool?
      defer {
        self.checking = false
        // An AX event that came meanwhile gets its check now.
        self.schedule(self.gate.checkEnded(answered: answered, now: Date()))
      }
      if lookUp {
        guard await self.refreshAutomationStatus() == 0 else { return }
      }
      guard let tty = await Terminals.focusedGhosttyTTY() else {
        answered = false
        // Events mode waits through the gate instead (`SeenEventGate.quietAfterNoAnswer`).
        if fast, self.seenMode == .polling { self.fastBackoff = 4 }
        // The mark stays as it was: one empty answer (a hung Ghostty, the backoff) must not
        // make it flicker. Leaving Ghostty clears it (`leaveFocusedTerminal`).
        return
      }
      answered = true
      self.fastBackoff = 0
      if !self.seenCandidates.isEmpty { self.store.markSeen(tty: tty) }
      // Only while Ghostty is still in front: an answer that arrives after the user switched
      // to another app must not bring the mark back.
      if Self.ghosttyInFront, !NotchSettings.isDemo { self.store.setFocusedTTY(tty) }
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
