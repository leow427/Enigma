import Foundation
import WebKit

/// One piece of an extracted article, in page order.
struct ArticleBlock: Equatable, Sendable {
  enum Kind: String, Sendable, Decodable { case paragraph, listItem, heading, code, tableRow }
  let kind: Kind
  let text: String
}

/// What Readability found in a page: plain text only, never HTML.
struct ExtractedArticle: Equatable, Sendable {
  let title: String
  let siteName: String?
  let byline: String?
  let language: String?
  let published: Date?
  /// The page's own last-modified date, when it gives one (D62). The stale check uses `published`.
  let modified: Date?
  let blocks: [ArticleBlock]
  let isReaderable: Bool
  /// Words in the blocks, by the system's word boundaries, so Japanese and Chinese count properly (D66).
  let wordCount: Int

  init(title: String, siteName: String?, byline: String?, language: String?, published: Date?, modified: Date? = nil,
       blocks: [ArticleBlock], isReaderable: Bool) {
    self.title = title
    self.siteName = siteName
    self.byline = byline
    self.language = language
    self.published = published
    self.modified = modified
    self.blocks = blocks
    self.isReaderable = isReaderable
    wordCount = blocks.reduce(0) { $0 + TextWords.count(in: $1.text) }
  }
}

/// Word boundaries shared by the word count and the near-duplicate shingles.
enum TextWords {
  static func count(in text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
      count += 1
    }
    return count
  }

  static func words(in text: String) -> [String] {
    var words: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
      if let word { words.append(word.lowercased()) }
    }
    return words
  }
}

/// Reads the date strings a page offers (D62).
enum ArticleDates {
  /// Dates before this are taken as placeholders (a zero timestamp, a template default).
  static let earliest = Date(timeIntervalSince1970: 788_918_400)  // 1995-01-01
  /// How far past now a date may be, for time zones and clock drift.
  static let futureAllowance: TimeInterval = 2 * 86_400

  /// The first candidate that parses to a plausible date.
  static func first(of candidates: [String], now: Date) -> Date? {
    candidates.lazy.compactMap { parse($0, now: now) }.first
  }

  /// ISO 8601 with or without a time, offset or fractions; RFC 1123; "October 28, 2026" and
  /// "28 October 2026". A date without an offset is read as UTC. Nil when it isn't plausible.
  static func parse(_ text: String, now: Date) -> Date? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
    // Fractions of a second don't matter here, and their length varies.
    if let fraction = trimmed.range(of: #"(?<=\d{2}:\d{2}:\d{2})\.\d+"#, options: .regularExpression) {
      trimmed.removeSubrange(fraction)
    }
    for formatter in formatters {
      if let date = formatter.date(from: trimmed) {
        return date >= earliest && date <= now.addingTimeInterval(futureAllowance) ? date : nil
      }
    }
    return nil
  }

  /// A `/2026/10/29/` or `2026-10-29` date in the link's path, the last resort for `published`.
  static func fromURLPath(_ url: URL, now: Date) -> Date? {
    let path = url.path(percentEncoded: false)
    let patterns = [#"/((?:19|20)\d{2})/(0?[1-9]|1[0-2])/(0?[1-9]|[12]\d|3[01])(?:/|$|[^0-9])"#,
                    #"(?<![0-9])((?:19|20)\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?![0-9])"#]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { continue }
      let numbers = (1...3).compactMap { Range(match.range(at: $0), in: path).flatMap { Int(path[$0]) } }
      guard numbers.count == 3 else { continue }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
      guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == components,
            date >= earliest, date <= now.addingTimeInterval(futureAllowance) else { continue }
      return date
    }
    return nil
  }

  // DateFormatter parsing is thread-safe; these are never mutated after creation.
  nonisolated(unsafe) private static let formatters: [DateFormatter] = {
    let utc = TimeZone(identifier: "UTC")!
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mmZZZZZ", "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd",
      "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz",
      "MMMM d, yyyy", "MMM d, yyyy", "MMMM d, yyyy h:mm a", "d MMMM yyyy", "d MMM yyyy",
    ]
    return formats.map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = utc
      formatter.isLenient = false
      formatter.dateFormat = format
      return formatter
    }
  }()
}

protocol ArticleExtracting: Sendable {
  @MainActor func warmUp()
  @MainActor func extract(html: String, url: URL) async throws -> ExtractedArticle
}

enum ArticleExtractorError: Error, Equatable {
  case timedOut
  case scriptFailed
  /// The bundled scripts or the block-all rule list couldn't be loaded.
  case unavailable
}

