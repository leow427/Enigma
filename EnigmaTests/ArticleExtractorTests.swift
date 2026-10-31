import CryptoKit
import Network
import WebKit
import XCTest
@testable import Enigma

/// A TCP listener on 127.0.0.1 that counts connections, to prove the sealed view loads nothing.
final class LoopbackListener: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackListener")
  private let lock = NSLock()
  private var connections = 0

  private let reply: Data?

  /// With `reply`, each connection gets it after its first bytes arrive (a tiny HTTP server).
  init(reply: Data? = nil) throws {
    self.reply = reply
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  var connectionCount: Int { lock.withLock { connections } }
  var origin: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let once = OnceFlag()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.claim() { continuation.resume() }
        case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self, queue, reply] connection in
        self?.lock.withLock { self?.connections += 1 }
        guard let reply else { return connection.cancel() }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
          connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false
  func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

/// Loads HTML in an ordinary view with page scripts off but no rule list, the control for the
/// subresource tests: it shows the listener does see what an unsealed view loads.
@MainActor private final class UnsealedLoader: NSObject, WKNavigationDelegate {
  let webView: WKWebView
  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
  }
  func load(_ html: String) { webView.loadHTMLString(html, baseURL: nil) }
}

@MainActor
final class ArticleExtractorTests: XCTestCase {
  private let pageURL = URL(string: "https://news.example.com/2026/10/28/tidal-barrier")!

  /// Tests that check what's extracted get a long limit: a slow CI runner took 0.6–0.8 s for
  /// pages that take 0.1–0.4 s here (D77). `testExtractionTimesOut` pins the limit itself.
  @MainActor static func patient() -> ArticleExtractor { ArticleExtractor(timeout: .seconds(10)) }

  private func fixture(_ name: String) -> String { SearchFixture.string("articles/\(name)") }

  private func waitUntil(_ condition: () -> Bool, seconds: Double = 3) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  func testExtractsNewsArticle() async throws {
    let extractor = Self.patient()
    let article = try await extractor.extract(html: fixture("article-news.html"), url: pageURL)
    XCTAssertEqual(article.title, "Harbor Council Backs Tidal Barrier Plan")
    XCTAssertEqual(article.siteName, "The Harbor Ledger")
    XCTAssertEqual(article.published, ISO8601DateFormatter().date(from: "2026-10-28T09:15:00Z"))
    XCTAssertEqual(article.modified, ISO8601DateFormatter().date(from: "2026-10-29T16:40:00Z"))
    XCTAssertEqual(article.language, "en-US")
    XCTAssertEqual(article.byline, "Mara Quillfeather")
    XCTAssertTrue(article.isReaderable)
    XCTAssertGreaterThan(article.wordCount, 300)
    let paragraphs = article.blocks.filter { $0.kind == .paragraph }.map(\.text)
    XCTAssertTrue(paragraphs.contains { $0.hasPrefix("The Saltmere harbor council voted seven to two on Tuesday evening") },
                  "\(paragraphs.prefix(3))")
    XCTAssertTrue(article.blocks.contains(ArticleBlock(kind: .heading, text: "What happens next")))
    let all = article.blocks.map(\.text).joined(separator: "\n")
    XCTAssertFalse(all.contains("kayak sale"), "the advert is left out")
    XCTAssertFalse(all.contains("All rights reserved"), "the footer is left out")
    for block in article.blocks {
      XCTAssertEqual(block.text, block.text.trimmingCharacters(in: .whitespacesAndNewlines))
      XCTAssertFalse(block.text.isEmpty)
      XCTAssertFalse(block.text.contains("  "), block.text)
    }
  }

