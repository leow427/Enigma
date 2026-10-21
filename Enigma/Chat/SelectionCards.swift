import SwiftUI

// Selection Context cards: the /edit revision card in a chat, the
// selected-text card over the composer, and the Accessibility card.

/// The revised text after an /edit reply: read it, edit it, or replace the
/// selection with it. Replace text is the card's one `accent` button.
struct SelectionRevisionCard: View {
  let revision: SelectionRevision
  let disabled: Bool
  let update: (String) -> Void
  let replace: () -> Void
  @State private var editing = false
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        EnigmaCardTitle("Revised text", systemImage: "text.alignleft")
        Spacer(minLength: 8)
        if revision.status == .sent { EnigmaStatusLine(.on, "Replacement sent") }
      }
      if editing {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        TextEditor(text: Binding(get: { revision.text }, set: { update($0) }))
          .font(EnigmaTypography.reply)
          .foregroundStyle(palette.textPrimary.color)
          .scrollContentBackground(.hidden)
          .padding(6)
          .frame(minHeight: 120, maxHeight: 240)
          .background(palette.background.color, in: shape)
          .enigmaEdge(shape)
          .tint(palette.accent.color)
          .accessibilityLabel("Edit revised text")
      } else {
        ScrollView {
          Text(revision.text)
            .font(EnigmaTypography.reply)
            .lineSpacing(ChatMarkdownStyle.lineSpacing)
            .foregroundStyle(palette.textPrimary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Button(editing ? "Done" : "Edit") { editing.toggle() }
          .enigmaButtonStyle(.secondary)
          .disabled(disabled || revision.status == .sent)
          .accessibilityLabel(editing ? "Done editing" : "Edit revised text")
          .enigmaTestMarker(editing ? "Done editing" : "Edit revised text")
        Button("Replace text") { editing = false; replace() }
          .enigmaButtonStyle(.compactPrimary)
          .disabled(disabled || revision.text.isEmpty || revision.status == .sent || revision.status == .applying)
          .enigmaTestMarker("Replace text")
        if revision.status == .applying { EnigmaStatusLine(.busy, "Replacing…") }
      }
    }
    .enigmaCard()
    .accessibilityElement(children: .contain)
  }
}

/// Selected text attached to the chat: where it came from, a preview, and a
/// button to remove it. Once it has gone with the first message, a note says
/// new questions don't carry it and /edit still revises it.
struct SelectionContextCard: View {
  let context: ConversationContext
  var isSent = false
  var isBusy = false
  let remove: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text("›")
        .font(EnigmaTypography.mono(12))
        .foregroundStyle(palette.textTertiary.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(context.title)
          .font(EnigmaTypography.mono(11.5, weight: .medium))
          .foregroundStyle(palette.accentText.color)
        Text(context.preview)
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textSecondary.color)
          .lineLimit(2)
        if isSent {
          Text(CompactSelectionStatus.sentNote)
            .font(EnigmaTypography.ui(11))
            .foregroundStyle(palette.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
            .enigmaTestMarker("Selection sent note")
        }
      }
      Spacer(minLength: 0)
      Button(action: remove) { Image(systemName: "xmark").font(EnigmaTypography.smallIconButtonSymbol) }
        .enigmaIconButtonStyle(size: CGSize(width: 24, height: 22))
        .help("Remove selected text")
        .accessibilityLabel("Remove selected text")
        .disabled(isBusy)
        .enigmaTestMarker("Remove selected text")
    }
    .enigmaCard(padding: 10)
  }
}

/// Selection Context needs Accessibility, and it isn't allowed yet.
struct AccessibilityNeededCard: View {
  let appName: String
  let openSettings: () -> Void
  @SelectionShortcutPhrase private var selectionShortcut

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EnigmaCardTitle("Action needed: allow Accessibility", systemImage: "exclamationmark.triangle")
      EnigmaNote("Allow \(appName) (Enigma) in System Settings → Privacy & Security → Accessibility to attach selected text when you \(selectionShortcut).")
      Button("Open Accessibility Settings…", action: openSettings)
        .enigmaButtonStyle(.compactPrimary)
        .padding(.top, 2)
        .enigmaTestMarker("Open Accessibility Settings…")
    }
    .enigmaCard()
  }
}
