import CoreGraphics
import Foundation

// Logic the conversation view would otherwise hide inline: which rows it
// shows, which reply the character sits beside, and what a reply's meta line
// says. Each is a plain value, so it can be tested without a view.

/// A chat as the window lays it out: the person's messages, and Enigma's
/// replies, including the one on its way while a request prepares. The latest
/// reply holds the character's 30 pt slot; earlier replies show the mark.
struct ConversationTranscript: Equatable {
  enum Row: Equatable, Identifiable {
    /// Something the person sent.
    case message(ChatMessage)
    case reply(Reply)

    var id: UUID {
      switch self {
      case .message(let message): message.id
      case .reply(let reply): reply.id
      }
    }
  }

  struct Reply: Equatable {
    /// The request's id while it prepares and once its reply is written, so
    /// the row and the character's slot carry over when the reply arrives.
    let id: UUID
    /// Nil while the request prepares, before any reply is written.
    let message: ChatMessage?
    /// The request's activity, or the sources a saved reply used.
    let activity: AssistantActivity?
    /// The newest reply, which the character sits beside.
    let isLatest: Bool
    /// The running request's reply, which has no meta line yet.
    let isInProgress: Bool

    var content: String { message?.content ?? "" }

    /// Waiting for the first words with no activity to show.
    var showsThinking: Bool { isInProgress && content.isEmpty && activity == nil }

    var slot: EnigmaCharacterSlotID { ConversationTranscript.slot(forReply: id) }

    /// The reply used web sources.
    var searched: Bool {
      !(activity?.sources.isEmpty ?? true) || !(message?.searchSources?.isEmpty ?? true)
    }
  }

  /// Beside each reply, where the character or the mark sits.
  static let slotSize: CGFloat = 30
  /// The mark an earlier reply keeps, inside its slot.
  static let markSize: CGFloat = 22

  let rows: [Row]

  /// `messages` are the chat's presentation messages, `activity` the running
  /// request's, and `isResponding` whether a request is running.
  init(messages: [ChatMessage], activity: AssistantActivity?, isResponding: Bool) {
    var rows: [Row] = []
    for message in messages {
      switch message.role {
      case .user:
        rows.append(.message(message))
      case .assistant:
        let activity = message.activity ?? message.searchSources.flatMap { sources in
          sources.isEmpty ? nil : AssistantActivity.savedSources(sources, messageID: message.id)
        }
        rows.append(.reply(Reply(id: message.activity?.id ?? message.id, message: message, activity: activity,
                                 isLatest: false, isInProgress: false)))
      }
    }
    // A request that's preparing has no reply yet: its activity stands in,
    // after the last message.
    if let activity, messages.last?.role != .assistant {
      rows.append(.reply(Reply(id: activity.id, message: nil, activity: activity, isLatest: false,
                               isInProgress: false)))
    }
    if let index = rows.lastIndex(where: { if case .reply = $0 { return true }; return false }),
       case .reply(let reply) = rows[index] {
      let running = isResponding && index == rows.count - 1
      rows[index] = .reply(Reply(id: reply.id, message: reply.message, activity: reply.activity, isLatest: true,
                                 isInProgress: running))
    }
    self.rows = rows
  }

  /// The slot of the reply the character sits beside, if the chat has one.
  var latestReplySlot: EnigmaCharacterSlotID? {
    for row in rows.reversed() {
      if case .reply(let reply) = row { return reply.slot }
    }
    return nil
  }

  /// The same slot as `latestReplySlot`, without building the rows, for the
  /// window to check on every update.
  static func latestReplySlot(messages: [ChatMessage], activity: AssistantActivity?) -> EnigmaCharacterSlotID? {
    if let activity, messages.last?.role != .assistant { return slot(forReply: activity.id) }
    guard let reply = messages.last(where: { $0.role == .assistant }) else { return nil }
    return slot(forReply: reply.activity?.id ?? reply.id)
  }