  func testDocsPageKeepsHeadingsAndCode() async throws {
    let article = try await Self.patient().extract(html: fixture("article-docs.html"),
                                                       url: URL(string: "https://docs.example.com/cache")!)
    let kinds = article.blocks.map(\.kind)
    XCTAssertTrue(kinds.contains(.heading))
    XCTAssertTrue(kinds.contains(.code))
    XCTAssertTrue(kinds.contains(.listItem))
    XCTAssertTrue(kinds.contains(.tableRow))
    func index(_ kind: ArticleBlock.Kind, _ prefix: String) -> Int? {
      article.blocks.firstIndex { $0.kind == kind && $0.text.hasPrefix(prefix) }
    }
    let installation = try XCTUnwrap(index(.heading, "Installation"))
    let installCode = try XCTUnwrap(index(.code, "lantern install cache-helper --global"))
    let options = try XCTUnwrap(index(.heading, "Options"))
    let row = try XCTUnwrap(index(.tableRow, "maxSize"))
    let clearing = try XCTUnwrap(index(.heading, "Clearing the cache"))
    let item = try XCTUnwrap(index(.listItem, "Stop any running builds"))
    let clearCode = try XCTUnwrap(index(.code, "lantern cache clear --all"))
    XCTAssertEqual([installation, installCode, options, row, clearing, item, clearCode].sorted(),
                   [installation, installCode, options, row, clearing, item, clearCode])
    // Code keeps its line breaks; table cells are separated.
    XCTAssertEqual(article.blocks[installCode].text, "lantern install cache-helper --global\nlantern cache status")
    XCTAssertEqual(article.blocks[row].text, "maxSize | 2 GB | Largest size before old entries are removed")
    XCTAssertEqual(article.siteName, "Lantern Docs")
    XCTAssertNil(article.published)
  }

  func testScriptOnlyPageIsNotReaderable() async throws {
    let article = try await Self.patient().extract(html: fixture("script-only.html"),
                                                       url: URL(string: "https://app.example.com/")!)
    XCTAssertFalse(article.isReaderable)
    XCTAssertLessThan(article.wordCount, 20)
    XCTAssertEqual(PageChecks.basic(article, isWikipedia: false, allowedLanguages: ["en"]), .notArticle)
  }

  func testPageScriptsNeverRun() async throws {
    let script = """
      <script>document.querySelectorAll('p').forEach(function (p) { p.textContent = 'SCRIPT RAN'; });
      document.title = 'SCRIPT RAN';</script>
      """
    var html = fixture("article-news.html")
    html = html.replacingOccurrences(of: "<body>", with: "<body onload=\"document.body.innerHTML='SCRIPT RAN'\">" + script)
    html = html.replacingOccurrences(of: "</article>", with: "<img src=\"x\" onerror=\"this.parentNode.innerHTML='SCRIPT RAN'\"></article>" + script)
    let article = try await Self.patient().extract(html: html, url: pageURL)
    XCTAssertFalse(article.blocks.isEmpty)
    XCTAssertFalse(article.title.contains("SCRIPT RAN"))
    for block in article.blocks {
      XCTAssertFalse(block.text.contains("SCRIPT RAN"), block.text)
    }
  }

  func testNoSubresourceLoads() async throws {
    // Control: an unsealed view does reach the listener, so a zero below means something.
    let control = try LoopbackListener()
    try await control.start()
    defer { control.stop() }
    let loader = UnsealedLoader()
    loader.load(fixture("subresources.html").replacingOccurrences(of: "{{ORIGIN}}", with: control.origin))
    await waitUntil({ control.connectionCount > 0 }, seconds: 5)
    XCTAssertGreaterThan(control.connectionCount, 0, "the listener sees an unsealed view's loads")

    let listener = try LoopbackListener()
    try await listener.start()
    defer { listener.stop() }
    let html = fixture("subresources.html").replacingOccurrences(of: "{{ORIGIN}}", with: listener.origin)
    let article = try await Self.patient().extract(html: html, url: URL(string: "https://trap.example.com/")!)
    XCTAssertTrue(article.blocks.contains { $0.text.hasPrefix("This page points at a local listener") })
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(listener.connectionCount, 0)
  }

