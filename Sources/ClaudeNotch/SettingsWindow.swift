import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// What the Settings window may do with the global shortcuts (the controller owns them).
@MainActor
struct ShortcutBridge {
  /// Registers a recorded shortcut; returns a Turkish error (previous one kept) or nil.
  var set: @MainActor (HotKeyRole, KeyCombo) -> String?
  var reset: @MainActor () -> Void
  /// A recorder is listening: our hot keys step aside so the chord reaches it.
  var pause: @MainActor (Bool) -> Void
  var registered: @MainActor (HotKeyRole) -> Bool
}

/// Small Settings window (gear / right-click > Ayarlar…).
@MainActor
final class SettingsWindowController {
  private var window: NSWindow?
  private let settings: NotchSettings
  private let shortcuts: ShortcutBridge
  private let modules: ModuleCenter

  init(settings: NotchSettings, shortcuts: ShortcutBridge, modules: ModuleCenter) {
    self.settings = settings
    self.shortcuts = shortcuts
    self.modules = modules
  }

  func close() {
    window?.close()
  }

  /// Window number (debug screenshots).
  var windowNumber: Int? { window?.windowNumber }

  func show() {
    if window == nil {
      let view = SettingsView(settings: settings, shortcuts: shortcuts, modules: modules)
      let hosting = NSHostingController(rootView: view)
      let w = NSWindow(contentViewController: hosting)
      w.title = "ClaudeNotch Ayarları"
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      w.setContentSize(NSSize(width: 460, height: 640))
      w.center()
      window = w
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  var isVisible: Bool { window?.isVisible ?? false }
}

struct SettingsView: View {
  @Bindable var settings: NotchSettings
  let shortcuts: ShortcutBridge
  let modules: ModuleCenter
  /// Bumped after a change so the "kaydedilemedi" notes re-read the registration state.
  @State private var revision = 0
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
  @State private var city = ""
  @State private var loginError: String?
  /// The one recorder listening (starting another stops it).
  @State private var recordingRole: HotKeyRole?

  var body: some View {
    Form {
      Section("Görünüm") {
        Picker("Ekran", selection: $settings.displayMode) {
          ForEach(DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Text(displayHelp).font(.caption).foregroundStyle(.secondary)
        Picker("Satırlar", selection: $settings.density) {
          ForEach(Density.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      }
      Section("Kısayollar") {
        ForEach(HotKeyRole.allCases, id: \.self) { role in
          ShortcutRecorder(
            role: role, active: $recordingRole, combo: settings.shortcut(role),
            registered: revision >= 0 && shortcuts.registered(role),
            record: { combo in
              defer { revision += 1 }
              return shortcuts.set(role, combo)
            },
            pause: shortcuts.pause)
        }
        HStack {
          Text(shortcutHelp).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button("Varsayılana dön") {
            shortcuts.reset()
            revision += 1
          }
          .disabled(HotKeyRole.allCases.allSatisfy {
            settings.shortcut($0) == KeyCombo.defaultCombo($0)
          })
        }
        Text("Panel açıkken: ⌘⏎ İzin ver · ⌘⇧⏎ Her zaman · ⌘⌫ Reddet · ←/→ istekler · "
          + "↑/↓ oturumlar · ⏎ terminale git · Esc kapat")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Bildirim") {
        Picker("İzin isteği görünür kalsın", selection: $settings.peekDuration) {
          ForEach(PeekDuration.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Text(peekHelp).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section("Bildirim sesleri") {
        ForEach(SoundEvent.allCases, id: \.self) { e in
          HStack {
            Toggle(e.title, isOn: Binding(
              get: { settings.soundEnabled(e) }, set: { settings.setSound(e, $0) }))
            Spacer()
            Picker("", selection: Binding(
              get: { settings.soundName(e) },
              set: {
                settings.setSoundName(e, $0)
                NSSound(named: NSSound.Name($0))?.play()
              })
            ) {
              ForEach(NotchSettings.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(!settings.soundEnabled(e))
          }
        }
        Toggle("Sessiz saatler", isOn: $settings.quietHours)
        if settings.quietHours {
          HStack {
            Picker("Başlangıç", selection: $settings.quietStart) {
              ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Picker("Bitiş", selection: $settings.quietEnd) {
              ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
          }
          Text("Bu aralıkta hiçbir ClaudeNotch sesi çalmaz; adalar yine düşer.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Modüller") {
        Toggle("Takvim: toplantıdan 10 dk önce hatırlat", isOn: $settings.calendarEnabled)
        Text("Google Takvim de çalışır: Sistem Ayarları > İnternet Hesapları > Google’da "
          + "Takvimler’i aç; macOS eşitler, ClaudeNotch oradan okur.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if settings.calendarEnabled {
          switch modules.calendarAccess {
          case .asking:
            Text("macOS takvim izni istiyor…").font(.caption).foregroundStyle(.secondary)
          case .denied:
            HStack {
              Text("Takvim izni verilmedi.").font(.caption).foregroundStyle(.orange)
              Spacer()
              Button("Sistem Ayarları’nı aç") { modules.openCalendar() }
            }
          default:
            EmptyView()
          }
        }
        Toggle(
          "Zamanlayıcı (panelin üst bandındaki ⏲ ile kurulur)", isOn: $settings.timerEnabled)
        if settings.timerEnabled {
          Picker("Pomodoro düzeni", selection: Binding(
            get: { PomoPreset.match(settings) }, set: { $0.apply(to: settings) })
          ) {
            ForEach(PomoPreset.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Stepper(
            "Odak: \(settings.pomoFocus) dk", value: $settings.pomoFocus, in: 5...180, step: 5)
          Stepper("Kısa mola: \(settings.pomoShort) dk", value: $settings.pomoShort, in: 1...60)
          Stepper(
            "Uzun mola: \(settings.pomoLong) dk", value: $settings.pomoLong, in: 1...90, step: 5)
          Stepper(
            "Uzun moladan önce: \(settings.pomoRounds) odak", value: $settings.pomoRounds,
            in: 1...8)
          Text("Ultradiyen döngü: beyin ~90 dk odak, ~20 dk dinlenme ritminde çalışır; uzun "
            + "işler için 90 / 20 düzenini seç.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Şarj: kablo takılınca ve pil %10’a inince", isOn: $settings.batteryEnabled)
        Toggle("Spotify: çalarken çentiğin yanında kapak", isOn: $settings.spotifyEnabled)
        if settings.spotifyEnabled {
          Toggle("Uygulamadayken kulakları çentiğe gizle", isOn: $settings.tuckEars)
          Text("Masaüstünde, tam ekranda ve şarkı değişince 3 sn kapak tam görünür; diğer "
            + "zamanlarda kapak çentiğin arkasına kayar, yalnız ucu görünür.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if settings.spotifyEnabled && modules.spotify.denied {
          Text("Spotify’ı kontrol izni verilmedi: Sistem Ayarları > Gizlilik ve Güvenlik > "
            + "Otomasyon > ClaudeNotch > Spotify.")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Hava durumu: panel bandında, yağmur yaklaşınca ada", isOn: $settings.weatherEnabled)
        if settings.weatherEnabled {
          HStack {
            TextField(
              "Şehir", text: $city, prompt: Text(modules.weather.place?.name ?? "ör. İstanbul"))
              .onSubmit { modules.weather.search(city) }
            Button("Bul") { modules.weather.search(city) }
              .disabled(city.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          Text(weatherHelp).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Claude planı: limit yüzdesi panel bandında", isOn: $settings.usageEnabled)
        if settings.usageEnabled && !modules.usage.hasData {
          Text("Claude Code bu yüzdeleri yalnız durum satırına verir. Bir kez çalıştır: "
            + "scripts/install-statusline.sh (durum satırı betiğine tek satır ekler, yedek alır).")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        Toggle("Raf: son 6 kopyalanan (metin, görüntü, dosya)", isOn: $settings.shelfEnabled)
        if settings.shelfEnabled {
          Text("Pano saniyede bir kontrol edilir; şifre yöneticilerinin gizli kopyaları alınmaz. "
            + "Raf geçici klasörde durur, kapatınca silinir.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("Modül adaları Claude bildirimlerinin önüne geçmez; bir Claude adası açıksa "
          + "sırasını bekler.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section("Başlangıç") {
        Toggle("Oturum açılışında başlat", isOn: Binding(
          get: { loginEnabled }, set: { setLogin($0) }))
        if let loginError {
          Text(loginError).font(.caption).foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
  }

  private var weatherHelp: String {
    switch modules.weather.searchNote {
    case .some(""): return "Aranıyor…"
    case .some(let s): return s
    case .none:
      return modules.weather.place == nil
        ? "Konum izni istenmez: şehrini yaz. Veri Open-Meteo’dan, 30 dk’da bir."
        : "Veri Open-Meteo’dan, 30 dk’da bir."
    }
  }

  private var shortcutHelp: String {
    let allow = settings.shortcut(.allow).display
    let deny = settings.shortcut(.deny).display
    return "\(allow) ve \(deny) her uygulamadan çalışır, odağı almaz; yalnızca ekranda "
      + "gösterilen isteğe uygulanır. Riskli komutta \(allow) basılı tutulur. "
      + "“Her zaman” için kısayol yoktur."
  }

  private var peekHelp: String {
    let allow = settings.shortcut(.allow).display
    let deny = settings.shortcut(.deny).display
    return "Süre dolunca istek çentiğin altındaki amber çizgide bekler (hook zaman aşımı "
      + "~10 dk). Üzerine gelmek açık tutar. Kapanmışken \(allow) / \(deny) önce isteği "
      + "geri getirir; karar ikinci basışta verilir."
  }

  private var displayHelp: String {
    switch settings.displayMode {
    case .automatic: return "Çentikli ekran her zaman; çalıştığınız ekran başkaysa orada bir hap."
    case .notchOnly: return "Yalnızca çentikli ekran (kapak kapalıyken ana ekran)."
    case .all: return "Çentikli ekran ve diğer tüm ekranlarda birer hap."
    }
  }

  private func setLogin(_ on: Bool) {
    let service = SMAppService.mainApp
    do {
      if on { try service.register() } else { try service.unregister() }
      loginError = nil
    } catch {
      loginError = "Değiştirilemedi: \(error.localizedDescription). "
        + "Uygulamanın /Applications altında olması gerekebilir."
    }
    loginEnabled = service.status == .enabled
  }
}

/// One global shortcut: click, then press the new chord (Esc cancels).
struct ShortcutRecorder: View {
  let role: HotKeyRole
  /// Which recorder listens; another one starting stops this one.
  @Binding var active: HotKeyRole?
  let combo: KeyCombo
  let registered: Bool
  let record: (KeyCombo) -> String?
  let pause: (Bool) -> Void
  @State private var recording = false
  @State private var monitor: Any?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(role.title) {
        Button(action: toggle) {
          Text(recording ? "Kısayola basın…" : combo.display)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(recording ? Color.accentColor : Color.primary)
            .frame(minWidth: 110)
        }
        .help(recording ? "Yeni kısayola basın; Esc vazgeçer" : "Değiştirmek için tıklayın")
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.orange)
      } else if !registered && !recording {
        Text("Kısayol kaydedilemedi; başka bir kısayol seçin.")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    .onDisappear(perform: stop)
    .onChange(of: active) { _, now in
      if now != role { stop() }
    }
  }

  private func toggle() {
    recording ? stop() : start()
  }

  private func start() {
    error = nil
    recording = true
    active = role
    pause(true)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      MainActor.assumeIsolated {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
          stop()
          return
        }
        guard let combo = KeyCombo(event: event) else {
          error = "En az bir değiştirici tuş kullanın: ⌃, ⌥ ya da ⌘."
          return
        }
        error = record(combo)
        stop()
      }
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard recording else { return }
    recording = false
    if active == role { active = nil }
    pause(false)
  }
}

/// Ready-made Pomodoro layouts; editing a value by hand shows "Özel".
enum PomoPreset: String, CaseIterable, Hashable {
  case classic
  case deep
  case ultradian
  case custom

  var title: String {
    switch self {
    case .classic: return "Klasik · 25 / 5, uzun 15"
    case .deep: return "Derin · 50 / 10, uzun 30"
    case .ultradian: return "Ultradiyen · 90 / 20"
    case .custom: return "Özel"
    }
  }

  private var values: (Int, Int, Int, Int)? {
    switch self {
    case .classic: return (25, 5, 15, 4)
    case .deep: return (50, 10, 30, 3)
    case .ultradian: return (90, 20, 30, 3)
    case .custom: return nil
    }
  }

  @MainActor
  static func match(_ s: NotchSettings) -> PomoPreset {
    allCases.first { p in
      guard let v = p.values else { return false }
      return v == (s.pomoFocus, s.pomoShort, s.pomoLong, s.pomoRounds)
    } ?? .custom
  }

  @MainActor
  func apply(to s: NotchSettings) {
    guard let v = values else { return }
    (s.pomoFocus, s.pomoShort, s.pomoLong, s.pomoRounds) = v
  }
}
