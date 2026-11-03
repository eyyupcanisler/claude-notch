import ClaudeNotchCore
import SwiftUI

/// Answers a held `AskUserQuestion` in the notch: one question at a time, its options as
/// buttons (tap selects; a multi-select question toggles), then "Gönder". Buttons arm 0.8 s
/// after the question appears, so a click aimed at something else never answers it.
/// "Terminalde" hands it back to the terminal. Free text ("Other") stays in the terminal.
struct QuestionAnswerView: View {
  let question: PendingQuestion
  let actions: NotchActions
  @State private var index = 0
  @State private var picks: [String: [String]] = [:]
  @State private var armed = false
  @Environment(\.notchTheme) private var theme

  static let armDelay: Double = 0.8

  private var current: AskedQuestion {
    question.questions[min(index, question.questions.count - 1)]
  }
  private var isLast: Bool { index >= question.questions.count - 1 }
  private var picked: [String] { picks[current.question] ?? [] }

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
          optionButton(option, number: i + 1)
        }
      }
      HStack(spacing: 6) {
        SmallButton(title: "Terminalde yanıtla", style: .secondary) {
          actions.releaseQuestion(question.id)
        }
        Spacer(minLength: 0)
        if index > 0 {
          SmallButton(title: "Geri", style: .secondary) { index -= 1 }
        }
        SmallButton(title: isLast ? "Gönder" : "Sonraki", style: .primary) { next() }
          .disabled(picked.isEmpty || !armed)
          .opacity(picked.isEmpty || !armed ? 0.4 : 1)
      }
    }
    .task(id: question.id) {
      armed = false
      index = 0
      picks = [:]
      try? await Task.sleep(for: .seconds(Self.armDelay))
      armed = true
    }
  }

  private func optionButton(_ option: AskedQuestion.Option, number: Int) -> some View {
    let on = picked.contains(option.label)
    return Button {
      guard armed else { return }
      var list = picked
      if current.multiSelect {
        if on { list.removeAll { $0 == option.label } } else { list.append(option.label) }
      } else {
        list = [option.label]
      }
      picks[current.question] = list
    } label: {
      HStack(spacing: 6) {
        Text("\(number)")
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

  private func next() {
    guard armed, !picked.isEmpty else { return }
    if isLast {
      actions.answerQuestion(question.id, picks)
    } else {
      index += 1
    }
  }
}