  func testMetaRefreshDoesNotNavigate() async throws {
    let listener = try LoopbackListener()
    try await listener.start()
    defer { listener.stop() }
    let html = fixture("meta-refresh.html").replacingOccurrences(of: "{{ORIGIN}}", with: listener.origin)
    let extractor = Self.patient()
    let article = try await extractor.extract(html: html, url: URL(string: "https://ferry.example.com/")!)
    XCTAssertEqual(article.title, "Ferry Timetable Changes")
    XCTAssertTrue(article.blocks.contains { $0.text.hasPrefix("The winter ferry timetable starts") })
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(listener.connectionCount, 0)
    // The view still serves the next page after the refresh was refused.
    let next = try await extractor.extract(html: fixture("article-docs.html"), url: URL(string: "https://docs.example.com/")!)
    XCTAssertTrue(next.title.hasPrefix("Configuring the Lantern cache"), next.title)
  }

  func testSealedConfiguration() {
    let controller = WKUserContentController()
    let configuration = SealedWebView.makeConfiguration(contentController: controller)
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertTrue(configuration.userContentController === controller)
    XCTAssertTrue(controller.userScripts.isEmpty)
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
  }

  func testNoScriptMessageHandlers() async throws {
    // Any message handler, in any world, would show up as `window.webkit` there.
    let compiled = await ArticleExtractor.ruleList()
    let rules = try XCTUnwrap(compiled)
    let view = SealedWebView()
    view.install(rules)
    let loaded: Bool = await withCheckedContinuation { continuation in
      view.load("<html><body><p>x</p></body></html>") { continuation.resume(returning: (try? $0.get()) != nil) }
    }
    XCTAssertTrue(loaded)
    for world in [WKContentWorld.page, .defaultClient, .world(name: ArticleExtractor.contentWorldName)] {
      let type: String? = await withCheckedContinuation { continuation in
        view.evaluate("return typeof window.webkit;", arguments: [:], world: world) {
          continuation.resume(returning: (try? $0.get()) as? String)
        }
      }
      XCTAssertEqual(type, "undefined")
    }
    view.close()
  }

  func testRuleListIsVersionedAndKeptAcrossLaunches() async throws {
    XCTAssertEqual(ArticleExtractor.ruleListIdentifier, "EnigmaBlockAll-v1")
    // A store of its own, so the installed app's store is never touched.
    let folder = FileManager.default.temporaryDirectory.appending(path: "EnigmaRuleListTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
    // An upgrade from the unversioned entry: v1 is missing, the old one is there.
    _ = try await store.compileContentRuleList(forIdentifier: "EnigmaBlockAll",
                                               encodedContentRuleList: ArticleExtractor.blockAllRules)
    let first = await ArticleExtractor.storedRuleList(in: store)
    XCTAssertNotNil(first.list)
    XCTAssertTrue(first.compiled)
    let identifiers = await store.availableIdentifiers() ?? []
    XCTAssertEqual(identifiers, ["EnigmaBlockAll-v1"], "the unversioned entry is removed")

    func storedFile() throws -> (inode: Int, modified: Date) {
      let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
      let name = try XCTUnwrap(files.first { $0.contains("EnigmaBlockAll-v1") }, "\(files)")
      let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path(percentEncoded: false))
      return (try XCTUnwrap(attributes[.systemFileNumber] as? Int), try XCTUnwrap(attributes[.modificationDate] as? Date))
    }
    let before = try storedFile()
    // The next launch looks the list up and writes nothing.
    let second = await ArticleExtractor.storedRuleList(in: store)
    XCTAssertNotNil(second.list)
    XCTAssertFalse(second.compiled)
    let after = try storedFile()
    XCTAssertEqual(after.inode, before.inode)
    XCTAssertEqual(after.modified, before.modified)
  }

