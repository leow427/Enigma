import XCTest
@testable import Enigma

/// Live checks of the search sites. They skip unless `ENIGMA_LIVE_SEARCH=1` reaches the test host
/// (`TEST_RUNNER_ENIGMA_LIVE_SEARCH=1`). With `ENIGMA_SEARCH_FIXTURE_DIR` set to a folder outside the
/// repository, each also saves the raw pages it got there, for sanitizing into fixtures. They print
/// counts and timings only, never result text.
final class WebSearchLiveTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  override func setUpWithError() throws {
    try super.setUpWithError()
    guard environment["ENIGMA_LIVE_SEARCH"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_LIVE_SEARCH=1 to query the search sites.")
    }
  }

  private func capture(_ name: String, _ data: Data) {
    guard let folder = environment["ENIGMA_SEARCH_FIXTURE_DIR"], !folder.isEmpty else { return }
    let directory = URL(fileURLWithPath: folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appending(path: name))
  }

  func testLiveDuckDuckGo() async throws {
    let region = SearchRegion(country: "us", language: "en")
    let request = DuckDuckGoEngine.request(for: EngineQuery(text: "swift concurrency actors", region: region,
                                                            recency: nil))
    let started = ContinuousClock.now
    let response = try await URLSessionSearchHTTPClient.live.send(request, maximumBytes: DuckDuckGoEngine.maximumBytes)
    let elapsed = ContinuousClock.now - started
    capture("duckduckgo-live.html", response.body)

    let outcome = DuckDuckGoEngine.parse(response)
    let page = String(decoding: response.body, as: UTF8.self)
    let echoesRegion = page.range(of: #"name="kl"[^>]*value="us-en""#, options: .regularExpression) != nil
    var count = 0
    if case .results(let results) = outcome { count = results.count }
    print("LIVE duckduckgo status=\(response.statusCode) bytes=\(response.body.count) results=\(count)",
          "ms=\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)",
          "klEchoed=\(echoesRegion)")

    guard case .results(let results) = outcome else { return XCTFail("Expected results, got \(outcome)") }
    XCTAssertGreaterThanOrEqual(results.count, 5)
    XCTAssertFalse(results.contains { $0.url.absoluteString.hasPrefix("https://duckduckgo.com/y.js?") })
    XCTAssertTrue(echoesRegion, "DuckDuckGo should echo the kl region it was sent")
  }

  func testLiveWikipedia() async throws {
    let client = CapturingClient(base: URLSessionSearchHTTPClient.live)
    let started = ContinuousClock.now
    let outcome = await WikipediaSearch().lookup("Alan Turing", preferredLanguages: ["en-US"], using: client)
    let elapsed = ContinuousClock.now - started
    for (index, body) in client.bodies.enumerated() { capture("wikipedia-live-\(index + 1).json", body) }

    var length = 0
    if case .article(let article) = outcome { length = article.text.count }
    print("LIVE wikipedia requests=\(client.bodies.count) characters=\(length)",
          "ms=\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)")
    guard case .article(let article) = outcome else { return XCTFail("Expected an article, got \(outcome)") }
    XCTAssertGreaterThan(article.text.count, 1_000)
    XCTAssertEqual(article.url.host(), "en.wikipedia.org")
  }
}

private final class CapturingClient: SearchHTTPClient, @unchecked Sendable {
  let base: any SearchHTTPClient
  private let lock = NSLock()
  private var captured: [Data] = []
  init(base: any SearchHTTPClient) { self.base = base }
  var bodies: [Data] { lock.withLock { captured } }

  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse {
    let response = try await base.send(request, maximumBytes: maximumBytes)
    lock.withLock { captured.append(response.body) }
    return response
  }
}
