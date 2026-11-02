import Foundation
import Network

/// One-shot HTTP response channel for a connection. Safe to call from any thread.
public final class HTTPResponder: @unchecked Sendable {
  private let lock = NSLock()
  private var responded = false
  private var closed = false
  private var closeHandler: (@Sendable () -> Void)?
  private let sendImpl: @Sendable (Data) -> Void

  init(send: @escaping @Sendable (Data) -> Void) {
    self.sendImpl = send
  }

  @discardableResult
  public func respond(status: Int, body: Data = Data()) -> Bool {
    lock.lock()
    if responded || closed {
      lock.unlock()
      return false
    }
    responded = true
    lock.unlock()
    sendImpl(HTTPResponse.build(status: status, body: body))
    return true
  }

  /// Called once if the peer disconnects before a response was sent.
  public func onPeerClosed(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    if closed {
      lock.unlock()
      handler()
      return
    }
    closeHandler = handler
    lock.unlock()
  }

  func peerClosed() {
    lock.lock()
    if closed || responded {
      lock.unlock()
      return
    }
    closed = true
    let h = closeHandler
    closeHandler = nil
    lock.unlock()
    h?()
  }
}

public enum SocketServerError: Error, Sendable {
  case startFailed(String)
}

/// Minimal HTTP/1.1 server on a Unix domain socket (Network.framework).
public final class SocketServer: @unchecked Sendable {
  public typealias Handler = @Sendable (HTTPRequest, HTTPResponder) -> Void

  public let path: String
  private let handler: Handler
  private let queue = DispatchQueue(label: "claudenotch.socket")
  private var listener: NWListener?

  public init(path: String, handler: @escaping Handler) {
    self.path = path
    self.handler = handler
  }

  public static func defaultSocketPath() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.path ?? NSHomeDirectory() + "/Library/Application Support"
    return base + "/ClaudeNotch/notch.sock"
  }

  public func start() throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(dir, 0o700)
    unlink(path)

    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
    let l: NWListener
    do {
      l = try NWListener(using: params)
    } catch {
      throw SocketServerError.startFailed("\(error)")
    }
    let ready = DispatchSemaphore(value: 0)
    let box = StartBox()
    l.stateUpdateHandler = { state in
      switch state {
      case .ready:
        box.set(nil)
        ready.signal()
      case .failed(let err):
        box.set("\(err)")
        ready.signal()
      default:
        break
      }
    }
    l.newConnectionHandler = { [handler, queue] conn in
      ServerConnection(conn, queue: queue, handler: handler).start()
    }
    l.start(queue: queue)
    if ready.wait(timeout: .now() + 3) == .timedOut {
      l.cancel()
      throw SocketServerError.startFailed("zaman aşımı")
    }
    if let err = box.get() {
      l.cancel()
      throw SocketServerError.startFailed(err)
    }
    chmod(path, 0o600)
    listener = l
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    unlink(path)
  }
}

private final class StartBox: @unchecked Sendable {
  private let lock = NSLock()
  private var error: String?
  func set(_ e: String?) {
    lock.lock()
    error = e
    lock.unlock()
  }
  func get() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return error
  }
}

private final class ServerConnection: @unchecked Sendable {
  private let conn: NWConnection
  private let queue: DispatchQueue
  private let handler: SocketServer.Handler
  private var parser = HTTPRequestParser()
  private var responder: HTTPResponder?

  init(_ conn: NWConnection, queue: DispatchQueue, handler: @escaping SocketServer.Handler) {
    self.conn = conn
    self.queue = queue
    self.handler = handler
  }

  func start() {
    conn.stateUpdateHandler = { [self] state in
      switch state {
      case .failed, .cancelled:
        responder?.peerClosed()
      default:
        break
      }
    }
    conn.start(queue: queue)
    readRequest()
  }

  private func readRequest() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [self] data, _, isComplete, error in
      if let data, !data.isEmpty {
        switch parser.feed(data) {
        case .needMore:
          break
        case .failed(let err):
          let status = err == .bodyTooLarge ? 413 : 400
          conn.send(
            content: HTTPResponse.build(status: status), contentContext: .finalMessage,
            isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
          return
        case .complete(let request):
          dispatch(request)
          return
        }
      }
      if error != nil || isComplete {
        conn.cancel()
        return
      }
      readRequest()
    }
  }

  private func dispatch(_ request: HTTPRequest) {
    let r = HTTPResponder { [conn] data in
      conn.send(
        content: data, contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { _ in conn.cancel() })
    }
    responder = r
    watchForClose()
    handler(request, r)
  }

  /// Keep a read pending so a dropped client (curl killed) is noticed while a response is held.
  private func watchForClose() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
      [self] data, _, isComplete, error in
      if error != nil || isComplete {
        responder?.peerClosed()
        conn.cancel()
        return
      }
      _ = data
      watchForClose()
    }
  }
}
