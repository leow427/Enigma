import Darwin
import Foundation

/// Turns a host name into numeric IPv4 or IPv6 address strings.
protocol HostResolver: Sendable {
  func addresses(for host: String) async throws -> [String]
}

/// The system resolver (`getaddrinfo`), run on a global queue so a slow lookup never blocks the
/// main actor or Swift's cooperative pool.
struct SystemHostResolver: HostResolver {
  struct LookupFailed: Error { let code: Int32 }

  private let lookUp: @Sendable (String) throws -> [String]

  /// `lookUp` is a blocking lookup, for tests; the default is `getaddrinfo`.
  init(lookUp: @escaping @Sendable (String) throws -> [String] = SystemHostResolver.getAddresses) {
    self.lookUp = lookUp
  }

  /// `getaddrinfo` can't be cancelled, so a cancelled caller is answered at once and the lookup's
  /// late result is dropped.
  func addresses(for host: String) async throws -> [String] {
    let answer = OneAnswer()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        answer.set(continuation)
        DispatchQueue.global(qos: .userInitiated).async { [lookUp] in
          answer.resume(with: Result { try lookUp(host) })
        }
      }
    } onCancel: {
      answer.resume(with: .failure(CancellationError()))
    }
  }

  /// Resumes a continuation once, from whichever of the lookup or cancellation comes first.
  private final class OneAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], any Error>?
    private var early: Result<[String], any Error>?

    func set(_ continuation: CheckedContinuation<[String], any Error>) {
      let pending: Result<[String], any Error>? = lock.withLock {
        if let early { return early }
        self.continuation = continuation
        return nil
      }
      if let pending { continuation.resume(with: pending) }
    }

    func resume(with result: Result<[String], any Error>) {
      let waiting: CheckedContinuation<[String], any Error>? = lock.withLock {
        guard let continuation else {
          if early == nil { early = result }
          return nil
        }
        self.continuation = nil
        early = result
        return continuation
      }
      waiting?.resume(with: result)
    }
  }

  static func getAddresses(_ host: String) throws -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &list)
    guard status == 0, let first = list else { throw LookupFailed(code: status) }
    defer { freeaddrinfo(first) }
    var addresses: [String] = []
    for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
      guard let socketAddress = entry.pointee.ai_addr else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(socketAddress, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST)
      guard result == 0 else { continue }
      var address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      // A scoped IPv6 address ("fe80::1%en0") is judged without its zone.
      if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
      if !addresses.contains(address) { addresses.append(address) }
    }
    return addresses
  }
}

/// Keeps page reading off the local network (spec §4): no local names, and no private, loopback,
/// link-local, CGNAT, multicast or unspecified address, whether written in the link or among the
/// host's DNS answers. It runs before every request, including each redirect; the small window
/// between this lookup and URLSession's own is accepted (spec §4).
struct NetworkGuard: Sendable {
  private let resolver: any HostResolver

  init(resolver: any HostResolver = SystemHostResolver()) {
    self.resolver = resolver
  }

  /// Name endings that exist only on local networks or never on the public web. D64 added the
  /// last six to the brief's four.
  static let refusedSuffixes = ["local", "lan", "internal", "home.arpa", "localhost", "localdomain", "home", "corp",
                                "intranet", "onion"]

  /// Refuses `localhost`, single-label names and the local-only endings. `allows(_:)` judges IP
  /// literals by their address.
  static func isAllowedName(_ host: String) -> Bool {
    var name = host.lowercased()
    while name.hasSuffix(".") { name.removeLast() }
    guard !name.isEmpty, name != "localhost", name.contains(".") else { return false }
    return !refusedSuffixes.contains { name.hasSuffix("." + $0) }
  }

  /// True only for a well-formed numeric address outside every refused range.
  static func isPublicAddress(_ address: String) -> Bool {
    if let v4 = ipv4Bytes(address) { return isPublicIPv4(v4) }
    if let v6 = ipv6Bytes(address) { return isPublicIPv6(v6) }
    return false
  }

  /// `.unresolved` is a lookup that failed, came back empty or was cancelled: not a refusal, so the
  /// result's snippet stays usable (D69).
  enum Verdict: Equatable, Sendable { case allowed, refused, unresolved }

