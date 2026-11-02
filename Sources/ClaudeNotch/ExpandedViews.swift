import AppKit
import ClaudeNotchCore
import SwiftUI

// MARK: - Toolbar (takes over the menu-bar band while the panel is open)

/// Symmetric band row: controls left of the notch (pin, settings, Ghostty consent when it is
/// missing), status chips right of it. Only while the user opened the panel.
struct ExpandedToolbar: View {
  let store: SessionStore
  let ui: NotchUIState
  let actions: NotchActions
  let notchWidth: CGFloat
  let sideWidth: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 2) {
        BandIconButton(
          icon: ui.pinned ? "pin.fill" : "pin",
          label: ui.pinned ? "Sabitlemeyi kaldır" : "Sabitle", active: ui.pinned,
          action: actions.togglePin)
        BandIconButton(
          icon: "gearshape", label: "Ayarlar", active: false, action: actions.openSettings)
        if ui.ghosttyConsent.missing {
          BandIconButton(
            icon: "lock.shield", label: consentLabel, active: false, tint: NotchTheme.bandNeeds,
            action: actions.ghosttyConsent)
        }
        Spacer(minLength: 0)
      }
      .padding(.leading, 10)
      .frame(width: sideWidth)
      .notchEnter(0)
      Color.clear.frame(width: notchWidth)
      BandChips(store: store, actions: actions)
        .padding(.trailing, 12)
        .frame(width: sideWidth, alignment: .trailing)
        .notchEnter(0)
    }
  }

  private var consentLabel: String {
    ui.ghosttyConsent == .denied
      ? "Ghostty izni kapalı: Sistem Ayarları'nda aç"
      : "Ghostty izni: sekmesine geçmek için izin ver"
  }
}

/// "N izin" (shows the oldest card) and "N çalışıyor", in the band.
struct BandChips: View {
  let store: SessionStore
  let actions: NotchActions

  var body: some View {
    HStack(spacing: 5) {
      Spacer(minLength: 0)
      if !store.pending.isEmpty {
        Button(action: actions.showCards) {
          BandChip(text: "\(store.pending.count) izin", color: NotchTheme.bandNeeds, solid: true)
        }
        .buttonStyle(.plain)
        .help("En eski isteği göster")
      }
      if store.activeWorkingCount > 0 {
        BandChip(
          text: "\(store.activeWorkingCount) çalışıyor", color: NotchTheme.bandWorking,
          solid: false)
      }
    }
  }
}

struct BandChip: View {
  let text: String
  let color: Color
  let solid: Bool

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(solid ? Color.black : color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .frame(height: 20)
      .background(Capsule().fill(solid ? color : color.opacity(0.18)))
  }
}

struct BandIconButton: View {
  let icon: String
  let label: String
  let active: Bool
  var tint: Color?
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(
          tint ?? (active || hover ? NotchTheme.bandInk : NotchTheme.bandSecondary))
        .frame(width: 24, height: 24)
        .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(label)
    .accessibilityLabel(label)
  }
}

// MARK: - Body

struct ExpandedBody: View {
  let store: SessionStore
  let ui: NotchUIState
  let settings: NotchSettings
  let actions: NotchActions
  /// Height of the black band above (notch height).
  let bandHeight: CGFloat
  @State private var topHeight: CGFloat = 0
  /// Measured natural height of the rows (nil until the first layout; an estimate is used
  /// meanwhile: a zero-height ScrollView would never lay out its content to report a size).
  @State private var measuredRows: CGFloat?
  @Environment(\.notchTheme) private var theme

  static let spacing: CGFloat = 6
  static let topPadding: CGFloat = 4
  static let bottomPadding: CGFloat = 12

  private var sessions: [Session] {
    let live = store.displayOrder
    guard let frozen = ui.frozenOrder else { return live }
    return SessionStore.applyFrozen(frozen, to: live)
  }

  /// Card shown in the fixed slot at the top (see `RowKind.slotCard`).
  private var slotCard: PendingPermission? {
    RowKind.slotCard(store: store, ui: ui)
  }

  /// Room left for the scrolling rows so the whole panel stays within `NotchMetrics.maxHeight`.
  private var rowsBudget: CGFloat {
    let body = NotchMetrics.maxHeight - bandHeight
    return max(44, body - topHeight - Self.spacing - Self.topPadding - Self.bottomPadding)
  }

