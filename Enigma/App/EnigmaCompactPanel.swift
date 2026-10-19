import SwiftUI

// The compact selection panel: the panel that opens over
// another app when you select text and double-tap ⌥. From top to bottom: the
// `› selected "…"` line, the input row with the character in its 40 pt slot,
// the answer area once a question is sent, and a monospace hint row. It's one
// opaque `surface` with a `border` edge. AppShellView owns every action and
// all the state; these views only lay them out, reusing the main window's
// composer pieces and the conversation's replies and cards.

/// The panel. While composing, it's as tall as its content, which it reports
/// so the window fits it, with room for the command list or the mode and model
/// menu while one is open: under the input, or above it when the panel sits
/// too low on the screen for them to open downward. The report also gives the
/// height at rest, without that room or the details, so the panel reopens at
/// its resting size. Once a question is accepted the window grows downward on
/// `EnigmaMotion.panelAnswer` and the answer area fills it.
struct EnigmaCompactPanel<Selection: View, Composer: View, Attachment: View, Details: View, Answer: View>: View {
  /// The panel is still the composer; false once it has grown into the answer.
  let isComposing: Bool
  /// Lists and menus open above the input, because there's no room under the panel.
  var opensOverlaysAbove = false
  let hints: [CompactPanelHints.Hint]
  /// The chat is temporary, as it is while it's in the panel: the hint row says so.
  var isTemporary = false
  @ViewBuilder let selection: () -> Selection
  @ViewBuilder let composer: () -> Composer
  /// Under the input while composing, like an attached screenshot.
  @ViewBuilder let attachment: () -> Attachment
  /// The selection's details while they're open.
  @ViewBuilder let details: () -> Details
  @ViewBuilder let answer: () -> Answer

  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The open command list's frame, the input row's, and the details' height,
  /// in the panel's space.
  @State private var suggestions: CGRect = .zero
  @State private var input: CGRect = .zero
  @State private var selectionHeight: CGFloat = 0
  @State private var detailsHeight: CGFloat = 0

  var body: some View {
    EnigmaMenuRoom { menuRoom in
      panel(menuRoom: menuRoom)
    }
  }

  private struct Rooms {
    var above: CGFloat = 0
    var below: CGFloat = 0
  }

  /// Room for whichever overlay needs more, the command list or the mode and
  /// model menu, on the side it opens on. The window grows by it while composing.
  private func rooms(menuRoom: CGFloat) -> Rooms {
    guard isComposing else { return Rooms() }
    var rooms = Rooms()
    if opensOverlaysAbove {
      // Measured from the input, so the room doesn't depend on itself: what
      // reaches higher than the selection line over the input needs room.
      let listRoom = suggestions == .zero ? 0 : max(0, input.minY - suggestions.minY + 8 - selectionHeight)
      rooms.above = max(listRoom, max(0, menuRoom - selectionHeight))
    } else {
      let listRoom = suggestions == .zero ? 0 : max(0, suggestions.maxY + 8 - input.maxY)
      rooms.below = max(listRoom, menuRoom)
    }
    return rooms
  }

  private func panel(menuRoom: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: CompactPanelLayout.cornerRadius, style: .continuous)
    let room = rooms(menuRoom: menuRoom)
    return VStack(spacing: 0) {
      if isComposing { Color.clear.frame(height: room.above) }
      selection()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { selectionHeight = $0 }
      composer()
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(SlashSuggestionsFrame.coordinateSpace))
        } action: { input = $0 }
        // The command list opens over what's around the input.
        .zIndex(1)
      if isComposing {
        attachment()
        details()
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
        Color.clear.frame(height: room.below)
      } else {
        EnigmaHairline()
        answer()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity)
      }
      EnigmaCompactHints(hints: hints, tag: isTemporary ? CompactPanelHints.temporaryTag : nil)
    }
    .fixedSize(horizontal: false, vertical: isComposing)
    .background {
      if isComposing {
        GeometryReader { proxy in
          Color.clear.preference(key: SelectionComposerHeight.self, value: SelectionComposerReport(
            height: proxy.size.height,
            restingHeight: proxy.size.height - room.above - room.below - detailsHeight, roomAbove: room.above))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .coordinateSpace(.named(SlashSuggestionsFrame.coordinateSpace))
    .onPreferenceChange(SlashSuggestionsFrame.self) { suggestions = $0 }
    // Dragging the panel anywhere off its controls and text moves it.
    .enigmaWindowDragArea()
    .background(palette.surface.color)
    .clipShape(shape)
    .enigmaEdge(shape)
    // The answer area springs open as the window grows; Reduce Motion fades.
    .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.panelAnswer.animation, value: isComposing)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Ask Enigma")
    .enigmaTestMarker(isComposing ? "Compact panel" : "Compact panel answer")
  }
}

