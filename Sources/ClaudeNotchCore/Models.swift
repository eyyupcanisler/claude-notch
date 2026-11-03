import Foundation

public enum SessionStatus: Sendable, Equatable {
  case idle
  case working(tool: String?)
  /// Was working but no hook event arrived for `SessionStore.quietAfter` (stuck or long run).
  case quiet
  case done(String)
  case waitingInput(String)
  /// AskUserQuestion: first question text and its option labels.
  case question(text: String, options: [String])
  /// ExitPlanMode: the plan's first line, if any.
  case planApproval(String?)
  case error(String)

  public var label: String {
    switch self {
    case .idle: return "Boşta"
    case .working: return "Çalışıyor"
    case .quiet: return "Sessiz"
    case .done: return "Bitti"
    case .waitingInput: return "Girdi bekliyor"
    case .question: return "Soru soruyor"
    case .planApproval: return "Plan onayı bekliyor"
    case .error: return "Hata"
    }
  }

  /// The status itself asks for the user (amber). `done` is not attention (see `Session.unseen`);
  /// an `error` only counts while unseen (`Session.needsAttention`).
  public var needsAttention: Bool {
    switch self {
    case .waitingInput, .question, .planApproval, .error: return true
    case .idle, .working, .quiet, .done: return false
    }
  }

  /// Claude is blocked on an interactive dialog in the terminal (question / plan approval).
  public var isBlocking: Bool {
    switch self {
    case .question, .planApproval: return true
    default: return false
    }
  }

  public var isWorking: Bool {
    if case .working = self { return true }
    return false
  }

  public var kind: String {
    switch self {
    case .idle: return "idle"
    case .working: return "working"
    case .quiet: return "quiet"
    case .done: return "done"
    case .waitingInput: return "waiting"
    case .question: return "question"
    case .planApproval: return "plan"
    case .error: return "error"
    }
  }

  public var detail: String? {
    switch self {
    case .idle, .quiet: return nil
    case .working(let t): return t
    case .done(let m), .waitingInput(let m), .error(let m): return m
    case .question(let text, _): return text
    case .planApproval(let m): return m
    }
  }
}

/// A subagent / teammate seen in the session's hook events (`agent_id`).
public struct AgentActivity: Sendable, Equatable, Identifiable {
  public var id: String
  /// `agent_type`, e.g. "Explore" (nil when the payload has none).
  public var type: String?
  public var lastTool: String?
  public var lastSeen: Date

  public init(id: String, type: String?, lastTool: String?, lastSeen: Date) {
    self.id = id
    self.type = type
    self.lastTool = lastTool
    self.lastSeen = lastSeen
  }
}

public struct Session: Sendable, Identifiable, Equatable {
  public var id: String
  public var project: String
  public var cwd: String
  public var termProgram: String?
  /// Controlling terminal of the claude process, e.g. "/dev/ttys012" (validated).
  public var tty: String?
  /// pid of the claude process that owns `tty`.
  public var pid: Int32?
  /// Git branch at SessionStart / last prompt (nil: unknown, detached or not a repo).
  public var branch: String?
  /// Found by the process scan (no hook event yet): an idle placeholder until hooks arrive.
  public var isDiscovered: Bool
  /// Title of the session's terminal tab (Ghostty, sanitized), when Automation allows reading it.
  public var tabTitle: String?
  public var status: SessionStatus
  /// `done` / `error` the user has not looked at yet (row click, focus, terminal focused).
  public var unseen: Bool
  /// Subagents active in this session, keyed by agent id.
  public var agents: [String: AgentActivity]
  public var startedAt: Date
  /// Time of the last hook event.
  public var lastUpdate: Date
  /// When `status.kind` last changed.
  public var statusSince: Date
  /// Last UserPromptSubmit (start of the current / last turn).
  public var turnStartedAt: Date?
  /// Target of the latest tool call ("Views.swift", "npm test"), cleared at turn boundaries.
  public var activity: String?
  /// Tool calls in the current / last turn (subagents included).
  public var turnToolCount: Int
  /// When those calls happened (the row's rhythm strip); nil before the first turn.
  public var rhythm: ActivityRhythm?

