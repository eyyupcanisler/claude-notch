import Foundation
import Observation

// MARK: - Model API (for the UI)
//
// SessionStore is the single source of truth, @MainActor + @Observable. The UI reads:
//
// Sessions
//   sessions[id] / orderedSessions   Stable order: needs-you (card, question, plan, waiting,
//                                    unseen error) > done-unseen > working/quiet > rest; inside
//                                    a group by start time. sortedSessions = most recent first.
//   Session.status                   idle | working(tool) | quiet ("Sessiz", 10 min without
//                                    events) | done(msg) | waitingInput(msg) |
//                                    question(text, options) | planApproval(summary) | error(msg).
//                                    .label is the Turkish label, .kind a stable string.
//   Session.unseen / isDoneUnseen    done (or error) the user has not looked at yet.
//   Session.tty / pid / branch       Identity from the hook (validated). ttySuffix = "s012".
//   Session.activeAgents             Subagents seen recently (agent_id / agent_type / tool).
//   Session.turnStartedAt / statusSince   For elapsed-time labels.
//   disambiguator(for:)              Branch, else tty suffix, only when the project name is
//                                    shared with another session. displayName(for:) joins both.
//
// Attention
//   needsAttention(_:)               Card pending, or question / plan / waiting / unseen error.
//   attentionCount                   Distinct sessions needing the user (amber badge).
//   doneUnseenSessions / doneUnseenCount   Separate green signal, not in the amber badge.
//   anyWorking, workingCount, anyWaiting, anyError, anyDone (= any done-unseen).
//   activeWorkingCount / anyActiveWorking   Working and not blocked on a card / question
//                                    (what the ears, chips and header spark show).
//
// Permission queue (oldest first, every card reachable)
//   queue / pending                  All cards, oldest first.
//   cards(for:) / firstCard(for:)    Cards of one session. queuePosition(of:) -> (index, total).
//   isArmed(_:) / armedAt(_:)        Click guard (arm delay after a new card / a removal).
//   removalArmDelay                  Arm delay after a removal; the app sets it above the
//                                    system double-click interval.
//   decide(id:decision:)             Replies to the held hook. The UI must check isArmed and,
//                                    for allow / always, needsExpansion + the full-text view.
//   denyAll(sessionID:)              Denies every card of a session at once.
//   PendingPermission.risk           Risk reason from the raw command (hold-to-allow / ⌘⏎).
//   PendingPermission.fitsPeek       The peek's one line is the whole request.
//
// Actions
//   markSeen(sessionID:)             Row click / focus: clears unseen, waiting -> idle.
//   markSeen(tty:)                   The session's terminal became the focused one.
//   sweep()                          Every `livenessInterval` while sessions exist: drops dead
//                                    claude processes (and their cards), marks quiet sessions.
//   processExited(sessionID:pid:)    Exit watch (probe.watchExit) fired: removes the row at once.
//
// Effects (onEffect): .sound(name), .autoExpand(seconds), .attention(sessionID:kind:).

@MainActor
@Observable
public final class SessionStore {
  public internal(set) var sessions: [String: Session] = [:]
  /// Pending permission cards, oldest first.
  public private(set) var pending: [PendingPermission] = []

  @ObservationIgnored public var onEffect: (@MainActor (StoreEffect) -> Void)?
  @ObservationIgnored public var now: @MainActor () -> Date
  @ObservationIgnored public var probe: ProcessProbe
  @ObservationIgnored public private(set) var lastRemovalAt = Date.distantPast
  @ObservationIgnored private var recentPre: [String: [(key: String, at: Date)]] = [:]
  /// Exit watches of the sessions' claude processes (session id -> pid + watch).
  @ObservationIgnored private var exitWatches: [String: (pid: Int32, watch: ExitWatch)] = [:]
  /// pids whose session just ended (SessionEnd), with the time: not re-discovered for a moment.
  @ObservationIgnored var endedPIDs: [Int32: Date] = [:]
  /// Buttons stay disabled this long after any card disappeared. The app raises it above the
  /// system double-click interval, so the second click of a double-click never lands on the
  /// card that slid into place (see `removalArmDelay(doubleClickInterval:)`).
  @ObservationIgnored public var removalArmDelay: TimeInterval = SessionStore.armDelayAfterRemoval

