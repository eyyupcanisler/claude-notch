import ClaudeNotchCore
import SwiftUI

// The "Gösterge" look: dot-matrix numerals, tick strips and a soft corner glow on black.

/// 5×7 dot-matrix numerals (digits and ':'). Unlit dots are drawn faintly, like an LED panel.
struct DotMatrixText: View {
  let text: String
  let color: Color
  /// Distance between dot centres.
  var pitch: CGFloat = 2.1

  private static let rows = 7
  private static let glyphs: [Character: [String]] = [
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ":": ["0", "0", "1", "0", "1", "0", "0"],
  ]

  private var columns: [[Bool]] {
    var cols: [[Bool]] = []
    for (i, ch) in text.enumerated() {
      guard let g = Self.glyphs[ch] else { continue }
      if i > 0 { cols.append(Array(repeating: false, count: Self.rows)) }
      for c in 0..<g[0].count {
        cols.append(g.map { Array($0)[c] == "1" })
      }
    }
    return cols
  }

  var body: some View {
    let cols = columns
    Canvas { ctx, _ in
      let d = pitch * 0.74
      let off = (pitch - d) / 2
      for (x, col) in cols.enumerated() {
        for (y, on) in col.enumerated() {
          let r = CGRect(
            x: CGFloat(x) * pitch + off, y: CGFloat(y) * pitch + off, width: d, height: d)
          ctx.fill(Path(ellipseIn: r), with: .color(on ? color : color.opacity(0.08)))
        }
      }
    }
    .frame(width: CGFloat(cols.count) * pitch, height: CGFloat(Self.rows) * pitch)
    .accessibilityHidden(true)
  }
}

/// A row's time in dot-matrix digits. What it measures depends on the row (see `Mode`).
struct DotElapsed: View {
  enum Mode: Equatable {
    /// Ticking "mm:ss" since `since` (work in progress, waiting for you).
    case live(since: Date)
    /// Frozen length of a finished turn ("02:14"): it does not move.
    case fixed(TimeInterval)
    /// Minutes / hours / days since `since`, refreshed every 30 s (idle rows).
    case coarse(since: Date)
  }

  let mode: Mode
  let color: Color
  var pitch: CGFloat = 2.1

  var body: some View {
    switch mode {
    case .live(let since):
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let t = context.date.timeIntervalSince(since)
        reading(DotClock.reading(t), label: RelativeTime.short(t))
      }
    case .fixed(let d):
      reading(DotClock.reading(d), label: "Süre \(DotClock.reading(d).digits)")
    case .coarse(let since):
      TimelineView(.periodic(from: .now, by: 30)) { context in
        let t = context.date.timeIntervalSince(since)
        reading(DotClock.coarse(t), label: RelativeTime.short(t))
      }
    }
  }

  private func reading(_ r: DotClock.Reading, label: String) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 3) {
      DotMatrixText(text: r.digits, color: color, pitch: pitch)
      if let unit = r.unit {
        Text(unit)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(color.opacity(0.8))
      }
    }
    .accessibilityElement()
    .accessibilityLabel(label)
  }
}

/// The rhythm of a turn: the turn so far in 28 time slots, each bar as tall as the tool calls
/// in its slot. Bursts and pauses show; no bars at the right end while working means Claude
/// has done nothing for a while (a long command, or stuck). Redrawn on new calls and every
/// 5 s while live (so a pause grows on screen); 28 rectangles, no animation.
struct RhythmStrip: View {
  let rhythm: ActivityRhythm?
  let color: Color
  /// Live turns advance with time; finished ones are read at `frozenAt`.
  var live = false
  var frozenAt: Date?
  @Environment(\.notchTheme) private var theme

  static let barWidth: CGFloat = 2
  static let gap: CGFloat = 3
  static let height: CGFloat = 14

  private var width: CGFloat {
    CGFloat(ActivityRhythm.slots) * (Self.barWidth + Self.gap) - Self.gap
  }

  var body: some View {
    Group {
      if live {
        TimelineView(.periodic(from: .now, by: 5)) { context in strip(at: context.date) }
      } else {
        strip(at: frozenAt ?? .now)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(label)
  }

  private var label: String {
    guard let rhythm, rhythm.total > 0 else { return "İşlem yok" }
    let agents = rhythm.agentIDs.count
    return "\(rhythm.total) işlem" + (agents > 0 ? " · \(agents) alt ajan" : "")
  }

  private func strip(at now: Date) -> some View {
    let reading = rhythm?.reading(at: now)
    return HStack(alignment: .bottom, spacing: 8) {
      Canvas { ctx, size in
        let counts = reading?.counts ?? []
        let used = reading?.used ?? 0
        let peak = max(1, counts.max() ?? 1)
        for k in 0..<ActivityRhythm.slots {
          let x = CGFloat(k) * (Self.barWidth + Self.gap)
          let n = k < counts.count ? counts[k] : 0
          let h = n > 0 ? max(3, (CGFloat(n) / CGFloat(peak) * size.height).rounded()) : 2
          let rect = CGRect(x: x, y: size.height - h, width: Self.barWidth, height: h)
          let path = Path(roundedRect: rect, cornerRadius: 1)
          if n == 0 {
            ctx.fill(path, with: .color(.white.opacity(k < used ? 0.16 : 0.07)))
          } else {
            let newest = live && k >= used - 2
            ctx.fill(path, with: .color(color.opacity(newest || !live ? 1 : 0.75)))
          }
        }
      }
      .frame(width: width, height: Self.height)
      if let rhythm, rhythm.total > 0 {
        Text(label)
          .font(.system(size: 10, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(theme.tertiary)
          .lineLimit(1)
          .fixedSize()
          .accessibilityHidden(true)
      }
    }
  }
}

/// Status colour bleeding in from a card's bottom-trailing corner.
struct CornerGlow: View {
  let color: Color?
  var strength: Double = 0.42
  var radius: CGFloat = 170

  var body: some View {
    RadialGradient(
      colors: [(color ?? .clear).opacity(strength), (color ?? .clear).opacity(0)],
      center: .bottomTrailing, startRadius: 0, endRadius: radius
    )
    .opacity(color == nil ? 0 : 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Semicircle of ticks that fill left to right while a risky "İzin ver" is held.
struct TickArc: Shape {
  var progress: Double
  var count = 9
  /// Draw every tick (the dim track) instead of the filled ones.
  var track = false

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let cx = rect.midX, cy = rect.maxY
    let r2 = min(rect.width / 2, rect.height)
    let r1 = r2 * 0.55
    let lit = track ? count : Int((progress * Double(count)).rounded(.down))
    for i in 0..<lit {
      let a = Double.pi * (1 - Double(i) / Double(count - 1))
      p.move(to: CGPoint(x: cx + r1 * cos(a), y: cy - r1 * sin(a)))
      p.addLine(to: CGPoint(x: cx + r2 * cos(a), y: cy - r2 * sin(a)))
    }
    return p
  }
}
