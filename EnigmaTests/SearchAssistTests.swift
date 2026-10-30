import XCTest
@testable import Enigma

/// The small-model path's query rewrite and "enough?" check (F29 CP7, D107, D108): parsing, the
/// code-only fallback, merging several queries, and the provider's use of both. No network, no model.
final class SearchAssistTests: XCTestCase {
  // MARK: Rewrite parsing

  func testRewriteParsesQueriesAndEntity() throws {
    let parsed = try XCTUnwrap(SearchQueryRewrite.parse("""
      query: rust newest release
      query: "rust release notes"
      - query: Rust Newest Release
      entity: Rust.
      """))
    XCTAssertEqual(parsed.queries, ["rust newest release", "rust release notes"], "Duplicates go")
    XCTAssertEqual(parsed.entity, "Rust")
  }

  func testRewriteKeepsAtMostThreeQueriesAndReadsNoEntity() throws {
    let parsed = try XCTUnwrap(SearchQueryRewrite.parse("query: a one\nquery: b two\nquery: c three\nquery: d four\nentity: none"))
    XCTAssertEqual(parsed.queries, ["a one", "b two", "c three"])
    XCTAssertNil(parsed.entity)
  }

  func testRewriteJunkIsRejected() {
    XCTAssertNil(SearchQueryRewrite.parse("Rust 1.99.1 came out in October."), "No query lines")
    XCTAssertNil(SearchQueryRewrite.parse("query: https://example.com/search?q=rust"), "A URL")
    XCTAssertNil(SearchQueryRewrite.parse("query: " + Array(repeating: "word", count: 11).joined(separator: " ")),
                 "Too many words")
    XCTAssertNil(SearchQueryRewrite.parse("query: ???"), "No letters or digits")
    XCTAssertNil(SearchQueryRewrite.parse(""))
  }

  func testRewriteDropsAThinkingBlock() throws {
    let parsed = try XCTUnwrap(SearchQueryRewrite.parse("<think>query: wrong one</think>\nquery: right one"))
    XCTAssertEqual(parsed.queries, ["right one"])
  }

  func testRewritePromptHoldsTheQuestionAndDate() {
    let prompt = SearchQueryRewrite.prompt(question: "who won the race?", today: OnDeviceSearchTests.now)
    XCTAssertTrue(prompt.hasSuffix("Question: who won the race?"))
    XCTAssertTrue(prompt.contains("Today is 2026-"))
  }

  // MARK: The code-only clean-up

  func testKeywordCleanUpDropsQuestionWordsAndKeepsQualifiers() {
    XCTAssertEqual(SearchQueryRewrite.keywords("What's the latest version of Swift?"), "latest version Swift")
    XCTAssertEqual(SearchQueryRewrite.keywords("Can you please tell me who won the Nobel Prize in Literature 2025?"),
                   "won Nobel Prize in Literature 2025")
    XCTAssertEqual(SearchQueryRewrite.keywords("How tall is Mount Everest, exactly?"), "tall Mount Everest")
    XCTAssertEqual(SearchQueryRewrite.keywords("c++ vs c# speed"), "c++ vs c# speed")
    XCTAssertEqual(SearchQueryRewrite.keywords("what is it?"), "what is it", "Nothing left: the question's words")
    XCTAssertEqual(SearchQueryRewrite.keywords("東京の天気は？"), "東京の天気は")
    // Names keep their capitalized stop-words (D126).
    XCTAssertEqual(SearchQueryRewrite.keywords("Will Smith's latest movie?"), "Will Smith's latest movie")
    XCTAssertEqual(SearchQueryRewrite.keywords("What did Theresa May say today?"), "Theresa May say today")
    XCTAssertEqual(SearchQueryRewrite.keywords("When did World War I end?"), "World War I end")
    XCTAssertEqual(SearchQueryRewrite.keywords("who are the members of The Who"), "members The Who")
    XCTAssertEqual(SearchQueryRewrite.keywords("how to tie a tie"), "how to tie tie")
    XCTAssertEqual(SearchQueryRewrite.keywords("Will it rain tomorrow?"), "rain tomorrow", "Not a name before a lowercase word")
    XCTAssertEqual(SearchQueryRewrite.keywords("Can I renew my passport online?"), "renew passport online")
  }

