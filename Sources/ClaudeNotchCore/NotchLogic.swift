import CoreGraphics
import Foundation

// Pure UI policy (no AppKit) so it can be unit tested: risky commands, text shortening, the
// peek planner, hover intent and the display order of the session list.

// MARK: - Risky commands

public enum RiskClassifier {
  /// Short Turkish reason when the request is destructive enough to need hold-to-allow (or
  /// ⌘⏎), nil otherwise. Only shell commands are classified. `text` may be raw or the
  /// sanitized display text (a literal `\n` / `\t` is treated as a separator).
  public static func risk(toolName: String, text: String) -> String? {
    guard toolName == "Bash" else { return nil }
    if text.count > ToolSummary.fullLimit { return "çok uzun komut" }
    let cmd = normalize(text)
    if hasRecursiveForceRemove(cmd) { return "rm -rf" }
    for (pattern, reason) in patterns where matches(pattern, cmd) { return reason }
    return exfiltration(cmd)
  }

  // MARK: Data exfiltration

  /// Uploads of local files (`curl -d @f`, `-F x=@f`, `-T f`, `wget --post-file`). Matched
  /// against `maskQuoted(cmd)`, so a `&` inside a quoted URL does not end the command.
  private static let uploadPatterns: [String] = [
    #"\bcurl\b[^;&|]*\s(-[a-zA-Z]*d|--data(-binary|-raw|-urlencode|-ascii)?|--json)"#
      + #"(\s+|=)?['"]?@"#,
    #"\bcurl\b[^;&|]*\s--data-urlencode(\s+|=)['"]?[^\s'"=]*@"#,
    #"\bcurl\b[^;&|]*\s(-[a-zA-Z]*F|--form(-string)?)(\s+|=)?['"]?[^\s'"=]*=['"]?[@<]"#,
    #"\bcurl\b[^;&|]*\s(-T|--upload-file|-(?![a-zA-Z]*X)[a-zA-Z]+T)(\s|=|$)"#,
    #"\bwget\b[^;&|]*--(post|body|put)-file\b"#
  ]

  /// Secrets: ssh / cloud credentials, dotenv files, private keys and certificates.
  private static let secretPattern =
    #"/\.(ssh|aws|gnupg|kube)\b"#
    + #"|(^|[\s/'"=<@])\.env(\.[\w-]+)?($|[\s'"/;|&)>])"#
    + #"|[\w~.-]\.(pem|key|p12|pfx)\b|\bid_(rsa|ed25519|ecdsa|dsa)\b"#
    + #"|(^|[\s/'"=<@])\.(netrc|npmrc|pypirc)\b"#

  /// Something that moves data out of the command: a pipe, an output redirect (not to
  /// /dev/null, not fd duplication), a substitution or a network tool.
  /// The network tool may start inside a quoted `sh -c '…'` payload (same boundary as
  /// `start`).
  private static let carrierPattern =
    #"\|(?!\|)|(?<![0-9&])>(?!\s*(/dev/null|&))|\$\(|`"#
    + "|" + start
    + #"(\S*/)?(curl|wget|nc|ncat|netcat|socat|scp|sftp|rsync|ssh|ftp|telnet)($|\s)"#

  /// Words that run the next word as the command: launchers, wrappers, shells (their `-c`
  /// payload is already split into words, see `commands`), `eval` and reserved words.
  private static let launchers: Set<String> = [
    "sudo", "env", "command", "exec", "nohup", "time", "xargs", "nice", "timeout", "watch",
    "stdbuf", "caffeinate", "eval", "sh", "bash", "zsh", "dash", "ksh", "fish", "if", "then",
    "else", "elif", "fi", "do", "done", "while", "until", "for", "case", "esac", "{", "}", "!"
  ]