  func testOnlyTheFirstMainFrameLoadIsAllowed() {
    XCTAssertTrue(SealedNavigation.allows(expectingLoad: true, isMainFrame: true))
    XCTAssertFalse(SealedNavigation.allows(expectingLoad: true, isMainFrame: false), "frames are cancelled")
    XCTAssertFalse(SealedNavigation.allows(expectingLoad: false, isMainFrame: true), "a refresh or link is cancelled")
    XCTAssertFalse(SealedNavigation.allows(expectingLoad: false, isMainFrame: false))
  }

  func testExtractionTimesOut() async {
    let extractor = ArticleExtractor(timeout: .milliseconds(1))
    do {
      _ = try await extractor.extract(html: fixture("article-news.html"), url: pageURL)
      XCTFail("expected a timeout")
    } catch {
      XCTAssertEqual(error as? ArticleExtractorError, .timedOut)
    }
    // The timed-out view is discarded (D63), and a fresh one warms up for the next page (D78).
    await waitUntil { !extractor.isWarming }
    XCTAssertEqual(extractor.viewsCreated, 2)
    XCTAssertEqual(extractor.warmLoads, 1)
    XCTAssertTrue(extractor.hasWebView)
  }

  func testNoStopFollowsACompletedWarmUp() async throws {
    let extractor = Self.patient()
    extractor.warmUp()
    await waitUntil { !extractor.isWarming }
    XCTAssertEqual(extractor.warmLoads, 1)
    // A stray stop here could cancel the next real page's load (reviewer round 2, D79).
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(extractor.viewStops, 0)
  }

  func testSharedExtractorUsesThePipelinesLimit() {
    XCTAssertEqual(ArticleExtractor.shared.timeout, OnDeviceSearchTiming.extractionTimeout)
    XCTAssertEqual(Self.patient().timeout, .seconds(10))
  }

  func testWarmUpLoadsOneBlankPageOncePerView() async throws {
    let extractor = Self.patient()
    extractor.warmUp()
    extractor.warmUp()
    XCTAssertTrue(extractor.hasWebView)
    await waitUntil { !extractor.isWarming }
    XCTAssertEqual(extractor.warmLoads, 1, "One blank load for two calls")
    extractor.warmUp()
    await waitUntil { !extractor.isWarming }
    XCTAssertEqual(extractor.warmLoads, 1, "A view that has loaded isn't warmed again")
    // The warmed view still serves sealed extractions: the meta refresh never navigates.
    let listener = try LoopbackListener()
    try await listener.start()
    defer { listener.stop() }
    let html = fixture("meta-refresh.html").replacingOccurrences(of: "{{ORIGIN}}", with: listener.origin)
    let article = try await extractor.extract(html: html, url: URL(string: "https://ferry.example.com/")!)
    XCTAssertEqual(article.title, "Ferry Timetable Changes")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(listener.connectionCount, 0)
    XCTAssertEqual(extractor.viewsCreated, 1)
  }

