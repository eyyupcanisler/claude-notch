import ClaudeNotchCore
import SwiftUI

/// The island under the notch: a permission card (two lines and compact buttons), a question,
/// or one "done / error" line. Clicking its background opens the panel.
struct PeekBody: View {
  let store: SessionStore
  let ui: NotchUIState
  let peek: PeekItem
  let displayID: CGDirectDisplayID
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Group {
      switch peek.kind {
      case .permission:
        if let card = peek.cardID.flatMap({ store.card(id: $0) }) {
          permission(card)
        }
      case .attention:
        attention
      case .finished:
        finished
      }
    }
    .padding(.horizontal, NotchMetrics.peekPadding)
    .padding(.top, peek.kind == .finished ? 9 : 8)
    .padding(.bottom, peek.kind == .finished ? 11 : 12)
    .background(CornerGlow(color: glowColor, strength: 0.34, radius: 220))
    .background(
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { actions.expand(displayID) }
    )
  }

  private var glowColor: Color {
    switch peek.kind {
    case .permission, .attention: return theme.needs
    case .finished:
      return peek.errorIDs.count == peek.sessionIDs.count ? theme.error : theme.done
    }
  }

  /// How long the finished turn took (single session only).
  private var turnDuration: TimeInterval? {
    guard peek.sessionIDs.count == 1, let s = store.sessions[peek.sessionIDs[0]],
      let start = s.turnStartedAt, start <= s.statusSince
    else { return nil }
    return s.statusSince.timeIntervalSince(start)
  }

  private func project(_ id: String?) -> String {
    id.flatMap { store.sessions[$0] }.map { store.displayName(for: $0) } ?? "Claude"
  }

  private func permission(_ card: PendingPermission) -> some View {
    let gate = CardGate(card: card, store: store, ui: ui)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10.5, weight: .bold)).foregroundStyle(theme.needs)
        Text("Claude izin istiyor")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink)
          .fixedSize()
        Text(project(card.sessionID))
          .font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        ToolIcon(tool: card.toolName).foregroundStyle(theme.secondary)
        Text(card.toolName)
          .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.secondary)
          .lineLimit(1).fixedSize()
        CountdownRing(createdAt: card.createdAt, compact: true)
        if store.pending.count > 1 {
          Text("+\(store.pending.count - 1)")
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(theme.needs))
            .help("\(store.pending.count - 1) istek daha")
        }
      }
      .notchEnter(0)
      Text(card.peekText)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchEnter(1)
      HStack(spacing: 6) {
        ActionButton(
          title: "Reddet", style: .secondary, keycap: ui.denyKey, enabled: gate.armed,
          compact: true
        ) {
          actions.decide(card.id, .deny(message: PermissionDecision.defaultDenyMessage), .peek)
        }
        if let risk = gate.risk {
          Text(risk).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.error)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        // Allowing from the peek only when its one line is the whole request; otherwise the
        // panel shows it in full first.
        if !card.fitsPeek {
          ActionButton(
            title: "Tümünü gör", style: .primary, keycap: ui.allowKey, enabled: true,
            compact: true
          ) {
            actions.selectCard(card.id)
            actions.expand(displayID)
          }
        } else {
          MoreButton(open: false) { actions.expand(displayID) }
            .help("Paneli aç")
          AllowButton(
            card: card, gate: gate, ui: ui, decision: .allow, title: "İzin ver",
            keycap: ui.allowKey, source: .peek, actions: actions, compact: true)
        }
      }
      .padding(.top, 2)
      .notchEnter(2)
      if let hint = ui.shortcutHint {
        // One-time: how to answer without the pointer (gone after the first use).
        Text(hint)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(theme.tertiary)
          .frame(maxWidth: .infinity, alignment: .center)
          .notchEnter(3)
      }
    }
  }

  private var attention: some View {
    let session = peek.sessionIDs.first.flatMap { store.sessions[$0] }
    let text = session?.status.detail ?? "Claude yanıt bekliyor"
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "questionmark.bubble.fill")
          .font(.system(size: 11, weight: .bold)).foregroundStyle(theme.needs)
        Text(project(session?.id))
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(session?.status.label ?? "Yanıt bekliyor")
          .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.secondary)
          .lineLimit(1).fixedSize()
      }
      .notchEnter(0)
      HStack(alignment: .center, spacing: 8) {
        Text(TextShortener.oneLine(text, limit: 90))
          .font(.system(size: 12))
          .foregroundStyle(theme.ink.opacity(0.92))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let id = session?.id {
          SmallButton(title: "Terminale git", style: .primary) { actions.focus(id) }
        }
      }
      .notchEnter(1)
    }
  }

  private var finished: some View {
    let names = peek.sessionIDs.map { id in
      store.sessions[id].map { store.displayName(for: $0) } ?? "Oturum"
    }
    let allErrors = peek.errorIDs.count == peek.sessionIDs.count
    let title = PeekPlanner.finishedTitle(names: names, errors: peek.errorIDs.count)
    let single = peek.sessionIDs.count == 1 ? peek.sessionIDs.first.flatMap {
      store.sessions[$0]?.status.detail
    } : nil
    return HStack(spacing: 7) {
      Image(systemName: allErrors ? "xmark.circle.fill" : "checkmark.circle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(allErrors ? theme.error : theme.done)
      Text(title)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .layoutPriority(1)
      if let single, !single.isEmpty {
        Text(TextShortener.oneLine(single, limit: 120))
          .font(.system(size: 11.5))
          .foregroundStyle(theme.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let d = turnDuration {
        let r = DotClock.reading(d)
        HStack(alignment: .lastTextBaseline, spacing: 3) {
          DotMatrixText(text: r.digits, color: allErrors ? theme.error : theme.done, pitch: 2)
          if let unit = r.unit {
            Text(unit).font(.system(size: 10, weight: .semibold))
              .foregroundStyle((allErrors ? theme.error : theme.done).opacity(0.8))
          }
        }
        .accessibilityElement()
        .accessibilityLabel("Süre \(r.digits) \(r.unit ?? "")")
      }
    }
    .frame(height: 18)
    .notchEnter(0)
  }
}
