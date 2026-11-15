import AppKit
import ClaudeNotchCore
import CoreServices

enum Terminals {
  static let bundleIDs: [String: String] = [
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "vscode": "com.microsoft.VSCode",
    "ghostty": "com.mitchellh.ghostty",
    "WarpTerminal": "dev.warp.Warp-Stable",
    "cursor": "com.todesktop.230313mzl4w4u92",
    "WezTerm": "com.github.wez.wezterm",
    "kitty": "net.kovidgoyal.kitty",
    "Hyper": "co.zeit.hyper"
  ]

  static let ghosttyBundleID = "com.mitchellh.ghostty"

  enum Outcome {
    case activated
    /// The terminal is not known (nothing to bring forward).
    case unknownTerminal
    case failed
  }

  /// An accessory app that is not active cannot reliably `activate()` another app since
  /// macOS 14 (cooperative activation); LaunchServices can, also for already running apps.
  @MainActor
  static func activate(termProgram: String?) async -> Outcome {
    guard let termProgram, let id = bundleIDs[termProgram] else { return .unknownTerminal }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
      return .failed
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    do {
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
      return .activated
    } catch {
      return .failed
    }
  }

  static func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  /// Brings the session's terminal forward: the exact tab by tty (only while the claude pid
  /// still owns that tty), then for Ghostty the only terminal in the session's directory, then
  /// the app itself. -1743 maps to `.notAuthorized` (the app is still activated).
  @MainActor
  static func focus(_ session: Session, probe: ProcessProbe) async -> FocusOutcome {
    guard let term = session.termProgram, let bundleID = bundleIDs[term] else {
      return .unknownTerminal
    }
    let kind = TerminalKind(termProgram: term)
    var result: FocusOutcome?
    if isRunning(bundleID) {
      if let tty = session.tty, let pid = session.pid, probe.owns(pid: pid, tty: tty),
        let script = kind.focusScript(tty: tty)
      {
        let r = await AppleScriptRunner.run(script)
        if r.errorCode == FocusOutcome.errNotPermitted {
          result = .notAuthorized(app: kind.appName)
        } else if r.output == "focused" {
          result = .focusedTerminal
        }
      }
      if result == nil, kind == .ghostty,
        let script = TerminalScript.ghosttyFocus(directory: session.cwd)
      {
        let r = await AppleScriptRunner.run(script)
        if r.errorCode == FocusOutcome.errNotPermitted {
          result = .notAuthorized(app: kind.appName)
        } else if r.output == "focused" {
          result = .focusedByDirectory
        }
      }
    }
    // The script's own `activate` may be ignored for an accessory app: LaunchServices too.
    let app = await activate(termProgram: term)
    if let result { return result }
    return app == .activated ? .activatedApp : .failed
  }

  /// tty of Ghostty's focused terminal (raw Apple Event, no AppleScript). Only call when
  /// `automationStatus` is granted (0); the event itself never asks for consent.
  static func focusedGhosttyTTY() async -> String? {
    guard isRunning(ghosttyBundleID),
      let texts = await AppleScriptRunner.get({ [GhosttyQuery.focusedTTY()] }, from: ghosttyBundleID)
    else { return nil }
    return HookContext.validTTY(texts.first?.first)
  }

  /// Tab titles of Ghostty's terminals by tty, and each tty's position in Ghostty's tab order
  /// (window → tab → split), read with raw Apple Events (no AppleScript). Only call when
  /// `automationStatus` is granted (0); the events themselves never ask for consent.
  static func ghosttyTitles() async -> (titles: [String: String], order: [String: Int])? {
    guard isRunning(ghosttyBundleID),
      let lists = await AppleScriptRunner.get(GhosttyQuery.titles, from: ghosttyBundleID),
      lists.count == 2
    else { return nil }
    return (TabTitle.map(ttys: lists[0], names: lists[1]), TabTitle.order(ttys: lists[0]))
  }

  /// Automation (Apple Events) permission towards `bundleID` without asking the user:
  /// 0 granted, -1743 denied, -1744 would prompt, -600 target not running.
  static func automationStatus(bundleID: String) async -> Int32 {
    await AppleScriptRunner.permission(bundleID: bundleID)
  }

  /// Same, but lets macOS show its consent prompt when the user was never asked. Blocks (off
  /// the main thread, on its own queue) until the user answers. Only on an explicit click.
  static func requestAutomation(bundleID: String) async -> Int32 {
    await AppleScriptRunner.permission(bundleID: bundleID, askUserIfNeeded: true)
  }
}

struct ScriptResult: Sendable {
  var output: String?
  var errorCode: Int?
}

