import XCTest
@testable import Enigma

/// `OnDeviceSearchProvider` on the web route (F29 CP5): sites, ranking, reading within the window,
/// checks, passages and the snippet fallback. Everything is faked: no network, no WebKit.
final class OnDeviceSearchTests: XCTestCase {
  static let question = "solar panel cost"
  static let now = Date(timeIntervalSince1970: 1_793_000_000)

  // MARK: Fixtures

  /// A page of distinct English prose about `topic`, so it passes the checks and doesn't
  /// near-duplicate another page.
  static func prose(_ name: String, topic: String = question, paragraphs: Int = 4) -> [ArticleBlock] {
    (0..<paragraphs).map { paragraph in
      ArticleBlock(kind: .paragraph, text: (0..<3).map { sentence in
        // The name every few words keeps each page's 5-word shingles its own.
        "Writer \(name) explains \(name) note \(paragraph * 3 + sentence) that \(name) the \(topic) \(name) changed for \(name) households across \(name) the region."
      }.joined(separator: " "))
    }
  }

  static func article(_ name: String, topic: String = question, paragraphs: Int = 4, siteName: String? = nil,
                      published: Date? = nil, modified: Date? = nil) -> ExtractedArticle {
    ExtractedArticle(title: "Article \(name)", siteName: siteName, byline: nil, language: "en", published: published,
                     modified: modified, blocks: prose(name, topic: topic, paragraphs: paragraphs), isReaderable: true)
  }

  static let wall = ExtractedArticle(title: "Subscribe", siteName: nil, byline: nil, language: "en", published: nil,
    blocks: [ArticleBlock(kind: .paragraph, text: "Subscribe to continue reading this story about solar panels.")],
    isReaderable: false)

  static func host(_ name: String) -> String { "\(name).example" }
  static func url(_ name: String) -> URL { URL(string: "https://\(host(name))/page")! }

  static func result(_ name: String, position: Int) -> EngineResult {
    EngineResult(title: "Title \(name)", url: url(name), snippet: "Snippet \(name) about solar panel cost.",
                 position: position, engine: .duckDuckGo)
  }

