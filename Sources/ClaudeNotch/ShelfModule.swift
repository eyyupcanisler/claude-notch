import AppKit
import ClaudeNotchCore
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The shelf: the last 6 things copied (text, images, ⌘⌃⇧4 screenshots included) plus files
/// dropped on the notch. The clipboard has no change notification, so only its change counter
/// (one integer) is read once a second while the module is on. Images go straight to a temp PNG;
/// memory keeps only small previews. Password managers' concealed copies are never taken. The
/// temp folder is emptied when the module turns off and when the app starts; pinned items stay.
/// Two opt-in settings (both off by default, the original behavior): unpinned items can leave
/// 1 / 3 / 7 days after they were added (checked hourly, at start and on wake, never in the
/// clipboard poll; with "Never" no check runs at all), and turning the module off can also
/// delete the pinned items and their folder.
@MainActor
@Observable
final class ShelfModule {
  nonisolated static let previewPixels = 160

  private(set) var shelf = Shelf()
  /// Pinned items: kept across launches (Application Support), outside the 6-item limit.
  private(set) var pinned: [ShelfItem] = []
  static let maxPinned = 6
  /// A demo recording (`CLAUDE_NOTCH_DEMO=1`) pins into its own temp folder: it never reads or
  /// deletes the user's real pins.
  static let pinFolder =
    NotchSettings.isDemo
    ? FileManager.default.temporaryDirectory
      .appendingPathComponent("ClaudeNotchDemoPinned", isDirectory: true)
    : FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/ClaudeNotch/Pinned", isDirectory: true)
  private static var pinIndex: URL { pinFolder.appendingPathComponent("pins.json") }
  /// Small previews of image items, by item id.
  private(set) var previews: [String: NSImage] = [:]
  /// The item just copied back from the shelf (a short "Copied" on its chip).
  private(set) var copiedID: String?
  /// The chip being dragged (a session row accepts only shelf drags).
  @ObservationIgnored var draggingID: String?

  func item(id: String) -> ShelfItem? {
    pinned.first { $0.id == id } ?? shelf.items.first { $0.id == id }
  }

  /// A new image arrived (the controller shows "Added to the shelf").
  @ObservationIgnored var onImage: (@MainActor (ShelfItem) -> Void)?
  @ObservationIgnored private var timer: Timer?
  /// Hourly expiry check and the wake observer (only while the module is on and an expiry is
  /// chosen).
  @ObservationIgnored private var expiryTimer: Timer?
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?
  /// Settings > Modules > Shelf options (set by `configure` before `setEnabled`).
  @ObservationIgnored private var expiry: ShelfExpiry = .fallback
  @ObservationIgnored private var deletePinsWhenOff = ShelfPinsOnOff.fallback
  /// Everything was deleted since the module was last on (a later "off" has nothing to do).
  @ObservationIgnored private var wipedWhileOff = false
  @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
  @ObservationIgnored private var copiedTask: Task<Void, Never>?

  static let folder: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent(
      NotchSettings.isDemo ? "ClaudeNotchDemoShelf" : "ClaudeNotchShelf", isDirectory: true)

  init() {
    // Leftovers of an earlier run.
    try? FileManager.default.removeItem(at: Self.folder)
    loadPins()
  }

  // MARK: Pins

  private struct PinRecord: Codable {
    var id: String
    var text: String?
    var image: String?
    var width: Int?
    var height: Int?
    var file: String?
  }

  func isPinned(_ id: String) -> Bool { pinned.contains { $0.id == id } }

  /// Pins a shelf item (an image is copied out of the temp folder) or unpins it.
  func togglePin(_ item: ShelfItem) {
    if let i = pinned.firstIndex(where: { $0.id == item.id }) {
      let gone = pinned.remove(at: i)
      if let f = gone.ownedFile { try? FileManager.default.removeItem(at: f) }
      previews[gone.id] = nil
      savePins()
      return
    }
    guard pinned.count < Self.maxPinned else { return }
    var kind = item.kind
    if case .image(let file, let key, let w, let h) = item.kind {
      try? FileManager.default.createDirectory(
        at: Self.pinFolder, withIntermediateDirectories: true)
      let dest = Self.pinFolder.appendingPathComponent("\(item.id).png")
      guard (try? FileManager.default.copyItem(at: file, to: dest)) != nil else { return }
      kind = .image(file: dest, key: key, width: w, height: h)
    }
    pinned.append(ShelfItem(id: item.id, kind: kind, addedAt: item.addedAt))
    remove(item.id)
    if case .image(let f, _, _, _) = kind, previews[item.id] == nil,
      let src = CGImageSourceCreateWithURL(f as CFURL, nil)
    {
      previews[item.id] = Self.preview(src)
    }
    savePins()
  }

