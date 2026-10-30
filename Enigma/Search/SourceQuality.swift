import Foundation
import NaturalLanguage
import os

/// FNV-1a, 64-bit: the hash `scripts/update-search-lists.py` writes into `unsafe.bin` and `spam.bin`.
enum FNV1a64 {
  static func hash(_ text: String) -> UInt64 {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.lowercased().utf8 {
      value ^= UInt64(byte)
      value &*= 0x0000_0100_0000_01B3
    }
    return value
  }
}

/// A set of domains stored as sorted little-endian FNV-1a-64 hashes (spec §3.6).
struct DomainHashSet: Sendable {
  struct MalformedData: Error {}

  private let hashes: [UInt64]

  /// Throws when the length isn't a multiple of 8.
  init(data: Data) throws {
    guard data.count % 8 == 0 else { throw MalformedData() }
    var hashes = [UInt64](repeating: 0, count: data.count / 8)
    data.withUnsafeBytes { raw in
      for index in hashes.indices {
        hashes[index] = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
      }
    }
    // The script writes them sorted; a hand-edited file still works.
    if zip(hashes, hashes.dropFirst()).contains(where: { $0 > $1 }) { hashes.sort() }
    self.hashes = hashes
  }

  init(domains: some Sequence<String>) {
    hashes = Set(domains.map(FNV1a64.hash)).sorted()
  }

  var count: Int { hashes.count }

  func contains(_ domain: String) -> Bool {
    let target = FNV1a64.hash(domain)
    var low = 0, high = hashes.count
    while low < high {
      let middle = (low + high) / 2
      if hashes[middle] < target { low = middle + 1 } else { high = middle }
    }
    return low < hashes.count && hashes[low] == target
  }
}

/// Wikipedia's Perennial sources statuses (`reliability.tsv`).
enum SourceReliability: String, Sendable {
  case generallyReliable = "gr", noConsensus = "nc", generallyUnreliable = "gu", deprecated = "d", blacklisted = "b"
}

/// A reviewed exception in `overrides.tsv` (decisions D55, D56). It never lifts an unsafe-list
/// block, the user's block or an `enigma-blocked.txt` entry.
enum SourceOverride: String, Sendable {
  /// Ignore the domain's Perennial sources status (factor 1.0 from reliability).
  case neutral
  /// Lift a spam-list or Perennial deprecated/blacklisted block.
  case allow
}

/// The quality lists bundled in `Enigma/Resources/SearchData`, refreshed by
/// `scripts/update-search-lists.py`. Nothing downloads them at runtime (spec §7).
struct SearchDataBundle: Sendable {
  let publicSuffixes: PublicSuffixList
  let unsafe: DomainHashSet
  let spam: DomainHashSet
  let reliability: [String: SourceReliability]
  /// ".gov", ".gov.uk", …
  let authoritySuffixes: [String]
  let authorityDomains: Set<String>
  let unreadable: Set<String>
  let enigmaBlocked: Set<String>
  var overrides: [String: SourceOverride] = [:]
  /// `!academia.edu` lines in `authority.txt`: never an authority, whatever suffix matches (D58).
  var authorityExclusions: Set<String> = []

  struct MissingFile: Error { let name: String }

  static func load(from directory: URL) throws -> SearchDataBundle {
    func data(_ name: String) throws -> Data {
      do { return try Data(contentsOf: directory.appending(path: name)) } catch { throw MissingFile(name: name) }
    }
    func lines(_ name: String) throws -> [String] {
      String(decoding: try data(name), as: UTF8.self).split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    func domains(_ name: String) throws -> Set<String> {
      Set(try lines(name).compactMap(PublicSuffixList.normalizedHost))
    }

    var reliability: [String: SourceReliability] = [:]
    for line in try lines("reliability.tsv") {
      let fields = line.split(separator: "\t")
      guard fields.count == 2, let domain = PublicSuffixList.normalizedHost(String(fields[0])),
            let status = SourceReliability(rawValue: String(fields[1])) else { continue }
      reliability[domain] = status
    }
    var suffixes: [String] = [], authority = Set<String>(), exclusions = Set<String>()
    for line in try lines("authority.txt") {
      if line.hasPrefix("!") {
        if let domain = PublicSuffixList.normalizedHost(String(line.dropFirst())) { exclusions.insert(domain) }
      } else if line.hasPrefix(".") {
        if let suffix = PublicSuffixList.normalizedHost(String(line.dropFirst())) { suffixes.append("." + suffix) }
      } else if let domain = PublicSuffixList.normalizedHost(line) {
        authority.insert(domain)
      }
    }
    // Optional: without it the lists apply as they are.
    var overrides: [String: SourceOverride] = [:]
    for line in (try? lines("overrides.tsv")) ?? [] {
      let fields = line.split(separator: "\t")
      guard fields.count == 2, let domain = PublicSuffixList.normalizedHost(String(fields[0])),
            let action = SourceOverride(rawValue: String(fields[1])) else { continue }
      overrides[domain] = action
    }
    return SearchDataBundle(
      publicSuffixes: PublicSuffixList(contents: String(decoding: try data("public_suffix_list.dat"), as: UTF8.self)),
      unsafe: try DomainHashSet(data: data("unsafe.bin")),
      spam: try DomainHashSet(data: data("spam.bin")),
      reliability: reliability,
      authoritySuffixes: suffixes,
      authorityDomains: authority,
      unreadable: try domains("unreadable.txt"),
      enigmaBlocked: try domains("enigma-blocked.txt"),
      overrides: overrides,
      authorityExclusions: exclusions)
  }

  /// Loaded once from the app bundle; nil, and logged, if the folder is missing or damaged.
  static let bundled: SearchDataBundle? = {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight", category: "search")
    guard let folder = Bundle.main.url(forResource: "SearchData", withExtension: nil) else {
      logger.error("Search quality lists are missing from the app bundle")
      return nil
    }
    do {
      return try load(from: folder)
    } catch {
      logger.error("Search quality lists failed to load: \(String(describing: error), privacy: .public)")
      return nil
    }
  }()
}

/// Which results Enigma never uses or only trusts less (spec §3.2–§3.3). A block or factor matches
/// the URL's host and each parent domain down to its registrable domain.
struct SourceQuality: Sendable {
  let data: SearchDataBundle
  let userBlocked: Set<String>

