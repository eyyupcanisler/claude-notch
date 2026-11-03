import AppKit
import ClaudeNotchCore
import Network
import Observation
import Security

/// Google Calendar over its API, with the user's own "Desktop app" OAuth client. Sign-in runs
/// in the browser (PKCE, loopback redirect to 127.0.0.1); the client and the tokens live in the
/// macOS Keychain, never in a file or the repository. Read-only scope. Events of the next 12 h
/// are fetched every 5 min while the module is on (and after wake).
@MainActor
@Observable
final class GoogleCalendarModule {
  enum Status: Equatable {
    /// No OAuth client yet (Settings: choose the downloaded JSON).
    case noClient
    /// Client set, not signed in (or the sign-in expired).
    case signedOut
    case signingIn
    case connected
    case failed(String)
  }

  private(set) var status: Status = .noClient
  /// The signed-in account (primary calendar id = its address).
  private(set) var account: String?
  private(set) var lastSync: Date?

  /// New events after a fetch (the calendar module runs reminders on them).
  @ObservationIgnored var onEvents: (@MainActor ([CalendarItem]) -> Void)?

  @ObservationIgnored private var client: GoogleCalendar.Client?
  @ObservationIgnored private var tokens: GoogleCalendar.Tokens?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var enabled = false

  static let refresh: TimeInterval = 5 * 60

  init() {
    let dec = JSONDecoder()
    client = Keychain.load("client").flatMap {
      try? dec.decode(GoogleCalendar.Client.self, from: $0)
    }
    tokens = Keychain.load("tokens").flatMap {
      try? dec.decode(GoogleCalendar.Tokens.self, from: $0)
    }
    account = UserDefaults.standard.string(forKey: "google.account")
    status = client == nil ? .noClient : (tokens?.refreshToken == nil ? .signedOut : .connected)
  }

  var isReady: Bool { status == .connected }
  var isEnabled: Bool { enabled }

