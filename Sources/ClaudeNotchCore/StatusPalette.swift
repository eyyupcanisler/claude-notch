import CoreGraphics
import Foundation

/// Which status colors the app draws (Settings > General > Appearance > Status colors).
/// Stored under `defaultsKey`; a fresh install (nothing saved) is `classic`, the original look.
public enum StatusColorScheme: String, CaseIterable, Sendable {
  /// The original look: amber and red for needs and error (error a solid bar), grey working and
  /// blue done.
  case classic
  /// Colors that stay apart for the common color-vision deficiencies, plus a shape sign per
  /// state (the error segment drawn as a broken bar).
  case colorblind

  /// UserDefaults key (app domain).
  public static let defaultsKey = "statusColors"
  /// What an install without a saved choice uses: the original look.
  public static let fallback: StatusColorScheme = .classic

  /// The stored raw value, or the fallback when nothing (or something unknown) is stored.
  public init(stored: String?) {
    self = stored.flatMap(Self.init(rawValue:)) ?? Self.fallback
  }

  public var colors: StatusPalette.Colors {
    switch self {
    case .classic: return StatusPalette.classic
    case .colorblind: return StatusPalette.colorblind
    }
  }
}

/// The status colors (sRGB hex) and the pure math behind them.
///
/// Two palettes (`StatusColorScheme`). `classic` is the original one. `colorblind` is picked to
/// stay apart for the common color-vision deficiencies, and on the status line every state
/// also carries a non-color sign (moving shine = working, slow fade = needs you, solid = done,
/// broken = error, faint = idle), so the states read even in grayscale. Exception: with Reduce
/// Motion on, the shine and the fade stop, so working, needs you and done differ by color and
/// brightness only.
public enum StatusPalette {
  /// One palette: the four status colors and how the error segment is drawn.
  public struct Colors: Sendable, Equatable {
    /// Working (neutral grey, shimmer).
    public let working: UInt32
    /// Needs you (breathing).
    public let needs: UInt32
    /// Done, unseen (blue, solid, flashes once on arrival).
    public let done: UInt32
    /// Error, unseen (static).
    public let error: UInt32
    /// The error segment is drawn as a broken bar (`StatusPalette.dashes`), not a solid one.
    public let errorDashed: Bool

    /// The four status colors, for checks that must hold for each of them.
    public var all: [UInt32] { [working, needs, done, error] }
  }

  /// Color only signals "needs the user", in both palettes: working is a neutral grey (brighter
  /// than idle, white at `idleAlpha`); done (unseen) is blue, a chat to look at; needs and error
  /// keep their colors. The blue stays apart from grey and yellow for red-green color blindness.
  public static let workingGrey: UInt32 = 0x8E8E8E
  public static let doneBlue: UInt32 = 0x388BFD

  /// The original look for the states that need you: amber and red; error is a solid bar.
  public static let classic = Colors(
    working: workingGrey, needs: 0xFFB020, done: doneBlue, error: 0xFF453A, errorDashed: false)

  /// Colorblind-friendly: yellow and pink-red; error is a broken bar.
  public static let colorblind = Colors(
    working: workingGrey, needs: 0xF0E442, done: doneBlue, error: 0xFB7185, errorDashed: true)

  /// An idle status-line segment: white at this alpha over the black band (both palettes).
  public static let idleAlpha: Double = 0.22

  /// Opacity of a status-line segment's bar in `state` (before any animation). Idle is drawn as
  /// white at `idleAlpha` and returns that alpha here.
  public static func lineOpacity(_ state: LineState) -> Double {
    // Done is opaque, so its blue reads at full strength.
    switch state {
    case .idle: return idleAlpha
    default: return 1
    }
  }

  /// `hex` drawn at `opacity` over black, as the sRGB color you see (per-channel, rounded).
  public static func onBlack(_ hex: UInt32, opacity: Double) -> UInt32 {
    let a = max(0, min(1, opacity))
    let c = components(hex)
    func ch(_ v: Double) -> UInt32 { UInt32((v * a * 255).rounded()) }
    return ch(c.red) << 16 | ch(c.green) << 8 | ch(c.blue)
  }

  /// The color a status-line segment in `state` shows over the black band (its palette color
  /// at `lineOpacity`; idle is white at `idleAlpha`).
  public static func lineColor(_ state: LineState, in colors: Colors) -> UInt32 {
    let hex: UInt32
    switch state {
    case .working: hex = colors.working
    case .needs: hex = colors.needs
    case .done: hex = colors.done
    case .error: hex = colors.error
    case .idle: hex = 0xFFFFFF
    }
    return onBlack(hex, opacity: lineOpacity(state))
  }

  /// How far a color is from grey: the spread between its largest and smallest sRGB component
  /// (0 = no hue at all, 1 = fully saturated).
  public static func chroma(_ hex: UInt32) -> Double {
    let c = components(hex)
    return max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue)
  }

  /// The 0...1 sRGB components of a 0xRRGGBB value.
  public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
    (
      Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
      Double(hex & 0xFF) / 255
    )
  }

  /// WCAG 2 relative luminance of an sRGB color (0 = black, 1 = white).
  public static func luminance(_ hex: UInt32) -> Double {
    func linear(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let c = components(hex)
    return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
  }

  /// WCAG 2 contrast ratio between two sRGB colors (1...21).
  public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  /// Text ink for a solid fill: black or white, whichever contrasts more with it.
  public enum Ink: Sendable, Equatable {
    case black
    case white

    public var hex: UInt32 { self == .black ? 0x000000 : 0xFFFFFF }
  }

  /// Black or white text on a solid `fill`, whichever gives the higher contrast.
  public static func ink(on fill: UInt32) -> Ink {
    contrast(fill, Ink.black.hex) >= contrast(fill, Ink.white.hex) ? .black : .white
  }

  /// How the error segment is cut: nil when the palette draws it as one solid bar (no mask,
  /// the original look), else the dashes of the broken bar.
  public static func errorPieces(_ colors: Colors, width: CGFloat, height: CGFloat) -> [CGRect]? {
    colors.errorDashed ? dashes(width: width, height: height) : nil
  }

  /// The error sign: the segment drawn as `count` short dashes split by `gap` points, filling
  /// the segment's width. When the segment is too narrow for dashes of at least 1 pt, dashes and
  /// gaps share the width equally so the bar still reads as broken.
  public static func dashes(width: CGFloat, height: CGFloat, count: Int = 3, gap: CGFloat = 2)
    -> [CGRect]
  {
    guard count > 0, width > 0 else { return [] }
    let n = CGFloat(count)
    var space = gap
    var dash = (width - space * (n - 1)) / n
    if dash < 1 {
      space = width / (2 * n - 1)
      dash = space
    }
    return (0..<count).map { i in
      CGRect(x: CGFloat(i) * (dash + space), y: 0, width: dash, height: height)
    }
  }
}
