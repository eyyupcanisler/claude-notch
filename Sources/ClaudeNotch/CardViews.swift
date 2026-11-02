import AppKit
import ClaudeNotchCore
import SwiftUI

/// Hook timeout is 600 s; Claude Code gives up a little earlier.
let permissionTimeout: TimeInterval = 590

@MainActor
struct CardGate {
  let card: PendingPermission
  let store: SessionStore
  let ui: NotchUIState

  /// Reads `ui.tick` so the view refreshes when the card becomes clickable.
  var armed: Bool {
    _ = ui.tick
    return store.isArmed(card) && Date() >= ui.pagerArmedAt
  }

  var opened: Bool { ui.openedCards.contains(card.id) }
  /// The opened text was scrolled down to its end.
  var read: Bool { opened && ui.readToEnd.contains(card.id) }
  /// A long request is allowed only after its whole text was on screen.
  var canAllow: Bool { armed && (!card.needsExpansion || read) }
  /// "Her zaman" also waits until its whole rule has been on screen, and a moment more.
  var ruleRead: Bool { ui.moreCardID == card.id && ui.ruleRead.contains(card.id) }
  var canAlways: Bool {
    canAllow && card.alwaysDescription != nil && ruleRead && Date() >= ui.moreArmedAt
  }
  /// Classified from the raw command when the card was created (not the display text).
  var risk: String? { card.risk }
}

// MARK: - Inline card

struct PermissionCardView: View {
  let card: PendingPermission
  let store: SessionStore
  let ui: NotchUIState
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  private var gate: CardGate { CardGate(card: card, store: store, ui: ui) }

  private var detailTitle: String {
    if gate.opened { return "Daralt" }
    return card.needsExpansion
      ? "Tümünü göster (\(fullBody.count) karakter)" : "Ayrıntıyı göster"
  }

