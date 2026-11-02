import Foundation

/// Who sent a hook request: terminal app, the claude process's tty and pid, git branch.
/// Built from the bridge's headers; every value is validated because tty / cwd flow into
/// AppleScript and pid into kill(2).
public struct HookContext: Sendable, Equatable {
  public var termProgram: String?
  public var tty: String?
  public var pid: Int32?
  public var branch: String?

  public init(
    termProgram: String? = nil, tty: String? = nil, pid: Int32? = nil, branch: String? = nil
  ) {
    self.termProgram = termProgram
    self.tty = tty
    self.pid = pid
    self.branch = branch
  }

  /// Reads X-Term-Program, X-Claude-TTY, X-Claude-PID and X-Git-Branch. Invalid values are
  /// dropped (nil), never passed on. A pid without a valid tty is dropped too: liveness needs
  /// both to tell a reused pid apart.
  public init(request: HTTPRequest) {
    termProgram = Self.validTermProgram(request.header("x-term-program"))
    tty = Self.validTTY(request.header("x-claude-tty"))
    pid = tty == nil ? nil : Self.validPID(request.header("x-claude-pid"))
    if pid == nil { tty = nil }
    branch = Self.validBranch(request.header("x-git-branch"))
  }

  public static let maxBranchLength = 100

  /// `/dev/ttys` followed by 1-5 digits.
  public static func validTTY(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let prefix = "/dev/ttys"
    guard raw.hasPrefix(prefix) else { return nil }
    let digits = raw.dropFirst(prefix.count)
    guard (1...5).contains(digits.count), digits.allSatisfy(\.isASCIIDigitChar) else { return nil }
    return raw
  }

  /// Decimal digits only, 2 ... Int32.max (pid 0 / 1 are never a claude process).
  public static func validPID(_ raw: String?) -> Int32? {
    guard let raw, (1...10).contains(raw.count), raw.allSatisfy(\.isASCIIDigitChar),
      let n = Int32(raw), n > 1
    else { return nil }
    return n
  }

  /// Git branch: no control / format / space characters, cut at `maxBranchLength`.
  public static func validBranch(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw.unicodeScalars.count <= 255 else { return nil }
    for scalar in raw.unicodeScalars where scalar == " " || ToolSummary.isDeceptive(scalar) {
      return nil
    }
    return raw.count > maxBranchLength ? String(raw.prefix(maxBranchLength)) + "…" : raw
  }

  /// TERM_PROGRAM: letters, digits, `.`, `_`, `-`, up to 64 characters.
  public static func validTermProgram(_ raw: String?) -> String? {
    guard let raw, (1...64).contains(raw.count) else { return nil }
    let ok = raw.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
    }
    return ok ? raw : nil
  }
}

extension Character {
  var isASCIIDigitChar: Bool { isASCII && isNumber }
}