// MARK: Selection line

/// `› selected "…"`, with the selection's status and a button to remove it,
/// or its own plain line when no text was selected. The status button opens
/// the details, and shows a problem glyph when there's a notice or
/// Accessibility is missing. Once the selection has gone with the first
/// message, the line reads `› for /edit "…"` in a quieter color: it's still
/// what /edit revises and Replace text replaces, but new questions don't carry it.
struct EnigmaCompactSelectionLine: View {
  let contexts: [ConversationContext]
  /// The selections an earlier message already carried.
  var sentContextIDs: Set<UUID> = []
  var isBusy = false
  /// The status button and the no-selection line show only while composing.
  var isComposing: Bool
  var statusNeedsAttention = false
  var isStatusPresented = false
  var toggleStatus: () -> Void = {}
  let remove: (UUID) -> Void
  /// Opens the panel's chat in the main window, as Command-O does.
  /// The button ends the top row whatever else it shows.
  var openInWindow: (() -> Void)? = nil
  /// Opening in the window keeps the chat private instead of saving it.
  var opensPrivately = false
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    if !contexts.isEmpty || isComposing || openInWindow != nil {
      VStack(alignment: .leading, spacing: 2) {
        if !contexts.isEmpty {
          ForEach(Array(contexts.enumerated()), id: \.element.id) { index, context in
            line(context, showsStatus: index == 0, isFirst: index == 0)
          }
        } else if isComposing {
          line(nil, showsStatus: true, isFirst: true)
        } else {
          // Grown with no selection: the row holds only Open in window.
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            openInWindowButton
          }
          .frame(minHeight: 22)
        }
      }
      .padding(.top, 9)
      .padding(.leading, 16)
      .padding(.trailing, 10)
    }
  }

  @ViewBuilder private var openInWindowButton: some View {
    if let openInWindow {
      Button(action: openInWindow) {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(EnigmaTypography.smallIconButtonSymbol)
      }
      .enigmaIconButtonStyle(size: CGSize(width: 24, height: 22))
      .help(CompactPanelHints.openInWindowHelp(keepsPrivate: opensPrivately))
      .accessibilityLabel(CompactPanelHints.openInWindowLabel)
      .accessibilityHint(opensPrivately ? "Opens this chat in the main window. It stays private."
                         : "Opens this chat in the main window and saves it to history")
      .enigmaTestMarker("Open in window")
    }
  }

  private func line(_ context: ConversationContext?, showsStatus: Bool, isFirst: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text("›")
        .foregroundStyle(palette.textTertiary.color)
        .accessibilityHidden(true)
      if let context {
        let isSent = sentContextIDs.contains(context.id)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(CompactSelectionStatus.label(isSent: isSent))
            .fontWeight(.medium)
            .foregroundStyle(isSent ? palette.textTertiary.color : palette.accentText.color)
          Text("“\(context.preview)”")
            .foregroundStyle(isSent ? palette.textTertiary.color : palette.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(isSent ? context.title + ". " + CompactSelectionStatus.sentNote : context.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context.title): \(context.preview)")
        .accessibilityHint(isSent ? CompactSelectionStatus.sentNote : "")
        .enigmaTestMarker("Selected text")
        .enigmaTestMarker(isSent ? "Selected text for /edit" : "Selected text to send")
      } else {
        Text("no text selected")
          .foregroundStyle(palette.textTertiary.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("No text selected")
          .enigmaTestMarker("No text selected")
      }
      if showsStatus && isComposing {
        Button(action: toggleStatus) {
          Image(systemName: statusNeedsAttention ? "exclamationmark.circle" : "info.circle")
            .font(EnigmaTypography.smallIconButtonSymbol)
        }
        .enigmaIconButtonStyle(isActive: isStatusPresented, size: CGSize(width: 24, height: 22))
        .accessibilityLabel("Selection context and status")
        .accessibilityValue(isStatusPresented ? "Shown" : "Hidden")
        .help(context?.title ?? "Selection context and status")
        .enigmaTestMarker("Selection details")
      }
      if let context {
        Button { remove(context.id) } label: {
          Image(systemName: "xmark").font(EnigmaTypography.smallIconButtonSymbol)
        }
        .enigmaIconButtonStyle(size: CGSize(width: 24, height: 22))
        .disabled(isBusy)
        .help("Remove selected text")
        .accessibilityLabel("Remove selected text")
        .enigmaTestMarker("Remove selection")
      }
      if isFirst { openInWindowButton }
    }
    .font(EnigmaTypography.mono(12))
    .frame(minHeight: 22)
  }
}

