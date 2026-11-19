import Foundation
import XCTest

@testable import ClaudeNotchCore

/// Which app a chat runs in (`TerminalHost`): TERM_PROGRAM, else the inherited bundle id. A
/// friend's iTerm2 chats arrived with neither tty nor TERM_PROGRAM, and every jump said "Can't
/// tell which terminal"; the bundle id names the app in those cases.
@MainActor
final class TerminalHostTests: XCTestCase {
  private let iterm = "com.googlecode.iterm2"

  func testTerminalProgramWinsForTerminals() {
    XCTAssertEqual(TerminalHost.bundleID(termProgram: "iTerm.app", termBundle: nil), iterm)
    XCTAssertEqual(
      TerminalHost.bundleID(termProgram: "Apple_Terminal", termBundle: nil), "com.apple.Terminal")
    XCTAssertEqual(
      TerminalHost.bundleID(termProgram: "ghostty", termBundle: "com.apple.Terminal"),
      "com.mitchellh.ghostty", "a terminal's own TERM_PROGRAM is the most direct clue")
  }

  func testBundleIDFillsInWhatTermProgramMisses() {
    // No TERM_PROGRAM at all (the friend's chats; Alacritty; Claude's desktop app).
    XCTAssertEqual(TerminalHost.bundleID(termProgram: nil, termBundle: iterm), iterm)
    // tmux inside iTerm2.
    XCTAssertEqual(TerminalHost.bundleID(termProgram: "tmux", termBundle: iterm), iterm)
    // Cursor calls itself vscode; its bundle id tells them apart.
    XCTAssertEqual(
      TerminalHost.bundleID(termProgram: "vscode", termBundle: "com.todesktop.230313mzl4w4u92"),
      "com.todesktop.230313mzl4w4u92")
    XCTAssertEqual(
      TerminalHost.bundleID(termProgram: "vscode", termBundle: nil), "com.microsoft.VSCode")
    XCTAssertNil(TerminalHost.bundleID(termProgram: nil, termBundle: nil))
    XCTAssertNil(TerminalHost.bundleID(termProgram: "tmux", termBundle: nil))
  }

  func testBundleIDValidation() {
    XCTAssertEqual(TerminalHost.validBundleID(iterm), iterm)
    XCTAssertEqual(TerminalHost.validBundleID("dev.warp.Warp-Stable"), "dev.warp.Warp-Stable")
    for bad in [
      "", "iterm", ".com.x", "com.x.", "com..x", "com.x\"; do shell script \"y", "com.x y",
      "com.x/../y", String(repeating: "a.", count: 70),
    ] {
      XCTAssertNil(TerminalHost.validBundleID(bad), bad)
    }
  }

  func testKindFromBundleID() {
    XCTAssertEqual(TerminalKind(bundleID: iterm), .iTerm)
    XCTAssertEqual(TerminalKind(bundleID: "com.apple.Terminal"), .appleTerminal)
    XCTAssertEqual(TerminalKind(bundleID: "com.mitchellh.ghostty"), .ghostty)
    XCTAssertEqual(TerminalKind(bundleID: "com.microsoft.VSCode"), .other)
    var s = Session(
      id: "a", project: "p", cwd: "/p", termProgram: nil, termBundle: iterm, status: .idle,
      startedAt: Date(), lastUpdate: Date())
    XCTAssertEqual(s.terminalKind, .iTerm)
    XCTAssertEqual(s.hostBundleID, iterm)
    s.termProgram = "tmux"
    XCTAssertEqual(s.terminalKind, .iTerm)
    XCTAssertTrue(s.behindTmux)
  }

  func testContextReadsTheBundleHeader() {
    func req(_ h: [String: String]) -> HTTPRequest {
      HTTPRequest(method: "POST", target: "/event", headers: h, body: Data())
    }
    XCTAssertEqual(HookContext(request: req(["x-term-bundle": iterm])).termBundle, iterm)
    XCTAssertNil(HookContext(request: req(["x-term-bundle": "x\" & y"])).termBundle)
    XCTAssertNil(HookContext(request: req([:])).termBundle)
  }

  func testStoreKeepsTheBundleAndAPlaceholderPassesItOn() {
    let probe = ProcessProbe(isAlive: { _ in true }, ttyOf: { _ in nil })
    let store = SessionStore(probe: probe)
    store.applyDiscovery([
      ProcessRecord(
        pid: 900, ppid: 1, tty: "/dev/ttys030", path: "/usr/local/bin/claude", args: ["claude"],
        cwd: "/Users/x/all", termProgram: nil, termBundle: iterm)
    ])
    XCTAssertEqual(store.sessions["found:900"]?.hostBundleID, iterm)
    store.handleEvent(
      HookEvent(name: "SessionStart", sessionID: "s1", cwd: "/Users/x/all"),
      context: HookContext(termProgram: nil, tty: "/dev/ttys030", pid: 900))
    XCTAssertNil(store.sessions["found:900"])
    XCTAssertEqual(store.sessions["s1"]?.termBundle, iterm, "inherited from the placeholder")
    store.handleEvent(
      HookEvent(name: "UserPromptSubmit", sessionID: "s2", cwd: "/Users/x/all"),
      context: HookContext(termBundle: "com.apple.Terminal"))
    XCTAssertEqual(store.sessions["s2"]?.hostBundleID, "com.apple.Terminal")
  }

  /// A terminal-only question stays out of sight while the chat's terminal is in front, also
  /// when only the bundle id names that terminal.
  func testTerminalInFrontByBundle() {
    XCTAssertTrue(AskingPeek.terminalInFront(
      termProgram: nil, terminalBundleID: iterm, frontmostBundleID: iterm))
    XCTAssertTrue(AskingPeek.terminalInFront(
      termProgram: "tmux", terminalBundleID: iterm, frontmostBundleID: iterm))
    XCTAssertFalse(AskingPeek.terminalInFront(
      termProgram: nil, terminalBundleID: "com.microsoft.VSCode",
      frontmostBundleID: "com.microsoft.VSCode"), "an editor may have its terminal closed")
    XCTAssertFalse(AskingPeek.terminalInFront(
      termProgram: nil, terminalBundleID: iterm, frontmostBundleID: "com.apple.Safari"))
  }
}
