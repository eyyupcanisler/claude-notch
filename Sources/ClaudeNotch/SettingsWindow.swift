import AppKit
import ClaudeNotchCore
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// What the Settings window may do with the global shortcuts (the controller owns them).
@MainActor
struct ShortcutBridge {
  /// Registers a recorded shortcut; returns a localized error (previous one kept) or nil.
  var set: @MainActor (HotKeyRole, KeyCombo) -> String?
  var reset: @MainActor () -> Void
  /// Gives every role its default key with the preset's modifiers; returns, per role, why it
  /// kept its previous shortcut.
  var applyPreset: @MainActor (ShortcutPreset) -> [HotKeyRole: String]
  /// A recorder is listening: our hot keys step aside so the chord reaches it.
  var pause: @MainActor (Bool) -> Void
  var registered: @MainActor (HotKeyRole) -> Bool
}

/// Small Settings window (gear / right-click > Settings…).
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
      w.title = loc("ClaudeNotch Settings")
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      w.setContentSize(NSSize(width: 480, height: 620))
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
  /// Bumped after a change so the "could not be registered" notes re-read the registration state.
  @State private var revision = 0
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
  @State private var hooks = HookInstaller()
  @State private var city = ""
  @State private var loginError: String?
  /// The one recorder listening (starting another stops it).
  @State private var recordingRole: HotKeyRole?
  /// Roles the last preset could not change, with the reason (shown under each row).
  @State private var presetErrors: [HotKeyRole: String] = [:]

  var body: some View {
    TabView {
      Form {
        Section("Appearance") {
          Picker("Screens", selection: $settings.displayMode) {
            ForEach(DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Text(displayHelp).font(.caption).foregroundStyle(.secondary)
          Picker("Rows", selection: $settings.density) {
            ForEach(Density.allCases, id: \.self) { Text($0.title).tag($0) }
          }
        }
        Section("Claude Code connection") {
          HStack {
            switch hooks.state {
            case .installed:
              Label("Hooks installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            case .notInstalled:
              Label("Hooks not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            case .other:
              Label("Hooks call another copy", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            }
            Spacer()
            if hooks.busy {
              ProgressView().controlSize(.small)
            } else if hooks.state == .installed {
              Button("Remove") { hooks.uninstall() }
            } else {
              Button(hooks.state == .notInstalled ? "Install hooks" : "Connect to this app") {
                hooks.install()
              }
            }
          }
          Text(hooks.message ?? hookHelp)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        Section("Startup") {
          Toggle("Open at login", isOn: Binding(
            get: { loginEnabled }, set: { setLogin($0) }))
          if let loginError {
            Text(loginError).font(.caption).foregroundStyle(.orange)
          }
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("General", systemImage: "gearshape") }
      Form {
        Section("Calendar") {
          // The source comes first: choosing Google never triggers the macOS Calendar prompt.
          Picker("Source", selection: $settings.calendarGoogle) {
            Text("macOS Calendar").tag(false)
            Text("Google Calendar").tag(true)
          }
          .pickerStyle(.segmented)
          if settings.calendarGoogle {
            GoogleCalendarSettings(google: modules.google)
          } else {
            Text("Calendars from the macOS Calendar app (including Google accounts added in Internet Accounts). macOS asks for calendar access once when you turn this on.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("Remind me of meetings and show them in the panel", isOn: $settings.calendarEnabled)
        if settings.calendarEnabled {
        Toggle("Use the calendar’s own alert times", isOn: $settings.calendarOwnAlerts)
        Text(settings.calendarOwnAlerts
          ? "Each meeting is announced at the alert times set in its calendar (e.g. 1 h and 10 min before); a meeting without alerts is not announced."
          : "Each meeting is announced 10 min before.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
          if settings.calendarEnabled {
            switch modules.calendarAccess {
            case .asking:
              Text("macOS is asking for calendar access…").font(.caption).foregroundStyle(.secondary)
            case .denied:
              HStack {
                Text("Calendar access was not granted.").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open System Settings") { modules.openCalendar() }
              }
            default:
              EmptyView()
            }
          }
        }
        Section("Timer and Pomodoro") {
          Toggle(
            "Timer (set with ⏲ in the panel’s top band)", isOn: $settings.timerEnabled)
          if settings.timerEnabled {
            Picker("Pomodoro layout", selection: Binding(
              get: { PomoPreset.match(settings) }, set: { $0.apply(to: settings) })
            ) {
              ForEach(PomoPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper(
              "Focus: \(settings.pomoFocus) min", value: $settings.pomoFocus, in: 5...180, step: 5)
            Stepper("Short break: \(settings.pomoShort) min", value: $settings.pomoShort, in: 1...60)
            Stepper(
              "Long break: \(settings.pomoLong) min", value: $settings.pomoLong, in: 1...90, step: 5)
            Stepper(
              "Focus rounds before a long break: \(settings.pomoRounds)", value: $settings.pomoRounds,
              in: 1...8)
            Text("Ultradian cycle: the brain works in a rhythm of ~90 min focus and ~20 min rest; choose 90 / 20 for long tasks.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Section("Other modules") {
          Toggle("Charging: when plugged in and when the battery drops to 10%", isOn: $settings.batteryEnabled)
          Toggle("Spotify: album art beside the notch while playing", isOn: $settings.spotifyEnabled)
          if settings.spotifyEnabled {
            Toggle("Tuck the art into the notch while you work in an app", isOn: $settings.tuckEars)
            Text("On the desktop, in full screen and for 3 s after a track change the art shows in full; otherwise it slides behind the notch and only its edge shows.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if settings.spotifyEnabled && modules.spotify.denied {
            Text("Permission to control Spotify was not granted: System Settings > Privacy & Security > Automation > ClaudeNotch > Spotify.")
              .font(.caption).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle(
            "Weather: in the panel band, an island when rain is near", isOn: $settings.weatherEnabled)
          if settings.weatherEnabled {
            HStack {
              TextField(
                "City", text: $city, prompt: Text(modules.weather.place?.name ?? loc("e.g. Istanbul")))
                .onSubmit { modules.weather.search(city) }
              Button("Find") { modules.weather.search(city) }
                .disabled(city.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(weatherHelp).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("Claude plan: usage limit percentage in the panel band", isOn: $settings.usageEnabled)
          if settings.usageEnabled && !modules.usage.hasData {
            Text("Claude Code gives these percentages only to the status line. Run once: scripts/install-statusline.sh (adds one line to your status line script, after a backup).")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
          Toggle("Shelf: last 6 copied items (text, images, files)", isOn: $settings.shelfEnabled)
          if settings.shelfEnabled {
            Text("The clipboard is checked once a second; concealed copies from password managers are skipped. Unpinned items are removed after 3 days and when the app restarts. Turning the shelf off deletes everything, pinned items too.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text("Module islands never get ahead of Claude notifications; while a Claude island is open they wait their turn.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
      Form {
        Section("Notification") {
          Picker("Keep permission requests visible", selection: $settings.peekDuration) {
            ForEach(PeekDuration.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Text(peekHelp).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Section("Notification sounds") {
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
          Toggle("Silent mode: only permission requests and questions", isOn: $settings.silentMode)
          Text("Also toggled with 🔔 in the panel band. “Done” and module islands and their sounds stay quiet; everything still shows in the panel.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Toggle("Quiet hours", isOn: $settings.quietHours)
          if settings.quietHours {
            HStack {
              Picker("From", selection: $settings.quietStart) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
              }
              Picker("To", selection: $settings.quietEnd) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
              }
            }
            Text("No ClaudeNotch sound plays in this window; islands still drop.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Notifications", systemImage: "bell") }
      Form {
        Section("Shortcuts") {
          ForEach(HotKeyRole.configurable, id: \.self) { role in
            ShortcutRecorder(
              role: role, active: $recordingRole, combo: settings.shortcut(role),
              registered: revision >= 0 && shortcuts.registered(role),
              presetError: presetErrors[role],
              record: { combo in
                defer { revision += 1 }
                presetErrors[role] = nil
                return shortcuts.set(role, combo)
              },
              pause: shortcuts.pause)
          }
          Text(shortcutHelp).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Use Caps Lock (Hyper key)") {
              recordingRole = nil
              presetErrors = shortcuts.applyPreset(.hyper)
              revision += 1
            }
            .disabled(usesPreset(.hyper))
            Spacer(minLength: 8)
            Button("Reset to defaults") {
              recordingRole = nil
              shortcuts.reset()
              presetErrors = [:]
              revision += 1
            }
            .disabled(usesPreset(.standard))
          }
          Text("Needs a tool that turns Caps Lock into ⌃⌥⇧⌘: Raycast (Settings > Advanced > Hyper Key), Hyperkey or Karabiner-Elements.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text("While the panel is open: ⌘⏎ Allow · ⌘⇧⏎ Always · ⌘⌫ Deny · ←/→ requests · ↑/↓ sessions · ⏎ go to terminal · Esc close")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Shortcuts", systemImage: "keyboard") }
    }
    .frame(width: 480, height: 620)
  }

  private var hookHelp: String {
    switch hooks.state {
    case .installed:
      return loc("Claude Code events and permission requests come to this app.")
    case .notInstalled:
      return loc("To bring Claude Code’s status and permission requests to the notch, hooks are added to ~/.claude/settings.json (after a backup; your other settings stay untouched).")
    case .other(let path):
      return loc("\(path) is in use right now (an install from source). If it works, it can stay that way.")
    }
  }

  private var weatherHelp: String {
    switch modules.weather.searchNote {
    case .some(""): return loc("Searching…")
    case .some(let s): return s
    case .none:
      return modules.weather.place == nil
        ? loc("No location permission needed: type your city. Data from Open-Meteo, every 30 min.")
        : loc("Data from Open-Meteo, every 30 min.")
    }
  }

  /// Every shortcut is the preset's (default key + the preset's modifiers).
  private func usesPreset(_ preset: ShortcutPreset) -> Bool {
    HotKeyRole.configurable.allSatisfy {
      settings.shortcut($0) == KeyCombo.presetCombo($0, preset)
    }
  }

  private var shortcutHelp: String {
    let allow = settings.shortcut(.allow).display
    let deny = settings.shortcut(.deny).display
    return loc("\(allow) and \(deny) work from any app without taking focus; they apply only to the request on screen. For a risky command, hold \(allow). “Always” has no shortcut.")
  }

  private var peekHelp: String {
    let allow = settings.shortcut(.allow).display
    let deny = settings.shortcut(.deny).display
    return loc("When time runs out, the request waits in the yellow line under the notch (hook timeout ~10 min). Hovering keeps it open. Once it has closed, \(allow) / \(deny) first bring the request back; the second press decides.")
  }

  private var displayHelp: String {
    switch settings.displayMode {
    case .automatic: return loc("The notched screen always; a pill on the screen you work on when that is another one.")
    case .notchOnly: return loc("Only the notched screen (the main screen while the lid is closed).")
    case .all: return loc("The notched screen, plus a pill on every other screen.")
    }
  }

  private func setLogin(_ on: Bool) {
    let service = SMAppService.mainApp
    do {
      if on { try service.register() } else { try service.unregister() }
      // Remembered so a reinstalled copy (scripts/install-app.sh) registers itself again.
      UserDefaults.standard.set(on, forKey: "loginWanted")
      loginError = nil
    } catch {
      loginError = loc("Could not change it: \(error.localizedDescription). The app may need to be in /Applications.")
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
  /// Why the last preset left this role unchanged (nil: it applied, or no preset was used).
  var presetError: String?
  let record: (KeyCombo) -> String?
  let pause: (Bool) -> Void
  @State private var recording = false
  @State private var monitor: Any?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(role.title) {
        Button(action: toggle) {
          Text(recording ? loc("Press a shortcut…") : combo.display)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(recording ? Color.accentColor : Color.primary)
            .frame(minWidth: 110)
        }
        .help(recording ? "Press the new shortcut; Esc cancels" : "Click to change")
      }
      if let error = error ?? presetError {
        Text(error).font(.caption).foregroundStyle(.orange)
      } else if !registered && !recording {
        Text("The shortcut could not be registered; choose another one.")
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
          error = loc("Use at least one modifier key: ⌃, ⌥ or ⌘.")
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

/// Ready-made Pomodoro layouts; editing a value by hand shows "Custom".
enum PomoPreset: String, CaseIterable, Hashable {
  case classic
  case deep
  case ultradian
  case custom

  var title: String {
    switch self {
    case .classic: return loc("Classic · 25 / 5, long 15")
    case .deep: return loc("Deep · 50 / 10, long 30")
    case .ultradian: return loc("Ultradian · 90 / 20")
    case .custom: return loc("Custom")
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

/// Google Calendar connection: the OAuth client file, sign-in, status.
struct GoogleCalendarSettings: View {
  let google: GoogleCalendarModule

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        switch google.status {
        case .noClient:
          Button("Choose client file…") { google.chooseClientFile() }
        case .signedOut, .failed:
          Button("Connect with Google") { google.signIn() }
          Button("Change client file…") { google.chooseClientFile() }
        case .signingIn:
          ProgressView().controlSize(.small)
          Text("Finish the Google sign-in in your browser…").font(.caption)
          Button("Cancel") { google.disconnect() }
        case .connected:
          Button("Sync now") { Task { await google.fetch() } }
          Button("Disconnect") { google.disconnect() }
        }
      }
      Text(statusLine).font(.caption).foregroundStyle(statusColor)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }

  private var statusLine: String {
    switch google.status {
    case .noClient:
      return loc("Create a “Desktop app” OAuth client in Google Cloud and choose the JSON file you downloaded (steps in the README). It is kept in a file only you can read.")
    case .signedOut: return loc("The client is ready. Press Connect to open the Google sign-in in your browser.")
    case .signingIn: return loc("Sign-in is in your browser; this screen updates by itself when it is done.")
    case .connected:
      let who = google.account.map { loc("\($0) connected") } ?? loc("Connected")
      let when = google.lastSync.map { loc(" · last sync \(ModuleCenter.clock($0))") } ?? ""
      return who + when + loc(" · read-only")
    case .failed(let m): return m
    }
  }

  private var statusColor: Color {
    if case .failed = google.status { return .orange }
    return .secondary
  }
}
