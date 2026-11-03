import Foundation

/// Routes HTTP requests from the socket to the session store. Runs on the main actor.
@MainActor
public final class RequestRouter {
  public let store: SessionStore
  /// Debug: renders the notch view to PNG data (GET /debug/snapshot).
  public var snapshotProvider: (@MainActor () -> Data?)?
  /// Debug: extra UI state merged into GET /debug/state under "ui".
  public var uiStateProvider: (@MainActor () -> JSONValue)?
  /// Debug: POST /debug/focus {"session_id", "dry_run"} -> focus outcome / script text.
  public var focusProvider: (@MainActor (String, Bool) async -> JSONValue)?
  /// Debug: POST /debug/ui and /debug/key (route name without prefix, JSON body) -> result.
  /// Forces UI modes / theme / simulated keys for visual tests.
  public var uiCommandProvider: (@MainActor (String, JSONValue) -> JSONValue)?
  /// Debug: POST /debug/discover runs one process scan now.
  public var discoverProvider: (@MainActor () async -> Void)?

  /// `/debug/*` routes can approve requests and expose commands: off unless opted in
  /// (`CLAUDE_NOTCH_DEBUG=1` at launch).
  public let debugEnabled: Bool

  public init(store: SessionStore, debugEnabled: Bool = false) {
    self.store = store
    self.debugEnabled = debugEnabled
  }

  public func handle(_ req: HTTPRequest, _ responder: HTTPResponder) {
    if req.path.hasPrefix("/debug/") && !debugEnabled {
      responder.respond(status: 404)
      return
    }
    switch (req.method, req.path) {
    case ("POST", "/event"):
      guard let event = HookEvent.parse(req.body) else {
        responder.respond(status: 400)
        return
      }
      store.handleEvent(event, context: HookContext(request: req))
      responder.respond(status: 200)
    case ("POST", "/permission"):
      guard let event = HookEvent.parse(req.body), event.toolName != nil else {
        responder.respond(status: 400)
        return
      }
      let card = store.addPermission(event, context: HookContext(request: req)) { body in
        responder.respond(status: 200, body: body ?? Data())
      }
      let store = self.store
      let id = card.id
      responder.onPeerClosed {
        Task { @MainActor in store.connectionDropped(id: id) }
      }
    case ("POST", "/question"):
      guard let event = HookEvent.parse(req.body), event.toolName == "AskUserQuestion" else {
        responder.respond(status: 400)
        return
      }
      let held = store.addQuestion(event) { body in
        responder.respond(status: 200, body: body ?? Data())
      }
      if let id = held?.id {
        let store = self.store
        responder.onPeerClosed {
          Task { @MainActor in store.connectionDropped(id: id) }
        }
      }
    case ("GET", "/debug/state"):
      var snapshot = store.debugSnapshot().objectValue ?? [:]
      if let ui = uiStateProvider?() { snapshot["ui"] = ui }
      responder.respond(status: 200, body: JSONValue.object(snapshot).encoded())
    case ("GET", "/debug/snapshot"):
      if let png = snapshotProvider?() {
        responder.respond(status: 200, body: png)
      } else {
        responder.respond(status: 404)
      }
    case ("POST", "/debug/decide"):
      handleDecide(req, responder)
    case ("POST", "/debug/ui"), ("POST", "/debug/key"):
      guard let json = JSONValue.parse(req.body), let provider = uiCommandProvider else {
        responder.respond(status: 400)
        return
      }
      let result = provider(String(req.path.dropFirst("/debug/".count)), json)
      responder.respond(status: 200, body: result.encoded())
    case ("POST", "/debug/discover"):
      let store = self.store
      let provider = discoverProvider
      Task { @MainActor in
        await provider?()
        responder.respond(status: 200, body: store.debugSnapshot().encoded())
      }
    case ("POST", "/debug/focus"):
      guard let json = JSONValue.parse(req.body), let sid = json["session_id"]?.stringValue,
        let provider = focusProvider
      else {
        responder.respond(status: 400)
        return
      }
      let dryRun = json["dry_run"] == .bool(true)
      Task { @MainActor in
        let result = await provider(sid, dryRun)
        responder.respond(status: 200, body: result.encoded())
      }
    default:
      responder.respond(status: 404)
    }
  }

  private func handleDecide(_ req: HTTPRequest, _ responder: HTTPResponder) {
    guard let json = JSONValue.parse(req.body), let id = json["id"]?.stringValue,
      let kind = json["decision"]?.stringValue
    else {
      responder.respond(status: 400)
      return
    }
    let decision: PermissionDecision
    switch kind {
    case "allow": decision = .allow
    case "always": decision = .always
    case "deny":
      decision = .deny(
        message: json["message"]?.stringValue ?? PermissionDecision.defaultDenyMessage)
    default:
      responder.respond(status: 400)
      return
    }
    let ok = store.decide(id: id, decision: decision)
    responder.respond(status: ok ? 200 : 404, body: Data(#"{"ok":\#(ok)}"#.utf8))
  }
}
