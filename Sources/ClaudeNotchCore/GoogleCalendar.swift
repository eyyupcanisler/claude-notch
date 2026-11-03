import CryptoKit
import Foundation

/// Pure parts of the Google Calendar connection (OAuth 2.0 for installed apps with PKCE and a
/// loopback redirect, Calendar API v3 replies). The app layer does the networking.
public enum GoogleCalendar {
  public static let scope = "https://www.googleapis.com/auth/calendar.readonly"
  public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
  public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

  /// The "Desktop app" OAuth client the user created (client_secret_….json from Google Cloud).
  public struct Client: Sendable, Equatable, Codable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
      self.clientID = clientID
      self.clientSecret = clientSecret
    }

    /// Reads Google's downloaded JSON (`{"installed": {"client_id", "client_secret", …}}`).
    public static func parse(_ data: Data) -> Client? {
      guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inst = (root["installed"] ?? root["web"]) as? [String: Any],
        let id = inst["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com")
      else { return nil }
      return Client(clientID: id, clientSecret: inst["client_secret"] as? String)
    }
  }

  public struct Tokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.expiresAt = expiresAt
    }

    /// Valid for at least another minute.
    public func isFresh(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) > 60 }

    /// Parses the token endpoint reply; a refresh reply keeps the old refresh token.
    public static func parse(_ data: Data, at t: Date, keeping old: String? = nil) -> Tokens? {
      guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let access = root["access_token"] as? String
      else { return nil }
      let ttl = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
      return Tokens(
        accessToken: access, refreshToken: root["refresh_token"] as? String ?? old,
        expiresAt: t.addingTimeInterval(ttl))
    }
  }

  // MARK: PKCE

  /// A random code verifier (43–128 unreserved characters).
  public static func makeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    return base64URL(Data(bytes))
  }

  public static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  public static func authURL(client: Client, redirect: String, verifier: String, state: String)
    -> URL?
  {
    var c = URLComponents(string: authEndpoint)
    c?.queryItems = [
      .init(name: "client_id", value: client.clientID),
      .init(name: "redirect_uri", value: redirect),
      .init(name: "response_type", value: "code"),
      .init(name: "scope", value: scope),
      .init(name: "code_challenge", value: challenge(for: verifier)),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "state", value: state),
      // A refresh token on every consent (the app may have lost the old one).
      .init(name: "access_type", value: "offline"),
      .init(name: "prompt", value: "consent"),
    ]
    return c?.url
  }

  /// Form body for the token endpoint.
  public static func form(_ fields: [(String, String?)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let s = fields.compactMap { k, v in
      v.map { "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
    }.joined(separator: "&")
    return Data(s.utf8)
  }

  /// `GET /?code=…&state=…` (or `?error=…`) on the loopback listener.
  public enum Callback: Equatable {
    case code(String)
    case error(String)
    case ignore
  }

  public static func callback(requestLine: String, state: String) -> Callback {
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
      let c = URLComponents(string: "http://127.0.0.1" + parts[1])
    else { return .ignore }
    let q = Dictionary(
      (c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    if let e = q["error"] { return .error(e) }
    guard let code = q["code"], !code.isEmpty else { return .ignore }
    return q["state"] == state ? .code(code) : .error("state_mismatch")
  }

  // MARK: Calendar API

  /// A calendar the user shows in Google Calendar, with its default reminders (minutes).
  public struct CalendarRef: Sendable, Equatable {
    public var id: String
    public var defaultReminders: [Int]
  }

  /// Calendars the user shows in Google Calendar (`selected`), plus the primary one.
  public static func calendars(_ data: Data) -> [CalendarRef] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = root["items"] as? [[String: Any]]
    else { return [] }
    return items.compactMap { c in
      guard let id = c["id"] as? String else { return nil }
      let shown = c["selected"] as? Bool ?? false
      let primary = c["primary"] as? Bool ?? false
      let hidden = c["hidden"] as? Bool ?? false
      guard (shown || primary) && !hidden else { return nil }
      return CalendarRef(id: id, defaultReminders: minutes(c["defaultReminders"]))
    }
  }

  public static func calendarIDs(_ data: Data) -> [String] { calendars(data).map(\.id) }

  /// Minutes of the popup reminders in a `[{method, minutes}]` list (email ones only notify
  /// by mail, so they are left out).
  static func minutes(_ v: Any?) -> [Int] {
    (v as? [[String: Any]] ?? []).compactMap { r in
      guard (r["method"] as? String ?? "popup") == "popup" else { return nil }
      return (r["minutes"] as? NSNumber)?.intValue
    }
  }

  /// Events of `events.list?singleEvents=true` as calendar items. Cancelled events and those
  /// the user declined are left out.
  public static func events(_ data: Data, calendarID: String, defaultReminders: [Int] = [])
    -> [CalendarItem]
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = root["items"] as? [[String: Any]]
    else { return [] }
    let iso = ISO8601DateFormatter()
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    day.locale = Locale(identifier: "en_US_POSIX")
    func date(_ v: Any?) -> (Date, Bool)? {
      guard let o = v as? [String: Any] else { return nil }
      if let s = o["dateTime"] as? String, let d = iso.date(from: s) ?? isoFrac.date(from: s) {
        return (d, false)
      }
      if let s = o["date"] as? String, let d = day.date(from: s) { return (d, true) }
      return nil
    }
    return items.compactMap { e in
      guard (e["status"] as? String) != "cancelled", let id = e["id"] as? String,
        let (start, allDay) = date(e["start"]), let (end, _) = date(e["end"])
      else { return nil }
      let attendees = e["attendees"] as? [[String: Any]] ?? []
      if attendees.contains(where: {
        ($0["self"] as? Bool ?? false) && ($0["responseStatus"] as? String) == "declined"
      }) {
        return nil
      }
      var join = (e["hangoutLink"] as? String).flatMap(URL.init(string:))
      if join == nil, let conf = e["conferenceData"] as? [String: Any],
        let points = conf["entryPoints"] as? [[String: Any]],
        let video = points.first(where: { ($0["entryPointType"] as? String) == "video" }),
        let uri = video["uri"] as? String
      {
        join = URL(string: uri)
      }
      if let j = join, j.scheme != "https" { join = nil }
      let title = (e["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Etkinlik"
      // reminders.useDefault: the calendar's defaults; else the event's overrides (possibly
      // none: the event asked for no reminder).
      let rem = e["reminders"] as? [String: Any]
      let useDefault = rem?["useDefault"] as? Bool ?? true
      let mins = useDefault ? defaultReminders : minutes(rem?["overrides"])
      return CalendarItem(
        id: "g:\(calendarID):\(id)", title: title, start: start, end: end, isAllDay: allDay,
        location: e["location"] as? String, joinURL: join,
        alerts: mins.map { TimeInterval($0 * 60) })
    }
  }
}