  // MARK: The check

  func testCheckParsesYesAndNoWithMissingWords() {
    XCTAssertEqual(SearchSufficiencyCheck.parse("yes"), .enough)
    XCTAssertEqual(SearchSufficiencyCheck.parse("Yes."), .enough)
    XCTAssertEqual(SearchSufficiencyCheck.parse("no: 2026 laureate name"), .missing("2026 laureate name"))
    XCTAssertEqual(SearchSufficiencyCheck.parse("No, the release date\nmore text"), .missing("release date"))
    XCTAssertNil(SearchSufficiencyCheck.parse("no"), "No words to search for")
    XCTAssertNil(SearchSufficiencyCheck.parse("maybe"))
    XCTAssertNil(SearchSufficiencyCheck.parse("nothing here"), "Not a no")
    XCTAssertNil(SearchSufficiencyCheck.parse("no: one two three four five six seven"), "Too many words")
    XCTAssertNil(SearchSufficiencyCheck.parse("no: www.example.org release"), "A www. name")
    XCTAssertNil(SearchSufficiencyCheck.parse("no: laureate site example.com"), "A domain")
    XCTAssertEqual(SearchSufficiencyCheck.parse("no: python 3.12 node.js"), .missing("python 3.12 node.js"),
                   "Version numbers and names aren't domains")
    XCTAssertNil(SearchQueryRewrite.parse("query: nobel winner nobelprize.org"), "The rewrite rejects domains too")
  }

  func testCheckPromptCapsThePassages() {
    let long = Array(repeating: "zebra", count: 1_000).joined(separator: " ")
    let prompt = SearchSufficiencyCheck.prompt(question: "q?", sources: [("A", long), ("B", "never shown")])
    XCTAssertEqual(prompt.components(separatedBy: "zebra").count - 1, SearchAssistTuning.checkWords)
    XCTAssertFalse(prompt.contains("never shown"))
  }

  // MARK: Merging several queries

  private func candidate(_ name: String, score: Double, position: Int) -> RankedCandidate {
    RankedCandidate(url: OnDeviceSearchTests.url(name), title: "T \(name)", snippet: "S", positions: [.duckDuckGo: position],
                    score: score, domain: OnDeviceSearchTests.host(name))
  }

  func testFuseKeepsOneListAndSumsScoresAcrossLists() {
    let first = [candidate("a", score: 1, position: 1), candidate("b", score: 0.5, position: 2)]
    XCTAssertEqual(OnDeviceSearchProvider.fuse([first]), first)
    let second = [candidate("b", score: 1, position: 1), candidate("c", score: 0.5, position: 2)]
    let fused = OnDeviceSearchProvider.fuse([first, second])
    XCTAssertEqual(fused.map(\.domain), ["b.example", "a.example", "c.example"])
    XCTAssertEqual(fused[0].score, 1.5)
    XCTAssertEqual(fused[0].positions, [.duckDuckGo: 1])
  }

  // MARK: The provider

  private func provider(_ harness: OnDeviceSearchTests.Harness, engine: any SearchEngine,
                        trace: (any SearchTracing)? = nil) -> OnDeviceSearchProvider {
    let quality = harness.quality
    let sites = SearchSiteRunner(engines: [.duckDuckGo: engine], wikipedia: WikipediaSearch(), client: harness.client,
                                 health: EngineHealth(), log: RecordingSearchLog())
    let reader = PageReader(client: harness.client, networkGuard: NetworkGuard(resolver: harness.resolver),
                            isBlocked: { quality.isBlocked($0) })
    return OnDeviceSearchProvider(sites: sites, reader: reader, extractor: harness.extractor, quality: { quality },
                                  preferredLanguages: { ["en-US"] }, clock: harness.clock,
                                  now: { OnDeviceSearchTests.now }, places: harness.places, weather: harness.weather,
                                  geocoder: harness.geocoder, units: { .us }, trace: trace,
                                  extras: ExtraSearchSources(facts: WikidataFacts(), news: GoogleNewsSearch(),
                                                             client: harness.client))
  }

