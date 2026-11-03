import Foundation

// Pure logic of the non-Claude modules (calendar, timer, battery). The app adapters only feed
// them system events; nothing here polls.

// MARK: - Calendar

/// One calendar event, as much as the notch needs.
public struct CalendarItem: Sendable, Equatable {
  public var id: String
  public var title: String
  public var start: Date
  public var end: Date
  public var isAllDay: Bool
  public var location: String?

  public init(
    id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
    location: String? = nil
  ) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.location = location
  }
}

public enum CalendarReminder {
  /// A reminder drops this long before an event.
  public static let lead: TimeInterval = 10 * 60
  /// The panel tile shows events starting within this window.
  public static let horizon: TimeInterval = 12 * 3600

  /// The next timed event that has not ended and starts within the horizon (all-day events
  /// never count: they would fill the tile all day).
  public static func next(_ items: [CalendarItem], now: Date) -> CalendarItem? {
    items
      .filter { !$0.isAllDay && $0.end > now && $0.start.timeIntervalSince(now) <= horizon }
      .min { $0.start < $1.start }
  }

  /// When the reminder for `item` is due (`lead` before its start).
  public static func dueAt(_ item: CalendarItem) -> Date { item.start.addingTimeInterval(-lead) }

  /// Events whose reminder is due now and was not shown yet, earliest first. An event already
  /// running is never reminded (the app may have started late).
  public static func due(_ items: [CalendarItem], now: Date, shown: Set<String>) -> [CalendarItem] {
    items
      .filter { !$0.isAllDay && !shown.contains($0.id) && dueAt($0) <= now && $0.start > now }
      .sorted { $0.start < $1.start }
  }

  /// The next moment a reminder becomes due (the one wake-up to schedule), nil when none.
  public static func nextWake(_ items: [CalendarItem], now: Date, shown: Set<String>) -> Date? {
    items
      .filter { !$0.isAllDay && !shown.contains($0.id) && $0.start > now }
      .map { max(now, dueAt($0)) }
      .min()
  }

  /// "10 dk" / "şimdi" until the start, whole minutes rounded up.
  public static func untilText(_ item: CalendarItem, now: Date) -> (digits: String, unit: String) {
    let s = item.start.timeIntervalSince(now)
    if s <= 30 { return ("0", "dk") }
    let m = Int((s / 60).rounded(.up))
    if m < 60 { return ("\(m)", "dk") }
    return ("\(m / 60)", "sa")
  }
}

// MARK: - Timer

/// A focus timer: idle → running → (paused ↔ running) → finished → idle.
public struct FocusTimer: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case idle
    case running(endsAt: Date)
    case paused(remaining: TimeInterval)
    case finished(at: Date)
  }

  public private(set) var state: State = .idle
  public var duration: TimeInterval

  public init(duration: TimeInterval = 25 * 60) {
    self.duration = duration
  }

  public var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  /// One tap on the tile: start / pause / resume; a finished timer starts again.
  public mutating func toggle(at t: Date) {
    switch state {
    case .idle, .finished: state = .running(endsAt: t.addingTimeInterval(duration))
    case .running(let end): state = .paused(remaining: max(0, end.timeIntervalSince(t)))
    case .paused(let r): state = .running(endsAt: t.addingTimeInterval(r))
    }
  }

  public mutating func reset() {
    state = .idle
  }

  public func remaining(at t: Date) -> TimeInterval {
    switch state {
    case .idle: return duration
    case .running(let end): return max(0, end.timeIntervalSince(t))
    case .paused(let r): return r
    case .finished: return 0
    }
  }

  /// 0 at the start, 1 when done.
  public func progress(at t: Date) -> Double {
    guard duration > 0 else { return 1 }
    return min(1, max(0, 1 - remaining(at: t) / duration))
  }

  /// Moves a running timer whose time is up to `.finished`. Returns true on that edge only.
  @discardableResult
  public mutating func settle(at t: Date) -> Bool {
    guard case .running(let end) = state, end <= t else { return false }
    state = .finished(at: end)
    return true
  }
}

// MARK: - Battery

public struct PowerReading: Sendable, Equatable {
  public var onAC: Bool
  public var charging: Bool
  /// 0…100.
  public var percent: Int

  public init(onAC: Bool, charging: Bool, percent: Int) {
    self.onAC = onAC
    self.charging = charging
    self.percent = percent
  }
}

