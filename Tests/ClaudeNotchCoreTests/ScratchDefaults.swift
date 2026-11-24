import Foundation
import XCTest

/// A throwaway UserDefaults suite for one test. `remove()` empties it and also deletes its
/// plist: `removePersistentDomain` alone leaves an empty file in ~/Library/Preferences for
/// every test run.
struct ScratchDefaults {
  let name: String
  let defaults: UserDefaults

  init(_ prefix: String) throws {
    name = "\(prefix).\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: name))
  }

  func remove() {
    defaults.removePersistentDomain(forName: name)
    CFPreferencesAppSynchronize(name as CFString)
    let file = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: file)
  }
}