  var body: some View {
    let all = sessions
    let card = slotCard
    let slotSession = card.flatMap { c in all.first { $0.id == c.sessionID } }
    let rows = all.filter { $0.id != slotSession?.id }
    let kinds = rows.map {
      RowKind.kind(for: $0, store: store, ui: ui, density: settings.density)
    }
    let rowsHeight = measuredRows
      ?? RowKind.estimate(rows: rows, kinds: kinds, spacing: Self.spacing)
    let overflow = rowsHeight > rowsBudget + 0.5
    VStack(alignment: .leading, spacing: Self.spacing) {
      VStack(alignment: .leading, spacing: Self.spacing) {
        if !SummaryChips.isEmpty(store) {
          SummaryChips(store: store, actions: actions)
            .notchEnter(0)
        }
        if let hint = ui.focusHint {
          Label(hint, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.needs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .notchEnter(1)
        }
        if all.isEmpty {
          EmptyStateView().notchEnter(1)
        }
        // The selected card sits in a fixed slot: paging swaps the card in place, so the pager
        // and the buttons never move to another row under the pointer, and the card the
        // keyboard acts on is always on screen.
        if let card, let session = slotSession {
          SessionRow(
            session: session, kind: .card(card.id), store: store, ui: ui, actions: actions,
            title: store.displayName(for: session))
            .notchEnter(1)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
      if !rows.isEmpty {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.spacing) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { i, session in
                SessionRow(
                  session: session, kind: kinds[i], store: store, ui: ui, actions: actions,
                  title: store.displayName(for: session))
                  .notchEnter(min(i + 2, 8))
              }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredRows = $0 }
            // Lets the last row scroll clear of the fade.
            .padding(.bottom, overflow ? ScrollFade.height : 0)
          }
          .scrollIndicators(overflow ? .automatic : .never)
          .frame(height: min(rowsHeight, rowsBudget))
          .mask(ScrollFade(active: overflow))
          .onChange(of: ui.selectedSessionID) { _, id in
            guard let id, rows.contains(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, Self.topPadding)
    .padding(.bottom, Self.bottomPadding)
  }
}

/// Fades the last rows out when the list scrolls (there is more below).
struct ScrollFade: View {
  static let height: CGFloat = 18
  let active: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Short soft edge at the top so rows scrolled under the card do not end in a hard cut.
      LinearGradient(
        colors: [active ? .black.opacity(0.2) : .black, .black], startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 6)
      Color.black
      LinearGradient(
        colors: [.black, active ? .black.opacity(0.15) : .black], startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: Self.height)
    }
  }
}

/// How each row is drawn.
enum RowKind: Equatable {
  case card(PendingPermission.ID)
  case rich
  case compact

  /// Needs-you rows are rich; while the order is frozen (pointer over the list) a row keeps
  /// the shape it had at freeze time, so nothing grows or regroups under the pointer.
  @MainActor
  static func kind(
    for s: Session, store: SessionStore, ui: NotchUIState, density: Density
  ) -> RowKind {
    if density == .rich { return .rich }
    if let frozen = ui.frozenOrder, frozen.contains(s.id) {
      return ui.frozenRich.contains(s.id) ? .rich : .compact
    }
    return store.needsAttention(s) ? .rich : .compact
  }

  /// First-frame height guess for the rows, replaced by the measured one right after.
  static func estimate(rows: [Session], kinds: [RowKind], spacing: CGFloat) -> CGFloat {
    guard !rows.isEmpty else { return 0 }
    let total = zip(rows, kinds).reduce(CGFloat(0)) { sum, pair in
      switch pair.1 {
      case .compact: return sum + 30
      case .card: return sum + 236
      case .rich:
        switch pair.0.status {
        case .question: return sum + 122
        case .waitingInput, .planApproval: return sum + 76
        default: return sum + 62
        }
      }
    }
    return total + spacing * CGFloat(rows.count - 1)
  }

  /// The selected card, else the oldest one; none when the list was frozen without cards
  /// (a new card then only shows in the chips until the user asks for it).
  @MainActor
  static func slotCard(store: SessionStore, ui: NotchUIState) -> PendingPermission? {
    if let id = ui.selectedCardID, let card = store.card(id: id) { return card }
    if ui.frozenOrder != nil && ui.slotFrozenEmpty { return nil }
    return store.pending.first
  }
}

struct EmptyStateView: View {
  @Environment(\.notchTheme) private var theme

  var body: some View {
    VStack(spacing: 4) {
      Text("Etkin oturum yok")
        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.secondary)
      Text("Bir Claude Code oturumu başlattığınızda burada görünür.")
        .font(.system(size: 11)).foregroundStyle(theme.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
  }
}

// MARK: - Summary (body)

/// What the band chips do not say: questions, errors, unseen "done", and "Tümünü okundu say".
/// Hidden when there is none of it.
struct SummaryChips: View {
  let store: SessionStore
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  static func isEmpty(_ store: SessionStore) -> Bool {
    let s = NotchSignals(store: store)
    return s.questions == 0 && s.errorCount == 0 && store.doneUnseenCount == 0
  }

