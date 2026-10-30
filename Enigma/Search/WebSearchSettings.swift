import Combine
import Foundation

protocol WebSearchCredentialStore: Sendable {
  func containsAPIKey() throws -> Bool
  func apiKey() throws -> String?
  func setAPIKey(_ value: String) throws
  func removeAPIKey() throws
}

extension WebSearchCredentialStore {
  func containsAPIKey() throws -> Bool { try apiKey()?.isEmpty == false }
}

struct KeychainSearchCredentialStore: WebSearchCredentialStore {
  private let store = KeychainCredentialStore(service: "com.leow427.AISpotlight.web-search")
  func containsAPIKey() throws -> Bool { try store.containsAPIKey(account: "brave") }
  func apiKey() throws -> String? { try store.apiKey(account: "brave") }
  func setAPIKey(_ value: String) throws { try store.setAPIKey(value, account: "brave") }
  func removeAPIKey() throws { try store.removeAPIKey(account: "brave") }
}

@MainActor
final class WebSearchSettings: ObservableObject {
  static let shared = WebSearchSettings()
  @Published private(set) var hasAPIKey = false
  @Published var automaticallySearch: Bool {
    didSet { defaults.set(automaticallySearch, forKey: Self.automaticSearchKey) }
  }
  /// Search needs no setup (spec §8). A saved Brave key only changes who runs it (D128).
  var canSearchAutomatically: Bool { automaticallySearch }
  static let blockedSitesKey = "webSearch.blockedSites"
  static let maximumBlockedSites = 500
  /// The sites the user chose never to use: registrable domains only, oldest first (spec §7).
  @Published private(set) var blockedSites: [String]
  private static let automaticSearchKey = "webSearch.automaticallySearch"
  private let defaults: UserDefaults
  private let credentials: any WebSearchCredentialStore
  /// Resolved on the first `block(_:)`, so launch doesn't load the bundled lists (decision D54).
  private let publicSuffixes: () -> PublicSuffixList?

  init(credentials: any WebSearchCredentialStore = KeychainSearchCredentialStore(), defaults: UserDefaults = .standard,
       publicSuffixes: @autoclosure @escaping () -> PublicSuffixList? = SearchDataBundle.bundled?.publicSuffixes) {
    self.credentials = credentials
    self.defaults = defaults
    self.publicSuffixes = publicSuffixes
    automaticallySearch = defaults.object(forKey: Self.automaticSearchKey) as? Bool ?? true
    hasAPIKey = (try? credentials.containsAPIKey()) ?? false
    blockedSites = Self.sanitizedBlockList(defaults.stringArray(forKey: Self.blockedSitesKey) ?? [])
  }

  /// Stores the URL's registrable domain, never the URL or its path; without the Public Suffix
  /// List, the host without "www.". Over the limit, the oldest entries go.
  func block(_ url: URL) {
    guard let domain = domain(of: url), !blockedSites.contains(domain) else { return }
    blockedSites = Array((blockedSites + [domain]).suffix(Self.maximumBlockedSites))
    defaults.set(blockedSites, forKey: Self.blockedSitesKey)
  }

  /// The domain `block(_:)` stores for the URL: its registrable domain, or the host without "www.".
  func domain(of url: URL) -> String? {
    guard let host = url.host(percentEncoded: false).flatMap(PublicSuffixList.normalizedHost) else { return nil }
    return publicSuffixes()?.registrableDomain(of: host)
      ?? (host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host)
  }

  /// Whether the URL's host is a blocked domain or under one; used for Brave's results, which
  /// the on-device lists never see (D132).
  func isBlocked(_ url: URL) -> Bool {
    guard let host = url.host(percentEncoded: false).flatMap(PublicSuffixList.normalizedHost) else { return false }
    return blockedSites.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  /// The blocked domains, most recent first, for F30's provider search (spec §8).
  var blockedDomainsMostRecentFirst: [String] { blockedSites.reversed() }

  func unblock(_ domain: String) {
    guard let domain = PublicSuffixList.normalizedHost(domain), blockedSites.contains(domain) else { return }
    blockedSites.removeAll { $0 == domain }
    defaults.set(blockedSites, forKey: Self.blockedSitesKey)
  }

  /// Lowercased, deduplicated domains, at most `maximumBlockedSites` of them; anything holding a
  /// path, scheme or space is dropped.
  private static func sanitizedBlockList(_ stored: [String]) -> [String] {
    var seen = Set<String>()
    let domains = stored.compactMap { entry -> String? in
      guard !entry.contains(where: { "/:@ ?#".contains($0) }),
            let domain = PublicSuffixList.normalizedHost(entry), seen.insert(domain).inserted else { return nil }
      return domain
    }
    return Array(domains.suffix(maximumBlockedSites))
  }

  /// Reads the Keychain again, as when Brave found no key that this setting still showed (D141).
  func refreshKeyState() {
    hasAPIKey = (try? credentials.containsAPIKey()) ?? false
  }

  func saveAPIKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw WebSearchError.missingAPIKey }
    try credentials.setAPIKey(key)
    hasAPIKey = true
  }

  func removeAPIKey() throws {
    try credentials.removeAPIKey()
    hasAPIKey = false
  }
}

/// What the optional Brave key field in Settings does (D128).
extension WebSearchSettings {
  /// Save stays off until something other than spaces is typed.
  static func canSaveAPIKey(_ field: String) -> Bool {
    !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Saves the typed key to the Keychain and clears the field. On failure the
  /// field keeps what was typed and the error's message is returned.
  func saveAPIKey(from field: inout String) -> String? {
    do {
      try saveAPIKey(field)
      field = ""
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// Removes the stored key and clears the field, returning the error's message on failure.
  func removeAPIKey(clearing field: inout String) -> String? {
    do {
      try removeAPIKey()
      field = ""
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}
