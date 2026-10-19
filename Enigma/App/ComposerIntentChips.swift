import SwiftUI

/// The commands recognized from the draft's wording, as small monospace chips
/// in the composer bar, in `ComposerIntent.chipOrder`. Clicking one turns that
/// recognition off for the current draft. Typed commands get no chip; they're
/// already highlighted in the text.
struct ComposerIntentChips: View {
  let commands: [SlashCommand]
  let dismiss: (SlashCommand) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(commands) { command in
        Button { dismiss(command) } label: {
          HStack(spacing: 4) {
            Text(command.rawValue).font(EnigmaTypography.mono(11))
            Image(systemName: "xmark").font(EnigmaTypography.symbol(8))
          }
        }
        .modifier(ComposerIntentChipFocus())
        .accessibilityLabel("Recognized command: \(command.rawValue)")
        .accessibilityHint("Turns it off for this message")
        .help("Recognized from your wording · click to turn off \(command.token) for this message")
        .enigmaTestMarker("Recognized \(command.rawValue)")
      }
    }
    .fixedSize()
  }
}

/// Keyboard focus shows the `accent` ring, as on the composer's other buttons.
private struct ComposerIntentChipFocus: ViewModifier {
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content
      .buttonStyle(ComposerIntentChipStyle(isFocused: isFocused))
      .focused($isFocused)
      .focusEffectDisabled()
  }
}

private struct ComposerIntentChipStyle: ButtonStyle {
  let isFocused: Bool

  func makeBody(configuration: Configuration) -> some View {
    ComposerIntentChipBody(isFocused: isFocused, configuration: configuration)
  }
}

/// The command and a small × in `accentText`, in a capsule with a
/// `border` edge and a `hover` fill under the pointer. No fill otherwise, so
/// Send stays the composer's one `accent` control.
private struct ComposerIntentChipBody: View {
  let isFocused: Bool
  let configuration: ButtonStyleConfiguration
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    let shape = Capsule(style: .continuous)
    let hovered = isHovered && isEnabled
    configuration.label
      .foregroundStyle(palette.accentText.color)
      .padding(.leading, 8)
      .padding(.trailing, 7)
      .frame(height: 20)
      .background { if hovered { shape.fill(palette.hover.color) } }
      .enigmaEdge(shape)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
      .scaleEffect(EnigmaControlStyle.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
      .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: 10, outset: 2)
      .animation(reduceMotion ? nil : EnigmaControlStyle.press.animation, value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}
