import AppKit
import ClaudeNotchCore
import SwiftUI

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}

/// Dark Matte tokens (the only theme). The band at notch height is pure black (it reads as the
/// hardware notch growing), so anything drawn in it uses `band*` ink. The four status colors
/// come from the chosen `StatusColorScheme` (Settings): the environment's `notchTheme` carries
/// them, so views read `theme.working` / `theme.needs` / `theme.done` / `theme.error`.
struct NotchTheme: Sendable {
  let surface: Color
  let raised: Color
  let hairline: Color
  let ink: Color
  let secondary: Color
  let tertiary: Color
  let faint: Color
  let working: Color
  let needs: Color
  let done: Color
  let error: Color
  let idle: Color
  /// Primary button (Allow): ink fill, surface text.
  let primaryFill: Color
  let primaryText: Color
  let grainOpacity: Double

  static let band = Color.black
  static let bandInk = Color.white
  static let bandSecondary = Color.white.opacity(0.62)
  /// Text or a glyph on a solid status fill (chips, capsules, the picked option number): black,
  /// as it always was. It reaches at least 4.5:1 on every status color of both palettes
  /// (`StatusPalette.ink(on:)`, checked in `StatusPaletteTests`).
  static let onStatus = Color.black

  private static func make(_ colors: StatusPalette.Colors) -> NotchTheme {
    NotchTheme(
      surface: Color(hex: 0x000000), raised: Color(hex: 0x0E0E10),
      hairline: .white.opacity(0.07), ink: Color(hex: 0xF5F5F4),
      secondary: Color(hex: 0xF5F5F4, opacity: 0.72),
      tertiary: Color(hex: 0xF5F5F4, opacity: 0.56),
      faint: .white.opacity(0.06), working: Color(hex: colors.working),
      needs: Color(hex: colors.needs), done: Color(hex: colors.done),
      error: Color(hex: colors.error), idle: .white.opacity(0.35),
      primaryFill: Color(hex: 0xF5F5F4), primaryText: Color(hex: 0x0B0B0C), grainOpacity: 1)
  }

  /// The original look (orange / amber / green / red).
  static let classic = make(StatusPalette.classic)
  /// Colorblind-friendly status colors (cyan / yellow / blue / pink-red).
  static let colorblind = make(StatusPalette.colorblind)

  static func scheme(_ scheme: StatusColorScheme) -> NotchTheme {
    switch scheme {
    case .classic: return classic
    case .colorblind: return colorblind
    }
  }
}

private struct ThemeKey: EnvironmentKey {
  static let defaultValue = NotchTheme.classic
}

extension EnvironmentValues {
  var notchTheme: NotchTheme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

/// One static noise tile (generated once) for the matte grain.
@MainActor
enum Grain {
  static let image: Image? = {
    let size = 96
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    var seed: UInt32 = 0x9E37_79B9
    for i in 0..<(size * size) {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      let v = UInt8(truncatingIfNeeded: seed >> 24)
      let light = v > 127
      let alpha = UInt8(Double(v % 64) / 64 * 9)
      let c: UInt8 = light ? 255 : 0
      pixels[i * 4] = UInt8((Int(c) * Int(alpha)) / 255)
      pixels[i * 4 + 1] = UInt8((Int(c) * Int(alpha)) / 255)
      pixels[i * 4 + 2] = UInt8((Int(c) * Int(alpha)) / 255)
      pixels[i * 4 + 3] = alpha
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let cg = CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return Image(decorative: cg, scale: 2)
  }()
}

/// Motion tokens shared by every surface (Apple fluid springs: damping ratio + response).
enum Motion {
  /// Expand / collapse of the panel: quick, settling with the faintest overshoot.
  static let expand = Animation.spring(response: 0.3, dampingFraction: 0.9)
  /// The collapsed notch swelling under the pointer (instant acknowledgement).
  static let prime = Animation.spring(response: 0.18, dampingFraction: 0.72)
  /// The island dropping out of the notch: a little life, it arrives on its own.
  static let peek = Animation.spring(response: 0.34, dampingFraction: 0.86)
  /// The island going back into the notch: same response, no undershoot past the notch.
  static let retract = Animation.spring(response: 0.34, dampingFraction: 1)
  /// Content height changes inside an open shape (a card opens, a row appears).
  static let resize = Animation.spring(response: 0.38, dampingFraction: 1)
  /// Reduce motion: crossfades only.
  static let crossfade = Animation.easeOut(duration: 0.16)
  /// Content leaving before the shape retracts.
  static let contentOut = Animation.easeOut(duration: 0.12)
  /// Content waits until the shape is ~60% there (spring step response).
  static let contentDelay: Double = 0.06
  static let stagger: Double = 0.03

  @MainActor
  static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  @MainActor
  static var reduceTransparency: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  /// The spring for a shape change between two modes.
  @MainActor
  static func shape(from old: NotchMode, to new: NotchMode) -> Animation {
    if reduce { return crossfade }
    if old == .expanded || new == .expanded { return expand }
    return new == .peek ? peek : retract
  }
}
