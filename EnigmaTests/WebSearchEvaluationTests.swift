import XCTest
@testable import Enigma

/// F29 CP7's evaluation. It runs the fixed question set (`scripts/web-search-queries.json`, 60 questions)
/// in two styles, the question as typed (small models) and the entry's query or tool arguments (capable
/// models), through Brave and through on-device search. It writes what each provider found, its timings,
/// the ranking trace, and the evidence each answer is grounded on, for `scripts/evaluate-web-search.py`.
///
/// Opt-in: it skips unless `ENIGMA_SEARCH_EVAL` names a folder outside the repository
/// (`TEST_RUNNER_ENIGMA_SEARCH_EVAL`). Brave runs only when `ENIGMA_BRAVE_KEY` is set
/// (`TEST_RUNNER_ENIGMA_BRAVE_KEY`); the key is never written, printed or logged. Every search uses
/// Chicago at 41.88, -87.63 where a location is needed, never the Mac's location. The user's blocked
/// sites are empty, so the run measures the lists alone. `ENIGMA_SEARCH_EVAL_IDS` limits the run to
/// comma-separated question IDs, for a quick check.
@MainActor
final class WebSearchEvaluationTests: XCTestCase {
  private struct Question: Decodable {
    let id: String
    let category: String
    let question: String
    let query: String?
    let tool: Tool?

    struct Tool: Decodable {
      let name: String
      let arguments: [String: String]
    }
  }

  private struct SourceRow: Encodable {
    let url: String
    let domain: String
    let kind: String
    let title: String
    let site: String?
    let published: String?
  }

  private struct RunRow: Encodable {
    let id: String
    let category: String
    let style: String
    let provider: String
    let route: String
    let latencyMs: Int
    let error: String?
    let sources: [SourceRow]
    let trace: [SearchTraceEvent]?
    /// How many tries the search took; more than one when DuckDuckGo rate-limited an earlier try.
    let attempts: Int
  }

  /// One search's result, with the time of its last try.
  private struct Outcome {
    let results: [WebSearchResult]?
    let failure: Error?
    let milliseconds: Int
    let trace: [SearchTraceEvent]?
    let attempts: Int
  }

  private struct EvidenceRow: Encodable {
    let title: String
    let url: String
    let kind: String
    let text: String
  }

  private struct ContextRow: Encodable {
    let id: String
    let style: String
    let provider: String
    let evidence: [EvidenceRow]
  }

  private struct KeyStore: WebSearchCredentialStore {
    let key: String

    func containsAPIKey() throws -> Bool { true }
    func apiKey() throws -> String? { key }
    func setAPIKey(_ value: String) throws { throw WebSearchError.unavailable }
    func removeAPIKey() throws { throw WebSearchError.unavailable }
  }

  private static let chicago = SearchCoordinate(latitude: 41.88, longitude: -87.63)
  private static let styles = ["typed", "model"]

