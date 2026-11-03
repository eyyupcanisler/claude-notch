import AppKit
import Carbon.HIToolbox
import ClaudeNotchCore
import Observation
import SwiftUI

/// Owns the surfaces (one per screen), decides the mode of each (collapsed / peek / expanded),
/// the peek, hover intent, the hotkey and every decision path.
@MainActor
final class NotchController {
  let store: SessionStore
  let ui = NotchUIState()
  let settings = NotchSettings()
  /// Calendar, timer and battery (see `ModuleCenter`).
  private(set) lazy var modules = ModuleCenter(settings: settings)
  private(set) var surfaces: [CGDirectDisplayID: NotchSurface] = [:]
  private var primaryID: CGDirectDisplayID?
  private var activeID: CGDirectDisplayID?
  private var expandedID: CGDirectDisplayID?
  private var planner = PeekPlanner()
  private var menu: AppMenuController?
  private var settingsWindow: SettingsWindowController?
  private var hotKeys: HotKeyCenter?
  /// One latch per global shortcut: auto-repeat and a held key never act twice.
  private var latches: [HotKeyRole: GlobalKeyLatch] = [:]
  /// Settings recorders listening right now; the hot keys stay off while any does.
  private var shortcutPauses = 0
  /// Risky request held with the global allow shortcut (decides when the hold completes).
  private var keyHold: (cardID: String, task: Task<Void, Never>)?
  private var nextPeekTask: Task<Void, Never>?
  private var shortcutOpenTask: Task<Void, Never>?
  private var holdHintTask: Task<Void, Never>?
  /// After a decision from the peek, the next pending card drops in after this long.
  static let nextPeekDelay: TimeInterval = 0.5
  private var previousApp: NSRunningApplication?
  /// Fresh key press per keyboard decision (no auto-repeat, key-up between decisions).
  private var keyGate = DecisionKeyGate()
  /// Session whose card was in the slot at the last check (see `syncSlotOrder`).
  private var lastSlotSessionID: String?
  /// How long the ⋯ rule must be on screen before "Her zaman" is accepted.
  static let moreArmDelay: TimeInterval = 0.8

  private var peekTask: Task<Void, Never>?
  private var collapseTask: Task<Void, Never>?
  private var dwellTask: Task<Void, Never>?
  private var armTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?
  private var pollTimer: Timer?
  private var screenTimer: Timer?
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var menuOpen = false
  /// Debug: keeps forced modes (no peek expiry, no hover collapse).
  private var debugFreeze = false
  /// Debug: pretend the active screen is this display.
  private var forcedActiveID: CGDirectDisplayID?
  /// Debug: Automation status shown instead of the real one (screenshots never ask macOS).
  private var consentOverride: Int32?
  /// Last consent action taken or planned ("request", "open_settings", ...) and whether it was
  /// a dry run.
  private var lastConsent: (action: ConsentAction, dryRun: Bool)?
  /// `/debug/*` and the debug log only with CLAUDE_NOTCH_DEBUG=1.
  static let debugEnabled = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DEBUG"] == "1"

  /// A session finished / asked (sessionID, kind).
  var onAttention: (@MainActor (String, String) -> Void)?
  /// The panel opened (tab titles are refreshed then).
  var onExpand: (@MainActor () -> Void)?

