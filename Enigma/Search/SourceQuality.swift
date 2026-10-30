import Foundation
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