  public init(
    id: String, project: String, cwd: String, termProgram: String?, tty: String? = nil,
    pid: Int32? = nil, branch: String? = nil, status: SessionStatus, isDiscovered: Bool = false,
    tabTitle: String? = nil, unseen: Bool = false,
    agents: [String: AgentActivity] = [:], startedAt: Date, lastUpdate: Date,
    statusSince: Date? = nil, turnStartedAt: Date? = nil, activity: String? = nil,
    turnToolCount: Int = 0, rhythm: ActivityRhythm? = nil
  ) {
    self.id = id
    self.project = project
    self.cwd = cwd
    self.termProgram = termProgram
    self.tty = tty
    self.pid = pid
    self.branch = branch
    self.isDiscovered = isDiscovered
    self.tabTitle = tabTitle
    self.status = status
    self.unseen = unseen
    self.agents = agents
    self.startedAt = startedAt
    self.lastUpdate = lastUpdate
    self.statusSince = statusSince ?? startedAt
    self.turnStartedAt = turnStartedAt
    self.activity = activity
    self.turnToolCount = turnToolCount
    self.rhythm = rhythm
  }

  /// "s012" for "/dev/ttys012".
  public var ttySuffix: String? {
    guard let tty, tty.hasPrefix("/dev/tty") else { return nil }
    return String(tty.dropFirst("/dev/tty".count))
  }

  public var isDoneUnseen: Bool {
    if case .done = status { return unseen }
    return false
  }

  /// Amber attention from the status alone (cards are counted by the store).
  public var needsAttention: Bool {
    if case .error = status { return unseen }
    return status.needsAttention
  }

  /// Active subagents, oldest first.
  public var activeAgents: [AgentActivity] {
    agents.values.sorted { ($0.lastSeen, $0.id) < ($1.lastSeen, $1.id) }
  }
}

public struct PendingPermission: Sendable, Identifiable {
  public let id: String
  public let sessionID: String
  public let project: String
  public let toolName: String
  public let toolInput: JSONValue?
  /// Principal text, sanitized and cut at `ToolSummary.maxLength`.
  public let summary: String
  /// Principal text, sanitized, without the 400 character cut.
  public let fullText: String
  /// Written content / edit before-after, if the tool has any.
  public let extra: String?
  /// Subagent that asked, `nil` for the main agent.
  public let agentID: String?
  public let suggestions: [JSONValue]
  public let createdAt: Date
  public let key: String
  /// Risk reason from the RAW tool input (not the sanitized / cut display text); non-nil means
  /// allowing needs hold-to-allow or ⌘⏎.
  public let risk: String?
  /// Replies to the held connection. `nil` means an empty 200 (no decision).
  public let reply: PermissionReply

  /// Text for the collapsed card (head + tail when long).
  public var collapsedText: String { ToolSummary.collapsed(fullText) }

  /// The collapsed card hides part of the request: allowing needs the full view first. Written
  /// content / an edit's before-after (`extra`) is never on the collapsed card, so a tool with
  /// `extra` always needs it (the full view shows `fullText` + `extra`).
  public var needsExpansion: Bool { collapsedText != fullText || extra != nil }

  /// There is more to see than the collapsed card shows.
  public var hasMore: Bool { needsExpansion || extra != nil }

  /// Display columns of the peek's one-line text (monospaced 11.5 pt in a 392 pt line).
  public static let peekLimit = 50

  /// One line for the peek (head…tail when long).
  public var peekText: String {
    TextShortener.oneLine(fullText.isEmpty ? toolName : fullText, limit: Self.peekLimit)
  }

  /// The peek's one line shows the whole request (nothing folded, cut or elided, no written
  /// content / edit behind it), so allowing from the peek is allowed. Otherwise the peek can
  /// only open the panel.
  public var fitsPeek: Bool {
    extra == nil && !fullText.isEmpty && peekText == fullText
      && ToolSummary.displayWidth(fullText) <= Self.peekLimit
  }

  /// Rule text for the "Her zaman" section (whole and sanitized), if a suggestion exists.
  public var alwaysDescription: String? {
    let pick = suggestions.first { $0["type"]?.stringValue == "addRules" } ?? suggestions.first
    return pick.map { ToolSummary.describeSuggestion($0) }
  }
}

/// One-shot reply channel for a held permission request.
public final class PermissionReply: @unchecked Sendable {
  private let lock = NSLock()
  private var sent = false
  private let handler: @Sendable (Data?) -> Void

  public init(_ handler: @escaping @Sendable (Data?) -> Void) {
    self.handler = handler
  }

  @discardableResult
  public func send(_ body: Data?) -> Bool {
    lock.lock()
    if sent {
      lock.unlock()
      return false
    }
    sent = true
    lock.unlock()
    handler(body)
    return true
  }
}

public enum StoreEffect: Sendable, Equatable {
  case sound(String)
  case autoExpand(seconds: Double)
  /// A session entered a state worth a peek. `kind` is a `SessionStatus.kind` ("done", "error",
  /// "waiting", "question", "plan") or "permission" for a new card.
  case attention(sessionID: String, kind: String)
}
