import Foundation

/// One row in the sidebar's chat history.
struct ChatHistoryRow: Equatable, Identifiable {
  enum Target: Hashable {
    /// Shown when there's no history yet. Opens a new chat.
    case newChat
    case session(UUID)
  }

  let target: Target
  let title: String
  /// Nil for chats with no messages yet.
  let date: Date?
  let isSelected: Bool

  var id: Target { target }
}

enum ChatHistoryList {
  /// Every chat the store keeps; the sidebar scrolls when they don't fit.
  static let visibleCount = ChatSessionStore.maximumRetainedSessions

  static func rows(sessions: [ChatSession], selectedSessionID: UUID?) -> [ChatHistoryRow] {
    guard !sessions.isEmpty else {
      return [ChatHistoryRow(target: .newChat, title: "New Chat", date: nil, isSelected: true)]
    }
    return sessions.prefix(visibleCount).map { session in
      ChatHistoryRow(
        target: .session(session.id),
        title: session.title,
        date: session.messages.isEmpty ? nil : session.lastActivityAt,
        isSelected: session.id == selectedSessionID
      )
    }
  }
}
