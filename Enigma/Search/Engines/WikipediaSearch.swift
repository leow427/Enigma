import Foundation

struct WikipediaArticle: Equatable, Sendable {
  let title: String
  let url: URL
  /// Plain text, capped at `WikipediaSearch.maximumCharacters`.
  let text: String
}

enum WikipediaOutcome: Equatable, Sendable { case article(WikipediaArticle), none, failed }

/// Wikipedia's official API (spec §2). Full-text search rather than ddgs's title lookup, which finds
/// nothing for question wording; then the plain text of the first hit that isn't a disambiguation page.
struct WikipediaSearch: Sendable {
  /// Hits searched per query.
  static let searchLimit = 3
  static let maximumCharacters = 30_000
  static let maximumBytes = 2_097_152

  /// Wikimedia's user-agent policy asks for a name, version and contact (spec §2).
  static var userAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let numeric = version.flatMap { $0.allSatisfy { $0.isNumber || $0 == "." } && !$0.isEmpty ? $0 : nil }
    return "Enigma/\(numeric ?? "1.0") (https://github.com/leow427/Enigma)"
  }

  /// Large editions by article count, leaving out the mostly bot-generated ones (Cebuano, Waray,
  /// Egyptian Arabic, Chechen, Tatar, South Azerbaijani); decision D39.
  static let editions: Set<String> = [
    "en", "de", "fr", "sv", "nl", "ru", "es", "it", "pl", "zh", "ja", "uk", "vi", "ar", "pt",
    "fa", "ca", "id", "sr", "ko", "no", "fi", "tr", "hu", "cs", "he", "ro", "da", "eu", "hy",
  ]

  /// The first preferred language's base code if Wikipedia has a large edition for it, else `en`.
  static func language(for preferred: [String]) -> String {
    guard let first = preferred.first,
          let base = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() else { return "en" }
    let code = base == "nb" || base == "nn" ? "no" : base
    return editions.contains(code) ? code : "en"
  }

  static func searchRequest(for query: String, language: String) -> URLRequest {
    request(language: language, query: [
      ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", String(searchLimit)), ("format", "json"),
    ])
  }

  static func extractRequest(title: String, language: String) -> URLRequest {
    request(language: language, query: [
      ("action", "query"), ("prop", "extracts"), ("explaintext", "1"), ("exsectionformat", "plain"),
      ("redirects", "1"), ("titles", title), ("format", "json"),
    ])
  }

  private static func request(language: String, query: [(String, String)]) -> URLRequest {
    let items = query.map { "\(SearchFormEncoding.percentEncode($0.0))=\(SearchFormEncoding.percentEncode($0.1))" }
    var request = URLRequest(url: URL(string: "https://\(language).wikipedia.org/w/api.php?" + items.joined(separator: "&"))!)
    request.httpMethod = "GET"
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func lookup(_ query: String, preferredLanguages: [String], using client: any SearchHTTPClient) async -> WikipediaOutcome {
    let language = Self.language(for: preferredLanguages)
    guard let search = await Self.json(Self.searchRequest(for: query, language: language), client: client),
          let hits = (search["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return .failed }
    for title in hits.prefix(Self.searchLimit).compactMap({ $0["title"] as? String }) {
      guard let extract = await Self.json(Self.extractRequest(title: title, language: language), client: client),
            let pages = (extract["query"] as? [String: Any])?["pages"] as? [String: Any] else { return .failed }
      guard let page = pages.values.compactMap({ $0 as? [String: Any] }).first,
            let text = page["extract"] as? String, !text.isEmpty else { continue }
      if text.contains("may refer to:") { continue }
      let resolved = page["title"] as? String ?? title
      guard let url = Self.articleURL(title: resolved, language: language) else { continue }
      return .article(WikipediaArticle(title: resolved, url: url, text: String(text.prefix(Self.maximumCharacters))))
    }
    return .none
  }

  static func articleURL(title: String, language: String) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#%;")
    let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed)
    return path.flatMap { URL(string: "https://\(language).wikipedia.org/wiki/\($0)") }
  }

  private static func json(_ request: URLRequest, client: any SearchHTTPClient) async -> [String: Any]? {
    guard let response = try? await client.send(request, maximumBytes: maximumBytes), response.statusCode == 200,
          !response.truncated else { return nil }
    return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
  }
}