  /// A PreToolUse with a different call key only flushes a card older than this.
  public static let mismatchGrace: TimeInterval = 1.5
  /// Buttons of a new card stay disabled this long (a click aimed elsewhere must not land).
  public static let armDelayNew: TimeInterval = 0.8
  /// Minimum time the buttons stay disabled after any card disappeared (the list may shift).
  public static let armDelayAfterRemoval: TimeInterval = 0.45

  /// Arm delay after a removal for a system double-click interval: a double-click whose first
  /// click decided a card must not decide the next one with its second click.
  public static func removalArmDelay(doubleClickInterval: TimeInterval) -> TimeInterval {
    max(armDelayAfterRemoval, doubleClickInterval + 0.1)
  }
  /// Sessions without a pid (old hook) are dropped after this long without events.
  public static let pruneAge: TimeInterval = 2 * 60 * 60
  public static let autoExpandSeconds: Double = 4
  /// Working with no hook event for this long -> `.quiet`.
  public static let quietAfter: TimeInterval = 10 * 60
  /// How often the app should call `sweep()` while sessions exist.
  public static let livenessInterval: TimeInterval = 10
  /// A subagent without events for this long is no longer listed as active.
  public static let agentStaleAfter: TimeInterval = 5 * 60

  public init(now: @escaping @MainActor () -> Date = { Date() }, probe: ProcessProbe = .system) {
    self.now = now
    self.probe = probe
  }

  // MARK: - Derived: sessions

  /// Most recently updated first.
  public var sortedSessions: [Session] {
    sessions.values.sorted { ($0.lastUpdate, $0.id) > ($1.lastUpdate, $1.id) }
  }

  /// Stable display order (see the API comment at the top).
  public var orderedSessions: [Session] {
    sessions.values.sorted {
      let a = rank($0)
      let b = rank($1)
      if a != b { return a < b }
      return ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
    }
  }

  private func rank(_ s: Session) -> Int {
    if needsAttention(s) { return 0 }
    if s.isDoneUnseen { return 1 }
    if s.status.isWorking || s.status == .quiet { return 2 }
    return 3
  }

  /// Short label telling apart sessions with the same project name; nil when the name is unique.
  public func disambiguator(for s: Session) -> String? {
    let peers = sessions.values.filter { $0.project == s.project && $0.id != s.id }
    guard !peers.isEmpty else { return nil }
    // The terminal tab's title (Ghostty) says the most, when it tells the two apart.
    if let title = s.tabTitle, !peers.contains(where: { $0.tabTitle == title }) { return title }
    if let branch = s.branch, !peers.contains(where: { $0.branch == branch }) { return branch }
    if let suffix = s.ttySuffix { return s.branch.map { "\($0) · \(suffix)" } ?? suffix }
    return String(s.id.prefix(6))
  }

  /// "project" or "project · disambiguator".
  public func displayName(for s: Session) -> String {
    disambiguator(for: s).map { "\(s.project) · \($0)" } ?? s.project
  }

  /// Secondary text of a row: the terminal tab title (when known), plus the disambiguator when
  /// the title alone does not tell same-project sessions apart.
  public func secondaryText(for s: Session) -> String? {
    let d = disambiguator(for: s)
    guard let title = s.tabTitle else { return d }
    guard let d, d != title else { return title }
    return "\(title) · \(d)"
  }

  /// Ghostty tab titles by tty (already sanitized, see `TabTitle.clean`): sets each session's
  /// title, clears it for sessions whose tty is not listed. Writes only what changed.
  public func applyTabTitles(_ titles: [String: String]) {
    for (id, s) in sessions {
      let title = s.tty.flatMap { titles[$0] }
      if s.tabTitle != title { sessions[id]?.tabTitle = title }
    }
  }

  // MARK: - Derived: attention

  public func hasPending(for sessionID: String) -> Bool {
    pending.contains { $0.sessionID == sessionID }
  }

  /// Card pending, or the status asks for the user.
  public func needsAttention(_ s: Session) -> Bool {
    hasPending(for: s.id) || s.needsAttention
  }

  /// Number of distinct sessions needing the user's attention (done-unseen excluded).
  public var attentionCount: Int {
    var ids = Set(pending.map(\.sessionID))
    for s in sessions.values where s.needsAttention { ids.insert(s.id) }
    return ids.count
  }

  public var doneUnseenSessions: [Session] {
    orderedSessions.filter(\.isDoneUnseen)
  }