  /// Keeps the trace events of one search, in the order they were recorded.
  final class SearchTraceRecorder: SearchTracing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SearchTraceEvent] = []

    func record(_ event: SearchTraceEvent) {
      lock.lock()
      defer { lock.unlock() }
      recorded.append(event)
    }

    var events: [SearchTraceEvent] {
      lock.lock()
      defer { lock.unlock() }
      return recorded
    }
  }

  final class Harness: @unchecked Sendable {
    let client = FakeSearchHTTPClient()
    let clock = ManualClock()
    let extractor: FakeExtractor
    let engine: RecordingEngine
    var quality = SourceQualityFixture.quality()
    var resolver = FakeHostResolver()
    let activity = LockedEvents()
    var places = FakePlaces(error: URLError(.notConnectedToInternet))
    var weather = FakeWeather(error: URLError(.notConnectedToInternet))
    var geocoder = FakeGeocoder(error: URLError(.notConnectedToInternet))

    /// `pages` in search order: each is read, then extracted with its behavior.
    init(_ pages: [(name: String, behavior: FakeExtractor.Behavior)], engineOutcome: EngineOutcome? = nil) {
      extractor = FakeExtractor(Dictionary(uniqueKeysWithValues: pages.map { (OnDeviceSearchTests.host($0.name), $0.behavior) }))
      let results = pages.enumerated().map { OnDeviceSearchTests.result($0.element.name, position: $0.offset + 1) }
      engine = RecordingEngine(engineOutcome ?? (results.isEmpty ? .noResults : .results(results)))
      for page in pages {
        let host = OnDeviceSearchTests.host(page.name)
        client.stub(where: { $0.url?.host == host }, .response(status: 200, headers: ["Content-Type": "text/html"],
                                                               body: Data("<html><body>\(page.name)</body></html>".utf8)))
      }
    }

    func provider(trace: (any SearchTracing)? = nil) -> OnDeviceSearchProvider {
      let quality = self.quality
      let sites = SearchSiteRunner(engines: [.duckDuckGo: engine], wikipedia: WikipediaSearch(), client: client,
                                   health: EngineHealth(), log: RecordingSearchLog())
      let reader = PageReader(client: client, networkGuard: NetworkGuard(resolver: resolver),
                              isBlocked: { quality.isBlocked($0) })
      return OnDeviceSearchProvider(sites: sites, reader: reader, extractor: extractor, quality: { quality },
                                    preferredLanguages: { ["en-US"] }, clock: clock, now: { OnDeviceSearchTests.now },
                                    places: places, weather: weather, geocoder: geocoder, units: { .us }, trace: trace)
    }

    func search(_ query: String = OnDeviceSearchTests.question, route: SearchRoute = .web, recency: SearchRecency? = nil,
                city: String? = nil, coordinate: SearchCoordinate? = nil, namedPlace: String? = nil,
                maximumTokens: Int = WebSearchLimits.evidenceTokens) async throws -> [WebSearchResult] {
      let request = WebSearchRequest(query: query, route: route, city: city, coordinate: coordinate, namedPlace: namedPlace,
                                     recency: recency, maximumTokens: maximumTokens)
      let events = activity
      return try await provider().search(request) { events.append($0) }
    }

    func stubWikipedia(title: String, text: String, query: String = OnDeviceSearchTests.question) {
      let search = WikipediaSearch.searchRequest(for: query, language: "en").url!
      let extract = WikipediaSearch.extractRequest(title: title, language: "en").url!
      let searchBody = try! JSONSerialization.data(withJSONObject: ["query": ["search": [["title": title]]]])
      let extractBody = try! JSONSerialization.data(withJSONObject:
        ["query": ["pages": ["1": ["title": title, "extract": text]]]])
      client.stub(search, .response(status: 200, body: searchBody))
      client.stub(extract, .response(status: 200, body: extractBody))
    }
  }

  /// The verdict of every candidate the ranking saw (F29 CP7). A wall page's verdict is "wall"
  /// even when its snippet is used, and a blocked site is never read.
  func testTraceRecordsVerdicts() async throws {
    let recorder = SearchTraceRecorder()
    let harness = Harness([("read", .article(Self.article("read"))), ("wall", .article(Self.wall)),
                           ("blocked", .article(Self.article("blocked")))])
    harness.quality = SourceQualityFixture.quality(userBlocked: [Self.host("blocked")])
    let request = WebSearchRequest(query: OnDeviceSearchTests.question, route: .web,
                                   maximumTokens: WebSearchLimits.evidenceTokens)
    _ = try await harness.provider(trace: recorder).search(request)
    let verdicts = Dictionary(uniqueKeysWithValues: recorder.events.map { ($0.domain, $0.verdict) })
    XCTAssertEqual(verdicts[Self.host("read")], "read")
    XCTAssertEqual(verdicts[Self.host("wall")], "wall")
    XCTAssertEqual(verdicts[Self.host("blocked")], "blocked")
    XCTAssertEqual(recorder.events.first { $0.domain == Self.host("read") }?.positions, ["duckDuckGo": 1])
  }

  private func names(_ results: [WebSearchResult]) -> [String] {
    results.map { $0.source.url.host()?.replacingOccurrences(of: ".example", with: "") ?? "" }
  }

  // MARK: The pipeline

  func testPipelineReturnsReadPagesBestFirst() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))), ("beta", .article(Self.article("beta"))),
                           ("gamma", .article(Self.article("gamma")))])
    let results = try await harness.search()
    XCTAssertEqual(names(results), ["alpha", "beta", "gamma"])
    XCTAssertEqual(results.map(\.kind), [.article, .article, .article])
    for result in results {
      XCTAssertEqual(result.snippets.count, 1, "One string of passages")
    }
    XCTAssertTrue(results[0].snippets[0].contains("Writer alpha explains alpha note"))
    XCTAssertEqual(results[0].source.title, "Article alpha")
    XCTAssertEqual(harness.extractor.warmUps, 1, "The web view warms up when a search starts")
  }

  func testResultsCarrySiteDateKind() async throws {
    let published = Self.now.addingTimeInterval(-86_400)
    let harness = Harness([("alpha", .article(Self.article("alpha", siteName: "Alpha News", published: published))),
                           ("beta", .article(Self.article("beta"))), ("gamma", .article(Self.article("gamma")))])
    let results = try await harness.search()
    let alpha = try XCTUnwrap(results.first { $0.source.url == Self.url("alpha") })
    XCTAssertEqual(alpha.site, "Alpha News")
    XCTAssertEqual(alpha.published, published)
    XCTAssertEqual(alpha.kind, .article)
    let beta = try XCTUnwrap(results.first { $0.source.url == Self.url("beta") })
    XCTAssertEqual(beta.site, "beta.example", "The registrable domain without a site name")
    XCTAssertNil(beta.published)
  }

  func testEarlyStopAfterEnoughPassingPages() async throws {
    let names = ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8"]
    let harness = Harness(names.map { ($0, .article(Self.article($0))) })
    let results = try await harness.search()
    XCTAssertEqual(results.count, OnDeviceSearchTiming.earlyStopPages)
    // Passing pages never start another read: only the first batch was requested.
    let requested = Set(harness.client.requests.compactMap { $0.url?.host() })
    XCTAssertFalse(requested.contains(Self.host("a7")))
    XCTAssertFalse(requested.contains(Self.host("a8")))
  }

  func testFailedPageIsReplacedFromQueue() async throws {
    let names = ["b1", "b2", "b3", "b4", "b5", "b6", "b7"]
    let harness = Harness(names.map { ($0, .article(Self.article($0))) })
    // Two of the first six fail, so a fifth passing page can only come from the seventh.
    harness.client.stub(where: { ["b1.example", "b2.example"].contains($0.url?.host ?? "") }, .response(status: 500, body: Data()))
    let results = try await harness.search()
    XCTAssertTrue(self.names(results).contains("b7"), "The seventh candidate replaced a failed one")
    XCTAssertFalse(self.names(results).contains("b1"))
    XCTAssertEqual(results.filter { $0.kind == .article }.count, OnDeviceSearchTiming.earlyStopPages)
  }

  func testHangingPageEndsAtWindow() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))), ("slow", .article(Self.article("slow"))),
                           ("gamma", .article(Self.article("gamma")))])
    harness.client.stub(where: { $0.url?.host == Self.host("slow") }, .hang)
    let task = Task { try await harness.search() }
    await harness.clock.waitForSleepers(1)
    for _ in 0..<5_000 where harness.extractor.finished < 2 { try await Task.sleep(for: .milliseconds(1)) }
    // The two finished pages still go through the checks before the window may end.
    try await Task.sleep(for: .milliseconds(300))
    harness.clock.advance(by: OnDeviceSearchTiming.readingWindow)
    let results = try await task.value
    XCTAssertEqual(names(results), ["alpha", "gamma"])
    XCTAssertEqual(harness.client.cancellations, 1, "The hanging download saw cancellation")
  }

  func testHangingExtractionEndsAtWindow() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))), ("slow", .hang),
                           ("gamma", .article(Self.article("gamma")))])
    let task = Task { try await harness.search() }
    await harness.clock.waitForSleepers(1)
    for _ in 0..<5_000 where harness.extractor.finished < 2 { try await Task.sleep(for: .milliseconds(1)) }
    // The two finished pages still go through the checks before the window may end.
    try await Task.sleep(for: .milliseconds(300))
    harness.clock.advance(by: OnDeviceSearchTiming.readingWindow)
    let results = try await task.value
    XCTAssertEqual(names(results), ["alpha", "gamma"])
    XCTAssertEqual(harness.extractor.cancellations, 1)
  }

  func testAllPagesFailingUseSnippets() async throws {
    let names = ["w1", "w2", "w3", "w4", "w5", "w6"]
    let harness = Harness(names.map { ($0, .article(Self.wall)) })
    let results = try await harness.search()
    XCTAssertLessThanOrEqual(results.count, OnDeviceSearchTiming.snippetFallbackSources)
    XCTAssertEqual(results.count, 4)
    XCTAssertTrue(results.allSatisfy { $0.kind == .snippet })
    XCTAssertEqual(results.first?.snippets, ["Snippet w1 about solar panel cost."])
    XCTAssertEqual(self.names(results), ["w1", "w2", "w3", "w4"])
  }

  func testExtractorUnavailableUsesSnippets() async throws {
    let harness = Harness(["u1", "u2", "u3"].map { ($0, .fail(ArticleExtractorError.unavailable)) })
    let results = try await harness.search()
    XCTAssertEqual(results.map(\.kind), [.snippet, .snippet, .snippet])
  }

  func testSnippetsFillUpToFourWithOnePassingPage() async throws {
    let harness = Harness([("ok", .article(Self.article("ok"))), ("x1", .article(Self.wall)), ("x2", .article(Self.wall)),
                           ("x3", .article(Self.wall)), ("x4", .article(Self.wall))])
    let results = try await harness.search()
    XCTAssertEqual(results.map(\.kind), [.article, .snippet, .snippet, .snippet])
    XCTAssertEqual(names(results), ["ok", "x1", "x2", "x3"])
  }

  func testRefusedPageLosesItsSnippet() async throws {
    let harness = Harness([("ok", .article(Self.article("ok"))), ("local", .article(Self.article("local"))),
                           ("wall", .article(Self.wall))])
    harness.resolver.table[Self.host("local")] = ["192.168.1.10"]
    let results = try await harness.search()
    XCTAssertFalse(names(results).contains("local"), "A refused page gives neither its text nor its snippet")
    XCTAssertEqual(names(results), ["ok", "wall"])
  }

  func testStopCancelsEverything() async throws {
    let harness = Harness([("h1", .article(Self.article("h1"))), ("h2", .article(Self.article("h2")))])
    harness.client.stub(where: { $0.url?.host?.hasPrefix("h") == true }, .hang)
    let task = Task { try await harness.search() }
    for _ in 0..<5_000 where harness.client.requests.filter({ $0.url?.host?.hasPrefix("h") == true }).count < 2 {
      try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(harness.client.cancellations, 2)
    XCTAssertEqual(harness.clock.sleeperCount, 0, "The window's timer ended too")
  }

  // MARK: Wikipedia

  func testWikipediaLaneAddedWhenRelevant() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))), ("beta", .article(Self.article("beta")))])
    let text = (0..<6).map { "Solar panel cost has fallen sharply over the decade, according to study \($0)." }
      .joined(separator: "\n")
    harness.stubWikipedia(title: "Solar panel", text: text)
    let results = try await harness.search()
    let wikipedia = try XCTUnwrap(results.first { $0.kind == .wikipedia })
    XCTAssertEqual(wikipedia.source.url.absoluteString, "https://en.wikipedia.org/wiki/Solar_panel")
    XCTAssertEqual(wikipedia.site, "Wikipedia")
    XCTAssertTrue(wikipedia.snippets[0].contains("Solar panel cost has fallen"))

    let unrelated = Harness([("alpha", .article(Self.article("alpha"))), ("beta", .article(Self.article("beta")))])
    unrelated.stubWikipedia(title: "Tennis", text: "Tennis is a racket sport played between two players.")
    let without = try await unrelated.search()
    XCTAssertFalse(without.contains { $0.kind == .wikipedia })
  }

  func testWikipediaSkippedForDayAndWeekRecency() async throws {
    for recency in [SearchRecency.day, .week] {
      let harness = Harness([("alpha", .article(Self.article("alpha", published: Self.now)))])
      harness.stubWikipedia(title: "Solar panel", text: "Solar panel cost text.")
      _ = try await harness.search(recency: recency)
      XCTAssertFalse(harness.client.requests.contains { $0.url?.host()?.hasSuffix("wikipedia.org") == true })
      XCTAssertEqual(harness.engine.queries.first?.recency, recency)
    }
    let monthly = Harness([("alpha", .article(Self.article("alpha")))])
    _ = try? await monthly.search(recency: .month)
    XCTAssertTrue(monthly.client.requests.contains { $0.url?.host()?.hasSuffix("wikipedia.org") == true })
  }

  // MARK: Failures

  func testAllSitesFailedIsUnavailable() async {
    for outcome in [EngineOutcome.failed, .blocked, .unrecognized] {
      let harness = Harness([], engineOutcome: outcome)
      do {
        _ = try await harness.search()
        XCTFail("Expected unavailable")
      } catch {
        XCTAssertEqual(error as? WebSearchError, .unavailable, "\(outcome)")
      }
    }
  }

  func testAnyRateLimitIsRateLimited() async {
    let harness = Harness([], engineOutcome: .rateLimited)
    do {
      _ = try await harness.search()
      XCTFail("Expected rateLimited")
    } catch {
      XCTAssertEqual(error as? WebSearchError, .rateLimited)
    }
  }

  func testNothingUsableIsNoResults() async {
    let empty = Harness([], engineOutcome: .noResults)
    do {
      _ = try await empty.search()
      XCTFail("Expected noResults")
    } catch {
      XCTAssertEqual(error as? WebSearchError, .noResults)
    }
    // Every result is on a blocked site.
    let blocked = Harness([("malware", .article(Self.article("malware")))])
    do {
      _ = try await blocked.search()
      XCTFail("Expected noResults")
    } catch {
      XCTAssertEqual(error as? WebSearchError, .noResults)
    }
  }

  func testSiteOutageWithUnrelatedWikipediaReportsTheOutage() async {
    for (outcome, expected) in [(EngineOutcome.rateLimited, WebSearchError.rateLimited), (.failed, .unavailable)] {
      let harness = Harness([], engineOutcome: outcome)
      harness.stubWikipedia(title: "Tennis", text: "Tennis is a racket sport played between two players.")
      do {
        _ = try await harness.search()
        XCTFail("Expected \(expected)")
      } catch {
        XCTAssertEqual(error as? WebSearchError, expected, "\(outcome)")
      }
    }
  }

  func testUserBlockedWikipediaNeverAppears() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha")))])
    harness.quality = SourceQuality(data: SourceQualityFixture.bundle(), userBlocked: ["wikipedia.org"])
    harness.stubWikipedia(title: "Solar panel", text: "Solar panel cost has fallen sharply over the decade.")
    let results = try await harness.search()
    XCTAssertFalse(results.contains { $0.kind == .wikipedia || $0.source.url.host()?.hasSuffix("wikipedia.org") == true })
    XCTAssertEqual(names(results), ["alpha"])
  }

  func testSnippetFallbackLeavesOutWrongLanguagePages() async throws {
    let french = ExtractedArticle(title: "Barrière", siteName: nil, byline: nil, language: "fr", published: nil,
      blocks: (0..<12).map { ArticleBlock(kind: .paragraph, text:
        "Le conseil municipal a voté mardi soir pour le nouveau projet de barrière contre les marées, selon le rapport numéro \($0) publié hier.") },
      isReaderable: true)
    let harness = Harness([("ok", .article(Self.article("ok"))), ("french", .article(french)), ("wall", .article(Self.wall))])
    let results = try await harness.search()
    XCTAssertEqual(names(results), ["ok", "wall"])
    XCTAssertEqual(results.map(\.kind), [.article, .snippet])
  }

  // MARK: Query, privacy and checks

  func testNearMeUsesCityNotCoordinates() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha", topic: "cafes near Chicago")))])
    _ = try? await harness.search("cafes near me", city: "Chicago",
                                  coordinate: SearchCoordinate(latitude: 41.88, longitude: -87.63))
    XCTAssertEqual(harness.engine.queries.map(\.text), ["cafes near Chicago"])
    for request in harness.client.requests {
      XCTAssertFalse(request.url?.absoluteString.contains("41.88") == true)
      XCTAssertFalse(request.url?.absoluteString.contains("87.63") == true)
    }
  }

  func testSiteQueryIsCappedAt50WordsAnd400Characters() {
    let long = (0..<80).map { "w\($0)" }.joined(separator: " ")
    XCTAssertEqual(OnDeviceSearchProvider.siteQuery(long).split(separator: " ").count, 50)
    let wide = String(repeating: "abcdefghij ", count: 45)
    let capped = OnDeviceSearchProvider.siteQuery(wide)
    XCTAssertLessThanOrEqual(capped.count, 400)
    XCTAssertFalse(capped.hasSuffix(" "))
    XCTAssertEqual(OnDeviceSearchProvider.siteQuery("  solar   panels \n cost "), "solar panels cost")
  }

  func testDuplicatePageDropped() async throws {
    // reliable.example (trust 1.15) and plain.example carry the same text; the trusted one stays.
    let copy = Self.article("same")
    let harness = Harness([("plain", .article(copy)), ("reliable", .article(copy)), ("other", .article(Self.article("other")))])
    let results = try await harness.search()
    XCTAssertTrue(names(results).contains("reliable"))
    XCTAssertFalse(names(results).contains("plain"))
    XCTAssertTrue(names(results).contains("other"))
  }

  func testOffTopicPageDropped() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))),
                           ("hose", .article(Self.article("hose", topic: "garden hose repair"))),
                           ("beta", .article(Self.article("beta"))), ("gamma", .article(Self.article("gamma")))])
    let results = try await harness.search()
    XCTAssertEqual(names(results), ["alpha", "beta", "gamma"])
  }

  func testOffTopicNeedsTwoOtherPages() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha"))),
                           ("hose", .article(Self.article("hose", topic: "garden hose repair")))])
    let results = try await harness.search()
    XCTAssertEqual(names(results), ["alpha", "hose"])
  }

  func testStalePageRanksLower() async throws {
    // alpha is first in search, reliable.example second (trust 1.15). With a week's recency,
    // alpha's month-old date halves its score, and reliable moves ahead.
    let old = Self.now.addingTimeInterval(-30 * 86_400)
    let pages: [(name: String, behavior: FakeExtractor.Behavior)] = [
      ("alpha", .article(Self.article("alpha", published: old))),
      ("reliable", .article(Self.article("reliable", published: Self.now))),
    ]
    let timeless = try await Harness(pages).search()
    XCTAssertEqual(names(timeless), ["alpha", "reliable"])
    let recent = try await Harness(pages).search(recency: .week)
    XCTAssertEqual(names(recent), ["reliable", "alpha"])
    // The modified date counts when there's no publish date (D74).
    let modified: [(name: String, behavior: FakeExtractor.Behavior)] = [
      ("alpha", .article(Self.article("alpha", modified: old))), ("reliable", .article(Self.article("reliable"))),
    ]
    let byModified = try await Harness(modified).search(recency: .week)
    XCTAssertEqual(names(byModified), ["reliable", "alpha"])
  }

  func testBudgetStopsCollectingPassages() async throws {
    let pages: [(name: String, behavior: FakeExtractor.Behavior)] = ["c1", "c2", "c3"].map {
      ($0, .article(Self.article($0, paragraphs: 40)))
    }
    let full = try await Harness(pages).search()
    let small = try await Harness(pages).search(maximumTokens: 400)
    func words(_ results: [WebSearchResult]) -> Int { results.reduce(0) { $0 + TextWords.count(in: $1.snippets.joined()) } }
    let budget = Double(400) * OnDeviceSearchTiming.collectionAllowance / OnDeviceSearchTiming.tokensPerWord
    XCTAssertLessThan(words(small), words(full))
    XCTAssertLessThanOrEqual(Double(words(small)), budget + Double(PassageRanker.targetWords))
    XCTAssertEqual(small.count, 3, "Every source keeps its best passage")
    XCTAssertTrue(small.allSatisfy { !$0.snippets[0].isEmpty })
    // Each source is capped at the per-source token limit.
    let perSource = Double(WebSearchLimits.tokensPerSource) / OnDeviceSearchTiming.tokensPerWord
    XCTAssertTrue(full.allSatisfy { Double(TextWords.count(in: $0.snippets[0])) <= perSource + Double(PassageRanker.targetWords) })
    XCTAssertTrue(full[0].snippets[0].contains("\n…\n"), "Passages are joined with an ellipsis line")
  }

  func testDiscoveredSourcesReported() async throws {
    let names = ["d1", "d2", "d3", "d4", "d5", "d6", "d7"]
    let harness = Harness(names.map { ($0, .article(Self.article($0))) })
    harness.stubWikipedia(title: "Solar panel", text: "Solar panel cost has fallen.")
    _ = try await harness.search()
    guard case .sourcesDiscovered(let sources)? = harness.activity.values.first else {
      return XCTFail("Expected discovered sources first")
    }
    XCTAssertEqual(sources.map(\.url), names.prefix(OnDeviceSearchTiming.readLimit).map(Self.url)
                   + [URL(string: "https://en.wikipedia.org/wiki/Solar_panel")!])
  }
}