/// Runs AppleScript and raw Apple Events in-process on one serial queue (never on the main
/// thread: an Apple Event to a busy terminal blocks until it answers or times out).
enum AppleScriptRunner {
  private static let queue = DispatchQueue(
    label: "com.eyyupcan.claudenotch.applescript", qos: .userInitiated)

  /// Compiled scripts of fixed sources (`reuse: true`), only touched on `queue`. macOS scans
  /// every script it compiles (XProtect: ~14 MB of short-lived heap and 15-50 ms each time);
  /// a compiled script runs again in about a millisecond. Only fixed sources come here, so the
  /// cache stays as small as the list of those scripts.
  nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

  /// The script for `source`, compiled once when `reuse` is set; nil with the error code when
  /// it does not compile. Call on `queue` only.
  private static func script(_ source: String, reuse: Bool) -> (NSAppleScript?, Int?) {
    if reuse, let cached = compiled[source] { return (cached, nil) }
    guard let script = NSAppleScript(source: source) else { return (nil, -1) }
    guard reuse else { return (script, nil) }
    var error: NSDictionary?
    guard script.compileAndReturnError(&error) else {
      return (nil, (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1)
    }
    // Fixed sources only, so this never fills up; the cap is a guard against a reused source
    // that is built from a variable by mistake.
    if compiled.count < 16 { compiled[source] = script }
    return (script, nil)
  }

  /// `reuse`: the source never changes (no tty, path or number in it), so it is compiled once
  /// and kept for the next runs.
  static func run(_ source: String, reuse: Bool = false) async -> ScriptResult {
    await withCheckedContinuation { cont in
      queue.async {
        var retried = false
        while true {
          let wasCached = reuse && compiled[source] != nil
          let (script, failure) = Self.script(source, reuse: reuse)
          guard let script else {
            cont.resume(returning: ScriptResult(output: nil, errorCode: failure ?? -1))
            return
          }
          var error: NSDictionary?
          let desc = script.executeAndReturnError(&error)
          guard let error else {
            cont.resume(returning: ScriptResult(output: desc.stringValue, errorCode: nil))
            return
          }
          let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
          // A cached script that fails for another reason than a missing Automation grant is
          // compiled again. After its app quit and relaunched (Spotify does after an update)
          // it fails with "connection is invalid" (-609): that one is retried at once with a
          // fresh compile, so the click is not lost.
          if reuse, code != -1743, code != -1744 {
            compiled[source] = nil
            if wasCached, code == -609, !retried {
              retried = true
              continue
            }
          }
          cont.resume(returning: ScriptResult(output: nil, errorCode: code))
          return
        }
      }
    }
  }

  /// Sends one `get` Apple Event per specifier to the running app `bundleID` and returns each
  /// reply as text (`AEQuery.texts`); nil on any error. Raw events, not AppleScript: nothing is
  /// compiled, so there is no XProtect scan and the AppleScript component is not loaded for
  /// them. Same 4 s timeout as the scripts. `kAEDoNotPromptForUserConsent`: a missing
  /// Automation grant fails (-1744) instead of asking. The specifiers are built on the queue
  /// (descriptors are not Sendable).
  static func get(
    _ specifiers: @escaping @Sendable () -> [NSAppleEventDescriptor], from bundleID: String
  ) async -> [[String]]? {
    await withCheckedContinuation { cont in
      queue.async {
        var out: [[String]] = []
        for specifier in specifiers() {
          let event = AEQuery.get(specifier, bundleID: bundleID)
          guard
            let reply = try? event.sendEvent(
              options: [.waitForReply, .neverInteract, doNotPrompt],
              timeout: TimeInterval(TerminalScript.timeoutSeconds)),
            (reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0) == 0,
            let value = reply.paramDescriptor(forKeyword: keyDirectObject)
          else {
            cont.resume(returning: nil)
            return
          }
          out.append(AEQuery.texts(of: value))
        }
        cont.resume(returning: out)
      }
    }
  }

  /// kAEDoNotPromptForUserConsent (AEDataModel.h), not in SendOptions.
  private static let doNotPrompt = NSAppleEventDescriptor.SendOptions(rawValue: 0x0002_0000)

  /// The consent prompt waits for the user: never on the script queue (a focus script would
  /// stall behind it).
  private static let consentQueue = DispatchQueue(
    label: "com.eyyupcan.claudenotch.consent", qos: .userInitiated)

  static func permission(bundleID: String, askUserIfNeeded: Bool = false) async -> Int32 {
    await withCheckedContinuation { cont in
      (askUserIfNeeded ? consentQueue : queue).async {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else {
          cont.resume(returning: -1)
          return
        }
        let status = AEDeterminePermissionToAutomateTarget(
          desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
        cont.resume(returning: status)
      }
    }
  }
}