  public var doneUnseenCount: Int {
    sessions.values.reduce(0) { $0 + ($1.isDoneUnseen ? 1 : 0) }
  }

  public var workingCount: Int {
    sessions.values.reduce(0) { $0 + ($1.status.isWorking ? 1 : 0) }
  }

  public var anyWorking: Bool { workingCount > 0 }

  /// Sessions actually running: working and not blocked on the user (no pending card, no
  /// question / plan / input request). The ears, chips and header spark use this.
  public var activeWorkingCount: Int {
    sessions.values.reduce(0) { n, s in
      n + (s.status.isWorking && !needsAttention(s) ? 1 : 0)
    }
  }

  public var anyActiveWorking: Bool { activeWorkingCount > 0 }

  public var anyError: Bool {
    sessions.values.contains {
      if case .error = $0.status { return $0.unseen }
      return false
    }
  }

  /// Any done session the user has not seen yet.
  public var anyDone: Bool { doneUnseenCount > 0 }

  /// A card, question, plan approval or input request is waiting.
  public var anyWaiting: Bool {
    !pending.isEmpty || sessions.values.contains {
      switch $0.status {
      case .waitingInput, .question, .planApproval: return true
      default: return false
      }
    }
  }

  // MARK: - Derived: permission queue

  /// All cards, oldest first.
  public var queue: [PendingPermission] { pending }

  public func cards(for sessionID: String) -> [PendingPermission] {
    pending.filter { $0.sessionID == sessionID }
  }

  public func firstCard(for sessionID: String) -> PendingPermission? {
    pending.first { $0.sessionID == sessionID }
  }

  public func card(id: String) -> PendingPermission? {
    pending.first { $0.id == id }
  }

  /// Zero-based position of the card in the global queue and the queue length.
  public func queuePosition(of id: String) -> (index: Int, total: Int)? {
    pending.firstIndex { $0.id == id }.map { ($0, pending.count) }
  }

  /// Whether a click on the card's buttons may be acted on yet.
  public func isArmed(_ card: PendingPermission) -> Bool {
    let t = now()
    return t.timeIntervalSince(card.createdAt) >= Self.armDelayNew
      && t.timeIntervalSince(lastRemovalAt) >= removalArmDelay
  }

  /// Time at which `card` becomes clickable, given the current state.
  public func armedAt(_ card: PendingPermission) -> Date {
    max(card.createdAt.addingTimeInterval(Self.armDelayNew),
      lastRemovalAt.addingTimeInterval(removalArmDelay))
  }

  // MARK: - Events

  public func handleEvent(_ e: HookEvent, termProgram: String?) {
    handleEvent(e, context: HookContext(termProgram: termProgram))
  }

