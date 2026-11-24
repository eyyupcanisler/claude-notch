import Foundation

/// How the app learns that the user switched to a Ghostty tab or split, so a "done" or waiting
/// chat can be marked seen.
public enum SeenWatchMode: String, Sendable, Equatable {
  /// Accessibility events from Ghostty (focus, window, title changes) trigger the check; the
  /// 0.5 s poll and the click monitor are off.
  case events
  /// The fallback: while Ghostty is in front and a chat could be cleared, the focused terminal
  /// is asked for every 0.5 s and after each click.
  case polling
}

public enum SeenWatch {
  /// Events only when the app is trusted for Accessibility, Ghostty runs and the observer on
  /// it is attached; polling in every other case (not trusted, Ghostty not running, attaching
  /// failed).
  public static func mode(trusted: Bool, ghosttyRunning: Bool, attached: Bool) -> SeenWatchMode {
    trusted && ghosttyRunning && attached ? .events : .polling
  }

  /// A window title as compared for title-change events: leading spaces and Claude Code's
  /// spinner / status glyphs dropped (the same set `TabTitle.clean` removes), nothing shortened.
  /// A working chat animates its tab title several times a second; only a change of the text
  /// after the glyph (another tab's title showing up) is worth a focused-terminal check.
  public static func titleKey(_ raw: String) -> String {
    let scalars = raw.unicodeScalars.drop {
      $0.properties.isWhitespace || TabTitle.isStatusGlyph($0)
    }
    return String(String.UnicodeScalarView(scalars))
  }
}

/// Turns bursts of Accessibility events from Ghostty into single focused-terminal checks.
///
/// - A focus event (window, main window, focused element) asks for a check `focusDelay` later;
///   more events in that time join the same check.
/// - A title event asks `titleDelay` later: a program animating its tab title (Claude Code's
///   spinner) must not cause more checks than the 0.5 s poll would.
/// - An event while a check is in flight is not dropped: the check runs once more after it
///   ends (at the soonest delay any of those events asked for).
/// - After Ghostty gave no focused terminal (hung, no window), checks wait `quietAfterNoAnswer`
///   so a stuck Ghostty cannot keep the shared Apple Event queue busy.
///
/// The caller schedules a timer for each returned `Schedule` and calls `fire` with its token;
/// a token replaced by a sooner schedule is ignored.
public struct SeenEventGate: Sendable {
  public enum Trigger: Sendable, Equatable {
    case focus
    case title
  }

  public struct Schedule: Sendable, Equatable {
    public let token: Int
    public let delay: TimeInterval
  }

  public static let focusDelay: TimeInterval = 0.05
  public static let titleDelay: TimeInterval = 0.5
  public static let quietAfterNoAnswer: TimeInterval = 2

  /// When the scheduled check runs; nil when none is scheduled.
  public private(set) var due: Date?
  /// The trigger the scheduled check is for.
  private var dueTrigger = Trigger.focus
  /// A check is owed after the one in flight ends, with the trigger that asked soonest.
  public private(set) var rerun: Trigger?
  private var token = 0
  private var quietUntil = Date.distantPast

  public init() {}

  static func delay(_ trigger: Trigger) -> TimeInterval {
    trigger == .focus ? focusDelay : titleDelay
  }

  /// Of a pending re-run and a new trigger, the one that asks sooner.
  private static func soonest(_ a: Trigger?, _ b: Trigger) -> Trigger {
    a == .focus || b == .focus ? .focus : .title
  }

  /// An event came at `now`; `busy`: a focused-terminal check is in flight. Returns the check
  /// to schedule, or nil when one is already scheduled at least as soon, or when the check in
  /// flight will run again.
  public mutating func event(_ trigger: Trigger, now: Date, busy: Bool) -> Schedule? {
    if busy {
      rerun = Self.soonest(rerun, trigger)
      return nil
    }
    let wanted = max(now.addingTimeInterval(Self.delay(trigger)), quietUntil)
    if let due, due <= wanted { return nil }
    due = wanted
    dueTrigger = trigger
    token += 1
    return Schedule(token: token, delay: wanted.timeIntervalSince(now))
  }

  /// The timer of `token` went off: true when the check should start now. A replaced token
  /// does nothing; a check still in flight makes this one a re-run after it.
  public mutating func fire(_ token: Int, busy: Bool) -> Bool {
    guard token == self.token, due != nil else { return false }
    due = nil
    if busy {
      rerun = Self.soonest(rerun, dueTrigger)
      return false
    }
    return true
  }

  /// A focused-terminal check (from any caller) ended at `now`. `answered`: Ghostty gave a
  /// terminal (true) or nothing (false); nil when the check did not ask Ghostty. Returns the
  /// re-run to schedule, if an event came while it was in flight.
  public mutating func checkEnded(answered: Bool?, now: Date) -> Schedule? {
    if let answered {
      quietUntil = answered ? .distantPast : now.addingTimeInterval(Self.quietAfterNoAnswer)
    }
    guard let trigger = rerun else { return nil }
    rerun = nil
    return event(trigger, now: now, busy: false)
  }
}
