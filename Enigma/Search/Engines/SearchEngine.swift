import Foundation
import os

/// The search sites Enigma queries itself. Wikipedia has its own API client (`WikipediaSearch`).
/// The owner's lineup after CP0b is DuckDuckGo alone: Mojeek and Startpage refused URLSession.
enum SearchEngineID: String, Sendable, CaseIterable { case duckDuckGo }

/// `<country>-<language>`, lowercased, from the Mac's locale.
struct SearchRegion: Equatable, Sendable {
  let country: String
  let language: String

  init(country: String, language: String) {
    self.country = country.lowercased()
    self.language = language.lowercased()
  }

  var code: String { "\(country)-\(language)" }

  /// Falls back to `us-en` when the locale has no region or language.
  static func current(_ locale: Locale = .current) -> SearchRegion {
    guard let country = locale.region?.identifier, let language = locale.language.languageCode?.identifier,
          !country.isEmpty, !language.isEmpty else {
      return SearchRegion(country: "us", language: "en")
    }
    return SearchRegion(country: country, language: language)
  }
}

struct EngineQuery: Equatable, Sendable {
  let text: String
  let region: SearchRegion
  let recency: SearchRecency?
}

struct EngineResult: Equatable, Sendable {
  let title: String
  let url: URL
  let snippet: String
  /// 1-based, within this engine.
  let position: Int
  let engine: SearchEngineID
}

enum EngineOutcome: Equatable, Sendable { case results([EngineResult]), noResults, blocked, rateLimited, unrecognized, failed }

protocol SearchEngine: Sendable {
  var id: SearchEngineID { get }
  /// DuckDuckGo 1.0 (spec §3.3).
  var weight: Double { get }
  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome
}

/// A search site's results page, parsed with `XMLDocument` (libxml2) as CP0 confirmed. The page is
/// decoded before parsing: `XMLDocument(data:)` ignores DuckDuckGo's `http-equiv` charset and
/// garbles every non-ASCII character.
struct SERPDocument {
  private let document: XMLDocument

  init?(html: Data) {
    guard !html.isEmpty, let string = Self.decode(html),
          let document = try? XMLDocument(xmlString: string, options: [.documentTidyHTML]) else {
      return nil
    }
    self.document = document
  }

  /// Nodes matching `xpath`, relative to `node`, or to the document when `node` is nil.
  func nodes(_ xpath: String, in node: XMLNode?) -> [XMLNode] {
    (try? (node ?? document).nodes(forXPath: xpath)) ?? []
  }

  /// Every matching text node joined, as ddgs joins them: concatenated, whitespace collapsed,
  /// NFC, and Unicode "C" characters (controls, format characters such as zero-width spaces)
  /// removed. Escaped markup stays as text.
  func text(_ xpath: String, in node: XMLNode) -> String {
    Self.normalize(textNodes(xpath, in: node).compactMap(\.stringValue).joined())
  }

  /// `NSXMLNode` evaluates a relative `…//text()` wrongly: `./a//text()` on a result also returns
  /// the text of every later result on the page (found in CP2). So a path ending in `//text()` is
  /// split: the XPath selects the elements, and their descendant text nodes are collected here,
  /// in document order, which is what the XPath means.
  private func textNodes(_ xpath: String, in node: XMLNode) -> [XMLNode] {
    let suffix = "//text()"
    guard xpath.hasSuffix(suffix), xpath.count > suffix.count else { return nodes(xpath, in: node) }
    let elements = nodes(String(xpath.dropLast(suffix.count)), in: node)
    return elements.flatMap(Self.descendantText)
  }

  private static func descendantText(_ node: XMLNode) -> [XMLNode] {
    node.kind == .text ? [node] : (node.children ?? []).flatMap(descendantText)
  }

  /// The first match's value, such as an attribute.
  func value(_ xpath: String, in node: XMLNode) -> String? {
    nodes(xpath, in: node).first?.stringValue
  }

  static func normalize(_ raw: String) -> String {
    let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let composed = collapsed.precomposedStringWithCanonicalMapping
    let visible = String(String.UnicodeScalarView(composed.unicodeScalars.filter { !isOtherCategory($0) }))
    return visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func isOtherCategory(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned: true
    default: false
    }
  }

