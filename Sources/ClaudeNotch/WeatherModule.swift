import AppKit
import ClaudeNotchCore
import Observation

/// Weather for one city the user typed (no location permission): Open-Meteo, no API key.
/// One request every 30 min while on (and after wake); a single "yağmur geliyor" note when
/// rain becomes likely within 2 h while it is dry.
@MainActor
@Observable
final class WeatherModule {
  private(set) var now: WeatherNow?
  private(set) var place: WeatherPlace?
  /// A search in Settings: nil idle, "" running, text = result / error line.
  private(set) var searchNote: String?

  @ObservationIgnored var onNote: (@MainActor (ModuleNote) -> Void)?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?
  @ObservationIgnored private var lastRainHour: Date?
  @ObservationIgnored private let defaults = UserDefaults.standard

  static let refresh: TimeInterval = 30 * 60

  init() {
    if let d = defaults.data(forKey: "module.weatherPlace") {
      place = try? JSONDecoder().decode(WeatherPlace.self, from: d)
    }
  }

  func setEnabled(_ on: Bool) {
    if on, timer == nil {
      let t = Timer(timeInterval: Self.refresh, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.fetch() }
      }
      t.tolerance = 120
      RunLoop.main.add(t, forMode: .common)
      timer = t
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.fetch() }
      }
      Task { await fetch() }
    } else if !on, let t = timer {
      t.invalidate()
      timer = nil
      if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
      wakeObserver = nil
      now = nil
    }
  }

  /// Settings: look the city up and keep the first match.
  func search(_ name: String) {
    let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty,
      var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
    else { return }
    c.queryItems = [
      .init(name: "name", value: q), .init(name: "count", value: "1"),
      .init(name: "language", value: "tr"),
    ]
    guard let url = c.url else { return }
    searchNote = ""
    Task {
      guard let (data, _) = try? await URLSession.shared.data(from: url),
        let p = WeatherPlace.geocoding(data)
      else {
        searchNote = "“\(q)” bulunamadı."
        return
      }
      place = p
      if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: "module.weatherPlace") }
      searchNote = String(format: "%@ (%.2f, %.2f)", p.name, p.latitude, p.longitude)
      now = nil
      await fetch()
    }
  }

  private func fetch() async {
    guard timer != nil, let p = place,
      var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
    else { return }
    c.queryItems = [
      .init(name: "latitude", value: String(p.latitude)),
      .init(name: "longitude", value: String(p.longitude)),
      .init(name: "current", value: "temperature_2m,weather_code,is_day"),
      .init(name: "hourly", value: "precipitation_probability"),
      .init(name: "forecast_hours", value: "4"), .init(name: "timezone", value: "UTC"),
      .init(name: "timeformat", value: "unixtime"),
    ]
    guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
      let w = WeatherNow.openMeteo(data, at: Date())
    else { return }
    now = w
    if let (hour, chance) = w.rainSoon(now: Date()), hour != lastRainHour {
      lastRainHour = hour
      onNote?(
        ModuleNote(
          source: .weather, id: "rain:\(Int(hour.timeIntervalSince1970))",
          title: "Yağmur bekleniyor",
          subtitle: "\(p.name) · \(ModuleCenter.clock(hour)) civarı %\(chance)",
          digits: "\(chance)", unit: "%", validUntil: hour))
    }
  }
}
