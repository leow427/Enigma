# CP2: Search sites

Read [agent-workflow.md](agent-workflow.md), the spec (§2, plus §7 for
logging), and the Hand-offs of [CP0](cp0-spike.md#hand-off),
[CP0b](cp0b-second-probe.md#hand-off), [CP1](cp1-foundations.md#hand-off)
and [CP1b](cp1b-routing-fixes.md#hand-off). CP0's and CP0b's findings decide
the parser (Q1, and CP0b's Q3) and site behavior (Q4–Q6, and CP0b's Q1–Q2).

## The owner's lineup comes first

This brief was written for the full lineup: DuckDuckGo, Mojeek and
Wikipedia, with Startpage as the backup. **CP0b's Hand-off records the
owner's decision**, and it overrides this brief:

- **A dropped site:** skip its task (2.3 Mojeek, 2.4 Startpage), its
  `SearchEngineID` case, its fixtures' tests, its live check, its
  `UPSTREAM.json` entry and its weight in spec §3.3. If Startpage is
  dropped, Task 2.7's Startpage rule goes too: the runner queries the
  primaries only.
- **A replaced site:** stop and ask the owner for the brief changes before
  building it.
- **The header set** (A or B from CP0b) replaces `SafariHeaders.standard`'s
  fields in Task 2.1 if the owner chose A.
- **`kl`:** if the owner chose it, DuckDuckGo's form sends `kl=<region>`
  instead of `l=<region>` (Task 2.2), and the live check confirms the echoed
  value.

Record in the Hand-off which tasks you skipped or changed, and why.

## Goal

Enigma can query the sites the owner kept, plus Wikipedia, itself. It
parses their pages, notices blocks and layout changes, backs off, and
applies spec §2's Startpage rule if Startpage stays. Nothing calls this yet.
CP5 wires it in.

## Starting point

- CP1's `WebSearchRequest`, `SearchRecency` and `WebSearchLimits` are in
  `Enigma/Search/WebSearch.swift`.
- Sanitized fixtures from CP0 and CP0b are in `EnigmaTests/Fixtures/Search/`,
  listed in their README. CP0b may have added Mojeek and Startpage results
  pages; without them, a kept site's parsing tests wait for a capture from
  the live check (Task 2.8), saved through `ENIGMA_SEARCH_FIXTURE_DIR`.
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

  *Amended overnight (orchestrator, owner to confirm):* an unexpected 3xx,
  400, 404, 405 or 410 is `.unrecognized` (logged with status and size, and
  it starts the cooldown), since it means the port needs updating. 413, 414,
  other 5xx and any other status stay `.failed`, logged with status and size;
  a thrown error or timeout stays `.failed` with nothing logged or recorded.
  403 and 503 stay `.blocked`, as the row above says (decisions D47, D48).

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
  *Amended overnight (orchestrator, owner to confirm):* timeouts and
  network errors (`.failed`) record nothing; `.blocked`, `.unrecognized`
  and a second consecutive `.rateLimited` start or climb the cooldown; a
  single `.rateLimited` leaves a strike that the next success clears
  (decision D41).
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

- [ ] `scripts/verify-xcode.sh build` and `analyze` pass, the engine test
  classes pass, and the full `test` runs once before the commit. The live
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

*Filled in by the CP2 worker (overnight run, 2026-10-30; decisions D33–D43 and D45–D48).*

1. **Summary:** Enigma can now query DuckDuckGo and Wikipedia itself, the
   owner's lineup after CP0b. `SearchHTTPClient` is an ephemeral URLSession
   with no cookies, cache, credentials or redirects that stops reading at a
   byte limit. `SafariHeaders` sends header set A. `DuckDuckGoEngine` ports
   ddgs v9.16.1 (`kl` for the region) and tells results, no results, rate
   limits, blocks and layout changes apart. `WikipediaSearch` uses the
   official API. `EngineHealth` keeps backoff and pacing in memory, and
   `SearchSiteRunner` runs DuckDuckGo and Wikipedia together, each with a
   2.0 s limit. Nothing calls this yet; CP5 wires it in. Skipped, per the
   owner's lineup (D33): Task 2.3 (Mojeek), Task 2.4 (Startpage), Task 2.7's
   Startpage rule and `startpageBudget`, `testLiveMojeek` and
   `testLiveStartpage`, and their `UPSTREAM.json` entries.
2. **Files:**
   - `Enigma/Search/SearchHTTPClient.swift` (new): `SearchHTTPResponse`,
     `SearchHTTPClient`, `URLSessionSearchHTTPClient`, `SafariHeaders`.
   - `Enigma/Search/Engines/SearchEngine.swift` (new): the engine types,
     `SERPDocument`, `SearchFormEncoding`, `SearchLogging`/`OSSearchLog`,
     `EngineHealth`.
   - `Enigma/Search/Engines/DuckDuckGoEngine.swift` (new): the port.
   - `Enigma/Search/Engines/WikipediaSearch.swift` (new): search, extract,
     disambiguation skip, 30,000-character cap, language edition.
   - `Enigma/Search/Engines/SearchSiteRunner.swift` (new): the runner.
   - `Enigma/Search/Engines/UPSTREAM.json` (new, in no target): ddgs tag,
     commit and the blob SHAs of `duckduckgo.py` and `wikipedia.py`.
   - `Enigma/Resources/ThirdPartyNotices.txt`: ddgs's MIT licence.
   - `Enigma.xcodeproj/project.pbxproj`: the five app files and five test
     files.
   - `EnigmaTests/SearchTestSupport.swift` (new): `ManualClock`,
     `FakeSearchHTTPClient`, `SearchFixture`, `formFields`.
   - `EnigmaTests/SearchHTTPClientTests.swift`, `SearchEngineTests.swift`,
     `SearchSiteRunnerTests.swift`, `WebSearchLiveTests.swift` (new).
   - `EnigmaTests/Fixtures/Search/`: `duckduckgo-no-results.html` (captured,
     D36), `duckduckgo-changed.html`, `duckduckgo-ads.html`,
     `wikipedia-search.json`, `wikipedia-extract.json` (synthetic), and
     their README rows.
   - `overnight-decisions.md`: D33–D40, D43, D46 and D48 (D41, D42, D45 and D47 are the orchestrator's).
3. **Decisions** (details in the decision log):
   - **D33:** the lineup; `SearchEngineID` has only `.duckDuckGo`. The three
     Startpage runner tests are replaced by tests of the rules that remain
     (cooling-down skip, timeout, outcomes and health, pacing).
   - **D34:** header set A needs GET and POST variants, so
     `SafariHeaders.standard(acceptLanguage:)` is the GET set (with
     `Sec-Fetch-Site: none` and `Priority: u=0, i`), and the new
     `formPost(to:acceptLanguage:)` adds `same-origin`, `Origin` and
     `Referer`. DuckDuckGo sends `kl`.
   - **D35, D42:** `kl` uses DuckDuckGo's own region values
     (`DuckDuckGoEngine.regionCode(for:)`: `gb` gives `uk-en`, `jp` gives
     `jp-jp`), taken from the region menu on its own results page (D42),
     and `wt-wt` for countries it doesn't list. `SearchRegion.code` stays
     `<country>-<language>`.
   - **D36:** one extra live request found DuckDuckGo's real "no results"
     page. Empty means a `no-results`/`result--no-result` marker, or a page
     of nothing but ads. Items without a usable link are `.unrecognized`.
   - **D41, D43, D45, D46:** a timeout or network error (`.failed`)
     records nothing; `.blocked` and `.unrecognized` climb the ladder. A
     `.rateLimited` (202 or 429) leaves a strike holding the query's
     in-memory fingerprint (`EngineHealth.recordRateLimited(_:query:)`).
     That query is skipped, with no request, for 60 s (`isSkipped`). A
     challenge for a different query while the strike is pending climbs
     the ladder, and a success clears it. The skipped query's lane comes
     back `.rateLimited`, and nothing is recorded (D47).
   - **D47, D48:** an unexpected 3xx, 400, 404, 405 or 410 is
     `.unrecognized` (logged, starts the cooldown). 413, 414 and other 5xx
     are `.failed` and logged through the new `SearchLogging.failedPage`.
     403 and 503 stay `.blocked`, as the brief's row says. After the pacing
     wait the runner checks both the cooldown and the per-query skip. The cooldown is checked
     again after the pacing wait.
   - **D37:** a cooling-down skip and a cancelled run record nothing; a
     failure while already cooling down doesn't climb the ladder; the new
     `EngineHealth.reservePacingSlot(_:)` checks and books the pacing slot
     in one call, and the wait comes before the 2.0 s timeout; Wikipedia
     isn't in `EngineHealth`. The runner reads an unrecognized page's status
     and size through a wrapper client, so `EngineOutcome` is unchanged.
   - **D38:** one DuckDuckGo page (about 10 results) and 3 Wikipedia hits
     per search. ddgs's page field is ported
     (`DuckDuckGoEngine.request(for:page:)`) but unused.
   - **D39:** the 30 Wikipedia editions leave out the bot-generated ones;
     `nb`/`nn` use `no`.
   - **D40:** on the synthetic `duckduckgo-ads.html`, `NSXMLNode` evaluates
     a relative `…//text()` wrongly (`./a//text()` also returns later
     results' text), so `SERPDocument.text` collects descendant text itself
     for paths ending in `//text()`. On the real `duckduckgo-results.html`
     plain XPath and the workaround give identical text, so only
     `testDuckDuckGoDropsAds` guards it. The XPath strings stay verbatim.
   - Also: `testDuckDuckGoRequestIsFormPost` expects `kl` rather than the
     brief's `l` (owner, CP0b). Query and title values are percent-encoded
     over RFC 3986's unreserved set, so `+`, `&` and `=` stay data
     (URLComponents leaves `+` raw). Wikipedia's extract is read with
     `JSONSerialization`; a truncated or non-200 response is `.failed`.
     Results with an empty title are dropped, as are non-http(s) links.
4. **Verification** (`scripts/verify-xcode.sh`, logs outside the repo):
   - RED: `test -only-testing:EnigmaTests/SearchHTTPClientTests
     -only-testing:EnigmaTests/SearchEngineTests
     -only-testing:EnigmaTests/SearchSiteRunnerTests
     -only-testing:EnigmaTests/WebSearchLiveTests`, against compiling
     stubs: 50 executed, 2 skipped, 46 failed.
   - GREEN, the same command: 51 executed, 2 skipped (the live tests),
     0 failed. `SearchSiteRunnerTests` and `SearchHTTPClientTests` with
     `-test-iterations 10 -run-tests-until-failure`: 160 executed,
     0 failed.
   - `testDuckDuckGoDropsAds` failed on the first GREEN run, before D40's
     fix, because the synthetic page's snippet held later results' text. The linkless-items
     row of `testDuckDuckGoChangedLayoutIsUnrecognized` and
     `testDuckDuckGoPageOfAdsIsNoResults` were written together with D36's
     rule, not before it.
   - `build`: succeeded, with no warnings in the new files.
   - Live check: `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1
     TEST_RUNNER_ENIGMA_SEARCH_FIXTURE_DIR=<scratch> scripts/verify-xcode.sh
     test -only-testing:EnigmaTests/WebSearchLiveTests`: 2 executed,
     0 failed. DuckDuckGo: HTTP 200, 30 KB, 10 results, 624 ms, `kl=us-en`
     echoed. Wikipedia ("Alan Turing"): 2 requests, 30,000 characters (the
     cap), 439 ms. The D36 probe: HTTP 200, 722 ms. Raw pages stay in the
     scratch folder. In all, DuckDuckGo got 2 requests and Wikipedia 2.
   - `plutil -lint Enigma.xcodeproj/project.pbxproj`: OK.
   - Before review, the orchestrator's instructions were to run neither the
     full suite nor `analyze`. Both ran after round 3, below.
   - Review round 1 (Opus, xhigh): no Blockers, 4 Should fixes, all fixed
     (D41–D43):
     1. timeouts and network errors no longer cool DuckDuckGo down, and a
        lone 202 doesn't either;
     2. `testClientKeepsNoCookies` couldn't fail (the stub bypasses cookie
        handling), so the new `testSessionStoresNothing` checks the
        session's settings;
     3. the cooldown is checked again after the pacing wait;
     4. the region table is rebuilt from DuckDuckGo's own menu.

     The fixes went in before their tests. Every new or changed test was
     then shown to fail in a scratch copy with the old behavior restored
     (pacing re-check removed, `.failed`/`.rateLimited` recording failures,
     cookie storage left on, a code DuckDuckGo doesn't list, no strike).
     8 tests failed there. After the fixes, the four classes ran 58
     executed, 2 skipped, 0 failed. The live check wasn't rerun.
   - Review round 2 (Opus, xhigh; it also ran `analyze`, which succeeded):
     no Blockers, 1 Should fix, fixed test-first (D45, D46). Retrying a
     challenged query gave a second 202 and cooled DuckDuckGo down for
     every query. Now that query alone sits out 60 s. RED: 3 tests failed
     (`testChallengedQuerySitsOutAMinute`,
     `testSameChallengedQueryIsSkippedForAMinute`,
     `test429BehavesLike202`). GREEN: the four classes ran 62 executed,
     2 skipped, 0 failed.
   - Review round 3 (Opus, xhigh): no Blockers, 3 Should fixes and 2
     surviving mutants, all fixed test-first (D47, D48):
     1. the pacing wait now re-checks the per-query skip;
     2. unexpected statuses are logged, and those that mean a changed site
        climb the ladder;
     3. a skipped query reports `.rateLimited`.

     RED: 57 executed, 18 failures in 6 tests. The two mutant-killing
     tests (`testDifferentQueryChallengeClearsTheStrike`,
     `testSkippedQueryBooksNoPacingSlot`) passed on the real code and each
     failed on its mutant in a scratch copy. GREEN: the four classes ran 67
     executed, 2 skipped, 0 failed. There was no round 4 (D47).
   - Final checks after round 3:
     - live check rerun: DuckDuckGo HTTP 200, 30 KB, 10 results, 601 ms,
       `kl` echoed; Wikipedia 2 requests, 30,000 characters, 467 ms;
     - `build` succeeded; `analyze` succeeded, with no warnings in the new
       files;
     - full suite: `test -test-timeouts-enabled YES
       -default-test-execution-time-allowance 60` (D31, screen locked):
       1,723 tests, 1,609 passed, 33 skipped, 81 failed. The failures are
       the same nine hosted-UI classes, with the same counts, as CP1b's 81
       (D32): AppCommandTests 2, ChatCopyTests 2, ComposerIntentChipsTests 2,
       EnigmaCompactPanelTests 15, EnigmaConversationTests 18,
       EnigmaMainWindowTests 29, FileModeUITests 1 (hung, stopped at 60 s),
       ScreenCaptureTests 1, ScreenViewTests 11. They fail with "Timed out
       waiting for visible control", the shortcut test's "must be
       frontmost", a key-window assertion or an undrawn animation. None is
       in a Search class, so all 81 are environment failures under D25, left
       for CI.
5. **Limitations:**
   - DuckDuckGo is the only web index. When it is challenged (HTTP 202
     answered about 1 in 4 requests in CP0 and CP0b, always on the same
     query), times out or cools down, a search has Wikipedia alone. After
     D41, timeouts don't cool it down, but CP5 and CP7 should watch the
     timeout rate and tune `SearchSiteRunner.primaryTimeout` if it bites
     (the speed bar allows it, D2).
   - Disambiguation is detected by the English "may refer to:" only, so
     other editions may return a disambiguation page.
   - The region table (D35) is unverified live outside `us-en`.
   - The 50-word/400-character query cap (spec §2) isn't applied here;
     CP5 builds the query.
   - `docs/Testing.md` doesn't list `ENIGMA_LIVE_SEARCH` yet (CP10's docs).
   - The live check ran twice (before review and after round 3), each time
     from this Mac's network only.
6. **For the next checkpoint:**
   - Build the runner with `SearchSiteRunner(engines: [.duckDuckGo:
     DuckDuckGoEngine()], wikipedia: WikipediaSearch(), client:
     URLSessionSearchHTTPClient.live, health: .shared, log: OSSearchLog())`.
     `includeWikipedia` should be false for day and week recency (spec §2).
     A skipped site comes back `.failed`, and Wikipedia not asked for
     comes back `.none`.
   - `SearchRegion.current()` gives the region; DuckDuckGo maps it to `kl`
     itself.
   - **For CP5:** a DuckDuckGo lane of `.rateLimited` may come from the
     per-query skip (the same query challenged in the last minute, D45,
     D47), with no request sent. Treat it like any rate limit: the spec's
     `rateLimited` message when nothing else answered.
   - `SERPDocument.text` must stay the only way to read `//text()` paths
     (D40). `XMLNode.nodes(forXPath:)` with a relative `//text()` is wrong
     on this parser.
   - `SearchFormEncoding.percentEncode` is the safe encoder for query
     values; `PageReader` (CP4) can reuse `URLSessionSearchHTTPClient` with
     `SafariHeaders.standard` and a 3 MB limit.
   - Tests: `FakeSearchHTTPClient.stub(_:_:)` matches exact URLs, and
     `stub(where:_:)` matches a predicate (later rules win). `.hang` waits
     until cancelled and counts `cancellations`. `ManualClock.waitForSleepers(_:)`
     waits until the code under test is sleeping. `TestInstant` (in
     `SearchEngineTests.swift`) drives `EngineHealth`, and `FakeEngine` and
     `RecordingSearchLog` live in `SearchSiteRunnerTests.swift`.
   - Interface additions beyond the brief: `SafariHeaders.formPost(to:acceptLanguage:)`
     and `.preferredAcceptLanguage`; `URLSessionSearchHTTPClient.configuration`;
     `EngineHealth.reservePacingSlot(_:)`, `.recordRateLimited(_:query:)`, `.isSkipped(_:query:)` and `SearchLogging.failedPage(engine:status:bytes:)`, and
     `.pacingInterval`; `DuckDuckGoEngine.request(for:page:)`,
     `.regionCode(for:)`, `.regionCodes`, `.maximumBytes`; `WikipediaSearch.searchRequest(for:language:)`,
     `.extractRequest(title:language:)`, `.articleURL(title:language:)`,
     `.searchLimit`, `.maximumCharacters`, `.editions`; `SearchFormEncoding`.
     Removed from the brief's interface: `SearchEngineID.mojeek`,
     `.startpage` and `SearchSiteRunner.startpageBudget`.
