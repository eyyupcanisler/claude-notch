import Foundation

/// Reads an app's scripting properties with raw Apple Events instead of AppleScript. Nothing is
/// compiled, so macOS runs no XProtect scan (about 14 MB of short-lived heap and 15-50 ms of
/// CPU per compile) and the AppleScript component (about 1.4 MB, kept for the life of the app)
/// is not loaded for these reads. The specifiers are the ones AppleScript itself sends for the
/// same expressions.
public enum AEQuery {
  /// Four-character code as the Apple Event Manager stores it ("core" -> 0x636F7265).
  public static func code(_ s: String) -> FourCharCode {
    precondition(s.utf8.count == 4, "four-character code: \(s)")
    return s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
  }

  /// `every <class> of <container>`; a nil container is the application.
  public static func every(
    _ elementClass: String, of container: NSAppleEventDescriptor? = nil
  ) -> NSAppleEventDescriptor {
    var all = code("all ")
    let data =
      NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)
      ?? NSAppleEventDescriptor(enumCode: all)
    return object(elementClass, from: container, form: "indx", data: data)
  }

  /// `<property> of <container>`; a nil container is the application.
  public static func property(
    _ propertyCode: String, of container: NSAppleEventDescriptor? = nil
  ) -> NSAppleEventDescriptor {
    object(
      "prop", from: container, form: "prop",
      data: NSAppleEventDescriptor(typeCode: code(propertyCode)))
  }

  private static func object(
    _ desiredClass: String, from container: NSAppleEventDescriptor?, form: String,
    data: NSAppleEventDescriptor
  ) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desiredClass)), forKeyword: code("want"))
    record.setDescriptor(container ?? .null(), forKeyword: code("from"))
    record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
    record.setDescriptor(data, forKeyword: code("seld"))
    return record.coerce(toDescriptorType: code("obj ")) ?? record
  }

  /// The `get` event (core/getd) for `specifier`, addressed to the app `bundleID`.
  public static func get(
    _ specifier: NSAppleEventDescriptor, bundleID: String
  ) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
      eventClass: code("core"), eventID: code("getd"),
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
      returnID: -1,  // kAutoGenerateReturnID
      transactionID: 0)  // kAnyTransactionID
    event.setParam(specifier, forKeyword: code("----"))
    return event
  }

  /// A reply's value as text: a list's text leaves depth first (a missing or non-text item
  /// becomes "", so parallel lists stay aligned), anything else as one item.
  public static func texts(of value: NSAppleEventDescriptor) -> [String] {
    value.descriptorType == code("list") ? leaves(of: value) : [value.stringValue ?? ""]
  }

  private static func leaves(of list: NSAppleEventDescriptor) -> [String] {
    guard list.numberOfItems > 0 else { return [] }
    var out: [String] = []
    for j in 1...list.numberOfItems {
      guard let item = list.atIndex(j) else {
        out.append("")
        continue
      }
      if item.descriptorType == code("list") {
        out += leaves(of: item)
      } else {
        out.append(item.stringValue ?? "")
      }
    }
    return out
  }
}

/// Ghostty's reads (terms from its scripting dictionary: window Gwnd, tab Gtab, terminal Gtrm,
/// tty Gtty, name pnam, front window GFWn, selected tab GWsT, focused terminal GTfT).
public enum GhosttyQuery {
  /// The ttys and the titles of every terminal in tab order (window -> tab -> split), as two
  /// nested lists: what `{tty of every terminal of every tab of every window, name of every
  /// terminal of every tab of every window}` asks. `every terminal` alone is not in tab order.
  public static func titles() -> [NSAppleEventDescriptor] {
    let terminals = AEQuery.every("Gtrm", of: AEQuery.every("Gtab", of: AEQuery.every("Gwnd")))
    return [AEQuery.property("Gtty", of: terminals), AEQuery.property("pnam", of: terminals)]
  }

  /// `tty of (focused terminal of (selected tab of front window))`.
  public static func focusedTTY() -> NSAppleEventDescriptor {
    AEQuery.property(
      "Gtty",
      of: AEQuery.property("GTfT", of: AEQuery.property("GWsT", of: AEQuery.property("GFWn"))))
  }
}