  private var fullBody: String {
    guard let extra = card.extra else { return card.fullText }
    return card.fullText + "\n" + extra
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      code
      if card.hasMore {
        Button { actions.toggleDetail(card.id) } label: {
          HStack(spacing: 4) {
            Image(systemName: gate.opened ? "chevron.up" : "chevron.down")
              .font(.system(size: 8.5, weight: .bold))
            Text(detailTitle).font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(card.needsExpansion && !gate.opened ? theme.needs : theme.tertiary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      if let risk = gate.risk {
        RiskTag(reason: risk, allowKey: ui.allowKey)
      }
      buttons
      if ui.moreCardID == card.id {
        MoreSection(card: card, gate: gate, ui: ui, actions: actions)
          .transition(.opacity)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      ToolIcon(tool: card.toolName).foregroundStyle(theme.needs)
      Text(card.toolName)
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink)
      Text(card.agentID == nil ? "izin istiyor" : "alt ajan izin istiyor")
        .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
      Spacer(minLength: 4)
      if let pos = store.queuePosition(of: card.id), pos.total > 1 {
        CardPager(index: pos.index, total: pos.total, actions: actions)
      }
      CountdownRing(createdAt: card.createdAt)
    }
  }

  @ViewBuilder
  private var code: some View {
    let collapsed = card.fullText.isEmpty ? "(ayrıntı yok)" : card.collapsedText
    let text = gate.opened ? fullBody : collapsed
    Group {
      if gate.opened {
        DetailText(
          text: text, color: NSColor(theme.ink.opacity(0.92)), maxHeight: 150,
          page: ui.detailPage[card.id] ?? 0
        ) { [actions, id = card.id] trigger in actions.readToEnd(id, trigger) }
      } else {
        Text(text).lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.system(size: 11.5, design: .monospaced))
    .foregroundStyle(theme.ink.opacity(0.92))
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.faint))
  }

  private var buttons: some View {
    HStack(spacing: 6) {
      ActionButton(
        title: "Reddet", style: .secondary, keycap: ui.keyMode ? "⌘⌫" : ui.denyKey,
        enabled: gate.armed
      ) {
        actions.decide(card.id, .deny(message: PermissionDecision.defaultDenyMessage), .click)
      }
      if card.needsExpansion && !gate.read {
        Text(gate.opened
          ? (ui.keyMode ? "Sonuna kadar kaydırın · Boşluk" : "Sonuna kadar kaydırın")
          : "Önce tümünü göster")
          .font(.system(size: 11)).foregroundStyle(theme.needs)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      MoreButton(open: ui.moreCardID == card.id) { actions.toggleMore(card.id) }
      AllowButton(
        card: card, gate: gate, ui: ui, decision: .allow, title: "İzin ver",
        keycap: ui.keyMode ? "⌘⏎" : ui.allowKey, source: .click, actions: actions)
    }
  }
}

struct CardPager: View {
  let index: Int
  let total: Int
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  var body: some View {
    HStack(spacing: 0) {
      pagerButton("chevron.left", "Önceki istek") { actions.pager(-1) }
      Text("\(index + 1)/\(total)")
        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        .foregroundStyle(theme.secondary)
        .frame(minWidth: 26)
      pagerButton("chevron.right", "Sonraki istek") { actions.pager(1) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("İstek \(index + 1) / \(total)")
  }

  private func pagerButton(_ icon: String, _ label: String, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(theme.secondary)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// Ring that empties towards the hook timeout.
struct CountdownRing: View {
  let createdAt: Date
  /// Peek: the time only in the last two minutes (the ring alone says the rest).
  var compact = false
  @Environment(\.notchTheme) private var theme

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = max(0, permissionTimeout - context.date.timeIntervalSince(createdAt))
      let urgent = left < 60
      HStack(spacing: 4) {
        if !compact || left < 120 {
          Text(left < 120
          ? String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
          : "\(Int(left / 60)) dk")
          .font(.system(size: 11, weight: .medium)).monospacedDigit()
          .foregroundStyle(urgent ? theme.needs : theme.tertiary)
        }
        ZStack {
          Circle().stroke(theme.hairline, lineWidth: 1.5)
          Circle()
            .trim(from: 0, to: left / permissionTimeout)
            .stroke(
              urgent ? theme.needs : theme.tertiary,
              style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .scaleEffect(x: -1)
        }
        .frame(width: 11, height: 11)
      }
      .help("Yanıt için kalan süre: \(Int(left) / 60) dk \(Int(left) % 60) sn")
      .accessibilityLabel("Kalan süre \(Int(left) / 60) dakika")
    }
  }
}

struct RiskTag: View {
  let reason: String
  var allowKey: String?
  @Environment(\.notchTheme) private var theme

  private var holdText: String {
    allowKey.map { "· basılı tutun (fare ya da \($0)) ya da ⌘⏎" } ?? "· basılı tutun ya da ⌘⏎"
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5, weight: .bold))
      Text("Riskli komut: \(reason)").font(.system(size: 11, weight: .semibold))
      Text(holdText).font(.system(size: 11)).opacity(0.8)
    }
    .foregroundStyle(theme.error)
    .lineLimit(1)
  }
}

/// "Her zaman" lives here, with the full rule it would add.
struct MoreSection: View {
  let card: PendingPermission
  let gate: CardGate
  let ui: NotchUIState
  let actions: NotchActions
  @Environment(\.notchTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Rectangle().fill(theme.hairline).frame(height: 0.5)
      if let rule = card.alwaysDescription {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Her zaman izin ver")
              .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.ink)
            Text(ruleCaption)
              .font(.system(size: 11))
              .foregroundStyle(gate.ruleRead ? theme.tertiary : theme.needs)
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          AllowButton(
            card: card, gate: gate, ui: ui, decision: .always, title: "Her zaman",
            keycap: ui.keyMode ? "⌘⇧⏎" : nil, source: .click, actions: actions, primary: false)
        }
        // The whole rule, never shortened: what is shown is what gets saved. A rule longer
        // than four lines scrolls, and "Her zaman" waits until its end was on screen.
        DetailText(
          text: rule, color: NSColor(theme.secondary), maxHeight: Self.ruleMaxHeight,
          page: ui.rulePage[card.id] ?? 0, font: Self.ruleFont
        ) { [actions, id = card.id] trigger in actions.ruleRead(id, trigger) }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.faint))
          .accessibilityLabel("Eklenecek kural: \(rule)")
      } else {
        Text("Bu istek için kalıcı kural önerisi yok.")
          .font(.system(size: 11)).foregroundStyle(theme.tertiary)
      }
      if store(card).count > 1 {
        Button { actions.denyAll(card.sessionID) } label: {
          Text("Bu oturumdaki \(store(card).count) isteğin tümünü reddet")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.error)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!gate.armed)
      }
    }
  }

  private func store(_ card: PendingPermission) -> [PendingPermission] {
    gate.store.cards(for: card.sessionID)
  }

  static let ruleFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  static let ruleMaxHeight = DetailText.height(lines: 4, font: ruleFont)

  private var ruleCaption: String {
    if gate.ruleRead { return "Bu kural kalıcı olarak eklenir" }
    return ui.keyMode ? "Kuralı sonuna kadar kaydırın · Boşluk" : "Kuralı sonuna kadar kaydırın"
  }
}

