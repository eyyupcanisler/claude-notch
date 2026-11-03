import AppKit
import ClaudeNotchCore
import ImageIO
import Observation

/// Spotify only (macOS closed other apps' now-playing info to third parties). State comes from
/// Spotify's own distributed notification, so nothing polls; AppleScript is used once at start,
/// for the cover URL on a track change and for the controls. Never launches Spotify: every
/// script runs only while it is already open.
@MainActor
@Observable
final class SpotifyModule {
  nonisolated static let bundleID = "com.spotify.client"
  /// Cover kept at this many pixels (ears 20 pt, tile 44 pt at 2x).
  nonisolated static let artPixels = 96

  private(set) var nowPlaying: NowPlaying?
  private(set) var artwork: NSImage?
  /// Automation permission for Spotify was refused (controls and cover cannot work).
  private(set) var denied = false
  /// True for a few seconds after the track changed (the tucked ears come out to show it).
  private(set) var justChanged = false
  @ObservationIgnored private var changeTask: Task<Void, Never>?
  static let showOnChange: TimeInterval = 3

  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var artTrackID: String?
  @ObservationIgnored private var enabled = false

  var isPlaying: Bool { nowPlaying?.isPlaying == true }

  func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    enabled = on
    if on { start() } else { stop() }
  }

  private func start() {
    let dnc = DistributedNotificationCenter.default()
    observers.append(
      dnc.addObserver(
        forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil,
        queue: .main
      ) { [weak self] note in
        let info = note.userInfo ?? [:]
        let now = NowPlaying.spotify(info, at: Date())
        Task { @MainActor in self?.update(now) }
      })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == SpotifyModule.bundleID else { return }
        Task { @MainActor in self?.update(nil) }
      })
    Task { await queryInitial() }
  }

  private func stop() {
    for o in observers {
      DistributedNotificationCenter.default().removeObserver(o)
      NSWorkspace.shared.notificationCenter.removeObserver(o)
    }
    observers = []
    nowPlaying = nil
    artwork = nil
    artTrackID = nil
  }

  private var spotifyRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
  }

  private func update(_ now: NowPlaying?) {
    guard enabled else { return }
    nowPlaying = now
    guard let now else {
      artwork = nil
      artTrackID = nil
      return
    }
    if now.trackID != artTrackID {
      let first = artTrackID == nil
      artTrackID = now.trackID
      artwork = nil
      Task { await loadArtwork(for: now.trackID) }
      if !first && now.isPlaying { flagChange() }
    }
  }

  private func flagChange() {
    changeTask?.cancel()
    justChanged = true
    changeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.showOnChange))
      guard !Task.isCancelled else { return }
      self?.justChanged = false
    }
  }

  private func queryInitial() async {
    guard spotifyRunning else { return }
    let script = """
      tell application "Spotify"
        if player state is stopped then return "stopped"
        set t to current track
        return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) \
      & linefeed & ((duration of t) as text) & linefeed & ((player position) as text) \
      & linefeed & (id of t)
      end tell
      """
    let r = await AppleScriptRunner.run(script)
    if r.errorCode == -1743 { denied = true }
    guard let out = r.output else { return }
    update(NowPlaying.spotifyScript(out, at: Date()))
  }

  private func loadArtwork(for trackID: String) async {
    guard spotifyRunning else { return }
    let r = await AppleScriptRunner.run(
      "tell application \"Spotify\" to return artwork url of current track")
    if r.errorCode == -1743 { denied = true }
    guard let s = r.output, let url = URL(string: s), url.scheme == "https",
      let (data, _) = try? await URLSession.shared.data(from: url),
      artTrackID == trackID
    else { return }
    artwork = Self.thumbnail(data)
  }

  /// Decodes straight to a small bitmap (the full 640 px cover is never kept).
  nonisolated static func thumbnail(_ data: Data) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: artPixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
  }

  // MARK: Controls

  func playPause() { command("playpause") }
  func next() { command("next track") }
  func previous() { command("previous track") }

  /// Jumps to `seconds` in the current track.
  func seek(to seconds: TimeInterval) {
    let s = String(format: "%.1f", max(0, seconds))
    // Optimistic: the bar moves at once; Spotify's notification confirms.
    if var n = nowPlaying {
      n.position = max(0, seconds)
      n.readAt = Date()
      nowPlaying = n
    }
    command("set player position to \(s)")
  }

  private func command(_ verb: String) {
    guard spotifyRunning else { return }
    Task {
      let r = await AppleScriptRunner.run("tell application \"Spotify\" to \(verb)")
      if r.errorCode == -1743 { denied = true }
    }
  }
}
