import Foundation

/// Asks before `MessagesTools` returns message text. Without a gate the tools behave as for a typed /messages.
protocol MessagesAccessGate: Sendable {
  /// Shows the read-a-chat card unless the chat is already allowed.
  func mayRead(chatGUID: String, name: String) async -> Bool
  /// Shows the search-all-chats card unless searching is already allowed.
  func maySearch(query: String) async -> Bool
  /// Whether a chat is already allowed, without a card; for previews.
  func isAllowed(chatGUID: String) async -> Bool
  /// Message text is now in the conversation, so later web searches ask first. Throws
  /// `ProviderSearchRestart` when the text must not reach this request (F30).
  func didReturnMessageText() async throws
}

/// The gate for one chat session and destination, answered through the permission card.
struct CoordinatorMessagesGate: MessagesAccessGate {
  let coordinator: ToolPermissionCoordinator
  let destination: ToolDestination
  let session: UUID

  init(coordinator: ToolPermissionCoordinator, destination: ToolDestination, session: UUID) {
    self.coordinator = coordinator
    self.destination = destination
    self.session = session
  }

  func mayRead(chatGUID: String, name: String) async -> Bool {
    await coordinator.authorize(.readChat(chatGUID: chatGUID, name: name), destination: destination, session: session)
  }

  func maySearch(query: String) async -> Bool {
    await coordinator.authorize(.searchChats(query: query), destination: destination, session: session)
  }

  func isAllowed(chatGUID: String) async -> Bool {
    await coordinator.store.isGranted(.readChat(chatGUID: chatGUID, name: ""), destination: destination, session: session)
  }

  func didReturnMessageText() async {
    await coordinator.store.markMessageText(session: session, destination: destination)
  }
}
