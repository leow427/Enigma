import Foundation
import NaturalLanguage

/// Every number the pipeline runs on, for the evaluation (CP7) to measure and change. Spec
/// starting values, moved within the owner's speed bar (median 4.0 s, p90 6.0 s; D2, D73).
enum OnDeviceSearchTiming {
  /// From when the candidates are known (spec 2.5 s).
  static let readingWindow: Duration = .milliseconds(3_000)
  /// Reads running at once (spec §7: at most 6 downloads).
  static let readLimit = 6
  /// Reading stops once this many pages pass the checks (spec 4).
  static let earlyStopPages = 5
  /// One page's extraction (spec 500 ms; 1 MB pages missed it in CP4's live check).
  static let extractionTimeout: Duration = .milliseconds(800)
  /// Candidates under this share of the top score are dropped (spec and `RankingTuning.cutoff` 0.15).
  static let rankingCutoff = 0.08
  /// The snippet fallback's total, read pages and Wikipedia included (spec §3.5).
  static let snippetFallbackSources = 4
  static let tokensPerWord = 1.4
  /// Passages are collected up to this multiple of the request's tokens; `WebSearchContext`
  /// trims with the model's tokenizer (spec §5).
  static let collectionAllowance = 1.5
  /// Words lemmatized and scored per page; later passages score 0.
  static let maximumWordsScoredPerPage = 15_000
  /// Spec §2's cap on what goes to the search sites.
  static let maximumQueryWords = 50
  static let maximumQueryCharacters = 400
}

/// One candidate's outcome in a search, for the evaluation (F29 CP7). Production passes no
/// recorder, so nothing is recorded or kept.
struct SearchTraceEvent: Codable, Equatable, Sendable {
  let url: String
  let domain: String
  /// The engine's best position, by engine ID.
  let positions: [String: Int]
  /// The merged score before the trust factor, and the trust factor.
  let score: Double
  let trustFactor: Double
  /// "read", "snippet", "blocked", "cutoff", "notArticle", "wall", "offTopic", "duplicate",
  /// "wrongLanguage" or "unread".
  let verdict: String
}

protocol SearchTracing: Sendable {
  func record(_ event: SearchTraceEvent)
  /// What each lane answered, merged into what earlier calls recorded: "duckDuckGo",
  /// "duckDuckGo#2" (the second query), "retry", "wikipedia", "wikidata", "googleNews" →
  /// "results:N" or the outcome's name. No query or result text (D111).
  func recordSites(_ outcomes: [String: String])
  /// A helper step's time and outcome: "rewrite" (model, fallback, timeout, junk, failed,
  /// asWritten) and "check" (yes, no, junk, timeout, failed, skipped). No query text (D111).
  func recordStep(_ step: String, milliseconds: Int, outcome: String)
}

extension SearchTracing {
  func recordSites(_ outcomes: [String: String]) {}
  func recordStep(_ step: String, milliseconds: Int, outcome: String) {}
}

/// Wikidata's facts and Google News's headlines, with the client they use (D109, D110).
struct ExtraSearchSources: Sendable {
  let facts: WikidataFacts
  let news: GoogleNewsSearch
  let client: any SearchHTTPClient
  /// Wikidata's lookup takes up to four requests.
  var factsTimeout: Duration = .milliseconds(2_500)
  var newsTimeout: Duration = SearchSiteRunner.primaryTimeout
}

/// Searches the web from the Mac (spec §1, §3, §5): the search sites, ranking, reading pages
/// within a window, the checks after reading, and passages. Weather comes from Open-Meteo alone,
/// and places from Apple Maps with a web search beside it (spec §6.4, §6.5).
struct OnDeviceSearchProvider: WebSearchProvider {
  private let sites: SearchSiteRunner
  private let reader: PageReader
  private let extractor: any ArticleExtracting
  private let quality: @Sendable () async throws -> SourceQuality
  private let preferredLanguages: @Sendable () -> [String]
  private let clock: any Clock<Duration>
  private let now: @Sendable () -> Date
  private let places: any PlaceSearching
  private let weather: any WeatherLooking
  private let geocoder: any Geocoding
  private let units: @Sendable () -> MeasurementUnits
  private let trace: (any SearchTracing)?
  private let extras: ExtraSearchSources?
  /// Queries the model's rewrite may send to DuckDuckGo. The product value is the default; the
  /// evaluation overrides it to measure one query against two (D116).
  private let maximumSiteQueries: Int

  init(sites: SearchSiteRunner, reader: PageReader, extractor: any ArticleExtracting,
       quality: @escaping @Sendable () async throws -> SourceQuality,
       preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
       clock: any Clock<Duration> = ContinuousClock(),
       now: @escaping @Sendable () -> Date = Date.init,
       places: any PlaceSearching = MapKitPlaceSearch(),
       weather: any WeatherLooking = OpenMeteoWeather(),
       geocoder: any Geocoding = OpenMeteoGeocoder(),
       units: @escaping @Sendable () -> MeasurementUnits = { .current },
       trace: (any SearchTracing)? = nil, extras: ExtraSearchSources? = nil,
       maximumSiteQueries: Int = SearchAssistTuning.maximumSiteQueries) {
    self.sites = sites
    self.reader = reader
    self.extractor = extractor
    self.quality = quality
    self.preferredLanguages = preferredLanguages
    self.clock = clock
    self.now = now
    self.places = places
    self.weather = weather
    self.geocoder = geocoder
    self.units = units
    self.trace = trace
    self.extras = extras
    self.maximumSiteQueries = maximumSiteQueries
  }