struct MoreButton: View {
  let open: Bool
  let action: () -> Void
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Button(action: action) {
      Image(systemName: "ellipsis")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(open ? theme.ink : theme.secondary)
        .frame(width: 28, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(open ? theme.faint.opacity(2) : theme.faint))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Diğer seçenekler: Her zaman")
    .accessibilityLabel("Diğer seçenekler")
  }
}

// MARK: - Buttons

enum ButtonTone {
  case primary
  case secondary
}

struct ActionButton: View {
  let title: String
  let style: ButtonTone
  var keycap: String?
  let enabled: Bool
  var compact = false
  let action: () -> Void
  @State private var hover = false
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title).font(.system(size: compact ? 11.5 : 12, weight: .semibold))
        if let keycap { Keycap(text: keycap, onPrimary: style == .primary) }
      }
      .foregroundStyle(style == .primary ? theme.primaryText : theme.ink)
      .padding(.horizontal, compact ? 10 : 12)
      .frame(height: compact ? 24 : 26)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(style == .primary ? theme.primaryFill : theme.faint)
          .brightness(hover && enabled ? 0.06 : 0))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(style == .primary ? .clear : theme.hairline, lineWidth: 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(PressScale())
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.38)
    .onHover { hover = $0 }
  }
}

struct SmallButton: View {
  let title: String
  let style: ButtonTone
  let action: () -> Void

  var body: some View {
    ActionButton(title: title, style: style, enabled: true, compact: true, action: action)
  }
}

struct Keycap: View {
  let text: String
  let onPrimary: Bool
  @Environment(\.notchTheme) private var theme

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle((onPrimary ? theme.primaryText : theme.ink).opacity(0.6))
      .padding(.horizontal, 4)
      .frame(height: 15)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder((onPrimary ? theme.primaryText : theme.ink).opacity(0.25), lineWidth: 0.5))
  }
}

/// Instant press feedback (on pointer-down).
struct PressScale: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// İzin ver / Her zaman. Risky requests need a 600 ms hold (ring fills) or ⌘⏎.
struct AllowButton: View {
  let card: PendingPermission
  let gate: CardGate
  let ui: NotchUIState
  let decision: PermissionDecision
  let title: String
  var keycap: String?
  let source: DecisionSource
  let actions: NotchActions
  var primary = true
  var compact = false
  @State private var holding = false
  @State private var progress: Double = 0
  @State private var holdTask: Task<Void, Never>?
  @Environment(\.notchTheme) private var theme

  static let holdDuration: Double = 0.6