  static func slot(forReply id: UUID) -> EnigmaCharacterSlotID {
    EnigmaCharacterSlotID("chat.reply.\(id.uuidString)")
  }
}

/// How the character gets to its new slot when the window's chat changes.
enum ChatCharacterMove {
  /// Within the open chat it moves: it falls from the main page into the first
  /// reply and moves down to each newer one. Opening another chat, or going
  /// back to the main page for a new one, puts it there at once. A chat that
  /// the current send created, as when nothing was selected yet, is the same
  /// chat.
  static func transition(fromSession old: UUID?, toSession new: UUID?, isResponding: Bool) -> EnigmaCharacterTransition {
    if old == new || (old == nil && isResponding) { return .automatic }
    return .instant
  }
}

/// Where the latest reply's character slot sits in the track beside it.
/// It rests at the reply's first line. When the reply's start scrolls above
/// the chat, it stays just under the chat's top edge, until the reply's end
/// would leave it behind. It counts as visible only while it's wholly inside
/// the chat, so the character never draws past the chat's edges.
struct ReplySlotPlacement: Equatable {
  /// Beside the first line of serif text, as in the mockup.
  static let restingOffset: CGFloat = -4
  /// Under the chat's top edge, leaving room for the antenna.
  static let topMargin: CGFloat = 14
  static let resting = ReplySlotPlacement(offset: restingOffset, isVisible: true)
  /// Before the slot's first measurement: not reported, so the character
  /// never heads for a point that may be off screen. Its move waits for it.
  static let waiting = ReplySlotPlacement(offset: restingOffset, isVisible: false)

  var offset: CGFloat
  var isVisible: Bool

  init(offset: CGFloat, isVisible: Bool) {
    self.offset = offset
    self.isVisible = isVisible
  }

  /// `viewport` is the visible chat in the track's own space, or nil outside a
  /// scrolling chat, where the slot rests and counts as visible.
  init(trackHeight: CGFloat, viewport: CGRect?, slot: CGFloat) {
    guard let viewport else {
      self = .resting
      return
    }
    let lowest = max(Self.restingOffset, trackHeight - slot)
    offset = min(max(Self.restingOffset, viewport.minY + Self.topMargin), lowest)
    isVisible = offset >= viewport.minY - 1 && offset + slot <= viewport.maxY + 1
  }
}

/// The monospace line under a finished reply: `model · where it ran · time`,
/// from what the reply recorded. A reply from an earlier session didn't record
/// its model, so it shows only what it has. Search reads "brave search" only when Brave answered
/// (a Brave key was saved, D131); on-device and the provider's own search are "web search".
enum ReplyMetaLine {
  static func text(origin: ReplyOrigin?, searched: Bool, date: Date, now: Date = .now,
                   calendar: Calendar = .current, locale: Locale = .current) -> String {
    var parts: [String] = []
    if let origin {
      if !origin.modelName.isEmpty { parts.append(origin.modelName) }
      parts.append(place(origin))
    }
    if searched { parts.append(origin?.braveSearch == true ? "brave search" : "web search") }
    parts.append(time(date, now: now, calendar: calendar, locale: locale))
    return parts.joined(separator: " · ")
  }

  /// Where the reply ran, in the mockup's lowercase: on this Mac, or the cloud provider.
  static func place(_ origin: ReplyOrigin) -> String {
    if origin.mode == .local { return "on this mac" }
    return switch CloudProviderID(rawValue: origin.providerID) {
    case .chatGPT: "chatgpt"
    case .claudeCode: "claude code"
    case .openAI: "openai"
    case .anthropic: "anthropic"
    case .gemini: "gemini"
    case nil: origin.providerID.lowercased()
    }
  }

  /// The time alone for a reply from today, and the date with it otherwise.
  static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    var style = calendar.isDate(date, inSameDayAs: now)
      ? Date.FormatStyle(date: .omitted, time: .shortened)
      : Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
    style.locale = locale
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }
}