/// Extracts article text in one hidden, sealed `WKWebView` (spec §4): no page scripts, every load
/// blocked by a rule list, every navigation after the first cancelled, no message handlers, no
/// stored data. Readability.js and `EnigmaExtract.js` run in an isolated content world and hand
/// back JSON. Page HTML is parsed only in WebKit's WebContent process.
@MainActor final class ArticleExtractor: ArticleExtracting {
  /// The search pipeline's extractor, with its per-page limit (D73).
  static let shared = ArticleExtractor(timeout: OnDeviceSearchTiming.extractionTimeout)

  /// Spec §4: 500 ms per page. CP5's timing passes its own value.
  static let defaultTimeout: Duration = .milliseconds(500)
  static let defaultIdleRelease: Duration = .seconds(60)
  static let contentWorldName = "EnigmaExtract"
  /// Versioned: a changed rule gets a new identifier, so a stored list is never stale (D69).
  static let ruleListIdentifier = "EnigmaBlockAll-v1"
  /// The unversioned identifier of the first build, removed once (D69).
  static let retiredRuleListIdentifiers = ["EnigmaBlockAll"]
  static let blockAllRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

  /// Each page's extraction limit; `shared` uses `OnDeviceSearchTiming.extractionTimeout`.
  let timeout: Duration
  private let idleRelease: Duration
  private let clock: any Clock<Duration>
  private var view: SealedWebView?
  private var busy = false
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
  private var idleTask: Task<Void, Never>?
  private var warmTask: Task<Void, Never>?
  private var created = 0
  private var blankLoads = 0

  /// A blank page, loaded once per view so its WebContent process is running before the first
  /// real page (a fresh process cost 0.4–0.9 s on the CI runner; D77).
  static let blankPage = "<html></html>"
  /// The most a blank load may hold the view.
  static let warmLoadLimit: Duration = .seconds(2)

  init(timeout: Duration = ArticleExtractor.defaultTimeout, idleRelease: Duration = ArticleExtractor.defaultIdleRelease,
       clock: any Clock<Duration> = ContinuousClock()) {
    self.timeout = timeout
    self.idleRelease = idleRelease
    self.clock = clock
  }

  /// For tests.
  var hasWebView: Bool { view != nil }
  /// For tests: views created so far, blank pages loaded, and whether a warm-up is under way.
  var viewsCreated: Int { created }
  var warmLoads: Int { blankLoads }
  var isWarming: Bool { warmTask != nil }
  /// For tests: how many times the current view was told to stop loading.
  var viewStops: Int? { view?.stopCount }

  /// Creates the view and loads a blank page in it, so the WebContent process starts while a
  /// search is still on the network. Once per view; the blank load takes an extraction turn, so it
  /// never overlaps a page (D78).
  func warmUp() {
    let view = currentView()
    scheduleIdleRelease()
    guard !view.hasLoaded, warmTask == nil else { return }
    warmTask = Task { [weak self] in
      await self?.warm(view)
      self?.warmTask = nil
    }
  }

  private func currentView() -> SealedWebView {
    if let view { return view }
    let view = SealedWebView()
    created += 1
    self.view = view
    return view
  }

