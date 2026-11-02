import Foundation

public struct HTTPRequest: Sendable, Equatable {
  public var method: String
  public var target: String
  public var headers: [String: String]
  public var body: Data

  public var path: String {
    target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? target
  }

  public func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }
}

public enum HTTPParseError: Error, Sendable, Equatable {
  case malformed(String)
  case headersTooLarge
  case bodyTooLarge
}

/// Incremental HTTP/1.1 request parser. Feed it bytes as they arrive from the socket.
public struct HTTPRequestParser: Sendable {
  public enum Outcome: Sendable, Equatable {
    case needMore
    case complete(HTTPRequest)
    case failed(HTTPParseError)
  }

  public static let maxHeaderBytes = 64 * 1024
  public static let maxBodyBytes = 64 * 1024 * 1024

  private var buffer: [UInt8] = []
  private var scanFrom = 0
  private var head: Head?

  private struct Head {
    var method: String
    var target: String
    var headers: [String: String]
    var bodyStart: Int
    var contentLength: Int?
    var chunked: Bool
  }

  public init() {}

  public mutating func feed(_ data: Data) -> Outcome {
    buffer.append(contentsOf: data)
    if head == nil, let failure = parseHead() { return failure }
    guard let h = head else { return .needMore }
    if h.chunked { return parseChunked(h) }
    let length = h.contentLength ?? 0
    if length > Self.maxBodyBytes { return .failed(.bodyTooLarge) }
    if buffer.count - h.bodyStart < length { return .needMore }
    let body = Data(buffer[h.bodyStart..<(h.bodyStart + length)])
    return .complete(
      HTTPRequest(method: h.method, target: h.target, headers: h.headers, body: body))
  }

  /// Returns nil when the head was parsed into `head`, otherwise an outcome to return as-is.
  private mutating func parseHead() -> Outcome? {
    var end: Int?
    var i = max(0, scanFrom - 3)
    while i + 4 <= buffer.count {
      if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 {
        end = i
        break
      }
      i += 1
    }
    scanFrom = buffer.count
    guard let headEnd = end else {
      return buffer.count > Self.maxHeaderBytes ? .failed(.headersTooLarge) : .needMore
    }
    if headEnd > Self.maxHeaderBytes { return .failed(.headersTooLarge) }
    let text = String(decoding: buffer[0..<headEnd], as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .failed(.malformed("empty")) }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return .failed(.malformed("request line")) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    var length: Int?
    if let raw = headers["content-length"] {
      guard let n = Int(raw), n >= 0 else { return .failed(.malformed("content-length")) }
      length = n
    }
    let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
    head = Head(
      method: String(parts[0]), target: String(parts[1]), headers: headers,
      bodyStart: headEnd + 4, contentLength: length, chunked: chunked
    )
    return head == nil ? .needMore : nil
  }

  private func parseChunked(_ h: Head) -> Outcome {
    var pos = h.bodyStart
    var body = Data()
    while true {
      guard let lineEnd = findCRLF(from: pos) else { return .needMore }
      let sizeText = String(decoding: buffer[pos..<lineEnd], as: UTF8.self)
        .split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
      guard let sizeText, let size = Int(sizeText, radix: 16), size >= 0 else {
        return .failed(.malformed("chunk size"))
      }
      pos = lineEnd + 2
      if size == 0 {
        // Trailers: skip until blank line.
        while true {
          guard let e = findCRLF(from: pos) else { return .needMore }
          if e == pos { break }
          pos = e + 2
        }
        return .complete(
          HTTPRequest(method: h.method, target: h.target, headers: h.headers, body: body))
      }
      if body.count + size > Self.maxBodyBytes { return .failed(.bodyTooLarge) }
      if buffer.count < pos + size + 2 { return .needMore }
      body.append(contentsOf: buffer[pos..<(pos + size)])
      pos += size + 2
    }
  }

  private func findCRLF(from start: Int) -> Int? {
    var i = start
    while i + 1 < buffer.count {
      if buffer[i] == 13, buffer[i + 1] == 10 { return i }
      i += 1
    }
    return nil
  }
}

public enum HTTPResponse {
  public static func build(
    status: Int, body: Data = Data(), contentType: String = "application/json"
  ) -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    case 413: reason = "Payload Too Large"
    default: reason = "Status"
    }
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    return out
  }
}
