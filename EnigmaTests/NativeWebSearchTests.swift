import XCTest
@testable import Enigma

/// The shared pieces of a cloud model's own web search (F30 CP1).
final class NativeWebSearchTests: XCTestCase {
  private func source(_ url: String, _ title: String = "Title") -> WebSearchSource {
    WebSearchSource(title: title, url: URL(string: url)!)
  }

  // MARK: Types, the error and the provider set

  func testChatRequestHasNoProviderSearchByDefault() {
    let route = Route(mode: .cloud, providerID: CloudProviderID.openAI.rawValue, modelID: "gpt-5.5", usesNetwork: true)
    let request = ChatRequest(sessionID: UUID(), messages: [], route: route)
    XCTAssertNil(request.providerSearch)
    XCTAssertEqual(ProviderSearch().blockedDomains, [])
  }

  func testUnavailableErrorMessage() {
    for provider in CloudProviderID.allCases {
      XCTAssertEqual(CloudProviderError.webSearchUnavailable(provider).errorDescription,
                     "Web search isn't available for this model.")
    }
  }

  func testNativeWebSearchProviders() {
    XCTAssertEqual(CloudProviderID.nativeWebSearchProviders, [])
    XCTAssertFalse(CloudProviderID.gemini.supportsNativeWebSearch)
    for provider in CloudProviderID.allCases {
      XCTAssertEqual(provider.supportsNativeWebSearch, CloudProviderID.nativeWebSearchProviders.contains(provider))
    }
  }

  func testLimits() {
    XCTAssertEqual(NativeWebSearch.maximumSearches, 5)
    XCTAssertEqual(NativeWebSearch.maximumSources, 8)
  }

  func testIsAllowed() {
    var checked = 0
    for provider in CloudProviderID.allCases {
      for enabled in [false, true] {
        for holdsMessageText in [false, true] {
          for available in [false, true] {
            var availability = NativeWebSearchAvailability()
            if !available { availability.markUnavailable(provider, modelID: "model") }
            let allowed = NativeWebSearch.isAllowed(provider: provider, modelID: "model",
              holdsMessageText: holdsMessageText, enabledProviders: enabled ? Set(CloudProviderID.allCases) : [],
              availability: availability)
            let expected = provider != .gemini && enabled && !holdsMessageText && available
            XCTAssertEqual(allowed, expected, "\(provider) enabled \(enabled) text \(holdsMessageText) available \(available)")
            checked += 1
          }
        }
      }
    }
    XCTAssertEqual(checked, CloudProviderID.allCases.count * 8)
  }

  func testAvailabilityIsPerProviderAndModel() {
    var availability = NativeWebSearchAvailability()
    XCTAssertTrue(availability.isAvailable(.openAI, modelID: "gpt-5.5"))
    availability.markUnavailable(.openAI, modelID: "gpt-5.5")
    XCTAssertFalse(availability.isAvailable(.openAI, modelID: "gpt-5.5"))
    XCTAssertTrue(availability.isAvailable(.openAI, modelID: "gpt-4.1"), "Another model of the same provider")
    XCTAssertTrue(availability.isAvailable(.anthropic, modelID: "gpt-5.5"), "The same model ID at another provider")
    availability.markUnavailable(.openAI, modelID: "gpt-5.5")
    XCTAssertFalse(availability.isAvailable(.openAI, modelID: "gpt-5.5"))
  }

  // MARK: Sources

  func testSelectSourcesPrefersCitedThenLinked() {
    let selected = NativeWebSearch.selectSources(
      cited: [source("https://b.com/1", "B"), source("https://a.com/1", "A")],
      linked: [URL(string: "https://a.com/1")!, URL(string: "https://c.com/1")!],
      discovered: [source("https://c.com/1", "C"), source("https://d.com/1", "D")])
    XCTAssertEqual(selected.map(\.url.absoluteString), ["https://b.com/1", "https://a.com/1", "https://c.com/1"])
    XCTAssertEqual(selected.map(\.title), ["B", "A", "C"], "A link takes its title from the result it came from")
  }