// MARK: Input row

/// The input row: the character's 40 pt slot, the message field, Attach, and
/// a monospace chip with the route, like `auto · local`, which opens the mode
/// and model menu, then `↵`, which sends, or Stop while a reply runs. The
/// same field and menu as the main window's composer, in one line.
struct EnigmaCompactComposer: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var availableCommands: [SlashCommand]
  var placeholder: String
  /// The command list opens above the field when the panel sits too low for it below.
  var opensSuggestionsAbove = false
  var insertion: SlashCommandInsertion?
  var submit: () -> Void

  @ObservedObject var files: FileModeCoordinator
  var isAttachDisabled: Bool
  var attach: () -> Void

  var chip: String
  var menu: ModeAndModelMenu
  var menuActions: ModeAndModelMenu.Actions
  @Binding var isMenuPresented: Bool
  var menuClosed: () -> Void

  var isResponding: Bool
  var canSend: Bool
  var send: () -> Void
  var stop: () -> Void

  /// Commands recognized from the draft's wording, shown as chips before the route chip.
  var inferredCommands: [SlashCommand] = []
  var dismissInferred: (SlashCommand) -> Void = { _ in }

  @Environment(\.enigmaPalette) private var palette
  /// The row's frame in the menu host's space, so the menu opens under the row.
  @State private var rowFrame: CGRect?

  /// From the field's edge to just past the row, for the command list.
  static let suggestionGap: CGFloat = 22

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Color.clear
        .frame(width: CompactPanelLayout.inputSlotSize, height: CompactPanelLayout.inputSlotSize)
        .enigmaCharacterSlot(id: CompactPanelLayout.inputSlot, size: CompactPanelLayout.inputSlotSize)
      SlashCommandComposer(
        text: $text, isFocused: $isFocused, isEnabled: isEnabled, fontSize: 16,
        availableCommands: availableCommands, placeholder: placeholder,
        suggestionPlacement: opensSuggestionsAbove ? .above(gap: Self.suggestionGap) : .below(gap: Self.suggestionGap),
        insertion: insertion, submit: submit)
        .enigmaCharacterTarget(MainWindowCharacter.composerTarget, at: UnitPoint(x: 0.05, y: 0.5))
      HStack(spacing: 4) {
        Button(action: attach) {
          Image(systemName: "plus").font(EnigmaTypography.symbol(14))
        }
        .enigmaIconButtonStyle(isActive: files.selection != nil || files.isPicking, size: CGSize(width: 26, height: 24))
        .disabled(isAttachDisabled)
        .accessibilityLabel("Attach files")
        .accessibilityValue(files.selection == nil ? "Off" : "On")
        .help("Attach a file or folder · ⇧⌘A")
        .enigmaTestMarker("Attach files")

        if !inferredCommands.isEmpty {
          ComposerIntentChips(commands: inferredCommands, dismiss: dismissInferred)
        }

        EnigmaMenu("Mode and model", sections: menu.sections(menuActions), style: .plain,
                   accessibilityValue: menu.label, isPresented: $isMenuPresented, returnFocus: menuClosed,
                   anchorBounds: rowFrame) {
          Text(chip)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 200, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .enigmaTestMarker("Route chip \(chip)")
        }

        Button {
          if isResponding { stop() } else { send() }
        } label: {
          Text(isResponding ? "stop" : "↵")
        }
        .enigmaButtonStyle(.keycap)
        .disabled(!isResponding && !canSend)
        .accessibilityLabel(isResponding ? "Stop response" : "Send message")
        .help(isResponding ? "Stop the response · ⌘." : "Send · Return")
        .enigmaTestMarker(isResponding ? "Stop response" : "Send message")
      }
      .fixedSize()
    }
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .padding(.vertical, 12)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EnigmaMenuPresenter.coordinateSpace)) } action: {
      rowFrame = $0
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Message composer")
  }
}