  private static let pages = ["alpha", "beta", "gamma", "delta"]

  private func harness() -> OnDeviceSearchTests.Harness {
    OnDeviceSearchTests.Harness(Self.pages.map { ($0, .article(OnDeviceSearchTests.article($0))) })
  }

  private func request(_ query: String, typed: Bool = true, recency: SearchRecency? = nil) -> WebSearchRequest {
    var request = WebSearchRequest(query: query, route: .web, recency: recency, maximumTokens: WebSearchLimits.evidenceTokens)
    request.isTypedQuestion = typed
    return request
  }

  func testModelQueriesAreSearchedAndMergedAndTheEntityGetsFacts() async throws {
    let harness = harness()
    harness.client.stub(WikidataFacts.searchRequest(entity: "Rust", language: "en").url!,
                        .response(status: 200, body: SearchFixture.data("wikidata-search.json")))
    harness.client.stub(WikidataFacts.entityRequest(id: "Q575650", language: "en").url!,
                        .response(status: 200, body: SearchFixture.data("wikidata-entity-rust.json")))
    let engine = ScriptedEngine(["rust newest release": ["alpha", "beta"], "rust release notes": ["beta", "gamma"]])
    let assistant = ScriptedAssistant(["query: rust newest release\nquery: rust release notes\nentity: Rust", "yes"])
    let recorder = OnDeviceSearchTests.SearchTraceRecorder()
    let results = try await provider(harness, engine: engine, trace: recorder)
      .search(request("which rust release is the newest?"), assistant: assistant, onActivity: { _ in })
    XCTAssertEqual(Set(engine.queries), ["rust newest release", "rust release notes"])
    XCTAssertEqual(results.first?.kind, .facts)
    XCTAssertTrue(results.first?.snippets.first?.contains("1.99.1") == true)
    XCTAssertEqual(Set(results.dropFirst().compactMap { $0.source.url.host() }),
                   ["alpha.example", "beta.example", "gamma.example"])
    XCTAssertEqual(recorder.steps["rewrite"]?.hasPrefix("model:"), true)
    XCTAssertEqual(recorder.steps["check"]?.hasPrefix("yes:"), true)
    XCTAssertEqual(recorder.siteOutcomes["duckDuckGo"], "results:2")
    XCTAssertEqual(recorder.siteOutcomes["duckDuckGo#2"], "results:2")
    XCTAssertEqual(recorder.siteOutcomes["wikidata"], "results:2")
    XCTAssertEqual(assistant.prompts.count, 2, "The rewrite and the check")
  }

  func testWithoutTheModelTheTypedQuestionIsCleanedUp() async throws {
    let engine = ScriptedEngine(["rust release newest": ["alpha", "beta"]])
    let recorder = OnDeviceSearchTests.SearchTraceRecorder()
    let results = try await provider(harness(), engine: engine, trace: recorder)
      .search(request("Which Rust release is the newest?"), assistant: nil, onActivity: { _ in })
    XCTAssertEqual(engine.queries, ["Rust release newest"])
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(recorder.steps["rewrite"], "fallback:0")
    XCTAssertNil(recorder.steps["check"], "No model, no check")
  }

  func testAModelWrittenQueryGoesAsWritten() async throws {
    let engine = ScriptedEngine(["which rust release is the newest?": ["alpha"]])
    let assistant = ScriptedAssistant(["query: should not be asked"])
    _ = try await provider(harness(), engine: engine)
      .search(request("which rust release is the newest?", typed: false), assistant: assistant, onActivity: { _ in })
    XCTAssertEqual(engine.queries, ["which rust release is the newest?"])
    XCTAssertTrue(assistant.prompts.isEmpty, "Neither the rewrite nor the check runs")
  }