  func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    enabled = on
    if on {
      let t = Timer(timeInterval: Self.refresh, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.fetch() }
      }
      t.tolerance = 30
      RunLoop.main.add(t, forMode: .common)
      timer = t
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.fetch() }
      }
      Task { await fetch() }
    } else {
      timer?.invalidate()
      timer = nil
      if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
      wakeObserver = nil
      stopListener()
    }
  }

  // MARK: Client

  /// Settings: the client_secret_….json downloaded from Google Cloud.
  func chooseClientFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Google Cloud’dan indirdiğin istemci dosyasını (client_secret_….json) seç"
    panel.canChooseDirectories = false
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url)
    else { return }
    guard let c = GoogleCalendar.Client.parse(data) else {
      status = .failed("Bu bir Google “Masaüstü uygulaması” istemci dosyası değil.")
      return
    }
    client = c
    if let d = try? JSONEncoder().encode(c) { Keychain.save("client", d) }
    tokens = nil
    Keychain.delete("tokens")
    status = .signedOut
  }

  func disconnect() {
    tokens = nil
    Keychain.delete("tokens")
    account = nil
    UserDefaults.standard.removeObject(forKey: "google.account")
    status = client == nil ? .noClient : .signedOut
    onEvents?([])
  }

  /// Forgets the client too (Settings "İstemciyi kaldır").
  func removeClient() {
    disconnect()
    client = nil
    Keychain.delete("client")
    status = .noClient
  }

  // MARK: Sign-in

  func signIn() {
    guard let client else { return }
    stopListener()
    let verifier = GoogleCalendar.makeVerifier()
    let state = GoogleCalendar.makeVerifier()
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    guard let l = try? NWListener(using: params) else {
      status = .failed("Yerel giriş adresi açılamadı.")
      return
    }
    listener = l
    status = .signingIn
    l.newConnectionHandler = { [weak self] conn in
      Task { @MainActor in self?.handle(conn, client: client, verifier: verifier, state: state) }
    }
    l.stateUpdateHandler = { [weak self] st in
      Task { @MainActor in
        guard let self else { return }
        switch st {
        case .ready:
          guard let port = self.listener?.port?.rawValue else { return }
          let redirect = "http://127.0.0.1:\(port)"
          self.lastRedirect = redirect
          guard
            let url = GoogleCalendar.authURL(
              client: client, redirect: redirect, verifier: verifier, state: state)
          else { return }
          NSWorkspace.shared.open(url)
        case .failed:
          self.status = .failed("Yerel giriş adresi kapandı.")
          self.stopListener()
        default: break
        }
      }
    }
    l.start(queue: .main)
    // Abandoned sign-in: stop listening after 5 min.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(300))
      guard let self, self.status == .signingIn else { return }
      self.stopListener()
      self.status = .signedOut
    }
  }

  private func stopListener() {
    listener?.cancel()
    listener = nil
  }

  private func handle(
    _ conn: NWConnection, client: GoogleCalendar.Client, verifier: String, state: String
  ) {
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
      let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      let line = head.components(separatedBy: "\r\n").first ?? ""
      Task { @MainActor in
        guard let self else { return }
        let result = GoogleCalendar.callback(requestLine: line, state: state)
        let page: String
        switch result {
        case .ignore:
          Self.reply(conn, status: "404 Not Found", body: "")
          return
        case .error(let e):
          page = "Bağlantı kurulamadı (\(e)). Bu sekmeyi kapatıp Ayarlar’dan yeniden dene."
          self.status = .failed(
            e == "access_denied" ? "Google izni verilmedi." : "Giriş hatası: \(e)")
        case .code(let code):
          page = "ClaudeNotch Google Takvim’e bağlandı. Bu sekmeyi kapatabilirsin."
          Task { await self.exchange(code: code, client: client, verifier: verifier) }
        }
        Self.reply(conn, status: "200 OK", body: Self.html(page))
        self.stopListener()
      }
    }
  }

  private static func html(_ text: String) -> String {
    let safe = text.replacingOccurrences(of: "<", with: "&lt;")
    return "<!doctype html><meta charset=utf-8><title>ClaudeNotch</title>"
      + "<body style=\"font:16px -apple-system;background:#0b0b0d;color:#eee;display:grid;"
      + "place-items:center;height:90vh\"><p>\(safe)</p>"
  }

  private static func reply(_ conn: NWConnection, status: String, body: String) {
    let b = Data(body.utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(b.count)\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + b, completion: .contentProcessed { _ in conn.cancel() })
  }

  private func exchange(code: String, client: GoogleCalendar.Client, verifier: String) async {
    guard let redirect = lastRedirect else { return }
    let body = GoogleCalendar.form([
      ("client_id", client.clientID), ("client_secret", client.clientSecret), ("code", code),
      ("code_verifier", verifier), ("grant_type", "authorization_code"),
      ("redirect_uri", redirect),
    ])
    guard let data = await post(GoogleCalendar.tokenEndpoint, body),
      let t = GoogleCalendar.Tokens.parse(data, at: Date())
    else {
      status = .failed("Google jetonu alınamadı.")
      return
    }
    store(t)
    status = .connected
    await fetch()
  }

  /// The redirect of the sign-in in progress (the token request must repeat it exactly).
  @ObservationIgnored private var lastRedirect: String?

  private func store(_ t: GoogleCalendar.Tokens) {
    tokens = t
    if let d = try? JSONEncoder().encode(t) { Keychain.save("tokens", d) }
  }

  // MARK: Fetch

  private func accessToken() async -> String? {
    guard let client, let t = tokens else { return nil }
    if t.isFresh(at: Date()) { return t.accessToken }
    guard let refresh = t.refreshToken else { return nil }
    let body = GoogleCalendar.form([
      ("client_id", client.clientID), ("client_secret", client.clientSecret),
      ("grant_type", "refresh_token"), ("refresh_token", refresh),
    ])
    guard let data = await post(GoogleCalendar.tokenEndpoint, body) else { return nil }
    guard let fresh = GoogleCalendar.Tokens.parse(data, at: Date(), keeping: refresh) else {
      // invalid_grant: revoked, or a 7-day "Testing" client token expired.
      tokens = nil
      Keychain.delete("tokens")
      status = .failed("Google oturumu sona erdi; yeniden bağlan.")
      return nil
    }
    store(fresh)
    return fresh.accessToken
  }

  func fetch() async {
    guard enabled, let token = await accessToken() else { return }
    let listURL = "https://www.googleapis.com/calendar/v3/users/me/calendarList"
    guard let list = await get(listURL, token) else { return }
    let cals = GoogleCalendar.calendars(list)
    let ids = cals.map(\.id)
    let now = Date()
    let iso = ISO8601DateFormatter()
    var all: [CalendarItem] = []
    for cal in cals.prefix(12) {
      let id = cal.id
      let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@"))
      let path = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
      guard
        var c = URLComponents(
          string: "https://www.googleapis.com/calendar/v3/calendars/\(path)/events")
      else { continue }
      let until = now.addingTimeInterval(CalendarReminder.horizon)
      c.queryItems = [
        .init(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-3600))),
        .init(name: "timeMax", value: iso.string(from: until)),
        .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"),
        .init(name: "maxResults", value: "50"),
      ]
      guard let url = c.url, let data = await get(url.absoluteString, token) else { continue }
      all += GoogleCalendar.events(
        data, calendarID: id, defaultReminders: cal.defaultReminders)
    }
    if let primary = ids.first(where: { $0.contains("@") }), account != primary {
      account = primary
      UserDefaults.standard.set(primary, forKey: "google.account")
    }
    status = .connected
    lastSync = now
    onEvents?(all)
  }

  // MARK: HTTP

  private func post(_ url: String, _ body: Data) async -> Data? {
    guard let u = URL(string: url) else { return nil }
    var r = URLRequest(url: u)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.httpBody = body
    guard let (data, resp) = try? await URLSession.shared.data(for: r),
      (resp as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return data
  }

  private func get(_ url: String, _ token: String) async -> Data? {
    guard let u = URL(string: url) else { return nil }
    var r = URLRequest(url: u)
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    guard let (data, resp) = try? await URLSession.shared.data(for: r) else { return nil }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 {
      tokens?.expiresAt = .distantPast
    }
    return code == 200 ? data : nil
  }
}

/// Generic-password items of ClaudeNotch in the login keychain.
enum Keychain {
  static let service = "com.eyyupcan.claudenotch.google"

  static func save(_ account: String, _ data: Data) {
    delete(account)
    let q: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
    ]
    SecItemAdd(q as CFDictionary, nil)
  }

  static func load(_ account: String) -> Data? {
    let q: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
  }

  static func delete(_ account: String) {
    let q: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
    ]
    SecItemDelete(q as CFDictionary)
  }
}
