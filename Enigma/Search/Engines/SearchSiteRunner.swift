import Foundation

struct SiteRunResult: Equatable, Sendable {
  var outcomes: [SearchEngineID: EngineOutcome]
  var wikipedia: WikipediaOutcome
}

/// Queries the search sites for one search (spec §2). Every engine it's given, plus Wikipedia when
/// asked, starts at once with its own time limit. The owner's lineup has no backup site, so there is
/// no Startpage rule (decision D33).
struct SearchSiteRunner: Sendable {
  static let primaryTimeout: Duration = .seconds(2)

  private let engines: [SearchEngineID: any SearchEngine]
  private let wikipedia: WikipediaSearch
  private let client: any SearchHTTPClient
  private let health: EngineHealth
  private let log: any SearchLogging
  private let clock: any Clock<Duration>

  init(engines: [SearchEngineID: any SearchEngine], wikipedia: WikipediaSearch, client: any SearchHTTPClient,
       health: EngineHealth, log: any SearchLogging, clock: any Clock<Duration> = ContinuousClock()) {
    self.engines = engines
    self.wikipedia = wikipedia
    self.client = client
    self.health = health
    self.log = log
    self.clock = clock
  }

  private enum Lane: Sendable {
    case engine(SearchEngineID, EngineOutcome)
    case wikipedia(WikipediaOutcome)
  }

  func run(_ query: EngineQuery, includeWikipedia: Bool, preferredLanguages: [String]) async -> SiteRunResult {
    await withTaskGroup(of: Lane.self) { group in
      for (id, engine) in engines {
        group.addTask { .engine(id, await runEngine(id, engine, query)) }
      }
      if includeWikipedia {
        group.addTask {
          let outcome = await withTimeout { await wikipedia.lookup(query.text, preferredLanguages: preferredLanguages,
                                                                  using: client) }
          return .wikipedia(outcome ?? .failed)
        }
      }
      var result = SiteRunResult(outcomes: [:], wikipedia: .none)
      for await lane in group {
        switch lane {
        case .engine(let id, let outcome): result.outcomes[id] = outcome
        case .wikipedia(let outcome): result.wikipedia = outcome
        }
      }
      return result
    }
  }

  /// One site: skipped while cooling down, paced, timed out, and its outcome recorded. A run
  /// cancelled from outside, a skip, a timeout and a network error record nothing (D37, D41, D45, D47).
  private func runEngine(_ id: SearchEngineID, _ engine: any SearchEngine, _ query: EngineQuery) async -> EngineOutcome {
    if await health.isCoolingDown(id) { return .failed }
    // A query the site just challenged isn't sent again for a minute (D45).
    let fingerprint = query.text.hashValue
    // Reported as rate limited, so the user hears "limiting requests", and nothing is recorded.
    if await health.isSkipped(id, query: fingerprint) { return .rateLimited }
    let delay = await health.reservePacingSlot(id)
    if delay > .zero {
      do { try await clock.sleep(for: delay) } catch { return .failed }
      // Another search may have hit a block, or challenged this query, while this one waited.
      if await health.isCoolingDown(id) { return .failed }
      if await health.isSkipped(id, query: fingerprint) { return .rateLimited }
    }
    guard !Task.isCancelled else { return .failed }

    let observer = ObservingClient(base: client)
    let outcome = await withTimeout { await engine.search(query, using: observer) } ?? .failed
    guard !Task.isCancelled else { return outcome }

    switch outcome {
    case .results, .noResults:
      await health.recordSuccess(id)
    case .unrecognized:
      let page = observer.lastResponse
      log.unrecognizedPage(engine: id, status: page?.status ?? 0, bytes: page?.bytes ?? 0)
      await health.recordFailure(id)
    case .blocked:
      await health.recordFailure(id)
    case .rateLimited:
      await health.recordRateLimited(id, query: fingerprint)
    case .failed:
      // A timeout or network error isn't a block sign (spec §2); with DuckDuckGo the only web index,
      // a slow network mustn't take it away for a minute or more (decision D41). A server error
      // that did answer is logged (D47).
      if let page = observer.lastResponse {
        log.failedPage(engine: id, status: page.status, bytes: page.bytes)
      }
    }
    return outcome
  }

  /// The operation's value, or nil once `primaryTimeout` passes; the loser is cancelled.
  private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await operation() }
      group.addTask { [clock] in
        try? await clock.sleep(for: Self.primaryTimeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}

/// Remembers the status and size of the last response, so an unrecognized page can be logged
/// without the engine passing them back.
private final class ObservingClient: SearchHTTPClient, @unchecked Sendable {
  private let base: any SearchHTTPClient
  private let lock = NSLock()
  private var last: (status: Int, bytes: Int)?

  init(base: any SearchHTTPClient) { self.base = base }

  var lastResponse: (status: Int, bytes: Int)? { lock.withLock { last } }

  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse {
    let response = try await base.send(request, maximumBytes: maximumBytes)
    lock.withLock { last = (response.statusCode, response.body.count) }
    return response
  }
}