  private func savePins() {
    let records = pinned.map { p -> PinRecord in
      switch p.kind {
      case .text(let s): return PinRecord(id: p.id, text: s)
      case .image(let f, _, let w, let h):
        return PinRecord(id: p.id, image: f.lastPathComponent, width: w, height: h)
      case .file(let u): return PinRecord(id: p.id, file: u.path)
      }
    }
    try? FileManager.default.createDirectory(at: Self.pinFolder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(records) {
      try? data.write(to: Self.pinIndex, options: [.atomic])
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: Self.pinIndex.path)
    }
  }

  private func loadPins() {
    guard let data = try? Data(contentsOf: Self.pinIndex),
      let records = try? JSONDecoder().decode([PinRecord].self, from: data)
    else { return }
    pinned = records.compactMap { r in
      if let t = r.text { return ShelfItem(id: r.id, kind: .text(t), addedAt: Date()) }
      if let name = r.image {
        let f = Self.pinFolder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        if let src = CGImageSourceCreateWithURL(f as CFURL, nil) {
          previews[r.id] = Self.preview(src)
        }
        return ShelfItem(
          id: r.id, kind: .image(file: f, key: name, width: r.width ?? 0, height: r.height ?? 0),
          addedAt: Date())
      }
      if let path = r.file {
        return ShelfItem(id: r.id, kind: .file(URL(fileURLWithPath: path)), addedAt: Date())
      }
      return nil
    }
  }

  var isPolling: Bool { timer != nil }

  /// The shelf options from Settings. A changed expiry takes effect at once while the module
  /// is on (the hourly check starts or stops); the pins choice applies at the next "off".
  func configure(expiry: ShelfExpiry, deletePinsWhenOff: Bool) {
    self.deletePinsWhenOff = deletePinsWhenOff
    guard expiry != self.expiry else { return }
    self.expiry = expiry
    if timer != nil { startExpiryChecks() }
  }

