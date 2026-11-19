import AppKit
import ClaudeNotchCore
import SwiftUI

// MARK: - Toolbar (takes over the menu-bar band while the panel is open)

/// Symmetric band row: controls left of the notch (pin, settings, Ghostty consent when it is
/// missing), status chips right of it. Only while the user opened the panel.
struct ExpandedToolbar: View {
  let store: SessionStore
  let ui: NotchUIState
  let settings: NotchSettings
  let modules: ModuleCenter
  let actions: NotchActions
  let notchWidth: CGFloat
  let sideWidth: CGFloat
  @Environment(\.notchTheme) private var theme

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 2) {
        BandIconButton(
          icon: ui.pinned ? "pin.fill" : "pin",
          label: ui.pinned ? loc("Unpin") : loc("Pin"), active: ui.pinned,
          action: actions.togglePin)
        BandIconButton(
          icon: "gearshape", label: loc("Settings"), active: false, action: actions.openSettings)
        BandIconButton(
          icon: settings.silentMode ? "bell.slash.fill" : "bell",
          label: settings.silentMode
            ? loc("Silent mode is on: only permission requests and questions") : loc("Turn on silent mode"),
          active: settings.silentMode,
          tint: settings.silentMode ? theme.needs : nil
        ) { settings.silentMode.toggle() }
        if settings.timerEnabled, case .idle = modules.timer.state, modules.timerDraft == nil {
          TimerStartMenu(modules: modules, settings: settings)
        }
        if ui.ghosttyConsent.missing {
          BandIconButton(
            icon: "lock.shield", label: consentLabel, active: false, tint: theme.needs,
            action: actions.ghosttyConsent)
        }
        Spacer(minLength: 0)
        if settings.weatherEnabled, let w = modules.weather.now {
          BandWeather(weather: w).padding(.trailing, 12)
        }
      }
      .padding(.leading, 10)
      .frame(width: sideWidth)
      .notchEnter(0)
      Color.clear.frame(width: notchWidth)
      HStack(spacing: 8) {
        if settings.usageEnabled, let u = modules.usage.usage?.live(at: Date()), u.primary != nil {
          BandUsage(usage: u)
        }
        BandChips(store: store, actions: actions)
      }
        .padding(.trailing, 12)
        .frame(width: sideWidth, alignment: .trailing)
        .notchEnter(0)
    }
  }

  private var consentLabel: String {
    ui.ghosttyConsent == .denied
      ? loc("Ghostty permission is off: turn it on in System Settings")
      : loc("Ghostty permission: allow switching to its tabs")
  }
}