  private func warm(_ view: SealedWebView) async {
    guard let rules = await Self.ruleList() else { return }
    do { try await waitForTurn() } catch { return }
    defer {
      endTurn()
      if !busy { scheduleIdleRelease() }
    }
    guard self.view === view, !view.hasLoaded else { return }
    view.install(rules)
    blankLoads += 1
    let once = WarmLoad()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      once.continuation = continuation
      let limit = Task {
        // A finished blank load cancels this; it must not stop the view then (D79).
        do { try await ContinuousClock().sleep(for: Self.warmLoadLimit) } catch { return }
        view.stopLoading()
        once.finish()
      }
      view.load(Self.blankPage) { _ in
        limit.cancel()
        once.finish()
      }
    }
  }

  /// One page at a time, in arrival order (D63); the time limit starts with this page's turn.
  func extract(html: String, url: URL) async throws -> ExtractedArticle {
    idleTask?.cancel()
    idleTask = nil
    try await waitForTurn()
    defer {
      endTurn()
      if !busy { scheduleIdleRelease() }
    }
    try Task.checkCancellation()
    guard let script = Self.script, let rules = await Self.ruleList() else { throw ArticleExtractorError.unavailable }
    try Task.checkCancellation()
    let view = currentView()
    view.install(rules)
    do {
      let json = try await run(script, html: html, in: view)
      return try await Self.article(from: json, url: url)
    } catch {
      // A timed-out or cancelled script may still be running in the WebContent process, and a
      // crashed one has none: the view goes, and a fresh one warms up for the next page (D63, D78).
      if self.view === view {
        discardView()
        warmUp()
      }
      throw Self.normalized(error)
    }
  }

  /// Cancellation and Enigma's own errors as they are; anything else becomes `.scriptFailed`, so
  /// the pipeline falls back to the page's snippet (D78).
  nonisolated static func normalized(_ error: any Error) -> any Error {
    if error is CancellationError || error is ArticleExtractorError { return error }
    return ArticleExtractorError.scriptFailed
  }

  // MARK: Turns

  private func waitForTurn() async throws {
    guard busy else {
      busy = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  /// Hands the view to the next waiter, which keeps `busy` set.
  private func endTurn() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  // MARK: Running one page

  private func run(_ script: String, html: String, in view: SealedWebView) async throws -> String {
    let job = ExtractionJob()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
        job.continuation = continuation
        guard !Task.isCancelled else {
          job.finish(.failure(CancellationError()))
          return
        }
        job.timeoutTask = Task { [clock, timeout] in
          do { try await clock.sleep(for: timeout) } catch { return }
          view.stopLoading()
          job.finish(.failure(ArticleExtractorError.timedOut))
        }
        view.load(html) { loaded in
          switch loaded {
          case .failure:
            job.finish(.failure(ArticleExtractorError.scriptFailed))
          case .success:
            guard !job.isFinished else { return }
            view.evaluate(script, arguments: ["pageHTML": html], world: .world(name: Self.contentWorldName)) { result in
              switch result {
              case .success(let value as String): job.finish(.success(value))
              default: job.finish(.failure(ArticleExtractorError.scriptFailed))
              }
            }
          }
        }
      }
    } onCancel: {
      Task { @MainActor in job.finish(.failure(CancellationError())) }
    }
  }

  // MARK: The view's lifetime

  private func scheduleIdleRelease() {
    idleTask?.cancel()
    idleTask = Task { [weak self, clock, idleRelease] in
      do { try await clock.sleep(for: idleRelease) } catch { return }
      guard let self, !self.busy else { return }
      self.discardView()
    }
  }

  private func discardView() {
    view?.close()
    view = nil
  }

  // MARK: Shared resources

  private static var ruleListTask: Task<WKContentRuleList?, Never>?

  /// The stored block-all list, compiled only when missing, so WebKit writes its one small file
  /// (the rule text, nothing else) once per rule version, not once per launch (D69).
  static func storedRuleList(in store: WKContentRuleListStore) async -> (list: WKContentRuleList?, compiled: Bool) {
    if let stored = try? await store.contentRuleList(forIdentifier: ruleListIdentifier) {
      return (stored, false)
    }
    for retired in retiredRuleListIdentifiers {
      try? await store.removeContentRuleList(forIdentifier: retired)
    }
    let compiled = try? await store.compileContentRuleList(forIdentifier: ruleListIdentifier,
                                                           encodedContentRuleList: blockAllRules)
    return (compiled, true)
  }

  /// The block-all rule list, loaded once per launch. Nil if WebKit can't provide it; the next
  /// extraction tries again.
  static func ruleList() async -> WKContentRuleList? {
    let task = ruleListTask ?? Task { @MainActor in
      guard let store = WKContentRuleListStore.default() else { return nil }
      return await storedRuleList(in: store).list
    }
    ruleListTask = task
    let list = await task.value
    if list == nil, ruleListTask == task { ruleListTask = nil }
    return list
  }

  /// Readability's two files and `EnigmaExtract.js`, as one function body (CP0 Q2).
  private static let script: String? = {
    guard let folder = Bundle.main.url(forResource: "SearchData", withExtension: nil)?.appending(path: "readability")
    else { return nil }
    let names = ["Readability-readerable.js", "Readability.js", "EnigmaExtract.js"]
    let sources = names.compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
    return sources.count == names.count ? sources.joined(separator: "\n;\n") : nil
  }()

  private struct Payload: Decodable {
    struct Block: Decodable {
      let kind: ArticleBlock.Kind
      let text: String
    }
    let title: String
    let siteName: String?
    let byline: String?
    let lang: String?
    let publishedTimes: [String]
    let modifiedTimes: [String]
    let readerable: Bool
    let blocks: [Block]
  }

  /// Decodes the script's JSON and counts words, off the main actor.
  private nonisolated static func article(from json: String, url: URL) async throws -> ExtractedArticle {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
      throw ArticleExtractorError.scriptFailed
    }
    let now = Date()
    return ExtractedArticle(
      title: payload.title, siteName: payload.siteName, byline: payload.byline, language: payload.lang,
      published: ArticleDates.first(of: payload.publishedTimes, now: now) ?? ArticleDates.fromURLPath(url, now: now),
      modified: ArticleDates.first(of: payload.modifiedTimes, now: now),
      blocks: payload.blocks.map { ArticleBlock(kind: $0.kind, text: $0.text) }, isReaderable: payload.readerable)
  }
}