  func testEvaluation() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let folderPath = environment["ENIGMA_SEARCH_EVAL"], !folderPath.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_SEARCH_EVAL to a folder outside the repository.")
    }
    guard let bundle = SearchDataBundle.bundled else { throw XCTSkip("The search lists aren't bundled.") }
    let questions = try Self.loadQuestions(filter: environment["ENIGMA_SEARCH_EVAL_IDS"])
    XCTAssertFalse(questions.isEmpty)

    let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let runsURL = folder.appending(path: "runs.jsonl"), contextsURL = folder.appending(path: "contexts.jsonl")
    FileManager.default.createFile(atPath: runsURL.path, contents: nil)
    FileManager.default.createFile(atPath: contextsURL.path, contents: nil)
    let runs = try FileHandle(forWritingTo: runsURL), contexts = try FileHandle(forWritingTo: contextsURL)
    defer {
      try? runs.close()
      try? contexts.close()
    }

    let brave = environment["ENIGMA_BRAVE_KEY"].flatMap { $0.isEmpty ? nil : $0 }.map {
      BraveSearchClient(credentials: KeyStore(key: $0), transport: BraveSearchClient.liveTransport)
    }
    for (index, question) in questions.enumerated() {
      for style in Self.styles {
        let request = Self.onDeviceRequest(question, style: style)
        let outcome = await Self.onDeviceSearch(request, bundle: bundle)
        try Self.append(Self.runRow(question, style: style, provider: "onDevice", route: request.route,
                                    outcome: outcome), to: runs)
        try Self.append(Self.contextRow(question, style: style, provider: "onDevice", results: outcome.results),
                        to: contexts)

        if let brave {
          var braveRequest = request
          braveRequest.query = Self.braveQuery(question, style: style)
          braveRequest.route = .web
          braveRequest.namedPlace = nil
          let braveOutcome = await Self.timed { try await brave.search(braveRequest) }
          try Self.append(Self.runRow(question, style: style, provider: "brave", route: .web, outcome: braveOutcome),
                          to: runs)
          try Self.append(Self.contextRow(question, style: style, provider: "brave", results: braveOutcome.results),
                          to: contexts)
        }
        // A short pause between searches, as a person's own pace would give.
        try await Task.sleep(for: .seconds(5))
      }
      print("Evaluated \(index + 1) of \(questions.count) questions.")
    }
  }

  /// One on-device search. DuckDuckGo answers "rateLimited" to searches that come in quick succession,
  /// so a rate-limited search waits 30 s and tries once more, as a person would. The trace and the time
  /// are the last try's.
  private static func onDeviceSearch(_ request: WebSearchRequest, bundle: SearchDataBundle) async -> Outcome {
    var attempt = 1
    while true {
      let recorder = OnDeviceSearchTests.SearchTraceRecorder()
      let provider = onDeviceProvider(bundle: bundle, trace: recorder)
      let outcome = await timed(trace: recorder, attempts: attempt) { try await provider.search(request) }
      if attempt == 1, let failure = outcome.failure as? WebSearchError, failure == .rateLimited {
        try? await Task.sleep(for: .seconds(30))
        attempt += 1
        continue
      }
      return outcome
    }
  }

  private static func timed(trace: OnDeviceSearchTests.SearchTraceRecorder? = nil, attempts: Int = 1,
                            _ search: () async throws -> [WebSearchResult]) async -> Outcome {
    let started = ContinuousClock.now
    var results: [WebSearchResult]?
    var failure: Error?
    do {
      results = try await search()
    } catch {
      failure = error
    }
    let elapsed = started.duration(to: ContinuousClock.now).components
    let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    return Outcome(results: results, failure: failure, milliseconds: milliseconds, trace: trace?.events,
                   attempts: attempts)
  }

  // MARK: Requests

  /// The request the chat would send. Typed: routed as the question is, with the location when the
  /// question needs it. Model: the entry's query, or its tool's arguments.
  private static func onDeviceRequest(_ question: Question, style: String) -> WebSearchRequest {
    let limit = WebSearchLimits.evidenceTokens
    if style == "typed" {
      let decision = SearchRouting.decide(question: question.question)
      var request = WebSearchRequest(query: question.question, route: decision.route, namedPlace: decision.namedPlace,
                                     recency: WebSearchPolicy.recency(question.question), maximumTokens: limit)
      if decision.needsCurrentLocation {
        request.coordinate = chicago
        request.city = "Chicago"
      }
      return request
    }
    guard let tool = question.tool else {
      let query = question.query ?? question.question
      return WebSearchRequest(query: query, route: .web, recency: WebSearchPolicy.recency(query), maximumTokens: limit)
    }
    if tool.name == "find_places" {
      let query = tool.arguments["query"] ?? ""
      if let area = tool.arguments["area"] {
        return WebSearchRequest(query: "\(query) in \(area)", route: .places, maximumTokens: limit)
      }
      return WebSearchRequest(query: query, route: .places, city: "Chicago", coordinate: chicago, maximumTokens: limit)
    }
    let place = tool.arguments["place"]
    var request = WebSearchRequest(query: place.map { "weather \($0)" } ?? "weather Chicago", route: .weather,
                                   namedPlace: place, maximumTokens: limit)
    if place == nil {
      request.city = "Chicago"
      request.coordinate = chicago
    }
    return request
  }

  /// Brave gets the question as text: the typed question, the entry's query, or the tool's words
  /// with "near Chicago" or the named area, as a capable model would search.
  private static func braveQuery(_ question: Question, style: String) -> String {
    if style == "typed" { return question.question }
    guard let tool = question.tool else { return question.query ?? question.question }
    if tool.name == "find_places" {
      return "\(tool.arguments["query"] ?? "") near \(tool.arguments["area"] ?? "Chicago")"
    }
    return "weather \(tool.arguments["place"] ?? "Chicago")"
  }

  @MainActor
  private static func onDeviceProvider(bundle: SearchDataBundle, trace: any SearchTracing) -> OnDeviceSearchProvider {
    let client = URLSessionSearchHTTPClient.live
    let sites = SearchSiteRunner(engines: [.duckDuckGo: DuckDuckGoEngine()], wikipedia: WikipediaSearch(),
                                 client: client, health: EngineHealth(), log: OSSearchLog())
    let quality = SourceQuality(data: bundle, userBlocked: [])
    let reader = PageReader(client: client, networkGuard: NetworkGuard(), isBlocked: { quality.isBlocked($0) })
    return OnDeviceSearchProvider(sites: sites, reader: reader, extractor: ArticleExtractor.shared, quality: { quality },
                                  places: MapKitPlaceSearch(), weather: OpenMeteoWeather(client: client),
                                  geocoder: OpenMeteoGeocoder(client: client), trace: trace)
  }

  // MARK: Rows

  private static func runRow(_ question: Question, style: String, provider: String, route: SearchRoute,
                             outcome: Outcome) -> RunRow {
    let sources = (outcome.results ?? []).map { result in
      SourceRow(url: result.source.url.absoluteString, domain: result.source.url.host() ?? "",
                kind: provider == "brave" ? "snippet" : result.kind.rawValue, title: result.source.title,
                site: result.site, published: result.published.map { ISO8601DateFormatter().string(from: $0) })
    }
    // A search error is recorded by type, never by its text, which could hold the query.
    let error = outcome.failure.map { $0 is WebSearchError ? "\($0)" : String(describing: type(of: $0)) }
    return RunRow(id: question.id, category: question.category, style: style, provider: provider,
                  route: route.rawValue, latencyMs: outcome.milliseconds, error: error, sources: sources,
                  trace: outcome.trace.flatMap { $0.isEmpty ? nil : $0 }, attempts: outcome.attempts)
  }

  private static func contextRow(_ question: Question, style: String, provider: String,
                                 results: [WebSearchResult]?) -> ContextRow {
    let evidence = (results ?? []).map { result in
      EvidenceRow(title: result.source.title, url: result.source.url.absoluteString, kind: result.kind.rawValue,
                  text: result.snippets.joined(separator: "\n\n"))
    }
    return ContextRow(id: question.id, style: style, provider: provider, evidence: evidence)
  }

  private static func append<Row: Encodable>(_ row: Row, to handle: FileHandle) throws {
    var data = try JSONEncoder().encode(row)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  private static func loadQuestions(filter: String?) throws -> [Question] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "scripts/web-search-queries.json")
    let all = try JSONDecoder().decode([Question].self, from: Data(contentsOf: url))
    guard let filter, !filter.isEmpty else { return all }
    let ids = Set(filter.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    return all.filter { ids.contains($0.id) }
  }
}
