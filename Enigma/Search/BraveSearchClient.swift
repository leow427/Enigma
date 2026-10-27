import Foundation

struct BraveSearchClient: WebSearchProvider {
  static let maximumSources = 10
  static let evidenceTokens = 8_192
  static let tokensPerSource = 2_048
  private let credentials: any WebSearchCredentialStore
  private let transport: any CloudNetworkTransport

  init(
    credentials: any WebSearchCredentialStore = KeychainSearchCredentialStore(),
    transport: any CloudNetworkTransport = BraveSearchClient.liveTransport
  ) {
    self.credentials = credentials
    self.transport = transport
  }

  // Search queries and credentials must not enter the shared disk cache or be
  // forwarded to a redirect destination through a custom authentication header.
  static let liveTransport: any CloudNetworkTransport = URLSessionCloudTransport(
    session: URLSession(configuration: .ephemeral, delegate: BraveRedirectBlocker(), delegateQueue: nil)
  )

  static func query(from prompt: String) -> String {
    String(prompt.split(whereSeparator: \.isWhitespace).prefix(50).joined(separator: " ").prefix(400))
  }

  /// Brave reads location as a line appended to the query, as it did before `WebSearchRequest`.
  func search(_ request: WebSearchRequest) async throws -> [WebSearchResult] {
    var query = request.query
    if let coordinate = request.coordinate {
      query += "\n" + ApproximateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude,
        area: request.city ?? ApproximateLocation.unknownArea).searchContext
    }
    return try await search(query, maximumTokens: request.maximumTokens)
  }

  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    try Task.checkCancellation()
    guard let key = try credentials.apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else { throw WebSearchError.missingAPIKey }
    let query = Self.query(from: query)
    guard !query.isEmpty else { throw ChatContextError.missingCurrentPrompt }
    var request = URLRequest(url: URL(string: "https://api.search.brave.com/res/v1/llm/context")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
    request.httpBody = try JSONEncoder().encode(Parameters(
      q: query, maximum_number_of_tokens: min(8_192, max(1_024, maximumTokens))
    ))
    let response: CloudDataResponse
    do {
      response = try await transport.data(for: request)
    } catch {
      if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
        throw CancellationError()
      }
      throw WebSearchError.unavailable
    }
    try Task.checkCancellation()
    switch response.statusCode {
    case 200..<300: break
    case 401, 403: throw WebSearchError.invalidAPIKey
    case 429: throw WebSearchError.rateLimited
    default: throw WebSearchError.requestFailed(response.statusCode)
    }
    // Do not show raw server error bodies: they can echo credentials or queries.
    guard let decoded = try? JSONDecoder().decode(Response.self, from: response.data) else {
      throw WebSearchError.invalidResponse
    }
    let entries = (decoded.grounding.generic ?? [])
      + (decoded.grounding.poi.map { [$0] } ?? []) + (decoded.grounding.map ?? [])
    var seen = Set<URL>()
    let results = entries.compactMap { entry -> WebSearchResult? in
      guard entry.url.utf8.count <= 2_048, let url = URL(string: entry.url),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil,
            !seen.contains(url) else { return nil }
      let snippets = (entry.snippets ?? []).map {
        $0.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard !snippets.isEmpty else { return nil }
      seen.insert(url)
      let title = entry.title ?? decoded.sources?[entry.url]?.title ?? url.host ?? entry.url
      return WebSearchResult(
        source: WebSearchSource(title: String(title.replacingOccurrences(of: "\0", with: "").prefix(160)), url: url),
        snippets: snippets
      )
    }
    guard !results.isEmpty else { throw WebSearchError.noResults }
    return Array(results.prefix(Self.maximumSources))
  }

  private struct Parameters: Encodable {
    let q: String
    let maximum_number_of_tokens: Int
    let count = 10
    let maximum_number_of_urls = BraveSearchClient.maximumSources
    let maximum_number_of_tokens_per_url = BraveSearchClient.tokensPerSource
    let context_threshold_mode = "balanced"
  }

  private struct Response: Decodable {
    let grounding: Grounding
    let sources: [String: Source]?
    struct Source: Decodable { let title: String? }
    struct Grounding: Decodable {
      let generic: [Entry]?
      let poi: Entry?
      let map: [Entry]?
    }
    struct Entry: Decodable {
      let url: String
      let title: String?
      let snippets: [String]?
    }
  }
}

private final class BraveRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
