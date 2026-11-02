import Darwin
import Dispatch
import Foundation

/// Cancels a process exit watch (see `ProcessProbe.watchExit`).
public final class ExitWatch: @unchecked Sendable {
  private let lock = NSLock()
  private var onCancel: (@Sendable () -> Void)?

  public init(cancel: @escaping @Sendable () -> Void) {
    onCancel = cancel
  }

  public func cancel() {
    lock.lock()
    let c = onCancel
    onCancel = nil
    lock.unlock()
    c?()
  }

  deinit { cancel() }
}

/// Process liveness checks, injectable for tests.
public struct ProcessProbe: Sendable {
  /// The process exists and has not exited (a zombie waiting to be reaped counts as dead).
  public var isAlive: @Sendable (Int32) -> Bool
  /// Controlling terminal of `pid`: "/dev/ttysNNN", "" when it has none, nil when unknown.
  public var ttyOf: @Sendable (Int32) -> String?
  /// Calls the handler (on the main queue) once `pid` exits, also while it is a zombie. The
  /// returned watch stops it. nil when exits cannot be watched (the sweep still catches them).
  public var watchExit: @Sendable (Int32, @escaping @Sendable () -> Void) -> ExitWatch?

  public init(
    isAlive: @escaping @Sendable (Int32) -> Bool, ttyOf: @escaping @Sendable (Int32) -> String?,
    watchExit: @escaping @Sendable (Int32, @escaping @Sendable () -> Void) -> ExitWatch? = {
      _, _ in nil
    }
  ) {
    self.isAlive = isAlive
    self.ttyOf = ttyOf
    self.watchExit = watchExit
  }

  /// Whether `pid` still is the process that owns `tty` (tty numbers are reused quickly).
  public func owns(pid: Int32, tty: String?) -> Bool {
    guard isAlive(pid) else { return false }
    guard let tty, let current = ttyOf(pid) else { return true }
    return current == tty
  }

  /// Process state from the kernel: nil when unknown, true for a zombie (exited, not reaped).
  /// sysctl still answers for zombies, where proc_pidinfo fails.
  static func isZombie(_ pid: Int32) -> Bool? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    // No such process: size comes back 0.
    if size == 0 { return true }
    return Int32(info.kp_proc.p_stat) == SZOMB
  }

  public static let system = ProcessProbe(
    isAlive: { pid in
      guard pid > 1 else { return false }
      guard kill(pid, 0) == 0 || errno == EPERM else { return false }
      return isZombie(pid) != true
    },
    ttyOf: { pid in
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
      let dev = dev_t(bitPattern: info.e_tdev)
      if dev == -1 { return "" }  // NODEV: no controlling terminal
      guard let name = devname(dev, S_IFCHR) else { return nil }
      return "/dev/" + String(cString: name)
    },
    watchExit: { pid, handler in
      guard pid > 1 else { return nil }
      let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
      source.setEventHandler {
        source.cancel()
        handler()
      }
      source.resume()
      return ExitWatch { source.cancel() }
    }
  )
}
