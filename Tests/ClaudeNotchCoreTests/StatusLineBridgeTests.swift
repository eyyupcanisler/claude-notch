import Foundation
import XCTest

/// scripts/install-statusline.sh and hooks/claude-notch-statusline.sh: Claude Code gives plan
/// usage only to the status line, so the notch's bridge takes the status line's place and runs
/// the previous one unchanged. Run in a scratch HOME and app folder, never the real settings.
final class StatusLineBridgeTests: XCTestCase {
  private var dir: URL!
  private var home: URL { dir.appendingPathComponent("home") }
  private var appDir: URL { dir.appendingPathComponent("App Support") }
  private var settings: URL { home.appendingPathComponent(".claude/settings.json") }
  private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("cn-sl-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// No status line before (the friend's case): the bridge is installed, copies its input for
  /// the notch and prints nothing; uninstall takes the entry away again.
  func testNoStatusLineBefore() throws {
    try writeSettings(#"{"model":"opus"}"#)
    XCTAssertEqual(try installer([]).code, 0)
    let line = try statusLine()
    XCTAssertEqual(line?["type"] as? String, "command")
    let command = try XCTUnwrap(line?["command"] as? String)
    XCTAssertTrue(command.contains("claude-notch-statusline.sh"), command)
    XCTAssertTrue(command.hasPrefix("'"), "quoted: the folder has a space")
    let payload = #"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#
    let out = try run("/bin/sh", ["-c", command], stdin: payload)
    XCTAssertEqual(out.output, "")
    XCTAssertEqual(
      try String(contentsOf: appDir.appendingPathComponent("statusline.json"), encoding: .utf8),
      payload)
    let mode = try FileManager.default.attributesOfItem(
      atPath: appDir.appendingPathComponent("statusline.json").path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    XCTAssertEqual(try installer(["--check"]).code, 0)
    XCTAssertEqual(try installer([]).code, 0, "a second install changes nothing")
    XCTAssertEqual(try installer(["--uninstall"]).code, 0)
    XCTAssertNil(try statusLine())
    XCTAssertEqual(try installer(["--check"]).code, 3)
    XCTAssertEqual(try json(settings)["model"] as? String, "opus", "the rest stays")
  }

  /// A status line command of its own keeps printing through the bridge, with its other
  /// fields, and comes back exactly as it was.
  func testPreviousCommandKeepsRunning() throws {
    try writeSettings(
      #"{"statusLine":{"type":"command","command":"jq -r .model | sed 's/^/M:/'","padding":2}}"#)
    XCTAssertEqual(try installer([]).code, 0)
    let line = try XCTUnwrap(try statusLine())
    XCTAssertEqual(line["padding"] as? Int, 2)
    let out = try run("/bin/sh", ["-c", line["command"] as? String ?? ""], stdin: #"{"model":"x"}"#)
    XCTAssertEqual(out.output, "M:x\n")
    XCTAssertEqual(try installer(["--uninstall"]).code, 0)
    let back = try XCTUnwrap(try statusLine())
    XCTAssertEqual(back["command"] as? String, "jq -r .model | sed 's/^/M:/'")
    XCTAssertEqual(back["padding"] as? Int, 2)
  }

  /// The bridge never fails a status line: without the app's folder it copies nothing and
  /// exits cleanly; with it, the previous line prints.
  func testBridgeNeverFailsTheLine() throws {
    try writeSettings(#"{"statusLine":{"type":"command","command":"echo hi"}}"#)
    XCTAssertEqual(try installer([]).code, 0)
    let bridge = root.appendingPathComponent("hooks/claude-notch-statusline.sh").path
    try "echo hi".write(
      to: appDir.appendingPathComponent("statusline-command"), atomically: true, encoding: .utf8)
    // A bridge pointed at a folder that does not exist copies nothing and still runs the line
    // it finds there: none here, so it prints nothing, and does not fail.
    let gone = try run(
      "/bin/bash", [bridge], stdin: "{}",
      env: ["CLAUDE_NOTCH_DIR": dir.appendingPathComponent("missing").path])
    XCTAssertEqual(gone.code, 0)
    let ok = try run("/bin/bash", [bridge], stdin: "{}")
    XCTAssertEqual(ok.output, "hi\n")
  }

  /// A script that already hands its input to ClaudeNotch (an earlier version added a line to
  /// it) is left alone and counts as connected.
  func testScriptThatAlreadyCopiesIsLeftAlone() throws {
    let script = home.appendingPathComponent(".claude/sl.sh")
    try """
      #!/bin/bash
      input=$(cat)
      # ClaudeNotch: plan kullanımını çentiğe ilet
      printf '%s' "$input" > "$HOME/Library/Application Support/ClaudeNotch/statusline.json"
      """.write(to: script, atomically: true, encoding: .utf8)
    try writeSettings(#"{"statusLine":{"type":"command","command":"~/.claude/sl.sh"}}"#)
    XCTAssertEqual(try installer([]).code, 0)
    XCTAssertEqual(try statusLine()?["command"] as? String, "~/.claude/sl.sh")
    XCTAssertEqual(try installer(["--check"]).code, 0)
  }

  // MARK: - Helpers

  private func installer(_ args: [String]) throws -> (code: Int32, output: String) {
    try run(
      "/bin/bash",
      [root.appendingPathComponent("scripts/install-statusline.sh").path, "--settings", settings.path]
        + args, stdin: "")
  }

  private func run(
    _ exe: String, _ args: [String], stdin: String, env extra: [String: String] = [:]
  ) throws -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": home.path, "CLAUDE_NOTCH_DIR": appDir.path, "CLAUDE_NOTCH_LANG": "en",
    ].merging(extra) { _, new in new }
    let input = Pipe()
    let output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    try p.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func writeSettings(_ text: String) throws {
    try text.write(to: settings, atomically: true, encoding: .utf8)
  }

  private func json(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  private func statusLine() throws -> [String: Any]? {
    try json(settings)["statusLine"] as? [String: Any]
  }
}