/// "N permissions" (shows the oldest card) and "N working", in the band.
struct BandChips: View {
  let store: SessionStore
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  var body: some View {
    HStack(spacing: 5) {
      Spacer(minLength: 0)
      if !store.pending.isEmpty {
        Button(action: actions.showCards) {
          BandChip(text: loc("\(store.pending.count) permissions"), color: theme.needs, solid: true)
        }
        .buttonStyle(.plain)
        .help("Show the oldest request")
      }
      if store.activeWorkingCount > 0 {
        BandChip(
          text: loc("\(store.activeWorkingCount) working"), color: theme.working,
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
      .foregroundStyle(solid ? NotchTheme.onStatus : color)
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
  let modules: ModuleCenter
  let actions: NotchActions
  /// Height of the black band above (notch height).
  let bandHeight: CGFloat
  @State private var topHeight: CGFloat = 0
  /// Height of the module tiles under the rows (0 when none show).
  @State private var stripHeight: CGFloat = 0
  /// Height of the "Hidden" line under the rows (0 when no chat is hidden).
  @State private var hiddenHeight: CGFloat = 0
  /// Measured natural height of the rows (nil until the first layout; an estimate is used
  /// meanwhile: a zero-height ScrollView would never lay out its content to report a size).
  @State private var measuredRows: CGFloat?
  /// The row being dragged to a new place (see `rowDrag(for:rows:)`).
  @State private var drag: RowDragState?
  /// Each row's place in the list (`rowSpace`), measured before any drag offset.
  @State private var rowSpans: [String: RowReorder.Span] = [:]
  @Environment(\.notchTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let spacing: CGFloat = 6
  static let topPadding: CGFloat = 4
  static let bottomPadding: CGFloat = 12
  /// The rows' coordinate space (drag translation and row places).
  nonisolated static let rowSpace = "panelRows"
  /// How far the pointer moves before a press on a row becomes a drag (a click jumps).
  nonisolated static let dragThreshold: CGFloat = 6

  /// A row on its way to a new place: its group (pinned rows, or the others) as it was when
  /// the drag started, where it started and where it would land now.
  struct RowDragState: Equatable {
    var id: String
    var group: [String]
    var start: Int
    var target: Int
    var translation: CGFloat
    /// The rows' places when the drag started. Measured places move with the rows' offsets
    /// (`frame(in:)` counts the offset around a row), so during the drag only this copy is
    /// used: the live ones would count the dragged row's own movement twice.
    var spans: [String: RowReorder.Span]
  }

  private var sessions: [Session] {
    let live = store.panelOrder
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
    let strip = stripHeight > 0 ? stripHeight + Self.spacing : 0
    let hidden = hiddenHeight > 0 ? hiddenHeight + Self.spacing : 0
    return max(
      44,
      body - topHeight - strip - hidden - Self.spacing - Self.topPadding - Self.bottomPadding)
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
        // Only hidden chats left: the "Hidden" line says so, not "No active sessions".
        if all.isEmpty && store.hiddenSessions.isEmpty {
          EmptyStateView().notchEnter(1)
        }
        // The selected card sits in a fixed slot: paging swaps the card in place, so the pager
        // and the buttons never move to another row under the pointer, and the card the
        // keyboard acts on is always on screen.
        if let card, let session = slotSession {
          SessionRow(
            session: session, kind: .card(card.id), store: store, ui: ui, actions: actions,
            title: store.chatLabel(for: session),
            contextLeft: modules.usage.contextLeft[session.id], pinned: store.isPinned(session.id))
            .notchEnter(1)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
      if !rows.isEmpty {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.spacing) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { i, session in
                let dragged = drag?.id == session.id
                let offset = rowOffset(session.id)
                SessionRow(
                  session: session, kind: kinds[i], store: store, ui: ui, actions: actions,
                  title: store.chatLabel(for: session),
                  contextLeft: modules.usage.contextLeft[session.id],
                  pinned: store.isPinned(session.id), lifted: dragged)
                  .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.rowSpace))
                  } action: { frame in
                    // Only between drags: during one the frames carry the drag's offsets.
                    guard drag == nil else { return }
                    rowSpans[session.id] = RowReorder.Span(
                      top: Double(frame.minY), bottom: Double(frame.maxY))
                  }
                  .offset(y: offset)
                  // The dragged row is glued to the pointer (1:1, never animated); the others
                  // slide out of its way with a spring that re-targets as it moves.
                  .animation(dragged || reduceMotion ? nil : Motion.rowShift, value: offset)
                  .zIndex(dragged ? 1 : 0)
                  .simultaneousGesture(
                    rowDrag(for: session, rows: rows),
                    including: kinds[i] == .compact || kinds[i] == .rich ? .all : .subviews)
                  .notchEnter(min(i + 2, 8))
              }
            }
            .coordinateSpace(.named(Self.rowSpace))
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
      if !store.hiddenSessions.isEmpty {
        HiddenChatsLine(store: store, actions: actions)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hiddenHeight = $0 }
          .onDisappear { hiddenHeight = 0 }
          .transition(.opacity)
      }
      ModuleStrip(modules: modules, settings: settings, ui: ui)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
    }
    .padding(.horizontal, 10)
    .padding(.top, Self.topPadding)
    .padding(.bottom, Self.bottomPadding)
    .dropDestination(for: URL.self) { urls, _ in
      guard settings.shelfEnabled else { return false }
      modules.shelf.addFiles(urls)
      return !urls.isEmpty
    }
  }
}

// MARK: - Dragging a row to a new place

extension ExpandedBody {
  /// The rows of `id`'s group, top first: the pinned rows, or the others (a row never leaves
  /// its group by a drag; the pin button moves it between them).
  private func group(of id: String, rows: [Session]) -> [String] {
    let pinned = store.isPinned(id)
    return rows.filter { store.isPinned($0.id) == pinned }.map(\.id)
  }

  /// How far the row is moved from its place: the drag itself for the dragged row, the gap
  /// it opens for the rows it passed.
  fileprivate func rowOffset(_ id: String) -> CGFloat {
    guard let drag else { return 0 }
    if id == drag.id { return drag.translation }
    let height = drag.spans[drag.id]?.height ?? Double(SessionRow.compactHeight)
    return CGFloat(RowReorder.shift(
      of: id, dragged: drag.id, group: drag.group, target: drag.target, height: height,
      spacing: Double(Self.spacing)))
  }

