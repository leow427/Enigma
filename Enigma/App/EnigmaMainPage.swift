import SwiftUI

// The main page: the character, a greeting, the route's
// status, the composer, and the slash commands as example lines. After the
// first send the composer springs to the bottom under the conversation.

/// The window's look: an opaque `background`, rounded corners, and a
/// `border` edge.
struct EnigmaWindowChrome: ViewModifier {
  static let cornerRadius: CGFloat = 12
  /// The band along the window's edges left to resizing, outside the drag area.
  static let resizeEdge: CGFloat = 6

  @Environment(\.enigmaPalette) private var palette

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    content
      // As the compact panel does, the window moves by its background.
      .enigmaWindowDragArea(edgeInset: Self.resizeEdge)
      .background(palette.background.color)
      .clipShape(shape)
      .enigmaEdge(shape)
      .tint(palette.accent.color)
  }
}

/// The greeting, status, and controls, measured so the page knows what fits.
private struct MainPageInfoHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Lays out the main column: the empty page, or the conversation with the
/// composer docked at the bottom. The composer is one view throughout, so it
/// springs between the two places with `EnigmaMotion.composerDock`. Under
/// Reduce Motion it moves there at once while the page around it cross-fades.
struct EnigmaMainColumn<TopBar: View, Header: View, Conversation: View, Accessories: View, Composer: View,
                        Examples: View>: View {
  /// Nothing has been sent in this chat yet.
  let isEmpty: Bool
  let showsTopBar: Bool
  let availableExamples: Int
  @ViewBuilder let topBar: () -> TopBar
  let header: (MainPageLayout.Header) -> Header
  @ViewBuilder let conversation: () -> Conversation
  @ViewBuilder let accessories: () -> Accessories
  /// Given whether the composer is docked at the bottom.
  let composer: (Bool) -> Composer
  /// Given how many example lines fit.
  let examples: (Int) -> Examples

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var docked: Bool
  @State private var infoHeight: CGFloat = 96
  @State private var composerHeight: CGFloat = 86
  @State private var accessoriesHeight: CGFloat = 0

  init(isEmpty: Bool, showsTopBar: Bool, availableExamples: Int, @ViewBuilder topBar: @escaping () -> TopBar,
       header: @escaping (MainPageLayout.Header) -> Header, @ViewBuilder conversation: @escaping () -> Conversation,
       @ViewBuilder accessories: @escaping () -> Accessories, composer: @escaping (Bool) -> Composer,
       examples: @escaping (Int) -> Examples) {
    self.isEmpty = isEmpty
    self.showsTopBar = showsTopBar
    self.availableExamples = availableExamples
    self.topBar = topBar
    self.header = header
    self.conversation = conversation
    self.accessories = accessories
    self.composer = composer
    self.examples = examples
    _docked = State(initialValue: !isEmpty)
  }

  var body: some View {
    GeometryReader { proxy in
      let layout = MainPageLayout(height: proxy.size.height, topBar: showsTopBar ? EnigmaTopBar.height : 0,
                                  info: infoHeight, composer: composerHeight, accessories: accessoriesHeight,
                                  availableExamples: availableExamples)
      let columnWidth = min(MainPageLayout.columnMaximumWidth, max(0, proxy.size.width - 48))
      VStack(spacing: 0) {
        if showsTopBar { topBar() }
        if docked {
          conversation()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else if layout.header != .hidden {
          header(layout.header)
            .frame(maxWidth: .infinity)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -30)))
        }
        VStack(spacing: MainPageLayout.accessoriesSpacing) {
          accessoriesArea(limit: layout.accessoriesLimit)
          composer(docked)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .frame(width: columnWidth)
        // Under Reduce Motion the composer doesn't slide: only the page fades.
        .transaction(value: docked) { if reduceMotion { $0.animation = nil } }
        .zIndex(1)
        if !docked {
          examples(layout.exampleCount)
            .frame(width: max(0, columnWidth - 12), alignment: .leading)
            .padding(.top, layout.exampleCount > 0 ? MainPageLayout.examplesTopPadding : 0)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 40)))
          Spacer(minLength: 0)
        }
      }
      .padding(.bottom, docked ? MainPageLayout.bottomPadding : 0)
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
    .onPreferenceChange(MainPageInfoHeight.self) { height in
      if height > 0 { infoHeight = height }
    }
    .onChange(of: isEmpty) { _, empty in dock(!empty) }
    .onAppear { if docked == isEmpty { docked = !isEmpty } }
  }

  /// Notices, attachments, and cards over the composer. They scroll once
  /// they'd push the composer out of a small window.
  private func accessoriesArea(limit: CGFloat) -> some View {
    ScrollView {
      accessories()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoriesHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(accessoriesHeight, limit))
  }

  private func dock(_ value: Bool) {
    guard value != docked else { return }
    // Under Reduce Motion the header, examples, and conversation cross-fade
    // and the composer moves at once. Animating its move, even while hidden,
    // could leave its AppKit views (the message field, Send) where it started
    // while SwiftUI drew it docked, so clicks missed.
    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : EnigmaMotion.composerDock.animation) { docked = value }
  }
}

