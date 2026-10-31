import XCTest
@testable import Enigma

/// Wikidata's facts and Google News's headlines (F29 CP7, D109, D110): requests, parsers and
/// excerpts, from sanitized fixtures. No network.
final class SearchFactsAndNewsTests: XCTestCase {
  private func json(_ name: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: SearchFixture.data(name)) as? [String: Any])
  }

  private static func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }

  // MARK: Wikidata requests

  func testWikidataRequestsSendOnlyTheEntityOverHTTPS() {
    let request = WikidataFacts.searchRequest(entity: "Rust", language: "en")
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "www.wikidata.org")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(Self.query(request), ["action": "wbsearchentities", "search": "Rust", "language": "en",
                                         "uselang": "en", "type": "item", "limit": "1", "format": "json"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WikipediaSearch.userAgent)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(Self.query(WikidataFacts.sitelinkRequest(title: "Rust (programming language)", language: "de")),
                   ["action": "wbgetentities", "sites": "dewiki", "titles": "Rust (programming language)",
                    "props": "info", "format": "json"])
    XCTAssertEqual(Self.query(WikidataFacts.entityRequest(id: "Q575650", language: "de"))["languages"], "de|en")
  }

  // MARK: Wikidata parsing

  func testSearchAndSitelinkParsing() throws {
    XCTAssertEqual(WikidataFacts.parseSearch(try json("wikidata-search.json")), "Q575650")
    XCTAssertNil(WikidataFacts.parseSearch(["search": [] as [Any]]))
    XCTAssertNil(WikidataFacts.parseSearch(["search": [["id": "P31"]]]), "Only items")
    XCTAssertEqual(WikidataFacts.parseSitelink(["entities": ["Q575650": ["id": "Q575650"]]]), "Q575650")
    XCTAssertNil(WikidataFacts.parseSitelink(["entities": ["-1": ["missing": ""]]]))
  }

  private func facts(_ fixture: String, id: String) throws -> WikidataEntityFacts {
    let entity = try XCTUnwrap(WikidataFacts.parseEntity(try json(fixture), id: id))
    let labels = WikidataFacts.parseLabels(try json("wikidata-labels.json"), language: "en")
    return try XCTUnwrap(WikidataFacts.facts(entity, labels: labels, language: "en"))
  }

  func testSoftwareVersionsNewestFirstWithTypeDateAndCurrent() throws {
    let rust = try facts("wikidata-entity-rust.json", id: "Q575650")
    XCTAssertEqual(rust.label, "Rust")
    XCTAssertEqual(rust.url.absoluteString, "https://www.wikidata.org/wiki/Q575650")
    let versions = try XCTUnwrap(rust.facts.first { $0.property == "software version" })
    XCTAssertEqual(versions.values, [
      "1.99.1 (stable version; 2026-10-15; current)",
      "1.99.0 (stable version; 2026-10-01)",
      "1.98.1 (stable version; 2026-09-03)",
    ])
    XCTAssertEqual(rust.facts.first?.property, "software version", "Whitelist order")
    XCTAssertEqual(rust.facts.first { $0.property == "inception" }?.values.first, "2006-07-23")
  }

  func testWinnersNewestFirstCappedAtFive() throws {
    let nobel = try facts("wikidata-entity-nobel.json", id: "Q37922")
    let winners = try XCTUnwrap(nobel.facts.first { $0.property == "winner" })
    XCTAssertEqual(winners.values.count, WikidataFacts.winnerValues)
    XCTAssertEqual(winners.values.first, "Anne Carson (2026)")
    XCTAssertEqual(winners.values.last, "Annie Ernaux (2022)")
  }

  func testDeprecatedValuesDropAndThePreferredOneAlwaysShows() throws {
    let everest = try facts("wikidata-entity-everest.json", id: "Q513")
    let elevation = try XCTUnwrap(everest.facts.first { $0.property == "elevation" })
    XCTAssertEqual(elevation.values.count, WikidataFacts.valuesPerProperty)
    XCTAssertFalse(elevation.values.contains { $0.contains("29,030") }, "The deprecated value in feet")
    XCTAssertTrue(elevation.values.contains("8,848.86 metre (current)"))
  }

  func testNumberAndDateFormatting() {
    XCTAssertEqual(WikidataFacts.formatAmount("+123802000"), "123,802,000")
    XCTAssertEqual(WikidataFacts.formatAmount("+8848.86"), "8,848.86")
    XCTAssertEqual(WikidataFacts.formatAmount("-1200"), "-1,200")
    XCTAssertEqual(WikidataFacts.formatTime("+2026-10-15T00:00:00Z"), "2026-10-15")
    XCTAssertEqual(WikidataFacts.formatTime("+2026-00-00T00:00:00Z"), "2026")
    XCTAssertEqual(WikidataFacts.formatTime("+1890-11-00T00:00:00Z"), "1890-11")
    XCTAssertNil(WikidataFacts.formatTime("junk"))
  }

  func testDatePrecisionAndDatesBeforeTheCommonEra() {
    XCTAssertEqual(WikidataFacts.formatTime("+1950-01-01T00:00:00Z", precision: 9), "1950")
    XCTAssertEqual(WikidataFacts.formatTime("+1950-03-01T00:00:00Z", precision: 10), "1950-03")
    XCTAssertEqual(WikidataFacts.formatTime("+1950-03-07T00:00:00Z", precision: 11), "1950-03-07")
    XCTAssertEqual(WikidataFacts.formatTime("+1950-01-01T00:00:00Z", precision: 7), "1950", "Centuries show the year")
    typealias Statement = WikidataFacts.Statement
    func dated(_ value: String, _ time: String) -> Statement {
      Statement(value: .text(value), rank: "normal", qualifiers: ["P585": [.time(time, precision: 9)]])
    }
    let shown = WikidataFacts.shown([dated("older", "-0500-01-01T00:00:00Z"), dated("newer", "-0044-01-01T00:00:00Z"),
                                     dated("common era", "+0010-01-01T00:00:00Z")], property: "P1082")
    XCTAssertEqual(shown.map(\.value), [.text("common era"), .text("newer"), .text("older")])
  }

  func testDeprecatedValuesNeverTakeAPlaceInTheCap() {
    typealias Statement = WikidataFacts.Statement
    func dated(_ value: String, _ time: String, rank: String = "normal") -> Statement {
      Statement(value: .text(value), rank: rank, qualifiers: ["P577": [.time(time, precision: 11)]])
    }
    let shown = WikidataFacts.shown([dated("1.0", "+2024-01-01T00:00:00Z"), dated("1.1", "+2025-01-01T00:00:00Z"),
                                     dated("1.2", "+2025-06-01T00:00:00Z"),
                                     dated("9.9", "+2026-01-01T00:00:00Z", rank: "deprecated")], property: "P348")
    XCTAssertEqual(shown.map(\.value), [.text("1.2"), .text("1.1"), .text("1.0")])
  }

  func testEntityWithoutWhitelistedFactsGivesNothing() {
    let entity = WikidataFacts.Entity(id: "Q1", labels: ["en": "Thing"], descriptions: [:], claims: [:])
    XCTAssertNil(WikidataFacts.facts(entity, labels: [:], language: "en"))
  }

  func testLookupSearchesTheEntityThenClaimsThenLabels() async throws {
    let client = FakeSearchHTTPClient()
    client.stub(WikidataFacts.searchRequest(entity: "Rust", language: "en").url!,
                .response(status: 200, body: SearchFixture.data("wikidata-search.json")))
    client.stub(WikidataFacts.entityRequest(id: "Q575650", language: "en").url!,
                .response(status: 200, body: SearchFixture.data("wikidata-entity-rust.json")))
    client.stub(where: { Self.query($0)["props"] == "labels" },
                .response(status: 200, body: SearchFixture.data("wikidata-labels.json")))
    let found = await WikidataFacts().lookup(entity: "Rust", wikipediaTitle: nil, preferredLanguages: ["en-US"],
                                             using: client)
    XCTAssertEqual(found?.facts.first?.values.first, "1.99.1 (stable version; 2026-10-15; current)")
    XCTAssertEqual(client.requests.count, 3)
    XCTAssertTrue(client.requests.allSatisfy { $0.url?.host == "www.wikidata.org" && $0.url?.scheme == "https" })
    XCTAssertEqual(Self.query(client.requests[2])["ids"], "Q2804309", "Only the labels the facts need")
  }

  func testLookupFallsBackToTheWikipediaTitle() async throws {
    let client = FakeSearchHTTPClient()
    let sitelink = try JSONSerialization.data(withJSONObject: ["entities": ["Q575650": ["id": "Q575650"]]])
    client.stub(WikidataFacts.sitelinkRequest(title: "Rust (programming language)", language: "en").url!,
                .response(status: 200, body: sitelink))
    client.stub(WikidataFacts.entityRequest(id: "Q575650", language: "en").url!,
                .response(status: 200, body: SearchFixture.data("wikidata-entity-rust.json")))
    let found = await WikidataFacts().lookup(entity: nil, wikipediaTitle: "Rust (programming language)",
                                             preferredLanguages: ["en"], using: client)
    XCTAssertEqual(found?.label, "Rust")
    // The labels call failed: the version type, an item, is left out; plain values stay.
    XCTAssertEqual(found?.facts.first { $0.property == "software version" }?.values.first,
                   "1.99.1 (2026-10-15; current)")
  }

  func testAWikipediaStyleEntityUsesItsSitelinkFirst() async throws {
    let client = FakeSearchHTTPClient()
    let sitelink = try JSONSerialization.data(withJSONObject: ["entities": ["Q17118377": ["id": "Q17118377"]]])
    client.stub(WikidataFacts.sitelinkRequest(title: "Swift (programming language)", language: "en").url!,
                .response(status: 200, body: sitelink))
    _ = await WikidataFacts().lookup(entity: "Swift (programming language)", wikipediaTitle: nil,
                                     preferredLanguages: ["en"], using: client)
    XCTAssertEqual(Self.query(client.requests[0])["titles"], "Swift (programming language)")
    XCTAssertEqual(Self.query(client.requests[1])["ids"], "Q17118377")
    XCTAssertEqual(WikidataFacts.withoutQualifier("Swift (programming language)"), "Swift")
    XCTAssertEqual(WikidataFacts.withoutQualifier("Japan"), "Japan")
  }

  func testLookupFailureGivesNothing() async {
    let client = FakeSearchHTTPClient()
    let found = await WikidataFacts().lookup(entity: "Rust", wikipediaTitle: nil, preferredLanguages: ["en"], using: client)
    XCTAssertNil(found)
  }

  func testFactsExcerpt() throws {
    let excerpt = WikidataFacts.excerpt(try facts("wikidata-entity-rust.json", id: "Q575650"))
    XCTAssertEqual(excerpt.kind, .facts)
    XCTAssertEqual(excerpt.site, "Wikidata")
    XCTAssertEqual(excerpt.source.title, "Rust — Wikidata")
    let text = try XCTUnwrap(excerpt.snippets.first)
    XCTAssertTrue(text.hasPrefix("Wikidata facts for Rust (memory-safe programming language"))
    XCTAssertTrue(text.contains("- software version: 1.99.1 (stable version; 2026-10-15; current); 1.99.0"))
  }

  // MARK: Google News

  func testNewsTriggerIsRecencyOrANewsCue() {
    XCTAssertTrue(GoogleNewsSearch.applies(question: "latest news on the strike", recency: .week))
    XCTAssertTrue(GoogleNewsSearch.applies(question: "what happened today", recency: .day))
    XCTAssertTrue(GoogleNewsSearch.applies(question: "events this month", recency: .month))
    XCTAssertTrue(GoogleNewsSearch.applies(question: "Who won the Nobel Prize in Literature?", recency: nil))
    XCTAssertTrue(GoogleNewsSearch.applies(question: "election results ohio", recency: nil))
    XCTAssertFalse(GoogleNewsSearch.applies(question: "how tall is mount everest", recency: nil))
    XCTAssertFalse(GoogleNewsSearch.applies(question: "best laptops 2026", recency: .year))
  }

  func testNewsRequestSendsOnlyTheQueryLanguageAndRegion() {
    let request = GoogleNewsSearch.request(query: "nobel prize literature", region: SearchRegion(country: "us", language: "en"))
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "news.google.com")
    XCTAssertEqual(request.url?.path, "/rss/search")
    XCTAssertEqual(Self.query(request), ["q": "nobel prize literature", "hl": "en-US", "gl": "US", "ceid": "US:en"])
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WikipediaSearch.userAgent)
    XCTAssertEqual(GoogleNewsSearch.request(query: "a&b=c", region: SearchRegion(country: "de", language: "de")).url?.query,
                   "q=a%26b%3Dc&hl=de-DE&gl=DE&ceid=DE%3Ade")
  }

  func testNewsFeedParsesNewestFirstWithPublisherAndDate() throws {
    let headlines = try XCTUnwrap(GoogleNewsSearch.parse(SearchFixture.data("google-news.xml")))
    XCTAssertEqual(headlines.count, 4)
    XCTAssertEqual(headlines.first?.publisher, "Global Comment")
    XCTAssertFalse(headlines.contains { $0.title.hasSuffix(" - The Guardian") }, "The publisher suffix is dropped")
    let guardian = try XCTUnwrap(headlines.first { $0.publisher == "The Guardian" })
    XCTAssertEqual(guardian.title, "Anne Carson wins Nobel prize in literature 2026")
    XCTAssertEqual(guardian.published, Date(timeIntervalSince1970: 1_791_442_800))
    XCTAssertNil(GoogleNewsSearch.parse(Data("<html><body>Sorry</body></html>".utf8)))
    XCTAssertEqual(GoogleNewsSearch.parse(Data("<rss><channel></channel></rss>".utf8)), [])
  }

  func testNewsExcerptHoldsHeadlinesAndNeverAnArticleLink() throws {
    let headlines = try XCTUnwrap(GoogleNewsSearch.parse(SearchFixture.data("google-news.xml")))
    XCTAssertEqual(headlines.first?.publisherURL, URL(string: "https://globalcomment.com"))
    let excerpt = GoogleNewsSearch.excerpt(headlines)
    XCTAssertEqual(excerpt.kind, .news)
    XCTAssertEqual(excerpt.site, "Google News")
    XCTAssertEqual(excerpt.source.title, "Google News headlines")
    // Google News's home page: a click never sends the query, and blocking it blocks Google News (D122, D125).
    XCTAssertEqual(excerpt.source.url.absoluteString, "https://news.google.com/")
    let text = try XCTUnwrap(excerpt.snippets.first)
    XCTAssertTrue(text.contains("- Anne Carson wins Nobel prize in literature 2026 — The Guardian, 2026-10-08"))
    XCTAssertFalse(text.contains("CBMi"), "No article token")
    XCTAssertEqual(excerpt.published, headlines.first?.published)
  }

  func testNewsExcerptWithoutAPublisherLinksToGoogleNewsWithoutTheQuery() {
    let plain = NewsHeadline(title: "A headline", publisher: nil, published: nil)
    XCTAssertEqual(GoogleNewsSearch.excerpt([plain]).source.url.absoluteString, "https://news.google.com/")
    let feed = Data(("<rss><channel><item><title>T - P</title><source url=\"javascript:alert(1)\">P</source>"
      + "</item></channel></rss>").utf8)
    let parsed = GoogleNewsSearch.parse(feed)
    XCTAssertNil(parsed?.first?.publisherURL, "Only http(s) publisher links")
    XCTAssertEqual(parsed.map { GoogleNewsSearch.excerpt($0).source.url.absoluteString }, "https://news.google.com/")
  }

  func testNewsSearchFailureGivesNil() async {
    let client = FakeSearchHTTPClient()
    client.stub(where: { $0.url?.host == "news.google.com" }, .response(status: 503, body: Data()))
    let headlines = await GoogleNewsSearch().search("x", region: SearchRegion(country: "us", language: "en"), using: client)
    XCTAssertNil(headlines)
  }
}