  func testJunkFromTheModelFallsBackToTheCleanUp() async throws {
    let engine = ScriptedEngine(["Rust release newest": ["alpha"]])
    let recorder = OnDeviceSearchTests.SearchTraceRecorder()
    _ = try await provider(harness(), engine: engine, trace: recorder)
      .search(request("Which Rust release is the newest?"), assistant: ScriptedAssistant(["Sure! Here you go.", "yes"]),
              onActivity: { _ in })
    XCTAssertEqual(engine.queries, ["Rust release newest"])
    XCTAssertEqual(recorder.steps["rewrite"]?.hasPrefix("junk:"), true)
  }

  func testAFailingModelFallsBackToTheCleanUp() async throws {
    let engine = ScriptedEngine(["Rust release newest": ["alpha"]])
    let recorder = OnDeviceSearchTests.SearchTraceRecorder()
    let results = try await provider(harness(), engine: engine, trace: recorder)
      .search(request("Which Rust release is the newest?"), assistant: ScriptedAssistant([]), onActivity: { _ in })
    XCTAssertEqual(engine.queries, ["Rust release newest"])
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(recorder.steps["rewrite"]?.hasPrefix("failed:"), true)
    XCTAssertEqual(recorder.steps["check"]?.hasPrefix("failed:"), true, "A failed check never retries")
  }

  func testNotEnoughRetriesOnceWithTheMissingWordsAndAddsTheNewPages() async throws {
    let engine = ScriptedEngine(["nobel literature winner": ["alpha"], "nobel literature winner 2026 laureate": ["alpha", "delta"]])
    // The check says "no" every time; only one retry may run.
    let assistant = ScriptedAssistant(["query: nobel literature winner\nentity: none", "no: 2026 laureate",
                                       "no: something else"])
    let recorder = OnDeviceSearchTests.SearchTraceRecorder()
    let results = try await provider(harness(), engine: engine, trace: recorder)
      .search(request("who won the nobel prize in literature"), assistant: assistant, onActivity: { _ in })
    XCTAssertEqual(engine.queries, ["nobel literature winner", "nobel literature winner 2026 laureate"])
    XCTAssertEqual(assistant.prompts.count, 2, "One check, so at most one retry")
    let hosts = Set(results.compactMap { $0.source.url.host() })
    XCTAssertTrue(hosts.isSuperset(of: ["alpha.example", "delta.example"]))
    XCTAssertEqual(recorder.siteOutcomes["retry"], "results:2")
    XCTAssertEqual(recorder.steps["check"]?.hasPrefix("no:"), true)
  }

  func testNewsQuestionsGetGoogleNewsHeadlinesWithoutFollowingLinks() async throws {
    let harness = harness()
    harness.client.stub(where: { $0.url?.host == "news.google.com" && $0.url?.path == "/rss/search" },
                        .response(status: 200, body: SearchFixture.data("google-news.xml")))
    let engine = ScriptedEngine(["latest news nobel literature": ["alpha", "beta"]])
    let results = try await provider(harness, engine: engine)
      .search(request("latest news nobel literature", recency: .week), assistant: nil, onActivity: { _ in })
    XCTAssertEqual(results.first?.kind, .news)
    let newsRequests = harness.client.requests.filter { $0.url?.host == "news.google.com" }
    XCTAssertEqual(newsRequests.count, 1, "No article link is followed")
    XCTAssertEqual(URLComponents(url: newsRequests[0].url!, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "q" }?.value, "latest news nobel literature")
  }

  func testNoMoreThanTheCapOfQueriesReachDuckDuckGo() async throws {
    let engine = ScriptedEngine([:])
    let assistant = ScriptedAssistant(["query: one alpha\nquery: two beta\nquery: three gamma\nentity: none", "yes"])
    _ = try? await provider(harness(), engine: engine)
      .search(request("tell me about alpha beta gamma"), assistant: assistant, onActivity: { _ in })
    XCTAssertEqual(engine.queries.count, SearchAssistTuning.maximumSiteQueries)
    XCTAssertEqual(Set(engine.queries), ["one alpha", "two beta"])
  }

