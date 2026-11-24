import Foundation

/// The panel's own order of chats: the ones the user pinned come first, in their order, then
/// the rest. Dragging a row puts it where it was dropped among the others. Without any of
/// that, the panel follows the terminal tabs (`SessionStore.tabOrdered`) as before. The status
/// line under the notch keeps the tab order: its segments stand for the tabs.
///
/// Keyed by session id. A chat keeps its pin and place when its id changes: /clear and /resume
/// start a new session in the same process, the hook session replaces the placeholder the
/// process scan made, and after a restart of the app the scan finds the process again before
/// any hook event (`identity` matches it by pid and terminal).
public struct ChatOrder: Codable, Equatable, Sendable {
  /// Pinned chats, top first.
  public var pinned: [String] = []
  /// The user's order of the chats that are not pinned (empty: the tab order). Only the chats
  /// in it move; the others keep the place the tab order gives them.
  public var manual: [String] = []
  /// pid and terminal of each chat in the lists, to find it again after the app restarts.
  public var identity: [String: Identity] = [:]
  /// When each chat in the lists was last seen alive; old ones are dropped (`pruned`).
  public var seen: [String: Date] = [:]

  public struct Identity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var tty: String

    public init(pid: Int32, tty: String) {
      self.pid = pid
      self.tty = tty
    }
  }

  /// UserDefaults key (app domain) of the saved order, JSON.
  public static let defaultsKey = "chatOrder"
  /// A chat in the lists not seen alive for this long is forgotten.
  public static let keepFor: TimeInterval = 24 * 60 * 60
  /// At most this many entries are kept (the oldest go first).
  public static let maxEntries = 100

  public init() {}

  public var isEmpty: Bool { pinned.isEmpty && manual.isEmpty }

  public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

  /// `sessions` (the tab order) in the panel's order: the pinned ones first, then the others,
  /// where those in `manual` take the places the tab order gives them, in the user's order.
  public func arrange(_ sessions: [Session]) -> [Session] {
    guard !isEmpty else { return sessions }
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let top = pinned.compactMap { byID[$0] }
    let pinnedSet = Set(pinned)
    var rest = sessions.filter { !pinnedSet.contains($0.id) }
    let restIDs = Set(rest.map(\.id))
    let ordered = manual.filter { restIDs.contains($0) }.compactMap { byID[$0] }
    let movable = Set(ordered.map(\.id))
    var next = ordered.makeIterator()
    for i in rest.indices where movable.contains(rest[i].id) {
      if let s = next.next() { rest[i] = s }
    }
    return top + rest
  }

  /// Pins the chat (at the bottom of the pinned ones) or unpins it (it goes back to the place
  /// the tab order gives it).
  public mutating func togglePin(_ id: String) {
    if let i = pinned.firstIndex(of: id) {
      pinned.remove(at: i)
    } else {
      pinned.append(id)
    }
    manual.removeAll { $0 == id }
    dropStale()
  }

  /// The user dropped a row: `group` is the new order of the rows of its group (all pinned
  /// ones, or all the others) as the panel's list shows them. The group's chats that are not
  /// in that list (hidden, or the one whose card has the slot above it) keep their places:
  /// the listed ones take the places listed ones had, in their new order.
  public mutating func reorder(_ group: [String]) {
    guard let first = group.first else { return }
    if pinned.contains(first) {
      pinned = Self.fill(pinned, with: group.filter(pinned.contains))
    } else {
      manual = Self.fill(manual, with: group.filter { !pinned.contains($0) })
    }
  }

  /// `list` (plus the ids of `group` it lacks, at its end) with the places of `group`'s ids
  /// taken by `group`, in its order; every other id stays where it was.
  static func fill(_ list: [String], with group: [String]) -> [String] {
    let shown = Set(group)
    var out = list + group.filter { !list.contains($0) }
    var next = group.makeIterator()
    for i in out.indices where shown.contains(out[i]) {
      if let id = next.next() { out[i] = id }
    }
    return out
  }

  /// The chat's id changed (see the type's note): its entries move to the new id. Nothing
  /// changes when the new id already has its own entries.
  public mutating func rename(_ old: String, to new: String) {
    guard old != new, contains(old), !contains(new) else { return }
    if let i = pinned.firstIndex(of: old) { pinned[i] = new }
    if let i = manual.firstIndex(of: old) { manual[i] = new }
    if let v = identity.removeValue(forKey: old) { identity[new] = v }
    if let v = seen.removeValue(forKey: old) { seen[new] = v }
  }

  public func contains(_ id: String) -> Bool { pinned.contains(id) || manual.contains(id) }

  /// Identities and times of ids that are in neither list any more (unpinned, never dragged)
  /// go: an old record must never be matched for a chat.
  mutating func dropStale() {
    identity = identity.filter { contains($0.key) }
    seen = seen.filter { contains($0.key) }
  }

  /// The entry (an id in the lists that no live chat has) whose pid and terminal are these.
  public func entry(pid: Int32, tty: String, live: Set<String>) -> String? {
    identity.filter { id, v in
      v.pid == pid && v.tty == tty && !live.contains(id) && contains(id)
    }.keys.sorted().first
  }

  /// Without entries not seen since `keepFor` whose chat is gone, and at most `maxEntries`
  /// (newest kept). `alive` says whether an entry's process still runs on its terminal: a
  /// chat that outlived a long pause of the app (quit on Friday, back on Monday) keeps its
  /// pin and place.
  public func pruned(now: Date, alive: (Identity) -> Bool = { _ in false }) -> ChatOrder {
    var out = self
    let ids = Set(pinned + manual)
    var keep = ids.filter { id in
      if let s = seen[id], now.timeIntervalSince(s) < Self.keepFor { return true }
      return identity[id].map(alive) ?? false
    }
    if keep.count > Self.maxEntries {
      keep = Set(keep.sorted { (seen[$0] ?? .distantPast) > (seen[$1] ?? .distantPast) }
        .prefix(Self.maxEntries))
    }
    out.pinned = pinned.filter(keep.contains)
    out.manual = manual.filter(keep.contains)
    out.identity = identity.filter { keep.contains($0.key) }
    out.seen = seen.filter { keep.contains($0.key) }
    return out
  }
}