  func testIdleRelease() async throws {
    let clock = ManualClock()
    let extractor = ArticleExtractor(clock: clock)
    XCTAssertFalse(extractor.hasWebView)
    _ = try await extractor.extract(html: fixture("article-docs.html"), url: URL(string: "https://docs.example.com/")!)
    XCTAssertTrue(extractor.hasWebView)
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(59))
    await Task.yield()
    XCTAssertTrue(extractor.hasWebView)
    clock.advance(by: .seconds(1))
    await waitUntil { !extractor.hasWebView }
    XCTAssertFalse(extractor.hasWebView)
    extractor.warmUp()
    XCTAssertTrue(extractor.hasWebView)
    // A warmed-up view that's never used is released too, once its blank load is done.
    await waitUntil { !extractor.isWarming }
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(60))
    await waitUntil { !extractor.hasWebView }
    XCTAssertFalse(extractor.hasWebView)
  }

  func testExtractionsTakeTurns() async throws {
    let extractor = Self.patient()
    let newsHTML = fixture("article-news.html"), docsHTML = fixture("article-docs.html"), newsURL = pageURL
    async let news = extractor.extract(html: newsHTML, url: newsURL)
    async let docs = extractor.extract(html: docsHTML, url: URL(string: "https://docs.example.com/")!)
    let (first, second) = try await (news, docs)
    XCTAssertEqual(first.title, "Harbor Council Backs Tidal Barrier Plan")
    XCTAssertTrue(second.title.hasPrefix("Configuring the Lantern cache"), second.title)
  }

  /// Any error that isn't Enigma's own becomes a normal extraction failure, so a search falls
  /// back to the page's snippet (D78). No WebKit needed.
  func testForeignWebKitErrorBecomesExtractionFailure() {
    struct InvalidTransition: Error {}
    XCTAssertEqual(ArticleExtractor.normalized(InvalidTransition()) as? ArticleExtractorError, .scriptFailed)
    XCTAssertEqual(ArticleExtractor.normalized(NSError(domain: "WKErrorDomain", code: 4)) as? ArticleExtractorError,
                   .scriptFailed)
    XCTAssertTrue(ArticleExtractor.normalized(CancellationError()) is CancellationError)
    for error in [ArticleExtractorError.timedOut, .scriptFailed, .unavailable] {
      XCTAssertEqual(ArticleExtractor.normalized(error) as? ArticleExtractorError, error)
    }
  }

  func testCancelledExtractionThrowsAndViewRecovers() async throws {
    let extractor = Self.patient()
    let task = Task { try await extractor.extract(html: fixture("article-news.html"), url: pageURL) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    let article = try await extractor.extract(html: fixture("article-docs.html"), url: URL(string: "https://docs.example.com/")!)
    XCTAssertTrue(article.title.hasPrefix("Configuring the Lantern cache"), article.title)
  }

  func testJSONLDDateAndPublisherFromStringScan() async throws {
    let body = String(repeating: "<p>The lighthouse keepers kept a written log of every passing ship, the weather at dawn and dusk, and the state of the lamp, and those logs are now read by historians who study the coast.</p>\n", count: 4)
    let html = """
      <html lang="en"><head><title>Keeping the Light</title>
      <script type="application/ld+json">
      {"@context":"https://schema.org","@graph":[
        {"@type":"WebSite","name":"Ignore Me","datePublished":"2001-01-01"},
        {"@type":["NewsArticle"],"datePublished":"2026-09-14T07:30:00+02:00","dateModified":"2026-09-15T10:00:00+02:00",
         "author":[{"@type":"Person","name":"Ivo Brannagh"}],
         "publisher":{"@type":"Organization","name":"Northwind Gazette"}}]}
      </script></head>
      <body><article><h1>Keeping the Light</h1>\(body)</article></body></html>
      """
    let article = try await Self.patient().extract(html: html, url: URL(string: "https://gazette.example.com/light")!)
    XCTAssertEqual(article.published, ISO8601DateFormatter().date(from: "2026-09-14T05:30:00Z"))
    XCTAssertEqual(article.modified, ISO8601DateFormatter().date(from: "2026-09-15T08:00:00Z"))
    XCTAssertEqual(article.siteName, "Northwind Gazette")
    XCTAssertEqual(article.byline, "Ivo Brannagh")
  }

  func testTimeElementAndURLDates() async throws {
    let body = String(repeating: "<p>The orchard society met in the old barn to compare the year's apples, judge the cider and plan the winter pruning, and as usual the arguments about which tree was oldest went on long after dark.</p>\n", count: 4)
    let withTime = "<html><head><title>Orchard Notes</title></head><body><article><h1>Orchard Notes</h1><p>Posted <time datetime=\"2026-08-02\">2 August</time></p>\(body)</article></body></html>"
    let timed = try await Self.patient().extract(html: withTime, url: URL(string: "https://orchard.example.com/notes")!)
    XCTAssertEqual(timed.published, ISO8601DateFormatter().date(from: "2026-08-02T00:00:00Z"))

    let plain = "<html><head><title>Orchard Notes</title></head><body><article><h1>Orchard Notes</h1>\(body)</article></body></html>"
    let fromURL = try await Self.patient().extract(html: plain, url: URL(string: "https://orchard.example.com/2026/07/19/notes")!)
    XCTAssertEqual(fromURL.published, ISO8601DateFormatter().date(from: "2026-07-19T00:00:00Z"))
    XCTAssertNil(fromURL.modified)
  }

  func testBundledReadabilityMatchesPinnedHashes() throws {
    let folder = try XCTUnwrap(Bundle.main.url(forResource: "SearchData", withExtension: nil)?.appending(path: "readability"))
    let readme = try String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8)
    for name in ["Readability.js", "Readability-readerable.js", "LICENSE.md"] {
      let digest = SHA256.hash(data: try Data(contentsOf: folder.appending(path: name)))
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      XCTAssertTrue(readme.contains("| `\(name)` | `\(hex)` |"), "\(name) doesn't match its README hash")
    }
    XCTAssertTrue(readme.contains("tag `0.6.0`"))
    let extract = try String(contentsOf: folder.appending(path: "EnigmaExtract.js"), encoding: .utf8)
    XCTAssertTrue(extract.contains("isProbablyReaderable(document)"))
    let notices = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")),
                             encoding: .utf8)
    XCTAssertTrue(notices.contains("Readability.js (Mozilla"))
    XCTAssertTrue(notices.contains("Copyright (c) 2010 Arc90 Inc"))
  }

  func testDateParsingAndPlausibility() {
    let now = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
    let iso = ISO8601DateFormatter()
    let cases: [(String, String?)] = [
      ("2026-10-28T09:15:00Z", "2026-10-28T09:15:00Z"),
      ("2026-10-28T09:15:00.123Z", "2026-10-28T09:15:00Z"),
      ("2026-10-28T11:15:00+02:00", "2026-10-28T09:15:00Z"),
      ("2026-10-28T11:15:00+0200", "2026-10-28T09:15:00Z"),
      ("2026-10-28T09:15:00", "2026-10-28T09:15:00Z"),
      ("2026-10-28 09:15:00", "2026-10-28T09:15:00Z"),
      ("2026-10-28", "2026-10-28T00:00:00Z"),
      ("Wed, 28 Oct 2026 09:15:00 GMT", "2026-10-28T09:15:00Z"),
      ("October 28, 2026", "2026-10-28T00:00:00Z"),
      ("28 October 2026", "2026-10-28T00:00:00Z"),
      ("  2026-10-28T09:15:00Z ", "2026-10-28T09:15:00Z"),
      ("2026-11-05T00:00:00Z", nil),   // in the future
      ("1970-01-01T00:00:00Z", nil),   // a zero timestamp
      ("yesterday", nil),
      ("", nil),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(ArticleDates.parse(text, now: now), expected.flatMap(iso.date(from:)), text)
    }
    XCTAssertEqual(ArticleDates.first(of: ["junk", "1999-02-03", "2026-01-01"], now: now), iso.date(from: "1999-02-03T00:00:00Z"))
    XCTAssertEqual(ArticleDates.fromURLPath(URL(string: "https://a.example.com/news/2026/10/29/story")!, now: now),
                   iso.date(from: "2026-10-29T00:00:00Z"))
    XCTAssertEqual(ArticleDates.fromURLPath(URL(string: "https://a.example.com/blog/2026-03-07-title")!, now: now),
                   iso.date(from: "2026-03-07T00:00:00Z"))
    XCTAssertNil(ArticleDates.fromURLPath(URL(string: "https://a.example.com/docs/2026/guide")!, now: now))
    XCTAssertNil(ArticleDates.fromURLPath(URL(string: "https://a.example.com/2026/13/40/x")!, now: now))
    XCTAssertNil(ArticleDates.fromURLPath(URL(string: "https://a.example.com/item/12345678")!, now: now))
  }
}
