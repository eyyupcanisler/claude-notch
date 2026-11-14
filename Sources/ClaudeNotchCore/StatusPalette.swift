import CoreGraphics
import Foundation

/// The status colors (sRGB hex) and the pure math behind them. Picked to stay apart for the
/// common color-vision deficiencies; every state also carries a non-color sign on the status
/// line (moving shine = working, slow fade = needs you, solid = done, broken = error,
/// faint = idle), so the states read even in grayscale. Exception: with Reduce Motion on, the
/// shine and the fade stop, so working, needs you and done differ by color and brightness only.
public enum StatusPalette {
  /// Working: cyan.
  public static let working: UInt32 = 0x22D3EE
  /// Needs you: yellow.
  public static let needs: UInt32 = 0xF0E442
  /// Done (unseen): blue.
  public static let done: UInt32 = 0x388BFD
  /// Error (unseen): pink-red.
  public static let error: UInt32 = 0xFB7185

  /// The four status colors, for checks that must hold for each of them.
  public static let all: [UInt32] = [working, needs, done, error]

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
