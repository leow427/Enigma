import Combine
import Foundation

// Native tool calling (F32): what a model may read, and who the user allowed it to send it to.

/// Where a tool's result goes: this Mac, or the company whose model answers.
enum ToolDestination: String, Codable, Sendable, CaseIterable {
  case thisMac, openAI, anthropic, google, apple

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
    case .free: self = FreeModelCatalog.underlyingProvider(route.modelID) == nil ? .apple : .google
    case nil: return nil
    }
  }

  var displayName: String {
    switch self {
    case .thisMac: "this Mac"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .google: "Google"
    case .apple: "Apple"
    }
  }
}

/// What a tool asks to do. Only the chat GUID keys a read; the name is for the card.
enum ToolPermission: Sendable, Equatable {
  case readChat(chatGUID: String, name: String)
  case searchChats(query: String)
  /// `service` names who receives the query on the card: Brave with a saved key, otherwise the
  /// search sites (D131).
  case searchAfterMessages(query: String, service: String = ToolPermission.searchSitesService)
  /// `find_places` in a chat that holds message text (F29, spec §6.2): `title` is the card's question,
  /// such as "Find ramen in Soho?". Each of gate 3's tools has its own grant (owner, 2026-10-31).
  case placesAfterMessages(title: String)
  /// `get_weather` in a chat that holds message text, such as "Check the weather for Paris?".
  case weatherAfterMessages(title: String)
  /// Send a chat that holds message text to a destination its text wasn't allowed for.
  case shareMessageText
  /// Give a provider's own web search the approximate area (F30, spec §2a). Granted per provider,
  /// never per destination; the area is for the card and never saved.
  case shareLocation(provider: CloudProviderID, area: String)
  /// Let a provider's own web search run in a chat that holds message text (owner, 2026-10-29). Its
  /// queries run on the provider's servers, where no card can ask, so this asks once, per provider.
  case providerSearchAfterMessages(provider: CloudProviderID)
}

extension ToolPermission {
  /// Who gets `web_search`'s query on gate 3's card when it runs on this Mac (D131).
  static let searchSitesService = "search sites"
  /// Who gets `find_places`' and `get_weather`'s questions on gate 3's cards.
  static let placesService = "Apple Maps"
  static let weatherService = "Open-Meteo"
}

enum ToolPermissionAnswer: Sendable { case deny, conversation, always }

struct ToolAlwaysGrant: Codable, Hashable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable {
    case readChat, searchChats, searchAfterMessages, placesAfterMessages, weatherAfterMessages, shareMessageText,
         shareLocation, providerSearchAfterMessages
  }

  let kind: Kind
  let chatGUID: String?
  /// The chat's name when it was granted, for the Settings list.
  let chatName: String?
  /// Nil for gate 3's kinds, which cover every destination, and for the per-provider kinds.
  let destination: ToolDestination?
  /// Only `shareLocation`'s and `providerSearchAfterMessages`'s provider: ChatGPT and the OpenAI API
  /// share a destination, but not these grants (F30). Grants saved before it decode with none.
  var provider: CloudProviderID? = nil

  var id: Key { key }

  /// What a grant covers. The chat's name is only shown, never matched.
  struct Key: Hashable, Sendable {
    let kind: Kind
    let chatGUID: String?
    let destination: ToolDestination?
    var provider: CloudProviderID? = nil
  }

  var key: Key { Key(kind: kind, chatGUID: chatGUID, destination: destination, provider: provider) }

  init(kind: Kind, chatGUID: String?, chatName: String?, destination: ToolDestination?, provider: CloudProviderID? = nil) {
    self.kind = kind
    self.chatGUID = chatGUID
    self.chatName = chatName
    self.destination = destination
    self.provider = provider
  }

  init(_ permission: ToolPermission, destination: ToolDestination) {
    switch permission {
    case .readChat(let guid, let name):
      self.init(kind: .readChat, chatGUID: guid, chatName: name, destination: destination)
    case .searchChats:
      self.init(kind: .searchChats, chatGUID: nil, chatName: nil, destination: destination)
    case .searchAfterMessages:
      self.init(kind: .searchAfterMessages, chatGUID: nil, chatName: nil, destination: nil)
    case .placesAfterMessages:
      self.init(kind: .placesAfterMessages, chatGUID: nil, chatName: nil, destination: nil)
    case .weatherAfterMessages:
      self.init(kind: .weatherAfterMessages, chatGUID: nil, chatName: nil, destination: nil)
    case .shareMessageText:
      self.init(kind: .shareMessageText, chatGUID: nil, chatName: nil, destination: destination)
    case .shareLocation(let provider, _):
      self.init(kind: .shareLocation, chatGUID: nil, chatName: nil, destination: nil, provider: provider)
    case .providerSearchAfterMessages(let provider):
      self.init(kind: .providerSearchAfterMessages, chatGUID: nil, chatName: nil, destination: nil, provider: provider)
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
  /// The companies all of each session's message text was allowed to go to, so it never moves
  /// on without asking. This Mac is always allowed.
  private var messageTextDestinations: [UUID: Set<ToolDestination>] = [:]
  let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    alwaysGrants = defaults.data(forKey: Self.defaultsKey)
      .flatMap { try? JSONDecoder().decode([ToolAlwaysGrant].self, from: $0) } ?? []
  }

  func isGranted(_ permission: ToolPermission, destination: ToolDestination, session: UUID) -> Bool {
    if case .shareMessageText = permission { return messageTextAllowed(session: session, destination: destination) }
    let key = ToolAlwaysGrant(permission, destination: destination).key
    return conversationGrants[session]?.contains(key) == true || alwaysGrants.contains { $0.key == key }
  }

  func record(_ answer: ToolPermissionAnswer, for permission: ToolPermission,
              destination: ToolDestination, session: UUID) {
    if case .shareMessageText = permission {
      // Asked per chat only: the card offers no Always.
      if answer != .deny { messageTextDestinations[session, default: []].insert(destination) }
      return
    }
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
    messageTextDestinations[session] = nil
  }

  /// Message text entered the session, allowed for `destination`. The history may then go only
  /// where every piece of text was allowed, so a read kept on this Mac takes the companies out.
  /// Only the share card adds one back.
  func markMessageText(session: UUID, destination: ToolDestination = .thisMac) {
    let allowed: Set<ToolDestination> = destination == .thisMac ? [] : [destination]
    messageTextDestinations[session] = hasMessageText(session: session)
      ? (messageTextDestinations[session] ?? []).intersection(allowed) : allowed
    sessionsWithMessageText.insert(session)
  }

  /// Whether the session's history may go to `destination`: this Mac, a session without message
  /// text, or a company all of its text was allowed for.
  func messageTextAllowed(session: UUID, destination: ToolDestination) -> Bool {
    destination == .thisMac || !hasMessageText(session: session)
      || messageTextDestinations[session]?.contains(destination) == true
  }

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
