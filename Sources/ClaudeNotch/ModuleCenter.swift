import AppKit
import ClaudeNotchCore
import EventKit
import IOKit.ps
import Observation

/// Calendar permission as the module sees it.
enum CalendarAccess: Equatable {
  case off
  case asking
  case granted
  case denied
}

/// The non-Claude modules: calendar reminders, the focus timer, battery notes. Event-driven
/// only: EventKit change notifications plus one scheduled wake, one timer task, the IOKit
/// power-source notification. Each module allocates nothing while it is switched off.
@MainActor
@Observable
final class ModuleCenter {
  @ObservationIgnored private let settings: NotchSettings
  /// A note for the peek (the controller decides whether it shows).
  @ObservationIgnored var onNote: (@MainActor (ModuleNote) -> Void)?

  // MARK: Calendar state
  private(set) var calendarAccess: CalendarAccess = .off
  private(set) var nextEvent: CalendarItem?
  @ObservationIgnored private var eventStore: EKEventStore?
  @ObservationIgnored private var events: [CalendarItem] = []
  @ObservationIgnored private var reminded: Set<String> = []
  @ObservationIgnored private var calendarObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var calendarWake: Task<Void, Never>?

  // MARK: Timer state
  private(set) var timer: FocusTimer
  /// Minutes being chosen in the tile ("Özel süre…"), nil when not choosing.
  private(set) var timerDraft: Int?
  @ObservationIgnored private var timerTask: Task<Void, Never>?

  // MARK: Battery state
  @ObservationIgnored private var battery: BatteryMonitor?

  let spotify = SpotifyModule()
  let shelf = ShelfModule()

  /// Ears beside the notch while the panel is closed: Spotify is playing.
  var earsVisible: Bool { settings.spotifyEnabled && spotify.isPlaying }
  /// Full ears (cover + waveform) only on the desktop, where Finder's short menu leaves room;
  /// with any other app in front the thin ears (sound waves) stay clear of its menus.
  var earsFull: Bool {
    !settings.tuckEars || desktop.isRoomy || spotify.justChanged
  }

  let desktop = DesktopWatch()

  init(settings: NotchSettings) {
    self.settings = settings
    timer = FocusTimer(duration: TimeInterval(settings.timerMinutes * 60))
    apply()
    track()
  }

