import CoreGraphics
import Foundation

/// Which status colors the app draws (Settings > General > Appearance > Status colors).
/// Stored under `defaultsKey`; a fresh install (nothing saved) is `classic`, the original look.
public enum StatusColorScheme: String, CaseIterable, Sendable {
  /// The original colors: Claude orange, amber, green, red; the error segment a solid bar.
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
    /// Working (shimmer).
    public let working: UInt32
    /// Needs you (breathing).
    public let needs: UInt32
    /// Done, unseen (solid, flashes once on arrival).
    public let done: UInt32
    /// Error, unseen (static).
    public let error: UInt32
    /// The error segment is drawn as a broken bar (`StatusPalette.dashes`), not a solid one.
    public let errorDashed: Bool

    /// The four status colors, for checks that must hold for each of them.
    public var all: [UInt32] { [working, needs, done, error] }
  }

  /// The original palette: Claude orange, amber, green, red; error is a solid bar.
  public static let classic = Colors(
    working: 0xD97757, needs: 0xFFB020, done: 0x34C759, error: 0xFF453A, errorDashed: false)

  /// Colorblind-friendly: cyan, yellow, blue, pink-red; error is a broken bar.
  public static let colorblind = Colors(
    working: 0x22D3EE, needs: 0xF0E442, done: 0x388BFD, error: 0xFB7185, errorDashed: true)

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
