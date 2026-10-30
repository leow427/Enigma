import Foundation

/// Mozilla's Public Suffix List (bundled as `SearchData/public_suffix_list.dat`, MPL-2.0), which
/// tells a site's registrable domain: `news.bbc.co.uk` is `bbc.co.uk` (spec §3.2).
struct PublicSuffixList: Sendable {
  private let rules: Set<String>
  private let wildcards: Set<String>
  private let exceptions: Set<String>

  /// The .dat format: `//` comments, one rule per line ending at the first space, `*.` wildcards
  /// and `!` exceptions. Rules in Unicode are stored in their punycode form.
  init(contents: String) {
    var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
    for line in contents.split(whereSeparator: \.isNewline) {
      guard let token = line.split(whereSeparator: \.isWhitespace).first, !token.hasPrefix("//") else { continue }
      var rule = String(token)
      if rule.hasPrefix("!") {
        rule.removeFirst()
        if let host = Self.normalizedHost(rule) { exceptions.insert(host) }
      } else if rule.hasPrefix("*.") {
        rule.removeFirst(2)
        if let host = Self.normalizedHost(rule) { wildcards.insert(host) }
      } else if let host = Self.normalizedHost(rule) {
        rules.insert(host)
      }
    }
    self.rules = rules
    self.wildcards = wildcards
    self.exceptions = exceptions
  }

  /// nil for IP addresses, single labels, and public suffixes themselves.
  func registrableDomain(of host: String) -> String? {
    guard let host = Self.normalizedHost(host), !Self.isIPAddress(host) else { return nil }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
    for index in labels.indices {
      let candidate = labels[index...].joined(separator: ".")
      if exceptions.contains(candidate) { return candidate }
      let parent = labels[(index + 1)...].joined(separator: ".")
      if rules.contains(candidate) || (index + 1 < labels.count && wildcards.contains(parent)) {
        return index > 0 ? labels[(index - 1)...].joined(separator: ".") : nil
      }
    }
    // The default rule "*": the last label is the suffix.
    return labels.suffix(2).joined(separator: ".")
  }

  /// Lowercase ASCII, without a trailing dot or IPv6 brackets; Unicode labels become punycode,
  /// which is the form `URL.host` gives. nil for an empty or unconvertible host.
  static func normalizedHost(_ host: String) -> String? {
    var host = host.trimmingCharacters(in: .whitespaces)
    while host.hasSuffix(".") { host.removeLast() }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.isEmpty else { return nil }
    if !host.unicodeScalars.allSatisfy(\.isASCII) {
      guard let encoded = URL(string: "http://\(host)/")?.host, encoded.unicodeScalars.allSatisfy(\.isASCII) else {
        return nil
      }
      host = encoded
    }
    return host.lowercased()
  }

  static func isIPAddress(_ host: String) -> Bool {
    host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
  }
}
