import XCTest
@testable import Enigma

final class SearchEngineTests: XCTestCase {
  private let usEnglish = SearchRegion(country: "us", language: "en")
  private let ddgURL = URL(string: "https://html.duckduckgo.com/html/")!

  private func page(_ name: String, status: Int = 200) -> SearchHTTPResponse {
    SearchHTTPResponse(url: ddgURL, statusCode: status, headers: [:], body: SearchFixture.data(name), truncated: false)
  }

  private func page(html: String, status: Int = 200) -> SearchHTTPResponse {
    SearchHTTPResponse(url: ddgURL, statusCode: status, headers: [:], body: Data(html.utf8), truncated: false)
  }

  private func results(_ outcome: EngineOutcome, file: StaticString = #filePath, line: UInt = #line) -> [EngineResult] {
    guard case .results(let results) = outcome else {
      XCTFail("Expected results, got \(outcome)", file: file, line: line)
      return []
    }
    return results
  }

  // MARK: DuckDuckGo request

  func testDuckDuckGoRequestIsFormPost() {
    let request = DuckDuckGoEngine.request(for: EngineQuery(text: "swift actors", region: usEnglish, recency: nil))
    XCTAssertEqual(request.url, ddgURL)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    // The owner chose `kl` over ddgs's `l` (CP0b): DuckDuckGo reads only `kl`.
    XCTAssertEqual(formFields(request.httpBody), ["q": "swift actors", "b": "", "kl": "us-en"])

    let week = DuckDuckGoEngine.request(for: EngineQuery(text: "swift actors", region: usEnglish, recency: .week))
    XCTAssertEqual(formFields(week.httpBody), ["q": "swift actors", "b": "", "kl": "us-en", "df": "w"])
  }

