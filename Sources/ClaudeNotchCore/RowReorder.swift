import Foundation

/// The arithmetic of dragging a panel row to a new place (pure, so it is tested without a
/// view). Rows have different heights, so places come from their measured frames.
public enum RowReorder {
  /// A row's vertical extent in the list (top, bottom; y grows downward).
  public struct Span: Equatable, Sendable {
    public var top: Double
    public var bottom: Double

    public init(top: Double, bottom: Double) {
      self.top = top
      self.bottom = bottom
    }

    public var mid: Double { (top + bottom) / 2 }
    public var height: Double { bottom - top }
  }

  /// Where the dragged row lands among `group` (the ids of its group, top first, the dragged
  /// one included): the number of the other rows whose middle is above the dragged row's
  /// middle, moved by `translation`. That is its index in the new order.
  public static func target(
    dragged: String, group: [String], spans: [String: Span], translation: Double
  ) -> Int {
    guard let own = spans[dragged] else { return group.firstIndex(of: dragged) ?? 0 }
    let mid = own.mid + translation
    return group.filter { $0 != dragged }.filter { id in
      guard let s = spans[id] else { return false }
      return s.mid < mid
    }.count
  }

  /// `group` with `dragged` moved to `index`.
  public static func moved(_ group: [String], dragged: String, to index: Int) -> [String] {
    guard let from = group.firstIndex(of: dragged) else { return group }
    var out = group
    out.remove(at: from)
    out.insert(dragged, at: min(max(index, 0), out.count))
    return out
  }

  /// How far each other row moves to open the gap: the dragged row's height plus `spacing`,
  /// up for the rows it passed going down, down for the rows it passed going up.
  public static func shift(
    of id: String, dragged: String, group: [String], target: Int, height: Double,
    spacing: Double
  ) -> Double {
    guard id != dragged, let from = group.firstIndex(of: dragged),
      let i = group.firstIndex(of: id)
    else { return 0 }
    let step = height + spacing
    if from < target, i > from, i <= target { return -step }
    if target < from, i >= target, i < from { return step }
    return 0
  }

  /// The translation the dragged row follows: 1:1 between the group's first and last place,
  /// then with growing resistance past them (it slows down instead of stopping dead).
  public static func resisted(
    translation: Double, dragged: String, group: [String], spans: [String: Span]
  ) -> Double {
    guard let own = spans[dragged], let first = group.first.flatMap({ spans[$0] }),
      let last = group.last.flatMap({ spans[$0] })
    else { return translation }
    let minT = first.top - own.top
    let maxT = last.bottom - own.bottom
    let dimension = max(own.height, 1)
    if translation < minT { return minT - band(minT - translation, dimension) }
    if translation > maxT { return maxT + band(translation - maxT, dimension) }
    return translation
  }

  /// Rubber band: the further past the edge, the less the row follows.
  static func band(_ overshoot: Double, _ dimension: Double, constant: Double = 0.55) -> Double {
    (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
  }
}