  @MainActor static func live(trace: (any SearchTracing)? = nil) -> OnDeviceSearchProvider {
    let client = URLSessionSearchHTTPClient.live
    let sites = SearchSiteRunner(engines: [.duckDuckGo: DuckDuckGoEngine()], wikipedia: WikipediaSearch(),
                                 client: client, health: .shared, log: OSSearchLog())
    let quality: @Sendable () async throws -> SourceQuality = {
      guard let bundle = SearchDataBundle.bundled else { throw WebSearchError.unavailable }
      let blocked = await MainActor.run { Set(WebSearchSettings.shared.blockedSites) }
      return SourceQuality(data: bundle, userBlocked: blocked)
    }
    // The reader asks the same lists, loaded with the user's blocked sites at each search.
    let blockedCheck = BlockedCheck()
    let reader = PageReader(client: client, networkGuard: NetworkGuard(), isBlocked: { blockedCheck.isBlocked($0) })
    return OnDeviceSearchProvider(sites: sites, reader: reader, extractor: ArticleExtractor.shared, quality: {
      let current = try await quality()
      blockedCheck.set(current)
      return current
    }, places: MapKitPlaceSearch(), weather: OpenMeteoWeather(client: client), geocoder: OpenMeteoGeocoder(client: client),
       trace: trace, extras: ExtraSearchSources(facts: WikidataFacts(), news: GoogleNewsSearch(), client: client))
  }

  func search(_ request: WebSearchRequest) async throws -> [WebSearchResult] {
    try await search(request, assistant: nil, onActivity: { _ in })
  }

  func search(_ request: WebSearchRequest,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    try await search(request, assistant: nil, onActivity: onActivity)
  }

  func search(_ request: WebSearchRequest, assistant: (any SearchModelAssistant)?,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    switch request.route {
    case .web: return try await searchWeb(request, assistant: assistant, onActivity: onActivity)
    case .weather: return try await searchWeather(request, onActivity: onActivity)
    case .places: return try await searchPlaces(request, assistant: assistant, onActivity: onActivity)
    }
  }

  // MARK: Weather and places

  /// Open-Meteo only, for the location's coordinate or the geocoded named place; no search site is
  /// contacted. Any failure, or a place the geocoder can't find, web-searches "weather <place>".
  private func searchWeather(_ request: WebSearchRequest,
                             onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    let place = request.namedPlace ?? request.city
    var fallback = request
    fallback.route = .web
    fallback.namedPlace = nil
    fallback.query = place.map { "weather " + $0 } ?? request.query
    fallback.isTypedQuestion = place == nil && request.isTypedQuestion
    do {
      let coordinate: SearchCoordinate
      let name: String
      if let known = request.coordinate {
        coordinate = known
        name = request.city ?? "your area"
      } else if let namedPlace = request.namedPlace, let found = try await geocoder.locate(namedPlace) {
        coordinate = found.coordinate
        name = found.name
      } else {
        return try await searchWeb(fallback, assistant: nil, onActivity: onActivity)
      }
      let forecast = try await weather.forecast(at: coordinate, units: units())
      try Task.checkCancellation()
      let result = WeatherLookup.excerpt(forecast, placeName: name, now: now())
      await onActivity(.sourcesDiscovered([result.source]))
      return [result]
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return try await searchWeb(fallback, assistant: nil, onActivity: onActivity)
    }
  }

  /// Apple Maps and the web route at the same time; the places result comes first. MapKit gets the
  /// question without its nearby cues and the rounded location, or the named area in the query;
  /// the search sites get only the city. A MapKit failure or no places leaves the web results.
  private func searchPlaces(_ request: WebSearchRequest, assistant: (any SearchModelAssistant)?,
                            onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    let mapQuery = SearchRouting.webQuery(request.query, city: nil)
    var web = request
    web.route = .web
    async let found: [PlaceResult]? = { [places] in
      guard !mapQuery.isEmpty else { return nil }
      return try? await places.places(matching: mapQuery, near: request.coordinate)
    }()
    let webResults: Result<[WebSearchResult], any Error>
    do {
      webResults = .success(try await searchWeb(web, assistant: assistant, onActivity: onActivity))
    } catch {
      webResults = .failure(error)
    }
    let mapResults = await found ?? []
    try Task.checkCancellation()
    guard !mapResults.isEmpty else { return try webResults.get() }
    let excerpt = PlaceSearch.excerpt(mapResults, query: mapQuery, units: units())
    await onActivity(.sourcesDiscovered([excerpt.source]))
    return [excerpt] + ((try? webResults.get()) ?? [])
  }

  // MARK: The web route

