import AppKit
import SwiftUI

// The conversation in the new design: the person's messages as right-aligned
// bubbles, and replies in the serif with the character, or the mark, in a
// 30 pt slot beside them and a monospace meta line under them. AppShellView
// owns the chat and every action; these views only lay it out, so the compact
// panel can reuse them at its narrower width.

/// The chat's scrolling list. It keeps the old list's behavior: it opens at
/// the bottom, follows new content only while the reader stays at the end,
/// and AppShellView gives it a new identity for each chat.
struct EnigmaMessageList<Revision: View>: View {
  let transcript: ConversationTranscript
  /// Changes with anything that should keep a reader at the bottom following it.
  let scrollRevision: String
  let activityExpansion: (UUID) -> Binding<Bool>
  /// The /edit revision card under a reply, if it has one.
  @ViewBuilder let revision: (ChatMessage) -> Revision
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Between one exchange and the next, and between a message and its reply.
  static var exchangeSpacing: CGFloat { 22 }
  static var replySpacing: CGFloat { 16 }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(transcript.rows.enumerated()), id: \.element.id) { index, row in
            rowView(row)
              .padding(.top, index == 0 ? 0 : spacing(before: row))
          }
        }
        .frame(maxWidth: MainPageLayout.columnMaximumWidth)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        // Messages gather at the bottom, by the composer, as in the mockup.
        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
        .background(ConversationScrollObserver(contentRevision: scrollRevision).allowsHitTesting(false))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.rowEnter.animation,
                   value: transcript.rows.map(\.id))
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(.top, for: .alignment)
    }
  }

  private func spacing(before row: ConversationTranscript.Row) -> CGFloat {
    if case .reply = row { return Self.replySpacing }
    return Self.exchangeSpacing
  }

  @ViewBuilder private func rowView(_ row: ConversationTranscript.Row) -> some View {
    switch row {
    case .message(let message):
      EnigmaUserMessage(message: message)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 18)))
    case .reply(let reply):
      EnigmaReplyView(reply: reply, expandedActivity: activityExpansion(reply.activity?.id ?? reply.id)) {
        if let message = reply.message { revision(message) }
      }
      // The reply follows its question a moment later, as in the mockup.
      .transition(reduceMotion ? .opacity
                  : .opacity.combined(with: .offset(y: 8)).animation(EnigmaMotion.rowEnter.animation.delay(0.14)))
    }
  }
}

// MARK: The person's message

/// Something the person sent: a `userBubble` on the right, with any attached
/// files and sent image above it.
struct EnigmaUserMessage: View {
  let message: ChatMessage
  @Environment(\.enigmaPalette) private var palette

  /// The mockup's 78% of the chat column.
  static let maximumWidth: CGFloat = 530

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let attachments = message.attachments {
        ForEach(attachments.indices, id: \.self) { index in
          HStack(spacing: 5) {
            Image(systemName: attachments[index].isDirectory ? "folder" : "doc")
              .font(.system(size: 10.5))
              .accessibilityHidden(true)
            Text(attachments[index].name).lineLimit(2)
          }
          .font(EnigmaTypography.mono(11.5))
          .foregroundStyle(palette.textSecondary.color)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Attached \(attachments[index].isDirectory ? "folder" : "file") \(attachments[index].name)")
        }
      }
      if let data = message.imagePreview, let image = NSImage(data: data) {
        EnigmaSentImage(image: image)
      }
      if !message.content.isEmpty {
        Text(verbatim: message.content)
          .font(EnigmaTypography.ui(14))
          .lineSpacing(3)
          .foregroundStyle(palette.textPrimary.color)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .background(palette.userBubble.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityLabel("You: " + message.content)
          .enigmaTestMarker("Your message")
      }
    }
    .frame(maxWidth: Self.maximumWidth, alignment: .trailing)
    .padding(.leading, 48)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// An image sent with a message, kept small and in proportion, with a `border` edge.
struct EnigmaSentImage: View {
  let image: NSImage
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let scale = min(1, 120 / max(1, image.size.width), 96 / max(1, image.size.height))
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    Image(nsImage: image)
      .resizable()
      .scaledToFit()
      .frame(width: image.size.width * scale, height: image.size.height * scale)
      .clipShape(shape)
      .enigmaEdge(shape)
      .accessibilityLabel("Image attached to your message")
  }
}

// MARK: Replies

/// One of Enigma's replies: the character's slot, or the mark, on the left;
/// then the activity, the serif text, any revision card, and the meta line.
struct EnigmaReplyView<Revision: View>: View {
  let reply: ConversationTranscript.Reply
  var expandedActivity: Binding<Bool>?
  @ViewBuilder var revision: () -> Revision
  @Environment(\.enigmaPalette) private var palette