// MARK: Fakes

// MARK: Places and weather (F29 CP6)

extension OnDeviceSearchTests {
  private static let chicago = PlacesAndWeatherFixtures.chicago

  private static func place(_ name: String) -> PlaceResult {
    PlaceResult(place: MapPlace(id: name, name: name, coordinate: chicago, distanceMeters: nil), category: "Cafe",
                address: nil, phone: nil, website: nil)
  }

  func testWeatherRouteSkipsWebSearch() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha")))])
    harness.weather = FakeWeather()
    let results = try await harness.search("will it rain tomorrow", route: .weather, city: "Chicago", coordinate: Self.chicago)
    XCTAssertEqual(results.map(\.kind), [.weather])
    XCTAssertEqual(results.first?.source.title, "Open-Meteo forecast")
    XCTAssertTrue(results.first?.snippets.first?.hasPrefix("Forecast for Chicago (local times).") == true)
    XCTAssertEqual(harness.weather.calls.map(\.coordinate), [Self.chicago])
    XCTAssertEqual(harness.weather.calls.map(\.units), [.us])
    XCTAssertTrue(harness.engine.queries.isEmpty)
    XCTAssertTrue(harness.client.requests.isEmpty)
    XCTAssertTrue(harness.geocoder.calls.isEmpty)
  }

  func testWeatherWithoutCityIsYourArea() async throws {
    let harness = Harness([])
    harness.weather = FakeWeather()
    let results = try await harness.search("will it rain tomorrow", route: .weather, coordinate: Self.chicago)
    XCTAssertTrue(results.first?.snippets.first?.hasPrefix("Forecast for your area (local times).") == true)
  }

  func testNamedPlaceIsGeocodedWithOpenMeteo() async throws {
    let harness = Harness([])
    harness.weather = FakeWeather()
    harness.geocoder = FakeGeocoder((PlacesAndWeatherFixtures.paris, "Paris, Île-de-France Region, France"))
    let results = try await harness.search("weather in paris this weekend", route: .weather, namedPlace: "paris")
    XCTAssertEqual(harness.geocoder.calls, ["paris"])
    XCTAssertEqual(harness.weather.calls.map(\.coordinate), [PlacesAndWeatherFixtures.paris])
    XCTAssertTrue(results.first?.snippets.first?.hasPrefix("Forecast for Paris, Île-de-France Region, France") == true)
    XCTAssertTrue(harness.places.calls.isEmpty, "Weather never asks MapKit")
  }

  func testWeatherFailureFallsBackToWeb() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha")))])
    let results = try await harness.search("will it rain tomorrow", route: .weather, city: "Chicago", coordinate: Self.chicago)
    XCTAssertEqual(harness.weather.calls.count, 1)
    XCTAssertEqual(harness.engine.queries.map(\.text), ["weather Chicago"])
    XCTAssertFalse(results.contains { $0.kind == .weather })
    XCTAssertFalse(results.isEmpty)
  }

  func testUnknownPlaceFallsBackToWeb() async throws {
    for geocoder in [FakeGeocoder(), FakeGeocoder(error: WeatherLookupError.timedOut)] {
      let harness = Harness([("alpha", .article(Self.article("alpha")))])
      harness.weather = FakeWeather()
      harness.geocoder = geocoder
      _ = try await harness.search("weather in atlantis tomorrow", route: .weather, namedPlace: "atlantis")
      XCTAssertTrue(harness.weather.calls.isEmpty)
      XCTAssertEqual(harness.engine.queries.map(\.text), ["weather atlantis"])
    }
  }

  func testPlacesRouteRunsMapsAndWeb() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha", topic: "cafes near Chicago")))])
    harness.places = FakePlaces([Self.place("Blue Bottle"), Self.place("Intelligentsia")])
    let results = try await harness.search("cafes near me", route: .places, city: "Chicago", coordinate: Self.chicago)
    XCTAssertEqual(results.first?.kind, .places)
    XCTAssertEqual(results.first?.places?.map(\.name), ["Blue Bottle", "Intelligentsia"])
    XCTAssertEqual(results.first?.source.url.absoluteString, "https://maps.apple.com/?q=cafes")
    XCTAssertTrue(results.dropFirst().contains { $0.kind == .article })
    XCTAssertEqual(harness.places.calls.map(\.query), ["cafes"])
    XCTAssertEqual(harness.places.calls.map(\.coordinate), [Self.chicago])
    XCTAssertEqual(harness.engine.queries.map(\.text), ["cafes near Chicago"])
  }

  func testNamedAreaPlacesHaveNoRegion() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha", topic: "ramen in soho")))])
    harness.places = FakePlaces([Self.place("Ramen House")])
    _ = try await harness.search("ramen in soho", route: .places)
    XCTAssertEqual(harness.places.calls.map(\.query), ["ramen in soho"])
    XCTAssertNil(harness.places.calls.first?.coordinate ?? nil)
  }

  func testPlacesFailureUsesWebOnly() async throws {
    for places in [FakePlaces(error: PlaceSearchError.timedOut), FakePlaces([])] {
      let harness = Harness([("alpha", .article(Self.article("alpha", topic: "cafes near Chicago")))])
      harness.places = places
      let results = try await harness.search("cafes near me", route: .places, city: "Chicago", coordinate: Self.chicago)
      XCTAssertFalse(results.isEmpty)
      XCTAssertFalse(results.contains { $0.kind == .places })
    }
  }

  func testPlacesSurviveAWebFailure() async throws {
    let harness = Harness([], engineOutcome: .failed)
    harness.places = FakePlaces([Self.place("Blue Bottle")])
    let results = try await harness.search("cafes near me", route: .places, city: "Chicago", coordinate: Self.chicago)
    XCTAssertEqual(results.map(\.kind), [.places])
  }

  func testPlacesWithoutCityStillSearchMaps() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha", topic: "cafes")))])
    harness.places = FakePlaces([Self.place("Blue Bottle")])
    _ = try? await harness.search("cafes near me", route: .places, coordinate: Self.chicago)
    XCTAssertEqual(harness.places.calls.map(\.query), ["cafes"])
    XCTAssertEqual(harness.places.calls.map(\.coordinate), [Self.chicago])
    // No "near current area" for the search sites: the cue is dropped.
    XCTAssertEqual(harness.engine.queries.map(\.text), ["cafes"])
    for request in harness.client.requests {
      XCTAssertFalse(request.url?.absoluteString.contains("41.88") == true)
    }
  }

  func testWeatherTimeoutFallsBackToWeb() async throws {
    let harness = Harness([("alpha", .article(Self.article("alpha")))])
    harness.weather = FakeWeather(error: WeatherLookupError.timedOut)
    _ = try await harness.search("will it rain tomorrow", route: .weather, city: "Chicago", coordinate: Self.chicago)
    XCTAssertEqual(harness.engine.queries.map(\.text), ["weather Chicago"])
  }
}

