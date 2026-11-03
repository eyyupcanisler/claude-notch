import ClaudeNotchCore
import SwiftUI

/// Answers a held `AskUserQuestion` in the notch: one question at a time, its options as
/// buttons (tap selects; a multi-select question toggles), then "Gönder". Keys do the same:
/// ⌃⌥1…4 pick, ⌃⌥Y goes on / sends, ⌃⌥N hands it to the terminal. Buttons and keys arm 0.8 s
/// after the question appears, so a click or key meant for something else never answers it.
/// The state lives in `NotchUIState` (the peek, the panel row and the keys share it).
struct QuestionAnswerView: View {
  let question: PendingQuestion
  let ui: NotchUIState
  let actions: NotchActions
  /// Re-renders once the arm time passes.
  @State private var tick = 0
  @Environment(\.notchTheme) private var theme

  static let armDelay: Double = 0.8

  private var index: Int { min(ui.questionIndex[question.id] ?? 0, question.questions.count - 1) }
  private var current: AskedQuestion { question.questions[index] }
  private var isLast: Bool { index >= question.questions.count - 1 }
  private var picked: [String] { ui.questionPicks[question.id]?[current.question] ?? [] }
  private var armed: Bool {
    _ = tick
    return Date() >= (ui.questionArmedAt[question.id] ?? .distantFuture)
  }
  private var allowKey: String? { ui.allowKey }
  private var denyKey: String? { ui.denyKey }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        if question.questions.count > 1 {
          Text("\(index + 1)/\(question.questions.count)")
            .font(.system(size: 10.5, weight: .bold)).monospacedDigit()
            .foregroundStyle(theme.needs)
        }
        if !current.header.isEmpty {
          Text(current.header.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
            .foregroundStyle(theme.tertiary)
        }
        if current.multiSelect {
          Text("birden çok seçilebilir").font(.system(size: 10)).foregroundStyle(theme.tertiary)
        }
      }
      Text(current.question)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(theme.ink)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
        alignment: .leading, spacing: 6
      ) {
        ForEach(Array(current.options.enumerated()), id: \.offset) { i, option in
          optionButton(option, index: i)
        }
      }
      HStack(spacing: 6) {
        Button { actions.releaseQuestion(question.id) } label: {
          keyed("Terminalde yanıtla", key: denyKey, primary: false)
        }
        .buttonStyle(.plain)
        Spacer(minLength: 0)
        if index > 0 {
          SmallButton(title: "Geri", style: .secondary) { actions.questionBack(question.id) }
        }
        Button { actions.questionNext(question.id) } label: {
          keyed(isLast ? "Gönder" : "Sonraki", key: allowKey, primary: true)
        }
        .buttonStyle(.plain)
        .disabled(picked.isEmpty || !armed)
        .opacity(picked.isEmpty || !armed ? 0.4 : 1)
      }
    }
    .task(id: question.id) {
      let wait = (ui.questionArmedAt[question.id] ?? Date()).timeIntervalSinceNow
      if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.02)) }
      tick += 1
    }
  }

  /// A button face with its global key ("Gönder ⌃⌥Y").
  private func keyed(_ title: String, key: String?, primary: Bool) -> some View {
    HStack(spacing: 5) {
      Text(title).font(.system(size: 11.5, weight: .semibold))
      if let key { Keycap(text: key, onPrimary: primary) }
    }
    .foregroundStyle(primary ? theme.primaryText : theme.ink)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(primary ? theme.primaryFill : theme.faint))
    .contentShape(Rectangle())
  }

  private func optionButton(_ option: AskedQuestion.Option, index i: Int) -> some View {
    let on = picked.contains(option.label)
    return Button {
      actions.pickOption(question.id, i)
    } label: {
      HStack(spacing: 6) {
        Text("\(i + 1)")
          .font(.system(size: 10, weight: .bold)).monospacedDigit()
          .foregroundStyle(on ? Color.black : theme.tertiary)
          .frame(width: 16, height: 16)
          .background(Circle().fill(on ? theme.needs : Color.white.opacity(0.08)))
        Text(option.label)
          .font(.system(size: 11.5, weight: on ? .semibold : .medium))
          .foregroundStyle(theme.ink)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        if i < 4, armed {
          Text("⌃⌥\(i + 1)")
            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(theme.tertiary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(on ? theme.needs.opacity(0.14) : theme.faint))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(on ? theme.needs.opacity(0.6) : theme.hairline, lineWidth: on ? 1 : 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(armed ? 1 : 0.55)
    .help(option.description.isEmpty ? option.label : option.description)
    .accessibilityLabel(option.label)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}
