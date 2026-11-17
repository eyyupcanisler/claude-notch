import Foundation

/// What macOS's own Do Not Disturb store says about Focus.
public enum SystemFocusState: String, Sendable, Equatable {
  /// At least one Focus (Do Not Disturb, Work, Sleep, a scheduled one...) is on.
  case on
  /// No Focus is on.
  case off
  /// The file is missing, cannot be read (permission denied) or has a shape the app does not
  /// know: only the Shortcuts value (`FocusIslands.defaultsKey`) counts then.
  case unknown

  /// The app could read the file and make sense of it.
  public var readable: Bool { self != .unknown }
}

/// Reads the Focus state macOS keeps in ~/Library/DoNotDisturb/DB/Assertions.json. macOS has
/// no public API that tells an app whether a Focus is on, but every active Focus (turned on by
/// hand, by a schedule or by an automation) is a record in that file's
/// `data[*].storeAssertionRecords`; ended ones move to `storeInvalidationRecords`. The app
/// watches the file (see SystemFocusWatcher) and passes its bytes here.
public enum SystemFocus {
  /// The file, relative to the user's home folder.
  public static let relativePath = "Library/DoNotDisturb/DB/Assertions.json"
  /// The app reads the file again this often even when no change event came (a missed event,
  /// a file it could not watch), and after the Mac wakes.
  public static let recheckInterval: TimeInterval = 30

  /// The file in `home`.
  public static func fileURL(home: URL) -> URL {
    home.appendingPathComponent(relativePath, isDirectory: false)
  }

  /// The state the file's bytes describe: `.on` when any entry of `data` has an assertion
  /// record, `.off` when none has (no `storeAssertionRecords` key counts as none), `.unknown`
  /// for no bytes (missing, not readable) or a shape that is not the expected one.
  public static func state(of data: Data?) -> SystemFocusState {
    guard let data, !data.isEmpty,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["data"] as? [Any]
    else { return .unknown }
    var records = 0
    for entry in entries {
      guard let object = entry as? [String: Any] else { return .unknown }
      guard let value = object["storeAssertionRecords"] else { continue }
      guard let list = value as? [Any] else { return .unknown }
      records += list.count
    }
    return records > 0 ? .on : .off
  }
}
