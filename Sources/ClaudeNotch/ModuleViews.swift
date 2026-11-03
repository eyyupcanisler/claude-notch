import ClaudeNotchCore
import SwiftUI

/// Module tiles under the session rows (expanded panel). Empty, zero height, when no module
/// has anything to show.
struct ModuleStrip: View {
  let modules: ModuleCenter
  let settings: NotchSettings

  private var showCalendar: Bool {
    settings.calendarEnabled && (modules.nextEvent != nil || modules.calendarAccess == .denied)
  }

  /// The timer tile exists only while a timer was set (running, paused or just finished).
  private var showTimer: Bool {
    guard settings.timerEnabled else { return false }
    if case .idle = modules.timer.state { return modules.timerDraft != nil }
    return true
  }

  private var showSpotify: Bool { settings.spotifyEnabled && modules.spotify.nowPlaying != nil }
  private var showShelf: Bool { settings.shelfEnabled && !modules.shelf.shelf.items.isEmpty }

  var body: some View {
    if showCalendar || showTimer || showSpotify || showShelf {
      VStack(spacing: 8) {
        if showShelf { ShelfRow(shelf: modules.shelf) }
        if showSpotify { SpotifyTile(spotify: modules.spotify) }
        if showCalendar || showTimer {
          HStack(spacing: 8) {
            if showCalendar { CalendarTile(modules: modules) }
            if showTimer { TimerTile(modules: modules) }
          }
        }
      }
      .notchEnter(6)
    }
  }
}

/// Band button (idle timer only): pick a duration, the timer starts and its tile appears.
struct TimerStartMenu: View {
  let modules: ModuleCenter
  @State private var hover = false

  var body: some View {
    Menu {
      ForEach(NotchSettings.timerChoices, id: \.self) { m in
        Button("\(m) dk") { modules.startTimer(minutes: m) }
      }
      Divider()
      Button("Özel süre…") { modules.beginTimerDraft() }
    } label: {
      Image(systemName: "timer")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(hover ? NotchTheme.bandInk : NotchTheme.bandSecondary)
        .frame(width: 24, height: 24)
        .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { hover = $0 }
    .help("Zamanlayıcı kur")
    .accessibilityLabel("Zamanlayıcı kur")
  }
}

/// The shared tile frame: label, dot-matrix value, one line, a glow in the module colour.
struct ModuleTile<Value: View, Sub: View>: View {
  let label: String
  let tint: Color
  @ViewBuilder let value: Value
  @ViewBuilder let sub: Sub
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  static var height: CGFloat { 74 }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(theme.tertiary)
      value
      sub
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
    .background(
      shape.fill(theme.raised).overlay(CornerGlow(color: tint, strength: 0.4, radius: 140))
        .clipShape(shape))
    .overlay(shape.fill(hover ? Color.white.opacity(0.05) : .clear).allowsHitTesting(false))
    .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5))
    .contentShape(shape)
    .onHover { hover = $0 }
  }
}

struct CalendarTile: View {
  let modules: ModuleCenter
  @Environment(\.notchTheme) private var theme

  static let tint = Color(hex: 0x8FA6FF)

  var body: some View {
    Group {
      if modules.calendarAccess == .denied {
        ModuleTile(label: "TAKVİM", tint: theme.needs) {
          Text("İzin yok").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink)
        } sub: {
          Text("Sistem Ayarları’nda aç").font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
        }
      } else if let event = modules.nextEvent {
        // Minutes to go change once a minute; the tile is only alive while the panel is open.
        TimelineView(.periodic(from: .now, by: 30)) { context in
          let now = context.date
          let running = event.start <= now
          let until = CalendarReminder.untilText(event, now: now)
          ModuleTile(label: running ? "TAKVİM · ŞİMDİ" : "TAKVİM", tint: Self.tint) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
              if running {
                Text(ModuleCenter.clock(event.end) + "’e kadar")
                  .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Self.tint)
              } else {
                DotMatrixText(text: until.digits, color: Self.tint, pitch: 2.2)
                Text(until.unit + " sonra").font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(Self.tint.opacity(0.85))
              }
            }
          } sub: {
            Text("\(ModuleCenter.clock(event.start)) · \(event.title)")
              .font(.system(size: 10.5)).foregroundStyle(theme.secondary).lineLimit(1)
          }
        }
      }
    }
    .onTapGesture { modules.openCalendar() }
    .help("Takvimi aç")
  }
}

struct TimerTile: View {
  let modules: ModuleCenter
  @Environment(\.notchTheme) private var theme

  private var timer: FocusTimer { modules.timer }