  var body: some View {
    let s = NotchSignals(store: store)
    HStack(spacing: 5) {
      if s.questions > 0 {
        Chip(text: "\(s.questions) yanıt bekliyor", color: theme.needs, solid: true)
      }
      if s.errorCount > 0 { Chip(text: "\(s.errorCount) hata", color: theme.error, solid: false) }
      if store.doneUnseenCount > 0 {
        Chip(text: "\(store.doneUnseenCount) bitti", color: theme.done, solid: false)
      }
      Spacer(minLength: 0)
      if store.doneUnseenCount + s.errorCount > 0 {
        Button(action: actions.markAllSeen) {
          Text("Tümünü okundu say")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .frame(height: 22)
    .padding(.horizontal, 4)
  }
}

struct Chip: View {
  let text: String
  let color: Color
  let solid: Bool
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(solid ? Color.black : color)
      .padding(.horizontal, 8)
      .frame(height: 20)
      .background(Capsule().fill(solid ? color : color.opacity(0.16)))
  }
}

// MARK: - Rows

struct SessionRow: View {
  let session: Session
  let kind: RowKind
  let store: SessionStore
  let ui: NotchUIState
  let actions: NotchActions
  let title: String
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  private var selected: Bool { ui.keyMode && ui.selectedSessionID == session.id }

  var body: some View {
    Group {
      switch kind {
      case .compact:
        header
          .padding(.horizontal, 8)
          .frame(height: 30)
          // Rows sit on a solid raised layer (never glass on glass).
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(hover || selected ? Color.white.opacity(0.05) : .clear)
              .allowsHitTesting(false))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(
                selected ? theme.secondary.opacity(0.5) : theme.hairline, lineWidth: 0.5))
      case .rich, .card:
        VStack(alignment: .leading, spacing: 8) {
          header.frame(height: 20)
          detail
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.raised))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? theme.secondary.opacity(0.5) : theme.hairline, lineWidth: 0.5)
        )
      }
    }
    .contentShape(Rectangle())
    .onHover { hover = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title), \(statusText)")
  }

  private var statusText: String {
    store.hasPending(for: session.id) ? "İzin istiyor" : session.status.label
  }

  /// Clicking the identity line jumps to the terminal.
  private var header: some View {
    HStack(spacing: 8) {
      StatusDot(session: session, pending: store.hasPending(for: session.id))
      HStack(spacing: 6) {
        Text(session.project)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .layoutPriority(2)
        if let d = store.secondaryText(for: session) {
          Text(d)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
        }
        if kind == .compact, let text = compactDetail {
          Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 4)
      if hover {
        RowActions(session: session, actions: actions)
          .transition(.opacity)
      } else {
        Elapsed(session: session)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { actions.focus(session.id) }
    .animation(.easeOut(duration: 0.12), value: hover)
  }

  private var compactDetail: String? {
    switch session.status {
    case .working(let tool):
      return session.activity ?? tool ?? "Düşünüyor…"
    case .quiet:
      return "Uzun süredir olay yok"
    case .idle:
      return session.isDiscovered ? "keşfedildi" : nil
    default:
      return session.status.detail.map { TextShortener.oneLine($0, limit: 80) }
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch kind {
    case .card(let id):
      if let card = store.card(id: id) {
        PermissionCardView(card: card, store: store, ui: ui, actions: actions)
      }
    default:
      RichDetail(session: session, store: store, actions: actions)
    }
  }
}

/// Second part of a rich row: the reason the session needs you, or what it is doing.
struct RichDetail: View {
  let session: Session
  let store: SessionStore
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  var body: some View {
    if let card = store.firstCard(for: session.id) {
      HStack(spacing: 8) {
        ToolIcon(tool: card.toolName).foregroundStyle(theme.needs)
        Text(TextShortener.oneLine(card.fullText, limit: 70))
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(theme.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        SmallButton(title: "Kartı göster", style: .secondary) { actions.selectCard(card.id) }
      }
    } else {
      switch session.status {
      case .question(let text, let options):
        QuestionDetail(text: text, options: options) { actions.focus(session.id) }
      case .planApproval(let summary):
        TerminalAsk(title: "Plan onayı bekliyor", text: summary) { actions.focus(session.id) }
      case .waitingInput(let message):
        TerminalAsk(title: "Girdi bekliyor", text: message) { actions.focus(session.id) }
      case .error(let message):
        Text(message)
          .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      case .done(let message):
        Text(message)
          .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      case .working(let tool):
        let agents = session.activeAgents.count
        HStack(spacing: 6) {
          Text(session.activity ?? tool ?? "Düşünüyor…")
            .font(.system(size: 11.5)).foregroundStyle(theme.secondary).lineLimit(1)
          if agents > 0 {
            Text("· \(agents) alt ajan").font(.system(size: 11)).foregroundStyle(theme.tertiary)
          }
        }
      case .quiet:
        Text("10 dakikadır olay gelmedi").font(.system(size: 11.5))
          .foregroundStyle(theme.tertiary)
      case .idle:
        Text(session.isDiscovered ? "Boşta · keşfedildi (hook olayı bekleniyor)" : "Boşta")
          .font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
      }
    }
  }
}

struct QuestionDetail: View {
  let text: String
  let options: [String]
  let goToTerminal: () -> Void
  @Environment(\.notchTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(theme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      if !options.isEmpty {
        HStack(spacing: 5) {
          ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { i, option in
            Text("\(i + 1)  \(option)")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(theme.secondary)
              .lineLimit(1)
              .padding(.horizontal, 8)
              .frame(height: 22)
              .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.faint))
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(theme.hairline, lineWidth: 0.5))
          }
          if options.count > 4 {
            Text("+\(options.count - 4)").font(.system(size: 11)).foregroundStyle(theme.tertiary)
          }
        }
      }
      HStack {
        Text("Yanıt terminalde verilir")
          .font(.system(size: 11)).foregroundStyle(theme.tertiary)
        Spacer()
        SmallButton(title: "Terminale git", style: .primary, action: goToTerminal)
      }
    }
  }
}

struct TerminalAsk: View {
  let title: String
  let text: String?
  let goToTerminal: () -> Void
  @Environment(\.notchTheme) private var theme

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.needs)
        if let text, !text.isEmpty {
          Text(text).font(.system(size: 11.5)).foregroundStyle(theme.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      SmallButton(title: "Terminale git", style: .primary, action: goToTerminal)
    }
  }
}

