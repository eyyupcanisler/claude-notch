// Draws the ClaudeNotch app icon (1024 px master) and writes Resources/AppIcon.iconset.
// Run: swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset
//      -o Resources/AppIcon.icns
import AppKit

let size: CGFloat = 1024

func draw(_ ctx: CGContext) {
  let s = size
  // macOS icon grid: the squircle sits inside a 824 px body with transparent margins.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

  // Shadow under the body.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
    color: CGColor(gray: 0, alpha: 0.45))
  ctx.addPath(squircle)
  ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(squircle)
  ctx.clip()
  // Body: near-black with a faint top-down sheen.
  let space = CGColorSpaceCreateDeviceRGB()
  let bg = CGGradient(
    colorsSpace: space,
    colors: [CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
      CGColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY),
    options: [])
  // Warm glow rising from the bottom-right corner (the gauge look).
  let glow = CGGradient(
    colorsSpace: space,
    colors: [CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.55),
      CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.maxX, y: body.minY), startRadius: 0,
    endCenter: CGPoint(x: body.maxX, y: body.minY), endRadius: 620, options: [])

  // The notch: pure black, hanging from the top edge, rounded bottom corners.
  let nw: CGFloat = 400, nh: CGFloat = 132
  let notch = CGRect(x: (s - nw) / 2, y: body.maxY - nh, width: nw, height: nh + 40)
  let notchPath = CGPath(roundedRect: notch, cornerWidth: 54, cornerHeight: 54, transform: nil)
  ctx.addPath(notchPath)
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  ctx.fillPath()

  // The status line under the notch: three segments, the first one working-orange.
  let lineY = body.maxY - nh - 44
  let segW: CGFloat = 100, gap: CGFloat = 22, segH: CGFloat = 16
  let total = segW * 3 + gap * 2
  for i in 0..<3 {
    let r = CGRect(x: (s - total) / 2 + CGFloat(i) * (segW + gap), y: lineY, width: segW,
      height: segH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
    if i == 0 {
      ctx.setFillColor(CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
      ctx.setShadow(offset: .zero, blur: 26,
        color: CGColor(red: 0.95, green: 0.55, blue: 0.4, alpha: 0.9))
    } else {
      ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
    ctx.fillPath()
  }
  ctx.setShadow(offset: .zero, blur: 0, color: nil)

  // A dot-matrix spark (four-point star) in the middle, the app's numeral style.
  let pattern = [
    "000010000",
    "000010000",
    "000111000",
    "001111100",
    "111111111",
    "001111100",
    "000111000",
    "000010000",
    "000010000",
  ]
  let pitch: CGFloat = 46, dot: CGFloat = 32
  let gridW = pitch * 9
  let ox = (s - gridW) / 2, oy = body.minY + 128
  for (row, line) in pattern.enumerated() {
    for (col, ch) in line.enumerated() {
      let x = ox + CGFloat(col) * pitch + (pitch - dot) / 2
      let y = oy + CGFloat(8 - row) * pitch + (pitch - dot) / 2
      let on = ch == "1"
      ctx.setFillColor(on
        ? CGColor(red: 0.96, green: 0.6, blue: 0.45, alpha: 1)
        : CGColor(gray: 1, alpha: 0.06))
      ctx.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
    }
  }
  ctx.restoreGState()

  // Hairline rim.
  ctx.addPath(squircle)
  ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
  ctx.setLineWidth(3)
  ctx.strokePath()
}

func png(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let g = NSGraphicsContext(bitmapImageRep: rep)!
  let ctx = g.cgContext
  ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
  ctx.interpolationQuality = .high
  draw(ctx)
  return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! png(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
  try! png(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("ok")