  private func searchWeb(_ request: WebSearchRequest, assistant: (any SearchModelAssistant)?,
                         onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult] {
    await extractor.warmUp()
    let quality = try await self.quality()
    let languages = preferredLanguages()
    let text = Self.siteQuery(SearchRouting.webQuery(request.query, city: request.city))
    guard !text.isEmpty else { throw WebSearchError.emptyQuery }

    // 0. The queries: the typed question as keywords, by the model or the clean-up (D107).
    let plan = await queryPlan(request, siteText: text, assistant: assistant)
    // A stop during the rewrite sends nothing further (D124).
    try Task.checkCancellation()
    let region = SearchRegion.current()
    var siteOutcomes: [String: String] = [:]

    // Wikidata and Google News run beside the sites (D109, D110); Wikidata starts now when the
    // rewrite named an entity, or after the sites from Wikipedia's article.
    var factsTask: Task<WikidataEntityFacts?, Never>?
    if let entity = plan.entity { factsTask = startFacts(entity: entity, wikipediaTitle: nil, languages: languages) }
    let newsTask: Task<[NewsHeadline]?, Never>? = extras.flatMap { extras in
      // Google never receives a location: a request with a city skips the headlines (D122).
      // A user who blocked Google News never has it asked (D125).
      guard request.city == nil, !quality.isBlocked(GoogleNewsSearch.homeURL),
            GoogleNewsSearch.applies(question: request.query, recency: request.recency) else {
        return nil
      }
      let query = plan.queries[0]
      return Task { [clock] in
        await Self.withTimeout(extras.newsTimeout, clock: clock) {
          await extras.news.search(query, region: region, using: extras.client)
        } ?? nil
      }
    }
    defer {
      factsTask?.cancel()
      newsTask?.cancel()
    }

    // 1–2. The sites, one run per query at once (the sites pace themselves). Wikipedia gets the
    // first query, and isn't asked for day or week questions.
    let runs = await withTaskGroup(of: (Int, SiteRunResult).self) { group in
      for (index, query) in plan.queries.enumerated() {
        group.addTask { [sites] in
          (index, await sites.run(EngineQuery(text: query, region: region, recency: request.recency),
                                  includeWikipedia: index == 0 && request.recency != .day && request.recency != .week,
                                  preferredLanguages: languages))
        }
      }
      var results: [Int: SiteRunResult] = [:]
      for await (index, run) in group { results[index] = run }
      return plan.queries.indices.compactMap { results[$0] }
    }
    try Task.checkCancellation()
    let run = runs[0]
    for (index, eachRun) in runs.enumerated() {
      for (engine, outcome) in eachRun.outcomes {
        siteOutcomes[engine.rawValue + (index == 0 ? "" : "#\(index + 1)")] = Self.outcomeName(outcome)
      }
    }
    switch run.wikipedia {
    case .article: siteOutcomes["wikipedia"] = "results:1"
    case WikipediaOutcome.none:
      siteOutcomes["wikipedia"] = request.recency == .day || request.recency == .week ? "skipped" : "noResults"
    case .failed: siteOutcomes["wikipedia"] = "failed"
    }
    trace?.recordSites(siteOutcomes)
    let foundLists = runs.map { eachRun in
      eachRun.outcomes.values.flatMap { outcome -> [EngineResult] in
        if case .results(let results) = outcome { return results }
        return []
      }
    }
    let found = foundLists.flatMap { $0 }
    var wikipedia: WikipediaArticle?
    if case .article(let article) = run.wikipedia { wikipedia = article }

    // 3–4. Ranking, and Wikipedia's lane when it shares a content word with the question.
    let merged = Self.fuse(foundLists.map { ResultRanking.merge($0, weights: RankingTuning.engineWeights, quality: quality) })
    let selection = ResultRanking.select(merged, quality: quality, cutoff: OnDeviceSearchTiming.rankingCutoff)
    let questionLemmas = PassageRanker.contentLemmas(request.query)
    if let article = wikipedia,
       quality.isBlocked(article.url) || !Self.shares(article, questionLemmas) { wikipedia = nil }
    if factsTask == nil, let article = wikipedia {
      factsTask = startFacts(entity: nil, wikipediaTitle: article.title, languages: languages)
    }
    if found.isEmpty, wikipedia == nil, factsTask == nil, newsTask == nil { throw Self.failure(run) }

    // 5. Report.
    let toRead = selection.readQueue
    await onActivity(.sourcesDiscovered(toRead.prefix(OnDeviceSearchTiming.readLimit).map(Self.source)
                                        + (wikipedia.map { [WebSearchSource(title: $0.title, url: $0.url)] } ?? [])))
    try Task.checkCancellation()

    // 6. Read within the window.
    let allowed = Self.allowedLanguages(question: request.query, preferred: languages)
    let outcomes = await read(toRead, allowedLanguages: allowed, window: OnDeviceSearchTiming.readingWindow)
    try Task.checkCancellation()

    var sources: [Source] = toRead.indices.compactMap { index in
      guard case .passed(let page)? = outcomes[index] else { return nil }
      return Source(kind: .article, candidate: toRead[index], page: page)
    }
    if let article = wikipedia, let page = Self.wikipediaPage(article, allowedLanguages: allowed) {
      sources.append(Source(kind: .wikipedia, candidate: nil, page: page))
    }

    // Wikidata's facts when the entity shares a content word with the question; the headlines.
    var excerpts: [WebSearchResult] = []
    if let factsTask {
      let facts = await Self.value(of: factsTask)
      siteOutcomes["wikidata"] = facts.map { "results:\($0.facts.count)" } ?? "noResults"
      if let facts, !quality.isBlocked(facts.url),
         !PassageRanker.contentLemmas(facts.label).isDisjoint(with: questionLemmas) {
        excerpts.append(WikidataFacts.excerpt(facts))
      }
    }
    if let newsTask {
      let headlines = await Self.value(of: newsTask)
      siteOutcomes["googleNews"] = headlines.map { $0.isEmpty ? "noResults" : "results:\($0.count)" } ?? "failed"
      // Headlines from a blocked or unsafe publisher are dropped (D125).
      let kept = (headlines ?? []).filter { headline in headline.publisherURL.map { !quality.isBlocked($0) } ?? true }
      if !kept.isEmpty { excerpts.append(GoogleNewsSearch.excerpt(kept)) }
    }
    trace?.recordSites(siteOutcomes)
    try Task.checkCancellation()

    // 7–9. Near-duplicates, passages, the off-topic check, the order and the snippet fallback.
    var assembled = assemble(sources, toRead: toRead, outcomes: outcomes, snippetOnly: selection.snippetOnly,
                             request: request, questionLemmas: questionLemmas, quality: quality)

    // The "enough?" check and its one retry, on the small-model path only (D108).
    if let assistant, request.isTypedQuestion {
      if let missing = await check(request.query, ordered: assembled.ordered, excerpts: excerpts, assistant: assistant) {
        let retryQuery = Self.siteQuery(plan.queries[0] + " " + missing)
        let retryRun = await sites.run(EngineQuery(text: retryQuery, region: region, recency: request.recency),
                                       includeWikipedia: false, preferredLanguages: languages)
        try Task.checkCancellation()
        for (_, outcome) in retryRun.outcomes { siteOutcomes["retry"] = Self.outcomeName(outcome) }
        trace?.recordSites(siteOutcomes)
        let retryFound = retryRun.outcomes.values.flatMap { outcome -> [EngineResult] in
          if case .results(let results) = outcome { return results }
          return []
        }
        let seen = Set(merged.map { URLNormalizer.key($0.url) })
        let fresh = ResultRanking.select(ResultRanking.merge(retryFound, weights: RankingTuning.engineWeights,
                                                             quality: quality),
                                         quality: quality, cutoff: OnDeviceSearchTiming.rankingCutoff)
          .readQueue.filter { !seen.contains(URLNormalizer.key($0.url)) }
        if !fresh.isEmpty {
          await onActivity(.sourcesDiscovered(fresh.prefix(OnDeviceSearchTiming.readLimit).map(Self.source)))
          let freshOutcomes = await read(fresh, allowedLanguages: allowed, window: SearchAssistTuning.retryReadingWindow)
          try Task.checkCancellation()
          let added: [Source] = fresh.indices.compactMap { index in
            guard case .passed(let page)? = freshOutcomes[index] else { return nil }
            return Source(kind: .article, candidate: fresh[index], page: page)
          }
          if !added.isEmpty {
            assembled = assemble(sources + added, toRead: toRead, outcomes: outcomes,
                                 snippetOnly: selection.snippetOnly, request: request, questionLemmas: questionLemmas,
                                 quality: quality)
          }
        }
      }
    }
    let ordered = assembled.ordered

    // Nothing left: when the sites themselves failed, say so rather than "no results" (D77).
    guard !ordered.isEmpty || !excerpts.isEmpty else { throw found.isEmpty ? Self.failure(run) : WebSearchError.noResults }
    if !excerpts.isEmpty { await onActivity(.sourcesDiscovered(excerpts.map(\.source))) }

    // 10. Results within the budget; Wikidata's facts and the headlines first.
    if let trace {
      let kept = Set(ordered.compactMap { entry -> String? in
        guard entry.source.kind == .article, let candidate = entry.source.candidate else { return nil }
        return URLNormalizer.key(candidate.url)
      })
      let snippets = Set(ordered.compactMap { entry -> String? in
        guard entry.source.kind == .snippet, let candidate = entry.source.candidate else { return nil }
        return URLNormalizer.key(candidate.url)
      })
      Self.record(trace, merged: merged, quality: quality, selection: selection, toRead: toRead, outcomes: outcomes,
                  deduplicated: assembled.deduplicated, kept: kept, snippets: snippets)
    }
    return excerpts + Self.collect(ordered, maximumTokens: request.maximumTokens)
  }

