import Foundation

/// Sendable JSON tree used for hook payloads. Supports canonical (sorted-key) serialization.
public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int.self) {
      self = .int(v)
    } else if let v = try? c.decode(Double.self) {
      self = .double(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  public static func parse(_ data: Data) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  /// Compact JSON with object keys sorted and slashes unescaped. Deterministic.
  public func canonical() -> String {
    var out = ""
    appendCanonical(to: &out)
    return out
  }

  public func encoded() -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(self)) ?? Data("null".utf8)
  }

  private func appendCanonical(to out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let v): out += v ? "true" : "false"
    case .int(let v): out += String(v)
    case .double(let v): out += v.isFinite ? String(v) : "null"
    case .string(let v): JSONValue.appendEscaped(v, to: &out)
    case .array(let a):
      out += "["
      for (i, v) in a.enumerated() {
        if i > 0 { out += "," }
        v.appendCanonical(to: &out)
      }
      out += "]"
    case .object(let o):
      out += "{"
      for (i, k) in o.keys.sorted().enumerated() {
        if i > 0 { out += "," }
        JSONValue.appendEscaped(k, to: &out)
        out += ":"
        o[k]?.appendCanonical(to: &out)
      }
      out += "}"
    }
  }

  private static func appendEscaped(_ s: String, to out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if u.value < 0x20 {
          out += String(format: "\\u%04x", u.value)
        } else {
          out.unicodeScalars.append(u)
        }
      }
    }
    out += "\""
  }
}