  private func track() {
    withObservationTracking {
      _ = settings.calendarEnabled
      _ = settings.timerEnabled
      _ = settings.timerMinutes
      _ = settings.batteryEnabled
      _ = settings.spotifyEnabled
      _ = settings.shelfEnabled
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.apply()
        self?.track()
      }
    }
  }

  private func apply() {
    spotify.setEnabled(settings.spotifyEnabled)
    shelf.setEnabled(settings.shelfEnabled)
    if shelf.onImage == nil {
      shelf.onImage = { [weak self] item in self?.shelfNote(item) }
    }
    if settings.calendarEnabled { enableCalendar() } else { disableCalendar() }
    if !settings.timerEnabled { resetTimer() }
    if case .idle = timer.state { timer.duration = TimeInterval(settings.timerMinutes * 60) }
    if settings.batteryEnabled {
      if battery == nil {
        let m = BatteryMonitor { [weak self] event, reading, toFull in
          self?.batteryNote(event, reading: reading, toFull: toFull)
        }
        m.start()
        battery = m
      }
    } else {
      battery?.stop()
      battery = nil
    }
  }

  // MARK: - Calendar

  private func enableCalendar() {
    guard eventStore == nil, calendarAccess != .asking else { return }
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      startCalendar(EKEventStore())
    case .notDetermined:
      calendarAccess = .asking
      let store = EKEventStore()
      store.requestFullAccessToEvents { [weak self] granted, _ in
        Task { @MainActor in
          guard let self else { return }
          guard self.settings.calendarEnabled else {
            self.calendarAccess = .off
            return
          }
          if granted { self.startCalendar(EKEventStore()) } else { self.calendarAccess = .denied }
        }
      }
    default:
      calendarAccess = .denied
    }
  }

  private func startCalendar(_ store: EKEventStore) {
    eventStore = store
    calendarAccess = .granted
    let nc = NotificationCenter.default
    calendarObservers.append(
      nc.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.reloadCalendar() }
      })
    calendarObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.reloadCalendar() }
      })
    reloadCalendar()
  }

  private func disableCalendar() {
    calendarWake?.cancel()
    calendarWake = nil
    for o in calendarObservers {
      NotificationCenter.default.removeObserver(o)
      NSWorkspace.shared.notificationCenter.removeObserver(o)
    }
    calendarObservers = []
    eventStore = nil
    events = []
    nextEvent = nil
    if calendarAccess != .asking { calendarAccess = .off }
  }

  /// Fetches the next 12 hours (at most 60 events), fires due reminders, schedules one wake.
  private func reloadCalendar() {
    guard let store = eventStore else { return }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-3600),
      end: now.addingTimeInterval(CalendarReminder.horizon), calendars: nil)
    events = store.events(matching: predicate).prefix(60).map { e in
      CalendarItem(
        id: "\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))",
        title: e.title?.isEmpty == false ? e.title : "Etkinlik", start: e.startDate,
        end: e.endDate, isAllDay: e.isAllDay, location: e.location)
    }
    reminded.formIntersection(events.map(\.id))
    for item in CalendarReminder.due(events, now: now, shown: reminded) {
      reminded.insert(item.id)
      let until = CalendarReminder.untilText(item, now: now)
      let sub = [Self.clock(item.start), item.location].compactMap { $0 }.filter { !$0.isEmpty }
      onNote?(
        ModuleNote(
          source: .calendar, id: "cal:\(item.id)", title: item.title,
          subtitle: sub.joined(separator: " · "), digits: until.digits, unit: until.unit,
          validUntil: item.start))
      NSSound(named: NSSound.Name("Tink"))?.play()
    }
    nextEvent = CalendarReminder.next(events, now: now)
    scheduleCalendarWake(now)
  }

  /// One wake: the next reminder, the current event's end, or in an hour at the latest (an
  /// event that enters the 12 h window).
  private func scheduleCalendarWake(_ now: Date) {
    calendarWake?.cancel()
    var wake = now.addingTimeInterval(3600)
    if let r = CalendarReminder.nextWake(events, now: now, shown: reminded) { wake = min(wake, r) }
    if let next = nextEvent {
      wake = min(wake, next.start > now ? next.start : next.end)
    }
    let delay = max(1, wake.timeIntervalSince(now))
    calendarWake = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.reloadCalendar()
    }
  }

  static func clock(_ d: Date) -> String {
    d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  }

  /// Opens Calendar (tile click) or the calendar privacy pane (access denied).
  func openCalendar() {
    if calendarAccess == .denied,
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    {
      NSWorkspace.shared.open(url)
    } else if let app = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.iCal")
    {
      NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
  }

  // MARK: - Timer

  /// The pill under the notch while the panel is closed: a timer that runs or is paused.
  var timerPillVisible: Bool {
    switch timer.state {
    case .running, .paused: return settings.timerEnabled
    default: return false
    }
  }

  static let draftRange = 1...180

  /// "Özel süre…": the tile opens with a − / + chooser at the last duration.
  func beginTimerDraft() {
    timerDraft = settings.timerMinutes
  }

  /// One − / + step: 1 min under 10, 5 min above.
  func adjustTimerDraft(up: Bool) {
    guard let d = timerDraft else { return }
    let step = (up ? d >= 10 : d > 10) ? 5 : 1
    let next = up ? d + step : d - step
    timerDraft = min(Self.draftRange.upperBound, max(Self.draftRange.lowerBound, next))
  }

  func startTimerDraft() {
    guard let d = timerDraft else { return }
    timerDraft = nil
    startTimer(minutes: d)
  }

  /// Starts a fresh timer of `minutes` (the band's timer menu); the tile appears with it.
  func startTimer(minutes: Int) {
    timerDraft = nil
    settings.timerMinutes = minutes
    timerTask?.cancel()
    timer.reset()
    timer.duration = TimeInterval(minutes * 60)
    timer.toggle(at: Date())
    scheduleTimer()
  }

  /// Tile tap: pause / resume.
  func toggleTimer() {
    timer.toggle(at: Date())
    scheduleTimer()
  }

  func resetTimer() {
    timerDraft = nil
    timerTask?.cancel()
    timerTask = nil
    timer.reset()
    timer.duration = TimeInterval(settings.timerMinutes * 60)
  }

  private func scheduleTimer() {
    timerTask?.cancel()
    guard case .running(let end) = timer.state else { return }
    let minutes = Int(timer.duration / 60)
    timerTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
      guard !Task.isCancelled, let self, self.timer.settle(at: Date()) else { return }
      NSSound(named: NSSound.Name("Glass"))?.play()
      self.onNote?(
        ModuleNote(
          source: .timer, id: "timer:\(Int(end.timeIntervalSince1970))", title: "Zamanlayıcı bitti",
          subtitle: "\(minutes) dk odak tamamlandı", digits: "00:00",
          validUntil: Date().addingTimeInterval(600)))
    }
  }

  // MARK: - Shelf

  private func shelfNote(_ item: ShelfItem) {
    guard case .image(_, _, let w, let h) = item.kind else { return }
    onNote?(
      ModuleNote(
        source: .shelf, id: "shelf:\(item.id)", title: "Rafa eklendi",
        subtitle: "Görüntü · \(w)×\(h)", validUntil: Date().addingTimeInterval(10)))
  }

  // MARK: - Battery

  private func batteryNote(_ event: BatteryEdges.Event, reading: PowerReading, toFull: Int?) {
    let now = Date()
    switch event {
    case .pluggedIn(let p):
      var sub = "%\(p)"
      if p >= 100 {
        sub += " · dolu"
      } else if let m = toFull {
        sub += " · tam dolum " + (m >= 60 ? "\(m / 60) sa \(m % 60) dk" : "\(m) dk")
      }
      onNote?(
        ModuleNote(
          source: .battery, id: "ac:\(Int(now.timeIntervalSince1970))",
          title: reading.charging || p < 100 ? "Şarj oluyor" : "Güç bağlandı", subtitle: sub,
          level: Double(p) / 100, validUntil: now.addingTimeInterval(10)))
    case .low(let p):
      onNote?(
        ModuleNote(
          source: .battery, id: "low:\(Int(now.timeIntervalSince1970))", title: "Pil azaldı",
          subtitle: "%\(p) · şarj aletini tak", level: Double(p) / 100,
          validUntil: now.addingTimeInterval(120)))
    }
  }
}