  // MARK: The helper calls (D107, D108)

  /// The typed question's keyword queries; any other query as written.
  private func queryPlan(_ request: WebSearchRequest, siteText: String,
                         assistant: (any SearchModelAssistant)?) async -> SearchQueryPlan {
    // A query a model wrote, and the places route's "near <city>" query, go as written.
    guard request.isTypedQuestion, request.city == nil else {
      return SearchQueryPlan(queries: [siteText], entity: nil, outcome: "asWritten")
    }
    let cleaned = Self.siteQuery(SearchQueryRewrite.keywords(siteText))
    let fallback = cleaned.isEmpty ? siteText : cleaned
    guard let assistant else {
      trace?.recordStep("rewrite", milliseconds: 0, outcome: "fallback")
      return SearchQueryPlan(queries: [fallback], entity: nil, outcome: "fallback")
    }
    let started = ContinuousClock.now
    let reply = await SearchAssistCall.run(assistant, prompt: SearchQueryRewrite.prompt(question: siteText, today: now()),
                                           maximumTokens: SearchAssistTuning.rewriteTokens,
                                           timeout: SearchAssistTuning.rewriteTimeout, clock: clock)
    let milliseconds = Self.milliseconds(since: started)
    switch reply {
    case .value(let output):
      guard let parsed = SearchQueryRewrite.parse(output) else {
        trace?.recordStep("rewrite", milliseconds: milliseconds, outcome: "junk")
        return SearchQueryPlan(queries: [fallback], entity: nil, outcome: "junk")
      }
      trace?.recordStep("rewrite", milliseconds: milliseconds, outcome: "model")
      let queries = parsed.queries.prefix(maximumSiteQueries).map(Self.siteQuery)
        .filter { !$0.isEmpty }
      return SearchQueryPlan(queries: queries.isEmpty ? [fallback] : Array(queries), entity: parsed.entity,
                             outcome: "model")
    case .timeout:
      trace?.recordStep("rewrite", milliseconds: milliseconds, outcome: "timeout")
      return SearchQueryPlan(queries: [fallback], entity: nil, outcome: "timeout")
    case .failed:
      trace?.recordStep("rewrite", milliseconds: milliseconds, outcome: "failed")
      return SearchQueryPlan(queries: [fallback], entity: nil, outcome: "failed")
    }
  }