  func setEnabled(_ on: Bool) {
    if on, timer == nil {
      wipedWhileOff = false
      lastChange = NSPasteboard.general.changeCount
      let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.poll() }
      }
      t.tolerance = 0.3
      RunLoop.main.add(t, forMode: .common)
      timer = t
      startExpiryChecks()
    } else if !on, deletePinsWhenOff, timer != nil || !wipedWhileOff {
      // Opt-in: everything goes, also at a start with the module off (pins left from a run
      // before the module was turned off).
      timer?.invalidate()
      timer = nil
      stopExpiryChecks()
      deleteAll()
      wipedWhileOff = true
    } else if !on, let t = timer {
      // The original: the shelf and its temp folder go, the pins stay.
      t.invalidate()
      timer = nil
      stopExpiryChecks()
      clear()
    }
  }

  /// Starts the hourly / on-wake expiry check for the chosen lifetime and runs it once; with
  /// "Never" nothing runs.
  private func startExpiryChecks() {
    stopExpiryChecks()
    guard expiry.lifetime != nil else { return }
    let e = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.removeExpired() }
    }
    e.tolerance = 5 * 60
    RunLoop.main.add(e, forMode: .common)
    expiryTimer = e
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.removeExpired() }
    }
    removeExpired()
  }

  private func stopExpiryChecks() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    wakeObserver = nil
  }

  /// Unpinned items older than the chosen lifetime leave, with their temp files.
  private func removeExpired() {
    guard let lifetime = expiry.lifetime else { return }
    let now = Date()
    // Read first: a no-op mutation would still redraw the shelf row.
    guard shelf.items.contains(where: { Shelf.isExpired($0, at: now, lifetime: lifetime) })
    else { return }
    for item in shelf.removeExpired(at: now, lifetime: lifetime) { discard(item) }
  }

  /// The module turned off with "Delete pinned items" on: the shelf, the pins, the temp folder
  /// and the Pinned folder go.
  private func deleteAll() {
    for item in shelf.clear() { discard(item) }
    pinned = []
    previews = [:]
    copiedID = nil
    try? FileManager.default.removeItem(at: Self.folder)
    try? FileManager.default.removeItem(at: Self.pinFolder)
  }

  private func poll() {
    let pb = NSPasteboard.general
    guard pb.changeCount != lastChange else { return }
    lastChange = pb.changeCount
    let types = (pb.types ?? []).map(\.rawValue)
    guard !Shelf.shouldSkip(types: types) else { return }
    let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL],
      !urls.isEmpty
    {
      for u in urls.prefix(Shelf.capacity).reversed() { add(.file(u)) }
    } else if let data = pb.data(forType: .png) {
      addImage(data, isPNG: true)
    } else if let data = pb.data(forType: .tiff) {
      addImage(data, isPNG: false)
    } else if let s = pb.string(forType: .string), let text = Shelf.keepText(s) {
      add(.text(text))
    }
  }

  /// Files dropped on the notch or the panel.
  func addFiles(_ urls: [URL]) {
    for u in urls.prefix(Shelf.capacity).reversed() where u.isFileURL { add(.file(u)) }
  }

  private func addImage(_ data: Data, isPNG: Bool) {
    let key = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let id = UUID().uuidString
    let file = Self.folder.appendingPathComponent("\(id).png")
    do {
      try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
      // Already PNG: written as is. TIFF (screenshots to the clipboard): converted once.
      let png = isPNG
        ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
      guard let png else { return }
      try png.write(to: file, options: .atomic)
    } catch {
      return
    }
    if let preview = Self.preview(src) { previews[id] = preview }
    let item = ShelfItem(
      id: id, kind: .image(file: file, key: key, width: w, height: h), addedAt: Date())
    add(item.kind, id: id)
    onImage?(item)
  }

  private func add(_ kind: ShelfItem.Kind, id: String = UUID().uuidString) {
    let gone = shelf.add(ShelfItem(id: id, kind: kind, addedAt: Date()))
    for g in gone { discard(g) }
  }

  private func discard(_ item: ShelfItem) {
    previews[item.id] = nil
    if let f = item.ownedFile { try? FileManager.default.removeItem(at: f) }
  }

  func remove(_ id: String) {
    if let item = shelf.remove(id: id) { discard(item) }
  }

  func clear() {
    for item in shelf.clear() { discard(item) }
    // Pinned items keep their previews.
    let keep = Set(pinned.map(\.id))
    previews = previews.filter { keep.contains($0.key) }
    try? FileManager.default.removeItem(at: Self.folder)
  }

  /// Puts the item back on the clipboard (an image as PNG, so ⌃V pastes it into Claude Code).
  func copy(_ item: ShelfItem) {
    let pb = NSPasteboard.general
    pb.clearContents()
    switch item.kind {
    case .text(let s):
      pb.setString(s, forType: .string)
    case .image(let file, _, _, _):
      if let data = try? Data(contentsOf: file) { pb.setData(data, forType: .png) }
    case .file(let u):
      pb.writeObjects([u as NSURL])
    }
    // Our own write is not a new copy.
    lastChange = pb.changeCount
    copiedID = item.id
    copiedTask?.cancel()
    copiedTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.copiedID = nil
    }
  }

  /// What a drag out of the shelf carries.
  func provider(for item: ShelfItem) -> NSItemProvider {
    switch item.kind {
    case .text(let s): return NSItemProvider(object: s as NSString)
    case .image(let file, _, _, _): return NSItemProvider(contentsOf: file) ?? NSItemProvider()
    case .file(let u): return NSItemProvider(contentsOf: u) ?? NSItemProvider()
    }
  }

  nonisolated static func preview(_ src: CGImageSource) -> NSImage? {
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: previewPixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
  }
}