  private var enabled: Bool { decision == .always ? gate.canAlways : gate.canAllow }
  /// The global allow shortcut is held on this card (its ring fills like a pointer hold).
  private var keyProgress: Double { decision == .allow ? ui.holdProgress[card.id] ?? 0 : 0 }
  private var tapped: Bool { decision == .allow && ui.holdHintCardID == card.id }
  private var keyHolding: Bool { decision == .allow && ui.keyHoldCardID == card.id }

  private var holdLabel: String {
    if holding || keyHolding { return "Tutun…" }
    return tapped ? "Basılı tutun" : "Basılı tut: \(title)"
  }

  var body: some View {
    if gate.risk != nil {
      holdButton
    } else {
      ActionButton(
        title: title, style: primary ? .primary : .secondary, keycap: keycap,
        enabled: enabled, compact: compact
      ) {
        actions.decide(card.id, decision, source)
      }
    }
  }

  private var holdButton: some View {
    let tone = primary ? theme.primaryText : theme.ink
    return HStack(spacing: 6) {
      ZStack {
        Circle().stroke(tone.opacity(0.25), lineWidth: 2)
        Circle().trim(from: 0, to: max(progress, keyProgress))
          .stroke(theme.error, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 12, height: 12)
      Text(holdLabel)
        .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
        // The ring fills in the hold's linear transaction; the label swaps at once.
        .transaction { $0.animation = nil }
      if let keycap { Keycap(text: keycap, onPrimary: primary) }
    }
    .foregroundStyle(tone)
    .padding(.horizontal, compact ? 10 : 12)
    .frame(height: compact ? 24 : 26)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(primary ? theme.primaryFill : theme.faint))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.needs, lineWidth: tapped ? 1.5 : 0))
    .scaleEffect(holding || keyHolding ? 0.97 : 1)
    .opacity(enabled ? 1 : 0.38)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in begin() }
        .onEnded { _ in cancel() }
    )
    .accessibilityLabel("\(title), basılı tutun")
    .accessibilityAddTraits(.isButton)
  }

  private func begin() {
    guard !holding, enabled else { return }
    holding = true
    withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
    holdTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(Self.holdDuration))
      guard !Task.isCancelled, holding else { return }
      holding = false
      progress = 0
      actions.decide(card.id, decision, source.fromPeek ? .peekHold : .hold)
    }
  }

  private func cancel() {
    holdTask?.cancel()
    holdTask = nil
    holding = false
    withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
  }
}

// MARK: - Full request text

/// The opened request text (or a long "Her zaman" rule) in a native scroll view, at most
/// `maxHeight` tall. Reports once the end of the text has been on screen (see `ReadProgress`:
/// a text that fits counts at once, a longer one only after a real scroll reaches its end),
/// and scrolls one page down when `page` grows (Space).
struct DetailText: NSViewRepresentable {
  let text: String
  let color: NSColor
  let maxHeight: CGFloat
  let page: Int
  var font: NSFont = DetailText.defaultFont
  /// Called once per text with the trigger ("layout" / "scroll") that saw its end.
  let onEnd: @MainActor (String) -> Void

  static let defaultFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

  @MainActor
  final class Coordinator {
    var onEnd: @MainActor (String) -> Void = { _ in }
    var page = 0
    var maxHeight: CGFloat = 0
    var font = DetailText.defaultFont
    var tracker = ReadTracker()
    /// Last `sizeThatFits` measurement (text, width, font, height).
    var measured: (text: String, width: CGFloat, font: NSFont, height: CGFloat)?
    var observers: [NSObjectProtocol] = []
    weak var scroll: NSScrollView?

    /// Height of the laid-out text, measured with the layout manager (not the document
    /// view's frame, which can be stale or zero during a re-render). `nil` until the text
    /// container is as wide as the visible part.
    func contentHeight() -> CGFloat? {
      guard let scroll, let tv = scroll.documentView as? NSTextView, !tv.string.isEmpty,
        let lm = tv.layoutManager, let tc = tv.textContainer
      else { return nil }
      let width = scroll.contentView.bounds.width
      guard width > 40, abs(tc.size.width - width) <= 1 else { return nil }
      lm.ensureLayout(for: tc)
      return lm.usedRect(for: tc).height
    }