  func testSelectSourcesFallsBackToDiscoveredWhenNothingCited() {
    let discovered = [source("https://a.com/1", "A"), source("https://b.com/1", "B")]
    XCTAssertEqual(NativeWebSearch.selectSources(cited: [], linked: [], discovered: discovered), discovered)
    XCTAssertEqual(NativeWebSearch.selectSources(cited: [source("javascript:alert(1)")], linked: [], discovered: discovered),
                   discovered, "Nothing usable was cited")
    XCTAssertEqual(NativeWebSearch.selectSources(cited: [], linked: [URL(string: "https://c.com")!], discovered: discovered)
      .map(\.url.absoluteString), ["https://c.com"], "A link counts, so the results aren't used")
  }

  func testSelectSourcesDropsFragmentDuplicates() {
    let selected = NativeWebSearch.selectSources(
      cited: [source("https://a.com/page#one", "A"), source("https://a.com/page#two", "A again"), source("https://a.com/page")],
      linked: [URL(string: "https://a.com/page#three")!, URL(string: "https://b.com/")!],
      discovered: [])
    XCTAssertEqual(selected.map(\.url.absoluteString), ["https://a.com/page#one", "https://b.com/"])
    XCTAssertEqual(selected.first?.title, "A")
  }

  func testSelectSourcesDropsUnsafeLinks() {
    let selected = NativeWebSearch.selectSources(
      cited: [source("javascript:alert(1)"), source("https://user:secret@a.com/"), source("/relative/path"),
              source("ftp://files.example.com/x"), source("https://ok.com/")],
      linked: [URL(string: "https://me@b.com/")!, URL(string: "file:///etc/hosts")!],
      discovered: [])
    XCTAssertEqual(selected.map(\.url.absoluteString), ["https://ok.com/"])
  }

  func testSelectSourcesUsesSiteNameForMissingTitle() {
    let selected = NativeWebSearch.selectSources(
      cited: [source("https://www.example.com/a", ""), source("https://news.site.org/b", "  ")],
      linked: [URL(string: "https://www.other.com/c")!], discovered: [])
    XCTAssertEqual(selected.map(\.title), ["example.com", "news.site.org", "other.com"])
  }

  func testSelectSourcesCapsAtEight() {
    let cited = (1...12).map { source("https://site\($0).com/") }
    let selected = NativeWebSearch.selectSources(cited: cited, linked: [], discovered: [])
    XCTAssertEqual(selected, Array(cited.prefix(8)))
    let discovered = NativeWebSearch.selectSources(cited: [], linked: [], discovered: cited)
    XCTAssertEqual(discovered.count, 8)
  }

  func testLinksInText() {
    let text = """
    See [the guide](https://a.com/guide) and ![chart](https://img.com/chart.png).
    More at https://b.com/page. Also (https://c.com/x), "https://d.com/q?x=1", and https://a.com/guide again.
    [Wiki](https://en.wikipedia.org/wiki/Swift_(programming_language)) and <https://e.com/>; then [mail](mailto:x@y.com).
    https://b.com/page!
    """
    XCTAssertEqual(NativeWebSearch.links(in: text).map(\.absoluteString), [
      "https://a.com/guide", "https://b.com/page", "https://c.com/x", "https://d.com/q?x=1",
      "https://en.wikipedia.org/wiki/Swift_(programming_language)", "https://e.com/",
    ])
    XCTAssertEqual(NativeWebSearch.links(in: "No links here."), [])
  }

  func testCollectorSelection() {
    var collector = NativeWebSearchSources()
    XCTAssertFalse(collector.searched)
    XCTAssertEqual(collector.selection(linksAreCitations: false), [])
    collector.discovered([source("https://a.com/", "A"), source("https://b.com/", "B")])
    XCTAssertTrue(collector.searched)
    XCTAssertEqual(collector.selection(linksAreCitations: false).map(\.title), ["A", "B"], "Nothing cited: the results")
    collector.answered("Per [B](https://b.com/) ")
    collector.answered("and https://c.com/.")
    XCTAssertEqual(collector.selection(linksAreCitations: true).map(\.url.absoluteString), ["https://b.com/", "https://c.com/"])
    XCTAssertEqual(collector.selection(linksAreCitations: true).first?.title, "B")
    collector.cited(source("https://a.com/", "A cited"))
    XCTAssertEqual(collector.selection(linksAreCitations: false).map(\.url.absoluteString),
                   ["https://a.com/", "https://b.com/", "https://c.com/"], "Citations first, then the answer's other links")
    XCTAssertEqual(collector.selection(linksAreCitations: false).first?.title, "A cited")
    XCTAssertEqual(collector.selection(linksAreCitations: true).map(\.url.absoluteString),
                   ["https://b.com/", "https://c.com/", "https://a.com/"], "The answer's links are its citations")
  }

