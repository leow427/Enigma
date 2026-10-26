import SwiftUI

/// The composer: one rounded, opaque `surface` box holding
/// the message field, Attach and `/` on the left, the `● local` or `○ cloud`
/// indicator, chips for commands recognized from the draft, the mode and model menu, and the `accent` Send button, which
/// becomes Stop while a reply runs. Then, once the field has text, a second Send beside Stop queues it.
/// `AppShellView` owns every action.
struct EnigmaComposer: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var availableCommands: [SlashCommand]
  var insertion: SlashCommandInsertion?
  /// The command list opens below the field while the composer sits high on
  /// the main page, and above it once the composer is docked.
  var opensSuggestionsBelow: Bool
  var submit: () -> Void

  @ObservedObject var files: FileModeCoordinator
  var isAttachDisabled: Bool
  var attach: () -> Void
  var beginCommand: () -> Void

  var route: ComposerRouteIndicator?
  var menu: ModeAndModelMenu
  var menuActions: ModeAndModelMenu.Actions
  @Binding var isMenuPresented: Bool
  var menuClosed: () -> Void

  var isResponding: Bool
  var canSend: Bool
  var send: () -> Void
  var stop: () -> Void
  /// While a reply runs: the field has text, so Send appears beside Stop to queue it.
  var showsQueueButton = false
  /// Off at the queue's cap, and for a draft that can't be queued.
  var canQueue = false

  /// Commands recognized from the draft's wording, shown as chips after the route.
  var inferredCommands: [SlashCommand] = []
  var dismissInferred: (SlashCommand) -> Void = { _ in }

  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  /// The box's frame in the menu host's space, so the menu opens 8 pt clear of it.
  @State private var boxFrame: CGRect?

  static let cornerRadius: CGFloat = 18
  /// Between the box and its open menu, as in the mockup.
  static let menuGap: CGFloat = 8
  /// From the field's bottom edge to below the box, for a list that opens downward.
  private static let belowGap: CGFloat = 10 + 30 + 9 + 8
  /// From the field's top edge to above the box, for a list that opens upward.
  private static let aboveGap: CGFloat = 13 + 8

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      SlashCommandComposer(
        text: $text, isFocused: $isFocused, isEnabled: isEnabled, fontSize: 15,
        availableCommands: availableCommands,
        placeholder: "Ask anything, or type / for commands",
        suggestionPlacement: opensSuggestionsBelow ? .below(gap: Self.belowGap) : .above(gap: Self.aboveGap),
        insertion: insertion, submit: submit)
        .padding(.trailing, 6)
        .welcomeTourTarget(.composer)
      bar
    }
    .padding(.top, 13)
    .padding(.leading, 15)
    .padding(.trailing, 10)
    .padding(.bottom, 9)
    .background(palette.surface.color, in: shape)
    .overlay {
      shape.strokeBorder(edgeColor.color, lineWidth: 1 / displayScale)
        .allowsHitTesting(false)
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EnigmaMenuPresenter.coordinateSpace)) } action: {
      boxFrame = $0
    }
    .enigmaCharacterTarget(MainWindowCharacter.composerTarget, at: UnitPoint(x: 0.2, y: 0.3))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Message composer")
  }

  /// The edge picks up the accent while the field has focus, as in the mockup.
  private var edgeColor: EnigmaColor {
    if isFocused && isEnabled { return palette.accent.withOpacity(0.5) }
    return EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased)
  }

  private var bar: some View {
    HStack(spacing: 2) {
      Button(action: attach) {
        Image(systemName: "plus").font(EnigmaTypography.iconButtonSymbol)
      }
      .enigmaIconButtonStyle(isActive: files.selection != nil || files.isPicking)
      .disabled(isAttachDisabled)
      .accessibilityLabel("Attach files")
      .accessibilityValue(files.selection == nil ? "Off" : "On")
      .help("Attach a file or folder · ⇧⌘A")
      .welcomeTourTarget(.files)
      .enigmaTestMarker("Attach files")

      Button(action: beginCommand) {
        Text("/").font(EnigmaTypography.mono(15, weight: .medium))
      }
      .enigmaIconButtonStyle()
      .disabled(!isEnabled)
      .accessibilityLabel("Commands")
      .help("Type / for commands")
      .enigmaTestMarker("Commands")

      if let route {
        Text(route.text)
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
          .lineLimit(1)
          .padding(.leading, 6)
          .accessibilityLabel(route.accessibilityLabel)
          .enigmaTestMarker("Route \(route.text)")
      }

      if !inferredCommands.isEmpty {
        ComposerIntentChips(commands: inferredCommands, dismiss: dismissInferred)
          .padding(.leading, 6)
      }

      Spacer(minLength: 8)

      EnigmaMenu("Mode and model", sections: menu.sections(menuActions), style: .plain,
                 accessibilityValue: menu.label, isPresented: $isMenuPresented, returnFocus: menuClosed,
                 anchorBounds: boxFrame?.insetBy(dx: 0, dy: -(Self.menuGap - EnigmaMenuPlacement.gap))) {
        Text(menu.label)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .welcomeTourTarget(.model)

      if isResponding && showsQueueButton {
        queueButton.padding(.leading, 6)
      }
      sendButton.padding(.leading, 6)
    }
  }

  private var queueButton: some View {
    Button(action: send) {
      Image(systemName: "arrow.up").font(EnigmaTypography.iconButtonSymbol)
    }
    // Outlined: Stop stays the composer's one `accent` control.
    .enigmaIconButtonStyle()
    .disabled(!canQueue)
    .accessibilityLabel("Queue message")
    .help("Queue this message · Return")
    .enigmaTestMarker("Queue message")
  }

  private var sendButton: some View {
    Button {
      if isResponding { stop() } else { send() }
    } label: {
      Image(systemName: isResponding ? "stop.fill" : "arrow.up")
        .font(EnigmaTypography.symbol(isResponding ? 12 : 15))
    }
    .modifier(EnigmaSendButtonFocus())
    .disabled(!isResponding && !canSend)
    .accessibilityLabel(isResponding ? "Stop response" : "Send message")
    .enigmaTestMarker(isResponding ? "Stop response" : "Send message")
  }
}

/// The composer's one `accent` control: a 30 pt rounded square, with the
/// `accent` focus ring outside it.
private struct EnigmaSendButtonFocus: ViewModifier {
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content
      .buttonStyle(EnigmaSendButtonStyle(isFocused: isFocused))
      .focused($isFocused)
      .focusEffectDisabled()
  }
}

private struct EnigmaSendButtonStyle: ButtonStyle {
  let isFocused: Bool

  func makeBody(configuration: Configuration) -> some View {
    EnigmaSendButtonBody(isFocused: isFocused, configuration: configuration)
  }
}

private struct EnigmaSendButtonBody: View {
  let isFocused: Bool
  let configuration: ButtonStyleConfiguration
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    configuration.label
      .foregroundStyle(palette.onAccent.color)
      .frame(width: 30, height: 30)
      .background(palette.accent.color, in: shape)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
      .scaleEffect(EnigmaControlStyle.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
      .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: 10)
      .animation(reduceMotion ? nil : EnigmaControlStyle.press.animation, value: configuration.isPressed)
  }
}