  public func handleEvent(_ e: HookEvent, context: HookContext) {
    // Effects raised while the event is applied go out once the session is stored: whatever
    // renders on an effect (the peek) must already see the new status (v2 "stale peek").
    let outermost = heldEffects == nil
    if outermost { heldEffects = [] }
    defer {
      if outermost {
        let effects = heldEffects ?? []
        heldEffects = nil
        for effect in effects { onEffect?(effect) }
      }
    }
    let t = now()
    let isNew = sessions[e.sessionID] == nil
    var session = sessions[e.sessionID] ?? newSession(e, context: context, at: t)
    if !e.cwd.isEmpty {
      session.cwd = e.cwd
      session.project = e.projectName
    }
    apply(context, to: &session)
    adoptDiscovered(context, into: &session, isNew: isNew)
    let before = session.status
    if let agent = e.agentID, e.name != "SubagentStop" {
      let old = session.agents[agent]
      session.agents[agent] = AgentActivity(
        id: agent, type: e.agentType ?? old?.type, lastTool: e.toolName ?? old?.lastTool,
        lastSeen: t)
    }

    switch e.name {
    case "SessionStart" where e.source == "compact":
      // Auto / manual compaction mid-session: same session, same turn. Only the identity
      // (already applied above) is refreshed; status, unseen, agents and cards stay.
      break
    case "SessionStart":
      flushPending(e.sessionID)
      session.agents = [:]
      session.activity = nil
      session.turnToolCount = 0
      session.rhythm = nil
      setStatus(&session, .idle, at: t)
    case "UserPromptSubmit":
      flushPending(e.sessionID)
      session.turnStartedAt = t
      session.turnToolCount = 0
      session.rhythm = ActivityRhythm(start: t)
      session.activity = nil
      setStatus(&session, .working(tool: nil), at: t)
    case "PreToolUse":
      handlePreToolUse(e, at: t)
      session.turnToolCount += 1
      // A turn already running when the app started gets its rhythm from the first call.
      if session.rhythm == nil { session.rhythm = ActivityRhythm(start: t) }
      session.rhythm?.record(at: t, agentID: e.agentID)
      if let tool = e.toolName {
        session.activity = ToolSummary.target(toolName: tool, input: e.toolInput)
      }
      if let status = interactiveStatus(e) {
        setStatus(&session, status, at: t)
      } else if !(e.agentID != nil && session.status.isBlocking) {
        setStatus(&session, .working(tool: e.toolName), at: t)
      }
    case "PostToolUse", "PostToolUseFailure":
      resolveMatching(e)
      if !(e.agentID != nil && session.status.isBlocking) {
        setStatus(&session, .working(tool: nil), at: t)
      }
    case "Stop":
      flushPending(e.sessionID, agentID: e.agentID)
      session.agents = [:]
      setStatus(&session, .done(Self.clean(e.lastAssistantMessage, fallback: "Tamamlandı")), at: t)
      session.unseen = true
      announce(e.sessionID, "done", sound: "Glass")
    case "StopFailure":
      flushPending(e.sessionID, agentID: e.agentID)
      session.agents = [:]
      let text = e.errorText ?? e.lastAssistantMessage
      setStatus(&session, .error(Self.clean(text, fallback: "Bir hata oluştu")), at: t)
      session.unseen = true
      announce(e.sessionID, "error", sound: "Basso")
    case "Notification":
      handleNotification(e, session: &session, at: t)
    case "PermissionRequest":
      // Forwarded as an event by the bridge: the tool needs interaction in the terminal.
      let status = interactiveStatus(e)
        ?? .waitingInput("Girdi bekliyor: \(e.toolName ?? "araç")")
      setStatus(&session, status, at: t)
    case "SubagentStart":
      break
    case "SubagentStop":
      if let agent = e.agentID { session.agents.removeValue(forKey: agent) }
    case "SessionEnd":
      if let pid = sessions[e.sessionID]?.pid ?? context.pid { endedPIDs[pid] = t }
      removeSession(e.sessionID)
      return
    default:
      return
    }
    session.lastUpdate = t
    sessions[e.sessionID] = session
    if session.status != before, session.status.needsAttention, e.name != "StopFailure" {
      announce(e.sessionID, session.status.kind, sound: "Ping")
    }
  }

  /// question / plan approval for AskUserQuestion / ExitPlanMode, nil for other tools.
  private func interactiveStatus(_ e: HookEvent) -> SessionStatus? {
    switch e.toolName {
    case "AskUserQuestion":
      let q = e.question
      let text = q?.text.isEmpty == false ? q?.text ?? "" : "Claude bir soru soruyor"
      return .question(text: text, options: q?.options ?? [])
    case "ExitPlanMode":
      return .planApproval(e.planSummary)
    default:
      return nil
    }
  }

  private func handleNotification(_ e: HookEvent, session: inout Session, at t: Date) {
    let type = e.notificationType ?? ""
    let text = Self.clean(e.message ?? e.title, fallback: "Girdi bekliyor")
    switch type {
    case "permission_prompt":
      // The card (or the question / plan dialog) already says it.
      guard !hasPending(for: e.sessionID), !session.status.isBlocking else { return }
      setStatus(&session, .waitingInput(text), at: t)
    case "idle_prompt":
      // Claude finished its turn ~60 s ago: no dialog can still be open (a question / plan
      // dismissed with Esc ends here). done / error keep their more useful text.
      flushStale(e.sessionID)
      switch session.status {
      case .done, .error:
        return
      case .question, .planApproval:
        guard t.timeIntervalSince(session.statusSince) > Self.mismatchGrace else { return }
        setStatus(&session, .waitingInput(text), at: t)
      default:
        setStatus(&session, .waitingInput(text), at: t)
      }
    case "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
      setStatus(&session, .waitingInput(text), at: t)
    default:
      return
    }
  }

  private func newSession(_ e: HookEvent, context: HookContext, at t: Date) -> Session {
    Session(
      id: e.sessionID, project: e.projectName, cwd: e.cwd, termProgram: context.termProgram,
      status: .idle, startedAt: t, lastUpdate: t)
  }