  /// True only when `check(_:)` allows the link.
  func allows(_ url: URL) async -> Bool {
    await check(url) == .allowed
  }

  /// The name rule, then a literal address, then every address the host resolves to.
  func check(_ url: URL) async -> Verdict {
    guard var host = url.host(percentEncoded: false), !host.isEmpty else { return .refused }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if Self.ipv4Bytes(host) != nil || Self.ipv6Bytes(host) != nil {
      return Self.isPublicAddress(host) ? .allowed : .refused
    }
    guard Self.isAllowedName(host) else { return .refused }
    guard let addresses = try? await resolver.addresses(for: host), !addresses.isEmpty, !Task.isCancelled else {
      return .unresolved
    }
    return addresses.allSatisfy(Self.isPublicAddress) ? .allowed : .refused
  }

  /// Like `isPublicAddress`, for an address as the network reports it: an IPv6 zone
  /// (`fe80::1%en0`) or brackets are ignored.
  static func isPublicRemoteAddress(_ address: String) -> Bool {
    var text = address
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") { text = String(text[text.index(after: text.startIndex)..<close]) }
    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
    return isPublicAddress(text)
  }

  // MARK: Address ranges

  private static func ipv4Bytes(_ text: String) -> [UInt8]? {
    var address = in_addr()
    guard !text.isEmpty, inet_pton(AF_INET, text, &address) == 1 else { return nil }
    return withUnsafeBytes(of: address.s_addr) { Array($0) }
  }

  private static func ipv6Bytes(_ text: String) -> [UInt8]? {
    var address = in6_addr()
    guard text.contains(":"), inet_pton(AF_INET6, text, &address) == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
  }

  private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
    switch (b[0], b[1]) {
    case (0, _), (10, _), (127, _): return false   // this network, private, loopback
    case (100, 64...127): return false              // carrier-grade NAT
    case (169, 254): return false                   // link-local
    case (172, 16...31): return false               // private
    case (192, 168): return false                   // private
    case (224..., _): return false                  // multicast, reserved, broadcast
    default: return true
    }
  }

  private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
    if b[0..<12].allSatisfy({ $0 == 0 }) {
      // ::, ::1, and the deprecated IPv4-compatible ::a.b.c.d (D64).
      if b[12..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return false }
      return isPublicIPv4(Array(b[12..<16]))
    }
    // IPv4-mapped ::ffff:a.b.c.d.
    if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublicIPv4(Array(b[12..<16])) }
    // NAT64 64:ff9b::a.b.c.d (D64).
    if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B, b[4..<12].allSatisfy({ $0 == 0 }) {
      return isPublicIPv4(Array(b[12..<16]))
    }
    if b[0] == 0xFF { return false }                           // ff00::/8 multicast
    if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return false }  // fe80::/10 link-local
    if b[0] == 0xFE && (b[1] & 0xC0) == 0xC0 { return false }  // fec0::/10 old site-local (D64)
    if (b[0] & 0xFE) == 0xFC { return false }                  // fc00::/7 unique local
    return true
  }
}

/// A downloaded result page, decoded to text.
struct FetchedPage: Equatable, Sendable {
  enum Format: Equatable, Sendable { case html, text }
  let requestedURL: URL
  let finalURL: URL
  let format: Format
  let content: String
}

enum PageFetchOutcome: Equatable, Sendable {
  case page(FetchedPage)
  /// Not HTML or plain text (a PDF, an image): the result's snippet stays usable.
  case skipped
  /// A network or HTTP error, too many redirects, or cancellation: the snippet stays usable.
  case failed
  /// The local-network guard, the blocklist or a non-http(s) link refused a hop: use neither the
  /// page nor its snippet (D64).
  case refused
}

/// Downloads one result page as Safari would, one GET per hop, never reaching the local network
/// or a blocked site (spec §4). Nothing is cached, stored or logged.
struct PageReader: Sendable {
  /// The most of an article page that's read (spec §4: 3 MB).
  static let maximumBytes = 3_145_728
  static let maximumRedirects = 5
  /// How far into a page a `<meta charset>` or `http-equiv` declaration counts.
  static let charsetScanBytes = 2_048