final class FakeExtractor: ArticleExtracting, @unchecked Sendable {
  enum Behavior: Sendable { case article(ExtractedArticle), fail(ArticleExtractorError), hang }

  private let behaviors: [String: Behavior]
  private let lock = NSLock()
  private var warmed = 0, started = 0, done = 0, cancelled = 0

  init(_ behaviors: [String: Behavior]) { self.behaviors = behaviors }

  var warmUps: Int { lock.withLock { warmed } }
  var extractions: Int { lock.withLock { started } }
  /// Extractions that returned an article.
  var finished: Int { lock.withLock { done } }
  var cancellations: Int { lock.withLock { cancelled } }

  @MainActor func warmUp() { lock.withLock { warmed += 1 } }

  @MainActor func extract(html: String, url: URL) async throws -> ExtractedArticle {
    lock.withLock { started += 1 }
    switch behaviors[url.host() ?? ""] {
    case .article(let article)?:
      lock.withLock { done += 1 }
      return article
    case .fail(let error)?: throw error
    case .hang?:
      do { try await Task.sleep(for: .seconds(3_600)) } catch { lock.withLock { cancelled += 1 } }
      throw CancellationError()
    case nil: throw ArticleExtractorError.scriptFailed
    }
  }
}

final class RecordingEngine: SearchEngine, @unchecked Sendable {
  let id = SearchEngineID.duckDuckGo
  let weight = 1.0
  private let outcome: EngineOutcome
  private let lock = NSLock()
  private var recorded: [EngineQuery] = []

  init(_ outcome: EngineOutcome) { self.outcome = outcome }

  var queries: [EngineQuery] { lock.withLock { recorded } }

  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome {
    lock.withLock { recorded.append(query) }
    return outcome
  }
}

final class LockedEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [AssistantActivityEvent] = []
  func append(_ event: AssistantActivityEvent) { lock.withLock { storage.append(event) } }
  var values: [AssistantActivityEvent] { lock.withLock { storage } }
}
