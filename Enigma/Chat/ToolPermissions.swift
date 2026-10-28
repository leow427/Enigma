import Combine
import Foundation

// Native tool calling (F32): what a model may read, and who the user allowed it to send it to.

/// Where a tool's result goes: this Mac, or the company whose model answers.
enum ToolDestination: String, Codable, Sendable, CaseIterable {
  case thisMac, openAI, anthropic, google

  /// Nil for a cloud route whose provider Enigma doesn't know, so no card can name the wrong company.
  init?(route: Route) {
    if route.mode == .local {
      self = .thisMac
      return
    }
    switch CloudProviderID(rawValue: route.providerID) {
    case .chatGPT, .openAI: self = .openAI
    case .claudeCode, .anthropic: self = .anthropic
    case .gemini: self = .google
    case nil: return nil
    }
  }

  var displayName: String {
    switch self {
    case .thisMac: "this Mac"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .google: "Google"
    }
  }
}

/// What a tool asks to do. Only the chat GUID keys a read; the name is for the card.
enum ToolPermission: Sendable, Equatable {
  case readChat(chatGUID: String, name: String)
  case searchChats(query: String)
  case searchAfterMessages(query: String)
}

enum ToolPermissionAnswer: Sendable { case deny, conversation, always }

struct ToolAlwaysGrant: Codable, Hashable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable { case readChat, searchChats, searchAfterMessages }

  let kind: Kind
  let chatGUID: String?
  /// The chat's name when it was granted, for the Settings list.
  let chatName: String?
  /// Nil for `searchAfterMessages`, which covers every destination.
  let destination: ToolDestination?

  var id: Key { key }

  /// What a grant covers. The chat's name is only shown, never matched.
  struct Key: Hashable, Sendable {
    let kind: Kind
    let chatGUID: String?
    let destination: ToolDestination?
  }

  var key: Key { Key(kind: kind, chatGUID: chatGUID, destination: destination) }

  init(kind: Kind, chatGUID: String?, chatName: String?, destination: ToolDestination?) {
    self.kind = kind
    self.chatGUID = chatGUID
    self.chatName = chatName
    self.destination = destination
  }

  init(_ permission: ToolPermission, destination: ToolDestination) {
    switch permission {
    case .readChat(let guid, let name):
      self.init(kind: .readChat, chatGUID: guid, chatName: name, destination: destination)
    case .searchChats:
      self.init(kind: .searchChats, chatGUID: nil, chatName: nil, destination: destination)
    case .searchAfterMessages:
      self.init(kind: .searchAfterMessages, chatGUID: nil, chatName: nil, destination: nil)
    }
  }
}

/// The user's answers to permission cards. Always grants are saved in settings; conversation grants
/// and whether a chat holds message text live only in memory, per chat session.
@MainActor
final class ToolGrantStore: ObservableObject {
  static let shared = ToolGrantStore(defaults: TestHost.isActive ? scratchDefaults() : .standard)
  static let defaultsKey = "tools.alwaysGrants"

  @Published private(set) var alwaysGrants: [ToolAlwaysGrant]
  private var conversationGrants: [UUID: Set<ToolAlwaysGrant.Key>] = [:]
  private var sessionsWithMessageText: Set<UUID> = []
  let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    alwaysGrants = defaults.data(forKey: Self.defaultsKey)
      .flatMap { try? JSONDecoder().decode([ToolAlwaysGrant].self, from: $0) } ?? []
  }

  func isGranted(_ permission: ToolPermission, destination: ToolDestination, session: UUID) -> Bool {
    let key = ToolAlwaysGrant(permission, destination: destination).key
    return conversationGrants[session]?.contains(key) == true || alwaysGrants.contains { $0.key == key }
  }

  func record(_ answer: ToolPermissionAnswer, for permission: ToolPermission,
              destination: ToolDestination, session: UUID) {
    let grant = ToolAlwaysGrant(permission, destination: destination)
    switch answer {
    case .deny: return
    case .conversation: conversationGrants[session, default: []].insert(grant.key)
    case .always:
      // A renamed chat keeps one row, under its newest name.
      alwaysGrants.removeAll { $0.key == grant.key }
      alwaysGrants.append(grant)
      save()
    }
  }

  func remove(_ grant: ToolAlwaysGrant) {
    alwaysGrants.removeAll { $0.key == grant.key }
    save()
  }

  /// Drops the session's conversation grants and its message-text mark. Always grants stay.
  func endSession(_ session: UUID) {
    conversationGrants[session] = nil
    sessionsWithMessageText.remove(session)
  }

  func markMessageText(session: UUID) { sessionsWithMessageText.insert(session) }

  func hasMessageText(session: UUID) -> Bool { sessionsWithMessageText.contains(session) }

  private func save() {
    guard let data = try? JSONEncoder().encode(alwaysGrants) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  /// The test host shares the app's defaults, so hosted tests never see or change the owner's grants.
  private static func scratchDefaults() -> UserDefaults {
    let name = "ToolGrantStore.testHost"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}