  private let client: any SearchHTTPClient
  private let networkGuard: NetworkGuard
  private let isBlocked: @Sendable (URL) -> Bool
  private let acceptLanguage: String

  init(client: any SearchHTTPClient, networkGuard: NetworkGuard, isBlocked: @escaping @Sendable (URL) -> Bool,
       acceptLanguage: String = SafariHeaders.preferredAcceptLanguage) {
    self.client = client
    self.networkGuard = networkGuard
    self.isBlocked = isBlocked
    self.acceptLanguage = acceptLanguage
  }

  /// Pages are read over https only: App Transport Security blocks plain http, and Enigma doesn't
  /// loosen it (D71). An `http` link is read as `https`, once.
  func fetch(_ url: URL) async -> PageFetchOutcome {
    guard url.scheme?.lowercased() == "http",
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return await follow(url, requestedURL: url)
    }
    components.scheme = "https"
    if components.port == 80 { components.port = nil }
    guard let secure = components.url else { return .failed }
    return await follow(secure, requestedURL: url)
  }

  private func follow(_ start: URL, requestedURL: URL) async -> PageFetchOutcome {
    var current = start
    var redirects = 0
    while true {
      switch await permission(for: current) {
      case .allowed: break
      case .refused: return .refused
      case .unresolved: return .failed
      }
      // A hop to plain http (a redirect) passes the checks above first, so a blocked or local
      // target is still refused; otherwise ATS would block it, so it's a failure (D71).
      if current.scheme?.lowercased() != "https" { return .failed }
      let response: SearchHTTPResponse
      do {
        response = try await client.send(request(for: current), maximumBytes: Self.maximumBytes)
      } catch {
        return .failed
      }
      // The address the connection really reached, which closes most of the window between the
      // guard's lookup and URLSession's own (DNS rebinding, D69). Unknown (a proxy) is kept.
      if let remote = response.remoteAddress, !NetworkGuard.isPublicRemoteAddress(remote) { return .refused }
      switch response.statusCode {
      case 301, 302, 303, 307, 308:
        guard let location = response.headers["location"], !location.isEmpty,
              let next = URL(string: location, relativeTo: current)?.absoluteURL else { return .failed }
        redirects += 1
        guard redirects <= Self.maximumRedirects else { return .failed }
        current = next
      case 200...299 where response.statusCode != 204 && response.statusCode != 205:
        return page(from: response, requestedURL: requestedURL, finalURL: current)
      default:
        return .failed
      }
    }
  }

  /// http(s) only, no credentials, not blocked, and through the local-network guard.
  private func permission(for url: URL) async -> NetworkGuard.Verdict {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil,
          !isBlocked(url) else { return .refused }
    let verdict = await networkGuard.check(url)
    return Task.isCancelled ? .unresolved : verdict
  }

  private func request(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    for (name, value) in SafariHeaders.standard(acceptLanguage: acceptLanguage) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  private func page(from response: SearchHTTPResponse, requestedURL: URL, finalURL: URL) -> PageFetchOutcome {
    let contentType = response.headers["content-type"]
    let format: FetchedPage.Format
    switch Self.mediaType(contentType) {
    case "text/html", "application/xhtml+xml": format = .html
    case "text/plain": format = .text
    case nil where Self.looksLikeHTML(response.body): format = .html
    default: return .skipped
    }
    guard let content = Self.decode(response.body, contentType: contentType) else { return .failed }
    return .page(FetchedPage(requestedURL: requestedURL, finalURL: finalURL, format: format, content: content))
  }

  private static func mediaType(_ contentType: String?) -> String? {
    guard let type = contentType?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return nil }
    return type
  }

  /// A response with no `Content-Type` counts as HTML only when it opens like HTML (D65).
  private static func looksLikeHTML(_ body: Data) -> Bool {
    let start = String(decoding: body.prefix(512), as: UTF8.self).lowercased()
    return start.contains("<!doctype html") || start.contains("<html")
  }

  // MARK: Decoding

  /// A byte-order mark, then the HTTP header's charset, then a `<meta charset>` or `http-equiv`
  /// declaration in the first 2,048 bytes, then UTF-8, then Windows-1252 (spec §4, D65).
  static func decode(_ body: Data, contentType: String?) -> String? {
    // A byte-order mark settles the encoding; bad bytes become replacement characters (D71).
    if body.starts(with: [0xEF, 0xBB, 0xBF]) {
      let rest = body.dropFirst(3)
      return decodeUTF8(rest) ?? String(decoding: rest, as: UTF8.self)
    }
    if body.starts(with: [0xFF, 0xFE]) { return decodeUTF16(body.dropFirst(2), littleEndian: true) }
    if body.starts(with: [0xFE, 0xFF]) { return decodeUTF16(body.dropFirst(2), littleEndian: false) }
    let declared = [contentType.flatMap(headerCharset), metaCharset(in: body)]
    for name in declared.compactMap({ $0 }) {
      guard let encoding = encoding(named: name) else { continue }
      if encoding == .utf8 {
        if let text = mostlyUTF8(body) { return text }
      } else if let text = String(data: body, encoding: encoding) {
        return text
      }
    }
    if let text = mostlyUTF8(body) { return text }
    return String(data: body, encoding: .windowsCP1252) ?? String(data: body, encoding: .isoLatin1)
  }

  /// Strict UTF-8 if it decodes; otherwise UTF-8 with replacement characters, as long as at most
  /// half the non-ASCII bytes are invalid, so one stray byte doesn't garble a whole page (D69).
  private static func mostlyUTF8(_ body: Data) -> String? {
    if let text = decodeUTF8(body) { return text }
    let nonASCII = body.reduce(0) { $0 + ($1 >= 0x80 ? 1 : 0) }
    let text = String(decoding: body, as: UTF8.self)
    let replaced = text.unicodeScalars.reduce(0) { $0 + ($1 == "\u{FFFD}" ? 1 : 0) }
    return replaced * 2 <= nonASCII ? text : nil
  }

  /// UTF-16 with replacement characters, dropping a cut tail: an odd last byte, or the first half
  /// of a surrogate pair.
  private static func decodeUTF16(_ body: Data, littleEndian: Bool) -> String {
    let bytes = Array(body.prefix(body.count & ~1))
    var units = stride(from: 0, to: bytes.count, by: 2).map { index in
      littleEndian ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                   : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
    if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
  }

  /// Strict UTF-8, forgiving only a multi-byte character cut off at the end by the byte limit.
  private static func decodeUTF8(_ body: Data) -> String? {
    for cut in 0...3 where body.count >= cut {
      let kept = body.dropLast(cut)
      if let text = String(data: kept, encoding: .utf8) { return text }
      guard let last = kept.last, last & 0x80 != 0 else { return nil }
    }
    return nil
  }

  private static func headerCharset(_ contentType: String) -> String? {
    for parameter in contentType.split(separator: ";").dropFirst() {
      let parts = parameter.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
      let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// The charset named by `<meta charset=…>` or `<meta http-equiv="Content-Type" content="…; charset=…">`
  /// in the first 2,048 bytes: a byte scan for the declaration, not an HTML parse.
  private static func metaCharset(in body: Data) -> String? {
    let head = String(decoding: body.prefix(charsetScanBytes).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self).lowercased()
    var searchStart = head.startIndex
    while let meta = head.range(of: "<meta", range: searchStart..<head.endIndex) {
      let tagEnd = head[meta.upperBound...].firstIndex(of: ">") ?? head.endIndex
      let tag = head[meta.upperBound..<tagEnd]
      if let charset = tag.range(of: "charset") {
        let value = tag[charset.upperBound...]
          .drop { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" }
          .prefix { $0.isLetter || $0.isNumber || "-_:.".contains($0) }
        if !value.isEmpty { return String(value) }
      }
      searchStart = tagEnd
    }
    return nil
  }

  private static func encoding(named name: String) -> String.Encoding? {
    let lowered = name.lowercased()
    // As browsers do (WHATWG), ISO-8859-1 and ASCII labels decode as Windows-1252.
    if ["iso-8859-1", "iso8859-1", "latin1", "us-ascii", "ascii"].contains(lowered) { return .windowsCP1252 }
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(lowered as CFString)
    guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
  }
}