  // MARK: The instruction

  private static let fixedDate = Date(timeIntervalSince1970: 1_793_232_000) // 2026-10-29T00:00:00Z
  private static let utc = TimeZone(identifier: "UTC")!

  func testProviderSearchInstruction() async {
    let part = ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc)
    XCTAssertEqual(part.instructions, """
    Today is Thursday, 29 October 2026. You can search the web with your web search tool. Use it for facts that change or that you may not know: news, prices, schedules, weather, recent events, and specific pages. You can't see live information yourself, so when a question depends on it, search instead of saying you can't look it up or asking for the date. Don't search for things you already know well, for the user's own data, or to answer from Messages or an attached selection. Search at most 5 times. Never put personal details, credentials, file contents, or text from messages into a search query. You don't know where the user is: for places or weather near them, ask which city they mean. Link the pages you rely on.
    """)
    XCTAssertTrue(part.definitions.isEmpty)
    XCTAssertEqual(part.phase(for: "web_search"), .searching)
    let result = await part.execute(name: "web_search", arguments: .object([:]))
    XCTAssertFalse(result.success)
    XCTAssertNil(result.stop)
    let west = ProviderSearchPart(today: Self.fixedDate, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    XCTAssertTrue(west.instructions.hasPrefix("Today is Wednesday, 28 October 2026."), "The user's own date")
  }

  func testProviderSearchInstructionNamesBlockedSites() {
    let domains = (1...25).map { "site\($0).com" }
    let part = ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc, blockedDomains: domains)
    let expected = " Don't use results from these sites: " + domains.prefix(20).joined(separator: ", ") + "."
    XCTAssertTrue(part.instructions.hasSuffix("Link the pages you rely on." + expected))
    XCTAssertFalse(part.instructions.contains("site21.com"))
    let two = ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc, blockedDomains: ["a.com", "b.com"])
    XCTAssertTrue(two.instructions.hasSuffix(" Don't use results from these sites: a.com, b.com."))
    XCTAssertFalse(ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc).instructions.contains("these sites"))
  }

  /// Spec §2a: with a location allowed for the provider, the near-me clause names the area.
  func testProviderSearchInstructionWithLocation() {
    let askClause = "You don't know where the user is: for places or weather near them, ask which city they mean."
    func clause(_ location: ProviderSearchLocation) -> String {
      let instructions = ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc, location: location).instructions
      XCTAssertFalse(instructions.contains(askClause))
      XCTAssertTrue(instructions.hasSuffix(" Link the pages you rely on."))
      return instructions
    }
    let full = ProviderSearchLocation(city: "Austin", region: "Texas", countryCode: "US", timeZone: "America/Chicago")
    XCTAssertEqual(full.displayName, "Austin, Texas, United States")
    XCTAssertTrue(clause(full).contains(" The user's approximate location is Austin, Texas, United States; your web search tool uses it for places and weather near them. Link"))
    let partial = ProviderSearchLocation(city: nil, region: "Bavaria", countryCode: "DE", timeZone: nil)
    XCTAssertEqual(partial.displayName, "Bavaria, Germany")
    XCTAssertTrue(clause(partial).contains("location is Bavaria, Germany; your"))
    XCTAssertEqual(ProviderSearchLocation(city: "Paris", region: " ", countryCode: nil, timeZone: nil).displayName, "Paris")
    XCTAssertTrue(ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc).instructions.contains(askClause))
    let empty = ProviderSearchLocation(city: nil, region: nil, countryCode: nil, timeZone: "Europe/Paris")
    XCTAssertTrue(ProviderSearchPart(today: Self.fixedDate, timeZone: Self.utc, location: empty).instructions.contains(askClause),
                  "No area to name: ask")
  }

  // MARK: Fixtures

  func testFixtureFolderIsFound() {
    XCTAssertTrue(FileManager.default.fileExists(atPath: CloudSearchFixture.url("README.md").path))
  }
}