  init(data: SearchDataBundle, userBlocked: Set<String>) {
    self.data = data
    self.userBlocked = Set(userBlocked.compactMap(PublicSuffixList.normalizedHost))
  }

  func registrableDomain(of url: URL) -> String? {
    url.host(percentEncoded: false).flatMap(data.publicSuffixes.registrableDomain(of:))
  }

  /// The host, then each parent down to the registrable domain; the host alone when it has none
  /// (an IP address or a public suffix). Empty without a host.
  func domains(of url: URL) -> [String] {
    guard let rawHost = url.host(percentEncoded: false), let host = PublicSuffixList.normalizedHost(rawHost) else { return [] }
    guard let registrable = data.publicSuffixes.registrableDomain(of: host), registrable != host else { return [host] }
    var domains = [host], current = Substring(host)
    while current != registrable, let dot = current.firstIndex(of: ".") {
      current = current[current.index(after: dot)...]
      domains.append(String(current))
    }
    return domains
  }

  /// The user's list, unsafe, spam, Perennial sources' deprecated or blacklisted, and
  /// `enigma-blocked.txt`. An `allow` override lifts only the spam and Perennial blocks.
  /// A URL without a host is blocked.
  func isBlocked(_ url: URL) -> Bool {
    let domains = domains(of: url)
    guard !domains.isEmpty else { return true }
    let allowed = override(for: domains) == .allow
    return domains.contains { domain in
      if userBlocked.contains(domain) || data.enigmaBlocked.contains(domain) || data.unsafe.contains(domain) {
        return true
      }
      if allowed { return false }
      return data.spam.contains(domain)
        || data.reliability[domain] == .deprecated || data.reliability[domain] == .blacklisted
    }
  }

  /// The most specific domain's override.
  private func override(for domains: [String]) -> SourceOverride? {
    domains.lazy.compactMap { data.overrides[$0] }.first
  }

  func isUnreadable(_ url: URL) -> Bool {
    domains(of: url).contains(where: data.unreadable.contains)
  }

  func isAuthority(_ url: URL) -> Bool {
    guard let host = domains(of: url).first,
          !data.authorityExclusions.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
    // Matched on the host's labels, not the registrable domain: some authorities are public
    // suffixes themselves (nhs.uk).
    return data.authorityDomains.contains { host == $0 || host.hasSuffix("." + $0) }
      || data.authoritySuffixes.contains { host.hasSuffix($0) || host == $0.dropFirst() }
  }

  /// The most specific domain's Perennial sources status; nil under a `neutral` or `allow` override.
  func reliability(of url: URL) -> SourceReliability? {
    let domains = domains(of: url)
    guard override(for: domains) == nil else { return nil }
    return domains.lazy.compactMap { data.reliability[$0] }.first
  }

