import Foundation

/// Every ranking number in one place, for the evaluation (CP7) to tune (decision D53).
/// Starting values from spec §3.3.
enum RankingTuning {
  /// Each search site's weight in the agreement score. CP0b dropped Startpage (1.0) and Mojeek (0.8).
  static let engineWeights: [SearchEngineID: Double] = [.duckDuckGo: 1.0]
  /// `authority.txt`: government, universities, research, health bodies, official docs.
  static let authorityFactor = 1.3
  /// "Generally reliable" in Wikipedia's Perennial sources.
  static let generallyReliableFactor = 1.15
  /// "Generally unreliable" in Wikipedia's Perennial sources.
  static let generallyUnreliableFactor = 0.5
  /// `unreadable.txt`: sites that can contribute only their snippet.
  static let unreadableFactor = 0.5
  /// Candidates scoring below this share of the top score are dropped.
  static let cutoff = 0.15
  /// Pages read at a time; the pipeline refills from the read queue (CP5).
  static let readBatch = 6
}

/// Cleans result links and computes the key duplicates merge on (spec §3.1).
enum URLNormalizer {
  /// Any name starting `utm_` counts too.
  static let trackingParameters: Set<String> = [
    "gclid", "dclid", "gbraid", "wbraid", "fbclid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
    "_hsenc", "_hsmi", "ref_src",
  ]
  static let maximumURLBytes = 2_048
  private static let hostPrefixes = ["www.", "m.", "mobile.", "amp."]

  /// nil for anything that isn't http(s), has credentials, is over 2,048 bytes, or is a search
  /// site's result page. Unwraps redirect wrappers and AMP pages, and strips tracking parameters.
  static func clean(_ url: URL) -> URL? {
    clean(url, unwrapping: 3)
  }

  private static func clean(_ url: URL, unwrapping depth: Int) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          components.user == nil, components.password == nil,
          let host = components.host?.lowercased(), !host.isEmpty,
          url.absoluteString.utf8.count <= maximumURLBytes else { return nil }
    if let inner = unwrapped(components, host: host) {
      return depth > 0 ? clean(inner, unwrapping: depth - 1) : nil
    }
    if isSearchResultPage(host: host, path: components.path, hasQuery: components.query != nil) { return nil }
    if let items = components.percentEncodedQueryItems {
      let kept = items.filter { !isTracking($0.name) }
      if kept.count != items.count { components.percentEncodedQueryItems = kept.isEmpty ? nil : kept }
    }
    return components.url
  }

  /// The normalized dedupe key: scheme ignored; host lowercased without a leading `www.`, `m.`,
  /// `mobile.` or `amp.` (when a domain remains); default port, fragment, trailing slash and
  /// trailing `/amp` dropped;
  /// `amp=1`, `outputType=amp` and tracking parameters dropped; the rest sorted.
  static func key(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    var host = (components.host ?? "").lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    // Only when what's left is still a domain: mobile.de keeps its host (D58).
    for prefix in hostPrefixes where host.hasPrefix(prefix) && host.dropFirst(prefix.count).contains(".") {
      host.removeFirst(prefix.count)
      break
    }
    var port = ""
    if let number = components.port, number != 80, number != 443 { port = ":\(number)" }
    var path = components.percentEncodedPath
    if path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/amp") { path.removeLast(4) }
    if path.hasSuffix("/") { path.removeLast() }
    let query = (components.percentEncodedQueryItems ?? [])
      .filter { !isTracking($0.name) && !isAMPMarker($0) }
      .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
      .sorted()
      .joined(separator: "&")
    return host + port + path + (query.isEmpty ? "" : "?" + query)
  }

  /// `amp=1` and `outputType=amp` only.
  private static func isAMPMarker(_ item: URLQueryItem) -> Bool {
    let name = item.name.lowercased(), value = item.value?.lowercased()
    return (name == "amp" && value == "1") || (name == "outputtype" && value == "amp")
  }

  private static func isTracking(_ name: String) -> Bool {
    let name = name.lowercased()
    return name.hasPrefix("utm_") || trackingParameters.contains(name)
  }

  private static func isGoogle(_ host: String) -> Bool {
    let labels = host.split(separator: ".")
    guard let index = labels.firstIndex(of: "google") else { return false }
    // google.com, www.google.co.uk: "google" followed only by a short country or generic suffix.
    return labels.count - index - 1 >= 1 && labels.count - index - 1 <= 2 && (index == 0 || labels[index - 1] == "www")
  }

  private static func hostIs(_ host: String, _ domain: String) -> Bool {
    host == domain || host.hasSuffix("." + domain)
  }

  /// The page inside an AMP cache link or a search site's redirect link.
  private static func unwrapped(_ components: URLComponents, host: String) -> URL? {
    let path = components.percentEncodedPath
    if host.hasSuffix(".cdn.ampproject.org") {
      for prefix in ["/c/", "/v/"] where path.hasPrefix(prefix) {
        return rebuilt(String(path.dropFirst(prefix.count)), query: components.percentEncodedQuery)
      }
    }
    if isGoogle(host), path.hasPrefix("/amp/") {
      return rebuilt(String(path.dropFirst("/amp/".count)), query: components.percentEncodedQuery)
    }
    if hostIs(host, "duckduckgo.com"), path.hasPrefix("/l/") {
      return components.queryItems?.first { $0.name == "uddg" }?.value.flatMap(URL.init(string:))
    }
    if isGoogle(host), path == "/url" {
      let items = components.queryItems ?? []
      return (items.first { $0.name == "q" } ?? items.first { $0.name == "url" })?.value.flatMap(URL.init(string:))
    }
    return nil
  }

  /// `s/example.com/a` is https; `example.com/a` is http.
  private static func rebuilt(_ rest: String, query: String?) -> URL? {
    let secure = rest.hasPrefix("s/")
    let address = secure ? String(rest.dropFirst(2)) : rest
    guard !address.isEmpty else { return nil }
    return URL(string: (secure ? "https://" : "http://") + address + (query.map { "?" + $0 } ?? ""))
  }

  private static func isSearchResultPage(host: String, path: String, hasQuery: Bool) -> Bool {
    let lowered = path.lowercased()
    if hostIs(host, "duckduckgo.com") {
      return lowered.hasPrefix("/html") || lowered.hasPrefix("/lite") || ((lowered.isEmpty || lowered == "/") && hasQuery)
    }
    if hostIs(host, "startpage.com") {
      return lowered.hasPrefix("/sp/search") || lowered.hasPrefix("/do/") || lowered.hasPrefix("/search")
    }
    if hostIs(host, "mojeek.com") { return lowered.hasPrefix("/search") }
    if isGoogle(host) { return lowered.hasPrefix("/search") || lowered == "/url" }
    if hostIs(host, "bing.com") { return lowered.hasPrefix("/search") || lowered.hasPrefix("/ck/") }
    return false
  }
}