  /// Press and move a row past `dragThreshold` to drag it; let go to drop it there. A press
  /// that does not move stays a click (the row's own tap jumps to the terminal).
  fileprivate func rowDrag(for session: Session, rows: [Session]) -> some Gesture {
    DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.rowSpace))
      .onChanged { value in
        if drag == nil {
          let group = group(of: session.id, rows: rows)
          // A group of one has nowhere to go.
          guard group.count > 1, let start = group.firstIndex(of: session.id) else { return }
          actions.rowDrag(session.id)
          withAnimation(reduceMotion ? nil : Motion.rowLift) {
            drag = RowDragState(
              id: session.id, group: group, start: start, target: start, translation: 0,
              spans: rowSpans)
          }
        }
        guard var d = drag, d.id == session.id else { return }
        let t = RowReorder.resisted(
          translation: Double(value.translation.height), dragged: d.id, group: d.group,
          spans: d.spans)
        d.translation = CGFloat(t)
        d.target = RowReorder.target(
          dragged: d.id, group: d.group, spans: d.spans, translation: t)
        drag = d
      }
      .onEnded { _ in
        guard let d = drag, d.id == session.id else { return }
        // The row settles into its new place from where the pointer left it; the others
        // close the gap in the same spring.
        withAnimation(reduceMotion ? nil : Motion.rowShift) {
          if d.target != d.start {
            actions.reorderChats(RowReorder.moved(d.group, dragged: d.id, to: d.target))
          }
          drag = nil
        }
        actions.rowDrag(nil)
      }
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
      case .compact: return sum + SessionRow.compactHeight
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
      Text("No active sessions")
        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.secondary)
      Text("Start a Claude Code session and it shows up here.")
        .font(.system(size: 11)).foregroundStyle(theme.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
  }
}

// MARK: - Summary (body)

