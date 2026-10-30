import Foundation

enum ChatMode: String, Codable, CaseIterable, Sendable, Identifiable {
  case auto
  case local
  case cloud

  var id: Self { self }

  var displayName: String { rawValue.capitalized }
}

struct Route: Codable, Sendable, Equatable {
  let mode: ChatMode
  let providerID: String
  let modelID: String
  let usesNetwork: Bool
}

/// The approximate location a provider's search may use once the user allows it for that provider
/// (F30, spec §2a). Never coordinates.
struct ProviderSearchLocation: Sendable, Equatable {
  var city: String?
  var region: String?
  /// ISO 3166-1 alpha-2.
  var countryCode: String?
  /// The Mac's IANA time zone identifier.
  var timeZone: String?

  /// "City, Region, Country" with missing parts left out, for the card and the instruction.
  var displayName: String {
    let country = countryCode.map { Locale(identifier: "en_US").localizedString(forRegionCode: $0) ?? $0 }
    return [city, region, country].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// A request that uses the provider's own web search tool instead of Enigma's `web_search` (F30).
struct ProviderSearch: Sendable, Equatable {
  /// F29's blocked sites, most recently blocked first. Empty until F29.
  var blockedDomains: [String] = []
  /// Set only for a nearby question, after the user allowed it for this provider (spec §2a).
  var location: ProviderSearchLocation? = nil
}

struct ChatRequest: Sendable, Equatable {
  let sessionID: UUID
  let messages: [ChatMessage]
  let route: Route
  var image: PreparedScreenImage? = nil
  var allowsCloudImages = false
  /// Nil: no provider search, as before F30.
  var providerSearch: ProviderSearch? = nil
}

enum ChatEvent: Sendable, Equatable {
  case activity(AssistantActivityEvent)
  case token(String)
  case completed
}

protocol ChatProvider: Sendable {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

struct MessageAttachment: Codable, Sendable, Equatable {
  let name: String
  let isDirectory: Bool
}

/// Where a reply ran: the model and route of the request that wrote it.
struct ReplyOrigin: Sendable, Equatable {
  let mode: ChatMode
  let providerID: String
  let modelName: String
  /// The provider's own web search ran the reply's searches (F30).
  var providerSearch = false
  /// Brave answered one of the reply's searches: a Brave key was saved (D128, D131).
  var braveSearch = false
}

struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
  enum Role: String, Codable, Sendable {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var content: String
  var searchSources: [WebSearchSource]?
  let createdAt: Date
  // Session-only UI data: never serialize screenshot pixels or send them as chat text.
  var activity: AssistantActivity? = nil
  var imagePreview: Data? = nil
  var extendedThinking: Bool? = nil
  var attachments: [MessageAttachment]? = nil
  var contexts: [ConversationContext]? = nil
  var selectionResponseMode: SelectionResponseMode? = nil
  var selectionDraft: String? = nil
  /// Session-only, like `activity`: the request a reply came from, for its meta line.
  var origin: ReplyOrigin? = nil

  private enum CodingKeys: String, CodingKey {
    case id, role, content, searchSources, createdAt, attachments
  }

  init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = .now, searchSources: [WebSearchSource]? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.searchSources = searchSources
    self.createdAt = createdAt
  }
}

struct ChatSession: Codable, Sendable, Equatable, Identifiable {
  let id: UUID
  var title: String
  var messages: [ChatMessage]
  let createdAt: Date
  var lastActivityAt: Date
  var workspace: WorkspaceSelection? = nil
  /// Message text from Messages entered this chat (F32), so a capable model's web searches
  /// ask first, after a relaunch too. Only this flag is saved, never the text or any grant.
  var holdsMessageText: Bool? = nil

  init(
    id: UUID = UUID(),
    title: String = "New Chat",
    messages: [ChatMessage] = [],
    createdAt: Date = .now,
    lastActivityAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
  }

  mutating func append(_ message: ChatMessage, at date: Date = .now) {
    messages.append(message)
    lastActivityAt = date
    if title == "New Chat", message.role == .user {
      title = Self.title(for: message.content)
    }
  }

  static func title(for content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "New Chat" }
    return String(trimmed.prefix(48))
  }
}