/// IOKit power-source notifications on the main run loop. Fires `onEvent` on edges only
/// (see `BatteryEdges`). Macs without a battery never produce a reading.
@MainActor
final class BatteryMonitor {
  private var source: CFRunLoopSource?
  private var edges = BatteryEdges()
  private let onEvent: @MainActor (BatteryEdges.Event, PowerReading, Int?) -> Void

  init(onEvent: @escaping @MainActor (BatteryEdges.Event, PowerReading, Int?) -> Void) {
    self.onEvent = onEvent
  }

  func start() {
    guard source == nil else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      let src = IOPSNotificationCreateRunLoopSource(
        { context in
          guard let context else { return }
          let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
          // The source is on the main run loop.
          MainActor.assumeIsolated { monitor.read() }
        }, context)?.takeRetainedValue()
    else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    source = src
    // Prime the edge detector with the current state (no note at launch).
    if let r = Self.current() { _ = edges.update(r.reading) }
  }

  /// Must run before the monitor goes away (the callback holds it unretained).
  func stop() {
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    source = nil
  }

  private func read() {
    guard let r = Self.current(), let event = edges.update(r.reading) else { return }
    onEvent(event, r.reading, r.toFull)
  }

  /// The internal battery's state and minutes to a full charge (nil while unknown).
  static func current() -> (reading: PowerReading, toFull: Int?)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for ps in list {
      guard
        let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue()
          as? [String: Any],
        d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { continue }
      let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
      let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
      let reading = PowerReading(
        onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
        charging: d[kIOPSIsChargingKey] as? Bool ?? false,
        percent: max > 0 ? cur * 100 / max : cur)
      let toFull = (d[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
      return (reading, toFull)
    }
    return nil
  }
}
