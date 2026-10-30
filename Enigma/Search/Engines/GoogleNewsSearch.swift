import Foundation

struct NewsHeadline: Equatable, Sendable {
  let title: String
  let publisher: String?
  let published: Date?
  /// The publisher's home page, from the item's `<source url>`; http(s) only.
  var publisherURL: URL? = nil
}

/// Google News RSS for news and recency questions (D104, D110). Sends only the query and the
/// language and region; no cookies (the search client stores none). Item links only resolve
/// through further Google requests, so none are followed: each item's headline, publisher and date
/// are the evidence.
struct GoogleNewsSearch: Sendable {
  static let maximumBytes = 1_048_576
  static let maximumHeadlines = 8

  /// News cues beyond the recency words `WebSearchPolicy.recency` already reads.
  private static let newsCue = try! NSRegularExpression(
    pattern: #"\b(?:headlines?|announced|announcement|elections?|who won|won the|winner of)\b"#)

  /// Day, week or month questions ("today", "latest", "news", "this month"), or a news cue.
  static func applies(question: String, recency: SearchRecency?) -> Bool {
    if recency == .day || recency == .week || recency == .month { return true }
    let text = WebSearchPolicy.questionText(question)
    return newsCue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// `hl`, `gl` and `ceid` from the Mac's region: `en-US`, `US`, `US:en`.
  static func request(query: String, region: SearchRegion) -> URLRequest {
    let country = region.country.uppercased(), language = region.language
    let items = [("q", query), ("hl", "\(language)-\(country)"), ("gl", country), ("ceid", "\(country):\(language)")]
      .map { "\($0.0)=\(SearchFormEncoding.percentEncode($0.1))" }
    var request = URLRequest(url: URL(string: "https://news.google.com/rss/search?" + items.joined(separator: "&"))!)
    request.httpMethod = "GET"
    request.setValue(WikipediaSearch.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/rss+xml, application/xml;q=0.9", forHTTPHeaderField: "Accept")
    return request
  }

  /// The excerpt's link: Google News's home page, with no query (D122, D125).
  static let homeURL = URL(string: "https://news.google.com/")!

  /// `DateFormatter` formats and parses safely from any thread once set up (D124).
  nonisolated(unsafe) private static let feedDates: [DateFormatter] =
    ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz"].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "GMT")
      formatter.dateFormat = format
      return formatter
    }
  nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  func search(_ query: String, region: SearchRegion, using client: any SearchHTTPClient) async -> [NewsHeadline]? {
    guard let response = try? await client.send(Self.request(query: query, region: region),
                                                maximumBytes: Self.maximumBytes),
          response.statusCode == 200 else { return nil }
    return Self.parse(response.body)
  }

  /// Items newest first, at most `maximumHeadlines`. nil when the feed doesn't parse.
  static func parse(_ data: Data) -> [NewsHeadline]? {
    let delegate = RSSItems()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() || !delegate.items.isEmpty, delegate.sawChannel else { return nil }
    let headlines = delegate.items.compactMap { item -> NewsHeadline? in
      var title = SERPDocument.normalize(item["title"] ?? "")
      let publisher = item["source"].map(SERPDocument.normalize).flatMap { $0.isEmpty ? nil : $0 }
      // Google ends each title with " - <publisher>".
      if let publisher, title.hasSuffix(" - " + publisher) { title = String(title.dropLast(publisher.count + 3)) }
      guard !title.isEmpty else { return nil }
      let home = item["sourceURL"].flatMap(URL.init(string:)).flatMap { url -> URL? in
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
      }
      return NewsHeadline(title: title, publisher: publisher, published: item["pubDate"].flatMap(Self.date),
                          publisherURL: home)
    }
    let ordered = headlines.enumerated().sorted { left, right in
      let leftDate = left.element.published ?? .distantPast, rightDate = right.element.published ?? .distantPast
      return leftDate != rightDate ? leftDate > rightDate : left.offset < right.offset
    }.map(\.element)
    return Array(ordered.prefix(maximumHeadlines))
  }

  /// RFC 822 dates, as the feed writes them ("Thu, 08 Oct 2026 07:00:00 GMT").
  static func date(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return feedDates.lazy.compactMap { $0.date(from: trimmed) }.first
  }

  /// The headlines as one evidence excerpt. It links to Google News's home page, never to a link
  /// carrying the query, so blocking it from the citation blocks Google News (D122, D125).
  static func excerpt(_ headlines: [NewsHeadline]) -> WebSearchResult {
    let formatter = dayFormatter
    var lines = ["News headlines from Google News, newest first (headline — publisher, date published):"]
    for headline in headlines {
      var line = "- \(headline.title)"
      let details = [headline.publisher, headline.published.map { formatter.string(from: $0) }].compactMap { $0 }
      if !details.isEmpty { line += " — " + details.joined(separator: ", ") }
      lines.append(line)
    }
    return WebSearchResult(source: WebSearchSource(title: "Google News headlines", url: homeURL),
                           snippets: [lines.joined(separator: "\n")], site: "Google News",
                           published: headlines.compactMap(\.published).max(), kind: .news)
  }
}

/// Collects each `<item>`'s title, source and pubDate.
private final class RSSItems: NSObject, XMLParserDelegate {
  var items: [[String: String]] = []
  var sawChannel = false
  private var current: [String: String]?
  private var element: String?
  private var text = ""

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
              attributes: [String: String] = [:]) {
    if name == "channel" { sawChannel = true }
    if name == "item" {
      current = [:]
    } else if current != nil, ["title", "source", "pubDate"].contains(name) {
      if name == "source", let url = attributes["url"] { current?["sourceURL"] = url }
      element = name
      text = ""
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if element != nil { text += string }
  }

  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    if element != nil { text += String(decoding: block, as: UTF8.self) }
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    if name == element {
      current?[name] = text
      element = nil
    } else if name == "item", let item = current {
      items.append(item)
      current = nil
    }
  }
}
