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

  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse {
    let (bytes, response) = try await session.bytes(for: request)
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
    return SearchHTTPResponse(url: http.url ?? request.url ?? URL(string: "about:blank")!,
                              statusCode: http.statusCode, headers: headers, body: body, truncated: truncated)
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