  /// The missing words when the model says the passages don't answer the question; nil otherwise.
  private func check(_ question: String, ordered: [(source: Source, passages: [Passage])], excerpts: [WebSearchResult],
                     assistant: any SearchModelAssistant) async -> String? {
    // Page passages fill the word budget first, then the facts and headlines (D122).
    var shown: [(title: String, text: String)] = ordered.map { entry in
      (entry.source.page?.article.title ?? entry.source.candidate?.title ?? "",
       entry.passages.prefix(2).map(\.text).joined(separator: " "))
    }
    shown += excerpts.map { ($0.source.title, $0.snippets.joined(separator: " ")) }
    guard !shown.isEmpty else {
      trace?.recordStep("check", milliseconds: 0, outcome: "skipped")
      return nil
    }
    let started = ContinuousClock.now
    let reply = await SearchAssistCall.run(assistant, prompt: SearchSufficiencyCheck.prompt(question: question, sources: shown),
                                           maximumTokens: SearchAssistTuning.checkTokens,
                                           timeout: SearchAssistTuning.checkTimeout, clock: clock)
    let milliseconds = Self.milliseconds(since: started)
    switch reply {
    case .value(let output):
      switch SearchSufficiencyCheck.parse(output) {
      case .enough?:
        trace?.recordStep("check", milliseconds: milliseconds, outcome: "yes")
        return nil
      case .missing(let words)?:
        trace?.recordStep("check", milliseconds: milliseconds, outcome: "no")
        return words
      case nil:
        trace?.recordStep("check", milliseconds: milliseconds, outcome: "junk")
        return nil
      }
    case .timeout:
      trace?.recordStep("check", milliseconds: milliseconds, outcome: "timeout")
      return nil
    case .failed:
      trace?.recordStep("check", milliseconds: milliseconds, outcome: "failed")
      return nil
    }
  }

  private func startFacts(entity: String?, wikipediaTitle: String?, languages: [String]) -> Task<WikidataEntityFacts?, Never>? {
    guard let extras else { return nil }
    return Task { [clock] in
      await Self.withTimeout(extras.factsTimeout, clock: clock) {
        await extras.facts.lookup(entity: entity, wikipediaTitle: wikipediaTitle, preferredLanguages: languages,
                                  using: extras.client)
      } ?? nil
    }
  }

  /// Steps 7–9 over the read sources: near-duplicates, passages and order, and snippets when fewer
  /// than 2 pages pass.
  private func assemble(_ sources: [Source], toRead: [RankedCandidate], outcomes: [Int: ReadOutcome],
                        snippetOnly: [RankedCandidate], request: WebSearchRequest, questionLemmas: Set<String>,
                        quality: SourceQuality)
    -> (ordered: [(source: Source, passages: [Passage])], deduplicated: Set<String>) {
    // 7. Near-duplicates: the less trusted copy goes, or the lower score; Wikipedia stays.
    let kept = dropDuplicates(sources, quality: quality)
    let deduplicated = Set(kept.compactMap { $0.candidate.map { URLNormalizer.key($0.url) } })

    // 8. Passages, the off-topic check and the order.
    var ordered = order(kept, question: request.query, questionLemmas: questionLemmas, recency: request.recency)

    // 9. Snippets when fewer than 2 pages pass.
    let passingPages = ordered.filter { $0.source.kind == .article }.count
    if passingPages < 2 {
      let excluded = Set(ordered.compactMap { $0.source.candidate.map { URLNormalizer.key($0.url) } })
      let snippets = Self.snippetCandidates(toRead, outcomes: outcomes, snippetOnly: snippetOnly)
        .filter { !excluded.contains(URLNormalizer.key($0.url)) }
      for candidate in snippets.prefix(max(0, OnDeviceSearchTiming.snippetFallbackSources - ordered.count)) {
        ordered.append((source: Source(kind: .snippet, candidate: candidate, page: nil),
                        passages: [Passage(text: candidate.snippet, order: 0)]))
      }
    }
    return (ordered, deduplicated)
  }