/// One cleaned, merged search result.
struct RankedCandidate: Equatable, Sendable {
  let url: URL
  var title: String
  var snippet: String
  /// Best position per engine.
  var positions: [SearchEngineID: Int]
  var score: Double
  /// Registrable domain.
  let domain: String
}

/// Merging, scoring and picking pages to read (spec §3.3).
enum ResultRanking {
  /// SearXNG's agreement score: `weight` is the product of the weights of the sites that returned
  /// the result times their number; the score sums `weight / position` over those sites.
  static func agreementScore(_ hits: [(weight: Double, position: Int)]) -> Double {
    guard !hits.isEmpty else { return 0 }
    let weight = hits.reduce(1.0) { $0 * $1.weight } * Double(hits.count)
    return hits.reduce(0.0) { $0 + weight / Double(max($1.position, 1)) }
  }

  /// Cleans, merges duplicates on `URLNormalizer.key` and scores; highest first.
  static func merge(_ results: [EngineResult], weights: [SearchEngineID: Double],
                    quality: SourceQuality) -> [RankedCandidate] {
    var order: [String] = []
    var merged: [String: RankedCandidate] = [:]
    for result in results {
      guard let url = URLNormalizer.clean(result.url) else { continue }
      let key = URLNormalizer.key(url)
      if var existing = merged[key] {
        if result.title.count > existing.title.count { existing.title = result.title }
        if result.snippet.count > existing.snippet.count { existing.snippet = result.snippet }
        existing.positions[result.engine] = min(existing.positions[result.engine] ?? .max, result.position)
        merged[key] = existing
      } else {
        let domain = quality.registrableDomain(of: url) ?? url.host(percentEncoded: false)?.lowercased() ?? ""
        merged[key] = RankedCandidate(url: url, title: result.title, snippet: result.snippet,
                                      positions: [result.engine: result.position], score: 0, domain: domain)
        order.append(key)
      }
    }
    var candidates = order.compactMap { merged[$0] }
    for index in candidates.indices {
      let hits = candidates[index].positions.map { engine, position in
        (weight: weights[engine] ?? RankingTuning.engineWeights[engine] ?? 1.0, position: position)
      }
      candidates[index].score = agreementScore(hits)
    }
    return candidates.enumerated().sorted { left, right in
      if left.element.score != right.element.score { return left.element.score > right.element.score }
      return left.offset < right.offset
    }.map(\.element)
  }

  struct Selection: Equatable, Sendable {
    /// Eligible to read, one per domain, best first; the pipeline reads `RankingTuning.readBatch`
    /// at a time and refills.
    var readQueue: [RankedCandidate]
    /// Unreadable sites and second pages from a domain: snippet evidence only.
    var snippetOnly: [RankedCandidate]
  }

  /// Drops blocked candidates, applies trust factors, drops anything under `cutoff` × the top
  /// score, then splits the rest into pages to read and snippets. Ties go to the more trusted
  /// source, then the better position (decision D53).
  static func select(_ candidates: [RankedCandidate], quality: SourceQuality,
                     cutoff: Double = RankingTuning.cutoff) -> Selection {
    let scored = candidates.filter { !quality.isBlocked($0.url) }.map { candidate in
      let trust = quality.trustFactor(for: candidate.url)
      var adjusted = candidate
      adjusted.score *= trust
      return (candidate: adjusted, trust: trust, position: candidate.positions.values.min() ?? .max,
              key: URLNormalizer.key(candidate.url))
    }.sorted { left, right in
      if left.candidate.score != right.candidate.score { return left.candidate.score > right.candidate.score }
      if left.trust != right.trust { return left.trust > right.trust }
      if left.position != right.position { return left.position < right.position }
      return left.key < right.key
    }
    guard let top = scored.first?.candidate.score else { return Selection(readQueue: [], snippetOnly: []) }
    var selection = Selection(readQueue: [], snippetOnly: [])
    var domainsToRead = Set<String>()
    for entry in scored where entry.candidate.score >= cutoff * top {
      let candidate = entry.candidate
      if quality.isUnreadable(candidate.url) || domainsToRead.contains(candidate.domain) {
        selection.snippetOnly.append(candidate)
      } else {
        domainsToRead.insert(candidate.domain)
        selection.readQueue.append(candidate)
      }
    }
    return selection
  }
}