struct RowActions: View {
  let session: Session
  let actions: NotchActions

  private var message: String? {
    switch session.status {
    case .done(let m), .error(let m): return m
    default: return nil
    }
  }

  var body: some View {
    HStack(spacing: 2) {
      if let message, !message.isEmpty {
        RowIconButton(icon: "doc.on.doc", label: "Son mesajı kopyala") {
          actions.copyMessage(session.id)
        }
      }
      if session.unseen || session.status.kind == "waiting" {
        RowIconButton(icon: "checkmark", label: "Okundu") { actions.markSeen(session.id) }
      }
      RowIconButton(icon: "arrow.up.forward.app", label: "Odakla") { actions.focus(session.id) }
    }
  }
}

struct RowIconButton: View {
  let icon: String
  let label: String
  let action: () -> Void
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(hover ? theme.ink : theme.secondary)
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? theme.faint : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(label)
    .accessibilityLabel(label)
  }
}

struct StatusDot: View {
  let session: Session
  let pending: Bool
  @State private var shimmer = false
  @Environment(\.notchTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if pending || session.status.needsAttention && session.status.kind != "error" {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(theme.needs)
      } else {
        switch session.status {
        case .working:
          Circle().fill(theme.working)
            .frame(width: 7, height: 7)
            .opacity(shimmer ? 1 : 0.45)
            .onAppear {
              guard !reduceMotion else { return }
              withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
              }
            }
        case .done:
          Circle().fill(theme.done.opacity(session.unseen ? 1 : 0.45)).frame(width: 7, height: 7)
        case .error:
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.error.opacity(session.unseen ? 1 : 0.6))
        case .quiet:
          Circle().strokeBorder(theme.idle, lineWidth: 1.2).frame(width: 7, height: 7)
        default:
          Circle().fill(theme.idle).frame(width: 7, height: 7)
        }
      }
    }
    .frame(width: 12, height: 12)
  }
}

struct Elapsed: View {
  let session: Session
  @Environment(\.notchTheme) private var theme

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(text(now: context.date))
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(theme.tertiary)
    }
  }

  private func text(now: Date) -> String {
    if session.status.isWorking {
      return Self.duration(now.timeIntervalSince(session.turnStartedAt ?? session.statusSince))
    }
    let s = now.timeIntervalSince(session.statusSince)
    return s < 10 ? "şimdi" : Self.duration(s) + " önce"
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s) sn" }
    if s < 3600 {
      let m = s / 60
      let r = s % 60
      return m < 10 && r > 0 ? "\(m) dk \(r) sn" : "\(m) dk"
    }
    let h = s / 3600
    let m = (s % 3600) / 60
    return m > 0 ? "\(h) sa \(m) dk" : "\(h) sa"
  }
}

struct ToolIcon: View {
  let tool: String

  var body: some View {
    Image(systemName: Self.symbol(tool))
      .font(.system(size: 11, weight: .semibold))
      .frame(width: 14)
  }

  static func symbol(_ tool: String) -> String {
    switch tool {
    case "Bash": return "terminal"
    case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
    case "Write": return "doc.badge.plus"
    case "Read": return "doc.text"
    case "WebFetch", "WebSearch": return "globe"
    default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
    }
  }
}