  func testDuckDuckGoSendsHeaderSetA() {
    let request = DuckDuckGoEngine.request(for: EngineQuery(text: "swift actors", region: usEnglish, recency: nil))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://html.duckduckgo.com")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://html.duckduckgo.com/")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Priority"), "u=0, i")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Mode"), "navigate")
    XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0 (Macintosh;") == true)
    XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept-Language"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
  }

  func testDuckDuckGoEncodesNonLatinQuery() throws {
    let request = DuckDuckGoEngine.request(for: EngineQuery(text: "東京", region: usEnglish, recency: nil))
    let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    XCTAssertTrue(body.hasPrefix("q=%E6%9D%B1%E4%BA%AC&"), body)
    XCTAssertTrue(body.allSatisfy(\.isASCII))
    XCTAssertEqual(formFields(request.httpBody)["q"], "東京")

    let symbols = DuckDuckGoEngine.request(for: EngineQuery(text: "c++ & rust = 100%", region: usEnglish, recency: nil))
    XCTAssertEqual(formFields(symbols.httpBody)["q"], "c++ & rust = 100%")
  }

  func testDuckDuckGoPagePayload() {
    let query = EngineQuery(text: "swift actors", region: usEnglish, recency: nil)
    XCTAssertNil(formFields(DuckDuckGoEngine.request(for: query, page: 1).httpBody)["s"])
    XCTAssertEqual(formFields(DuckDuckGoEngine.request(for: query, page: 2).httpBody)["s"], "10")
    XCTAssertEqual(formFields(DuckDuckGoEngine.request(for: query, page: 3).httpBody)["s"], "25")
  }

  func testDuckDuckGoRegionCodes() {
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "us", language: "en")), "us-en")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "gb", language: "en")), "uk-en")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "jp", language: "ja")), "jp-jp")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "ca", language: "fr")), "ca-fr")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "ca", language: "en")), "ca-en")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "de", language: "en")), "de-de")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "tw", language: "zh")), "tw-tzh")
    XCTAssertEqual(DuckDuckGoEngine.regionCode(for: SearchRegion(country: "zz", language: "en")), "wt-wt")
  }

  /// Every code the table can send is one DuckDuckGo lists in its own region menu (D42).
  func testDuckDuckGoRegionCodesAreListedByDuckDuckGo() throws {
    let page = SearchFixture.string("duckduckgo-no-results.html")
    let menu = try XCTUnwrap(page.range(of: #"<select[^>]*name="kl"[\s\S]*?</select>"#, options: .regularExpression))
    let listed = Set(page[menu].matches(of: /<option value="([^"]+)"/).map { String($0.1) })
    XCTAssertGreaterThan(listed.count, 50)
    XCTAssertFalse(DuckDuckGoEngine.regionCodes.isEmpty)
    for code in DuckDuckGoEngine.regionCodes {
      XCTAssertTrue(listed.contains(code), "\(code) isn't in DuckDuckGo's region menu")
    }
  }

  func testSearchRegionFromLocale() {
    XCTAssertEqual(SearchRegion.current(Locale(identifier: "en_US")).code, "us-en")
    XCTAssertEqual(SearchRegion.current(Locale(identifier: "fr_CA")).code, "ca-fr")
    XCTAssertEqual(SearchRegion.current(Locale(identifier: "zh-Hant_TW")).code, "tw-zh")
    XCTAssertEqual(SearchRegion.current(Locale(identifier: "en")).code, "us-en")
  }

  // MARK: DuckDuckGo parsing

  func testDuckDuckGoParsesResults() {
    let results = results(DuckDuckGoEngine.parse(page("duckduckgo-results.html")))
    XCTAssertEqual(results.count, 10)
    XCTAssertEqual(results.first?.title, "Concurrency - Documentation")
    XCTAssertEqual(results.first?.url,
                   URL(string: "https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/"))
    XCTAssertTrue(results.first?.snippet.hasPrefix(
      "You use actors and isolation to protect against data races, as described in this chapter.") == true)
    XCTAssertTrue(results.first?.snippet.contains("If you've written concurrent code before") == true)
    // Each snippet holds only its own result's text, never a later result's title.
    XCTAssertFalse(results.first?.snippet.contains(results[1].title) == true)
    XCTAssertTrue(results.first?.snippet.hasSuffix("but you don't interact with them directly.") == true,
                  results.first?.snippet ?? "")
    XCTAssertEqual(results.map(\.position), Array(1...10))
    XCTAssertTrue(results.allSatisfy { $0.engine == .duckDuckGo && !$0.title.isEmpty })
  }

  func testDuckDuckGoParsesJapanese() {
    let results = results(DuckDuckGoEngine.parse(page("duckduckgo-results-japanese.html")))
    XCTAssertEqual(results.count, 10)
    XCTAssertEqual(results.first?.title, "東京の天気予報(1時間・今日明日・週間) - ウェザーニュース")
    XCTAssertEqual(results.first?.url, URL(string: "https://weathernews.jp/onebox/tenki/tokyo/13100/"))
  }

  func testDuckDuckGoDropsAds() {
    let results = results(DuckDuckGoEngine.parse(page("duckduckgo-ads.html")))
    XCTAssertFalse(results.contains { $0.url.absoluteString.hasPrefix("https://duckduckgo.com/y.js?") })
    XCTAssertFalse(results.contains { $0.url.host() == "ads.example" })
    XCTAssertEqual(results.map(\.url.absoluteString),
                   ["https://organic.example/a", "https://example.com/a", "https://second.example/b"])
    XCTAssertEqual(results.map(\.position), [1, 2, 3])
    XCTAssertEqual(results.first?.snippet, "An organic snippet.")
  }

  func testDuckDuckGoUnwrapsUddgLinks() {
    let html = """
      <html><body><div class="result__body">
      <h2><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Title</a></h2>
      <a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Body</a>
      </div></body></html>
      """
    let results = results(DuckDuckGoEngine.parse(page(html: html)))
    XCTAssertEqual(results.map(\.url), [URL(string: "https://example.com/a")!])
    XCTAssertEqual(results.first?.title, "Title")
    XCTAssertEqual(results.first?.snippet, "Body")
  }

  func testDuckDuckGo202IsRateLimited() {
    XCTAssertEqual(DuckDuckGoEngine.parse(page("duckduckgo-blocked.html", status: 202)), .rateLimited)
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: "", status: 429)), .rateLimited)
  }

  func testDuckDuckGoBotCheckIsBlocked() {
    XCTAssertEqual(DuckDuckGoEngine.parse(page("duckduckgo-blocked.html", status: 200)), .blocked)
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: "<html></html>", status: 403)), .blocked)
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: "<html></html>", status: 503)), .blocked)
  }

  func testDuckDuckGoNoResultsPage() {
    // Captured in CP2: one `result--no-result` item holding the `no-results` message, no link.
    XCTAssertEqual(DuckDuckGoEngine.parse(page("duckduckgo-no-results.html")), .noResults)
    // The marker alone, without the item, still reads as an empty search.
    let markerOnly = "<html><body><div class=\"results\"><span class='no-results'>No results found</span></div></body></html>"
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: markerOnly)), .noResults)
  }

  func testDuckDuckGoChangedLayoutIsUnrecognized() {
    XCTAssertEqual(DuckDuckGoEngine.parse(page("duckduckgo-changed.html")), .unrecognized)
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: "")), .unrecognized)
    // Items whose links moved are a layout change too, not an empty search.
    let linkless = SearchFixture.string("duckduckgo-results.html").replacingOccurrences(of: "result__snippet", with: "x")
      .replacingOccurrences(of: "<a class=\"x\"", with: "<span class=\"x\"")
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: linkless)), .unrecognized)
  }

  func testDuckDuckGoPageOfAdsIsNoResults() {
    let html = """
      <html><body><div class="result result--ad"><div class="result__body">
      <h2><a href="https://duckduckgo.com/y.js?ad=1">Ad</a></h2><a href="https://duckduckgo.com/y.js?ad=1">Buy</a>
      </div></div></body></html>
      """
    XCTAssertEqual(DuckDuckGoEngine.parse(page(html: html)), .noResults)
  }

  /// A status that says the request itself is wrong (a moved endpoint, a rejected form) means the
  /// port needs updating; a server error or a too-long query doesn't (D47).
  func testDuckDuckGoUnexpectedStatuses() {
    for status in [301, 302, 303, 307, 308, 400, 404, 405, 410] {
      XCTAssertEqual(DuckDuckGoEngine.parse(page(html: "", status: status)), .unrecognized, "\(status)")
    }
    for status in [413, 414, 500, 502, 504] {
      XCTAssertEqual(DuckDuckGoEngine.parse(page("duckduckgo-results.html", status: status)), .failed, "\(status)")
    }
  }

  func testDuckDuckGoUsesTheClient() async {
    let client = FakeSearchHTTPClient()
    client.stub(ddgURL, .response(status: 200, body: SearchFixture.data("duckduckgo-results.html")))
    let outcome = await DuckDuckGoEngine().search(EngineQuery(text: "swift actors", region: usEnglish, recency: nil),
                                                  using: client)
    XCTAssertEqual(results(outcome).count, 10)
    XCTAssertEqual(client.maximumBytes, [2_097_152])
    XCTAssertEqual(DuckDuckGoEngine().weight, 1.0)

    let failing = FakeSearchHTTPClient()
    let failed = await DuckDuckGoEngine().search(EngineQuery(text: "x", region: usEnglish, recency: nil), using: failing)
    XCTAssertEqual(failed, .failed)
  }

  /// Text is joined as ddgs joins it: every text node, whitespace collapsed, NFC, no control or
  /// format characters. Escaped markup stays as text.
  func testSERPDocumentTextJoinsLikeDDGS() throws {
    let html = "<html><body><div class=\"x\"><p>Async\u{200B}Stream&lt;Element&gt;\n\n  is <b>e\u{0301}nough</b></p></div></body></html>"
    let document = try XCTUnwrap(SERPDocument(html: Data(html.utf8)))
    let item = try XCTUnwrap(document.nodes("//div[contains(@class, 'x')]", in: nil).first)
    XCTAssertEqual(document.text(".//p//text()", in: item), "AsyncStream<Element> is \u{00E9}nough")
    XCTAssertNil(document.value("./a/@href", in: item))
  }

  func testSERPDocumentReadsDeclaredCharset() throws {
    let html = "<html><head><meta charset=\"iso-8859-1\"></head><body><div class=\"x\">caf\u{E9}</div></body></html>"
    let data = try XCTUnwrap(html.data(using: .isoLatin1))
    let document = try XCTUnwrap(SERPDocument(html: data))
    let item = try XCTUnwrap(document.nodes("//div", in: nil).first)
    XCTAssertEqual(document.text(".//text()", in: item), "café")
  }

  // MARK: Wikipedia

  func testWikipediaSearchRequest() throws {
    let request = WikipediaSearch.searchRequest(for: "alan turing", language: "fr")
    let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "fr.wikipedia.org")
    XCTAssertEqual(components.path, "/w/api.php")
    XCTAssertEqual(components.queryItems?.map(\.name), ["action", "list", "srsearch", "srlimit", "format"])
    XCTAssertEqual(components.queryItems?.map { $0.value ?? "" }, ["query", "search", "alan turing", "3", "json"])
    XCTAssertEqual(request.httpMethod, "GET")
    let agent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
    XCTAssertNotNil(agent.range(of: #"^Enigma/[0-9.]+ \(https://github\.com/leow427/Enigma\)$"#, options: .regularExpression),
                    agent)
    XCTAssertEqual(WikipediaSearch.userAgent, agent)

    // `+` and `&` survive as data, and non-Latin text is percent-encoded UTF-8.
    let symbols = WikipediaSearch.searchRequest(for: "c++ & 東京", language: "en")
    XCTAssertTrue(symbols.url?.absoluteString.contains("srsearch=c%2B%2B%20%26%20%E6%9D%B1%E4%BA%AC&") == true,
                  symbols.url?.absoluteString ?? "")
  }

  func testWikipediaExtractRequest() throws {
    let request = WikipediaSearch.extractRequest(title: "Alan Turing", language: "en")
    let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(components.host, "en.wikipedia.org")
    XCTAssertEqual(components.path, "/w/api.php")
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(items, ["action": "query", "prop": "extracts", "explaintext": "1", "exsectionformat": "plain",
                           "redirects": "1", "titles": "Alan Turing", "format": "json"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WikipediaSearch.userAgent)
  }

  private func stubWikipedia(_ client: FakeSearchHTTPClient, query: String, search: Data,
                             extracts: [String: Data], language: String = "en") {
    client.stub(WikipediaSearch.searchRequest(for: query, language: language).url!, .response(status: 200, body: search))
    for (title, body) in extracts {
      client.stub(WikipediaSearch.extractRequest(title: title, language: language).url!, .response(status: 200, body: body))
    }
  }

  private func searchJSON(_ titles: [String]) -> Data {
    let hits = titles.enumerated().map { ["ns": 0, "title": $0.element, "pageid": 100 + $0.offset] as [String: Any] }
    return try! JSONSerialization.data(withJSONObject: ["batchcomplete": "", "query": ["search": hits]])
  }

  private func extractJSON(_ title: String, _ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "batchcomplete": "", "query": ["pages": ["7": ["pageid": 7, "ns": 0, "title": title, "extract": text]]],
    ])
  }

  func testWikipediaReturnsTopArticle() async {
    let client = FakeSearchHTTPClient()
    stubWikipedia(client, query: "synthetic topic", search: SearchFixture.data("wikipedia-search.json"),
                  extracts: ["Synthetic Topic": SearchFixture.data("wikipedia-extract.json")])
    let outcome = await WikipediaSearch().lookup("synthetic topic", preferredLanguages: ["en-US"], using: client)
    guard case .article(let article) = outcome else { return XCTFail("Expected an article, got \(outcome)") }
    XCTAssertEqual(article.title, "Synthetic Topic")
    XCTAssertEqual(article.url, URL(string: "https://en.wikipedia.org/wiki/Synthetic_Topic"))
    XCTAssertTrue(article.text.hasPrefix("Synthetic Topic is a made-up article"))
    XCTAssertEqual(client.requests.count, 2)
  }

  func testWikipediaSkipsDisambiguation() async {
    let client = FakeSearchHTTPClient()
    stubWikipedia(client, query: "mercury", search: searchJSON(["Mercury", "Mercury (planet)", "Mercury (element)"]),
                  extracts: ["Mercury": extractJSON("Mercury", "Mercury may refer to:\nMercury (planet)\n"),
                             "Mercury (planet)": extractJSON("Mercury (planet)", "Mercury is the first planet.")])
    let outcome = await WikipediaSearch().lookup("mercury", preferredLanguages: ["en"], using: client)
    guard case .article(let article) = outcome else { return XCTFail("Expected an article, got \(outcome)") }
    XCTAssertEqual(article.title, "Mercury (planet)")
    XCTAssertEqual(article.url, URL(string: "https://en.wikipedia.org/wiki/Mercury_(planet)"))

    let onlyDisambiguation = FakeSearchHTTPClient()
    stubWikipedia(onlyDisambiguation, query: "mercury", search: searchJSON(["Mercury"]),
                  extracts: ["Mercury": extractJSON("Mercury", "Mercury may refer to:\nMercury (planet)\n")])
    let none = await WikipediaSearch().lookup("mercury", preferredLanguages: ["en"], using: onlyDisambiguation)
    XCTAssertEqual(none, WikipediaOutcome.none)
  }

  func testWikipediaCapsText() async {
    let client = FakeSearchHTTPClient()
    stubWikipedia(client, query: "long", search: searchJSON(["Long"]),
                  extracts: ["Long": extractJSON("Long", String(repeating: "a", count: 35_000))])
    let outcome = await WikipediaSearch().lookup("long", preferredLanguages: ["en"], using: client)
    guard case .article(let article) = outcome else { return XCTFail("Expected an article, got \(outcome)") }
    XCTAssertEqual(article.text.count, 30_000)
  }

  func testWikipediaLanguage() {
    XCTAssertEqual(WikipediaSearch.language(for: ["fr-CA"]), "fr")
    XCTAssertEqual(WikipediaSearch.language(for: ["xx-YY"]), "en")
    XCTAssertEqual(WikipediaSearch.language(for: ["zh-Hant-TW"]), "zh")
    XCTAssertEqual(WikipediaSearch.language(for: ["nb-NO"]), "no")
    XCTAssertEqual(WikipediaSearch.language(for: []), "en")
  }

  func testWikipediaUsesPreferredEdition() async {
    let client = FakeSearchHTTPClient()
    stubWikipedia(client, query: "tokyo", search: searchJSON(["Tokyo"]),
                  extracts: ["Tokyo": extractJSON("Tokyo", "Tokyo est la capitale du Japon.")], language: "fr")
    let outcome = await WikipediaSearch().lookup("tokyo", preferredLanguages: ["fr-FR"], using: client)
    guard case .article(let article) = outcome else { return XCTFail("Expected an article, got \(outcome)") }
    XCTAssertEqual(article.url.host(), "fr.wikipedia.org")
  }

  func testWikipediaNoHitsIsNone() async {
    let client = FakeSearchHTTPClient()
    stubWikipedia(client, query: "qzxv", search: searchJSON([]), extracts: [:])
    let outcome = await WikipediaSearch().lookup("qzxv", preferredLanguages: ["en"], using: client)
    XCTAssertEqual(outcome, WikipediaOutcome.none)
  }

  func testWikipediaErrorsFail() async {
    let unreachable = FakeSearchHTTPClient()
    let failed = await WikipediaSearch().lookup("x", preferredLanguages: ["en"], using: unreachable)
    XCTAssertEqual(failed, .failed)

    let status = FakeSearchHTTPClient()
    status.stub(WikipediaSearch.searchRequest(for: "x", language: "en").url!, .response(status: 429, body: Data()))
    let limited = await WikipediaSearch().lookup("x", preferredLanguages: ["en"], using: status)
    XCTAssertEqual(limited, .failed)

    let garbage = FakeSearchHTTPClient()
    garbage.stub(WikipediaSearch.searchRequest(for: "x", language: "en").url!,
                 .response(status: 200, body: Data("<html>".utf8)))
    let invalid = await WikipediaSearch().lookup("x", preferredLanguages: ["en"], using: garbage)
    XCTAssertEqual(invalid, .failed)
  }

  // MARK: Health and pacing

  func testCooldownLadder() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    XCTAssertEqual(EngineHealth.cooldownSteps, [.seconds(60), .seconds(300), .seconds(900), .seconds(3600)])
    for expected in [60, 300, 900, 3_600, 3_600] {
      await health.recordFailure(.duckDuckGo)
      time.advance(.seconds(expected) - .milliseconds(1))
      let coolingBefore = await health.isCoolingDown(.duckDuckGo)
      XCTAssertTrue(coolingBefore, "still cooling down just before \(expected) s")
      time.advance(.milliseconds(1))
      let coolingAfter = await health.isCoolingDown(.duckDuckGo)
      XCTAssertFalse(coolingAfter, "cooldown ends at \(expected) s")
    }
  }

  func testSuccessResetsLadder() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordFailure(.duckDuckGo)
    time.advance(.seconds(60))
    await health.recordFailure(.duckDuckGo)
    time.advance(.seconds(300))
    await health.recordSuccess(.duckDuckGo)
    await health.recordFailure(.duckDuckGo)
    time.advance(.seconds(60))
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling, "the ladder restarts at 60 s after a success")
  }

  func testFailureWhileCoolingDownDoesNotClimb() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordFailure(.duckDuckGo)
    await health.recordFailure(.duckDuckGo)
    time.advance(.seconds(60))
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
    await health.recordFailure(.duckDuckGo)
    time.advance(.seconds(299))
    let second = await health.isCoolingDown(.duckDuckGo)
    XCTAssertTrue(second, "the next failure is the 300 s step, not 900 s")
    time.advance(.seconds(1))
    let ended = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(ended)
  }

  func testOneRateLimitDoesNotCoolDown() async {
    let health = EngineHealth()
    await health.recordRateLimited(.duckDuckGo, query: 1)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  /// Two different challenged queries in a row are a block sign for the site (D45).
  func testTwoRateLimitsInARowCoolDown() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordRateLimited(.duckDuckGo, query: 1)
    await health.recordRateLimited(.duckDuckGo, query: 2)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertTrue(cooling)
    time.advance(.seconds(60))
    let ended = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(ended, "the ladder's first step, 60 s")
  }

  /// The challenged query alone sits out the first ladder step; other queries don't.
  func testChallengedQuerySitsOutAMinute() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordRateLimited(.duckDuckGo, query: 1)
    let same = await health.isSkipped(.duckDuckGo, query: 1)
    let other = await health.isSkipped(.duckDuckGo, query: 2)
    XCTAssertTrue(same)
    XCTAssertFalse(other)
    time.advance(.seconds(59))
    let stillSkipped = await health.isSkipped(.duckDuckGo, query: 1)
    XCTAssertTrue(stillSkipped)
    time.advance(.seconds(1))
    let released = await health.isSkipped(.duckDuckGo, query: 1)
    XCTAssertFalse(released)
    // The same query challenged again after its minute doesn't climb the ladder.
    await health.recordRateLimited(.duckDuckGo, query: 1)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  func testSuccessClearsRateLimitStrike() async {
    let health = EngineHealth()
    await health.recordRateLimited(.duckDuckGo, query: 1)
    await health.recordSuccess(.duckDuckGo)
    let skipped = await health.isSkipped(.duckDuckGo, query: 1)
    XCTAssertFalse(skipped, "a success clears the per-query skip")
    await health.recordRateLimited(.duckDuckGo, query: 2)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  /// A different query's challenge turns the strike into a cooldown and clears it, so after the
  /// cooldown one more challenge is only a new strike.
  func testDifferentQueryChallengeClearsTheStrike() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordRateLimited(.duckDuckGo, query: 1)
    await health.recordRateLimited(.duckDuckGo, query: 2)
    time.advance(.seconds(60))
    await health.recordRateLimited(.duckDuckGo, query: 3)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  func testPacingDelayIsAtMostOneSecond() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let first = await health.pacingDelay(.duckDuckGo)
    XCTAssertEqual(first, .zero)
    let booked = await health.reservePacingSlot(.duckDuckGo)
    XCTAssertEqual(booked, .zero)
    let right = await health.pacingDelay(.duckDuckGo)
    XCTAssertEqual(right, .seconds(1))
    time.advance(.milliseconds(400))
    let later = await health.pacingDelay(.duckDuckGo)
    XCTAssertEqual(later, .milliseconds(600))
    time.advance(.seconds(5))
    let idle = await health.pacingDelay(.duckDuckGo)
    XCTAssertEqual(idle, .zero)
  }

  func testReservedSlotsQueueOneSecondApart() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let first = await health.reservePacingSlot(.duckDuckGo)
    let second = await health.reservePacingSlot(.duckDuckGo)
    XCTAssertEqual(first, .zero)
    XCTAssertEqual(second, .seconds(1))
  }
}

/// A settable `ContinuousClock.Instant` for `EngineHealth`.
final class TestInstant: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  var now: ContinuousClock.Instant { lock.withLock { instant } }
  func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
