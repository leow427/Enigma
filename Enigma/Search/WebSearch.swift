import Foundation

struct WebSearchSource: Codable, Equatable, Sendable, Identifiable {
  let title: String
  let url: URL
  var id: URL { url }
}

/// What a result's text is: a read page, a search snippet, or a places or weather excerpt.
enum EvidenceKind: String, Codable, Sendable { case article, snippet, wikipedia, places, weather }

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
}

typealias AssistantActivitySink = @Sendable (AssistantActivityEvent) async -> Void

protocol WebSearchProvider: Sendable {
  func search(_ request: WebSearchRequest) async throws -> [WebSearchResult]
  func search(_ request: WebSearchRequest,
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
}

enum WebSearchError: LocalizedError, Equatable {
  case missingAPIKey, invalidAPIKey, rateLimited, unavailable, invalidResponse, noResults, contextTooSmall
  /// The message had only slash commands and nothing was attached to write a query from.
  case emptyQuery
  case requestFailed(Int)

  var errorDescription: String? {
    let detail: String
    switch self {
    case .missingAPIKey: detail = "Add your Brave Search API key in Settings → Cloud and search → Web search · Brave."
    case .invalidAPIKey: detail = "Brave rejected the API key. Check its LLM Context access in Settings → Cloud and search → Web search · Brave."
    case .rateLimited: detail = "Brave Search is rate limiting this account. Try again shortly."
    case .unavailable: detail = "Brave Search could not be reached. Check your connection and try again."
    case .invalidResponse: detail = "Brave Search returned an invalid response. Try again."
    case .noResults: detail = "Brave Search found no relevant sources. Try a more specific question."
    case .emptyQuery: detail = "There's nothing to search for: the message has only commands. Add a question and send again."
    case .contextTooSmall: detail = "There isn’t enough room for web sources. Shorten your question or choose a larger model."
    case .requestFailed(let status): detail = "Brave Search failed (\(status)). Try again."
    }
    return detail + " Your draft has been kept."
  }
}

/// Evidence limits shared by every provider and `WebSearchContext`.
enum WebSearchLimits {
  /// 6 read pages, plus Wikipedia, plus one places or weather excerpt.
  static let maximumSources = 8
  static let tokensPerSource = 2_048
  static let evidenceTokens = 8_192
}