    func check(_ trigger: ReadTrigger) {
      guard let scroll else { return }
      let visible = scroll.contentView.bounds
      let height = tracker.reported ? nil : contentHeight().map(Double.init)
      if tracker.observe(
        trigger, contentHeight: height, visibleMinY: visible.minY,
        visibleHeight: visible.height, maxHeight: maxHeight)
      {
        onEnd(trigger.rawValue)
      }
    }

    func pageDown() {
      guard let scroll, let doc = scroll.documentView else { return }
      let clip = scroll.contentView
      let line = font.boundingRectForFont.height
      let maxY = max(0, doc.frame.height - clip.bounds.height)
      let y = min(maxY, clip.bounds.minY + max(line, clip.bounds.height - line * 2))
      // Posts boundsDidChange: the same observer as wheel / trackpad scrolling reports the end.
      clip.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(clip)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    for observer in coordinator.observers { NotificationCenter.default.removeObserver(observer) }
    coordinator.observers = []
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none
    // TextKit 1: the layout is complete and measurable (TextKit 2 estimates heights lazily).
    let tv = PassiveTextView(usingTextLayoutManager: false)
    tv.isEditable = false
    tv.isSelectable = true
    tv.drawsBackground = false
    tv.isRichText = false
    tv.textContainerInset = .zero
    tv.textContainer?.lineFragmentPadding = 0
    tv.textContainer?.widthTracksTextView = true
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.minSize = .zero
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    tv.font = font
    tv.textColor = color
    tv.string = text
    scroll.documentView = tv
    let c = context.coordinator
    c.scroll = scroll
    c.onEnd = onEnd
    c.page = page
    c.maxHeight = maxHeight
    c.font = font
    let clip = scroll.contentView
    clip.postsBoundsChangedNotifications = true
    clip.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    c.observers = [
      center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main)
      { [weak c] _ in
        MainActor.assumeIsolated { c?.check(.scroll) }
      },
      center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main)
      { [weak c] _ in
        MainActor.assumeIsolated { c?.check(.layout) }
      }
    ]
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let c = context.coordinator
    c.onEnd = onEnd
    c.maxHeight = maxHeight
    c.font = font
    if let tv = scroll.documentView as? NSTextView {
      if tv.string != text {
        tv.string = text
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        c.tracker.reset()
      }
      if tv.font != font { tv.font = font }
      tv.textColor = color
    }
    if page != c.page {
      c.page = page
      c.pageDown()
    }
    // After layout: a text that fits is read at once (measured, see `ReadProgress`).
    Task { @MainActor [weak c] in c?.check(.layout) }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
    -> CGSize?
  {
    let width = max(40, proposal.width ?? 400)
    let c = context.coordinator
    let height: CGFloat
    if let cached = c.measured, cached.text == text, cached.width == width, cached.font == font {
      height = cached.height
    } else {
      height = Self.measure(text, width: width, font: font)
      c.measured = (text, width, font, height)
    }
    return CGSize(width: width, height: min(maxHeight, ceil(height)))
  }

  /// Laid-out height of `text` at `width`, with the same TextKit 1 setup as the text view.
  static func measure(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    let storage = NSTextStorage(string: text, attributes: [.font: font])
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    return layout.usedRect(for: container).height
  }

  /// Height of `lines` lines of `font` (a scroll view that shows that many lines at most).
  static func height(lines: Int, font: NSFont) -> CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(lines)) + 1
  }
}

/// Selectable text that never makes the non-activating panel key (a click must not take the
/// keyboard away from the user's terminal).
final class PassiveTextView: NSTextView {
  override var needsPanelToBecomeKey: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