/// What the band chips do not say: questions, errors, unseen "done", and "Mark all as read".
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
        Chip(text: loc("\(s.questions) awaiting reply"), color: theme.needs, solid: true)
      }
      if s.errorCount > 0 { Chip(text: loc("\(s.errorCount) errors"), color: theme.error, solid: false) }
      if store.doneUnseenCount > 0 {
        Chip(text: loc("\(store.doneUnseenCount) done"), color: theme.done, solid: false)
      }
      Spacer(minLength: 0)
      if store.doneUnseenCount + s.errorCount > 0 {
        Button(action: actions.markAllSeen) {
          Text("Mark all as read")
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
      .foregroundStyle(solid ? NotchTheme.onStatus : color)
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
  /// Context window left (from the status line bridge); shown from 25 % down.
  var contextLeft: Double?
  /// Pinned to the top of the panel (a pin beside the title).
  var pinned = false
  /// Being dragged to a new place: lifted off the list.
  var lifted = false
  @State private var hover = false
  @State private var dropTarget = false
  @Environment(\.notchTheme) private var theme

  private var selected: Bool { ui.keyMode && ui.selectedSessionID == session.id }

  /// Hover swaps the time for the row's buttons only when there is one to show (the row itself
  /// jumps to the terminal, so a chat that is asking may have none).
  private var hasRowActions: Bool {
    RowActions.hasAny(session: session, canHide: store.canHide(session))
  }

  /// The whole row is a jump target (see the tap gesture in `body`).
  private var rowJumps: Bool {
    switch kind {
    case .card: return false
    case .compact, .rich:
      return !store.hasPending(for: session.id) && store.question(for: session.id) == nil
    }
  }

  var body: some View {
    Group {
      switch kind {
      case .compact:
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            header(trailing: false)
            statusLine.padding(.leading, 20)
            RhythmStrip(
              rhythm: session.rhythm, color: tickColor, live: session.status.isWorking,
              frozenAt: session.statusSince)
            .padding(.leading, 20)
          }
          Group {
            if hover && hasRowActions {
              RowActions(
                session: session, actions: actions, canHide: store.canHide(session), pinned: pinned)
                .transition(.opacity)
            } else {
              DotElapsed(mode: elapsedMode, color: elapsedColor)
            }
          }
          .animation(.easeOut(duration: 0.12), value: hover)
        }
        .padding(.horizontal, 8)
        .padding(.trailing, 4)
        .frame(height: Self.compactHeight)
        .background(card(radius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover || selected ? Color.white.opacity(0.05) : .clear)
            .allowsHitTesting(false))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
              selected ? theme.secondary.opacity(0.5) : theme.hairline, lineWidth: 0.5))
      case .rich, .card:
        VStack(alignment: .leading, spacing: 8) {
          header(trailing: true).frame(height: 20)
          detail
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(card(radius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? theme.secondary.opacity(0.5) : theme.hairline, lineWidth: 0.5)
        )
      }
    }
    .contentShape(Rectangle())
    // A click anywhere on the row jumps to its terminal tab (the buttons inside keep their own
    // action). Not the body of a permission card or of a question answered here: a click that
    // misses one of their buttons must not leave for the terminal. Their title line still
    // jumps, as it always did (`header`).
    .gesture(TapGesture().onEnded { actions.focus(session.id) }, including: rowJumps ? .all : .subviews)
    .onHover { hover = $0 }
    // A shelf chip dropped here: copied, and this session's tab comes forward (⌃V pastes it).
    .onDrop(of: [.item], isTargeted: $dropTarget) { _ in actions.dropShelf(session.id) }
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color(hex: 0xC3A8FF), lineWidth: dropTarget ? 1.5 : 0)
        .allowsHitTesting(false))
    .overlay(alignment: .bottomTrailing) {
      if dropTarget {
        Text("drop: copy and go to the tab · ⌃V")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color(hex: 0xC3A8FF))
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title), \(statusText)")
    // The row itself is the way to its terminal (a click anywhere, or the title line of a card);
    // VoiceOver gets the same jump as the row's action.
    .accessibilityAction(named: Text("Focus")) { actions.focus(session.id) }
    .accessibilityAction(named: Text(pinned ? loc("Unpin") : loc("Pin to the top"))) {
      actions.togglePinChat(session.id)
    }
    // Lifted while dragged: a touch larger, with a shadow under it, so it reads as held above
    // the rows that make room for it.
    .scaleEffect(lifted ? 1.02 : 1)
    .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
  }

  nonisolated static let compactHeight: CGFloat = 62

  /// Solid card on the black body with the status colour glowing in from one corner.
  private func card(radius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape.fill(theme.raised)
      .overlay(CornerGlow(color: glowColor))
      .clipShape(shape)
  }

  /// The row's colors follow its segment of the status line under the notch
  /// (`SessionStore.lineState`): a finished or failed chat is blue / red until it is seen, then
  /// plain like an idle one, on the line and in the panel alike.
  private var lineState: LineState { store.lineState(of: session) }

  /// Idle (and seen) rows stay plain.
  private var glowColor: Color? {
    lineState == .idle ? nil : statusColor
  }

  /// Idle (and seen) rows keep their last turn's rhythm, muted.
  private var tickColor: Color { statusColor }

  /// Working: how long this turn has been running. Needs you: how long it has waited.
  /// Done / error: how long the turn took (frozen). Idle: how long since anything happened.
  private var elapsedMode: DotElapsed.Mode {
    if store.hasPending(for: session.id) { return .live(since: session.statusSince) }
    switch session.status {
    case .working:
      return .live(since: session.turnStartedAt ?? session.statusSince)
    case .waitingInput, .question, .planApproval:
      return .live(since: session.statusSince)
    case .done, .error:
      if let start = session.turnStartedAt, start <= session.statusSince {
        return .fixed(session.statusSince.timeIntervalSince(start))
      }
      return .coarse(since: session.statusSince)
    case .idle, .quiet:
      return .coarse(since: session.statusSince)
    }
  }

  private var elapsedColor: Color { statusColor }

  private var statusText: String {
    store.hasPending(for: session.id) ? loc("Asks for permission") : session.status.label
  }

  /// Clicking the identity line jumps to the terminal. Compact rows draw their own trailing
  /// part (the dot-matrix time spans both lines).
  private func header(trailing: Bool) -> some View {
    HStack(spacing: 8) {
      StatusDot(session: session, state: lineState)
      // The chat's title leads, the project follows in grey (`SessionStore.rowNames`).
      let names = store.rowNames(for: session)
      HStack(spacing: 6) {
        Text(names.primary)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(2)
        if let d = names.secondary {
          Text(d)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
        }
        if pinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.tertiary)
            .rotationEffect(.degrees(45))
            .help("Pinned to the top")
            .accessibilityLabel("Pinned")
        }
      }
      Spacer(minLength: 4)
      if let left = contextLeft, left <= ContextLeft.showMark {
        Text("context \(Int(left.rounded()))%")
          .font(.system(size: 10, weight: .semibold)).monospacedDigit()
          .foregroundStyle(left <= ContextLeft.alertMark ? theme.error : theme.needs)
          .padding(.horizontal, 6)
          .frame(height: 16)
          .background(
            Capsule().fill(
              (left <= ContextLeft.alertMark ? theme.error : theme.needs).opacity(0.15)))
          .fixedSize()
          .help("\(Int(left.rounded()))% of the context window left")
      }
      if trailing {
        if hover && hasRowActions {
          RowActions(
                session: session, actions: actions, canHide: store.canHide(session), pinned: pinned)
            .transition(.opacity)
        } else {
          Elapsed(session: session)
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { actions.focus(session.id) }
    .animation(.easeOut(duration: 0.12), value: hover)
  }

  /// Second line of a compact row: an explicit, colored status label plus what it refers to.
  private var statusLine: some View {
    HStack(spacing: 0) {
      Text(statusText)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(statusColor)
      if let text = compactDetail {
        Text("  ·  " + text)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
  }

  private var statusColor: Color {
    switch lineState {
    case .needs: return theme.needs
    case .working: return theme.working
    case .done: return theme.done
    case .error: return theme.error
    case .idle: return theme.tertiary
    }
  }

  private var compactDetail: String? {
    if let card = store.firstCard(for: session.id) {
      return TextShortener.oneLine(card.fullText, limit: 80)
    }
    switch session.status {
    case .working(let tool):
      return session.activity ?? tool ?? loc("Thinking…")
    case .quiet:
      return loc("No events for 10 minutes")
    case .idle:
      return nil
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
      RichDetail(session: session, store: store, ui: ui, actions: actions)
    }
  }
}

/// Second part of a rich row: the reason the session needs you, or what it is doing.
struct RichDetail: View {
  let session: Session
  let store: SessionStore
  let ui: NotchUIState
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
        SmallButton(title: loc("Show card"), style: .secondary) { actions.selectCard(card.id) }
      }
    } else {
      switch session.status {
      case .question(let text, let options):
        if let held = store.question(for: session.id) {
          QuestionAnswerView(question: held, ui: ui, actions: actions)
        } else {
          QuestionDetail(text: text, options: options) { actions.focus(session.id) }
        }
      case .planApproval(let summary):
        TerminalAsk(title: loc("Waiting for plan approval"), text: summary) { actions.focus(session.id) }
      case .waitingInput(let message):
        TerminalAsk(title: loc("Waiting for input"), text: message) { actions.focus(session.id) }
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
          Text(session.activity ?? tool ?? loc("Thinking…"))
            .font(.system(size: 11.5)).foregroundStyle(theme.secondary).lineLimit(1)
          if agents > 0 {
            Text("· \(agents) subagents").font(.system(size: 11)).foregroundStyle(theme.tertiary)
          }
        }
      case .quiet:
        Text("No events came in for 10 minutes").font(.system(size: 11.5))
          .foregroundStyle(theme.tertiary)
      case .idle:
        Text("Idle")
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
        Text("Answer in the terminal")
          .font(.system(size: 11)).foregroundStyle(theme.tertiary)
        Spacer()
        SmallButton(title: loc("Go to terminal"), style: .primary, action: goToTerminal)
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
      SmallButton(title: loc("Go to terminal"), style: .primary, action: goToTerminal)
    }
  }
}