/// Turns power-source changes into notes on edges only: the cable plugged in, or the level
/// falling below the low mark on battery (once, re-armed above the mark + 5 or on AC).
public struct BatteryEdges: Sendable {
  public enum Event: Sendable, Equatable {
    case pluggedIn(percent: Int)
    case low(percent: Int)
  }

  public static let lowMark = 10
  private var last: PowerReading?
  private var lowShown = false

  public init() {}

  public mutating func update(_ r: PowerReading) -> Event? {
    defer { last = r }
    if r.onAC || r.percent > Self.lowMark + 5 { lowShown = false }
    guard let prev = last else { return nil }
    if r.onAC && !prev.onAC { return .pluggedIn(percent: r.percent) }
    if !r.onAC && r.percent <= Self.lowMark && !lowShown {
      lowShown = true
      return .low(percent: r.percent)
    }
    return nil
  }
}

// MARK: - Spotify

/// The track Spotify is on, from its `com.spotify.client.PlaybackStateChanged` notification
/// (or the one AppleScript query at start). Position is extrapolated while playing.
public struct NowPlaying: Sendable, Equatable {
  public var trackID: String
  public var title: String
  public var artist: String
  public var duration: TimeInterval
  public var position: TimeInterval
  public var isPlaying: Bool
  /// When `position` was read.
  public var readAt: Date

  public init(
    trackID: String, title: String, artist: String, duration: TimeInterval,
    position: TimeInterval, isPlaying: Bool, readAt: Date
  ) {
    self.trackID = trackID
    self.title = title
    self.artist = artist
    self.duration = duration
    self.position = position
    self.isPlaying = isPlaying
    self.readAt = readAt
  }

  public func position(at now: Date) -> TimeInterval {
    guard isPlaying else { return position }
    return min(duration, max(0, position + now.timeIntervalSince(readAt)))
  }

  /// Parses Spotify's notification; nil when playback stopped (nothing to show).
  public static func spotify(_ info: [AnyHashable: Any], at t: Date) -> NowPlaying? {
    let state = info["Player State"] as? String ?? "Stopped"
    guard state != "Stopped", let id = info["Track ID"] as? String else { return nil }
    let ms = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
    let pos = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
    return NowPlaying(
      trackID: id, title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
      duration: ms / 1000, position: pos, isPlaying: state == "Playing", readAt: t)
  }

  /// Parses the start-up AppleScript reply: state, name, artist, duration ms, position s, id,
  /// one per line (a decimal comma is accepted). nil when stopped or malformed.
  public static func spotifyScript(_ text: String, at t: Date) -> NowPlaying? {
    let f = text.components(separatedBy: "\n")
    guard f.count >= 6, f[0] != "stopped" else { return nil }
    let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    return NowPlaying(
      trackID: f[5], title: f[1], artist: f[2], duration: num(f[3]) / 1000, position: num(f[4]),
      isPlaying: f[0] == "playing", readAt: t)
  }

  /// "1:05" / "12:40".
  public static func clock(_ s: TimeInterval) -> String {
    let v = max(0, Int(s))
    return "\(v / 60):" + String(format: "%02d", v % 60)
  }
}

// MARK: - Shelf

/// One shelf item: copied text, a copied image (kept as a temp PNG) or a dropped / copied file.
public struct ShelfItem: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case text(String)
    /// PNG in the app's temp folder; `key` identifies the content (dedupe).
    case image(file: URL, key: String, width: Int, height: Int)
    case file(URL)
  }

  public var id: String
  public var kind: Kind
  public var addedAt: Date

  public init(id: String, kind: Kind, addedAt: Date) {
    self.id = id
    self.kind = kind
    self.addedAt = addedAt
  }

  /// Same content = same item (copying it again moves it to the front).
  var dedupeKey: String {
    switch kind {
    case .text(let s): return "t:" + s
    case .image(_, let key, _, _): return "i:" + key
    case .file(let u): return "f:" + u.path
    }
  }

  /// Temp file owned by the shelf (deleted when the item goes).
  public var ownedFile: URL? {
    if case .image(let file, _, _, _) = kind { return file }
    return nil
  }
}

/// The newest `capacity` items, newest first, without duplicates.
public struct Shelf: Sendable, Equatable {
  public static let capacity = 6
  /// Longer copied text is cut (the shelf is for snippets, not documents).
  public static let textLimit = 20_000

  public private(set) var items: [ShelfItem] = []

  public init() {}