/// The empty page above the composer: the character's 92 pt slot, the
/// greeting, the route's status with what's missing, and the routing mode.
struct EnigmaMainPageHeader: View {
  let style: MainPageLayout.Header
  let greeting: String
  let status: ChatRouteStatus
  let performStatusAction: (ChatRouteStatus.Action) -> Void
  @Binding var mode: ChatMode
  let isStatusActionEnabled: Bool
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      if style == .full {
        Color.clear
          .enigmaCharacterSlot(id: MainWindowCharacter.mainSlot, size: MainWindowCharacter.mainSlotSize)
          .padding(.top, MainPageLayout.slotTopPadding)
          .padding(.bottom, MainPageLayout.slotBlock - MainWindowCharacter.mainSlotSize)
      } else {
        Color.clear.frame(height: MainPageLayout.compactTopPadding)
      }
      info
        .background {
          GeometryReader { proxy in Color.clear.preference(key: MainPageInfoHeight.self, value: proxy.size.height) }
        }
      Color.clear.frame(height: MainPageLayout.headerGap)
    }
    .padding(.horizontal, 24)
  }

  private var info: some View {
    VStack(spacing: 8) {
      Text(greeting)
        .font(EnigmaTypography.ui(23, weight: .semibold))
        .tracking(-0.35)
        .foregroundStyle(palette.textPrimary.color)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .accessibilityAddTraits(.isHeader)
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        EnigmaStatusLine(status.lineStatus, status.text, tintsGlyphOnly: true)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .enigmaTestMarker("Page status \(status.text)")
        if let action = status.action, let title = status.actionTitle {
          Button(title) { performStatusAction(action) }
            .enigmaButtonStyle(.secondary)
            .disabled(!isStatusActionEnabled)
            .enigmaTestMarker(title)
        }
      }
      EnigmaSegmentedControl("Routing mode", selection: $mode,
                             options: ChatMode.allCases.map { EnigmaOption($0, $0.displayName) })
        .padding(.top, 4)
    }
    .frame(maxWidth: MainPageLayout.columnMaximumWidth)
  }
}

/// The route's status over a docked composer, with what's missing.
struct EnigmaRouteStatusLine: View {
  let status: ChatRouteStatus
  let isActionEnabled: Bool
  let performAction: (ChatRouteStatus.Action) -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Spacer(minLength: 0)
      EnigmaStatusLine(status.lineStatus, status.text, tintsGlyphOnly: true)
        .lineLimit(2)
        .enigmaTestMarker("Route status \(status.text)")
      if let action = status.action, let title = status.actionTitle {
        Button(title) { performAction(action) }
          .enigmaButtonStyle(.text)
          .disabled(!isActionEnabled)
      }
    }
  }
}

/// The slash commands as monospace example lines. Clicking one puts the
/// command in the composer.
struct EnigmaCommandExamples: View {
  let examples: [SlashCommandExample]
  let isEnabled: Bool
  let insert: (SlashCommand) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(examples) { example in
        EnigmaCommandExampleRow(example: example) { insert(example.command) }
          .disabled(!isEnabled)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Command examples")
  }
}

private struct EnigmaCommandExampleRow: View {
  let example: SlashCommandExample
  let action: () -> Void
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let hovered = isHovered && isEnabled
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("›").foregroundStyle(palette.textTertiary.color)
        Text(example.command.token)
          .fontWeight(.medium)
          .foregroundStyle(palette.accentText.color)
        if let argument = example.argument {
          Text(argument).foregroundStyle(palette.textTertiary.color)
        }
        Text("→").foregroundStyle((hovered ? palette.accentText : palette.textTertiary).color)
        Text(example.result)
          .foregroundStyle(palette.textSecondary.color)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .font(EnigmaTypography.mono(12))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .frame(height: MainPageLayout.exampleLineHeight)
      .background { if hovered { shape.fill(palette.hover.color) } }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: 8, outset: 0)
    .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
    .onHover { isHovered = $0 }
    .accessibilityLabel("Use \(example.command.token): \(example.result)")
    .enigmaTestMarker("Example \(example.command.token)")
  }
}