  /// Several queries' merged lists as one: positions merged, scores summed per URL — reciprocal-rank
  /// fusion with k = 0, matching each list's own `weight / position` score — so one list keeps its
  /// order and scores exactly (D107).
  static func fuse(_ lists: [[RankedCandidate]]) -> [RankedCandidate] {
    guard lists.count > 1 else { return lists.first ?? [] }
    var order: [String] = []
    var fused: [String: RankedCandidate] = [:]
    for list in lists {
      for candidate in list {
        let key = URLNormalizer.key(candidate.url)
        guard var existing = fused[key] else {
          fused[key] = candidate
          order.append(key)
          continue
        }
        existing.score += candidate.score
        if candidate.title.count > existing.title.count { existing.title = candidate.title }
        if candidate.snippet.count > existing.snippet.count { existing.snippet = candidate.snippet }
        for (engine, position) in candidate.positions {
          existing.positions[engine] = min(existing.positions[engine] ?? .max, position)
        }
        fused[key] = existing
      }
    }
    return order.enumerated().compactMap { offset, key in fused[key].map { (offset, $0) } }
      .sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }
      .map(\.1)
  }

  /// The task's value; cancelling the search cancels the task too (D124).
  private static func value<T: Sendable>(of task: Task<T, Never>) async -> T {
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  private static func outcomeName(_ outcome: EngineOutcome) -> String {
    if case .results(let results) = outcome { return "results:\(results.count)" }
    return "\(outcome)"
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: .now).components
    return Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
  }

  /// The operation's value, or nil once `timeout` passes; the loser is cancelled.
  private static func withTimeout<T: Sendable>(_ timeout: Duration, clock: any Clock<Duration>,
                                               _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await operation() }
      group.addTask {
        try? await clock.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  // MARK: Steps

  /// One event per candidate the ranking saw. Verdicts are the pipeline's own outcomes.
  private static func record(_ trace: any SearchTracing, merged: [RankedCandidate], quality: SourceQuality,
                             selection: ResultRanking.Selection, toRead: [RankedCandidate],
                             outcomes: [Int: ReadOutcome], deduplicated: Set<String>, kept: Set<String>,
                             snippets: Set<String>) {
    var readIndex: [String: Int] = [:]
    for (index, candidate) in toRead.enumerated() { readIndex[URLNormalizer.key(candidate.url)] = index }
    let snippetOnly = Set(selection.snippetOnly.map { URLNormalizer.key($0.url) })
    for candidate in merged {
      let key = URLNormalizer.key(candidate.url)
      let verdict: String
      if quality.isBlocked(candidate.url) {
        verdict = "blocked"
      } else if let index = readIndex[key] {
        switch outcomes[index] {
        case .passed?:
          verdict = kept.contains(key) ? "read" : (deduplicated.contains(key) ? "offTopic" : "duplicate")
        case .rejected(let page)?:
          verdict = verdictName(page)
        case .refused?:
          verdict = "blocked"
        case .unread?, nil:
          verdict = snippets.contains(key) ? "snippet" : "unread"
        }
      } else if snippetOnly.contains(key) {
        verdict = snippets.contains(key) ? "snippet" : "unread"
      } else {
        verdict = "cutoff"
      }
      var positions: [String: Int] = [:]
      for (engine, position) in candidate.positions { positions[engine.rawValue] = position }
      trace.record(SearchTraceEvent(url: candidate.url.absoluteString, domain: candidate.domain, positions: positions,
                                    score: candidate.score, trustFactor: quality.trustFactor(for: candidate.url),
                                    verdict: verdict))
    }
  }

  private static func verdictName(_ verdict: PageVerdict) -> String {
    switch verdict {
    case .keep: "read"
    case .notArticle: "notArticle"
    case .wall: "wall"
    case .wrongLanguage: "wrongLanguage"
    case .offTopic: "offTopic"
    case .duplicate: "duplicate"
    }
  }

  /// A read page or Wikipedia's article, ready for passages.
  struct ReadPage: Sendable {
    let url: URL
    let article: ExtractedArticle
    let passages: [Passage]
  }

  enum ReadOutcome: Sendable {
    case passed(ReadPage)
    /// The checks turned it down; its snippet stays usable for a wall or a non-article.
    case rejected(PageVerdict)
    /// Not read: a network or HTTP failure, a skipped type, an extraction failure. Snippet usable.
    case unread
    /// The guard or the blocklist refused it: neither the page nor its snippet (D64).
    case refused
  }

  struct Source: Sendable {
    let kind: EvidenceKind
    let candidate: RankedCandidate?
    let page: ReadPage?
  }

  private enum ReadEvent: Sendable {
    case read(Int, ReadOutcome)
    case windowEnded
  }

  /// Keeps up to `readLimit` reads running, within `readingWindow`. A failure starts the next
  /// candidate; `earlyStopPages` passes, the window's end or cancellation stops every read.
  private func read(_ queue: [RankedCandidate], allowedLanguages: Set<String>,
                    window: Duration) async -> [Int: ReadOutcome] {
    guard !queue.isEmpty else { return [:] }
    return await withTaskGroup(of: ReadEvent.self) { group in
      group.addTask { [clock] in
        try? await clock.sleep(for: window)
        return .windowEnded
      }
      var outcomes: [Int: ReadOutcome] = [:]
      var next = 0, running = 0, passed = 0
      while next < queue.count, running < OnDeviceSearchTiming.readLimit {
        let index = next, candidate = queue[index]
        group.addTask { .read(index, await readPage(candidate, allowedLanguages: allowedLanguages)) }
        next += 1
        running += 1
      }
      while let event = await group.next() {
        guard case .read(let index, let outcome) = event else { break }
        running -= 1
        outcomes[index] = outcome
        if case .passed = outcome {
          passed += 1
          if passed >= OnDeviceSearchTiming.earlyStopPages { break }
        } else if next < queue.count, !Task.isCancelled {
          let start = next, candidate = queue[start]
          group.addTask { .read(start, await readPage(candidate, allowedLanguages: allowedLanguages)) }
          next += 1
          running += 1
        }
        if running == 0 { break }
      }
      group.cancelAll()
      return outcomes
    }
  }

  private func readPage(_ candidate: RankedCandidate, allowedLanguages: Set<String>) async -> ReadOutcome {
    let fetched: FetchedPage
    switch await reader.fetch(candidate.url) {
    case .page(let page): fetched = page
    case .refused: return .refused
    case .failed, .skipped: return .unread
    }
    guard !Task.isCancelled else { return .unread }
    let article: ExtractedArticle
    switch fetched.format {
    case .html:
      do { article = try await extractor.extract(html: fetched.content, url: fetched.finalURL) } catch { return .unread }
    case .text:
      article = ExtractedArticle(title: candidate.title, siteName: nil, byline: nil, language: nil, published: nil,
                                 blocks: PassageRanker.paragraphBlocks(fetched.content), isReaderable: true)
    }
    let verdict = PageChecks.basic(article, isWikipedia: false, allowedLanguages: allowedLanguages)
    guard verdict == .keep else { return .rejected(verdict) }
    let passages = fetched.format == .html ? PassageRanker.passages(from: article.blocks)
      : PassageRanker.passages(fromPlainText: fetched.content)
    return .passed(ReadPage(url: fetched.finalURL, article: article, passages: passages))
  }

  private static func wikipediaPage(_ article: WikipediaArticle, allowedLanguages: Set<String>) -> ReadPage? {
    let blocks = PassageRanker.paragraphBlocks(article.text, lineBreaks: true)
    let extracted = ExtractedArticle(title: article.title, siteName: "Wikipedia", byline: nil, language: nil,
                                     published: nil, blocks: blocks, isReaderable: true)
    guard PageChecks.basic(extracted, isWikipedia: true, allowedLanguages: allowedLanguages) == .keep else { return nil }
    return ReadPage(url: article.url, article: extracted, passages: PassageRanker.passages(from: blocks))
  }

  private func dropDuplicates(_ sources: [Source], quality: SourceQuality) -> [Source] {
    let shingles = sources.map { source in
      PageChecks.shingles(source.page?.article.blocks.map(\.text).joined(separator: "\n") ?? "")
    }
    var dropped = Set<Int>()
    for first in sources.indices where !dropped.contains(first) {
      for second in sources.indices where second > first && !dropped.contains(second) {
        guard PageChecks.jaccard(shingles[first], shingles[second]) >= PageChecks.duplicateThreshold else { continue }
        dropped.insert(loser(sources[first], first, sources[second], second, quality: quality))
        if dropped.contains(first) { break }
      }
    }
    return sources.indices.filter { !dropped.contains($0) }.map { sources[$0] }
  }

  /// Wikipedia always stays; otherwise the lower trust factor, then the lower score, then the
  /// later one goes.
  private func loser(_ a: Source, _ aIndex: Int, _ b: Source, _ bIndex: Int, quality: SourceQuality) -> Int {
    if a.kind == .wikipedia { return bIndex }
    if b.kind == .wikipedia { return aIndex }
    let aTrust = a.page.map { quality.trustFactor(for: $0.url) } ?? 1
    let bTrust = b.page.map { quality.trustFactor(for: $0.url) } ?? 1
    if aTrust != bTrust { return aTrust > bTrust ? bIndex : aIndex }
    let aScore = a.candidate?.score ?? 0, bScore = b.candidate?.score ?? 0
    if aScore != bScore { return aScore > bScore ? bIndex : aIndex }
    return bIndex
  }

  /// Scores passages over every source, drops off-topic pages while 2 others remain, and orders
  /// sources by (search score) × (best passage ÷ overall best) × (stale factor).
  private func order(_ sources: [Source], question: String, questionLemmas: Set<String>,
                     recency: SearchRecency?) -> [(source: Source, passages: [Passage])] {
    guard !sources.isEmpty else { return [] }
    let scored = PassageRanker.scoreWithLemmas(sources.map { $0.page?.passages ?? [] }, question: question,
                                               wordLimit: OnDeviceSearchTiming.maximumWordsScoredPerPage)
    let bests = scored.pages.map { $0.map(\.score).max() ?? 0 }
    let overallBest = bests.max() ?? 0
    var kept = Array(sources.indices)
    // Worst-ranked first, so the check never drops below 2 other pages.
    for index in sources.indices.reversed() where kept.count - 1 >= 2 {
      if PageChecks.isOffTopic(bestPassageScore: bests[index], overallBestScore: overallBest,
                               pageLemmas: scored.pageLemmas[index], questionLemmas: questionLemmas) {
        kept.removeAll { $0 == index }
      }
    }
    let topScore = sources.compactMap { $0.candidate?.score }.max() ?? 1
    let date = now()
    let ranked = kept.map { index -> (index: Int, score: Double) in
      let source = sources[index]
      let match = overallBest > 0 ? bests[index] / overallBest : 1
      let article = source.page?.article
      let stale = PageChecks.staleFactor(published: article?.published ?? article?.modified, recency: recency, now: date)
      return (index, (source.candidate?.score ?? topScore) * match * stale)
    }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    return ranked.map { (source: sources[$0.index], passages: PassageRanker.ordered(scored.pages[$0.index])) }
  }

  /// Unread, failed, wall and not-an-article candidates, and snippet-only ones, best first;
  /// never refused, off-topic, duplicate or wrong-language ones (D74).
  private static func snippetCandidates(_ queue: [RankedCandidate], outcomes: [Int: ReadOutcome],
                                        snippetOnly: [RankedCandidate]) -> [RankedCandidate] {
    let fromQueue = queue.indices.compactMap { index -> RankedCandidate? in
      switch outcomes[index] {
      case nil, .unread?: return queue[index]
      case .rejected(let verdict)? where verdict == .wall || verdict == .notArticle: return queue[index]
      default: return nil
      }
    }
    return (fromQueue + snippetOnly)
      .filter { !$0.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
      .map(\.element)
  }

  /// Round-robin: each source's best passage, then each one's second, and so on, until the
  /// estimated tokens reach `collectionAllowance` × the budget; each source stops at
  /// `WebSearchLimits.tokensPerSource` (D74).
  static func collect(_ ordered: [(source: Source, passages: [Passage])], maximumTokens: Int) -> [WebSearchResult] {
    let budget = Double(maximumTokens) * OnDeviceSearchTiming.collectionAllowance / OnDeviceSearchTiming.tokensPerWord
    let perSource = Double(WebSearchLimits.tokensPerSource) / OnDeviceSearchTiming.tokensPerWord
    var taken = Array(repeating: [String](), count: ordered.count)
    var sourceWords = Array(repeating: 0, count: ordered.count)
    var total = 0
    var round = 0
    var progressed = true
    collecting: while progressed {
      progressed = false
      for index in ordered.indices where round < ordered[index].passages.count {
        guard Double(total) < budget else { break collecting }
        let passage = ordered[index].passages[round].text
        let words = TextWords.count(in: passage)
        guard sourceWords[index] == 0 || Double(sourceWords[index] + words) <= perSource else { continue }
        taken[index].append(passage)
        sourceWords[index] += words
        total += words
        progressed = true
      }
      round += 1
    }
    return ordered.indices.compactMap { index in
      guard !taken[index].isEmpty else { return nil }
      let (source, _) = ordered[index]
      let text = taken[index].joined(separator: "\n…\n")
      switch source.kind {
      case .snippet:
        let candidate = source.candidate!
        return WebSearchResult(source: Self.source(candidate), snippets: [text], site: candidate.domain, kind: .snippet)
      default:
        let page = source.page!
        let title = page.article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = page.article.siteName.flatMap { $0.isEmpty ? nil : $0 } ?? source.candidate?.domain
        return WebSearchResult(source: WebSearchSource(title: title.isEmpty ? (source.candidate?.title ?? "") : title,
                                                       url: page.url),
                               snippets: [text], site: site, published: page.article.published, kind: source.kind)
      }
    }
  }

  // MARK: Helpers

  /// At most 50 words and 400 characters, whitespace collapsed (spec §2).
  static func siteQuery(_ query: String) -> String {
    var text = query.split(whereSeparator: \.isWhitespace).prefix(OnDeviceSearchTiming.maximumQueryWords)
      .joined(separator: " ")
    if text.count > OnDeviceSearchTiming.maximumQueryCharacters {
      text = String(text.prefix(OnDeviceSearchTiming.maximumQueryCharacters))
      if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
    }
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// Rate limited if any site was; unavailable if every site failed; otherwise nothing found.
  static func failure(_ run: SiteRunResult) -> WebSearchError {
    let outcomes = Array(run.outcomes.values)
    if outcomes.contains(.rateLimited) { return .rateLimited }
    if outcomes.allSatisfy({ $0 == .failed || $0 == .blocked || $0 == .unrecognized }) { return .unavailable }
    return .noResults
  }

  /// Wikipedia's title or first 300 characters share a content word with the question.
  private static func shares(_ article: WikipediaArticle, _ questionLemmas: Set<String>) -> Bool {
    !PassageRanker.contentLemmas(article.title + "\n" + article.text.prefix(300)).isDisjoint(with: questionLemmas)
  }

  /// The Mac's preferred languages plus the question's, when the recognizer can tell.
  private static func allowedLanguages(question: String, preferred: [String]) -> Set<String> {
    var languages = Set(preferred)
    if let language = NLLanguageRecognizer.dominantLanguage(for: question), language != .undetermined {
      languages.insert(language.rawValue)
    }
    return languages
  }

  private static func source(_ candidate: RankedCandidate) -> WebSearchSource {
    WebSearchSource(title: candidate.title, url: candidate.url)
  }
}

/// The reader's blocklist check, following the lists the current search loaded.
private final class BlockedCheck: @unchecked Sendable {
  private let lock = NSLock()
  private var quality: SourceQuality?
  func set(_ quality: SourceQuality) { lock.withLock { self.quality = quality } }
  /// Blocked until a search has loaded the lists.
  func isBlocked(_ url: URL) -> Bool { lock.withLock { quality?.isBlocked(url) ?? true } }
}

/// Picks the provider for both kinds of turn. Brave stays the default until CP8; the on-device
/// provider is reachable only in Debug builds, through `webSearch.debugProvider`.
enum WebSearchProviderFactory {
  static let debugProviderKey = "webSearch.debugProvider"

  @MainActor static func makeDefault(defaults: UserDefaults = .standard) -> any WebSearchProvider {
    makeDefault(defaults: defaults, isTestHost: TestHost.isActive)
  }

  /// `isTestHost` is the seam for tests, whose host always has `TestHost.isActive`.
  @MainActor static func makeDefault(defaults: UserDefaults, isTestHost: Bool) -> any WebSearchProvider {
    #if DEBUG
    if !isTestHost, defaults.string(forKey: debugProviderKey) == "onDevice" {
      return OnDeviceSearchProvider.live()
    }
    #endif
    return BraveSearchClient()
  }
}
