import SwiftUI

// MARK: The character follows clicks, and the welcome types examples

extension View {
  /// A spot just right of this row where the character lands when the row is clicked.
  func welcomePerch(_ id: String, character: EnigmaCharacterController) -> some View {
    let slot = EnigmaCharacterSlotID("welcome.perch." + id)
    return overlay(alignment: .trailing) {
      Color.clear
        .enigmaCharacterSlot(id: slot, size: 38)
        .offset(x: 62)
        .allowsHitTesting(false)
    }
    .simultaneousGesture(TapGesture().onEnded { character.move(to: slot, .fly) })
  }
}

/// A little composer that types what people ask Enigma, plain words and
/// commands alike, while the character leans in at each keystroke.
struct WelcomeTypewriter: View {
  let character: EnigmaCharacterController
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = ""
  @State private var cursorOn = true
  static let target: EnigmaCharacterTargetID = "welcome.typewriter"
  static let examples = [
    "cafes near me",
    "/translate this into Spanish",
    "what did Sam say about Saturday?",
    "/snapshot what does this error mean?",
    "will it rain tomorrow?",
    "/edit make this sound friendlier",
    "fix the typos in notes.md",
    "/think plan my week around three deadlines",
  ]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 0) {
        typed
        Rectangle()
          .fill(palette.accent.color)
          .frame(width: 2, height: 19)
          .opacity(cursorOn ? 1 : 0)
          .padding(.leading, 1)
        Spacer(minLength: 0)
      }
      .frame(height: 22)
      HStack(spacing: 16) {
        Text("+").font(EnigmaTypography.ui(17))
        Text("/").font(EnigmaTypography.mono(15))
        Text("● local").font(EnigmaTypography.mono(12))
        Spacer()
        Circle().fill(palette.accent.color).frame(width: 26, height: 26)
          .overlay(Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.onAccent.color))
      }
      .foregroundStyle(palette.textSecondary.color)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
    .enigmaCharacterTarget(Self.target)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Examples of what you can ask")
    .task { await run() }
  }

  /// The command in `accentText`, the rest in body text, as the composer shows them.
  private var typed: some View {
    let parts = shown.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let isCommand = shown.hasPrefix("/")
    var text = AttributedString(shown)
    text.font = EnigmaTypography.ui(16)
    text.foregroundColor = palette.textPrimary.color
    if isCommand, let first = parts.first, let range = text.range(of: first) {
      text[range].foregroundColor = palette.accentText.color
      text[range].font = EnigmaTypography.mono(15)
    }
    return Text(text)
  }

  private func run() async {
    if reduceMotion { shown = Self.examples[0]; return }
    var index = 0
    while !Task.isCancelled {
      let example = Self.examples[index % Self.examples.count]
      for character in example {
        shown.append(character)
        self.character.key(towards: Self.target)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95)))
      }
      for _ in 0..<4 { cursorOn.toggle(); try? await Task.sleep(for: .milliseconds(350)) }
      cursorOn = true
      self.character.token()
      try? await Task.sleep(for: .milliseconds(500))
      while !shown.isEmpty {
        shown.removeLast()
        try? await Task.sleep(for: .milliseconds(18))
      }
      try? await Task.sleep(for: .milliseconds(300))
      index += 1
    }
  }
}