  init(store: SessionStore) {
    self.store = store
    menu = AppMenuController(
      openSettings: { [weak self] in self?.openSettings() },
      consent: { [weak self] in self?.ui.ghosttyConsent ?? .unknown },
      askConsent: { [weak self] in self?.ghosttyConsent(dryRun: false) })
    hotKeys = HotKeyCenter { [weak self] role, pressed in
      self?.hotKeyEvent(role, pressed: pressed)
    }
    planner.permissionHold = settings.peekDuration.seconds
    registerShortcuts()
    modules.onNote = { [weak self] note in self?.moduleNote(note) }
    settingsWindow = SettingsWindowController(
      settings: settings,
      shortcuts: ShortcutBridge(
        set: { [weak self] role, combo in self?.setShortcut(role, combo) },
        reset: { [weak self] in self?.resetShortcuts() },
        pause: { [weak self] paused in self?.pauseShortcuts(paused) },
        registered: { [weak self] role in self?.hotKeys?.isRegistered(role) ?? false }),
      modules: modules)

    rebuildSurfaces()
    store.onEffect = { [weak self] effect in self?.handle(effect) }
    trackStore()
    trackSettings()
    trackPeekSettings()
    installMonitors()
    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.rebuildSurfaces()
          self?.refresh()
        }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.updateActiveScreen() }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let ghostty = app?.bundleIdentifier == Terminals.ghosttyBundleID
        Task { @MainActor in
          self?.updateActiveScreen()
          if ghostty { self?.refreshConsent() }
        }
      })
    updateScreenTimer()
    refresh()
    refreshConsent()
  }

  // MARK: - Surfaces

  /// Any session exists: the status line is drawn and the notch / pill reacts.
  private var hasSessions: Bool { !store.sessions.isEmpty }

  private func makeRoot(_ state: SurfaceState) -> NotchRootView {
    NotchRootView(
      store: store, ui: ui, settings: settings, modules: modules, surface: state,
      actions: makeActions())
  }

  /// Creates / updates / closes surfaces for the current screens and display mode.
  private func rebuildSurfaces() {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let notch = screens.first { $0.hasNotch }
    let active = forcedActiveID.flatMap { id in screens.first { $0.displayID == id } }
      ?? ActiveScreen.current()
    var wanted: [(NSScreen, Bool)] = []
    switch settings.displayMode {
    case .notchOnly:
      if let s = notch ?? screens.first { wanted = [(s, true)] }
    case .automatic:
      if let notch {
        wanted = [(notch, true)]
        if let active, active.displayID != notch.displayID { wanted.append((active, false)) }
      } else if let s = active ?? screens.first {
        wanted = [(s, true)]
      }
    case .all:
      let first = notch ?? screens[0]
      wanted = [(first, true)] + screens.filter { $0 != first }.map { ($0, false) }
    }
    var keep: Set<CGDirectDisplayID> = []
    for (screen, primary) in wanted {
      let g = NotchGeometry.make(for: screen)
      keep.insert(g.displayID)
      if let s = surfaces[g.displayID] {
        s.layout(g)
        s.state.isPrimary = primary
      } else {
        surfaces[g.displayID] = NotchSurface(
          geometry: g, isPrimary: primary, makeRoot: { [unowned self] in self.makeRoot($0) })
      }
      if primary { primaryID = g.displayID }
    }
    for (id, s) in surfaces where !keep.contains(id) {
      s.close()
      surfaces.removeValue(forKey: id)
    }
    if let e = expandedID, surfaces[e] == nil { expandedID = nil }
    let a = active?.displayID
    activeID = a.flatMap { surfaces[$0] != nil ? $0 : nil } ?? primaryID
    installRightClick()
    updateScreenTimer()
  }

  /// Active screen changed (app activation / slow timer): move the pill. Never while a panel is
  /// open (it must not jump away from the pointer).
  private func updateActiveScreen() {
    // The menu bar can appear / disappear (full-screen space, auto-hide): follow it.
    for screen in NSScreen.screens {
      let g = NotchGeometry.make(for: screen)
      if let s = surfaces[g.displayID], s.state.geometry != g { s.layout(g) }
    }
    guard NSScreen.screens.count > 1, expandedID == nil else { return }
    let id = forcedActiveID ?? ActiveScreen.current()?.displayID
    let current = activeID
    let needsPill = settings.displayMode == .automatic
    if id != current || (needsPill && id.flatMap { surfaces[$0] } == nil) {
      rebuildSurfaces()
      refresh()
    }
  }

  private func updateScreenTimer() {
    let multi = NSScreen.screens.count > 1
    if multi, screenTimer == nil {
      screenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.updateActiveScreen() }
      }
    } else if !multi {
      screenTimer?.invalidate()
      screenTimer = nil
    }
  }

  private var peekSurfaceID: CGDirectDisplayID? { activeID ?? primaryID }

  // MARK: - Mode decision

  /// Applies the mode of every surface.
  func refresh() {
    let now = Date()
    if let peek = planner.current, peek.kind == .permission,
      peek.cardID.flatMap({ store.card(id: $0) }) == nil
    {
      planner.clear()
    }
    // After the stale-card check, so a module note waiting behind that card shows now.
    if !debugFreeze { planner.expire(at: now) }
    store.removalArmDelay = SessionStore.removalArmDelay(
      doubleClickInterval: NSEvent.doubleClickInterval)
    if expandedID != nil { planner.clearAll() }
    if ui.peek != planner.current { ui.peek = planner.current }
    validateSelection()
    if let hold = keyHold, shownRequest(at: now)?.cardID != hold.cardID {
      cancelKeyHold(hint: false)
    }
    syncSlotOrder()
    let live = hasSessions
    var changes: [(SurfaceState, NotchMode, Bool)] = []
    for (id, s) in surfaces {
      let mode: NotchMode
      if id == expandedID {
        mode = .expanded
      } else if expandedID == nil, ui.peek != nil, id == peekSurfaceID {
        mode = .peek
      } else {
        mode = .collapsed
      }
      let visible = s.state.geometry.hasNotch || live || mode != .collapsed
      if mode == .peek, let peek = ui.peek {
        let w: CGFloat
        switch peek.kind {
        case .finished: w = NotchMetrics.finishedWidth
        case .module: w = NotchMetrics.moduleWidth
        default: w = NotchMetrics.permissionWidth
        }
        if s.state.mode != .peek {
          // The island leaves the notch already at its width (no sideways morph on arrival).
          s.state.peekWidth = w
        } else if s.state.peekWidth != w {
          withAnimation(Motion.reduce ? Motion.crossfade : Motion.resize) { s.state.peekWidth = w }
        }
      }
      if s.state.mode != mode || s.state.visible != visible {
        if mode == .peek && s.state.mode != .peek { s.pointerAtAppear = NSEvent.mouseLocation }
        changes.append((s.state, mode, visible))
        log("mode \(id) \(s.state.mode.rawValue)->\(mode.rawValue) peek=\(ui.peek != nil)")
      }
    }
    // One spring per transition drives the shape, the material and the line together.
    for (state, mode, visible) in changes {
      withAnimation(Motion.shape(from: state.mode, to: mode)) {
        state.mode = mode
        state.visible = visible
      }
    }
    schedulePeekExpiry()
    scheduleArmTick()
    updatePointer()
  }

  private func validateSelection() {
    let ids = Set(store.pending.map(\.id))
    if let sel = ui.selectedCardID, !ids.contains(sel) { ui.selectedCardID = nil }
    if !ui.openedCards.isSubset(of: ids) { ui.openedCards.formIntersection(ids) }
    if let m = ui.moreCardID, !ids.contains(m) { ui.moreCardID = nil }
    if !ui.readToEnd.isSubset(of: ids) { ui.readToEnd.formIntersection(ids) }
    if ui.detailPage.keys.contains(where: { !ids.contains($0) }) {
      ui.detailPage = ui.detailPage.filter { ids.contains($0.key) }
    }
    if !ui.ruleRead.isSubset(of: ids) { ui.ruleRead.formIntersection(ids) }
    if ui.rulePage.keys.contains(where: { !ids.contains($0) }) {
      ui.rulePage = ui.rulePage.filter { ids.contains($0.key) }
    }
    if !ui.readTrigger.isEmpty {
      ui.readTrigger = ui.readTrigger.filter { entry in
        ids.contains(String(entry.key.drop(while: { $0 != ":" }).dropFirst()))
      }
    }
    if let s = ui.selectedSessionID, store.sessions[s] == nil { ui.selectedSessionID = nil }
  }

  private func schedulePeekExpiry() {
    peekTask?.cancel()
    // "Yanıtlanana kadar": nothing to schedule, the answer clears it.
    guard let until = planner.current?.until, until != .distantFuture, !debugFreeze else {
      return
    }
    let delay = max(0.05, until.timeIntervalSinceNow + 0.02)
    peekTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  /// Re-renders the card buttons the moment the newest card becomes clickable.
  private func scheduleArmTick() {
    armTask?.cancel()
    let times = store.pending.map { store.armedAt($0) } + [ui.pagerArmedAt, ui.moreArmedAt]
    guard let latest = times.max() else { return }
    let delay = latest.timeIntervalSinceNow
    guard delay > 0 else { return }
    armTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay + 0.03))
      guard !Task.isCancelled, let self else { return }
      self.ui.tick = Date()
    }
  }

  enum ExpandReason {
    case hover
    case hotkey
    case click
  }

  func expand(_ id: CGDirectDisplayID, reason: ExpandReason) {
    for s in surfaces.values where s.state.primed { s.state.primed = false }
    guard surfaces[id] != nil else { return }
    collapseTask?.cancel()
    collapseTask = nil
    let opening = expandedID != id
    let slotBefore = opening ? nil : RowKind.slotCard(store: store, ui: ui)?.id
    // The permission peek's request: a panel opened from that peek shows the same request,
    // never another one the user did not read.
    let peekCard = planner.current.flatMap { $0.kind == .permission ? $0.cardID : nil }
      .flatMap { store.card(id: $0)?.id }
    if reason == .hotkey {
      ui.selectedCardID = store.pending.first?.id
    } else if opening, let peekCard {
      ui.selectedCardID = peekCard
    } else if ui.selectedCardID == nil {
      ui.selectedCardID = store.pending.first?.id
    }
    if opening {
      expandedID = id
      planner.clearAll()
      freezeOrder()
      onExpand?()
    }
    if reason == .hotkey {
      ui.selectedSessionID = store.pending.first?.sessionID ?? store.displayOrder.first?.id
    }
    // A card that just came on screen (the panel opened with it, or another one took the
    // slot) waits the new-card delay before any button, key or global shortcut decides it.
    if let slot = RowKind.slotCard(store: store, ui: ui)?.id, opening || slot != slotBefore {
      ui.pagerArmedAt = max(
        ui.pagerArmedAt, Date().addingTimeInterval(SessionStore.armDelayNew))
      scheduleArmTick()
    }
    if reason == .hover { NSHapticFeedbackManager.defaultPerformer.perform(.alignment,
      performanceTime: .now) }
    refresh()
    refreshConsent()
  }

  func collapse() {
    log("collapse key=\(ui.keyMode)")
    collapseTask?.cancel()
    collapseTask = nil
    let wasKey = ui.keyMode
    expandedID = nil
    ui.keyMode = false
    ui.shortcutOpen = false
    shortcutOpenTask?.cancel()
    shortcutOpenTask = nil
    keyGate.reset()
    ui.frozenOrder = nil
    ui.frozenRich = []
    ui.moreCardID = nil
    for s in surfaces.values { s.intent.reset() }
    if wasKey { restoreFocus() }
    refresh()
  }

  /// Freezes the list (order, row shapes, whether the card slot exists) while the pointer is
  /// over the panel or the keyboard drives it.
  private func freezeOrder() {
    let order = store.displayOrder
    ui.frozenOrder = order.map(\.id)
    ui.frozenRich = Set(order.filter { store.needsAttention($0) }.map(\.id))
    ui.slotFrozenEmpty = store.pending.isEmpty
    lastSlotSessionID = RowKind.slotCard(store: store, ui: ui)?.sessionID
  }

  /// The card slot shows another session's card now: while the order is frozen, that session
  /// and the one that left the slot swap places in the list, so the rows under the pointer stay
  /// where they were (no "Kartı göster" slides under a stationary pointer).
  private func syncSlotOrder() {
    let slot = RowKind.slotCard(store: store, ui: ui)?.sessionID
    defer { lastSlotSessionID = slot }
    guard let frozen = ui.frozenOrder, let old = lastSlotSessionID, let new = slot, old != new
    else { return }
    let swapped = SessionStore.swapFrozen(frozen, old, new)
    if swapped != frozen { ui.frozenOrder = swapped }
  }

  /// Opens / closes the ⋯ section of a card; opening arms "Her zaman" only after a moment.
  private func setMore(_ id: String?) {
    ui.moreCardID = id
    if id != nil {
      ui.moreArmedAt = Date().addingTimeInterval(Self.moreArmDelay)
      scheduleArmTick()
    }
  }

  // MARK: - Pointer / hover intent

  private func installMonitors() {
    let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] _ in
      // Synchronous (monitors run on the main thread): the click-through state must not lag
      // the pointer by a Task hop, or a click just beside the notch lands on the panel.
      guard let self else { return }
      MainActor.assumeIsolated { self.updatePointer() }
    }
    let local = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .mouseEntered, .mouseExited]
    ) { [weak self] event in
      guard let self else { return event }
      MainActor.assumeIsolated { self.updatePointer() }
      return event
    }
    let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak self] event in
      guard let self else { return event }
      return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
    }
    monitors = [global, local, keys].compactMap { $0 }
  }

  /// The poll timer only runs while something is open, a dwell or re-check is pending, or a
  /// panel takes clicks (moves over our own window reach neither monitor reliably); a
  /// collapsed, idle notch costs nothing but the mouse monitor.
  private func updatePollTimer() {
    let needed = surfaces.values.contains {
      $0.state.mode != .collapsed || $0.intent.dwellStart != nil || $0.intent.recheckPending
        || !$0.panel.ignoresMouseEvents
    }
    if needed, pollTimer == nil {
      pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated { self.updatePointer() }
      }
    } else if !needed, let t = pollTimer {
      t.invalidate()
      pollTimer = nil
    }
  }

  func updatePointer() {
    let p = NSEvent.mouseLocation
    let now = Date()
    let live = hasSessions
    let pill = modules.timerPillVisible
    let ears = modules.earsVisible
    for s in surfaces.values {
      let rects = s.hitRects(
        hasSessions: live, pill: pill, ears: ears && s.state.geometry.hasNotch,
        fullEars: modules.earsFull)
      if let start = s.pointerAtAppear, hypot(p.x - start.x, p.y - start.y) > 2 {
        s.pointerAtAppear = nil
      }
      // Only the drawn shape takes clicks: the notch (+ line), the island, the open panel.
      // The menu-bar band beside the notch never does unless the panel is expanded.
      let inside = rects.contains { $0.contains(p) }
      let clickable = inside && s.pointerAtAppear == nil
      if s.panel.ignoresMouseEvents == clickable { s.panel.ignoresMouseEvents = !clickable }
      if menuOpen { continue }
      let g = s.state.geometry
      let top = g.screenFrame.maxY
      let notchMinX = g.screenFrame.midX - g.notchWidth / 2
      let notchMaxX = g.screenFrame.midX + g.notchWidth / 2
      switch s.state.mode {
      case .collapsed:
        // Hover target: the notch plus the status line under it.
        let depth = NotchMetrics.collapsedDepth(g, sessions: live, pill: pill)
        let fired = s.intent.update(
          point: p, at: now, minX: notchMinX, maxX: notchMaxX, top: top, bottom: top - depth)
        let primed = s.intent.dwellStart != nil && s.isLive(hasSessions: live, pill: pill)
        if s.state.primed != primed {
          withAnimation(Motion.reduce ? nil : Motion.prime) { s.state.primed = primed }
        }
        if fired, s.isLive(hasSessions: live, pill: pill) {
          s.intent.reset()
          expand(s.displayID, reason: .hover)
          return
        }
        if !fired, s.intent.dwellStart != nil || s.intent.recheckPending { scheduleDwellCheck() }
      case .peek:
        if inside {
          planner.hold(at: now)
          schedulePeekExpiry()
        }
        // Dwelling on the notch part of the island opens the panel.
        let fired = s.intent.update(
          point: p, at: now, minX: notchMinX, maxX: notchMaxX, top: top,
          bottom: top - g.notchHeight)
        if fired {
          s.intent.reset()
          expand(s.displayID, reason: .hover)
          return
        }
        if s.intent.dwellStart != nil || s.intent.recheckPending { scheduleDwellCheck() }
      case .expanded:
        let near = s.boundingRect(hasSessions: live).insetBy(dx: -6, dy: -6).contains(p)
        // Freeze the list while the pointer is over it; a pinned panel the pointer left
        // follows the live order again.
        // The pointer reached a panel a shortcut opened: from now on it closes like any other.
        if near, ui.shortcutOpen {
          ui.shortcutOpen = false
          shortcutOpenTask?.cancel()
          shortcutOpenTask = nil
        }
        if near, ui.frozenOrder == nil {
          freezeOrder()
        } else if !near, ui.pinned, !ui.keyMode, ui.frozenOrder != nil {
          ui.frozenOrder = nil
          ui.frozenRich = []
        }
        if near {
          collapseTask?.cancel()
          collapseTask = nil
        } else if !ui.pinned && !ui.keyMode && !ui.shortcutOpen && !debugFreeze
          && collapseTask == nil
        {
          collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            guard !self.ui.pinned, !self.ui.keyMode, !self.ui.shortcutOpen, !self.debugFreeze
            else { return }
            self.collapse()
          }
        }
      }
    }
    updatePollTimer()
  }

  private func scheduleDwellCheck() {
    guard dwellTask == nil else { return }
    dwellTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(HoverIntent.dwell * 1000) + 20))
      guard let self else { return }
      self.dwellTask = nil
      self.updatePointer()
    }
  }

  // MARK: - Hotkey and keyboard

  private func hotKeyPressed() {
    if expandedID != nil, ui.keyMode {
      collapse()
      return
    }
    guard let id = activeID ?? primaryID, let s = surfaces[id] else { return }
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previousApp = front
    }
    ui.keyMode = true
    keyGate.reset()
    ui.keysArmedAt = Date().addingTimeInterval(0.35)
    expand(id, reason: .hotkey)
    s.panel.onResignKey = { [weak self] in self?.panelResignedKey() }
    s.panel.makeKeyAndOrderFront(nil)
  }

  // MARK: - Global shortcuts (⌃⌥Y / ⌃⌥N / ⌃⌥Space)

  /// Every Carbon hot key event (and the debug route) comes through here. A key acts once per
  /// physical press: Pressed events while it is down (auto-repeat) are dropped.
  func hotKeyEvent(_ role: HotKeyRole, pressed: Bool) {
    // A recorder is listening: nothing is global until it stops.
    guard shortcutPauses == 0 else { return }
    if pressed {
      guard latches[role, default: GlobalKeyLatch()].pressed(at: Date()) else {
        log("hotkey \(role) repeat")
        return
      }
    } else {
      guard latches[role, default: GlobalKeyLatch()].released() else { return }
    }
    log("hotkey \(role) \(pressed ? "down" : "up")")
    switch role {
    case .panel: if pressed { hotKeyPressed() }
    case .allow: globalShortcut(.allow, pressed ? .down : .up)
    case .deny: globalShortcut(.deny, pressed ? .down : .up)
    }
  }

  /// The request the user sees right now: the open panel's card, or the permission peek's.
  /// nil when none is on screen (the peek went back to the line, the slot is empty).
  private func shownRequest(at now: Date = Date()) -> ShownRequest? {
    if let e = expandedID, surfaces[e]?.state.mode == .expanded {
      guard let card = RowKind.slotCard(store: store, ui: ui) else { return nil }
      let opened = ui.openedCards.contains(card.id)
      let read = opened && ui.readToEnd.contains(card.id)
      return ShownRequest(
        cardID: card.id, inPeek: false, armed: isArmed(card, at: now), risky: card.risk != nil,
        fullyVisible: !card.needsExpansion || read, opened: opened)
    }
    guard expandedID == nil, let peek = ui.peek, peek.kind == .permission,
      let id = peek.cardID, let card = store.card(id: id),
      let sid = peekSurfaceID, surfaces[sid]?.state.mode == .peek
    else { return nil }
    return ShownRequest(
      cardID: id, inPeek: true, armed: isArmed(card, at: now), risky: card.risk != nil,
      fullyVisible: card.fitsPeek)
  }

  /// Global shortcuts: the card delays, and the key delay (panel just opened by ⌃⌥Space, a
  /// card just removed).
  private func isArmed(_ card: PendingPermission, at now: Date) -> Bool {
    store.isArmed(card) && now >= ui.pagerArmedAt && now >= ui.keysArmedAt
  }

  private func globalShortcut(_ key: ShortcutKey, _ phase: ShortcutPhase) {
    let action = GlobalShortcutPolicy.action(
      key: key, phase: phase, shown: shownRequest(), oldestPending: store.pending.first?.id,
      holding: keyHold?.cardID)
    log("shortcut \(key.rawValue) \(phase.rawValue) -> \(action)")
    if phase == .down, action != .ignore, !settings.shortcutHintSeen {
      settings.shortcutHintSeen = true
    }
    switch action {
    case .ignore:
      break
    case .reveal(let id):
      reveal(id)
    case .openFull(let id):
      openFull(id)
    case .pageDown(let id):
      ui.detailPage[id, default: 0] += 1
    case .holdStart(let id):
      startKeyHold(id)
    case .holdCancel:
      cancelKeyHold(hint: true)
    case .allow(let id):
      decide(id, .allow, source: .global)
    case .deny(let id):
      decide(id, .deny(message: PermissionDecision.defaultDenyMessage), source: .global)
    }
  }

  /// Nothing was on screen: bring the oldest request back (peek, or the panel's slot) and
  /// decide nothing. The next press decides once the new-card delay is over.
  private func reveal(_ id: String) {
    guard let card = store.card(id: id) else { return }
    nextPeekTask?.cancel()
    if expandedID != nil {
      ui.slotFrozenEmpty = false
      selectCard(id)
      ui.selectedSessionID = card.sessionID
      ui.pagerArmedAt = max(ui.pagerArmedAt, Date().addingTimeInterval(SessionStore.armDelayNew))
      scheduleArmTick()
      refresh()
    } else {
      showPeek(card)
    }
  }

  /// The shown text is not all on screen: the panel opens on that card with its full text
  /// (never key, the user's app keeps the keyboard). A later press can allow it.
  private func openFull(_ id: String) {
    guard let card = store.card(id: id) else { return }
    if card.needsExpansion { ui.openedCards.insert(id) }
    ui.pagerArmedAt = max(ui.pagerArmedAt, Date().addingTimeInterval(SessionStore.armDelayNew))
    if expandedID == nil, let target = peekSurfaceID {
      ui.selectedCardID = id
      ui.selectedSessionID = card.sessionID
      ui.shortcutOpen = true
      expand(target, reason: .click)
      scheduleShortcutPanelTimeout()
    }
    scheduleArmTick()
    refresh()
  }

  /// A panel a shortcut opened, never reached by the pointer, closes after the peek time (the
  /// request stays pending on the line).
  private func scheduleShortcutPanelTimeout() {
    shortcutOpenTask?.cancel()
    guard let seconds = settings.peekDuration.seconds else { return }
    shortcutOpenTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self, self.ui.shortcutOpen, !self.debugFreeze else { return }
      self.collapse()
    }
  }

  /// Risky request: the allow shortcut must stay down for the hold time (ring on İzin ver).
  private func startKeyHold(_ id: String) {
    cancelKeyHold(hint: false)
    ui.holdHintCardID = nil
    ui.keyHoldCardID = id
    ui.holdProgress[id] = 0
    withAnimation(.linear(duration: GlobalShortcutPolicy.holdDuration)) {
      ui.holdProgress[id] = 1
    }
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(GlobalShortcutPolicy.holdDuration))
      guard !Task.isCancelled, let self, self.keyHold?.cardID == id else { return }
      self.keyHold = nil
      self.ui.keyHoldCardID = nil
      self.ui.holdProgress[id] = nil
      // Still down, still the request on screen: the single decision path re-checks it all.
      guard self.latches[.allow]?.isDown == true else { return }
      self.decide(id, .allow, source: .globalHold)
    }
    keyHold = (id, task)
  }

  private func cancelKeyHold(hint: Bool) {
    guard let hold = keyHold else { return }
    hold.task.cancel()
    keyHold = nil
    ui.keyHoldCardID = nil
    withAnimation(.easeOut(duration: 0.15)) { ui.holdProgress[hold.cardID] = nil }
    guard hint else { return }
    // A tap on a risky request: the button says "Basılı tutun" for a moment (no motion: it is
    // a keyboard action).
    ui.holdHintCardID = hold.cardID
    holdHintTask?.cancel()
    holdHintTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.6))
      guard !Task.isCancelled else { return }
      self?.ui.holdHintCardID = nil
    }
  }

  private func registerShortcuts() {
    for role in HotKeyRole.allCases { hotKeys?.register(role, settings.shortcut(role)) }
    for role in HotKeyRole.allCases { latches[role]?.reset() }
    updateKeyHints()
  }

  private func updateKeyHints() {
    let allow = hotKeys?.isRegistered(.allow) == true ? settings.shortcut(.allow).display : nil
    let deny = hotKeys?.isRegistered(.deny) == true ? settings.shortcut(.deny).display : nil
    if ui.allowKey != allow { ui.allowKey = allow }
    if ui.denyKey != deny { ui.denyKey = deny }
    var hint: String?
    if !settings.shortcutHintSeen, let allow, let deny {
      hint = "\(allow) izin ver · \(deny) reddet"
    }
    if ui.shortcutHint != hint { ui.shortcutHint = hint }
  }

  /// Settings recorder: validates and registers `combo` for `role`. Returns a Turkish error
  /// (the previous shortcut stays) or nil.
  private func setShortcut(_ role: HotKeyRole, _ combo: KeyCombo) -> String? {
    if let other = HotKeyRole.allCases.first(where: {
      $0 != role && settings.shortcut($0) == combo
    }) {
      return "Bu kısayol zaten “\(other.title)” için kullanılıyor."
    }
    if let error = combo.error(for: role) { return error }
    if combo.isSystemShortcut {
      return "Bu kısayolu macOS kullanıyor; başka bir kısayol seçin."
    }
    let old = settings.shortcut(role)
    let status = hotKeys?.register(role, combo) ?? OSStatus(eventNotHandledErr)
    guard status == noErr else {
      if shortcutPauses <= 1 { hotKeys?.register(role, old) }
      updateKeyHints()
      return status == OSStatus(eventHotKeyExistsErr)
        ? "Bu kısayol zaten kayıtlı; önceki kısayol korunuyor."
        : "Kısayol kaydedilemedi (hata \(status)); önceki kısayol korunuyor."
    }
    settings.setShortcut(role, combo)
    // Registered only to test it: another recorder still listens, so it stays off for now.
    if shortcutPauses > 1 { hotKeys?.unregister(role) }
    updateKeyHints()
    return nil
  }

  private func resetShortcuts() {
    settings.resetShortcuts()
    if shortcutPauses == 0 { registerShortcuts() } else { updateKeyHints() }
  }

  /// While a recorder listens, our own hot keys must not swallow the chord.
  /// Counted: two recorders may overlap for a moment, and the keys come back only when the
  /// last one stops listening.
  private func pauseShortcuts(_ paused: Bool) {
    if paused {
      shortcutPauses += 1
      cancelKeyHold(hint: false)
      hotKeys?.unregisterAll()
      for role in HotKeyRole.allCases { latches[role]?.reset() }
    } else {
      shortcutPauses = max(0, shortcutPauses - 1)
      if shortcutPauses == 0 { registerShortcuts() }
    }
  }

  private func panelResignedKey() {
    log("resignKey keyMode=\(ui.keyMode)")
    // collapse() clears keyMode before restoreFocus() orders the panel out, so this guard
    // keeps previousApp for that re-activation.
    guard ui.keyMode else { return }
    ui.keyMode = false
    // The user went elsewhere: never re-activate the app from the hotkey press later.
    previousApp = nil
    updatePointer()
  }

  /// Gives the keyboard back: ordering the key panel out makes the window server pick the
  /// active app's window again; then the panel comes back without key status.
  private func restoreFocus() {
    for s in surfaces.values where s.panel.isKeyWindow {
      s.panel.orderOut(nil)
      s.panel.orderFrontRegardless()
    }
    if let app = previousApp, NSWorkspace.shared.frontmostApplication != app {
      app.activate()
    }
    previousApp = nil
  }

  /// Keyboard model while the panel is key. Returns true when the key was consumed.
  func handleKey(_ event: NSEvent) -> Bool {
    guard ui.keyMode, expandedID != nil,
      surfaces.values.contains(where: { $0.panel.isKeyWindow })
    else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.type == .flagsChanged {
      keyGate.modifiersChanged(command: flags.contains(.command))
      return false
    }
    if event.type == .keyUp {
      if keyGate.latchedKey != nil { log("keyUp \(event.keyCode)") }
      keyGate.keyUp(keyCode: event.keyCode)
      return true
    }
    return press(keyCode: event.keyCode, command: flags.contains(.command),
      shift: flags.contains(.shift), isRepeat: event.isARepeat)
  }

  /// One key-down through the gate: auto-repeat of Return / Delete / Space is dropped and a
  /// decision key decides once per press (holding ⌘⏎ approves one card, not the queue).
  @discardableResult
  private func press(keyCode: UInt16, command: Bool, shift: Bool, isRepeat: Bool) -> Bool {
    guard keyGate.keyDown(keyCode: keyCode, command: command, isRepeat: isRepeat) else {
      return true
    }
    return perform(keyCode: keyCode, command: command, shift: shift)
  }

  @discardableResult
  private func perform(keyCode: UInt16, command: Bool, shift: Bool) -> Bool {
    switch keyCode {
    case 36, 76:  // return / enter
      if command && shift {
        decideAlwaysSelected()
      } else if command {
        decideSelected(.allow)
      } else if let sid = ui.selectedSessionID ?? selectedCard?.sessionID {
        Task { _ = await self.focus(sessionID: sid) }
      }
    case 51, 117:  // delete / forward delete
      if command { decideSelected(.deny(message: PermissionDecision.defaultDenyMessage)) }
    case 123: pager(-1)
    case 124: pager(1)
    case 125: moveSession(1)
    case 126: moveSession(-1)
    case 53: collapse()
    case 49:  // space: show the full request, then page through it (or the rule), then close it
      if let id = selectedCard?.id {
        if ui.openedCards.contains(id), !ui.readToEnd.contains(id) {
          ui.detailPage[id, default: 0] += 1
        } else if ui.moreCardID == id, !ui.ruleRead.contains(id) {
          ui.rulePage[id, default: 0] += 1
        } else {
          toggleDetail(id)
        }
      }
    default:
      break
    }
    return true
  }

  private var selectedCard: PendingPermission? {
    ui.selectedCardID.flatMap { store.card(id: $0) } ?? store.pending.first
  }

  private func decideSelected(_ decision: PermissionDecision) {
    guard let card = selectedCard else { return }
    decide(card.id, decision, source: .key)
  }

  /// ⌘⇧⏎: the first press opens the ⋯ section showing the rule; only a press while the rule
  /// is on screen adds it.
  private func decideAlwaysSelected() {
    guard let card = selectedCard else { return }
    decide(card.id, .always, source: .key)
  }

  private func visibleOrder() -> [Session] {
    let live = store.displayOrder
    guard let frozen = ui.frozenOrder else { return live }
    return SessionStore.applyFrozen(frozen, to: live)
  }

  private func moveSession(_ delta: Int) {
    let list = visibleOrder()
    guard !list.isEmpty else { return }
    let idx = list.firstIndex { $0.id == ui.selectedSessionID } ?? (delta > 0 ? -1 : list.count)
    let next = min(max(idx + delta, 0), list.count - 1)
    let s = list[next]
    ui.selectedSessionID = s.id
    // A session with a card moves into the card slot; the list scrolls to any other one
    // (ExpandedBody follows selectedSessionID with its ScrollViewReader).
    if let card = store.firstCard(for: s.id) { selectCard(card.id) }
  }

  // MARK: - Decisions (the single path for clicks, peek buttons, hold and keys)

  func decide(_ id: String, _ decision: PermissionDecision, source: DecisionSource) {
    guard let card = store.card(id: id) else { return }
    let now = Date()
    guard store.isArmed(card), now >= ui.pagerArmedAt else { return }
    if source == .key {
      // Keys act only on the card in the panel's slot, i.e. the one on screen.
      guard now >= ui.keysArmedAt, ui.keyMode, expandedID != nil,
        RowKind.slotCard(store: store, ui: ui)?.id == card.id
      else { return }
    }
    if source.isGlobal {
      // Global shortcuts: only the request on screen (peek or the panel's card), never
      // "Her zaman".
      guard decision != .always, now >= ui.keysArmedAt,
        shownRequest(at: now)?.cardID == card.id
      else { return }
    }
    let inPeek = source.fromPeek || (source.isGlobal && expandedID == nil)
    if case .deny = decision {
      finish(card, decision, source: source)
      return
    }
    // The peek shows one line: it may allow only when that line is the whole request.
    if inPeek && !card.fitsPeek {
      if let peekID = peekSurfaceID {
        ui.selectedCardID = id
        expand(peekID, reason: .click)
      }
      return
    }
    // A long request is allowed only after its whole text was on screen, down to the end.
    if card.needsExpansion && !(ui.openedCards.contains(id) && ui.readToEnd.contains(id)) {
      return
    }
    // "Her zaman" adds a permanent rule: only once that rule has been on screen a moment
    // (⌘⇧⏎ first opens it; a later, separate press saves it).
    if decision == .always && ui.moreCardID != card.id {
      if source == .key {
        withAnimation(.easeOut(duration: 0.16)) { setMore(card.id) }
        ui.pagerArmedAt = now.addingTimeInterval(0.35)
        scheduleArmTick()
      }
      return
    }
    if decision == .always && now < ui.moreArmedAt {
      return
    }
    // ... and only once that whole rule has been on screen, down to its end (a long rule
    // scrolls). No rule shown means no "Her zaman".
    if decision == .always && (card.alwaysDescription == nil || !ui.ruleRead.contains(id)) {
      return
    }
    if card.risk != nil, source != .key, !source.isHold {
      return
    }
    finish(card, decision, source: source)
  }

  /// "Bu oturumdaki N isteğin tümünü reddet": every card of the session, in one step.
  private func denyAll(sessionID: String) {
    let cards = store.cards(for: sessionID)
    guard let first = cards.first, store.isArmed(first), Date() >= ui.pagerArmedAt else { return }
    let selectedGoes = cards.contains { $0.id == ui.selectedCardID }
    store.denyAll(sessionID: sessionID)
    if let peek = planner.current?.cardID, cards.contains(where: { $0.id == peek }) {
      planner.clear()
    }
    if selectedGoes {
      ui.selectedCardID = store.pending.first?.id
      if ui.keyMode, let next = store.pending.first { ui.selectedSessionID = next.sessionID }
    }
    ui.moreCardID = nil
    refresh()
  }

  private func finish(
    _ card: PendingPermission, _ decision: PermissionDecision, source: DecisionSource
  ) {
    let index = store.queuePosition(of: card.id)?.index ?? 0
    let wasSelected = ui.selectedCardID == nil || ui.selectedCardID == card.id
    let fromPeek = source.fromPeek || (source.isGlobal && expandedID == nil)
    let shortcutPanel = ui.shortcutOpen && source.isGlobal
    if keyHold?.cardID == card.id { cancelKeyHold(hint: false) }
    store.decide(id: card.id, decision: decision)
    // The next card slides into the slot: keys wait as long as clicks do.
    ui.keysArmedAt = max(ui.keysArmedAt, Date().addingTimeInterval(store.removalArmDelay))
    if planner.current?.cardID == card.id { planner.clear() }
    if wasSelected, !store.pending.isEmpty {
      let next = store.pending[min(index, store.pending.count - 1)]
      ui.selectedCardID = next.id
      if ui.keyMode { ui.selectedSessionID = next.sessionID }
    }
    ui.moreCardID = nil
    // A panel a shortcut opened for this request closes with it.
    if shortcutPanel { collapse() }
    refresh()
    if fromPeek || shortcutPanel { scheduleNextPeek() }
  }

  /// After a decision from the peek (or a panel a shortcut opened), the oldest pending request
  /// drops in a moment later, never under the same key press or click.
  private func scheduleNextPeek() {
    nextPeekTask?.cancel()
    guard !store.pending.isEmpty else { return }
    nextPeekTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.nextPeekDelay))
      guard !Task.isCancelled, let self else { return }
      self.nextPeekTask = nil
      guard self.expandedID == nil, self.planner.current?.kind != .permission,
        let next = self.store.pending.first
      else { return }
      self.showPeek(next)
    }
  }

  /// Shows the permission peek for `card` again; its buttons and the shortcuts wait the new
  /// card delay (the request under the user just changed).
  private func showPeek(_ card: PendingPermission) {
    planner.show(cardID: card.id, sessionID: card.sessionID, at: Date())
    ui.pagerArmedAt = max(ui.pagerArmedAt, Date().addingTimeInterval(SessionStore.armDelayNew))
    refresh()
  }

  private func pager(_ delta: Int) {
    let cards = store.pending
    guard cards.count > 1 else { return }
    let idx = cards.firstIndex { $0.id == selectedCard?.id } ?? 0
    let next = cards[((idx + delta) % cards.count + cards.count) % cards.count]
    selectCard(next.id)
    ui.selectedSessionID = next.sessionID
  }

  private func selectCard(_ id: String) {
    guard ui.selectedCardID != id else { return }
    ui.selectedCardID = id
    ui.moreCardID = nil
    // Same delay as a new card: the card under the pointer just changed.
    ui.pagerArmedAt = Date().addingTimeInterval(SessionStore.armDelayNew)
    syncSlotOrder()
    scheduleArmTick()
  }

  private func toggleDetail(_ id: String) {
    if ui.openedCards.contains(id) {
      ui.openedCards.remove(id)
    } else {
      ui.openedCards.insert(id)
    }
  }

  // MARK: - Effects

  /// A module note: shown unless the panel is open (its tiles show the same), never over a
  /// Claude peek (the planner queues it).
  private func moduleNote(_ note: ModuleNote) {
    guard expandedID == nil else { return }
    if planner.receive(module: note, at: Date()) { refresh() }
  }

  private func handle(_ effect: StoreEffect) {
    guard case .attention(let sessionID, let kind) = effect else {
      // Sounds and expansion are driven by the attention kind (no auto-expand).
      return
    }
    onAttention?(sessionID, kind)
    if let e = SoundEvent(attention: kind), settings.soundEnabled(e) {
      NSSound(named: NSSound.Name(e.soundName))?.play()
    }
    guard expandedID == nil else { return }
    let cardID = kind == "permission"
      ? store.pending.last(where: { $0.sessionID == sessionID })?.id : nil
    if planner.receive(attention: kind, sessionID: sessionID, cardID: cardID, at: Date()) {
      refresh()
    }
  }

  private func trackStore() {
    withObservationTracking {
      _ = store.pending.count
      _ = store.attentionCount
      _ = store.workingCount
      _ = store.activeWorkingCount
      _ = store.doneUnseenCount
      _ = store.sessions.count
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.refresh()
        self?.trackStore()
      }
    }
  }

  private func trackSettings() {
    withObservationTracking {
      _ = settings.displayMode
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.rebuildSurfaces()
        self?.refresh()
        self?.trackSettings()
      }
    }
  }

  private func trackPeekSettings() {
    withObservationTracking {
      _ = settings.peekDuration
      _ = settings.shortcutHintSeen
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.planner.permissionHold = self.settings.peekDuration.seconds
        self.updateKeyHints()
        self.trackPeekSettings()
      }
    }
  }

  // MARK: - Actions

  private func makeActions() -> NotchActions {
    NotchActions(
      decide: { [weak self] id, decision, source in self?.decide(id, decision, source: source) },
      toggleDetail: { [weak self] id in self?.toggleDetail(id) },
      readToEnd: { [weak self] id, trigger in
        guard let self, !self.ui.readToEnd.contains(id) else { return }
        self.ui.readToEnd.insert(id)
        // The page that reveals the end is on screen a moment before the same key (or a
        // click) may allow: paging and allowing are never one tap rhythm.
        self.ui.pagerArmedAt = max(
          self.ui.pagerArmedAt, Date().addingTimeInterval(SessionStore.armDelayNew))
        self.scheduleArmTick()
        self.ui.readTrigger["text:\(id)"] = trigger
        self.log("read_to_end \(id) \(trigger)")
      },
      ruleRead: { [weak self] id, trigger in
        guard let self, !self.ui.ruleRead.contains(id) else { return }
        self.ui.ruleRead.insert(id)
        self.ui.readTrigger["rule:\(id)"] = trigger
        self.log("rule_read \(id) \(trigger)")
      },
      toggleMore: { [weak self] id in
        guard let self else { return }
        withAnimation(.easeOut(duration: 0.16)) {
          self.setMore(self.ui.moreCardID == id ? nil : id)
        }
      },
      pager: { [weak self] delta in self?.pager(delta) },
      selectCard: { [weak self] id in
        self?.selectCard(id)
        self?.ui.selectedSessionID = self?.store.card(id: id)?.sessionID
      },
      focus: { [weak self] sid in
        Task { @MainActor in _ = await self?.focus(sessionID: sid) }
      },
      markSeen: { [weak self] sid in self?.store.markSeen(sessionID: sid) },
      markAllSeen: { [weak self] in
        guard let self else { return }
        for s in self.store.sessions.values where s.unseen { self.store.markSeen(sessionID: s.id) }
      },
      copyMessage: { [weak self] sid in self?.copyMessage(sid) },
      denyAll: { [weak self] sid in self?.denyAll(sessionID: sid) },
      togglePin: { [weak self] in self?.ui.pinned.toggle() },
      openSettings: { [weak self] in self?.openSettings() },
      expand: { [weak self] id in self?.expand(id, reason: .click) },
      showCards: { [weak self] in
        guard let self, let first = self.store.pending.first else { return }
        self.selectCard(first.id)
        self.ui.selectedSessionID = first.sessionID
        self.ui.slotFrozenEmpty = false
      },
      bodyHeight: { [weak self] id, mode, h in
        guard let s = self?.surfaces[id], abs((s.state.bodyHeight[mode] ?? 0) - h) > 0.5 else {
          return
        }
        // A content change inside an open shape re-targets the same spring from where the
        // shape is now (no jump while it is still opening).
        withAnimation(Motion.reduce ? Motion.crossfade : Motion.resize) {
          s.state.bodyHeight[mode] = h
        }
      },
      ghosttyConsent: { [weak self] in self?.ghosttyConsent(dryRun: false) }
    )
  }

  private func copyMessage(_ sid: String) {
    guard let s = store.sessions[sid] else { return }
    switch s.status {
    case .done(let m), .error(let m):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(m, forType: .string)
      showHint("Son mesaj panoya kopyalandı", seconds: 2.5)
    default:
      break
    }
  }

  func openSettings() {
    settingsWindow?.show()
  }

  /// Jumps to the session's terminal, clears its unseen state, shows a hint on failure.
  func focus(sessionID: String) async -> FocusOutcome {
    guard let session = store.sessions[sessionID] else { return .failed }
    if !store.isAlive(session) { store.sweep() }
    let wasKey = ui.keyMode
    let outcome = await Terminals.focus(session, probe: store.probe)
    if outcome.reachedSession {
      store.markSeen(sessionID: sessionID)
      // The terminal is now frontmost on purpose: collapsing must not re-activate the app
      // that was frontmost when the hotkey was pressed.
      previousApp = nil
      if wasKey || ui.keyMode { collapse() }
    }
    showHint(outcome.hint)
    return outcome
  }

  private func showHint(_ text: String?, seconds: Double = 8) {
    hintTask?.cancel()
    ui.focusHint = text
    guard text != nil else { return }
    hintTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.ui.focusHint = nil
    }
  }

  // MARK: - Ghostty Automation consent

  enum ConsentAction: String {
    /// macOS has not asked yet: show its prompt.
    case request
    /// The user said no: only System Settings > Privacy & Security > Automation can change it.
    case openSettings = "open_settings"
    /// Ghostty is not running (no prompt is possible without the target).
    case unavailable
    case none
  }

  /// Re-reads the Automation status without asking (never raises the prompt).
  func refreshConsent() {
    guard consentOverride == nil else { return }
    Task { [weak self] in
      let status = await Terminals.automationStatus(bundleID: Terminals.ghosttyBundleID)
      // -600: Ghostty not running, says nothing about the grant.
      guard let self, self.consentOverride == nil, status != -600 else { return }
      if self.ui.ghosttyAutomation != status { self.ui.ghosttyAutomation = status }
    }
  }

  func consentAction() -> ConsentAction {
    switch ui.ghosttyConsent {
    case .granted: return .none
    case .denied: return .openSettings
    case .notDetermined, .unknown:
      return Terminals.isRunning(Terminals.ghosttyBundleID) ? .request : .unavailable
    }
  }

  /// "Ghostty iznini ver" (band icon / menu). A dry run only reports what a click would do.
  @discardableResult
  func ghosttyConsent(dryRun: Bool) -> ConsentAction {
    let action = consentAction()
    lastConsent = (action, dryRun)
    log("consent \(action.rawValue) dry=\(dryRun)")
    guard !dryRun else { return action }
    switch action {
    case .request:
      guard !ui.consentAsking else { return action }
      ui.consentAsking = true
      Task { [weak self] in
        let status = await Terminals.requestAutomation(bundleID: Terminals.ghosttyBundleID)
        guard let self else { return }
        self.ui.consentAsking = false
        if status != -600 { self.ui.ghosttyAutomation = status }
        switch status {
        case 0: self.showHint("Ghostty izni verildi", seconds: 2.5)
        case -1743:
          self.showHint("Ghostty izni reddedildi: Sistem Ayarları > Gizlilik ve Güvenlik > "
            + "Otomasyon'dan açabilirsiniz (kilit simgesi)")
        default: break
        }
      }
    case .openSettings:
      if let url = URL(string: GhosttyConsent.settingsURL) { NSWorkspace.shared.open(url) }
    case .unavailable:
      showHint("İzin için önce Ghostty'yi açın")
    case .none:
      break
    }
    return action
  }

  func showMenu(on surface: NotchSurface) {
    guard let m = menu?.buildMenu() else { return }
    let view = surface.hostingView
    let point = view.convert(surface.panel.mouseLocationOutsideOfEventStream, from: nil)
    menuOpen = true
    surface.panel.ignoresMouseEvents = false
    m.popUp(positioning: nil, at: point, in: view)
    menuOpen = false
    updatePointer()
  }

  func installRightClick() {
    for s in surfaces.values where s.hostingView.onRightClick == nil {
      s.hostingView.onRightClick = { [weak self, weak s] in
        guard let self, let s else { return }
        self.showMenu(on: s)
      }
      s.hostingView.onPointerMoved = { [weak self] in self?.updatePointer() }
      s.hostingView.updateTrackingAreas()
    }
  }

  // MARK: - Debug

  func debugUIState() -> JSONValue {
    let live = hasSessions
    let rectJSON = { (r: NSRect) -> JSONValue in
      .array([r.minX, r.minY, r.width, r.height].map { .double(Double($0)) })
    }
    let surf: [JSONValue] = surfaces.values.sorted { $0.displayID < $1.displayID }.map { s in
      let i = s.island
      return .object([
        "display": .int(Int(s.displayID)), "primary": .bool(s.state.isPrimary),
        "has_notch": .bool(s.state.geometry.hasNotch), "mode": .string(s.state.mode.rawValue),
        "visible": .bool(s.state.visible), "key": .bool(s.panel.isKeyWindow),
        "ignores_mouse_events": .bool(s.panel.ignoresMouseEvents),
        "stationary_guard": .bool(s.pointerAtAppear != nil),
        "occluded": .bool(!s.panel.occlusionState.contains(.visible)),
        "rect": rectJSON(s.boundingRect(hasSessions: live)),
        "hit_rects": .array(s.hitRects(hasSessions: live).map(rectJSON)),
        "window": rectJSON(s.panel.frame),
        "island": .object([
          "top_width": .double(Double(i.topWidth)), "body_width": .double(Double(i.bodyWidth)),
          "height": .double(Double(i.height)),
          "body_peek": .double(Double(s.state.bodyHeight[.peek] ?? -1)),
          "body_expanded": .double(Double(s.state.bodyHeight[.expanded] ?? -1)),
          "band": .double(Double(s.state.geometry.bandHeight))
        ]),
        "screen": rectJSON(s.state.geometry.screenFrame),
        "notch": .array([
          .double(Double(s.state.geometry.notchWidth)),
          .double(Double(s.state.geometry.notchHeight))
        ])
      ])
    }
    let peek: JSONValue = ui.peek.map { p in
      .object([
        "kind": .string(p.kind.rawValue), "sessions": .array(p.sessionIDs.map { .string($0) }),
        "card": p.cardID.map { .string($0) } ?? .null
      ])
    } ?? .null
    return .object([
      "surfaces": .array(surf), "active_display": activeID.map { .int(Int($0)) } ?? .null,
      "expanded_display": expandedID.map { .int(Int($0)) } ?? .null, "peek": peek,
      "display_mode": .string(settings.displayMode.rawValue),
      "density": .string(settings.density.rawValue), "pinned": .bool(ui.pinned),
      "key_mode": .bool(ui.keyMode),
      "selected_card": ui.selectedCardID.map { .string($0) } ?? .null,
      "slot_card": RowKind.slotCard(store: store, ui: ui).map { .string($0.id) } ?? .null,
      "more_card": ui.moreCardID.map { .string($0) } ?? .null,
      "read_to_end": .array(ui.readToEnd.sorted().map { .string($0) }),
      "opened_cards": .array(ui.openedCards.sorted().map { .string($0) }),
      "rule_read": .array(ui.ruleRead.sorted().map { .string($0) }),
      "read_trigger": .object(ui.readTrigger.mapValues { .string($0) }),
      "key_latched": .bool(keyGate.latchedKey != nil),
      "frozen_order": ui.frozenOrder.map { .array($0.map { .string($0) }) } ?? .null,
      "removal_arm_delay": .double(store.removalArmDelay),
      "selected_session": ui.selectedSessionID.map { .string($0) } ?? .null,
      "frozen": .bool(ui.frozenOrder != nil),
      "hotkey_status": .int(Int(hotKeys?.status[.panel] ?? -1)),
      "shortcuts": .object(Dictionary(uniqueKeysWithValues: HotKeyRole.allCases.map { role in
        ("\(role)", JSONValue.object([
          "keys": .string(settings.shortcut(role).display),
          "registered": .bool(hotKeys?.isRegistered(role) ?? false),
          "status": .int(Int(hotKeys?.status[role] ?? -1)),
          "down": .bool(latches[role]?.isDown ?? false)
        ]))
      })),
      "shown_request": shownRequest().map { r in
        .object([
          "card": .string(r.cardID), "in_peek": .bool(r.inPeek), "armed": .bool(r.armed),
          "risky": .bool(r.risky), "fully_visible": .bool(r.fullyVisible)
        ])
      } ?? .null,
      "key_hold": keyHold.map { .string($0.cardID) } ?? .null,
      "hold_hint": ui.holdHintCardID.map { .string($0) } ?? .null,
      "shortcut_open": .bool(ui.shortcutOpen),
      "shortcut_hint": ui.shortcutHint.map { .string($0) } ?? .null,
      "peek_duration": .string(settings.peekDuration.rawValue),
      "peek_until": planner.current.map { .double($0.until.timeIntervalSinceNow) } ?? .null,
      "poll_timer": .bool(pollTimer != nil),
      "status_line": .array(store.statusLine.map {
        .object(["session": .string($0.sessionID), "state": .string($0.state.rawValue)])
      }),
      "ghostty_consent": .object([
        "status": ui.ghosttyAutomation.map { .int(Int($0)) } ?? .null,
        "missing": .bool(ui.ghosttyConsent.missing), "asking": .bool(ui.consentAsking),
        "override": .bool(consentOverride != nil),
        "action": .string(consentAction().rawValue),
        "last": lastConsent.map {
          .object(["action": .string($0.action.rawValue), "dry_run": .bool($0.dryRun)])
        } ?? .null
      ]),
      "focus_hint": ui.focusHint.map { .string($0) } ?? .null,
      "peek_surface": peekSurfaceID.map { .int(Int($0)) } ?? .null,
      "shelf": .object([
        "enabled": .bool(settings.shelfEnabled), "items": .int(modules.shelf.shelf.items.count),
        "polling": .bool(modules.shelf.isPolling),
      ]),
      "log": .array(debugLog.map { .string($0) })
    ])
  }

  /// Debug only (CLAUDE_NOTCH_DEBUG=1): the last 30 mode / key / collapse events.
  private var debugLog: [String] = []
  private func log(_ s: @autoclosure () -> String) {
    guard Self.debugEnabled else { return }
    debugLog.append(s())
    if debugLog.count > 30 { debugLog.removeFirst() }
  }

  /// Debug: POST /debug/ui {mode, surface, pin, freeze, density, display_mode,
  /// active_display, select_card, open_card, more_card} and /debug/key {key, hotkey, key_mode,
  /// phase: down | up | press, repeat}.
  func debugCommand(_ route: String, _ json: JSONValue) -> JSONValue {
    if route == "key" {
      if json["hotkey"] == .bool(true) { hotKeyPressed() }
      // {"global": "allow" | "deny" | "panel", "phase": "down" | "up" | "press"}: the same
      // path as the Carbon hot key events.
      if let g = json["global"]?.stringValue {
        let role: HotKeyRole? = ["allow": .allow, "deny": .deny, "panel": .panel][g]
        let phase = json["phase"]?.stringValue ?? "press"
        if let role {
          if phase != "up" { hotKeyEvent(role, pressed: true) }
          if phase != "down" { hotKeyEvent(role, pressed: false) }
        }
      }
      // Keyboard mode without making the panel key (tests must not take the user's keyboard).
      if json["key_mode"] == .bool(true), let id = activeID ?? primaryID {
        ui.keyMode = true
        keyGate.reset()
        ui.keysArmedAt = Date().addingTimeInterval(0.35)
        expand(id, reason: .hotkey)
      }
      if let key = json["key"]?.stringValue {
        let map: [String: (UInt16, Bool, Bool)] = [
          "cmd_return": (36, true, false), "cmd_shift_return": (36, true, true),
          "cmd_delete": (51, true, false), "left": (123, false, false),
          "right": (124, false, false), "down": (125, false, false), "up": (126, false, false),
          "esc": (53, false, false), "return": (36, false, false), "space": (49, false, false)
        ]
        // phase: "down", "up" or (default) a full press; repeat: an auto-repeat key-down.
        let phase = json["phase"]?.stringValue ?? "press"
        if let (code, cmd, shift) = map[key], ui.keyMode {
          if phase != "up" {
            press(keyCode: code, command: cmd, shift: shift,
              isRepeat: json["repeat"] == .bool(true))
          }
          if phase != "down" { keyGate.keyUp(keyCode: code) }
        }
      }
      return debugUIState()
    }
    if let f = json["freeze"], case .bool(let b) = f { debugFreeze = b }
    if json["shortcut_hint"] == .bool(true) { settings.shortcutHintSeen = false }
    if let d = json["peek_duration"]?.stringValue, let v = PeekDuration(rawValue: d) {
      settings.peekDuration = v
      planner.permissionHold = v.seconds
    }
    if json["open_settings"] == .bool(true) { openSettings() }
    // {"set_shortcut": {"role": "allow", "keys": [keyCode, carbonModifiers]}} (the recorder's
    // path) and {"reset_shortcuts": true}.
    var shortcutError: JSONValue = .null
    if let spec = json["set_shortcut"], let name = spec["role"]?.stringValue,
      let role = HotKeyRole.allCases.first(where: { "\($0)" == name }),
      case .array(let keys)? = spec["keys"], keys.count == 2,
      case .int(let code) = keys[0], case .int(let mods) = keys[1]
    {
      shortcutError = setShortcut(role, KeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods)))
        .map { .string($0) } ?? .string("ok")
    }
    if json["reset_shortcuts"] == .bool(true) { resetShortcuts() }
    if json["close_settings"] == .bool(true) { settingsWindow?.close() }
    // {"ghostty_consent": -1744 | -1743 | 0 | null}: show that status (null: the real one).
    if let c = json["ghostty_consent"] {
      if case .int(let v) = c {
        consentOverride = Int32(v)
        ui.ghosttyAutomation = Int32(v)
      } else {
        consentOverride = nil
        refreshConsent()
      }
    }
    // {"consent": "dry_run"}: what clicking "Ghostty iznini ver" would do, without doing it.
    if json["consent"]?.stringValue == "dry_run" { ghosttyConsent(dryRun: true) }
    if let d = json["density"]?.stringValue, let v = Density(rawValue: d) { settings.density = v }
    if let d = json["display_mode"]?.stringValue, let v = DisplayMode(rawValue: d) {
      settings.displayMode = v
    }
    if let p = json["pin"], case .bool(let b) = p { ui.pinned = b }
    if let a = json["active_display"] {
      if case .int(let v) = a {
        forcedActiveID = CGDirectDisplayID(v)
      } else {
        forcedActiveID = nil
      }
      rebuildSurfaces()
    }
    if let m = json["module_note"], let title = m["title"]?.stringValue,
      let source = ModuleNote.Source(rawValue: m["source"]?.stringValue ?? "calendar")
    {
      var level: Double?
      if case .double(let v)? = m["level"] { level = v }
      moduleNote(
        ModuleNote(
          source: source, id: "debug:\(Date().timeIntervalSince1970)", title: title,
          subtitle: m["subtitle"]?.stringValue, digits: m["digits"]?.stringValue,
          unit: m["unit"]?.stringValue, level: level, validUntil: Date().addingTimeInterval(60)))
    }
    if json["timer_toggle"] != nil { modules.toggleTimer() }
    if let id = json["select_card"]?.stringValue { selectCard(id) }
    if let id = json["open_card"]?.stringValue { ui.openedCards.insert(id) }
    if let id = json["more_card"]?.stringValue { setMore(id) }
    if let mode = json["mode"]?.stringValue {
      let target: CGDirectDisplayID? = json["surface"]?.stringValue == "secondary"
        ? surfaces.values.first(where: { !$0.state.isPrimary })?.displayID : primaryID
      switch mode {
      case "expanded": if let target { expand(target, reason: .click) }
      case "collapsed":
        planner.clear()
        collapse()
      default: break
      }
    }
    refresh()
    guard shortcutError != .null, case .object(var state) = debugUIState() else {
      return debugUIState()
    }
    state["shortcut_error"] = shortcutError
    return .object(state)
  }

  /// Debug aid: the primary panel content over a gray backdrop, as PNG.
  func snapshotPNG() -> Data? {
    guard let id = primaryID, let view = surfaces[id]?.hostingView else { return nil }
    let bounds = view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    view.cacheDisplay(in: bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}