  private func apply(_ context: HookContext, to session: inout Session) {
    if let term = context.termProgram, !term.isEmpty { session.termProgram = term }
    if let tty = context.tty, let pid = context.pid {
      session.tty = tty
      session.pid = pid
      watchExit(sessionID: session.id, pid: pid)
    }
    if let branch = context.branch { session.branch = branch }
  }

  /// A hook event of a process the scan found earlier: its placeholder goes, the hook session
  /// (its session_id) stays. A new hook session takes the placeholder's place in the line.
  private func adoptDiscovered(_ context: HookContext, into session: inout Session, isNew: Bool) {
    for placeholder in discoveredMatches(context) where placeholder.id != session.id {
      if isNew { session.startedAt = min(session.startedAt, placeholder.startedAt) }
      if session.termProgram == nil { session.termProgram = placeholder.termProgram }
      sessions.removeValue(forKey: placeholder.id)
      exitWatches.removeValue(forKey: placeholder.id)?.watch.cancel()
    }
  }

  private func setStatus(_ s: inout Session, _ status: SessionStatus, at t: Date) {
    if s.status.kind != status.kind { s.statusSince = t }
    s.status = status
    s.unseen = false
  }

  private func announce(_ sessionID: String, _ kind: String, sound: String) {
    emit(.sound(sound))
    emit(.autoExpand(seconds: Self.autoExpandSeconds))
    emit(.attention(sessionID: sessionID, kind: kind))
  }

  /// Effects held back until the current event is committed (see `handleEvent`).
  @ObservationIgnored private var heldEffects: [StoreEffect]?

  private func emit(_ effect: StoreEffect) {
    if heldEffects != nil {
      heldEffects?.append(effect)
    } else {
      onEffect?(effect)
    }
  }

  private func handlePreToolUse(_ e: HookEvent, at t: Date) {
    guard let key = e.callKey else { return }
    let history = recentPre[e.sessionID] ?? []
    let stale = history.filter { t.timeIntervalSince($0.at) < 60 }
    for card in pending
    where card.sessionID == e.sessionID && card.agentID == e.agentID && card.key != key {
      let old = t.timeIntervalSince(card.createdAt) > Self.mismatchGrace
      let seenBefore = stale.contains { $0.key == key && $0.at < card.createdAt }
      if old && !seenBefore { remove(card.id, replyEmpty: true) }
    }
    recentPre[e.sessionID] = Array((stale + [(key, t)]).suffix(30))
  }

  private func resolveMatching(_ e: HookEvent) {
    guard let key = e.callKey else { return }
    for card in pending where card.key == key { remove(card.id, replyEmpty: true) }
  }

  // MARK: - Permissions

  @discardableResult
  public func addPermission(
    _ e: HookEvent, termProgram: String?, reply: @escaping @Sendable (Data?) -> Void
  ) -> PendingPermission {
    addPermission(e, context: HookContext(termProgram: termProgram), reply: reply)
  }

  @discardableResult
  public func addPermission(
    _ e: HookEvent, context: HookContext, reply: @escaping @Sendable (Data?) -> Void
  ) -> PendingPermission {
    let t = now()
    let isNew = sessions[e.sessionID] == nil
    var session = sessions[e.sessionID] ?? newSession(e, context: context, at: t)
    if isNew { session.status = .working(tool: e.toolName) }
    apply(context, to: &session)
    adoptDiscovered(context, into: &session, isNew: isNew)
    session.lastUpdate = t
    session.unseen = false
    sessions[e.sessionID] = session
    let tool = e.toolName ?? "?"
    let key = CallKey.make(sessionID: e.sessionID, toolName: tool, input: e.toolInput)
    // A retried call replaces its stale card (the old dialog is gone: Esc / "No" in terminal).
    for old in pending where old.key == key { remove(old.id, replyEmpty: true) }
    let card = PendingPermission(
      id: String(UUID().uuidString.prefix(8)).lowercased(), sessionID: e.sessionID,
      project: e.projectName, toolName: tool, toolInput: e.toolInput,
      summary: ToolSummary.make(toolName: tool, input: e.toolInput),
      fullText: ToolSummary.fullText(toolName: tool, input: e.toolInput),
      extra: ToolSummary.extra(toolName: tool, input: e.toolInput), agentID: e.agentID,
      suggestions: e.suggestions, createdAt: t, key: key,
      risk: RiskClassifier.risk(toolName: tool, input: e.toolInput),
      reply: PermissionReply(reply)
    )
    pending.append(card)
    emit(.sound("Ping"))
    emit(.attention(sessionID: e.sessionID, kind: "permission"))
    return card
  }

