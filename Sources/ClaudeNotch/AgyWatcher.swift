import ClaudeNotchCore
import Foundation

/// What the notch reads about agy (Antigravity CLI) chats besides their hook events:
///
/// - agy-bridge's folder (`~/.gemini/config/agy-bridge`, kernel file events, no polling):
///   `meters.json` (the plan meters, % left) and `statusline-<agyPid>.json` (each agy process's
///   status line input: its chat's model, effort and context left). Without the folder (no
///   agy-bridge on this Mac) the agy meters stay off; the folder is looked for again later.
/// - each agy chat's own CLI log (`~/.gemini/antigravity-cli/log/cli-<start>.log`, the file its
///   process keeps open, found once with lsof): the lines that say a permission prompt or a
///   question opened, or a prompt was answered (`AgyLogEvent`). Only new lines are read, every
///   `tick` seconds while agy chats exist.
@MainActor
final class AgyWatcher {
  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".gemini/config/agy-bridge", isDirectory: true)
  static let tick: TimeInterval = 1.5
  /// After a failed log lookup, the same process is not looked up again for this long.
  static let lookupRetry: TimeInterval = 30
  /// The most of a log read in one tick (a burst of lines; the rest waits for the next tick).
  static let maxRead = 256 * 1024

  private let store: SessionStore
  private let usage: UsageModule
  private var source: DispatchSourceFileSystemObject?
  private var timer: Timer?
  private var lastFolderCheck = Date.distantPast

  private struct LogTail {
    var path: String
    var offset: UInt64
    var partial = Data()
  }
  private var logs: [Int32: LogTail] = [:]
  private var lookingUp: Set<Int32> = []
  private var failedLookup: [Int32: Date] = [:]

  init(store: SessionStore, usage: UsageModule) {
    self.store = store
    self.usage = usage
  }

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickNow() }
    }
    tickNow()
  }

  /// The status line snapshot of agy process `pid`, if agy-bridge wrote one.
  static func snapshot(pid: Int32) -> AgyStatusSnapshot? {
    let url = folder.appendingPathComponent("statusline-\(pid).json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return AgyStatusSnapshot.parse(data)
  }

  private func tickNow() {
    if source == nil, Date().timeIntervalSince(lastFolderCheck) > 60 {
      lastFolderCheck = Date()
      watchFolder()
    }
    readLogs()
  }

  // MARK: agy-bridge's folder

  private func watchFolder() {
    let fd = open(Self.folder.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let src = self.source else { return }
        if src.data.contains(.delete) || src.data.contains(.rename) && !self.folderExists {
          // The folder itself went away: look for it again later.
          src.cancel()
          self.source = nil
          self.usage.setAgy(nil)
          return
        }
        self.readFolder()
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src
    readFolder()
  }

  private var folderExists: Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: Self.folder.path, isDirectory: &isDir)
      && isDir.boolValue
  }

  private func readFolder() {
    let meters = (try? Data(contentsOf: Self.folder.appendingPathComponent("meters.json")))
      .flatMap(AgyUsage.parse)
    usage.setAgy(meters)
    for chat in store.agyChats {
      guard let s = Self.snapshot(pid: chat.pid) else { continue }
      store.applyAgySnapshot(s, pid: chat.pid)
      if let left = s.contextLeft {
        usage.recordContext(ContextLeft(sessionID: chat.sessionID, percent: min(100, max(0, left))))
      }
    }
  }

  // MARK: agy's CLI logs

  private func readLogs() {
    let pids = Set(store.agyChats.map(\.pid))
    logs = logs.filter { pids.contains($0.key) }
    failedLookup = failedLookup.filter { pids.contains($0.key) }
    for pid in pids where logs[pid] == nil && !lookingUp.contains(pid) {
      if let failed = failedLookup[pid], Date().timeIntervalSince(failed) < Self.lookupRetry {
        continue
      }
      lookingUp.insert(pid)
      Task.detached(priority: .utility) {
        let path = Self.logPath(pid: pid)
        await MainActor.run { [weak self] in self?.found(path, pid: pid) }
      }
    }
    for pid in logs.keys.sorted() { readNewLines(pid: pid) }
  }

  private func found(_ path: String?, pid: Int32) {
    lookingUp.remove(pid)
    guard let path, store.agyChats.contains(where: { $0.pid == pid }) else {
      failedLookup[pid] = Date()
      return
    }
    // Start at the end: lines written before the chat had a row are history.
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    logs[pid] = LogTail(path: path, offset: size)
  }

  private func readNewLines(pid: Int32) {
    guard var tail = logs[pid], let handle = FileHandle(forReadingAtPath: tail.path) else {
      // Gone or unreadable: look it up again, but not before `lookupRetry`.
      logs[pid] = nil
      failedLookup[pid] = Date()
      return
    }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return }
    if end < tail.offset {
      // Replaced or truncated: carry on from its end (its old lines are history, and replaying
      // a "Surfacing" line would turn a row amber with nothing to answer).
      tail.offset = end
      tail.partial = Data()
      logs[pid] = tail
      return
    }
    guard end > tail.offset else { return }
    try? handle.seek(toOffset: tail.offset)
    let count = Int(min(UInt64(Self.maxRead), end - tail.offset))
    guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { return }
    tail.offset += UInt64(chunk.count)
    let data = tail.partial + chunk
    var events: [AgyLogEvent] = []
    var start = data.startIndex
    while let newline = data[start...].firstIndex(of: 0x0A) {
      if let e = AgyLogEvent.parse(String(decoding: data[start..<newline], as: UTF8.self)) {
        events.append(e)
      }
      start = data.index(after: newline)
    }
    // A line longer than a read is not one of agy's short lines: drop it rather than grow.
    let rest = data[start...]
    tail.partial = rest.count > Self.maxRead ? Data() : Data(rest)
    logs[pid] = tail
    for e in events { store.handleAgyLog(e, pid: pid) }
  }

  /// The CLI log agy process `pid` keeps open, from lsof (nil when there is none).
  nonisolated static func logPath(pid: Int32) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-a", "-p", "\(pid)", "-Fn"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let marker = "/.gemini/antigravity-cli/log/cli-"
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
    where line.hasPrefix("n") && line.contains(marker) && line.hasSuffix(".log") {
      return String(line.dropFirst())
    }
    return nil
  }
}
