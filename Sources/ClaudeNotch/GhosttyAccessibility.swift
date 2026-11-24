import AppKit
import ApplicationServices
import ClaudeNotchCore
import Observation

/// Whether macOS trusts the app for Accessibility (System Settings > Privacy & Security >
/// Accessibility). Optional: with it, `GhosttyFocusEvents` hears tab and split switches in
/// Ghostty as they happen; without it the notch polls (see `SessionMonitor`).
///
/// Never prompts on its own: only `request()` (a button in Settings) asks macOS. The state is
/// read again when macOS posts its trust-change notification, when the app becomes active
/// (back from System Settings), when the Settings window shows and on the monitor's 10 s tick.
@MainActor
@Observable
final class AccessibilityAccess {
  /// `AXIsProcessTrusted()` at the last check.
  private(set) var trusted: Bool
  /// Called after `trusted` changed.
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  static let settingsURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  /// macOS posts this (distributed) when any app's Accessibility trust changes.
  static let trustChanged = Notification.Name("com.apple.accessibility.api")

  init() {
    trusted = AXIsProcessTrusted()
    let distributed = DistributedNotificationCenter.default()
    observers.append((distributed, distributed.addObserver(
      forName: Self.trustChanged, object: nil, queue: .main
    ) { [weak self] _ in
      // The trust database is written a moment after the notification.
      Task { @MainActor in
        for delay in [0.3, 1.5] {
          try? await Task.sleep(for: .seconds(delay))
          self?.refresh()
        }
      }
    }))
    let local = NotificationCenter.default
    observers.append((local, local.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }))
  }

  /// Reads the trust state again (no prompt).
  func refresh() {
    let now = AXIsProcessTrusted()
    guard now != trusted else { return }
    trusted = now
    onChange?()
  }

  /// The user asked for it: macOS adds the app to the Accessibility list (and may show its
  /// own prompt), and System Settings opens on that list so the switch can be turned on.
  func request() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if let url = URL(string: Self.settingsURL) { NSWorkspace.shared.open(url) }
    refresh()
  }
}

/// An `AXObserver` on Ghostty's application element. It only says *when* to look: every
/// focus move (window, main window, focused element: a tab or split switch), a new window
/// and a title change of the focused window call `onEvent`; which terminal is focused still
/// comes from the Apple Event query (`Terminals.focusedGhosttyTTY`).
///
/// The title notification is registered on the focused window only, moved when focus moves: a
/// window's title follows its active tab, and background tabs retitling themselves (Claude
/// Code's spinner) then wake nothing. On that window, a title change counts only when the text
/// after the spinner glyph changed (`SeenWatch.titleKey`): a working chat in the focused tab
/// animates its title several times a second, which must not turn into a 0.5 s poll.
///
/// Every AX call to Ghostty has a `messagingTimeout` (a hung Ghostty stalls the main thread
/// at most that long per call), and attaching stops at the first call that times out.
@MainActor
final class GhosttyFocusEvents {
  /// Called on the main thread for each event.
  var onEvent: (@MainActor (SeenEventGate.Trigger) -> Void)?
  private var subscription: AXSubscription?

  static let messagingTimeout: Float = 0.5

  /// The process the observer is attached to, nil when detached.
  var pid: pid_t? { subscription?.pid }
  var attached: Bool { subscription != nil }
  /// Why the last attach failed (for GET /debug/state), nil after a successful one.
  private(set) var lastFailure: AttachFailure?

  struct AttachFailure: Equatable {
    /// The call that failed: "create" or the notification's name.
    let step: String
    let error: AXError
    /// Ghostty did not answer within `messagingTimeout`.
    var timedOut: Bool { error == .cannotComplete }
    var description: String { "\(step): \(GhosttyFocusEvents.name(error)) (\(error.rawValue))" }
  }

  nonisolated static func name(_ error: AXError) -> String {
    switch error {
    case .success: "success"
    case .failure: "failure"
    case .illegalArgument: "illegalArgument"
    case .invalidUIElement: "invalidUIElement"
    case .invalidUIElementObserver: "invalidUIElementObserver"
    case .cannotComplete: "cannotComplete"
    case .attributeUnsupported: "attributeUnsupported"
    case .actionUnsupported: "actionUnsupported"
    case .notificationUnsupported: "notificationUnsupported"
    case .notImplemented: "notImplemented"
    case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
    case .notificationNotRegistered: "notificationNotRegistered"
    case .apiDisabled: "apiDisabled"
    case .noValue: "noValue"
    case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: "notEnoughPrecision"
    @unknown default: "unknown"
    }
  }

  /// Attaches to Ghostty's process `pid` (detaching from any other first). False when macOS
  /// refused (not trusted, Ghostty not ready or not answering).
  @discardableResult
  func attach(pid: pid_t) -> Bool {
    if subscription?.pid == pid { return true }
    detach()
    let sub: AXSubscription
    switch AXSubscription.make(pid: pid, onEvent: { [weak self] trigger in
      self?.onEvent?(trigger)
    }) {
    case .success(let made): sub = made
    case .failure(let error):
      lastFailure = AttachFailure(step: "create", error: error.code)
      return false
    }
    if let failure = sub.start() {
      // No unregistering: a Ghostty that timed out would stall each call again; releasing
      // the observer drops what did register.
      sub.invalidate(processAlive: false)
      lastFailure = failure
      return false
    }
    lastFailure = nil
    subscription = sub
    return true
  }

  /// Removes the observer and its run-loop source. `processAlive` false (Ghostty quit) skips
  /// unregistering from a process that is gone.
  func detach(processAlive: Bool = true) {
    subscription?.invalidate(processAlive: processAlive)
    subscription = nil
  }
}

