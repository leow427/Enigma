import XCTest
@testable import Enigma

final class SearchHTTPClientTests: XCTestCase {
  override func tearDown() {
    SearchStubProtocol.reset()
    super.tearDown()
  }

  private func client() -> URLSessionSearchHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SearchStubProtocol.self]
    return URLSessionSearchHTTPClient(configuration: configuration)
  }

  func testClientDoesNotFollowRedirects() async throws {
    SearchStubProtocol.reply = { _ in
      (302, ["Location": "https://b.example/"], Data())
    }
    let response = try await client().send(URLRequest(url: URL(string: "https://a.example/")!), maximumBytes: 1_000)
    XCTAssertEqual(response.statusCode, 302)
    XCTAssertEqual(response.headers["location"], "https://b.example/")
    XCTAssertEqual(SearchStubProtocol.requests.count, 1)
    XCTAssertEqual(SearchStubProtocol.requests.first?.url?.host(), "a.example")
  }

  func testClientStopsAtByteLimit() async throws {
    SearchStubProtocol.reply = { _ in (200, [:], Data(repeating: 0x61, count: 3_000_000)) }
    let response = try await client().send(URLRequest(url: URL(string: "https://a.example/")!), maximumBytes: 2_097_152)
    XCTAssertEqual(response.body.count, 2_097_152)
    XCTAssertTrue(response.truncated)
  }

  func testClientReadsWholeBodyUnderLimit() async throws {
    SearchStubProtocol.reply = { _ in (200, ["Content-Type": "text/html"], Data(repeating: 0x61, count: 1_000)) }
    let response = try await client().send(URLRequest(url: URL(string: "https://a.example/")!), maximumBytes: 1_000)
    XCTAssertEqual(response.body.count, 1_000)
    XCTAssertFalse(response.truncated)
    XCTAssertEqual(response.headers["content-type"], "text/html")
    XCTAssertEqual(response.url, URL(string: "https://a.example/"))
  }

  func testClientKeepsNoCookies() async throws {
    SearchStubProtocol.reply = { _ in (200, ["Set-Cookie": "a=1; Path=/"], Data("x".utf8)) }
    let client = client()
    _ = try await client.send(URLRequest(url: URL(string: "https://a.example/")!), maximumBytes: 1_000)
    _ = try await client.send(URLRequest(url: URL(string: "https://a.example/")!), maximumBytes: 1_000)
    XCTAssertEqual(SearchStubProtocol.requests.count, 2)
    XCTAssertNil(SearchStubProtocol.requests[1].value(forHTTPHeaderField: "Cookie"))
  }

  /// The stub protocol bypasses cookie handling, so the settings themselves are checked too.
  func testSessionStoresNothing() {
    let configuration = URLSessionSearchHTTPClient(configuration: .default).configuration
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.urlCredentialStorage)
  }

  func testSafariUserAgent() {
    XCTAssertEqual(
      SafariHeaders.userAgent(safariVersion: "26.1"),
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15")
    XCTAssertFalse(SafariHeaders.installedSafariVersion.isEmpty)
  }

  func testAcceptLanguage() {
    XCTAssertEqual(SafariHeaders.acceptLanguage(["en-GB"]), "en-GB,en;q=0.9")
    XCTAssertEqual(SafariHeaders.acceptLanguage(["en-GB", "fr-FR"]), "en-GB,en;q=0.9,fr-FR;q=0.8,fr;q=0.7")
    XCTAssertEqual(SafariHeaders.acceptLanguage([]), "en-US,en;q=0.9")
    XCTAssertEqual(SafariHeaders.acceptLanguage(["en-GB", "en-US"]), "en-GB,en;q=0.9,en-US;q=0.8")
    XCTAssertEqual(SafariHeaders.acceptLanguage(["en"]), "en")
    // The q-value never drops below 0.5.
    XCTAssertEqual(SafariHeaders.acceptLanguage(["de-DE", "fr-FR", "es-ES", "it-IT"]),
                   "de-DE,de;q=0.9,fr-FR;q=0.8,fr;q=0.7,es-ES;q=0.6,es;q=0.5,it-IT;q=0.5,it;q=0.5")
  }

  /// Header set A (owner, CP0b): GETs say `Sec-Fetch-Site: none`, form POSTs say `same-origin`
  /// with `Origin` and `Referer`; both send `Priority`.
  func testHeaderSetA() {
    let get = SafariHeaders.standard(acceptLanguage: "en-US,en;q=0.9")
    XCTAssertEqual(get["User-Agent"], SafariHeaders.userAgent(safariVersion: SafariHeaders.installedSafariVersion))
    XCTAssertEqual(get["Accept"], "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    XCTAssertEqual(get["Accept-Language"], "en-US,en;q=0.9")
    XCTAssertEqual(get["Sec-Fetch-Dest"], "document")
    XCTAssertEqual(get["Sec-Fetch-Mode"], "navigate")
    XCTAssertEqual(get["Sec-Fetch-Site"], "none")
    XCTAssertEqual(get["Priority"], "u=0, i")
    XCTAssertNil(get["Origin"])
    XCTAssertNil(get["Referer"])

    let post = SafariHeaders.formPost(to: URL(string: "https://html.duckduckgo.com/html/")!,
                                      acceptLanguage: "en-US,en;q=0.9")
    XCTAssertEqual(post["Sec-Fetch-Site"], "same-origin")
    XCTAssertEqual(post["Origin"], "https://html.duckduckgo.com")
    XCTAssertEqual(post["Referer"], "https://html.duckduckgo.com/")
    XCTAssertEqual(post["Priority"], "u=0, i")
    XCTAssertEqual(post["User-Agent"], get["User-Agent"])
  }
}

/// Answers every request from `reply` and records it.
private final class SearchStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var reply: @Sendable (URLRequest) -> (Int, [String: String], Data) = { _ in (200, [:], Data()) }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recorded: [URLRequest] = []

  static var requests: [URLRequest] { lock.withLock { recorded } }
  static func reset() {
    lock.withLock { recorded = [] }
    reply = { _ in (200, [:], Data()) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.recorded.append(request) }
    let (status, headers, body) = Self.reply(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