// MARK: Details

/// The selection's status and details while composing: an opaque `menu`
/// surface under the input, holding the window's notices and cards. It
/// scrolls when they're tall.
struct EnigmaCompactDetails<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(\.enigmaPalette) private var palette
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    ScrollView {
      content()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(contentHeight, CompactPanelLayout.detailsMaximumHeight))
    .background(palette.menu.color, in: shape)
    .clipShape(shape)
    .enigmaEdge(shape)
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Selection context and status")
    .enigmaTestMarker("Selection details panel")
  }
}

// MARK: Answer

/// The opened answer: the conversation, then the notes and cards that sit
/// over the main window's composer, which scroll once they're tall, keeping
/// the newest, at the bottom, in view.
struct EnigmaCompactAnswer<Conversation: View, Accessories: View>: View {
  @ViewBuilder let conversation: () -> Conversation
  @ViewBuilder let accessories: () -> Accessories
  @State private var accessoriesHeight: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      conversation()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      ScrollView {
        accessories()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoriesHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      // The newest card, like a Messages approval, comes last: keep it in view.
      .defaultScrollAnchor(.bottom)
      .frame(height: min(accessoriesHeight, CompactPanelLayout.accessoriesMaximumHeight))
      .padding(.horizontal, 16)
      .padding(.bottom, accessoriesHeight > 0 ? 10 : 0)
    }
  }
}

// MARK: Hints

/// The monospace hint row along the panel's bottom. The shortcuts sit on the
/// left; the trailing side holds the chat's status, `temporary · not saved`,
/// while the chat is temporary, or Escape when there's no tag. Key symbols
/// use the system font, which draws them properly.
struct EnigmaCompactHints: View {
  let hints: [CompactPanelHints.Hint]
  var tag: String? = nil
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(spacing: 14) {
      ForEach(Array(hints.enumerated()), id: \.element.id) { index, hint in
        if tag == nil && index == hints.count - 1 && hints.count > 1 { Spacer(minLength: 0) }
        EnigmaKeyedText(hint.text, size: 11, symbolTracking: 1.5)
          .enigmaTestMarker("Hint \(hint.text)")
      }
      if let tag {
        Spacer(minLength: 0)
        Text(tag)
          .font(EnigmaTypography.mono(11))
          .enigmaTestMarker("Hint tag \(tag)")
      }
    }
    .foregroundStyle(palette.textTertiary.color)
    .lineLimit(1)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) { EnigmaHairline() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shortcuts: " + hints.map(\.text).joined(separator: ", ") + (tag.map { ". " + $0 } ?? ""))
  }
}
