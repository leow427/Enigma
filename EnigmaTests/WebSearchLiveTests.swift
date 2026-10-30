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

  /// CP4: downloads and extracts a few public pages of different kinds through the real
  /// `PageReader` and `ArticleExtractor`. Prints the page's position in this list with counts and
  /// timings, never a link or page text.
  func testLivePageReading() async throws {
    let pages = livePages
    let extracted = await Self.readLivePages(pages)
    XCTAssertGreaterThanOrEqual(extracted, pages.count / 2)
  }

  private var livePages: [String] {
    [
      "http://en.wikipedia.org/wiki/Alan_Turing",                   // http link, large article
      "https://www.rfc-editor.org/rfc/rfc9110.html",                 // very long page
      "https://docs.python.org/3/library/json.html",                 // docs with code
      "https://www.gov.uk/bank-holidays",                            // government page with tables
      "https://www.nhs.uk/conditions/flu/",                          // health authority
      "https://developer.apple.com/documentation/swift/array",       // script-rendered docs
    ]
  }

  @MainActor private static func readLivePages(_ pages: [String]) async -> Int {
    let reader = PageReader(client: URLSessionSearchHTTPClient.live, networkGuard: NetworkGuard(), isBlocked: { _ in false })
    let extractor = ArticleExtractor()
    extractor.warmUp()
    var extracted = 0
    for (index, link) in pages.enumerated() {
      let fetchStart = ContinuousClock.now
      let outcome = await reader.fetch(URL(string: link)!)
      let fetchTime = ContinuousClock.now - fetchStart
      guard case .page(let page) = outcome else {
        print("LIVE page \(index) outcome=\(outcome) fetch=\(fetchTime)")
        continue
      }
      let extractStart = ContinuousClock.now
      do {
        let article = try await extractor.extract(html: page.content, url: page.finalURL)
        let extractTime = ContinuousClock.now - extractStart
        extracted += 1
        var kinds: [String: Int] = [:]
        for block in article.blocks { kinds[block.kind.rawValue, default: 0] += 1 }
        let verdict = PageChecks.basic(article, isWikipedia: false, allowedLanguages: ["en"])
        print("LIVE page \(index) format=\(page.format) chars=\(page.content.count) fetch=\(fetchTime)",
              "extract=\(extractTime) words=\(article.wordCount) readerable=\(article.isReaderable)",
              "verdict=\(verdict) published=\(article.published != nil) modified=\(article.modified != nil)",
              "site=\(article.siteName != nil) lang=\(article.language ?? "-") blocks=\(kinds.sorted { $0.key < $1.key })")
      } catch {
        print("LIVE page \(index) format=\(page.format) chars=\(page.content.count) fetch=\(fetchTime)",
              "extract-error=\(error) after \(ContinuousClock.now - extractStart)")
      }
    }
    return extracted
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