/// One attached observer: owns the `AXObserver`, its run-loop source on the main run loop and
/// the registrations. `invalidate()` removes the source before the object can go away, so the
/// C callback (which holds an unretained pointer to it) never sees a freed object.
@MainActor
private final class AXSubscription {
  let pid: pid_t
  private let app: AXUIElement
  private let observer: AXObserver
  private let source: CFRunLoopSource
  private let onEvent: @MainActor (SeenEventGate.Trigger) -> Void
  /// The window whose title changes are registered (the focused one).
  private var titledWindow: AXUIElement?
  /// `SeenWatch.titleKey` of `titledWindow`'s title when last read.
  private var titleKey: String?
  private var live = true

  /// Notifications on the app element; the first two must register for the attach to count.
  /// No title change here: on the app element it would also come from every background window.
  private static let appNotifications = [
    kAXFocusedWindowChangedNotification,
    kAXFocusedUIElementChangedNotification,
    kAXMainWindowChangedNotification,
    kAXWindowCreatedNotification,
  ]
  private static let required = 2

  struct CreateError: Error { let code: AXError }

  static func make(
    pid: pid_t, onEvent: @escaping @MainActor (SeenEventGate.Trigger) -> Void
  ) -> Result<AXSubscription, CreateError> {
    var created: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, refcon in
      guard let refcon else { return }
      let sub = Unmanaged<AXSubscription>.fromOpaque(refcon).takeUnretainedValue()
      let name = notification as String
      MainActor.assumeIsolated { sub.handle(element, name) }
    }
    let err = AXObserverCreate(pid, callback, &created)
    guard err == .success, let created else {
      return .failure(CreateError(code: err == .success ? .failure : err))
    }
    return .success(AXSubscription(pid: pid, observer: created, onEvent: onEvent))
  }

  private init(
    pid: pid_t, observer: AXObserver, onEvent: @escaping @MainActor (SeenEventGate.Trigger) -> Void
  ) {
    self.pid = pid
    app = AXUIElementCreateApplication(pid)
    self.observer = observer
    source = AXObserverGetRunLoopSource(observer)
    self.onEvent = onEvent
    AXUIElementSetMessagingTimeout(app, GhosttyFocusEvents.messagingTimeout)
  }

  private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

  /// Registers the notifications and adds the source to the main run loop. Returns the failure
  /// when the required ones could not be registered or Ghostty timed out (the caller then
  /// invalidates); nil when attached.
  func start() -> GhosttyFocusEvents.AttachFailure? {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    for (i, name) in Self.appNotifications.enumerated() {
      let err = AXObserverAddNotification(observer, app, name as CFString, refcon)
      if err == .success || err == .notificationAlreadyRegistered { continue }
      // A timeout means Ghostty is not answering: stop instead of waiting on every call.
      if i < Self.required || err == .cannotComplete {
        return GhosttyFocusEvents.AttachFailure(step: name, error: err)
      }
    }
    followFocusedWindow()
    return nil
  }

  func invalidate(processAlive: Bool) {
    guard live else { return }
    live = false
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    // Releasing the observer drops its registrations too; unregistering first is tidier when
    // Ghostty still runs. No AX call once it has quit.
    if processAlive {
      if let w = titledWindow {
        AXObserverRemoveNotification(observer, w, kAXTitleChangedNotification as CFString)
        AXObserverRemoveNotification(observer, w, kAXUIElementDestroyedNotification as CFString)
      }
      for name in Self.appNotifications {
        AXObserverRemoveNotification(observer, app, name as CFString)
      }
    }
    titledWindow = nil
    titleKey = nil
  }

  private func handle(_ element: AXUIElement, _ name: String) {
    guard live else { return }
    switch name {
    case kAXTitleChangedNotification:
      // Only the focused window's title, and only when more than the spinner glyph changed.
      guard let w = titledWindow, CFEqual(w, element) else { return }
      let key = Self.titleKey(of: w)
      guard key != titleKey else { return }
      titleKey = key
      onEvent(.title)
    case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
      kAXWindowCreatedNotification:
      followFocusedWindow()
      onEvent(.focus)
    case kAXUIElementDestroyedNotification:
      if let w = titledWindow, CFEqual(w, element) {
        titledWindow = nil
        titleKey = nil
      }
    default:
      onEvent(.focus)
    }
  }

  /// Moves the title registration to the window that has focus now.
  private func followFocusedWindow() {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
    let window: AXUIElement? =
      err == .success && value != nil && CFGetTypeID(value) == AXUIElementGetTypeID()
      ? (value as! AXUIElement) : nil
    if let old = titledWindow, let window, CFEqual(old, window) { return }
    if let old = titledWindow {
      AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString)
      AXObserverRemoveNotification(observer, old, kAXUIElementDestroyedNotification as CFString)
    }
    titledWindow = nil
    titleKey = nil
    guard let window else { return }
    AXUIElementSetMessagingTimeout(window, GhosttyFocusEvents.messagingTimeout)
    let added = AXObserverAddNotification(
      observer, window, kAXTitleChangedNotification as CFString, refcon)
    if added == .success || added == .notificationAlreadyRegistered {
      titledWindow = window
      // The title it has now: its next spinner frame is no change.
      titleKey = Self.titleKey(of: window)
      AXObserverAddNotification(
        observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }
  }

  /// `SeenWatch.titleKey` of the window's title; nil when it could not be read (then any
  /// readable title next time counts as a change).
  private static func titleKey(of window: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
      let title = value as? String
    else { return nil }
    return SeenWatch.titleKey(title)
  }
}
