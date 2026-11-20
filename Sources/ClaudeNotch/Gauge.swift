import ClaudeNotchCore
import SwiftUI

// The "Gauge" look: dot-matrix numerals, tick strips and a soft corner glow on black.

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
    "-": ["000", "000", "000", "111", "000", "000", "000"],
    "°": ["010", "101", "010", "000", "000", "000", "000"],
    "%": ["11001", "11010", "00010", "00100", "01000", "01011", "10011"],
  ]

  /// Width `text` takes at `pitch` (the same columns the view draws).
  static func width(_ text: String, pitch: CGFloat) -> CGFloat {
    CGFloat(columns(of: text).count) * pitch
  }

  private var columns: [[Bool]] { Self.columns(of: text) }

  private static func columns(of text: String) -> [[Bool]] {
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

  // Two shapes (unlit and lit dots), not a Canvas: the first Canvas on screen starts
  // RenderBox's Metal device, about 2 MB of GPU buffers and surfaces kept for the life of the
  // app. Shapes are drawn by Core Animation. The dots never overlap, so the fill order does not
  // matter. A shape's fill colour can animate; the Canvas never did, so neither do these.
  var body: some View {
    let cols = columns
    ZStack(alignment: .topLeading) {
      DotGrid(columns: cols, pitch: pitch, lit: false).fill(color.opacity(0.08))
      DotGrid(columns: cols, pitch: pitch, lit: true).fill(color)
    }
    .animation(nil, value: color)
    .frame(width: CGFloat(cols.count) * pitch, height: CGFloat(Self.rows) * pitch)
    .accessibilityHidden(true)
  }
}

/// The lit or the unlit dots of a `DotMatrixText`, as one path.
private struct DotGrid: Shape {
  let columns: [[Bool]]
  let pitch: CGFloat
  let lit: Bool

  func path(in _: CGRect) -> Path {
    var p = Path()
    let d = pitch * 0.74
    let off = (pitch - d) / 2
    for (x, col) in columns.enumerated() {
      for (y, on) in col.enumerated() where on == lit {
        p.addEllipse(
          in: CGRect(
            x: CGFloat(x) * pitch + off, y: CGFloat(y) * pitch + off, width: d, height: d))
      }
    }
    return p
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
      reading(DotClock.reading(d), label: loc("Duration \(DotClock.reading(d).digits)"))
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

  nonisolated static let barWidth: CGFloat = 2
  nonisolated static let gap: CGFloat = 3
  nonisolated static let height: CGFloat = 14

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
    guard let rhythm, rhythm.total > 0 else { return loc("No actions") }
    let agents = rhythm.agentIDs.count
    return loc("\(rhythm.total) actions") + (agents > 0 ? loc(" · \(agents) subagents") : "")
  }

  private func strip(at now: Date) -> some View {
    let reading = rhythm?.reading(at: now)
    let counts = reading?.counts ?? []
    let used = reading?.used ?? 0
    // One shape per fill, not a Canvas (see DotMatrixText).
    func bars(_ fill: RhythmBars.Fill) -> RhythmBars {
      RhythmBars(counts: counts, used: used, live: live, fill: fill)
    }
    return HStack(alignment: .bottom, spacing: 8) {
      ZStack {
        bars(.emptyUsed).fill(Color.white.opacity(0.16))
        bars(.emptyAhead).fill(Color.white.opacity(0.07))
        bars(.full).fill(color)
        bars(.faded).fill(color.opacity(0.75))
      }
      .animation(nil, value: color)
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

/// The bars of a `RhythmStrip` that share one fill. Empty slots are 2 pt stubs, brighter where
/// the turn has already been; while live, all but the newest two filled slots are faded.
private struct RhythmBars: Shape {
  enum Fill { case emptyUsed, emptyAhead, full, faded }

  let counts: [Int]
  let used: Int
  let live: Bool
  let fill: Fill

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let peak = max(1, counts.max() ?? 1)
    for k in 0..<ActivityRhythm.slots {
      let n = k < counts.count ? counts[k] : 0
      let f: Fill =
        n == 0 ? (k < used ? .emptyUsed : .emptyAhead) : (live && k < used - 2 ? .faded : .full)
      guard f == fill else { continue }
      let x = CGFloat(k) * (RhythmStrip.barWidth + RhythmStrip.gap)
      let h = n > 0 ? max(3, (CGFloat(n) / CGFloat(peak) * rect.height).rounded()) : 2
      let bar = CGRect(x: x, y: rect.height - h, width: RhythmStrip.barWidth, height: h)
      p.addPath(Path(roundedRect: bar, cornerRadius: 1))
    }
    return p
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

/// Semicircle of ticks that fill left to right while a risky "Allow" is held.
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
