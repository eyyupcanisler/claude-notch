import Foundation

// agy (Antigravity CLI) chats in the store. agy's hook payloads become the Claude Code events
// the store already applies (`AgyLinker`), so an agy row gets the same statuses, wings, jump to
// its tab, pins and hiding as a Claude row. Helper (workflow) conversations of an agy process
// show as subagents of its main chat: they share its pid, and an event of another conversation
// with that pid would otherwise retire the main row (`retireSiblings`).
// Plan: docs/plans/2026-11-21-agy-in-the-notch.md.
extension SessionStore {
  /// One agy hook request (POST /agy/event). `event` is the name the hook command passes, used
  /// when the payload carries none. `snapshot` is the status line of the sending agy process,
  /// when there is one: its conversation is the chat the user sees (the main one) and it names
  /// the model. An event without a terminal identity (no tty + pid) changes nothing: only agy
  /// chats in a terminal tab become rows. Returns false for a payload that is not agy's.
  @discardableResult
  public func handleAgyEvent(
    _ data: Data, context: HookContext, event: String?, snapshot: AgyStatusSnapshot?
  ) -> Bool {
    guard let payload = AgyHookPayload.parse(data, fallbackEvent: event) else { return false }
    guard let pid = context.pid else { return true }
    // The row of this pid's main chat is gone (the liveness sweep, a stopped tab): what the
    // linker knows about the pid is stale, and a new agy may reuse the pid.
    if let main = agyLinker.mainConversation(pid: pid), sessions[main] == nil {
      agyLinker.forget(pid: pid)
    }
    var agyContext = context
    agyContext.tool = .agy
    guard
      let e = agyLinker.translate(
        payload, pid: pid, shownConversation: snapshot?.conversationID)
    else { return true }
    handleEvent(e, context: agyContext)
    // The model of the main chat (a helper may run another one).
    if e.agentID == nil, sessions[e.sessionID] != nil {
      let label =
        snapshot?.modelLabel ?? payload.modelName.flatMap { AgyStatusSnapshot.label(forModelName: $0) }
      if let label, sessions[e.sessionID]?.modelLabel != label {
        sessions[e.sessionID]?.modelLabel = label
      }
    }
    return true
  }

  /// A line of an agy process's CLI log: a permission prompt or a question opened (the row needs
  /// the user), or a prompt was answered (working again). Shown on the process's main chat.
  public func handleAgyLog(_ e: AgyLogEvent, pid: Int32) {
    guard let event = agyLinker.storeEvent(for: e, pid: pid), sessions[event.sessionID] != nil
    else { return }
    handleEvent(event, context: HookContext())
  }

  /// The per-process status line snapshot: the model and effort of that process's chat.
  public func applyAgySnapshot(_ snapshot: AgyStatusSnapshot, pid: Int32) {
    guard let label = snapshot.modelLabel else { return }
    for (id, s) in sessions where s.tool == .agy && s.pid == pid && s.modelLabel != label {
      sessions[id]?.modelLabel = label
    }
  }

  /// The agy chats with a live process: what the agy watcher reads logs and status lines for.
  public var agyChats: [(sessionID: String, pid: Int32)] {
    sessions.values.compactMap { s in
      guard s.tool == .agy, let pid = s.pid else { return nil }
      return (s.id, pid)
    }
    .sorted { $0.pid < $1.pid }
  }
}
