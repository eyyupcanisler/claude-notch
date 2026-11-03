// A neutral desktop for README recordings: covers the main screen (menu bar included) under the
// notch panel, so no real window, menu or icon gets into the frame. Quits after N seconds.
// Usage: swift scripts/demo/backdrop.swift [seconds]
import AppKit

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 40
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first else { exit(1) }
let frame = screen.frame
let menuBar = frame.maxY - screen.visibleFrame.maxY

final class Backdrop: NSView {
  var menuBar: CGFloat = 32
  override func draw(_ dirty: NSRect) {
    let b = bounds
    let g = NSGradient(colors: [
      NSColor(srgbRed: 0.10, green: 0.09, blue: 0.16, alpha: 1),
      NSColor(srgbRed: 0.20, green: 0.11, blue: 0.20, alpha: 1),
      NSColor(srgbRed: 0.42, green: 0.20, blue: 0.16, alpha: 1),
    ])!
    g.draw(in: b, angle: -60)
    // A quiet menu bar: translucent strip, app menus left, clock right.
    NSColor(white: 0, alpha: 0.28).setFill()
    NSRect(x: 0, y: b.maxY - menuBar, width: b.width, height: menuBar).fill()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor(white: 1, alpha: 0.88),
    ]
    let bold: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .bold),
      .foregroundColor: NSColor(white: 1, alpha: 0.92),
    ]
    let y = b.maxY - menuBar + (menuBar - 16) / 2
    var x: CGFloat = 20
    ("Terminal" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: bold)
    x += 82
    for m in ["Shell", "Edit", "View", "Window", "Help"] {
      (m as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
      x += (m as NSString).size(withAttributes: attrs).width + 20
    }
    let clock = "Tue 10:42" as NSString
    clock.draw(
      at: NSPoint(x: b.maxX - clock.size(withAttributes: attrs).width - 20, y: y),
      withAttributes: attrs)
  }
}

let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
window.ignoresMouseEvents = true
window.isOpaque = true
let view = Backdrop(frame: NSRect(origin: .zero, size: frame.size))
view.menuBar = menuBar > 0 ? menuBar : 32
window.contentView = view
window.setFrame(frame, display: true)
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