  /// Launcher flags that take the next word as their value (`sudo -u root`, `nice -n 10`).
  private static let valueFlags: [String: Set<String>] = [
    "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"],
    "env": ["-u", "-C", "-S"],
    "xargs": ["-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a"],
    "nice": ["-n"], "timeout": ["-s", "-k"], "watch": ["-n", "-d"],
    "stdbuf": ["-i", "-o", "-e"], "caffeinate": ["-t", "-w"]
  ]

  /// A count or duration argument of a wrapper (`timeout 5`, `watch -n 1`, `timeout 2.5m`).
  private static func isCount(_ word: String) -> Bool {
    word.range(of: #"^[0-9]+(\.[0-9]+)?[smhd]?$"#, options: .regularExpression) != nil
  }

  /// Command names of every simple command in `cmd` with their arguments. The split is not
  /// quote-aware on purpose: the payload of `bash -c '…'` / `eval '…'` lands in the same
  /// segments, and stripping the shell and its flags exposes the inner command name.
  static func commands(_ cmd: String) -> [(name: String, args: [String])] {
    let separators = Set(";&|()`")
    var out: [(String, [String])] = []
    for segment in cmd.split(whereSeparator: { separators.contains($0) }) {
      var words = segment.split(whereSeparator: \.isWhitespace).map(unquote)
        .filter { !$0.isEmpty }
      var launcher: String?
      while let first = words.first {
        let base = (first as NSString).lastPathComponent
        if launchers.contains(base) {
          launcher = base
        } else if first.hasPrefix("-") {
          if let l = launcher, valueFlags[l]?.contains(first) == true, words.count > 1 {
            words.removeFirst()
          }
        } else if !(first.contains("=") || (launcher != nil && isCount(first))) {
          break
        }
        words.removeFirst()
      }
      guard let name = words.first else { continue }
      out.append(((name as NSString).lastPathComponent, Array(words.dropFirst())))
    }
    return out
  }

  /// `cmd` with `;`, `&` and `|` inside quotes replaced by `_` (a quoted URL query is one
  /// word, not a command separator).
  static func maskQuoted(_ cmd: String) -> String {
    var out = ""
    var quote: Character?
    var escaped = false
    for ch in cmd {
      if escaped {
        escaped = false
      } else if ch == "\\" && quote != "'" {
        escaped = true
      } else if let q = quote {
        if ch == q { quote = nil }
      } else if ch == "'" || ch == "\"" {
        quote = ch
      }
      out.append(quote != nil && ";&|".contains(ch) ? "_" : ch)
    }
    return out
  }

  /// Copies a file to another machine, opens a raw connection or pipes a secret somewhere;
  /// nil otherwise.
  static func exfiltration(_ cmd: String) -> String? {
    let masked = maskQuoted(cmd)
    for p in uploadPatterns where matches(p, masked) { return "dosya yükleme" }
    for (name, args) in commands(cmd) {
      let operands = args.filter { !$0.hasPrefix("-") }
      switch name {
      case "sftp":
        return "uzak sunucuya kopya"
      case "scp":
        if operands.contains(where: isRemotePath) { return "uzak sunucuya kopya" }
      case "rsync":
        if operands.contains(where: { isRemotePath($0) || $0.hasPrefix("rsync://") }) {
          return "uzak sunucuya kopya"
        }
      case "nc", "ncat", "netcat", "socat":
        return "ağ bağlantısı (\(name))"
      default:
        break
      }
    }
    if matches(secretPattern, cmd) && matches(carrierPattern, cmd) {
      return "gizli dosya aktarımı"
    }
    return nil
  }

  /// `host:path`, `user@host:path` (not a URL, not a Windows-like drive letter).
  private static func isRemotePath(_ word: String) -> Bool {
    guard let colon = word.firstIndex(of: ":"), colon != word.startIndex else { return false }
    let host = word[..<colon]
    if host.contains("/") { return false }
    let rest = word[word.index(after: colon)...]
    return !rest.hasPrefix("//")
  }

  /// Classifies the raw tool input (the command exactly as Claude sent it, before any display
  /// sanitizing or cut).
  public static func risk(toolName: String, input: JSONValue?) -> String? {
    risk(toolName: toolName, text: ToolSummary.principal(toolName: toolName, input: input))
  }

  /// Line breaks become `;`, every other whitespace (tabs, NBSP, ...) one space; the sanitizer's
  /// `\n` / `\t` / `⟨N boşluk⟩` markers are undone the same way.
  static func normalize(_ text: String) -> String {
    // Not the `\r` marker: that would turn the alias bypass `\rm` into `m`.
    var s = text.replacingOccurrences(of: "\\n", with: " ; ")
      .replacingOccurrences(of: "\\t", with: " ")
    if let re = try? NSRegularExpression(pattern: "⟨[0-9]+ boşluk⟩") {
      s = re.stringByReplacingMatches(
        in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }
    var out = ""
    for ch in s {
      if ch.isNewline {
        out += " ; "
      } else if ch.isWhitespace {
        out += " "
      } else {
        out.append(ch)
      }
    }
    return out
  }

  /// Start of a command word.
  private static let start = #"(^|[\s;&|(`'"\\])"#
  /// Optional `env` / `/usr/bin/env` launcher before an interpreter.
  private static let env = #"((\S*/)?env\s+)?"#
  /// A shell, optionally by path (`sh`, `bash`, `/bin/zsh`).
  private static let shell = #"(\S*/)?(ba|z|fi|da|k)?sh"#
  private static let patterns: [(String, String)] = [
    (start + #"(\S*/)?sudo\b"#, "sudo"),
    (#"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?"# + env + shell + #"\b"#, "curl | sh"),
    (#"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?"# + env + #"(\S*/)?(python3?|perl|ruby|node)\b"#,
      "curl | sh"),
    (start + shell + #"\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*c\s*["']?\s*\$\(\s*(curl|wget)\b"#,
      "curl | sh"),
    (start + #"(eval|source|\.)\s+["']?\$\(\s*(curl|wget)\b"#, "curl | sh"),
    (#"<\(\s*(curl|wget)\b"#, "curl | sh"),
    (#"\bch(mod|own|grp)\s+(-[a-zA-Z]*R|--recursive)"#, "chmod -R"),
    (#"\bgit\b[^;&|]*\bpush\b[^;&|]*(--force\b|--force-with-lease|\s-[a-zA-Z]*f\b|\s\+\S)"#,
      "git push --force"),
    (#">\s*/dev/(?!null\b|stdout\b|stderr\b|tty\b|fd/)"#, "> /dev/…"),
    (#"\bdd\b[^;&|]*\bof=/dev/"#, "dd of=/dev/…"),
    (#"\bmkfs(\.\w+)?\b"#, "mkfs"),
    (#"\bgit\b[^;&|]*\breset\s+--hard\b"#, "git reset --hard")
  ]

  private static func matches(_ pattern: String, _ s: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
  }

  /// A word as the shell would see it for a command name: `\rm`, `'rm'`, `"rm"` -> `rm`.
  static func unquote(_ word: Substring) -> String {
    var w = word
    while let f = w.first, f == "\\" || f == "'" || f == "\"" { w = w.dropFirst() }
    while let l = w.last, l == "'" || l == "\"" { w = w.dropLast() }
    return String(w)
  }

  /// `rm` with both a recursive and a force flag, in any spelling (`-rf`, `-fR`, `-r -f`,
  /// `--recursive --force`, `\rm`, `"rm"`, `/bin/rm`).
  static func hasRecursiveForceRemove(_ cmd: String) -> Bool {
    let separators = Set(";&|()`")
    let words = cmd.split { $0.isWhitespace || separators.contains($0) }.map(unquote)
      .filter { !$0.isEmpty }
    for (i, w) in words.enumerated() where w == "rm" || w.hasSuffix("/rm") {
      var recursive = false
      var force = false
      for flag in words.dropFirst(i + 1) {
        guard flag.hasPrefix("-") else { break }
        if flag == "--recursive" { recursive = true }
        if flag == "--force" { force = true }
        if !flag.hasPrefix("--") {
          recursive = recursive || flag.contains("r") || flag.contains("R")
          force = force || flag.contains("f")
        }
      }
      if recursive && force { return true }
    }
    return false
  }
}

// MARK: - Text

public enum TextShortener {
  /// Keeps the head and the tail, joined by "…", when `s` is longer than `limit` characters
  /// (paths stay recognisable from both ends).
  public static func middle(_ s: String, limit: Int) -> String {
    guard s.count > limit, limit > 3 else { return s }
    let keep = limit - 1
    let head = (keep + 1) / 2
    let tail = keep - head
    return String(s.prefix(head)) + "…" + String(s.suffix(tail))
  }

  /// One line for the peek: newlines folded, head…tail when long.
  public static func oneLine(_ s: String, limit: Int) -> String {
    let flat = s.replacingOccurrences(of: "\\n", with: " ⏎ ")
      .split(whereSeparator: { $0 == " " }).joined(separator: " ")
    return middle(flat, limit: limit)
  }
}

extension ToolSummary {
  /// Short "what is it doing" text for a session row (file name, command head, host).
  public static func target(toolName: String, input: JSONValue?) -> String? {
    let full = fullText(toolName: toolName, input: input)
    guard !full.isEmpty else { return nil }
    switch toolName {
    case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
      let name = (full as NSString).lastPathComponent
      return name.isEmpty ? nil : TextShortener.middle(name, limit: 48)
    case "WebFetch":
      return URL(string: full)?.host ?? TextShortener.middle(full, limit: 48)
    case "AskUserQuestion":
      let q = AskedQuestion.parse(input)?.first?.question
      return q.map { "Soru: " + TextShortener.oneLine($0, limit: 54) } ?? "Soru soruyor"
    default:
      return TextShortener.oneLine(full, limit: 60)
    }
  }
}

// MARK: - Peek planner

public enum PeekKind: String, Sendable {
  /// A new permission card (the user's setting, default 15 s; hover keeps it).
  case permission
  /// Question / plan approval / waiting for input (4 s).
  case attention
  /// Done / error, coalesced (2.5 s).
  case finished
  /// A module note (meeting soon, timer done, charging): the lowest priority, never over a
  /// Claude peek, and any Claude peek replaces it at once.
  case module

  var priority: Int {
    switch self {
    case .permission: return 3
    case .attention: return 2
    case .finished: return 1
    case .module: return 0
    }
  }
}

/// What a module peek shows: a dot-matrix value with a unit, a title and a subtitle.
public struct ModuleNote: Sendable, Equatable {
  public enum Source: String, Sendable {
    case calendar
    case timer
    case battery
    case shelf
    case weather
    case usage
    case claude
  }

  public var source: Source
  /// Same id = same note (a repeated reminder is not queued twice).
  public var id: String
  public var title: String
  public var subtitle: String?
  public var digits: String?
  public var unit: String?
  /// 0…1 for a level bar (battery).
  public var level: Double?
  /// A link the peek offers as a button (a meeting's video link: "Katıl").
  public var link: URL?
  /// A note that waited behind a Claude peek is dropped after this (a meeting that started).
  public var validUntil: Date

  public init(
    source: Source, id: String, title: String, subtitle: String? = nil, digits: String? = nil,
    unit: String? = nil, level: Double? = nil, link: URL? = nil, validUntil: Date
  ) {
    self.link = link
    self.source = source
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.digits = digits
    self.unit = unit
    self.level = level
    self.validUntil = validUntil
  }
}

public struct PeekItem: Sendable, Equatable {
  public var kind: PeekKind
  /// Sessions in arrival order (no duplicates).
  public var sessionIDs: [String]
  public var errorIDs: Set<String>
  /// Card for a permission peek.
  public var cardID: String?
  public var startedAt: Date
  public var until: Date
  /// Payload of a module peek.
  public var module: ModuleNote? = nil
}

/// Decides what the peek shows. Pure state machine driven by the store's attention effects.
public struct PeekPlanner: Sendable {
  public static let coalesceWindow: TimeInterval = 1.5
  public static let finishedDuration: TimeInterval = 2.5
  public static let attentionDuration: TimeInterval = 4
  /// Default of a bare `PeekPlanner()`; the app passes the user's setting.
  public static let permissionDuration: TimeInterval = 6
  public static let moduleDuration: TimeInterval = 4

  public private(set) var current: PeekItem?
  /// A module note that arrived while a Claude peek was up: shown once that one is gone.
  public private(set) var pendingModule: ModuleNote?
  /// How long an unanswered permission peek stays; nil keeps it until the card is answered.
  public var permissionHold: TimeInterval?

  public init(permissionHold: TimeInterval? = PeekPlanner.permissionDuration) {
    self.permissionHold = permissionHold
  }

  public static func kind(for attention: String) -> PeekKind {
    switch attention {
    case "permission": return .permission
    case "done", "error": return .finished
    default: return .attention
    }
  }

  /// Seconds the peek stays; nil means until it is answered (no expiry).
  func duration(_ kind: PeekKind) -> TimeInterval? {
    switch kind {
    case .permission: return permissionHold
    case .attention: return Self.attentionDuration
    case .finished: return Self.finishedDuration
    case .module: return Self.moduleDuration
    }
  }

  /// Feeds a module note. Shown at once unless a Claude peek is up; then it waits (one slot,
  /// the newest wins) and shows when that peek is gone. Returns true when the peek changed.
  @discardableResult
  public mutating func receive(module note: ModuleNote, at t: Date) -> Bool {
    if let cur = current, cur.until > t, cur.kind != .module {
      pendingModule = note
      return false
    }
    if current?.module?.id == note.id { return false }
    present(note, at: t)
    return true
  }

  private mutating func present(_ note: ModuleNote, at t: Date) {
    current = PeekItem(
      kind: .module, sessionIDs: [], errorIDs: [], cardID: nil, startedAt: t,
      until: t.addingTimeInterval(Self.moduleDuration), module: note)
  }

  /// Feeds one attention effect. Returns true when the visible peek changed.
  @discardableResult
  public mutating func receive(
    attention: String, sessionID: String, cardID: String? = nil, at t: Date
  ) -> Bool {
    let kind = Self.kind(for: attention)
    if let cur = current, cur.until > t {
      if cur.kind.priority > kind.priority { return false }
      if cur.kind == .finished, kind == .finished,
        t.timeIntervalSince(cur.startedAt) <= Self.coalesceWindow
      {
        var merged = cur
        if !merged.sessionIDs.contains(sessionID) { merged.sessionIDs.append(sessionID) }
        if attention == "error" { merged.errorIDs.insert(sessionID) }
        merged.until = t.addingTimeInterval(Self.finishedDuration)
        current = merged
        return true
      }
    }
    current = PeekItem(
      kind: kind, sessionIDs: [sessionID],
      errorIDs: attention == "error" ? [sessionID] : [], cardID: cardID, startedAt: t,
      until: duration(kind).map { t.addingTimeInterval($0) } ?? .distantFuture)
    return true
  }

  /// Shows the permission peek for `cardID` again (a global shortcut pressed while nothing was
  /// shown, or the next card after a decision), for the usual permission time.
  public mutating func show(cardID: String, sessionID: String, at t: Date) {
    current = PeekItem(
      kind: .permission, sessionIDs: [sessionID], errorIDs: [], cardID: cardID, startedAt: t,
      until: permissionHold.map { t.addingTimeInterval($0) } ?? .distantFuture)
  }

  /// Keeps the peek up at least until `t + seconds` (pointer over it).
  public mutating func hold(at t: Date, seconds: TimeInterval = 1.5) {
    guard var cur = current else { return }
    cur.until = max(cur.until, t.addingTimeInterval(seconds))
    current = cur
  }

  /// Drops the peek once its time is over, then shows a waiting module note (if still
  /// valid). Returns true when the peek changed.
  @discardableResult
  public mutating func expire(at t: Date) -> Bool {
    var changed = false
    if let cur = current, cur.until <= t {
      current = nil
      changed = true
    }
    if current == nil, let note = pendingModule {
      pendingModule = nil
      if note.validUntil > t {
        present(note, at: t)
        changed = true
      }
    }
    return changed
  }

  /// Hides the peek. A waiting module note stays (it shows on the next `expire`).
  public mutating func clear() {
    current = nil
  }

  /// Panel opened: the user sees everything there, nothing waits.
  public mutating func clearAll() {
    current = nil
    pendingModule = nil
  }

  /// "api bitti", "api hata verdi", "3 oturum bitti", "3 oturum bitti · 1 hata".
  public static func finishedTitle(names: [String], errors: Int) -> String {
    if names.count == 1 {
      return errors > 0 ? "\(names[0]) hata verdi" : "\(names[0]) bitti"
    }
    let done = names.count - errors
    if done == 0 { return "\(names.count) oturumda hata" }
    return errors > 0 ? "\(done) oturum bitti · \(errors) hata" : "\(names.count) oturum bitti"
  }
}

// MARK: - Hover intent

/// Expands only after the pointer dwells in the top strip over the notch and ignores fast
/// horizontal sweeps along the menu bar (vertical approaches are never rejected).
public struct HoverIntent: Sendable {
  /// Short: the notch already answers the pointer at once (it swells), so the dwell only has
  /// to filter a pointer passing by, not stand in for feedback.
  public static let dwell: TimeInterval = 0.15
  /// Horizontal speed (pt/s) above which the pointer is sweeping past, not aiming.
  public static let maxSpeed: CGFloat = 600
  /// Height of the trigger strip under the top edge of the screen.
  public static let stripHeight: CGFloat = 10

  public private(set) var dwellStart: Date?
  /// The last update was inside the strip but too fast: the caller must re-check after
  /// `dwell` even if no further mouse event arrives (a pointer that stops sends none).
  public private(set) var recheckPending = false
  private var last: (p: CGPoint, t: Date)?

  public init() {}

  /// `zone` is the x-range of notch + ears, `top` the screen's top edge (Cocoa y-up).
  /// Returns true once the dwell completed.
  public mutating func update(point p: CGPoint, at t: Date, minX: CGFloat, maxX: CGFloat,
    top: CGFloat) -> Bool
  {
    update(point: p, at: t, minX: minX, maxX: maxX, top: top, bottom: top - Self.stripHeight)
  }

  /// Same, with the zone's lower edge given (the notch plus the status line under it).
  public mutating func update(point p: CGPoint, at t: Date, minX: CGFloat, maxX: CGFloat,
    top: CGFloat, bottom: CGFloat) -> Bool
  {
    var speed: CGFloat = 0
    var resting = false
    if let last, t > last.t {
      let dt = CGFloat(t.timeIntervalSince(last.t))
      if dt < 0.15 { speed = abs(p.x - last.p.x) / dt }
      resting = last.p == p
    }
    let previous = last
    last = (p, t)
    recheckPending = false
    let inside = p.x >= minX && p.x <= maxX && p.y >= min(bottom, top - Self.stripHeight)
      && p.y <= top + 1
    guard inside else {
      dwellStart = nil
      return false
    }
    guard speed <= Self.maxSpeed else {
      dwellStart = nil
      recheckPending = true
      return false
    }
    // A pointer that has not moved since the previous sample has been resting since then.
    let start = dwellStart ?? (resting ? previous?.t ?? t : t)
    dwellStart = start
    return t.timeIntervalSince(start) >= Self.dwell
  }

  public mutating func reset() {
    dwellStart = nil
    recheckPending = false
    last = nil
  }
}

// MARK: - Status line

/// Color role of one status-line segment (collapsed notch).
public enum LineState: String, Sendable {
  /// Running and not blocked on the user: Claude orange with a shimmer.
  case working
  /// Card pending, question, plan approval or input request: amber, breathing.
  case needs
  /// Finished and not seen yet: green.
  case done
  /// Failed and not seen yet: red.
  case error
  /// Idle, quiet or already seen: faint white.
  case idle

  /// Which states win a place when there are more sessions than segments.
  var priority: Int {
    switch self {
    case .needs: return 0
    case .error: return 1
    case .done: return 2
    case .working: return 3
    case .idle: return 4
    }
  }
}

public struct LineSegment: Sendable, Equatable, Identifiable {
  public var sessionID: String
  public var state: LineState
  public var id: String { sessionID }

  public init(sessionID: String, state: LineState) {
    self.sessionID = sessionID
    self.state = state
  }
}

extension SessionStore {
  /// At most this many segments; more sessions keep the most urgent ones.
  public static let maxLineSegments = 6

  public func lineState(of s: Session) -> LineState {
    if hasPending(for: s.id) { return .needs }
    switch s.status {
    case .waitingInput, .question, .planApproval: return .needs
    case .error: return s.unseen ? .error : .idle
    case .done: return s.unseen ? .done : .idle
    case .working: return .working
    case .idle, .quiet: return .idle
    }
  }

  /// One segment per session in creation order (a segment never moves when its session changes
  /// state); with more than `maxLineSegments` sessions the most urgent ones are shown.
  public var statusLine: [LineSegment] {
    let byAge = sessions.values.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    var picked = byAge.map { LineSegment(sessionID: $0.id, state: lineState(of: $0)) }
    if picked.count > Self.maxLineSegments {
      let rank = Dictionary(uniqueKeysWithValues: picked.enumerated().map { ($1.sessionID, $0) })
      let key = { (x: LineSegment) in (x.state.priority, rank[x.sessionID] ?? 0) }
      picked = Array(picked.sorted { key($0) < key($1) }.prefix(Self.maxLineSegments))
      picked.sort { (rank[$0.sessionID] ?? 0) < (rank[$1.sessionID] ?? 0) }
    }
    return picked
  }
}

// MARK: - Display order

public enum SessionGroup: Int, Sendable, Comparable {
  case needsYou = 0, done, working, quiet, idle

  public static func < (a: SessionGroup, b: SessionGroup) -> Bool { a.rawValue < b.rawValue }
}

extension SessionStore {
  public func group(of s: Session) -> SessionGroup {
    if needsAttention(s) { return .needsYou }
    switch s.status {
    case .done: return .done
    case .working: return .working
    case .quiet: return .quiet
    default: return .idle
    }
  }

  /// needs-you, done, working, quiet, idle; creation order inside a group.
  public var displayOrder: [Session] {
    sessions.values.sorted {
      let a = group(of: $0)
      let b = group(of: $1)
      if a != b { return a < b }
      return ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
    }
  }

  /// `live` reordered to follow `frozen` (ids captured on hover-enter); sessions that are new
  /// since then come last in their live order, removed ones disappear.
  public static func applyFrozen(_ frozen: [String], to live: [Session]) -> [Session] {
    let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let known = Set(frozen)
    return frozen.compactMap { byID[$0] } + live.filter { !known.contains($0.id) }
  }
}

extension SessionStore {
  /// The card slot moved from session `old` to session `new` while the order is frozen: the two
  /// swap places, so the row that leaves the slot takes the place of the row that entered it
  /// and no other row slides under the pointer.
  public static func swapFrozen(_ frozen: [String], _ old: String, _ new: String) -> [String] {
    guard old != new, let i = frozen.firstIndex(of: old), let j = frozen.firstIndex(of: new)
    else { return frozen }
    var out = frozen
    out.swapAt(i, j)
    return out
  }
}

// MARK: - Decision keys

/// Keyboard decisions (⌘⏎, ⌘⇧⏎, ⌘⌫) need a fresh key press: auto-repeat never decides, and
/// after a decision the next one waits for the Return / Delete key to come up.
public struct DecisionKeyGate: Sendable {
  public static let returnKeys: Set<UInt16> = [36, 76]
  public static let deleteKeys: Set<UInt16> = [51, 117]
  /// Keys whose auto-repeat is dropped altogether (Return, Delete, Space).
  public static let noRepeatKeys: Set<UInt16> = returnKeys.union(deleteKeys).union([49])

  /// A decision was taken with this key and it has not come up yet.
  public private(set) var latchedKey: UInt16?

  public init() {}

  public static func isDecision(keyCode: UInt16, command: Bool) -> Bool {
    command && (returnKeys.contains(keyCode) || deleteKeys.contains(keyCode))
  }

  /// Whether a key-down may act. Decision keys latch until their key-up.
  public mutating func keyDown(keyCode: UInt16, command: Bool, isRepeat: Bool) -> Bool {
    if isRepeat && Self.noRepeatKeys.contains(keyCode) { return false }
    guard Self.isDecision(keyCode: keyCode, command: command) else { return true }
    if latchedKey != nil { return false }
    latchedKey = keyCode
    return true
  }

  public mutating func keyUp(keyCode: UInt16) {
    guard let latched = latchedKey else { return }
    let group = Self.returnKeys.contains(latched) ? Self.returnKeys : Self.deleteKeys
    if group.contains(keyCode) { latchedKey = nil }
  }

  /// Modifier keys changed: once ⌘ is up no decision chord can still be held, so a key-up that
  /// AppKit swallowed while ⌘ was down cannot leave the gate latched.
  public mutating func modifiersChanged(command: Bool) {
    if !command { latchedKey = nil }
  }

  /// The panel lost / gained the keyboard: a key-up may have been missed.
  public mutating func reset() {
    latchedKey = nil
  }
}

/// One short Turkish time format for session rows: "şimdi", "45 sn önce", "5 dk önce",
/// "2 sa önce", "3 gün önce". Only the largest unit is shown so rows stay scannable.
public enum RelativeTime {
  public static func short(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 10 { return "şimdi" }
    if s < 60 { return "\(s) sn önce" }
    if s < 3600 { return "\(s / 60) dk önce" }
    if s < 86_400 { return "\(s / 3600) sa önce" }
    return "\(s / 86_400) gün önce"
  }
}

/// Elapsed time for the dot-matrix gauge: "mm:ss" under an hour, then whole hours ("3" + "sa")
/// or days ("2" + "gün"). The unit is drawn as small text beside the dots.
public enum DotClock {
  public struct Reading: Equatable, Sendable {
    public let digits: String
    public let unit: String?
  }

  public static func reading(_ seconds: TimeInterval) -> Reading {
    let s = max(0, Int(seconds))
    if s < 3600 {
      return Reading(digits: String(format: "%02d:%02d", s / 60, s % 60), unit: nil)
    }
    if s < 86_400 { return Reading(digits: "\(s / 3600)", unit: "sa") }
    return Reading(digits: "\(s / 86_400)", unit: "gün")
  }

  /// A countdown: "mm:ss", or "h:mm:ss" from an hour up (timers up to 180 min).
  public static func countdown(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
  }

  /// Whole minutes at least ("12" + "dk"), for times that need no seconds (idle rows).
  public static func coarse(_ seconds: TimeInterval) -> Reading {
    let s = max(0, Int(seconds))
    if s < 3600 { return Reading(digits: "\(max(1, s / 60))", unit: "dk") }
    return reading(seconds)
  }
}

/// The rhythm of a turn in a fixed amount of memory: tool calls counted into 28 time slots.
/// Slots start 5 s wide; when the turn outgrows the strip, neighbouring slots merge pairwise
/// and the width doubles, so a turn of any length always fits (an 18-minute turn ends up at
/// 40 s per slot). Distinct subagents seen in the turn are counted too.
public struct ActivityRhythm: Sendable, Equatable {
  public static let slots = 28

  public let start: Date
  public private(set) var slotWidth: TimeInterval
  public private(set) var counts: [Int]
  public private(set) var total = 0
  public private(set) var agentIDs: Set<String> = []

  public init(start: Date, slotWidth: TimeInterval = 5) {
    self.start = start
    self.slotWidth = slotWidth
    counts = Array(repeating: 0, count: Self.slots)
  }

  public mutating func record(at t: Date, agentID: String? = nil) {
    fit(t)
    counts[slot(t)] += 1
    total += 1
    if let agentID { agentIDs.insert(agentID) }
  }

  /// Slots as of `now` (the strip grows to the right as time passes, even without events) and
  /// how many of them the turn has reached.
  public func reading(at now: Date) -> (counts: [Int], used: Int) {
    var copy = self
    copy.fit(now)
    return (copy.counts, copy.slot(now) + 1)
  }

  private func slot(_ t: Date) -> Int {
    max(0, min(Self.slots - 1, Int(t.timeIntervalSince(start) / slotWidth)))
  }

  private mutating func fit(_ t: Date) {
    while t.timeIntervalSince(start) / slotWidth >= Double(Self.slots) {
      let half = Self.slots / 2
      for i in 0..<half { counts[i] = counts[2 * i] + counts[2 * i + 1] }
      for i in half..<Self.slots { counts[i] = 0 }
      slotWidth *= 2
    }
  }
}
