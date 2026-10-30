import Foundation

struct WebSearchSource: Codable, Equatable, Sendable, Identifiable {
  let title: String
  let url: URL
  var id: URL { url }
}

/// What a result's text is: a read page, a search snippet, a places or weather excerpt, Wikidata's
/// facts or Google News's headlines (D111).
enum EvidenceKind: String, Codable, Sendable { case article, snippet, wikipedia, places, weather, facts, news }

struct WebSearchResult: Equatable, Sendable {
  let source: WebSearchSource
  let snippets: [String]
  var site: String? = nil
  var published: Date? = nil
  var kind: EvidenceKind = .article
  /// A places result's places, for the map card (CP9). In memory only, never saved.
  var places: [MapPlace]? = nil
}

enum SearchRoute: String, Equatable, Sendable { case web, places, weather }

/// Raw values are the search sites' date-filter codes.
enum SearchRecency: String, Equatable, Sendable { case day = "d", week = "w", month = "m", year = "y" }

/// Rounded to 2 decimals (about 1 km) before it leaves `ApproximateLocation`.
struct SearchCoordinate: Equatable, Sendable {
  let latitude: Double
  let longitude: Double
}

/// One search. Location travels in its own fields, never in `query`.
struct WebSearchRequest: Equatable, Sendable {
  var query: String
  var route: SearchRoute = .web
  var city: String? = nil
  var coordinate: SearchCoordinate? = nil
  var namedPlace: String? = nil
  var recency: SearchRecency? = nil
  var maximumTokens: Int
  /// The query is the user's typed question, not one a model wrote: the on-device provider turns
  /// it into keyword queries (D107).
  var isTypedQuestion = false
}

typealias AssistantActivitySink = @Sendable (AssistantActivityEvent) async -> Void

protocol WebSearchProvider: Sendable {
  func search(_ request: WebSearchRequest) async throws -> [WebSearchResult]
  func search(_ request: WebSearchRequest,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult]
  /// With the chat's local model for the on-device provider's helper calls (D107, D108); other
  /// providers ignore it.
  func search(_ request: WebSearchRequest, assistant: (any SearchModelAssistant)?,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult]
}

extension WebSearchProvider {
  /// Batch providers publish once on arrival; incremental providers override this overload.
  func search(_ request: WebSearchRequest,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    let results = try await search(request)
    try Task.checkCancellation()
    await onActivity(.sourcesDiscovered(results.map(\.source)))
    return results
  }

  func search(_ request: WebSearchRequest, assistant: (any SearchModelAssistant)?,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    try await search(request, onActivity: onActivity)
  }
}

enum WebSearchError: LocalizedError, Equatable {
  case missingAPIKey, invalidAPIKey, rateLimited, unavailable, invalidResponse, noResults, contextTooSmall
  /// Brave's own failures, worded with its name (D141); the on-device ones above name search sites.
  case braveRateLimited, braveUnavailable, braveInvalidResponse
  /// The message had only slash commands and nothing was attached to write a query from.
  case emptyQuery
  case requestFailed(Int)

  var errorDescription: String? {
    let detail: String
    switch self {
    // Brave only (D128, D130): a saved key selects Brave; without one, search runs on this Mac.
    case .missingAPIKey: detail = "Enter a Brave Search API key in Settings → Cloud and search → Web search."
    case .invalidAPIKey: detail = "Brave rejected the API key. Check its LLM Context access in Settings → Cloud and search → Web search, or remove it to search on this Mac."
    case .rateLimited: detail = "Search sites are limiting requests right now. Try again shortly."
    case .unavailable: detail = "Search sites couldn't be reached. Check your connection and try again."
    case .invalidResponse: detail = "A search site returned an invalid response. Try again."
    case .noResults: detail = "No usable sources were found. Try a more specific question."
    case .emptyQuery: detail = "There's nothing to search for: the message has only commands. Add a question and send again."
    case .contextTooSmall: detail = "There isn’t enough room for web sources. Shorten your question or choose a larger model."
    case .braveRateLimited: detail = "Brave Search is limiting requests right now. Try again shortly."
    case .braveUnavailable: detail = "Brave Search couldn't be reached. Check your connection and try again."
    case .braveInvalidResponse: detail = "Brave Search returned an invalid response. Try again."
    case .requestFailed(let status): detail = "Brave Search failed (\(status)). Try again."
    }
    return detail + " Your draft has been kept."
  }
}

extension WebSearchError {
  /// The same failure from Brave, in words that name it (D141).
  var namingBrave: WebSearchError {
    switch self {
    case .rateLimited: .braveRateLimited
    case .unavailable: .braveUnavailable
    case .invalidResponse: .braveInvalidResponse
    default: self
    }
  }
}

/// Evidence limits shared by every provider and `WebSearchContext`.
enum WebSearchLimits {
  /// 6 read pages, plus Wikipedia, plus one places or weather excerpt.
  static let maximumSources = 8
  static let tokensPerSource = 2_048
  static let evidenceTokens = 8_192
}
