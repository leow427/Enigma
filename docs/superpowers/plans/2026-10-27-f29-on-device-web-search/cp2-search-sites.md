# CP2: Search sites

Read [agent-workflow.md](agent-workflow.md), the spec (§2, plus §7 for
logging), and the Hand-offs of [CP0](cp0-spike.md#hand-off) and
[CP1](cp1-foundations.md#hand-off). CP0's findings decide the parser: Q1, and
Q4–Q6 for site behavior.

## Goal

Enigma can query DuckDuckGo, Mojeek, Startpage and Wikipedia itself. It
parses their pages, notices blocks and layout changes, backs off, and
applies spec §2's Startpage rule. Nothing calls this yet. CP5 wires it in.

## Starting point

- CP1's `WebSearchRequest`, `SearchRecency` and `WebSearchLimits` are in
  `Enigma/Search/WebSearch.swift`.
- Sanitized fixtures from CP0 are in `EnigmaTests/Fixtures/Search/`, listed
  in their README.
- The existing `CloudNetworkTransport` (`Enigma/Cloud/CloudDomain.swift:169`)
  returns no headers and follows redirects, so search gets its own client.

## Tasks

### Task 2.1: The HTTP client and Safari headers

**Files:**

- Create `Enigma/Search/SearchHTTPClient.swift`, registered in the app target.
- Test: create `EnigmaTests/SearchHTTPClientTests.swift`. It uses a
  `URLProtocol` stub passed in through `URLSessionConfiguration.protocolClasses`.
- Test support: create `EnigmaTests/SearchTestSupport.swift`, registered in
  the test target. Every later checkpoint reuses it:
  - `final class ManualClock: Clock`, with `Duration` and
    `advance(by:)`;
  - `final class FakeSearchHTTPClient: SearchHTTPClient`. It maps a URL to a
    response or error, can hang until cancelled, and records the requests
    and `maximumBytes` it receives;
  - `enum SearchFixture`, with `data(_ name: String)` and
    `string(_ name: String)`. These read `Fixtures/Search/` through
    `#filePath`.

**Interfaces.** This task produces:

```swift
struct SearchHTTPResponse: Equatable, Sendable {
  let url: URL
  let statusCode: Int
  let headers: [String: String]        // names lowercased
  let body: Data
  let truncated: Bool
}
protocol SearchHTTPClient: Sendable {
  /// Never follows redirects: a 3xx response comes back as is. Stops reading after maximumBytes.
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse
}
final class URLSessionSearchHTTPClient: SearchHTTPClient {
  static let live: URLSessionSearchHTTPClient
  init(configuration: URLSessionConfiguration = .ephemeral)
}
enum SafariHeaders {
  static var installedSafariVersion: String { get }     // /Applications/Safari.app CFBundleShortVersionString, else "26.0"
  static func userAgent(safariVersion: String) -> String
  static func acceptLanguage(_ preferred: [String]) -> String
  static func standard(acceptLanguage: String) -> [String: String]
}
```

**Session settings** (the configuration):

- `httpCookieStorage = nil`, `httpShouldSetCookies = false`;
- `urlCache = nil`, `urlCredentialStorage = nil`;
- a delegate whose `willPerformHTTPRedirection` returns `nil`;
- reading through `bytes(for:)`, stopping at `maximumBytes`.

**Header values:**

- **User agent:**
  `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/<v> Safari/605.1.15`.
- **`Accept`:** `text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8`.
- **Accept-Language:**
  - each preferred tag is followed by its base language, if that isn't
    listed yet;
  - the first entry has no q-value; later ones get `;q=0.9`, `0.8`, and so
    on, never below `0.5`;
  - an empty list gives `en-US,en;q=0.9`.
- **`standard` adds:** `Sec-Fetch-Dest: document`, `Sec-Fetch-Mode: navigate`,
  `Sec-Fetch-Site: none`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testClientDoesNotFollowRedirects`: the stub returns 302 with
    `Location: https://b.example/`. The response has `statusCode == 302` and
    `headers["location"] == "https://b.example/"`, and the stub saw exactly
    one request.
  - `testClientStopsAtByteLimit`: a 3,000,000-byte body with a 2,097,152
    limit gives `body.count == 2_097_152` and `truncated == true`.
  - `testClientKeepsNoCookies`: the first response sets `Set-Cookie: a=1`,
    and the second request has no `Cookie` header.
  - `testSafariUserAgent`: `userAgent(safariVersion: "26.1")` equals the
    exact string above, with `<v>` = `26.1`.
  - `testAcceptLanguage`:
    - `["en-GB"]` gives `"en-GB,en;q=0.9"`;
    - `["en-GB", "fr-FR"]` gives `"en-GB,en;q=0.9,fr-FR;q=0.8,fr;q=0.7"`;
    - `[]` gives `"en-US,en;q=0.9"`.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchHTTPClientTests`.
  Expect failures.
- [ ] **Implement** `SearchHTTPClient.swift`.
- [ ] **Run** the same tests. Expect them to pass.

### Task 2.2: Engine types, the result-page parser and DuckDuckGo

**Files:**

- Create, all registered in the app target:
  - `Enigma/Search/Engines/SearchEngine.swift`: the types, `SERPDocument`,
    `EngineHealth` and `SearchLogging`;
  - `Enigma/Search/Engines/DuckDuckGoEngine.swift`;
  - `Enigma/Search/Engines/UPSTREAM.json`, which isn't in any target.
- Test: create `EnigmaTests/SearchEngineTests.swift`.

**Interfaces.** This task produces:

```swift
enum SearchEngineID: String, Sendable, CaseIterable { case duckDuckGo, mojeek, startpage }
struct SearchRegion: Equatable, Sendable {
  let country: String; let language: String           // lowercased
  var code: String { get }                             // "us-en"
  static func current(_ locale: Locale = .current) -> SearchRegion   // falls back to us-en
}
struct EngineQuery: Equatable, Sendable { let text: String; let region: SearchRegion; let recency: SearchRecency? }
struct EngineResult: Equatable, Sendable {
  let title: String; let url: URL; let snippet: String
  let position: Int                                    // 1-based, within this engine
  let engine: SearchEngineID
}
enum EngineOutcome: Equatable, Sendable { case results([EngineResult]), noResults, blocked, rateLimited, unrecognized, failed }
protocol SearchEngine: Sendable {
  var id: SearchEngineID { get }
  var weight: Double { get }                           // DuckDuckGo 1.0, Startpage 1.0, Mojeek 0.8
  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome
}
struct SERPDocument {                                  // the parser CP0 confirmed (XMLDocument by default)
  init?(html: Data)
  func nodes(_ xpath: String, in node: XMLNode?) -> [XMLNode]
  func text(_ xpath: String, in node: XMLNode) -> String     // every text node joined, whitespace collapsed, as ddgs does
  func value(_ xpath: String, in node: XMLNode) -> String?
}
protocol SearchLogging: Sendable { func unrecognizedPage(engine: SearchEngineID, status: Int, bytes: Int) }
struct OSSearchLog: SearchLogging        // Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight", category: "search"), error level
struct DuckDuckGoEngine: SearchEngine {
  static func request(for query: EngineQuery) -> URLRequest
  static func parse(_ response: SearchHTTPResponse) -> EngineOutcome
}
```

**DuckDuckGo's values, from spec §2:**

- **Request:**
  - `POST https://html.duckduckgo.com/html/`, form-encoded;
  - fields `q`, `b=""` and `l=<region code>`, plus `df=<d|w|m|y>` when
    `recency` is set;
  - `SafariHeaders.standard`.
- **Parsing:**
  - items: `//div[contains(@class, 'body')]`;
  - title: `.//h2//text()`;
  - href: `./a/@href`;
  - body: `./a//text()`.
- **Dropped:** hrefs starting `https://duckduckgo.com/y.js?`, and items inside
  an ancestor whose class contains `result--ad`.
- **Unwrapped:** `//duckduckgo.com/l/?uddg=<encoded>` links become the
  decoded URL.
- **Outcomes:**

  | Response | Outcome |
  | --- | --- |
  | HTTP 202 or 429 | `.rateLimited` |
  | HTTP 403 or 503, or the bot-check page (CP0's marker) | `.blocked` |
  | DuckDuckGo's "No results" marker | `.noResults` |
  | HTTP 200 with zero items and no marker | `.unrecognized` |
  | Anything else | `.failed` |

  Only `http` and `https` links are kept, and positions count from 1.

**Steps:**

- [ ] **Write the failing tests** in `SearchEngineTests`:
  - `testDuckDuckGoRequestIsFormPost`: the URL, `POST`, and Content-Type
    `application/x-www-form-urlencoded`. The decoded body fields equal
    `["q": "swift actors", "b": "", "l": "us-en"]`. `.week` adds
    `"df": "w"`, and there's no `df` without recency.
  - `testDuckDuckGoEncodesNonLatinQuery` (Review Focus 1): the body has
    `q=%E6%9D%B1%E4%BA%AC` for "東京", and decodes back to the original.
  - `testDuckDuckGoParsesResults`: `duckduckgo-results.html` gives the item
    count and the first result's title, URL and snippet as recorded in the
    fixture README. Positions are `1…n`.
  - `testDuckDuckGoDropsAds`: no result URL starts with
    `https://duckduckgo.com/y.js?`.
  - `testDuckDuckGoUnwrapsUddgLinks`: a minimal synthetic page with href
    `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&rut=x` gives
    `https://example.com/a`.
  - Outcome tests:
    - `testDuckDuckGo202IsRateLimited`;
    - `testDuckDuckGoBotCheckIsBlocked`;
    - `testDuckDuckGoNoResultsPage`;
    - `testDuckDuckGoChangedLayoutIsUnrecognized`, using a copy of the
      results fixture with `body` renamed in every class, saved as
      `duckduckgo-changed.html`.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchEngineTests`.
  Expect failures.
- [ ] **Implement.** Start `DuckDuckGoEngine.swift` with
  `// Ported from ddgs v9.16.1, ddgs/engines/duckduckgo.py (MIT). XPaths are verbatim; see UPSTREAM.json.`
- [ ] **Run** the tests. Expect them to pass.

### Task 2.3: Mojeek

**Files:** create `Enigma/Search/Engines/MojeekEngine.swift`. Tests go in
`SearchEngineTests`.

**Interfaces.** This task produces
`struct MojeekEngine: SearchEngine` (weight 0.8), with
`static func request(for:) -> URLRequest` and
`static func parse(_:) -> EngineOutcome`.

**Values:**

- `GET https://www.mojeek.com/search?q=<query>`;
- header `Cookie: arc=<country>; lb=<language>`;
- items: `//ul[contains(@class, 'results')]/li`;
- title: `.//h2//text()`;
- href: `.//h2/a/@href`;
- body: `.//p[@class='s']//text()`;
- no recency parameter.

**Steps:**

- [ ] **Write the failing tests:**
  - `testMojeekRequest`: the URL query item `q`, and the cookie header
    `arc=us; lb=en`;
  - `testMojeekParsesResults`;
  - `testMojeekNoResults`;
  - `testMojeek403IsBlocked`;
  - `testMojeekChangedLayoutIsUnrecognized`.
- [ ] **Run** `SearchEngineTests`. Expect failures.
- [ ] **Implement** `MojeekEngine.swift`, with the same header comment
  pointing at `mojeek.py`.
- [ ] **Run** `SearchEngineTests`. Expect them to pass.

### Task 2.4: Startpage

**Files:** create `Enigma/Search/Engines/StartpageEngine.swift`. Tests go in
`SearchEngineTests`.

**Interfaces.** This task produces
`struct StartpageEngine: SearchEngine` (weight 1.0), with
`static func token(fromHome: SearchHTTPResponse) -> String?`,
`static func request(for:token:) -> URLRequest` and `static func parse(_:)`.
Reuse the token only if CP0's Q6 says reuse works.

**Values, from ddgs's `startpage.py`:**

- **Token:** `GET https://www.startpage.com/`, then the token from
  `//form[@id="search"]//input[@name="sc"]/@value`.
- **Search:** `POST https://www.startpage.com/sp/search`, with
  `Referer: https://www.startpage.com/`.
- **Form fields:** `query`, `cat=web`, `t=device`, `sc=<token>`,
  `lui=english`, `language=english`, `abp=1`, `abd=0`, `abe=0`,
  `qsr=<lang>_<COUNTRY>` (for example `en_US`), `qadf=moderate`,
  `segment=organic`, plus `with_date=<d|w|m|y>` when recency is set.
- **Parsing:**
  - items: `//div[contains(@class, 'result css')][./a]`;
  - title: `.//h2//text()`;
  - href: `./a/@href`;
  - body: `.//p//text()`;
  - drop hrefs starting `https://www.google.com`.
- **Outcomes:** a missing token gives `.failed`; a captcha page gives
  `.blocked`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testStartpageReadsToken`, from `startpage-home.html`;
  - `testStartpagePayload`: the exact form fields above, with
    `with_date=w` for `.week`;
  - `testStartpageSendsReferer`;
  - `testStartpageDropsGoogleLinks`;
  - `testStartpageMissingTokenFails`;
  - `testStartpageCaptchaIsBlocked`.
- [ ] **Run** `SearchEngineTests`. Expect failures.
- [ ] **Implement** `StartpageEngine.swift`, with the header comment
  pointing at `startpage.py`.
- [ ] **Run** `SearchEngineTests`. Expect them to pass.

### Task 2.5: Wikipedia

**Files:** create `Enigma/Search/Engines/WikipediaSearch.swift`. Tests go in
`SearchEngineTests`, with the fixtures `wikipedia-search.json` and
`wikipedia-extract.json`. Write those synthetically, in the API's documented
shape.

**Interfaces.** This task produces:

```swift
struct WikipediaArticle: Equatable, Sendable { let title: String; let url: URL; let text: String }
enum WikipediaOutcome: Equatable, Sendable { case article(WikipediaArticle), none, failed }
struct WikipediaSearch: Sendable {
  static var userAgent: String { get }   // "Enigma/<CFBundleShortVersionString> (https://github.com/leow427/Enigma)"
  static func language(for preferred: [String]) -> String
  func lookup(_ query: String, preferredLanguages: [String], using client: any SearchHTTPClient) async -> WikipediaOutcome
}
```

**Values, from spec §2:**

- **Search:**
  `https://<lang>.wikipedia.org/w/api.php?action=query&list=search&srsearch=<q>&srlimit=3&format=json`.
- **Extract:**
  `action=query&prop=extracts&explaintext=1&exsectionformat=plain&redirects=1&titles=<title>&format=json`.
- **Top hit:** the first of the three hits whose extract doesn't contain
  "may refer to:".
- **Text:** capped at 30,000 characters.
- **Language:** the first preferred language's base code if it's in a fixed
  set of the 30 largest editions, otherwise `en`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testWikipediaSearchRequest`: the host, every query item, and the
    User-Agent matching
    `^Enigma/[0-9.]+ \(https://github\.com/leow427/Enigma\)$`;
  - `testWikipediaExtractRequest`;
  - `testWikipediaSkipsDisambiguation`;
  - `testWikipediaCapsText`: 35,000 characters in, 30,000 out;
  - `testWikipediaLanguage`: `["fr-CA"]` gives `"fr"`, `["xx-YY"]` gives
    `"en"`, and `["zh-Hant-TW"]` gives `"zh"`.
- [ ] **Run** `SearchEngineTests`. Expect failures.
- [ ] **Implement** `WikipediaSearch.swift`.
- [ ] **Run** `SearchEngineTests`. Expect them to pass.

### Task 2.6: Site health, backoff and pacing

**Files:** add to `Enigma/Search/Engines/SearchEngine.swift`. Tests go in
`SearchEngineTests`.

**Interfaces.** This task produces:

```swift
actor EngineHealth {
  static let shared: EngineHealth
  static let cooldownSteps: [Duration]              // [.seconds(60), .seconds(300), .seconds(900), .seconds(3600)]
  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })
  func isCoolingDown(_ id: SearchEngineID) -> Bool
  func recordFailure(_ id: SearchEngineID)          // the next step of the ladder; stays at 3,600 s
  func recordSuccess(_ id: SearchEngineID)          // resets the ladder
  func pacingDelay(_ id: SearchEngineID) -> Duration  // time until 1 s after this site's last search; 0 if none is needed
}
```

**Steps:**

- [ ] **Write the failing tests:**
  - `testCooldownLadder`: successive failures, each after the previous
    cooldown ends, give 60, 300, 900, 3,600 and 3,600 seconds;
  - `testSuccessResetsLadder`;
  - `testPacingDelayIsAtMostOneSecond`.
- [ ] **Run** `SearchEngineTests`. Expect failures.
- [ ] **Implement** `EngineHealth`.
- [ ] **Run** `SearchEngineTests`. Expect them to pass.

### Task 2.7: The site runner and the Startpage rule

**Files:** create `Enigma/Search/Engines/SearchSiteRunner.swift`. Test:
create `EnigmaTests/SearchSiteRunnerTests.swift`, using fake engines and a
test clock.

**Interfaces.** This task produces:

```swift
struct SiteRunResult: Equatable, Sendable {
  var outcomes: [SearchEngineID: EngineOutcome]
  var wikipedia: WikipediaOutcome
}
struct SearchSiteRunner: Sendable {
  static let primaryTimeout: Duration            // .seconds(2)
  static let startpageBudget: Duration           // .milliseconds(2500)
  init(engines: [SearchEngineID: any SearchEngine], wikipedia: WikipediaSearch,
       client: any SearchHTTPClient, health: EngineHealth, log: any SearchLogging,
       clock: any Clock<Duration> = ContinuousClock())
  func run(_ query: EngineQuery, includeWikipedia: Bool, preferredLanguages: [String]) async -> SiteRunResult
}
```

**Rules, from spec §2:**

- **Primaries:** DuckDuckGo, Mojeek and, when `includeWikipedia` is true,
  Wikipedia start together, each with `primaryTimeout`.
- **Startpage starts at once** when DuckDuckGo is cooling down or returns
  `.blocked`, `.rateLimited`, `.unrecognized` or `.failed`.
- **Startpage starts at DuckDuckGo's timeout** if Mojeek has fewer than 3
  results. It gets `startpageBudget` in total.
- **Health:** each outcome is recorded. Results and no-results count as
  successes; everything else, timeouts included, as failures.
- **Logging:** `.unrecognized` calls `log.unrecognizedPage`.
- **Skipping:** sites that are cooling down are skipped, with outcome
  `.failed`. Pacing waits `pacingDelay` first.

**Steps:**

- [ ] **Write the failing tests:**
  - `testPrimariesRunTogether`;
  - `testStartpageRunsWhenDuckDuckGoBlocks`;
  - `testStartpageRunsWhenDuckDuckGoCoolingDown`;
  - `testStartpageRunsOnDuckDuckGoTimeoutWithFewResults`: DuckDuckGo hangs
    and Mojeek returns 2 results, so Startpage starts at 2 s;
  - `testStartpageSkippedWhenEnoughResults`: Mojeek returns 5 results;
  - `testUnrecognizedPageIsLoggedWithoutQuery`: the recorded call is
    `(duckDuckGo, 200, <bytes>)`, and the query text appears in no recorded
    argument;
  - `testCancellationStopsAllSites`: every fake sees cancellation.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchSiteRunnerTests`.
  Expect failures.
- [ ] **Implement** `SearchSiteRunner`.
- [ ] **Run** the tests. Expect them to pass.

### Task 2.8: The upstream record, live checks and notice

**Files:**

- **`Enigma/Search/Engines/UPSTREAM.json`:** the ddgs tag `v9.16.1`, plus the
  blob SHA at that tag of `ddgs/engines/duckduckgo.py`, `mojeek.py`,
  `startpage.py` and `wikipedia.py`. Get each SHA with
  `gh api "repos/deedy5/ddgs/contents/ddgs/engines/<file>?ref=v9.16.1" --jq .sha`.
- **Create `EnigmaTests/WebSearchLiveTests.swift`.** It skips unless
  `ENIGMA_LIVE_SEARCH` is set.
- **`Enigma/Resources/ThirdPartyNotices.txt`:** add ddgs's MIT licence, with
  the copyright line copied from its repository, under the heading "ddgs
  (search engine definitions ported to Swift)".

**Steps:**

- [ ] **Write the live tests:**
  - `testLiveDuckDuckGo`, `testLiveMojeek` and `testLiveStartpage`: for the
    query "swift concurrency actors", each returns `.results` with at least
    5 results and no ad URLs;
  - `testLiveWikipedia`: "Alan Turing" returns an article whose text is over
    1,000 characters.
- [ ] **Add capture mode.** When `ENIGMA_SEARCH_FIXTURE_DIR` is set, each live
  test also writes its raw page to that folder.
- [ ] **Run the live checks:**
  `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1 scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchLiveTests`.
  Expect them to pass. Without the variable, expect 4 skipped.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass. The live
  tests skip in a normal run.
- [ ] The live checks pass on this Mac. Rerun them before
  committing.
- [ ] `plutil -lint Enigma.xcodeproj/project.pbxproj` passes.

## Reviewer checklist

- **XPaths** match ddgs v9.16.1 character for character, and the header
  comments are right.
- **No query text** reaches a log call, an error message or `UPSTREAM.json`.
- **Cooldown and pacing** state lives only in memory.
- **The Startpage rule** matches spec §2 exactly, including that a genuine
  `.noResults` from DuckDuckGo doesn't start it.
- **Cancellation:** an outer cancel stops every site request (check the fakes
  in `testCancellationStopsAllSites`).

## Hand-off

*Filled in by the CP2 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