  @discardableResult
  public func decide(id: String, decision: PermissionDecision) -> Bool {
    guard let card = pending.first(where: { $0.id == id }) else { return false }
    let body = decision.responseBody(suggestions: card.suggestions)
    pending.removeAll { $0.id == id }
    lastRemovalAt = now()
    card.reply.send(body)
    return true
  }

  /// Denies every card of the session in one step ("Tümünü reddet"). The per-card arm guard
  /// after a removal must not stop cards 2...N of an explicit bulk action. Returns the count.
  @discardableResult
  public func denyAll(sessionID: String, message: String = PermissionDecision.defaultDenyMessage)
    -> Int
  {
    let cards = pending.filter { $0.sessionID == sessionID }
    guard !cards.isEmpty else { return 0 }
    let ids = Set(cards.map(\.id))
    pending.removeAll { ids.contains($0.id) }
    lastRemovalAt = now()
    for card in cards {
      card.reply.send(PermissionDecision.deny(message: message).responseBody(
        suggestions: card.suggestions))
    }
    return cards.count
  }

  /// The held connection went away (curl killed / timed out): drop the card silently.
  public func connectionDropped(id: String) {
    remove(id, replyEmpty: true)
  }

  /// Flushes every card of the session.
  public func flushPending(_ sessionID: String) {
    for card in pending where card.sessionID == sessionID { remove(card.id, replyEmpty: true) }
  }

  /// Flushes only the cards asked by `agentID` (`nil` = main agent), so a main-agent Stop keeps
  /// subagent prompts alive.
  public func flushPending(_ sessionID: String, agentID: String?) {
    for card in pending where card.sessionID == sessionID && card.agentID == agentID {
      remove(card.id, replyEmpty: true)
    }
  }

  /// idle_prompt: Claude waits for a prompt, so no dialog can be open. Cards created a moment
  /// ago are kept (event ordering race).
  private func flushStale(_ sessionID: String) {
    let t = now()
    for card in pending
    where card.sessionID == sessionID && t.timeIntervalSince(card.createdAt) > Self.mismatchGrace {
      remove(card.id, replyEmpty: true)
    }
  }

  private func remove(_ id: String, replyEmpty: Bool) {
    guard let card = pending.first(where: { $0.id == id }) else { return }
    pending.removeAll { $0.id == id }
    lastRemovalAt = now()
    if replyEmpty { card.reply.send(nil) }
  }

  // MARK: - Seen

  /// The user looked at the session (row click, focus): clears unseen done / error and turns a
  /// plain "waiting for input" into idle. Questions, plan approvals and cards stay.
  public func markSeen(sessionID: String) {
    guard var s = sessions[sessionID] else { return }
    var changed = false
    if s.unseen {
      s.unseen = false
      changed = true
    }
    if case .waitingInput = s.status {
      setStatus(&s, .idle, at: now())
      changed = true
    }
    if changed { sessions[sessionID] = s }
  }

  /// The terminal with `tty` became the focused one: marks its sessions seen.
  @discardableResult
  public func markSeen(tty: String) -> Bool {
    guard HookContext.validTTY(tty) != nil else { return false }
    var any = false
    for s in sessions.values where s.tty == tty && (s.unseen || s.status.kind == "waiting") {
      markSeen(sessionID: s.id)
      any = true
    }
    return any
  }

  /// v1 name of `markSeen(sessionID:)`.
  public func dismiss(sessionID: String) {
    markSeen(sessionID: sessionID)
  }

  // MARK: - Housekeeping

  /// Whether the session's claude process is still alive on its tty (true when unknown).
  public func isAlive(_ s: Session) -> Bool {
    guard let pid = s.pid else { return true }
    return probe.owns(pid: pid, tty: s.tty)
  }