  /// UTF-8 first, then the charset the page declares.
  private static func decode(_ data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    let head = String(decoding: data.prefix(4_096), as: Unicode.ASCII.self)
    if let match = head.firstMatch(of: /(?i)charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)/) {
      let encoding = CFStringConvertIANACharSetNameToEncoding(String(match.1) as CFString)
      if encoding != kCFStringEncodingInvalidId {
        let converted = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        if let string = String(data: data, encoding: converted) { return string }
      }
    }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Encodes form and query values: everything outside RFC 3986's unreserved set is percent-encoded
/// UTF-8, so `+`, `&` and `=` in a query stay data.
enum SearchFormEncoding {
  private static let unreserved = CharacterSet(charactersIn:
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  /// `application/x-www-form-urlencoded`, spaces as `+`, in the given order.
  static func formBody(_ fields: [(String, String)]) -> Data {
    let pairs = fields.map { name, value in
      "\(percentEncode(name))=\(percentEncode(value).replacingOccurrences(of: "%20", with: "+"))"
    }
    return Data(pairs.joined(separator: "&").utf8)
  }
}

/// Where an unrecognized results page is reported. Never given the query or a URL.
protocol SearchLogging: Sendable {
  /// A page the port doesn't understand, or a status that says the request itself is wrong.
  func unrecognizedPage(engine: SearchEngineID, status: Int, bytes: Int)
  /// A server error or a too-long query: not the port's fault, but worth seeing (D47).
  func failedPage(engine: SearchEngineID, status: Int, bytes: Int)
}

/// The owner's signal that a port needs updating (spec §2, "Logging").
struct OSSearchLog: SearchLogging {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight",
                                     category: "search")

  func unrecognizedPage(engine: SearchEngineID, status: Int, bytes: Int) {
    Self.logger.error(
      "Unrecognized results page from \(engine.rawValue, privacy: .public): HTTP \(status, privacy: .public), \(bytes, privacy: .public) bytes")
  }

  func failedPage(engine: SearchEngineID, status: Int, bytes: Int) {
    Self.logger.error(
      "Search request to \(engine.rawValue, privacy: .public) failed: HTTP \(status, privacy: .public), \(bytes, privacy: .public) bytes")
  }
}

/// Each site's backoff and pacing, in memory for this app run only (spec §2).
actor EngineHealth {
  static let shared = EngineHealth()
  static let cooldownSteps: [Duration] = [.seconds(60), .seconds(300), .seconds(900), .seconds(3600)]
  /// At most one search per site per second.
  static let pacingInterval: Duration = .seconds(1)

  private let now: @Sendable () -> ContinuousClock.Instant
  private var failures: [SearchEngineID: Int] = [:]
  private var coolingUntil: [SearchEngineID: ContinuousClock.Instant] = [:]
  private var lastSearch: [SearchEngineID: ContinuousClock.Instant] = [:]
  /// A pending rate-limit strike: the challenged query's fingerprint (`String.hashValue`, seeded
  /// per launch; never logged or stored) and when its skip ends.
  private var rateLimitStrike: [SearchEngineID: (query: Int, skipUntil: ContinuousClock.Instant)] = [:]

  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
    self.now = now
  }

  func isCoolingDown(_ id: SearchEngineID) -> Bool {
    guard let until = coolingUntil[id] else { return false }
    return now() < until
  }

  /// A block sign (spec §2): starts the next step of the ladder; stays at 3,600 s. A failure while the site is already
  /// cooling down (another search that was in flight) doesn't climb the ladder again.
  func recordFailure(_ id: SearchEngineID) {
    guard !isCoolingDown(id) else { return }
    let step = min(failures[id, default: 0], Self.cooldownSteps.count - 1)
    coolingUntil[id] = now().advanced(by: Self.cooldownSteps[step])
    failures[id] = step + 1
  }

  /// A rate-limit answer (DuckDuckGo's 202 challenge, or 429) for one query. CP0 and CP0b saw the
  /// challenge follow one query, not the network, so that query alone sits out the ladder's first
  /// step; a challenge for a different query while a strike is pending starts the ladder (D45).
  func recordRateLimited(_ id: SearchEngineID, query: Int) {
    if let strike = rateLimitStrike[id], strike.query != query {
      rateLimitStrike[id] = nil
      recordFailure(id)
    } else {
      rateLimitStrike[id] = (query, now().advanced(by: Self.cooldownSteps[0]))
    }
  }

  /// True while this query is sitting out after its own challenge.
  func isSkipped(_ id: SearchEngineID, query: Int) -> Bool {
    guard let strike = rateLimitStrike[id], strike.query == query else { return false }
    return now() < strike.skipUntil
  }

  /// Resets the ladder and clears a pending rate-limit strike.
  func recordSuccess(_ id: SearchEngineID) {
    failures[id] = nil
    coolingUntil[id] = nil
    rateLimitStrike[id] = nil
  }

  /// Time until 1 s after this site's last search; zero if none is needed.
  func pacingDelay(_ id: SearchEngineID) -> Duration {
    guard let last = lastSearch[id] else { return .zero }
    let ready = last.advanced(by: Self.pacingInterval)
    let current = now()
    return ready > current ? current.duration(to: ready) : .zero
  }

  /// Books this site's next search slot and returns how long to wait for it. Checking and booking
  /// in one call keeps two searches started together a second apart.
  func reservePacingSlot(_ id: SearchEngineID) -> Duration {
    let delay = pacingDelay(id)
    lastSearch[id] = now().advanced(by: delay)
    return delay
  }
}
