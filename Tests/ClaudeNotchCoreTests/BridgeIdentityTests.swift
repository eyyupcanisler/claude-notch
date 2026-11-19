import Foundation
import XCTest

/// The hook bridge (hooks/claude-notch-hook.sh) names the chat's tty and pid by walking up from
/// the hook to the claude process. Run against a fake `ps` (a made-up process table) and a fake
/// `curl` (records the headers it was given), so no real process or socket is involved.
final class BridgeIdentityTests: XCTestCase {
  private var dir: URL!
  private var socketFD: Int32 = -1

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("cn-bridge-\(UUID().uuidString.prefix(8))")
    let bin = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try write(
      """
      #!/bin/bash
      # Answers `ps -o tty=,ppid=,comm= -p <pid>` from the table: lines of "pid|tty ppid comm".
      pid="${@: -1}"
      while IFS='|' read -r k v; do
        if [ "$k" = "$pid" ]; then printf '%s\\n' "$v"; exit 0; fi
      done < "$FAKE_PS"
      exit 1
      """, to: bin.appendingPathComponent("ps"))
    try write(
      """
      #!/bin/bash
      printf '%s\\n' "$@" > "$CURL_LOG"
      cat > /dev/null
      """, to: bin.appendingPathComponent("curl"))
    // The bridge only runs when the app's socket exists: a bound (not listening) one will do.
    socketFD = try bindSocket(at: dir.appendingPathComponent("s.sock").path)
  }

  override func tearDownWithError() throws {
    if socketFD >= 0 { Darwin.close(socketFD) }
    try? FileManager.default.removeItem(at: dir)
  }

  /// The chat a /restart brings back runs as Claude Code's versioned build, named only by its
  /// version: it is the chat, with its tty and pid (it used to send none, so the notch showed a
  /// second segment for it that could not be opened).
  func testVersionedBuildIsTheChat() throws {
    let me = getpid()
    let h = try headers(table: [
      "\(me)|ttys009 4000 /Users/x/.local/share/claude/versions/2.1.328"
    ])
    XCTAssertTrue(h.contains("X-Claude-TTY: /dev/ttys009"), "\(h)")
    XCTAssertTrue(h.contains("X-Claude-PID: \(me)"), "\(h)")
  }

  /// Behind a shell wrapper too.
  func testVersionedBuildBehindAShell() throws {
    let h = try headers(table: [
      "\(getpid())|?? 5000 /bin/zsh",
      "5000|ttys009 4000 /Users/x/.local/share/claude/versions/2.1.328",
    ])
    XCTAssertTrue(h.contains("X-Claude-TTY: /dev/ttys009"), "\(h)")
    XCTAssertTrue(h.contains("X-Claude-PID: 5000"), "\(h)")
  }

  /// A plain `claude` keeps working as before.
  func testPlainClaude() throws {
    let h = try headers(table: ["\(getpid())|ttys003 4000 /Users/x/.local/bin/claude"])
    XCTAssertTrue(h.contains("X-Claude-TTY: /dev/ttys003"), "\(h)")
  }

  /// No terminal (a background spare, `claude -p` from a tool) or another program: no identity.
  func testNoIdentityWithoutATerminalOrForAnotherProgram() throws {
    for table in [
      ["\(getpid())|?? 4000 /Users/x/.local/share/claude/versions/2.1.328"],
      ["\(getpid())|ttys009 4000 /usr/bin/python3"],
      ["\(getpid())|ttys009 4000 /Users/x/versions/2.1.328"],
    ] {
      let h = try headers(table: table)
      XCTAssertFalse(h.contains { $0.hasPrefix("X-Claude-TTY") }, "\(table): \(h)")
      XCTAssertFalse(h.contains { $0.hasPrefix("X-Claude-PID") }, "\(table): \(h)")
    }
  }

  // MARK: - Helpers

  /// Runs the bridge with this process as the hook's parent; returns the curl header values.
  private func headers(table: [String]) throws -> [String] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let psTable = dir.appendingPathComponent("ps.txt")
    let log = dir.appendingPathComponent("curl.txt")
    try? FileManager.default.removeItem(at: log)
    try (table.joined(separator: "\n") + "\n").write(to: psTable, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [root.appendingPathComponent("hooks/claude-notch-hook.sh").path, "event"]
    p.environment = [
      "PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin",
      "HOME": dir.path,
      "CLAUDE_NOTCH_SOCK": dir.appendingPathComponent("s.sock").path,
      "FAKE_PS": psTable.path,
      "CURL_LOG": log.path,
    ]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8))
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    XCTAssertEqual(p.terminationStatus, 0)
    let args = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    // Each header follows a "-H".
    return zip(args, args.dropFirst()).filter { $0.0 == "-H" }.map(\.1)
  }

  private func write(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func bindSocket(at path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw XCTSkip("no socket") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    XCTAssertLessThan(bytes.count, capacity, "socket path too long")
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in bytes.prefix(capacity - 1).enumerated() { buf[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(ok, 0, "bind failed")
    return fd
  }
}
