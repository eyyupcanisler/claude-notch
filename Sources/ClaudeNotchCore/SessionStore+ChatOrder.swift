import Foundation

// MARK: - The panel's order: pins and drags (`ChatOrder`)

extension SessionStore {
  /// The panel list: `displayOrder` (the tab order, hidden chats left out) with the user's pins
  /// on top and dragged rows where they were dropped. The status line keeps `displayOrder`.
  public var panelOrder: [Session] { chatOrder.arrange(displayOrder) }

  public func isPinned(_ sessionID: String) -> Bool { chatOrder.isPinned(sessionID) }

  /// Pins the chat to the top of the panel, or unpins it.
  public func togglePin(sessionID: String) {
    guard sessions[sessionID] != nil else { return }
    updateOrder { order in
      order.togglePin(sessionID)
      remember(sessionID, in: &order)
    }
  }

  /// A row was dropped: `group` is the new order of its group's rows (the pinned ones, or the
  /// others) as the panel showed them. Rows of the other group are ignored.
  public func reorder(group: [String]) {
    let live = group.filter { sessions[$0] != nil }
    guard let first = live.first else { return }
    let pinned = chatOrder.isPinned(first)
    let same = live.filter { chatOrder.isPinned($0) == pinned }
    updateOrder { order in
      order.reorder(same)
      for id in same { remember(id, in: &order) }
    }
  }

  /// The saved order (the app loads it at launch): entries not seen for a day are dropped.
  public func loadChatOrder(_ order: ChatOrder) {
    chatOrder = order.pruned(now: now())
  }

  /// Changes `chatOrder` and reports it (`onChatOrderChange`) when it changed.
  func updateOrder(_ change: (inout ChatOrder) -> Void) {
    var order = chatOrder
    change(&order)
    guard order != chatOrder else { return }
    chatOrder = order
    onChatOrderChange?(order)
  }

  /// Notes the chat's pid and terminal (to find it after the app restarts) and that it is alive.
  private func remember(_ id: String, in order: inout ChatOrder) {
    guard order.contains(id), let s = sessions[id] else { return }
    if let pid = s.pid, let tty = s.tty {
      order.identity[id] = ChatOrder.Identity(pid: pid, tty: tty)
    }
    order.seen[id] = now()
  }

  /// A hook event of `sessionID`: when it is a chat the order knows under an old id (same
  /// process and terminal: /clear or /resume whose SessionEnd came first, or a chat from
  /// before the app restarted), the entry moves to this id. Also keeps its identity current.
  func carryOrder(to sessionID: String, context: HookContext) {
    guard !chatOrder.isEmpty else { return }
    if !chatOrder.contains(sessionID), let pid = context.pid, let tty = context.tty {
      let live = Set(sessions.keys).subtracting([sessionID])
      if let old = chatOrder.entry(pid: pid, tty: tty, live: live) {
        updateOrder { $0.rename(old, to: sessionID) }
      }
    }
    if chatOrder.contains(sessionID), let pid = context.pid, let tty = context.tty,
      chatOrder.identity[sessionID] != ChatOrder.Identity(pid: pid, tty: tty)
    {
      updateOrder { $0.identity[sessionID] = ChatOrder.Identity(pid: pid, tty: tty) }
    }
  }

  /// A placeholder the process scan just made for `pid` on `tty`: when the order knows that
  /// chat (from before the app restarted), the entry moves to the placeholder, and from there
  /// to the hook session that adopts it.
  func carryOrder(toPlaceholder id: String, pid: Int32, tty: String) {
    guard !chatOrder.isEmpty, !chatOrder.contains(id) else { return }
    let live = Set(sessions.keys).subtracting([id])
    guard let old = chatOrder.entry(pid: pid, tty: tty, live: live) else { return }
    updateOrder { $0.rename(old, to: id) }
  }

  /// Marks the live chats in the order as seen, at most once an hour each (the sweep calls it),
  /// so an open chat is never forgotten while it runs.
  func touchOrder() {
    guard !chatOrder.isEmpty else { return }
    let t = now()
    let stale = sessions.keys.filter { id in
      chatOrder.contains(id) && (chatOrder.seen[id].map { t.timeIntervalSince($0) > 3600 } ?? true)
    }
    guard !stale.isEmpty else { return }
    updateOrder { order in for id in stale { order.seen[id] = t } }
  }
}