/// One extraction's single continuation, resumed once whichever of load, script, timeout or
/// cancellation ends it first.
@MainActor private final class ExtractionJob {
  var continuation: CheckedContinuation<String, any Error>?
  var timeoutTask: Task<Void, Never>?
  private(set) var isFinished = false

  func finish(_ result: Result<String, any Error>) {
    guard !isFinished else { return }
    isFinished = true
    timeoutTask?.cancel()
    timeoutTask = nil
    continuation?.resume(with: result)
    continuation = nil
  }
}

/// The blank load's single continuation, resumed by the load or by `warmLoadLimit`.
@MainActor private final class WarmLoad {
  var continuation: CheckedContinuation<Void, Never>?
  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

/// The navigation delegate's rule: only the main-frame load Enigma starts, once. Frames, meta
/// refreshes, new windows and anything after the first load are cancelled.
enum SealedNavigation {
  static func allows(expectingLoad: Bool, isMainFrame: Bool) -> Bool {
    expectingLoad && isMainFrame
  }
}

/// The hidden view and its navigation delegate (spec §4's configuration).
@MainActor final class SealedWebView: NSObject, WKNavigationDelegate {
  private let webView: WKWebView
  private let contentController = WKUserContentController()
  private var rulesInstalled = false
  private var allowsNextNavigation = false
  private var navigation: WKNavigation?
  private var onLoad: ((Result<Void, ArticleExtractorError>) -> Void)?
  /// A load has finished in this view, so its WebContent process is running.
  private(set) var hasLoaded = false

  /// Spec §4's configuration: nothing stored, no page scripts, only Enigma's content controller
  /// (which never gets a script message handler).
  static func makeConfiguration(contentController: WKUserContentController) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.userContentController = contentController
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return configuration
  }

  override init() {
    let configuration = Self.makeConfiguration(contentController: contentController)
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
    super.init()
    webView.navigationDelegate = self
  }

  func install(_ rules: WKContentRuleList) {
    guard !rulesInstalled else { return }
    contentController.add(rules)
    rulesInstalled = true
  }

  /// Loads the page with no base URL; only this one navigation is allowed.
  func load(_ html: String, completion: @escaping (Result<Void, ArticleExtractorError>) -> Void) {
    precondition(rulesInstalled, "the block-all rule list must be installed before any page loads")
    onLoad = completion
    allowsNextNavigation = true
    navigation = webView.loadHTMLString(html, baseURL: nil)
  }

  func evaluate(_ script: String, arguments: [String: Any], world: WKContentWorld,
                completion: @escaping (Result<Any, any Error>) -> Void) {
    webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world, completionHandler: completion)
  }

  /// For tests.
  private(set) var stopCount = 0

  func stopLoading() {
    stopCount += 1
    webView.stopLoading()
  }

  func close() {
    webView.stopLoading()
    webView.navigationDelegate = nil
    finishLoad(.failure(.scriptFailed))
  }

  private func finishLoad(_ result: Result<Void, ArticleExtractorError>) {
    let callback = onLoad
    onLoad = nil
    // The finished navigation stays referenced until the next load replaces it or the view goes,
    // so WebKit never sees it released mid-callback (macOS 26 CI, D76). Delegate calls for it
    // after this find `onLoad` empty and do nothing.
    callback?(result)
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let allowed = SealedNavigation.allows(expectingLoad: allowsNextNavigation,
                                          isMainFrame: navigationAction.targetFrame?.isMainFrame == true)
    if allowed { allowsNextNavigation = false }
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard navigation === self.navigation else { return }
    hasLoaded = true
    finishLoad(.success(()))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    guard navigation === self.navigation else { return }
    finishLoad(.failure(.scriptFailed))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    guard navigation === self.navigation else { return }
    finishLoad(.failure(.scriptFailed))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finishLoad(.failure(.scriptFailed))
  }
}
