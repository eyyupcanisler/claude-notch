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

  init(settings: NotchSettings, shortcuts: ShortcutBridge) {
    self.settings = settings
    self.shortcuts = shortcuts
  }

  func close() {
    window?.close()
  }

  /// Window number (debug screenshots).
  var windowNumber: Int? { window?.windowNumber }

  func show() {
    if window == nil {
      let view = SettingsView(settings: settings, shortcuts: shortcuts)
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
  /// Bumped after a change so the "kaydedilemedi" notes re-read the registration state.
  @State private var revision = 0
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
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
          Toggle(e.title, isOn: Binding(
            get: { settings.soundEnabled(e) }, set: { settings.setSound(e, $0) }))
        }
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