struct RowActions: View {
  let session: Session
  let actions: NotchActions
  /// Offer "Hide" (never while the chat needs the user, see `SessionStore.canHide`).
  var canHide = false
  /// The chat is pinned: the pin button unpins it.
  var pinned = false

  private static func marksRead(_ s: Session) -> Bool {
    s.unseen || s.status.kind == "waiting"
  }

  /// Whether the row has any of these buttons (there is no "go to the chat" button: the row
  /// itself does that). Every row can be pinned, so there always is one.
  static func hasAny(session s: Session, canHide: Bool) -> Bool { true }

  var body: some View {
    HStack(spacing: 2) {
      if Self.marksRead(session) {
        RowIconButton(icon: "checkmark", label: loc("Mark as read")) { actions.markSeen(session.id) }
      }
      RowIconButton(
        icon: pinned ? "pin.slash" : "pin",
        label: pinned ? loc("Unpin") : loc("Pin to the top")
      ) {
        actions.togglePinChat(session.id)
      }
      // An eye crossed out, not a cross: the chat is only out of sight, its terminal and its
      // process stay (a cross would read as closing it).
      if canHide {
        RowIconButton(icon: "eye.slash", label: loc("Hide until it does something new")) {
          actions.hide(session.id)
        }
      }
    }
  }
}

