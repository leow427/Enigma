import AppKit
import SwiftUI

// The conversation: the person's messages as right-aligned
// bubbles, and replies in the serif with the character, or the mark, in a
// 30 pt slot beside them and a monospace meta line under them. AppShellView
// owns the chat and every action; these views only lay it out, so the compact
// panel can reuse them at its narrower width.

/// The chat's scrolling list. It opens at the bottom, follows new content only
/// while the reader stays at the end, and AppShellView gives it a new identity
/// for each chat.
struct EnigmaMessageList<Revision: View>: View {
  let transcript: ConversationTranscript
  /// Changes with anything that should keep a reader at the bottom following it.
  let scrollRevision: String
  /// Changes when the person sends a message, which brings the end back into view.
  var sendRevision = ""
  let activityExpansion: (UUID) -> Binding<Bool>
  /// Messages typed while a reply ran, drawn after the chat with a dashed
  /// outline. They're never part of the transcript.
  var queued: [QueuedMessage] = []
  var sendQueuedNow: (UUID) -> Void = { _ in }
  var cancelQueued: (UUID) -> Void = { _ in }
  /// A quiet monospace line under the messages, in the replies' meta style,
  /// like the note that a chat kept from the panel is now saved. It's never
  /// part of the transcript.
  var footnote: String? = nil
  /// The /edit revision card under a reply, if it has one.
  @ViewBuilder let revision: (ChatMessage) -> Revision
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Between one exchange and the next, and between a message and its reply.
  static var exchangeSpacing: CGFloat { 22 }
  static var replySpacing: CGFloat { 16 }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        // Not lazy: a LazyVStack sizes rows it hasn't drawn from an estimate,
        // so after a tall reply a new message can grow the chat by hundreds of
        // points of empty space, and following the end scrolls into it. A plain
        // stack keeps exact heights but lays out every row on each update:
        // fine for the short chats Enigma intends, slower in very long ones.
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(transcript.rows.enumerated()), id: \.element.id) { index, row in
            rowView(row)
              .padding(.top, index == 0 ? 0 : spacing(before: row))
          }
          ForEach(Array(queued.enumerated()), id: \.element.id) { index, message in
            EnigmaQueuedMessage(message: message, sendNow: { sendQueuedNow(message.id) },
                                cancel: { cancelQueued(message.id) })
              .padding(.top, index == 0 && transcript.rows.isEmpty ? 0 : Self.replySpacing)
              .transition(.opacity)
          }
          if let footnote {
            EnigmaFootnote(text: footnote)
              .padding(.top, transcript.rows.isEmpty && queued.isEmpty ? 0 : Self.replySpacing)
          }
        }
        .frame(maxWidth: MainPageLayout.columnMaximumWidth)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        // Messages gather by the composer, as in the mockups.
        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
        .background(ConversationScrollObserver(contentRevision: scrollRevision, sendRevision: sendRevision).allowsHitTesting(false))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.rowEnter.animation,
                   value: transcript.rows.map(\.id))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.rowEnter.animation, value: queued.map(\.id))
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

