import XCTest
@testable import Enigma

final class SearchSiteRunnerTests: XCTestCase {
  private let query = EngineQuery(text: "secret query words", region: SearchRegion(country: "us", language: "en"),
                                  recency: nil)

  private func runner(engine: any SearchEngine, client: FakeSearchHTTPClient, health: EngineHealth,
                      log: RecordingSearchLog = RecordingSearchLog(), clock: ManualClock) -> SearchSiteRunner {
    SearchSiteRunner(engines: [.duckDuckGo: engine], wikipedia: WikipediaSearch(), client: client, health: health,
                     log: log, clock: clock)
  }

  private func stubWikipediaArticle(_ client: FakeSearchHTTPClient) {
    client.stub(WikipediaSearch.searchRequest(for: query.text, language: "en").url!,
                .response(status: 200, body: SearchFixture.data("wikipedia-search.json")))
    client.stub(WikipediaSearch.extractRequest(title: "Synthetic Topic", language: "en").url!,
                .response(status: 200, body: SearchFixture.data("wikipedia-extract.json")))
  }

  private func isWikipedia(_ request: URLRequest) -> Bool { request.url?.host()?.hasSuffix("wikipedia.org") == true }

  func testPrimariesRunTogether() async {
    let clock = ManualClock()
    let engine = FakeEngine(.hang)
    let client = FakeSearchHTTPClient()
    client.stub(where: { $0.url?.host()?.hasSuffix("wikipedia.org") == true }, .hang)
    let health = EngineHealth()
    let runner = runner(engine: engine, client: client, health: health, clock: clock)
    let run = Task { [query] in await runner.run(query, includeWikipedia: true, preferredLanguages: ["en-US"]) }

    await engine.waitUntilStarted()
    await client.waitForRequests(1)
    // Both are in flight at once, and neither has finished.
    XCTAssertEqual(engine.calls, 1)
    XCTAssertEqual(client.requests.filter(isWikipedia).count, 1)
    await clock.waitForSleepers(2)
    clock.advance(by: SearchSiteRunner.primaryTimeout)

    let result = await run.value
    XCTAssertEqual(SearchSiteRunner.primaryTimeout, .seconds(2))
    XCTAssertEqual(result.outcomes[.duckDuckGo], .failed)
    XCTAssertEqual(result.wikipedia, .failed)
  }