  /// Adds `item` at the front. Returns the items that left the shelf (their temp files can go);
  /// a duplicate's old entry is among them only when it owns a different file.
  @discardableResult
  public mutating func add(_ item: ShelfItem) -> [ShelfItem] {
    var gone: [ShelfItem] = []
    if let i = items.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
      let old = items.remove(at: i)
      if old.ownedFile != item.ownedFile { gone.append(old) }
    }
    items.insert(item, at: 0)
    while items.count > Self.capacity { gone.append(items.removeLast()) }
    return gone
  }

  @discardableResult
  public mutating func remove(id: String) -> ShelfItem? {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
    return items.remove(at: i)
  }

  public mutating func clear() -> [ShelfItem] {
    defer { items = [] }
    return items
  }

  /// Clipboard types that mean "do not keep this" (password managers, transient data).
  public static let skippedTypes: Set<String> = [
    "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
    "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
  ]

  public static func shouldSkip(types: [String]) -> Bool {
    types.contains { skippedTypes.contains($0) }
  }

  /// Text as kept: trimmed of surrounding blank lines, cut at `textLimit`; nil when empty.
  public static func keepText(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    return t.count > textLimit ? String(t.prefix(textLimit)) : t
  }
}

// MARK: - Weather (Open-Meteo, no key)

public struct WeatherNow: Sendable, Equatable {
  public var temperature: Double
  public var code: Int
  public var isDay: Bool
  /// Next hours: (time, precipitation probability %).
  public var rainChances: [(Date, Int)]
  public var readAt: Date

  public static func == (a: WeatherNow, b: WeatherNow) -> Bool {
    a.temperature == b.temperature && a.code == b.code && a.isDay == b.isDay
      && a.readAt == b.readAt && a.rainChances.map(\.1) == b.rainChances.map(\.1)
  }

  public init(
    temperature: Double, code: Int, isDay: Bool, rainChances: [(Date, Int)], readAt: Date
  ) {
    self.temperature = temperature
    self.code = code
    self.isDay = isDay
    self.rainChances = rainChances
    self.readAt = readAt
  }

  /// "14°", "-3°" (rounded).
  public var degrees: String { "\(Int(temperature.rounded()))°" }

  /// It is raining / snowing / storming now (WMO codes 51…99).
  public var isWet: Bool { code >= 51 }

  /// The first hour within `window` whose chance reaches `threshold`, while it is dry now.
  public func rainSoon(now: Date, window: TimeInterval = 2 * 3600, threshold: Int = 60)
    -> (Date, Int)?
  {
    guard !isWet else { return nil }
    return rainChances.first { $0.0 > now && $0.0.timeIntervalSince(now) <= window && $0.1 >= threshold }
  }

  /// Parses `/v1/forecast?current=temperature_2m,weather_code,is_day&hourly=precipitation_probability`
  /// with `timezone=UTC` and `timeformat=unixtime`.
  public static func openMeteo(_ data: Data, at t: Date) -> WeatherNow? {
    struct Reply: Decodable {
      struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
      }
      struct Hourly: Decodable {
        let time: [Double]
        let precipitation_probability: [Int?]
      }
      let current: Current
      let hourly: Hourly?
    }
    guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
    let hours = zip(r.hourly?.time ?? [], r.hourly?.precipitation_probability ?? []).compactMap {
      time, p in p.map { (Date(timeIntervalSince1970: time), $0) }
    }
    return WeatherNow(
      temperature: r.current.temperature_2m, code: r.current.weather_code,
      isDay: r.current.is_day == 1, rainChances: hours, readAt: t)
  }

  /// Turkish label and an SF Symbol for a WMO weather code.
  public static func describe(code: Int, isDay: Bool) -> (text: String, symbol: String) {
    switch code {
    case 0: return ("Açık", isDay ? "sun.max.fill" : "moon.stars.fill")
    case 1, 2: return ("Parçalı bulutlu", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
    case 3: return ("Bulutlu", "cloud.fill")
    case 45, 48: return ("Sisli", "cloud.fog.fill")
    case 51...57: return ("Çiseliyor", "cloud.drizzle.fill")
    case 61...67, 80...82: return ("Yağmurlu", "cloud.rain.fill")
    case 71...77, 85, 86: return ("Karlı", "cloud.snow.fill")
    case 95...99: return ("Fırtınalı", "cloud.bolt.rain.fill")
    default: return ("", "cloud.fill")
    }
  }
}

/// A place from Open-Meteo's geocoding search.
public struct WeatherPlace: Sendable, Equatable, Codable {
  public var name: String
  public var latitude: Double
  public var longitude: Double

