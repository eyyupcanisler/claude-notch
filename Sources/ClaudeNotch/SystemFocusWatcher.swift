import AppKit
import ClaudeNotchCore
import Foundation

/// Follows macOS's Focus state (`SystemFocus`): reads ~/Library/DoNotDisturb/DB/Assertions.json
/// at start, again whenever it changes, every `SystemFocus.recheckInterval` and after a wake,
/// and reports each new state once.
///
/// macOS rewrites the file atomically (a new file renamed over the old one), so a watch on the
/// file alone would go deaf after the first change. Two kqueue sources run on the main queue:
/// one on the folder (an entry was added, removed or renamed: the atomic replace) and one on the
/// file (written in place, deleted, renamed). After any event the watcher waits a moment,
/// reads the file and opens the file source again on whatever file is there now. When the
/// folder or file cannot be opened (missing, or blocked by privacy settings) the timer and the
/// wake re-read still run and try to open the sources again; the state is then `.unknown`,
/// reported once, never an error loop. One failed read after a known state is treated as a
/// hiccup (a half-written file, the instant of a rename): the known state is kept and the file
/// is read again shortly; only a second failure in a row reports `.unknown`.
@MainActor
final class SystemFocusWatcher {
  private let file: URL
  private let onChange: @MainActor (SystemFocusState) -> Void
  /// The last state read (`.unknown` until the first read).
  private(set) var state: SystemFocusState = .unknown
  private var folderSource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var timer: Timer?
  private var wakeObserver: NSObjectProtocol?
  /// A re-read is already scheduled (events come in bursts: temp file, rename, attributes).
  private var readScheduled = false
  /// Failed reads in a row (see `read()`).
  private var failures = 0
  /// Why the last read failed ("missing", "permission denied", "unrecognized format"...), nil
  /// after a good read. For the debug state.
  private(set) var lastError: String?

  /// The folder or the file is watched for changes (false: only the timer and wake re-read).
  var watching: Bool { folderSource != nil || fileSource != nil }
  /// The path read, for the debug state.
  var path: String { file.path }

  init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    onChange: @escaping @MainActor (SystemFocusState) -> Void
  ) {
    file = SystemFocus.fileURL(home: home)
    self.onChange = onChange
  }

  /// Reads the state now and starts watching.
  func start() {
    stop()
    watchFolder()
    watchFile()
    let t = Timer(timeInterval: SystemFocus.recheckInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.reread() }
    }
    t.tolerance = 5
    RunLoop.main.add(t, forMode: .common)
    timer = t
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reread() }
    }
    read()
  }

  func stop() {
    folderSource?.cancel()
    folderSource = nil
    fileSource?.cancel()
    fileSource = nil
    timer?.invalidate()
    timer = nil
    if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    wakeObserver = nil
  }

  /// The folder source catches the atomic replace. Opened at start and, while it could not be
  /// opened (folder missing, access granted later), tried again on every re-read.
  private func watchFolder() {
    guard folderSource == nil else { return }
    folderSource = watch(file.deletingLastPathComponent().path, mask: .write) { [weak self] _ in
      self?.scheduleRead()
    }
  }

  /// The file source follows one inode: after a replace, delete or rename it is opened again on
  /// the file now at the path (none while there is none; the folder source brings it back).
  private func watchFile() {
    fileSource?.cancel()
    fileSource = watch(file.path, mask: [.write, .extend, .delete, .rename, .attrib]) {
      [weak self] event in
      guard let self else { return }
      if !event.isDisjoint(with: [.delete, .rename]) {
        self.fileSource?.cancel()
        self.fileSource = nil
      }
      self.scheduleRead()
    }
  }

  /// A kqueue source on `path` (O_EVTONLY: it never keeps a volume busy), nil when the path
  /// cannot be opened.
  private func watch(
    _ path: String, mask: DispatchSource.FileSystemEvent,
    _ handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
  ) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: mask, queue: .main)
    source.setEventHandler { [weak source] in
      let event = source?.data ?? []
      MainActor.assumeIsolated { handler(event) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
  }

  private func scheduleRead(after delay: TimeInterval = 0.2) {
    guard !readScheduled else { return }
    readScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.readScheduled = false
        self.reread()
      }
    }
  }

  /// Reads again and re-opens the sources (the file may be a new one by now).
  private func reread() {
    watchFolder()
    watchFile()
    read()
  }

  private func read() {
    var bytes: Data?
    do {
      bytes = try Data(contentsOf: file)
    } catch {
      lastError = Self.describe(error)
    }
    let next = SystemFocus.state(of: bytes)
    if next == .unknown {
      if bytes != nil { lastError = "unrecognized format" }
      failures += 1
      // A single failure after a known state: keep that state, look again in a second.
      if state != .unknown && failures < 2 {
        scheduleRead(after: 1)
        return
      }
    } else {
      failures = 0
      lastError = nil
    }
    guard next != state else { return }
    state = next
    onChange(next)
  }

  private static func describe(_ error: Error) -> String {
    switch (error as? CocoaError)?.code {
    case .fileReadNoSuchFile?: return "missing"
    case .fileReadNoPermission?: return "permission denied"
    default:
      let ns = error as NSError
      if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
        posix.domain == NSPOSIXErrorDomain
      {
        return String(cString: strerror(Int32(posix.code)))
      }
      return ns.localizedDescription
    }
  }
}