  /// Liveness + quiet pass. Removes sessions whose claude process died or left its tty (their
  /// cards are flushed), marks long-silent working sessions `.quiet`, forgets stale subagents.
  /// Returns the removed session ids.
  @discardableResult
  public func sweep() -> [String] {
    let t = now()
    var removed: [String] = []
    for (id, s) in sessions {
      if !isAlive(s) {
        removeSession(id)
        removed.append(id)
        continue
      }
      var u = s
      if s.status.isWorking, !hasPending(for: id),
        t.timeIntervalSince(s.lastUpdate) >= Self.quietAfter
      {
        setStatus(&u, .quiet, at: t)
      }
      u.agents = u.agents.filter { t.timeIntervalSince($0.value.lastSeen) < Self.agentStaleAfter }
      if u != s { sessions[id] = u }
    }
    return removed
  }

  /// Drops the session and flushes its cards (empty reply: the terminal dialog decides).
  public func removeSession(_ id: String) {
    flushPending(id)
    sessions.removeValue(forKey: id)
    recentPre.removeValue(forKey: id)
    exitWatches.removeValue(forKey: id)?.watch.cancel()
  }

  /// Watches the session's claude process: its exit removes the row at once (also while the
  /// process is an unreaped zombie), instead of waiting for the next sweep.
  func watchDiscoveredExit(sessionID: String, pid: Int32) {
    watchExit(sessionID: sessionID, pid: pid)
  }

  private func watchExit(sessionID: String, pid: Int32) {
    if exitWatches[sessionID]?.pid == pid { return }
    exitWatches.removeValue(forKey: sessionID)?.watch.cancel()
    let watch = probe.watchExit(pid) { [weak self] in
      Task { @MainActor in self?.processExited(sessionID: sessionID, pid: pid) }
    }
    if let watch { exitWatches[sessionID] = (pid, watch) }
  }

  /// The watched claude process of `sessionID` exited.
  public func processExited(sessionID: String, pid: Int32) {
    guard let s = sessions[sessionID], s.pid == pid else { return }
    removeSession(sessionID)
  }

  /// Sessions without a pid (old hook, no tty) cannot be checked for liveness: drop them after
  /// `pruneAge` without events.
  public func prune() {
    let cutoff = now().addingTimeInterval(-Self.pruneAge)
    for (id, s) in sessions where s.pid == nil && s.lastUpdate < cutoff && !hasPending(for: id) {
      removeSession(id)
    }
  }

  static func clean(_ text: String?, fallback: String) -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return fallback }
    return ToolSummary.truncate(trimmed, 400)
  }

  // MARK: - Debug

  public func debugSnapshot() -> JSONValue {
    func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    let sess: [JSONValue] = orderedSessions.map { s in
      var options: JSONValue = .null
      if case .question(_, let o) = s.status { options = .array(o.map { .string($0) }) }
      return .object([
        "session_id": .string(s.id), "project": .string(s.project), "cwd": .string(s.cwd),
        "term": opt(s.termProgram), "tty": opt(s.tty),
        "pid": s.pid.map { .int(Int($0)) } ?? .null, "branch": opt(s.branch),
        "discovered": .bool(s.isDiscovered), "tab_title": opt(s.tabTitle),
        "secondary": opt(secondaryText(for: s)),
        "disambiguator": opt(disambiguator(for: s)),
        "status": .string(s.status.kind), "label": .string(s.status.label),
        "detail": opt(s.status.detail), "options": options,
        "unseen": .bool(s.unseen), "attention": .bool(needsAttention(s)),
        "agents": .array(s.activeAgents.map { .string($0.type ?? $0.id) }),
        "cards": .array(cards(for: s.id).map { .string($0.id) }),
        "activity": opt(s.activity), "group": .int(group(of: s).rawValue),
        "last_update": .double(s.lastUpdate.timeIntervalSince1970)
      ])
    }
    let cards: [JSONValue] = pending.map { c in
      .object([
        "id": .string(c.id), "session_id": .string(c.sessionID), "project": .string(c.project),
        "tool_name": .string(c.toolName), "summary": .string(c.summary),
        "agent_id": opt(c.agentID),
        "needs_expansion": .bool(c.needsExpansion),
        "has_suggestions": .bool(!c.suggestions.isEmpty),
        "always": opt(c.alwaysDescription),
        "created_at": .double(c.createdAt.timeIntervalSince1970)
      ])
    }
    return .object([
      "sessions": .array(sess), "pending": .array(cards),
      "attention_count": .int(attentionCount), "done_unseen_count": .int(doneUnseenCount)
    ])
  }
}