  var body: some View {
    Group {
      if let draft = modules.timerDraft {
        draftTile(draft)
      } else if timer.isRunning {
        TimelineView(.periodic(from: .now, by: 1)) { context in tile(at: context.date) }
          .onTapGesture { modules.toggleTimer() }
      } else {
        tile(at: Date())
          .onTapGesture {
            if case .finished = timer.state { modules.resetTimer() } else { modules.toggleTimer() }
          }
      }
    }
    .overlay(alignment: .topTrailing) {
      Button { modules.resetTimer() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(theme.secondary)
          .frame(width: 20, height: 20)
          .background(Circle().fill(Color.white.opacity(0.08)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .padding(6)
      .help("Zamanlayıcıyı kapat")
      .accessibilityLabel("Zamanlayıcıyı kapat")
    }
  }

  /// "Özel süre…": − minutes + and Başlat.
  private func draftTile(_ minutes: Int) -> some View {
    let tint = theme.working
    return ModuleTile(label: "ZAMANLAYICI · SÜRE", tint: tint) {
      HStack(alignment: .center, spacing: 8) {
        stepButton("minus", up: false, enabled: minutes > ModuleCenter.draftRange.lowerBound)
        HStack(alignment: .lastTextBaseline, spacing: 3) {
          DotMatrixText(text: "\(minutes)", color: tint, pitch: 2.2)
          Text("dk").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint.opacity(0.85))
        }
        .frame(minWidth: 44)
        stepButton("plus", up: true, enabled: minutes < ModuleCenter.draftRange.upperBound)
        Button { modules.startTimerDraft() } label: {
          Text("Başlat")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(theme.primaryFill))
        }
        .buttonStyle(.plain)
      }
    } sub: {
      Text("1–180 dk").font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
    }
  }

  private func stepButton(_ icon: String, up: Bool, enabled: Bool) -> some View {
    Button { modules.adjustTimerDraft(up: up) } label: {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(theme.ink)
        .frame(width: 22, height: 22)
        .background(Circle().fill(Color.white.opacity(0.1)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.35)
    .disabled(!enabled)
    .accessibilityLabel(up ? "Süreyi artır" : "Süreyi azalt")
  }

  private func tile(at now: Date) -> some View {
    let remaining = timer.remaining(at: now)
    let tint = theme.working
    let (label, line): (String, String) = {
      switch timer.state {
      case .idle: return ("ZAMANLAYICI", "")
      case .running: return ("ZAMANLAYICI", "Duraklatmak için tıkla")
      case .paused: return ("ZAMANLAYICI · DURDU", "Sürdürmek için tıkla")
      case .finished: return ("ZAMANLAYICI · BİTTİ", "Kapatmak için tıkla")
      }
    }()
    return ModuleTile(label: label, tint: timer.isRunning ? tint : tint.opacity(0.5)) {
      HStack(alignment: .center, spacing: 8) {
        DotMatrixText(
          text: DotClock.countdown(remaining), color: timer.isRunning ? tint : tint.opacity(0.6),
          pitch: 2.2)
        TickArc(progress: timer.progress(at: now), count: 12)
          .stroke(tint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
          .background(
            TickArc(progress: 1, count: 12, track: true)
              .stroke(
                Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.3, lineCap: .round)))
          .frame(width: 26, height: 13)
      }
    } sub: {
      Text(line).font(.system(size: 10.5)).foregroundStyle(theme.tertiary).lineLimit(1)
    }
  }
}

/// The notch grown down by `NotchMetrics.pillHeight` with the remaining time inside, while the
/// panel is closed and a timer runs (or is paused).
struct TimerPill: View {
  let modules: ModuleCenter
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Group {
      if modules.timer.isRunning {
        TimelineView(.periodic(from: .now, by: 1)) { context in pill(at: context.date) }
      } else {
        pill(at: Date())
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Zamanlayıcı")
  }

  private func pill(at now: Date) -> some View {
    let running = modules.timer.isRunning
    let tint = running ? theme.working : theme.working.opacity(0.55)
    return HStack(spacing: 5) {
      Image(systemName: running ? "timer" : "pause.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(tint)
      DotMatrixText(
        text: DotClock.countdown(modules.timer.remaining(at: now)), color: tint, pitch: 1.7)
    }
    .padding(.top, NotchMetrics.pillOverlap)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The notch growing down: straight sides, rounded bottom.
    .background(
      UnevenRoundedRectangle(
        bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous
      ).fill(Color.black))
  }
}

/// Spotify while playing and the panel is closed, fused to the notch (each ear starts inside
/// it, so no gap shows). Full: a black ear on each side, the cover left, a waveform right.
/// Tucked (an app in front whose menu might reach the notch): the black ears fold away and the
/// cover and the waveform slide behind the notch with a slight tilt, only their edge peeking
/// out. The change runs one spring; nothing animates while the ears just sit there.
struct SpotifyEars: View {
  let spotify: SpotifyModule
  let full: Bool
  let notchWidth: CGFloat
  let height: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let green = Color(hex: 0x1ED760)
  /// How far each ear reaches into the notch (covers its rounded corner).
  static let overlap: CGFloat = 10
  static let glyph: CGFloat = 20
  /// Tucked: the glyph's centre sits this far inside the notch, tilted by `tilt`.
  static let tuckInside: CGFloat = 3
  static let tilt: Double = 14

  var body: some View {
    let w = NotchMetrics.earWidth
    HStack(spacing: 0) {
      side(leading: true, width: w)
      Color.clear.frame(width: notchWidth - Self.overlap * 2)
      side(leading: false, width: w)
    }
    .frame(height: height)
    .animation(
      reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.86),
      value: full)
    .accessibilityElement()
    .accessibilityLabel(
      spotify.nowPlaying.map { "Spotify: \($0.title), \($0.artist)" } ?? "Spotify")
  }

  /// One ear in a box that spans the full ear plus its part under the notch.
  private func side(leading: Bool, width w: CGFloat) -> some View {
    let box = w + Self.overlap
    let black = UnevenRoundedRectangle(
      bottomLeadingRadius: leading ? 9 : 0, bottomTrailingRadius: leading ? 0 : 9,
      style: .continuous)
    // Glyph centre from the box's notch-side edge: mid-ear when full, inside the notch tucked.
    let fullCentre = Self.overlap + w / 2
    let tuckCentre = Self.overlap - Self.tuckInside
    let shift = full ? 0 : (fullCentre - tuckCentre) * (leading ? 1 : -1)
    return ZStack(alignment: leading ? .trailing : .leading) {
      black.fill(Color.black)
        .frame(width: full ? box : Self.overlap)
      glyph(leading: leading)
        .rotationEffect(.degrees(full ? 0 : (leading ? -Self.tilt : Self.tilt)))
        .opacity(full ? 1 : 0.9)
        .frame(width: box - Self.overlap, height: height)
        .padding(leading ? .trailing : .leading, Self.overlap)
        .offset(x: shift)
        .padding(.top, 1)
    }
    .frame(width: box, alignment: leading ? .trailing : .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func glyph(leading: Bool) -> some View {
    if leading {
      SpotifyArt(image: spotify.artwork, size: Self.glyph, radius: 5)
    } else {
      Image(systemName: "waveform")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Self.green)
        .frame(width: Self.glyph, height: Self.glyph)
    }
  }
}

/// The cover, or a note glyph while it loads.
struct SpotifyArt: View {
  let image: NSImage?
  let size: CGFloat
  let radius: CGFloat

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
      } else {
        ZStack {
          Color.white.opacity(0.1)
          Image(systemName: "music.note")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(SpotifyEars.green)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

/// Panel row: cover, title and artist, elapsed / total with a seekable bar, ⏮ ⏯ ⏭.
struct SpotifyTile: View {
  let spotify: SpotifyModule
  @Environment(\.notchTheme) private var theme

  var body: some View {
    if let now = spotify.nowPlaying {
      Group {
        if now.isPlaying {
          TimelineView(.periodic(from: .now, by: 1)) { context in tile(now, at: context.date) }
        } else {
          tile(now, at: Date())
        }
      }
    }
  }

  private func tile(_ now: NowPlaying, at t: Date) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    let pos = now.position(at: t)
    let green = SpotifyEars.green
    return HStack(spacing: 11) {
      SpotifyArt(image: spotify.artwork, size: 48, radius: 8)
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(now.title.isEmpty ? "Spotify" : now.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          Text(now.artist)
            .font(.system(size: 11))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
        }
        HStack(spacing: 8) {
          Text(NowPlaying.clock(pos))
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(theme.secondary)
          SeekBar(fraction: now.duration > 0 ? pos / now.duration : 0, tint: green) { f in
            spotify.seek(to: f * now.duration)
          }
          Text(NowPlaying.clock(now.duration))
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(theme.tertiary)
        }
      }
      HStack(spacing: 4) {
        control("backward.fill", label: "Önceki şarkı", action: spotify.previous)
        control(
          now.isPlaying ? "pause.fill" : "play.fill", label: now.isPlaying ? "Duraklat" : "Oynat",
          big: true, action: spotify.playPause)
        control("forward.fill", label: "Sonraki şarkı", action: spotify.next)
      }
    }
    .padding(.horizontal, 11)
    .frame(height: ModuleTile<EmptyView, EmptyView>.height)
    .background(
      shape.fill(theme.raised).overlay(CornerGlow(color: green, strength: 0.3, radius: 160))
        .clipShape(shape))
    .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5))
  }

  private func control(
    _ icon: String, label: String, big: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: big ? 13 : 10.5, weight: .bold))
        .foregroundStyle(big ? Color.black : theme.ink)
        .frame(width: big ? 30 : 26, height: big ? 30 : 26)
        .background(Circle().fill(big ? Color.white : Color.white.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// Thin progress bar; a click jumps there.
struct SeekBar: View {
  let fraction: Double
  let tint: Color
  let seek: (Double) -> Void

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.14))
        Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction)))
      }
      .frame(height: 3)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture { p in seek(min(1, max(0, p.x / max(1, geo.size.width)))) }
    }
    .frame(height: 14)
    .accessibilityElement()
    .accessibilityLabel("Şarkıda ilerleme")
  }
}