  init(reply: ConversationTranscript.Reply, expandedActivity: Binding<Bool>? = nil,
       @ViewBuilder revision: @escaping () -> Revision) {
    self.reply = reply
    self.expandedActivity = expandedActivity
    self.revision = revision
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // The slot's column; the slot itself rides in the overlay, which spans the reply's height.
      Color.clear.frame(width: ConversationTranscript.slotSize, height: 1)
      VStack(alignment: .leading, spacing: 8) {
        if let activity = reply.activity {
          EnigmaActivityView(activity: activity, expanded: expandedActivity)
        } else if reply.showsThinking {
          EnigmaThinkingLine()
        }
        if !reply.content.isEmpty {
          EnigmaMarkdownView(content: reply.content)
            .enigmaTestMarker("Reply")
        }
        revision()
        if !reply.isInProgress, let message = reply.message {
          Text(ReplyMetaLine.text(origin: message.origin, searched: reply.searched, date: message.createdAt))
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.top, 2)
            .enigmaTestMarker("Reply meta")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .overlay(alignment: .topLeading) {
      EnigmaReplySlot(reply: reply)
    }
  }
}

extension EnigmaReplyView where Revision == EmptyView {
  init(reply: ConversationTranscript.Reply, expandedActivity: Binding<Bool>? = nil) {
    self.init(reply: reply, expandedActivity: expandedActivity) { EmptyView() }
  }
}

/// The 30 pt square beside a reply, in a track as tall as the reply. Earlier
/// replies keep the outline mark at its top; the latest reply's track holds
/// the character's slot.
private struct EnigmaReplySlot: View {
  let reply: ConversationTranscript.Reply

  var body: some View {
    let size = ConversationTranscript.slotSize
    Color.clear
      .frame(width: size)
      .frame(maxHeight: .infinity)
      .overlay(alignment: .top) {
        if reply.isLatest {
          EnigmaLatestReplySlot(slot: reply.slot)
        } else {
          EnigmaMark(style: .outline)
            .frame(width: ConversationTranscript.markSize, height: ConversationTranscript.markSize)
            .opacity(0.55)
            .frame(width: size, height: size)
            .offset(y: ReplySlotPlacement.restingOffset)
            .enigmaTestMarker("Earlier reply mark")
        }
      }
      .allowsHitTesting(false)
  }
}

/// The character's slot beside the latest reply. It scrolls with the reply,
/// stays in view at the top of the chat while a long reply's start is
/// scrolled away, and is reported only while it's inside the visible chat, so
/// the character never floats over the window's edge. It waits for its first
/// measurement before it's reported. Only this one slot watches the scroll.
private struct EnigmaLatestReplySlot: View {
  let slot: EnigmaCharacterSlotID
  @State private var placement = ReplySlotPlacement.waiting

  var body: some View {
    let size = ConversationTranscript.slotSize
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .top) {
        Group {
          if placement.isVisible {
            Color.clear.enigmaCharacterSlot(id: slot, size: size, movesWithContent: true)
          } else {
            Color.clear.frame(width: size, height: size)
          }
        }
        .offset(y: placement.offset)
      }
      .onGeometryChange(for: ReplySlotPlacement.self) { proxy in
        // The visible chat, in this track's own space.
        ReplySlotPlacement(trackHeight: proxy.size.height, viewport: proxy.bounds(of: .scrollView), slot: size)
      } action: { placement in
        self.placement = placement
      }
  }
}

/// Waiting for the first words when there's no activity to show. VoiceOver
/// reads "Thinking", as the old Thinking row did; the character in the slot
/// beside it thinks too.
private struct EnigmaThinkingLine: View {
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(EnigmaStatusLine.Status.busy.glyph)
      Text("thinking…")
    }
    .font(EnigmaTypography.mono(11.5))
    .foregroundStyle(palette.textSecondary.color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thinking")
  }
}

// MARK: Notes over the composer

/// A short notice over the composer, like a trimmed-context note or
/// "Temporary chat · Not saved to history", right-aligned under the route's
/// status. Route details are monospace; sentences use the system font.
struct EnigmaChatNote: View {
  let text: String
  var monospaced = false
  @Environment(\.enigmaPalette) private var palette

  init(_ text: String, monospaced: Bool = false) {
    self.text = text
    self.monospaced = monospaced
  }

  var body: some View {
    Text(text)
      .font(monospaced ? EnigmaTypography.mono(11) : EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .multilineTextAlignment(.trailing)
      .fixedSize(horizontal: false, vertical: true)
  }
}