  public init(name: String, latitude: Double, longitude: Double) {
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
  }

  /// First result of `geocoding-api.open-meteo.com/v1/search?name=…&count=1`.
  public static func geocoding(_ data: Data) -> WeatherPlace? {
    struct Reply: Decodable {
      struct R: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
      }
      let results: [R]?
    }
    guard let r = try? JSONDecoder().decode(Reply.self, from: data), let f = r.results?.first
    else { return nil }
    return WeatherPlace(name: f.name, latitude: f.latitude, longitude: f.longitude)
  }
}

// MARK: - Claude plan usage (from the statusLine payload)

/// Plan limits as Claude Code reports them to the status line (`rate_limits`): the 5-hour and
/// the 7-day window, each a percentage and a reset time. Only Pro / Max / Ultra subscribers get
/// them, and a window disappears once its reset time has passed.
public struct PlanUsage: Sendable, Equatable {
  public struct Window: Sendable, Equatable {
    public var percent: Double
    public var resetsAt: Date

    public init(percent: Double, resetsAt: Date) {
      self.percent = percent
      self.resetsAt = resetsAt
    }
  }

  public var fiveHour: Window?
  public var sevenDay: Window?
  public var readAt: Date

  public init(fiveHour: Window?, sevenDay: Window?, readAt: Date) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.readAt = readAt
  }

  /// Parses the statusLine stdin JSON; nil when it has no usable window.
  public static func statusLine(_ data: Data, at t: Date) -> PlanUsage? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let limits = root["rate_limits"] as? [String: Any]
    else { return nil }
    func window(_ key: String) -> Window? {
      guard let w = limits[key] as? [String: Any],
        let p = (w["used_percentage"] as? NSNumber)?.doubleValue,
        let r = (w["resets_at"] as? NSNumber)?.doubleValue
      else { return nil }
      return Window(percent: min(100, max(0, p)), resetsAt: Date(timeIntervalSince1970: r))
    }
    let u = PlanUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), readAt: t)
    return u.fiveHour == nil && u.sevenDay == nil ? nil : u
  }

  /// Windows still running at `now` (a passed reset means the number is stale).
  public func live(at now: Date) -> PlanUsage {
    PlanUsage(
      fiveHour: fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
      sevenDay: sevenDay.flatMap { $0.resetsAt > now ? $0 : nil }, readAt: readAt)
  }

  /// The warning mark the 5-hour window just reached (80, then 95), or nil. `shown` holds
  /// "<reset>:<mark>" keys already warned for.
  public func newMark(shown: Set<String>) -> (mark: Int, key: String)? {
    guard let w = fiveHour else { return nil }
    for mark in [95, 80] where w.percent >= Double(mark) {
      let key = "\(Int(w.resetsAt.timeIntervalSince1970)):\(mark)"
      return shown.contains(key) ? nil : (mark, key)
    }
    return nil
  }
}

// MARK: - Pomodoro

/// Classic Pomodoro cycle: focus, short break, … and a long break after every 4th focus.
public struct Pomodoro: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self != .focus }
  }

  public var focusMinutes: Int
  public var shortMinutes: Int
  public var longMinutes: Int
  public var roundsBeforeLong: Int
  public private(set) var phase: Phase = .focus
  /// Focus blocks finished in the current set (0…roundsBeforeLong-1 while focusing).
  public private(set) var completed = 0

  public init(focus: Int = 25, short: Int = 5, long: Int = 15, rounds: Int = 4) {
    focusMinutes = focus
    shortMinutes = short
    longMinutes = long
    roundsBeforeLong = max(1, rounds)
  }

  public func minutes(_ p: Phase) -> Int {
    switch p {
    case .focus: return focusMinutes
    case .shortBreak: return shortMinutes
    case .longBreak: return longMinutes
    }
  }

  /// The focus block being worked on or next up, 1-based ("2/4").
  public var round: Int { min(completed, roundsBeforeLong - 1) + 1 }

  /// The current phase is over: moves to the next one and returns it.
  @discardableResult
  public mutating func advance() -> Phase {
    switch phase {
    case .focus:
      completed += 1
      phase = completed >= roundsBeforeLong ? .longBreak : .shortBreak
    case .shortBreak:
      phase = .focus
    case .longBreak:
      completed = 0
      phase = .focus
    }
    return phase
  }

  public mutating func reset() {
    phase = .focus
    completed = 0
  }
}