/// A quiet monospace line under the messages, in the meta line's style.
struct EnigmaFootnote: View {
  let text: String
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Text(text)
      .font(EnigmaTypography.mono(11))
      .foregroundStyle(palette.textTertiary.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .enigmaTestMarker("Chat footnote \(text)")
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
              .font(EnigmaTypography.symbol(10.5))
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
        SentImagePreview(image: image)
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

/// A message waiting to send: the person's bubble with a dashed outline in
/// place of its fill, an x that cancels it, and under it "Send now" with a
/// clock, so it reads as waiting rather than sent. It turns into an ordinary,
/// solid bubble once it's sent.
struct EnigmaQueuedMessage: View {
  let message: QueuedMessage
  let sendNow: () -> Void
  let cancel: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    VStack(alignment: .trailing, spacing: 4) {
      Text(verbatim: message.text)
        .font(EnigmaTypography.ui(14))
        .lineSpacing(3)
        .foregroundStyle(palette.textSecondary.color)
        // Selectable, as a sent message is: editing one means copying it before cancelling.
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .overlay { EnigmaEdgeStroke(shape: shape, isDashed: true) }
        .accessibilityLabel("Queued: " + message.text)
        .enigmaTestMarker("Queued message")
        // In the bubble's left margin, so the bubble is as wide as it will be once sent.
        .overlay(alignment: .leading) {
          Button(action: cancel) {
            Image(systemName: "xmark").font(EnigmaTypography.symbol(10))
          }
          .enigmaIconButtonStyle(size: CGSize(width: 22, height: 22))
          .accessibilityLabel("Cancel queued message: " + message.text)
          .help("Cancel this message")
          .enigmaTestMarker("Cancel queued message")
          .offset(x: -26)
        }
      Button(action: sendNow) {
        HStack(spacing: 4) {
          Image(systemName: "clock").font(EnigmaTypography.symbol(10)).accessibilityHidden(true)
          Text("Send now")
        }
        .font(EnigmaTypography.mono(11))
      }
      .enigmaButtonStyle(.text)
      .accessibilityLabel("Send now: " + message.text)
      .help("Send this message now, stopping any reply")
      .enigmaTestMarker("Send queued message now")
    }
    .frame(maxWidth: EnigmaUserMessage.maximumWidth, alignment: .trailing)
    .padding(.leading, 48)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// An image sent with a message, kept small and in proportion, with a `border` edge.
struct SentImagePreview: View {
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
  /// Whether the pointer is over the reply, which brightens its copy button.
  @State private var isHovered = false

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
          AssistantActivityView(activity: activity, expanded: expandedActivity)
        } else if reply.showsThinking {
          EnigmaThinkingLine()
        }
        if !reply.content.isEmpty {
          ChatMarkdownView(content: reply.content)
            .enigmaTestMarker("Reply")
        }
        revision()
        if !reply.isInProgress, let message = reply.message {
          HStack(spacing: 8) {
            Text(ReplyMetaLine.text(origin: message.origin, searched: reply.searched, date: message.createdAt))
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textTertiary.color)
              .lineLimit(1)
              .truncationMode(.middle)
              .enigmaTestMarker("Reply meta")
            Spacer(minLength: 0)
            if !reply.content.allSatisfy(\.isWhitespace) {
              ChatCopyButton(label: "Copy reply", isEmphasized: isHovered, size: CGSize(width: 24, height: 18)) {
                .reply(reply.content)
              }
            }
          }
          .padding(.top, 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
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
/// reads "Thinking"; the character in the slot beside it thinks too.
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
/// "Automatic replacement was not sent", right-aligned under the route's
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

// MARK: Following the end of the chat

/// Follow new layout only while the reader remains at the end of the chat, or
/// has just sent a message.
struct ConversationScrollObserver: NSViewRepresentable {
  var contentRevision = ""
  var sendRevision = ""
  func makeNSView(context: Context) -> ObserverView { ObserverView() }
  func updateNSView(_ view: ObserverView, context: Context) {
    view.sendChanged(sendRevision)
    view.contentChanged(contentRevision)
  }

  final class ObserverView: NSView {
    private var contentRevision = ""
    /// Every send this list has shown. The first value is the chat as opened, and
    /// going back to an earlier one (a failed send removed) isn't a new send.
    private var seenSends: Set<String>?
    func sendChanged(_ revision: String) {
      guard let seen = seenSends else { seenSends = [revision]; return }
      guard !seen.contains(revision) else { return }
      seenSends?.insert(revision)
      // Sending is an explicit wish to see the message and its reply.
      followsLatest = true
      isLiveScrolling = false
      isSettlingDocumentLayout = true
      pendingScroll?.cancel()
      pendingScroll = nil
      scheduleScroll()
    }
    func contentChanged(_ revision: String) {
      guard revision != contentRevision else { return }
      contentRevision = revision
      scheduleScroll()
    }
    private var pendingScroll: DispatchWorkItem?
    private weak var observedScroll: NSScrollView?
    private var previousClipBounds = NSRect.zero
    private var previousDocumentSize = NSSize.zero
    private var isAdjustingScroll = false
    private var isSettlingDocumentLayout = false
    private var isLiveScrolling = false
    private var hasPositionedInitially = false
    private(set) var followsLatest = true

    override func setFrameSize(_ newSize: NSSize) {
      let changed = frame.size != newSize
      super.setFrameSize(newSize)
      if changed { scheduleScroll() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disconnect()
      if window != nil {
        connect()
        scheduleScroll()
      }
    }

    private func connect() {
      guard let scroll = enclosingScrollView, observedScroll !== scroll else { return }
      observedScroll = scroll
      rememberGeometry()
      scroll.contentView.postsBoundsChangedNotifications = true
      let center = NotificationCenter.default
      if let document = scroll.documentView {
        document.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(documentLayoutChanged),
                           name: NSView.frameDidChangeNotification, object: document)
      }
      center.addObserver(self, selector: #selector(boundsChanged),
                         name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      center.addObserver(self, selector: #selector(beginScrolling),
                         name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      center.addObserver(self, selector: #selector(endScrolling),
                         name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    private func disconnect() {
      pendingScroll?.cancel()
      pendingScroll = nil
      NotificationCenter.default.removeObserver(self)
      observedScroll = nil
      isLiveScrolling = false
    }

    private var isAtBottom: Bool {
      guard let scroll = observedScroll, let document = scroll.documentView else { return false }
      let visible = scroll.contentView.bounds
      let distance = document.isFlipped
        ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
      return distance <= 2
    }

    private func rememberGeometry() {
      previousClipBounds = observedScroll?.contentView.bounds ?? .zero
      previousDocumentSize = observedScroll?.documentView?.bounds.size ?? .zero
    }

    @objc private func documentLayoutChanged() {
      isSettlingDocumentLayout = followsLatest
      rememberGeometry()
      scheduleScroll()
    }

    @objc private func beginScrolling() {
      isLiveScrolling = true
      followsLatest = false
      pendingScroll?.cancel()
      pendingScroll = nil
    }

    @objc private func endScrolling() {
      isLiveScrolling = false
      followsLatest = isAtBottom
      rememberGeometry()
      if followsLatest { scheduleScroll() }
    }

    @objc private func boundsChanged() {
      guard let scroll = observedScroll else { return }
      defer { rememberGeometry() }
      guard !isAdjustingScroll, hasPositionedInitially else { return }
      // Removing the waiting row can trigger a native offset correction after the
      // document notification. That correction is layout, not reader navigation.
      let event = NSApp.currentEvent
      let input = event?.type
      let recentInput = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp < 0.2 } ?? false
      let navigationKey = input == .keyDown && [115, 116, 119, 121, 125, 126].contains(Int(event?.keyCode ?? 0))
      let userNavigation = recentInput && (input == .scrollWheel || navigationKey || input == .leftMouseDragged || input == .leftMouseDown)
      if isSettlingDocumentLayout && !isLiveScrolling && !userNavigation { return }
      // Resizing/streaming changes geometry too. Only an offset change at the
      // same size is navigation; live gestures suspend following before layout.
      let bounds = scroll.contentView.bounds
      if isLiveScrolling || (bounds.origin != previousClipBounds.origin
          && bounds.size == previousClipBounds.size
          && scroll.documentView?.bounds.size == previousDocumentSize) {
        followsLatest = !isLiveScrolling && isAtBottom
        if !followsLatest { pendingScroll?.cancel(); pendingScroll = nil }
      }
    }

    private func scheduleScroll() {
      guard followsLatest, !isLiveScrolling, pendingScroll == nil else { return }
      let work = DispatchWorkItem { [weak self] in self?.scrollToBottomIfFollowing() }
      pendingScroll = work
      // Coalesce repeated layout changes; recheck reader intent at execution.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: work)
    }

    func scrollToBottomIfFollowing() {
      pendingScroll?.cancel()
      pendingScroll = nil
      connect()
      guard followsLatest, !isLiveScrolling, window != nil,
            let scroll = observedScroll, let document = scroll.documentView else { return }
      let clip = scroll.contentView
      let bottom = document.isFlipped
        ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        : document.bounds.minY
      isAdjustingScroll = true
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
      scroll.reflectScrolledClipView(clip)
      isAdjustingScroll = false
      hasPositionedInitially = true
      isSettlingDocumentLayout = false
      rememberGeometry()
    }
  }
}
