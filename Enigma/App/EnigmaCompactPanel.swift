import SwiftUI

// The compact selection panel: the panel that opens over another app when you
// select text and use the selection shortcut (double-tap ⌥ by default). From
// top to bottom: the `› selected "…"` line, the input row with the character
// in its 40 pt slot, and a monospace hint row. It's one opaque `surface`
// with a `border` edge. AppShellView owns every action and all the state;
// these views only lay them out, reusing the main window's composer pieces
// and cards. Once a question is sent, the chat moves to the window's own
// layout, so the panel never shows an answer.

/// The panel. It's as tall as its content, which it reports so the window
/// fits it, with room for the command list or the mode and model menu while
/// one is open: under the input, or above it when the panel sits too low on
/// the screen for them to open downward. The report also gives the height at
/// rest, without that room or the details, so the panel reopens at its
/// resting size.
struct EnigmaCompactPanel<Selection: View, Composer: View, Attachment: View, Details: View>: View {
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

  @Environment(\.enigmaPalette) private var palette
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
  /// model menu, on the side it opens on. The window grows by it.
  private func rooms(menuRoom: CGFloat) -> Rooms {
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
      Color.clear.frame(height: room.above)
      selection()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { selectionHeight = $0 }
      composer()
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(SlashSuggestionsFrame.coordinateSpace))
        } action: { input = $0 }
        // The command list opens over what's around the input.
        .zIndex(1)
      attachment()
      details()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
      Color.clear.frame(height: room.below)
      EnigmaCompactHints(hints: hints, tag: isTemporary ? CompactPanelHints.temporaryTag : nil)
    }
    .fixedSize(horizontal: false, vertical: true)
    .background {
      GeometryReader { proxy in
        Color.clear.preference(key: SelectionComposerHeight.self, value: SelectionComposerReport(
          height: proxy.size.height,
          restingHeight: proxy.size.height - room.above - room.below - detailsHeight, roomAbove: room.above))
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Ask Enigma")
    .enigmaTestMarker("Compact panel")
  }
}

// MARK: Selection line

/// `› selected "…"`, with the selection's status and a button to remove it,
/// or its own plain line when no text was selected. The status button opens
/// the details, and shows a problem glyph when there's a notice or
/// Accessibility is missing. The panel only ever holds a chat before its
/// first question, so the selection here is always still to be sent.
struct EnigmaCompactSelectionLine: View {
  let contexts: [ConversationContext]
  var isBusy = false
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
    VStack(alignment: .leading, spacing: 2) {
      if contexts.isEmpty {
        line(nil, showsStatus: true, isFirst: true)
      } else {
        ForEach(Array(contexts.enumerated()), id: \.element.id) { index, context in
          line(context, showsStatus: index == 0, isFirst: index == 0)
        }
      }
    }
    .padding(.top, 9)
    .padding(.leading, 16)
    .padding(.trailing, 10)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("selected")
            .fontWeight(.medium)
            .foregroundStyle(palette.accentText.color)
          Text("“\(context.preview)”")
            .foregroundStyle(palette.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(context.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context.title): \(context.preview)")
        .enigmaTestMarker("Selected text")
      } else {
        Text("no text selected")
          .foregroundStyle(palette.textTertiary.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("No text selected")
          .enigmaTestMarker("No text selected")
      }
      if showsStatus {
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