  /// The product of the factors in `RankingTuning`: authority, generally reliable, generally
  /// unreliable and unreadable.
  func trustFactor(for url: URL) -> Double {
    var factor = 1.0
    if isAuthority(url) { factor *= RankingTuning.authorityFactor }
    switch reliability(of: url) {
    case .generallyReliable: factor *= RankingTuning.generallyReliableFactor
    case .generallyUnreliable: factor *= RankingTuning.generallyUnreliableFactor
    default: break
    }
    if isUnreadable(url) { factor *= RankingTuning.unreadableFactor }
    return factor
  }
}

/// What the checks after reading decided about a page (spec §3.4). CP5 adds off-topic.
enum PageVerdict: Equatable, Sendable { case keep, notArticle, wall, wrongLanguage, offTopic, duplicate }

/// The checks after reading (spec §3.4). Every value is a starting value for CP7 to tune.
enum PageChecks {
  static let minimumWords = 120
  /// A page `isProbablyReaderable` turns down is kept only with this many words (D66). FAQ, spec
  /// sheet and API reference pages fail Readability's paragraph test yet carry facts.
  static let minimumWordsWhenNotReaderable = 250
  static let wallWordLimit = 400
  /// Lowercase English phrases of login walls, paywalls and bot checks; they count only on pages
  /// under `wallWordLimit` words. Spec §3.4's, the brief's, then D66's.
  static let wallPhrases = [
    "subscribe to continue", "sign in to continue", "enable javascript", "access denied", "verify you are human",
    "log in to continue", "are you a robot", "this content is for subscribers",
    "verify you are a human", "please enable cookies", "javascript is disabled", "checking your browser",
    "unusual traffic", "complete the security check", "subscribe to read", "sign in to read", "log in to read",
    "subscribers only", "create a free account to continue", "to continue reading, subscribe",
  ]
  static let duplicateThreshold = 0.6
  static let shingleWords = 5
  /// `NLLanguageRecognizer`'s confidence needed before a page's language counts.
  static let languageConfidence = 0.8
  /// How much text the language check reads.
  static let languageSampleCharacters = 5_000
  /// Fewer letters than this leaves the language undetermined: the recognizer calls a page of
  /// model numbers Polish with 98% confidence.
  static let languageMinimumLetters = 200
  static let stalePenalty = 0.5
  /// Spec §3.4: twice each recency window.
  static let staleAfter: [SearchRecency: TimeInterval] = [
    .day: 2 * 86_400, .week: 14 * 86_400, .month: 60 * 86_400, .year: 730 * 86_400,
  ]

  /// Wall, then not an article, then wrong language. Wikipedia (read through its API) is exempt
  /// from the length and wall checks.
  static func basic(_ article: ExtractedArticle, isWikipedia: Bool, allowedLanguages: Set<String>) -> PageVerdict {
    if !isWikipedia {
      if article.wordCount < wallWordLimit, containsWallPhrase(article) { return .wall }
      let needed = article.isReaderable ? minimumWords : max(minimumWords, minimumWordsWhenNotReaderable)
      if article.wordCount < needed { return .notArticle }
    }
    if let language = dominantLanguage(of: article), !allowedLanguages.isEmpty,
       !allowedLanguages.contains(where: { baseLanguage($0) == language }) {
      return .wrongLanguage
    }
    return .keep
  }

  /// 5-word shingles of the text's words, lowercased, hashed with FNV-1a-64. A text of fewer
  /// than 5 words is one shingle.
  static func shingles(_ text: String) -> Set<UInt64> {
    let words = TextWords.words(in: text)
    guard !words.isEmpty else { return [] }
    guard words.count >= shingleWords else { return [FNV1a64.hash(words.joined(separator: " "))] }
    var result = Set<UInt64>()
    result.reserveCapacity(words.count - shingleWords + 1)
    for start in 0...(words.count - shingleWords) {
      result.insert(FNV1a64.hash(words[start..<(start + shingleWords)].joined(separator: " ")))
    }
    return result
  }

  static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
    let union = a.union(b).count
    guard union > 0 else { return 0 }
    return Double(a.intersection(b).count) / Double(union)
  }

  /// 0.5 when a recency hint is set and the page was published more than twice its window ago;
  /// 1.0 with no hint or no date.
  static func staleFactor(published: Date?, recency: SearchRecency?, now: Date) -> Double {
    guard let published, let recency, let limit = staleAfter[recency] else { return 1.0 }
    return now.timeIntervalSince(published) > limit ? stalePenalty : 1.0
  }

  // MARK: Helpers

  private static func containsWallPhrase(_ article: ExtractedArticle) -> Bool {
    let text = ([article.title] + article.blocks.map(\.text)).joined(separator: "\n").lowercased()
    return wallPhrases.contains { phrase in
      var searchStart = text.startIndex
      while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
        // Whole words only: "design in to continue" isn't "sign in to continue".
        let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
        let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { return true }
        searchStart = text.index(after: range.lowerBound)
      }
      return false
    }
  }

  /// The base code of the page's language when the recognizer is at least 80% sure; nil otherwise.
  private static func dominantLanguage(of article: ExtractedArticle) -> String? {
    // Prose only: code and table rows are mostly names and figures.
    var sample = ""
    for block in article.blocks where block.kind != .code && block.kind != .tableRow {
      sample += block.text + "\n"
      if sample.count >= languageSampleCharacters { break }
    }
    guard sample.lazy.filter(\.isLetter).count >= languageMinimumLetters else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(String(sample.prefix(languageSampleCharacters)))
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
          confidence >= languageConfidence, language != .undetermined else { return nil }
    return baseLanguage(language.rawValue)
  }

  /// "en-GB", "EN_us" and "en" all give "en"; Norwegian's three codes give "no".
  static func baseLanguage(_ code: String) -> String {
    let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    return ["nb", "nn"].contains(base) ? "no" : base
  }
}