  func testARequestWithACityNeverAsksGoogleNews() async throws {
    let harness = harness()
    var nearby = request("latest news cafes near Chicago", recency: .week)
    nearby.city = "Chicago"
    _ = try? await provider(harness, engine: ScriptedEngine(["latest news cafes near Chicago": ["alpha"]]))
      .search(nearby, assistant: nil, onActivity: { _ in })
    XCTAssertFalse(harness.client.requests.contains { $0.url?.host == "news.google.com" })
  }

  func testStoppingDuringTheRewriteSendsNothingToGoogleOrWikidata() async throws {
    let harness = harness()
    let engine = ScriptedEngine(["latest news nobel literature": ["alpha"]])
    let assistant = HangingAssistant()
    let provider = provider(harness, engine: engine)
    let question = request("latest news nobel literature", recency: .week)
    let search = Task { [provider, question, assistant] in
      try await provider.search(question, assistant: assistant, onActivity: { _ in })
    }
    await assistant.waitUntilAsked()
    search.cancel()
    do {
      _ = try await search.value
      XCTFail("A stopped search returns no results")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    // Give any stray task a moment to send.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(harness.client.requests.contains { ["news.google.com", "www.wikidata.org"].contains($0.url?.host) })
    XCTAssertTrue(engine.queries.isEmpty)
  }

  // MARK: Blocked sites in the new lanes (D125)

  private func stubRustFacts(_ harness: OnDeviceSearchTests.Harness) {
    harness.client.stub(WikidataFacts.searchRequest(entity: "Rust", language: "en").url!,
                        .response(status: 200, body: SearchFixture.data("wikidata-search.json")))
    harness.client.stub(WikidataFacts.entityRequest(id: "Q575650", language: "en").url!,
                        .response(status: 200, body: SearchFixture.data("wikidata-entity-rust.json")))
  }

  func testBlockedWikidataLeavesOutTheFacts() async throws {
    let harness = harness()
    harness.quality = SourceQualityFixture.quality(userBlocked: ["wikidata.org"])
    stubRustFacts(harness)
    let results = try await provider(harness, engine: ScriptedEngine(["rust newest release": ["alpha"]]))
      .search(request("which rust release is the newest?"),
              assistant: ScriptedAssistant(["query: rust newest release\nentity: Rust", "yes"]), onActivity: { _ in })
    XCTAssertFalse(results.contains { $0.kind == .facts })
  }

  func testBlockedGoogleNewsIsNeverAsked() async throws {
    let harness = harness()
    harness.quality = SourceQualityFixture.quality(userBlocked: ["news.google.com"])
    harness.client.stub(where: { $0.url?.host == "news.google.com" },
                        .response(status: 200, body: SearchFixture.data("google-news.xml")))
    let results = try await provider(harness, engine: ScriptedEngine(["latest news nobel literature": ["alpha"]]))
      .search(request("latest news nobel literature", recency: .week), assistant: nil, onActivity: { _ in })
    XCTAssertFalse(harness.client.requests.contains { $0.url?.host == "news.google.com" })
    XCTAssertFalse(results.contains { $0.kind == .news })
  }

  private static func feed(_ items: [(title: String, publisher: String, home: String)]) -> Data {
    let body = items.map { item in
      "<item><title>\(item.title) - \(item.publisher)</title><pubDate>Thu, 08 Oct 2026 07:00:00 GMT</pubDate>"
        + "<source url=\"\(item.home)\">\(item.publisher)</source></item>"
    }.joined()
    return Data("<rss><channel>\(body)</channel></rss>".utf8)
  }

  func testHeadlinesFromABlockedPublisherAreDropped() async throws {
    let harness = harness()
    harness.quality = SourceQualityFixture.quality(userBlocked: ["blocked.example"])
    harness.client.stub(where: { $0.url?.host == "news.google.com" }, .response(status: 200, body: Self.feed([
      ("Kept story", "Good Paper", "https://good.example"), ("Hidden story", "Blocked Paper", "https://blocked.example"),
    ])))
    let results = try await provider(harness, engine: ScriptedEngine(["latest news nobel literature": ["alpha"]]))
      .search(request("latest news nobel literature", recency: .week), assistant: nil, onActivity: { _ in })
    let news = try XCTUnwrap(results.first { $0.kind == .news }?.snippets.first)
    XCTAssertTrue(news.contains("Kept story"))
    XCTAssertFalse(news.contains("Hidden story"))
  }

  func testOnlyBlockedPublishersLeaveNoNewsExcerpt() async throws {
    let harness = harness()
    harness.quality = SourceQualityFixture.quality(userBlocked: ["blocked.example"])
    harness.client.stub(where: { $0.url?.host == "news.google.com" }, .response(status: 200, body: Self.feed([
      ("Hidden story", "Blocked Paper", "https://blocked.example"),
    ])))
    let results = try await provider(harness, engine: ScriptedEngine(["latest news nobel literature": ["alpha"]]))
      .search(request("latest news nobel literature", recency: .week), assistant: nil, onActivity: { _ in })
    XCTAssertFalse(results.contains { $0.kind == .news })
  }

  func testAPublisherPageStaysBesideTheNewsExcerpt() async throws {
    let harness = harness()
    // The newest headline's publisher is the very page DuckDuckGo found.
    harness.client.stub(where: { $0.url?.host == "news.google.com" }, .response(status: 200, body: Self.feed([
      ("Alpha story", "Alpha", OnDeviceSearchTests.url("alpha").absoluteString),
    ])))
    let results = try await provider(harness, engine: ScriptedEngine(["latest news nobel literature": ["alpha"]]))
      .search(request("latest news nobel literature", recency: .week), assistant: nil, onActivity: { _ in })
    XCTAssertEqual(results.first { $0.kind == .news }?.source.url.absoluteString, "https://news.google.com/")
    XCTAssertTrue(results.contains { $0.kind == .article && $0.source.url == OnDeviceSearchTests.url("alpha") })
    XCTAssertEqual(Set(results.map(\.source.url)).count, results.count, "No two sources share a link")
  }

  // MARK: The check's budget

  func testPagePassagesFillTheCheckBeforeFactsAndHeadlines() async throws {
    let harness = harness()
    stubRustFacts(harness)
    let assistant = ScriptedAssistant(["query: rust newest release\nentity: Rust", "yes"])
    let results = try await provider(harness, engine: ScriptedEngine(["rust newest release": ["alpha", "beta"]]))
      .search(request("which rust release is the newest?"), assistant: assistant, onActivity: { _ in })
    XCTAssertEqual(results.first?.kind, .facts, "The facts excerpt is in the results")
    let check = try XCTUnwrap(assistant.prompts.last)
    XCTAssertTrue(check.contains("[1] Article "), "A page comes first")
    // The facts come after the pages, when the budget leaves them room at all.
    if let facts = check.range(of: "Rust — Wikidata"), let page = check.range(of: "Article ") {
      XCTAssertLessThan(page.lowerBound, facts.lowerBound)
    }
  }

  // MARK: Cancelling the lanes (D124)

  /// True when the task ends within 3 s. Polls, so a task that never ends fails the test instead
  /// of hanging it.
  private func endsPromptly(_ task: Task<[WebSearchResult], any Error>) async -> Bool {
    let ended = LockedFlag()
    Task { _ = try? await task.value; ended.set() }
    for _ in 0..<3_000 where !ended.value {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return ended.value
  }

  func testStoppingWhileWikidataAnswersEndsTheSearchAndSendsNoMore() async throws {
    let harness = harness()
    harness.client.stub(where: { $0.url?.host == "www.wikidata.org" }, .hang)
    let provider = provider(harness, engine: ScriptedEngine(["rust newest release": ["alpha"]]))
    // A Wikipedia-style title: its sitelink is asked first, then the entity search would follow.
    let assistant = ScriptedAssistant(["query: rust newest release\nentity: Rust (programming language)", "yes"])
    let question = request("which rust release is the newest?")
    let search = Task { [provider, question, assistant] in
      try await provider.search(question, assistant: assistant, onActivity: { _ in })
    }
    for _ in 0..<5_000 where !harness.client.requests.contains(where: { $0.url?.host == "www.wikidata.org" }) {
      try await Task.sleep(for: .milliseconds(1))
    }
    // Let the sites and the reading finish, so the search waits on Wikidata alone.
    try await Task.sleep(for: .milliseconds(300))
    search.cancel()
    let ended = await endsPromptly(search)
    XCTAssertTrue(ended, "Stopping cancels the facts lane")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(harness.client.requests.filter { $0.url?.host == "www.wikidata.org" }.count, 1,
                   "No Wikidata request after the stop")
  }

  func testStoppingWhileGoogleNewsAnswersEndsTheSearch() async throws {
    let harness = harness()
    harness.client.stub(where: { $0.url?.host == "news.google.com" }, .hang)
    let provider = provider(harness, engine: ScriptedEngine(["latest news nobel literature": ["alpha"]]))
    let question = request("latest news nobel literature", recency: .week)
    let search = Task { [provider, question] in
      try await provider.search(question, assistant: nil, onActivity: { _ in })
    }
    for _ in 0..<5_000 where !harness.client.requests.contains(where: { $0.url?.host == "news.google.com" }) {
      try await Task.sleep(for: .milliseconds(1))
    }
    try await Task.sleep(for: .milliseconds(300))
    search.cancel()
    let ended = await endsPromptly(search)
    XCTAssertTrue(ended, "Stopping cancels the news lane")
  }

  func testOtherQuestionsNeverAskGoogleNews() async throws {
    let harness = harness()
    _ = try await provider(harness, engine: ScriptedEngine(["tall Mount Everest": ["alpha"]]))
      .search(request("How tall is Mount Everest?"), assistant: nil, onActivity: { _ in })
    XCTAssertFalse(harness.client.requests.contains { $0.url?.host == "news.google.com" })
  }

  func testOnlyHeadlinesStillAnswer() async throws {
    let harness = harness()
    harness.client.stub(where: { $0.url?.host == "news.google.com" },
                        .response(status: 200, body: SearchFixture.data("google-news.xml")))
    let results = try await provider(harness, engine: ScriptedEngine([:]))
      .search(request("breaking news nobel", recency: .week), assistant: nil, onActivity: { _ in })
    XCTAssertEqual(results.map(\.kind), [.news])
  }
}

/// Answers each query from a table of page names; anything else finds nothing.
final class ScriptedEngine: SearchEngine, @unchecked Sendable {
  let id = SearchEngineID.duckDuckGo
  let weight = 1.0
  private let table: [String: [String]]
  private let lock = NSLock()
  private var recorded: [String] = []

  init(_ table: [String: [String]]) {
    self.table = Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
  }

  var queries: [String] { lock.withLock { recorded } }

  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome {
    lock.withLock { recorded.append(query.text) }
    guard let names = table[query.text.lowercased()], !names.isEmpty else { return .noResults }
    return .results(names.enumerated().map { OnDeviceSearchTests.result($0.element, position: $0.offset + 1) })
  }
}

/// Replies in order; throws once the replies run out.
final class ScriptedAssistant: SearchModelAssistant, @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [String]
  private var asked: [String] = []

  init(_ replies: [String]) { self.replies = replies }

  var prompts: [String] { lock.withLock { asked } }

  func complete(_ prompt: String, maximumTokens: Int) async throws -> String {
    try lock.withLock {
      asked.append(prompt)
      guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
      return replies.removeFirst()
    }
  }
}

/// Never answers until its task is cancelled.
final class HangingAssistant: SearchModelAssistant, @unchecked Sendable {
  private let lock = NSLock()
  private var asked = false

  func waitUntilAsked() async {
    for _ in 0..<5_000 where !lock.withLock({ asked }) {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  func complete(_ prompt: String, maximumTokens: Int) async throws -> String {
    lock.withLock { asked = true }
    try await Task.sleep(for: .seconds(3_600))
    throw CancellationError()
  }
}

final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  var value: Bool { lock.withLock { flag } }
}