  func testResultsAndArticleComeBackTogether() async {
    let client = FakeSearchHTTPClient()
    client.stub(DuckDuckGoEngine.request(for: query).url!,
                .response(status: 200, body: SearchFixture.data("duckduckgo-results.html")))
    stubWikipediaArticle(client)
    let health = EngineHealth()
    let result = await runner(engine: DuckDuckGoEngine(), client: client, health: health, clock: ManualClock())
      .run(query, includeWikipedia: true, preferredLanguages: ["en-US"])
    guard case .results(let results)? = result.outcomes[.duckDuckGo] else {
      return XCTFail("Expected results, got \(String(describing: result.outcomes[.duckDuckGo]))")
    }
    XCTAssertEqual(results.count, 10)
    guard case .article(let article) = result.wikipedia else { return XCTFail("Expected an article") }
    XCTAssertEqual(article.title, "Synthetic Topic")
    XCTAssertEqual(client.maximumBytes.first, 2_097_152)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  func testWikipediaSkippedWhenNotIncluded() async {
    let client = FakeSearchHTTPClient()
    let result = await runner(engine: FakeEngine(.outcome(.noResults)), client: client, health: EngineHealth(),
                              clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(result.wikipedia, WikipediaOutcome.none)
    XCTAssertTrue(client.requests.filter(isWikipedia).isEmpty)
    XCTAssertEqual(result.outcomes[.duckDuckGo], .noResults)
  }

  func testCoolingDownSiteIsSkipped() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    await health.recordFailure(.duckDuckGo)
    let engine = FakeEngine(.outcome(.results([])))
    let result = await runner(engine: engine, client: FakeSearchHTTPClient(), health: health, clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(result.outcomes[.duckDuckGo], .failed)
    XCTAssertEqual(engine.calls, 0)
    // Skipping isn't another failure: the cooldown still ends at 60 s.
    time.advance(.seconds(60))
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  /// A timeout isn't a block sign: the request is cancelled and DuckDuckGo stays available (D41).
  func testTimeoutLeavesDuckDuckGoAvailable() async {
    let clock = ManualClock()
    let engine = FakeEngine(.hang)
    let health = EngineHealth()
    let runner = runner(engine: engine, client: FakeSearchHTTPClient(), health: health, clock: clock)
    let run = Task { [query] in await runner.run(query, includeWikipedia: false, preferredLanguages: ["en-US"]) }
    await engine.waitUntilStarted()
    await clock.waitForSleepers(1)
    clock.advance(by: .milliseconds(1_999))
    XCTAssertEqual(engine.cancellations, 0, "still waiting just before 2 s")
    clock.advance(by: .milliseconds(1))
    let result = await run.value
    XCTAssertEqual(result.outcomes[.duckDuckGo], .failed)
    XCTAssertEqual(engine.cancellations, 1, "the timed-out request is cancelled")
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling, "a timeout records nothing")
    // Nor does it leave a hidden strike: one later 202 still doesn't cool down.
    await health.recordRateLimited(.duckDuckGo, query: 1)
    let afterOne202 = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(afterOne202)
  }

  func testOutcomesUpdateHealth() async {
    // Block signs cool down at once; one 202 only leaves a strike; a network error records nothing.
    for (outcome, coolsDown) in [(EngineOutcome.blocked, true), (.rateLimited, false), (.failed, false),
                                 (.unrecognized, true), (.noResults, false),
                                 (.results([EngineResult(title: "t", url: URL(string: "https://a.example/")!,
                                                         snippet: "s", position: 1, engine: .duckDuckGo)]), false)] {
      let health = EngineHealth()
      let result = await runner(engine: FakeEngine(.outcome(outcome)), client: FakeSearchHTTPClient(), health: health,
                                clock: ManualClock())
        .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
      XCTAssertEqual(result.outcomes[.duckDuckGo], outcome)
      let cooling = await health.isCoolingDown(.duckDuckGo)
      XCTAssertEqual(cooling, coolsDown, "\(outcome)")
    }
  }

  private func query(_ text: String) -> EngineQuery {
    EngineQuery(text: text, region: SearchRegion(country: "us", language: "en"), recency: nil)
  }

  func testTwoRateLimitsInARowCoolDown() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let clock = ManualClock()
    for (run, text) in ["first query", "second query"].enumerated() {
      let result = await runner(engine: FakeEngine(.outcome(.rateLimited)), client: FakeSearchHTTPClient(),
                                health: health, clock: clock)
        .run(query(text), includeWikipedia: false, preferredLanguages: ["en-US"])
      XCTAssertEqual(result.outcomes[.duckDuckGo], .rateLimited)
      let cooling = await health.isCoolingDown(.duckDuckGo)
      XCTAssertEqual(cooling, run == 1, "run \(run + 1)")
      time.advance(.seconds(2))
    }
  }

  /// Retrying a challenged query (a regenerate, or a model searching again) sends nothing for a
  /// minute, and the site stays available to other queries (D45).
  func testSameChallengedQueryIsSkippedForAMinute() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let clock = ManualClock()
    let challenged = FakeEngine(.outcome(.rateLimited))
    _ = await runner(engine: challenged, client: FakeSearchHTTPClient(), health: health, clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    time.advance(.seconds(2))

    let retry = FakeEngine(.outcome(.rateLimited))
    let retried = await runner(engine: retry, client: FakeSearchHTTPClient(), health: health, clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    // Reported as rate limited, so the user sees "limiting requests", not a connection error.
    XCTAssertEqual(retried.outcomes[.duckDuckGo], .rateLimited)
    XCTAssertEqual(retry.calls, 0, "no request for the challenged query")
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling, "the skip doesn't climb the ladder")
    time.advance(.seconds(2))

    let other = FakeEngine(.outcome(.noResults))
    let otherResult = await runner(engine: other, client: FakeSearchHTTPClient(), health: health, clock: clock)
      .run(query("another question"), includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(other.calls, 1)
    XCTAssertEqual(otherResult.outcomes[.duckDuckGo], .noResults)
  }

  func testSameChallengedQueryIsSentAgainAfterAMinute() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let clock = ManualClock()
    _ = await runner(engine: FakeEngine(.outcome(.rateLimited)), client: FakeSearchHTTPClient(), health: health,
                     clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    time.advance(.seconds(60))
    let again = FakeEngine(.outcome(.noResults))
    let result = await runner(engine: again, client: FakeSearchHTTPClient(), health: health, clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(again.calls, 1)
    XCTAssertEqual(result.outcomes[.duckDuckGo], .noResults)
  }

  /// HTTP 429 follows the 202 rule, through the real engine and client.
  func test429BehavesLike202() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let clock = ManualClock()
    let client = FakeSearchHTTPClient()
    client.stub(DuckDuckGoEngine.searchURL, .response(status: 429, body: Data()))
    let first = await runner(engine: DuckDuckGoEngine(), client: client, health: health, clock: clock)
      .run(query("first query"), includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(first.outcomes[.duckDuckGo], .rateLimited)
    let coolingAfterOne = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(coolingAfterOne)
    time.advance(.seconds(2))

    let retry = await runner(engine: DuckDuckGoEngine(), client: client, health: health, clock: clock)
      .run(query("first query"), includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(retry.outcomes[.duckDuckGo], .rateLimited)
    XCTAssertEqual(client.requests.count, 1, "the retried query sends nothing")
    time.advance(.seconds(2))

    _ = await runner(engine: DuckDuckGoEngine(), client: client, health: health, clock: clock)
      .run(query("second query"), includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(client.requests.count, 2)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertTrue(cooling, "a second, different 429 cools the site down")
  }

  /// The same query challenged while this run waits for its pacing slot isn't sent (review round 3).
  func testChallengedQueryNotSentAfterPacingWait() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    _ = await health.reservePacingSlot(.duckDuckGo)
    let clock = ManualClock()
    let engine = FakeEngine(.outcome(.rateLimited))
    let runner = runner(engine: engine, client: FakeSearchHTTPClient(), health: health, clock: clock)
    let q = query("same question")
    let run = Task { await runner.run(q, includeWikipedia: false, preferredLanguages: ["en-US"]) }
    await clock.waitForSleepers(1)
    await health.recordRateLimited(.duckDuckGo, query: q.text.hashValue)
    clock.advance(by: .seconds(1))
    let result = await run.value
    XCTAssertEqual(engine.calls, 0, "the just-challenged query isn't sent after the pacing wait")
    XCTAssertEqual(result.outcomes[.duckDuckGo], .rateLimited)
  }

  /// A skipped query books no pacing slot, so it doesn't delay the next search.
  func testSkippedQueryBooksNoPacingSlot() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    let clock = ManualClock()
    _ = await runner(engine: FakeEngine(.outcome(.rateLimited)), client: FakeSearchHTTPClient(), health: health,
                     clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    time.advance(.seconds(2))
    _ = await runner(engine: FakeEngine(.outcome(.rateLimited)), client: FakeSearchHTTPClient(), health: health,
                     clock: clock)
      .run(query("challenged"), includeWikipedia: false, preferredLanguages: ["en-US"])
    let delay = await health.pacingDelay(.duckDuckGo)
    XCTAssertEqual(delay, .zero)
  }

  func testUnexpectedStatusIsLoggedAndClimbs() async {
    let client = FakeSearchHTTPClient()
    client.stub(DuckDuckGoEngine.searchURL, .response(status: 404, body: Data("gone".utf8)))
    let log = RecordingSearchLog()
    let health = EngineHealth()
    let result = await runner(engine: DuckDuckGoEngine(), client: client, health: health, log: log,
                              clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(result.outcomes[.duckDuckGo], .unrecognized)
    XCTAssertEqual(log.entries.map(\.status), [404])
    XCTAssertEqual(log.entries.map(\.bytes), [4])
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertTrue(cooling)
  }

  func testServerErrorIsLoggedWithoutClimbing() async {
    let client = FakeSearchHTTPClient()
    client.stub(DuckDuckGoEngine.searchURL, .response(status: 500, body: Data("oops".utf8)))
    let log = RecordingSearchLog()
    let health = EngineHealth()
    let result = await runner(engine: DuckDuckGoEngine(), client: client, health: health, log: log,
                              clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(result.outcomes[.duckDuckGo], .failed)
    XCTAssertEqual(log.failures.map(\.status), [500])
    XCTAssertEqual(log.failures.map(\.bytes), [4])
    XCTAssertTrue(log.entries.isEmpty)
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)

    // A thrown network error logs nothing.
    let unreachable = RecordingSearchLog()
    _ = await runner(engine: DuckDuckGoEngine(), client: FakeSearchHTTPClient(), health: EngineHealth(),
                     log: unreachable, clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertTrue(unreachable.entries.isEmpty)
    XCTAssertTrue(unreachable.failures.isEmpty)
  }

  func testPacingWaitThenCooldownSkipsTheSite() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    _ = await health.reservePacingSlot(.duckDuckGo)
    let clock = ManualClock()
    let engine = FakeEngine(.outcome(.results([])))
    let runner = runner(engine: engine, client: FakeSearchHTTPClient(), health: health, clock: clock)
    let run = Task { [query] in await runner.run(query, includeWikipedia: false, preferredLanguages: ["en-US"]) }
    await clock.waitForSleepers(1)
    // Another search hits a block while this one waits for its pacing slot.
    await health.recordFailure(.duckDuckGo)
    clock.advance(by: .seconds(1))
    let result = await run.value
    XCTAssertEqual(result.outcomes[.duckDuckGo], .failed)
    XCTAssertEqual(engine.calls, 0, "the site isn't queried once it is cooling down")
    // Nothing more was recorded: the cooldown is still the first 60 s step.
    time.advance(.seconds(60))
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  func testUnrecognizedPageIsLoggedWithoutQuery() async {
    let client = FakeSearchHTTPClient()
    let body = SearchFixture.data("duckduckgo-changed.html")
    client.stub(DuckDuckGoEngine.request(for: query).url!, .response(status: 200, body: body))
    let log = RecordingSearchLog()
    let result = await runner(engine: DuckDuckGoEngine(), client: client, health: EngineHealth(), log: log,
                              clock: ManualClock())
      .run(query, includeWikipedia: false, preferredLanguages: ["en-US"])
    XCTAssertEqual(result.outcomes[.duckDuckGo], .unrecognized)
    XCTAssertEqual(log.entries.count, 1)
    XCTAssertEqual(log.entries.first?.engine, .duckDuckGo)
    XCTAssertEqual(log.entries.first?.status, 200)
    XCTAssertEqual(log.entries.first?.bytes, body.count)
    for entry in log.entries {
      for argument in [entry.engine.rawValue, String(entry.status), String(entry.bytes)] {
        XCTAssertFalse(argument.contains("secret"), argument)
      }
    }
  }

  func testCancellationStopsAllSites() async {
    let clock = ManualClock()
    let engine = FakeEngine(.hang)
    let client = FakeSearchHTTPClient()
    client.stub(where: { $0.url?.host()?.hasSuffix("wikipedia.org") == true }, .hang)
    let health = EngineHealth()
    let runner = runner(engine: engine, client: client, health: health, clock: clock)
    let run = Task { [query] in await runner.run(query, includeWikipedia: true, preferredLanguages: ["en-US"]) }
    await engine.waitUntilStarted()
    await client.waitForRequests(1)
    run.cancel()
    _ = await run.value
    XCTAssertEqual(engine.cancellations, 1)
    XCTAssertEqual(client.cancellations, 1)
    XCTAssertEqual(clock.sleeperCount, 0, "no timeout is left waiting")
    // Stop isn't the site's fault: nothing is recorded.
    let cooling = await health.isCoolingDown(.duckDuckGo)
    XCTAssertFalse(cooling)
  }

  func testPacingWaitsBeforeTheRequest() async {
    let time = TestInstant()
    let health = EngineHealth(now: { time.now })
    _ = await health.reservePacingSlot(.duckDuckGo)
    time.advance(.milliseconds(300))
    let clock = ManualClock()
    let engine = FakeEngine(.outcome(.noResults))
    let runner = runner(engine: engine, client: FakeSearchHTTPClient(), health: health, clock: clock)
    let run = Task { [query] in await runner.run(query, includeWikipedia: false, preferredLanguages: ["en-US"]) }
    await clock.waitForSleepers(1)
    XCTAssertEqual(engine.calls, 0, "waits for the pacing slot first")
    clock.advance(by: .milliseconds(699))
    XCTAssertEqual(engine.calls, 0)
    clock.advance(by: .milliseconds(1))
    let result = await run.value
    XCTAssertEqual(engine.calls, 1)
    XCTAssertEqual(result.outcomes[.duckDuckGo], .noResults)
  }
}

/// An engine that returns a fixed outcome or hangs until cancelled.
final class FakeEngine: SearchEngine, @unchecked Sendable {
  enum Behavior { case outcome(EngineOutcome), hang }

  let id = SearchEngineID.duckDuckGo
  let weight = 1.0
  private let behavior: Behavior
  private let lock = NSLock()
  private var callCount = 0
  private var cancelCount = 0

  init(_ behavior: Behavior) { self.behavior = behavior }

  var calls: Int { lock.withLock { callCount } }
  var cancellations: Int { lock.withLock { cancelCount } }

  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome {
    lock.withLock { callCount += 1 }
    switch behavior {
    case .outcome(let outcome):
      return outcome
    case .hang:
      do { try await Task.sleep(for: .seconds(3_600)) } catch { lock.withLock { cancelCount += 1 } }
      return .failed
    }
  }

  func waitUntilStarted() async {
    for _ in 0..<5_000 where calls == 0 { try? await Task.sleep(for: .milliseconds(1)) }
  }
}

final class RecordingSearchLog: SearchLogging, @unchecked Sendable {
  struct Entry { let engine: SearchEngineID; let status: Int; let bytes: Int }
  private let lock = NSLock()
  private var recorded: [Entry] = []
  private var failed: [Entry] = []
  var entries: [Entry] { lock.withLock { recorded } }
  var failures: [Entry] { lock.withLock { failed } }
  func unrecognizedPage(engine: SearchEngineID, status: Int, bytes: Int) {
    lock.withLock { recorded.append(Entry(engine: engine, status: status, bytes: bytes)) }
  }
  func failedPage(engine: SearchEngineID, status: Int, bytes: Int) {
    lock.withLock { failed.append(Entry(engine: engine, status: status, bytes: bytes)) }
  }
}