// MARK: - Shelf

/// The shelf in the panel: up to 6 chips, newest first. Click copies back to the clipboard
/// (an image as PNG: ⌃V pastes it into Claude Code); drag one out into a terminal or an app;
/// × removes it. Buttons only: a right click in the panel opens the app menu.
struct ShelfRow: View {
  let shelf: ShelfModule
  @Environment(\.notchTheme) private var theme

  static let chipHeight: CGFloat = 58

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("RAF")
          .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
          .foregroundStyle(theme.tertiary)
        Text("tıkla: kopyala · sürükle: bırak")
          .font(.system(size: 9.5)).foregroundStyle(theme.tertiary.opacity(0.8))
        Spacer()
        Button("Temizle") { shelf.clear() }
          .buttonStyle(.plain)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.secondary)
      }
      HStack(spacing: 6) {
        ForEach(shelf.shelf.items) { item in
          ShelfChip(item: item, shelf: shelf)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      shape.fill(theme.raised)
        .overlay(CornerGlow(color: Color(hex: 0xC3A8FF), strength: 0.28, radius: 160))
        .clipShape(shape))
    .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5))
  }
}

struct ShelfChip: View {
  let item: ShelfItem
  let shelf: ShelfModule
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  private static let width: CGFloat = 86

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    content
      .frame(width: Self.width, height: ShelfRow.chipHeight)
      .background(shape.fill(Color.white.opacity(hover ? 0.1 : 0.06)))
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
      .overlay {
        if shelf.copiedID == item.id {
          shape.fill(Color.black.opacity(0.65))
            .overlay(
              Label("Kopyalandı", systemImage: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.done))
            .transition(.opacity)
        }
      }
      .overlay(alignment: .topTrailing) {
        if hover {
          Button { shelf.remove(item.id) } label: {
            Image(systemName: "xmark")
              .font(.system(size: 7.5, weight: .bold))
              .foregroundStyle(theme.ink)
              .frame(width: 16, height: 16)
              .background(Circle().fill(Color.black.opacity(0.7)))
          }
          .buttonStyle(.plain)
          .padding(3)
          .accessibilityLabel("Raftan kaldır")
        }
      }
      .contentShape(shape)
      .onHover { hover = $0 }
      .onTapGesture { shelf.copy(item) }
      .onDrag { shelf.provider(for: item) }
      .animation(.easeOut(duration: 0.15), value: shelf.copiedID)
      .help(help)
  }

  @ViewBuilder
  private var content: some View {
    switch item.kind {
    case .text(let s):
      Text(s)
        .font(.system(size: 10))
        .foregroundStyle(theme.secondary)
        .lineLimit(4)
        .multilineTextAlignment(.leading)
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .image:
      if let p = shelf.previews[item.id] {
        Image(nsImage: p).resizable().aspectRatio(contentMode: .fill)
          .frame(width: Self.width, height: ShelfRow.chipHeight)
      } else {
        Image(systemName: "photo").foregroundStyle(theme.tertiary)
      }
    case .file(let u):
      VStack(spacing: 4) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path))
          .resizable().frame(width: 26, height: 26)
        Text(u.lastPathComponent)
          .font(.system(size: 9.5)).foregroundStyle(theme.secondary)
          .lineLimit(1).truncationMode(.middle)
          .padding(.horizontal, 5)
      }
    }
  }

  private var help: String {
    switch item.kind {
    case .text: return "Metni panoya kopyala"
    case .image(_, _, let w, let h): return "Görüntüyü panoya kopyala (\(w)×\(h))"
    case .file(let u): return u.path
    }
  }
}
