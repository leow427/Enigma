import Foundation

/// One HTTP response from a search site or result page, read up to a byte limit.
struct SearchHTTPResponse: Equatable, Sendable {
  let url: URL
  let statusCode: Int
  /// Header names lowercased.
  let headers: [String: String]
  let body: Data
  /// True when the body was cut at the byte limit.
  let truncated: Bool
  /// The server address the response came from; nil when unknown or reached through a proxy.
  var remoteAddress: String? = nil
}

protocol SearchHTTPClient: Sendable {
  /// Never follows redirects: a 3xx response comes back as is. Stops reading after maximumBytes.
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse
}

/// Search's own URLSession: ephemeral, with no cookies, cache, stored credentials or redirects
/// (spec §2, "Store nothing").
final class URLSessionSearchHTTPClient: SearchHTTPClient {
  static let live = URLSessionSearchHTTPClient()

  private let session: URLSession
  /// The settings the session runs with, for tests.
  var configuration: URLSessionConfiguration { session.configuration }

  init(configuration: URLSessionConfiguration = .ephemeral) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCredentialStorage = nil
    // Callers set the real time limits; this only stops a stalled connection lingering.
    configuration.timeoutIntervalForRequest = 15
    session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  /// The address a request's connection reached: the last transaction that reports one, or nil
  /// when that transaction went through a proxy, whose address says nothing about the site and is
  /// often loopback or private (D70). A plain-HTTP proxy reports `isProxyConnection == false`, but
  /// page reading is https only (ATS, D71), and an https proxy (CONNECT) does report it.
  static func reachedAddress(_ transactions: [(isProxy: Bool, address: String?)]) -> String? {
    guard let last = transactions.last(where: { $0.address != nil }) else { return nil }
    return last.isProxy ? nil : last.address
  }

  /// How long to wait, after the body, for the connection's metrics (the remote address).
  static let metricsWait: Duration = .milliseconds(250)

  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse {
    let metrics = RemoteAddressCollector()
    let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var body = Data()
    body.reserveCapacity(min(max(Int(http.expectedContentLength), 0), maximumBytes))
    var truncated = false
    for try await byte in bytes {
      if body.count >= maximumBytes {
        truncated = true
        break
      }
      body.append(byte)
    }
    if truncated { bytes.task.cancel() }
    var headers: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      if let name = name as? String { headers[name.lowercased()] = "\(value)" }
    }
    let remoteAddress = await metrics.remoteAddress(within: Self.metricsWait)
    return SearchHTTPResponse(url: http.url ?? request.url ?? URL(string: "about:blank")!,
                              statusCode: http.statusCode, headers: headers, body: body, truncated: truncated,
                              remoteAddress: remoteAddress)
  }
}

/// A per-task delegate that reads the address the connection reached from the task's metrics,
/// and refuses redirects like the session's own delegate. Through a proxy the address is the
/// proxy's, so it reports none.
private final class RemoteAddressCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var collected = false
  private var address: String?
  private var waiter: CheckedContinuation<String?, Never>?

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    let reached = URLSessionSearchHTTPClient.reachedAddress(
      metrics.transactionMetrics.map { (isProxy: $0.isProxyConnection, address: $0.remoteAddress) })
    let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
      guard !collected else { return nil }
      collected = true
      address = reached
      defer { waiter = nil }
      return waiter
    }
    waiting?.resume(returning: reached)
  }

  /// The address, or nil if the metrics don't arrive within `limit`.
  func remoteAddress(within limit: Duration) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let ready: String?? = lock.withLock {
        if collected { return .some(address) }
        waiter = continuation
        return nil
      }
      if let ready { return continuation.resume(returning: ready) }
      let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
        guard let self else { return }
        let late: CheckedContinuation<String?, Never>? = self.lock.withLock {
          guard !self.collected else { return nil }
          self.collected = true
          defer { self.waiter = nil }
          return self.waiter
        }
        late?.resume(returning: nil)
      }
    }
  }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

/// Safari's request headers, so search sites see an ordinary browser (spec §2, "Look like Safari").
/// The fields are header set A, which the owner chose after CP0b's probe.
enum SafariHeaders {
  static let installedSafariVersion: String = {
    let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
    let version = info?["CFBundleShortVersionString"] as? String
    return version.flatMap { $0.isEmpty ? nil : $0 } ?? "26.0"
  }()

  static func userAgent(safariVersion: String) -> String {
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      + "Version/\(safariVersion) Safari/605.1.15"
  }

  /// Each preferred tag, followed by its base language if that isn't listed yet. The first entry
  /// has no q-value; later ones step down by 0.1 from 0.9, never below 0.5.
  static func acceptLanguage(_ preferred: [String]) -> String {
    var tags: [String] = []
    for tag in preferred where !tag.isEmpty {
      if !tags.contains(tag) { tags.append(tag) }
      if let base = tag.split(separator: "-").first.map(String.init), base != tag, !tags.contains(base) {
        tags.append(base)
      }
    }
    if tags.isEmpty { tags = ["en-US", "en"] }
    return tags.enumerated().map { index, tag in
      guard index > 0 else { return tag }
      return "\(tag);q=0.\(max(5, 10 - index))"
    }.joined(separator: ",")
  }

  /// `acceptLanguage` of the Mac's preferred languages.
  static var preferredAcceptLanguage: String { acceptLanguage(Locale.preferredLanguages) }

  /// Headers for a top-level GET, as if typed into the address bar.
  static func standard(acceptLanguage: String) -> [String: String] {
    [
      "User-Agent": userAgent(safariVersion: installedSafariVersion),
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": acceptLanguage,
      "Sec-Fetch-Dest": "document",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-Site": "none",
      "Priority": "u=0, i",
    ]
  }

  /// Headers for a form POST sent from the site's own page: `same-origin`, with its origin.
  static func formPost(to url: URL, acceptLanguage: String) -> [String: String] {
    var headers = standard(acceptLanguage: acceptLanguage)
    let origin = "\(url.scheme ?? "https")://\(url.host() ?? "")"
    headers["Sec-Fetch-Site"] = "same-origin"
    headers["Origin"] = origin
    headers["Referer"] = origin + "/"
    return headers
  }
}