/// Under the rows while chats are hidden: "Hidden" and each hidden chat by its title (a click
/// brings that one back), then "Show all".
struct HiddenChatsLine: View {
  let store: SessionStore
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  /// Chips shown by title; more are counted ("+2").
  static let maxChips = 3

  var body: some View {
    let hidden = store.hiddenSessions
    HStack(spacing: 6) {
      Image(systemName: "eye.slash")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(theme.tertiary)
      Text("Hidden")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.tertiary)
        .fixedSize()
      ForEach(hidden.prefix(Self.maxChips)) { s in
        HiddenChip(names: store.rowNames(for: s), label: store.chatLabel(for: s)) {
          actions.unhide(s.id)
        }
      }
      if hidden.count > Self.maxChips {
        Text("+\(hidden.count - Self.maxChips)")
          .font(.system(size: 11, weight: .medium)).monospacedDigit()
          .foregroundStyle(theme.tertiary)
          .fixedSize()
      }
      Spacer(minLength: 4)
      Button(action: actions.unhideAll) {
        Text("Show all")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(theme.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fixedSize()
    }
    .frame(height: 22)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(loc("Hidden chats"))
  }
}

/// One hidden chat in the "Hidden" line: its title, the project after it in grey (as on the
/// row); a click shows it again.
struct HiddenChip: View {
  let names: (primary: String, secondary: String?)
  let label: String
  let action: () -> Void
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(names.primary)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(hover ? theme.ink : theme.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
        if let second = names.secondary {
          Text(second)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
            .fixedSize()
        }
      }
        .padding(.horizontal, 7)
        .frame(maxWidth: 170, minHeight: 20, maxHeight: 20)
        .background(Capsule().fill(hover ? theme.faint : theme.faint.opacity(0.6)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(loc("Show this chat again"))
    .accessibilityLabel(loc("Show \(label) again"))
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

/// The row's status sign, colored by its status line segment (`state`): a seen finished chat
/// gets the idle dot, a seen error keeps its × shape in the idle grey.
struct StatusDot: View {
  let session: Session
  let state: LineState
  @Environment(\.notchTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      switch state {
      case .needs:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(theme.needs)
      case .working:
        // Core Animation runs the pulse in the render server: a SwiftUI repeatForever here
        // redrew the panel every frame (~2% CPU while open, measured).
        PulseDot(color: NSColor(theme.working), pulsing: !reduceMotion)
          .frame(width: 7, height: 7)
      case .done:
        Circle().fill(theme.done).frame(width: 7, height: 7)
      case .error:
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(theme.error)
      case .idle:
        switch session.status {
        case .error:
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.idle)
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

  /// Time since the current status began (for work: since the turn started), one format.
  private func text(now: Date) -> String {
    let since = session.status.isWorking
      ? (session.turnStartedAt ?? session.statusSince) : session.statusSince
    return RelativeTime.short(now.timeIntervalSince(since))
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

/// A dot whose opacity breathes 0.45 ↔ 1 on a CALayer animation (no SwiftUI frames).
struct PulseDot: NSViewRepresentable {
  let color: NSColor
  let pulsing: Bool

  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let dot = CALayer()
    dot.name = "dot"
    v.layer?.addSublayer(dot)
    return v
  }

  func updateNSView(_ v: NSView, context: Context) {
    guard let dot = v.layer?.sublayers?.first(where: { $0.name == "dot" }) else { return }
    dot.frame = CGRect(x: 0, y: 0, width: 7, height: 7)
    dot.cornerRadius = 3.5
    dot.backgroundColor = color.cgColor
    if pulsing, dot.animation(forKey: "pulse") == nil {
      let a = CABasicAnimation(keyPath: "opacity")
      a.fromValue = 0.45
      a.toValue = 1
      a.duration = 0.9
      a.autoreverses = true
      a.repeatCount = .infinity
      a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dot.add(a, forKey: "pulse")
    } else if !pulsing {
      dot.removeAnimation(forKey: "pulse")
    }
  }
}
