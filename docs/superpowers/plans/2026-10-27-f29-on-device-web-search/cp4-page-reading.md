# CP4: Page reading

Read [agent-workflow.md](agent-workflow.md), the spec (§3.4, §4, §7), and
the Hand-offs of [CP0](cp0-spike.md#hand-off), where Q2 and Q3 cover WebKit,
and [CP3](cp3-quality-and-ranking.md#hand-off).

## Goal

Enigma can download a result page safely, extract its article text in a
sealed `WKWebView` running Readability.js, and judge it with the checks
after reading. Nothing calls this yet. CP5 wires it in.

## Starting point

- CP2's `SearchHTTPClient`, which follows no redirects, is in
  `Enigma/Search/SearchHTTPClient.swift`.
- CP3's `SourceQuality`, `FNV1a64` and the `SearchData` folder reference are
  in place.
- Readability.js isn't bundled yet.

## Tasks

### Task 4.1: The local-network guard

**Files:**

- Create `Enigma/Search/PageReader.swift`, registered in the app target.
- Test: create `EnigmaTests/PageReaderTests.swift`.

**Interfaces.** This task produces:

```swift
protocol HostResolver: Sendable { func addresses(for host: String) async throws -> [String] }  // numeric IPv4 or IPv6 strings
struct SystemHostResolver: HostResolver                    // getaddrinfo, off the main actor
struct NetworkGuard: Sendable {
  init(resolver: any HostResolver = SystemHostResolver())
  static func isAllowedName(_ host: String) -> Bool        // refuses localhost, single-label names, *.local, *.lan, *.internal, *.home.arpa
  static func isPublicAddress(_ address: String) -> Bool
  func allows(_ url: URL) async -> Bool                    // the name rule, then literal IPs, then every resolved address
}
```

**Refused addresses:**

- **IPv4:** `0.0.0.0/8`, `10/8`, `100.64/10` (CGNAT), `127/8`,
  `169.254/16`, `172.16/12`, `192.168/16` and `224/4` and above;
- **IPv6:** `::`, `::1`, `fe80::/10`, `fc00::/7` and `ff00::/8`;
- **IPv4-mapped IPv6** (`::ffff:a.b.c.d`), judged by its IPv4 address.

**Steps:**

- [ ] **Write the failing tests:**
  - `testRefusedHostNames`: `localhost`, `printer`, `nas.local`,
    `router.lan`, `x.internal` and `box.home.arpa`.
  - `testRefusedAddresses`: `10.0.0.1`, `172.16.5.4`, `192.168.1.1`,
    `127.0.0.1`, `169.254.1.1`, `100.64.0.1`, `224.0.0.1`, `0.0.0.0`, `::1`,
    `fe80::1`, `fc00::1`, `ff02::1`, `::` and `::ffff:192.168.0.1`.
  - `testPublicAddressesAllowed`: `93.184.216.34` and `2606:2800:220:1::1`.
  - `testHostResolvingToPrivateAddressIsRefused`: a fake resolver maps
    `evil.example` to `192.168.0.10`.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/PageReaderTests`.
  Expect failures.
- [ ] **Implement** `NetworkGuard` and `SystemHostResolver`.
- [ ] **Run** `PageReaderTests`. Expect them to pass.

### Task 4.2: Downloading pages

**Files:** add to `Enigma/Search/PageReader.swift`. Tests go in
`PageReaderTests`, with a fake `SearchHTTPClient`.

**Interfaces.** This task produces:

```swift
struct FetchedPage: Equatable, Sendable {
  enum Format: Equatable, Sendable { case html, text }
  let requestedURL: URL
  let finalURL: URL
  let format: Format
  let content: String
}
enum PageFetchOutcome: Equatable, Sendable { case page(FetchedPage), skipped, failed }
struct PageReader: Sendable {
  static let maximumBytes = 3_145_728
  static let maximumRedirects = 5
  init(client: any SearchHTTPClient, networkGuard: NetworkGuard, isBlocked: @escaping @Sendable (URL) -> Bool)
  func fetch(_ url: URL) async -> PageFetchOutcome
  static func decode(_ body: Data, contentType: String?) -> String?
}
```

**Rules, from spec §4:**

- **Requests:** one GET each, with `SafariHeaders.standard` and nothing else.
  No `Referer`, no `Cookie`.
- **`http` links** are tried as `https` first, then as `http` if that fails. *Amended overnight (orchestrator, owner to confirm): https only, no http fallback; ATS blocks plain http (D71).*
- **Every hop,** including the first, passes `networkGuard.allows` and
  `!isBlocked`.
- **Redirects:** at most 5, and only to `http` or `https`.
- **Content types:**

  | Type | Handling |
  | --- | --- |
  | `text/html`, `application/xhtml+xml` | `.html` |
  | `text/plain` | `.text` |
  | Anything else, including `application/pdf` | `.skipped` |

- **Decoding:** use the charset from the HTTP header, then the page's
  `<meta charset>` or `http-equiv` declaration within its first 2,048 bytes,
  then UTF-8, then Windows-1252.

**Steps:**

- [ ] **Write the failing tests:**
  - `testHttpLinksTryHttpsFirst`;
  - `testRedirectToPrivateAddressDropsPage`;
  - `testRedirectToBlockedSiteDropsPage`;
  - `testSixthRedirectDropsPage`;
  - `testPDFIsSkipped`;
  - `testPlainTextUsedDirectly`;
  - `testPageReadAtMostThreeMegabytes`: the client is called with
    `maximumBytes == 3_145_728`;
  - `testCharsetFromHeaderThenMetaThenUTF8ThenWindows1252`;
  - `testRequestsCarryOnlySafariHeaders`: no `Referer` and no `Cookie`.
- [ ] **Run** `PageReaderTests`. Expect failures.
- [ ] **Implement** `PageReader`.
- [ ] **Run** `PageReaderTests`. Expect them to pass.

### Task 4.3: `ArticleExtractor` and Readability.js

**Files:**

- Create `Enigma/Search/ArticleExtractor.swift`.
- Add `Enigma/Resources/SearchData/readability/`:
  - `Readability.js` and `Readability-readerable.js`, from the `0.6.0` tag of
    github.com/mozilla/readability;
  - its `LICENSE.md`;
  - `README.md`, recording the source URL, version and each file's SHA-256;
  - `EnigmaExtract.js`, which is Enigma's own.
- Test: create `EnigmaTests/ArticleExtractorTests.swift`. Fixtures go in
  `EnigmaTests/Fixtures/Search/articles/`. Write them yourself, with
  original text. Never copy a real article into the repository.

**Interfaces.** This task produces:

```swift
struct ArticleBlock: Equatable, Sendable {
  enum Kind: String, Sendable, Decodable { case paragraph, listItem, heading, code, tableRow }
  let kind: Kind
  let text: String
}
struct ExtractedArticle: Equatable, Sendable {
  let title: String
  let siteName: String?
  let byline: String?
  let language: String?
  let published: Date?
  let blocks: [ArticleBlock]
  let isReaderable: Bool
  var wordCount: Int { get }
}
protocol ArticleExtracting: Sendable {
  @MainActor func warmUp()
  @MainActor func extract(html: String, url: URL) async throws -> ExtractedArticle
}
enum ArticleExtractorError: Error, Equatable { case timedOut, scriptFailed, unavailable }
@MainActor final class ArticleExtractor: ArticleExtracting {
  static let shared: ArticleExtractor
  init(timeout: Duration = .milliseconds(500), idleRelease: Duration = .seconds(60),
       clock: any Clock<Duration> = ContinuousClock())
  var hasWebView: Bool { get }                    // for tests
}
```

**Configuration, from spec §4:**

- `WKWebsiteDataStore.nonPersistent()`;
- `defaultWebpagePreferences.allowsContentJavaScript = false`;
- a content rule list compiled from
  `[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]`;
- a navigation delegate that allows only the first load;
- no script message handlers;
- `loadHTMLString(html, baseURL: nil)`.

**Running the scripts.** After `didFinish`, run one `callAsyncJavaScript`
in `WKContentWorld.world(name: "EnigmaExtract")`. It contains the
Readability sources followed by `EnigmaExtract.js`, which:

1. reads `isProbablyReaderable(document)`;
2. collects `article:published_time` and JSON-LD `datePublished`;
3. runs `new Readability(document.cloneNode(true)).parse()`;
4. walks the result's content into ordered blocks;
5. returns JSON with the keys `title`, `siteName`, `byline`, `lang`,
   `publishedTime`, `readerable` and `blocks`.

**Lifetime and limits:**

- `warmUp()` creates the view if it doesn't exist.
- After the last extraction, the view is released after `idleRelease`.
- An extraction past `timeout` stops loading and throws `.timedOut`.

**Steps:**

- [ ] **Write the failing tests**, in `@MainActor` test methods with a real
  `WKWebView`:
  - `testExtractsNewsArticle`: `article-news.html` gives its title, the
    published date set in its meta tag, its site name and first paragraph,
    `isReaderable == true` and `wordCount > 300`.
  - `testDocsPageKeepsHeadingsAndCode`: blocks of kind `.heading` and
    `.code` appear, in page order.
  - `testScriptOnlyPageIsNotReaderable`.
  - `testPageScriptsNeverRun`: the page's inline script would replace a
    paragraph with `SCRIPT RAN`, and no block contains it.
  - `testNoSubresourceLoads`. An `NWListener` on 127.0.0.1 serves as the
    target of the page's `img`, `script`, `iframe` and stylesheet references.
    It counts 0 connections, measured 300 ms after extraction.
  - `testMetaRefreshDoesNotNavigate`: also 0 connections, and the blocks come
    from the original page.
  - `testExtractionTimesOut`: `ArticleExtractor(timeout: .milliseconds(1))`
    throws `.timedOut`.
  - `testIdleRelease`: with a test clock, `hasWebView` becomes false 60 s
    after the last extraction, and `warmUp()` recreates the view.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/ArticleExtractorTests`.
  Expect failures.
- [ ] **Implement** the extractor, and add the Readability files.
- [ ] **Run** the tests. Expect them to pass.
- [ ] **Add the notice.** Readability.js's Apache-2.0 notice goes into
  `ThirdPartyNotices.txt`.

### Task 4.4: Checks after reading

**Files:** add to `Enigma/Search/SourceQuality.swift`. Tests go in
`SourceQualityTests`.

**Interfaces.** This task produces the following. CP5 adds `offTopic`.

```swift
enum PageVerdict: Equatable, Sendable { case keep, notArticle, wall, wrongLanguage, offTopic, duplicate }
enum PageChecks {
  static let minimumWords = 120
  static let wallWordLimit = 400
  static let wallPhrases: [String]              // lowercase English: spec §3.4, plus "log in to continue", "are you a robot", "this content is for subscribers"
  static let duplicateThreshold = 0.6
  static func basic(_ article: ExtractedArticle, isWikipedia: Bool, allowedLanguages: Set<String>) -> PageVerdict
  static func shingles(_ text: String) -> Set<UInt64>             // 5-word shingles, hashed with FNV1a64
  static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double
  static func staleFactor(published: Date?, recency: SearchRecency?, now: Date) -> Double
}
```

**Language.** `NLLanguageRecognizer`'s dominant language counts only at a
hypothesis confidence of 0.8 or more. Compare base codes. A page whose
language can't be determined is kept.

**Staleness.** The factor is 0.5 when the page is older than 2 days for
`.day`, 14 days for `.week`, 60 days for `.month`, or 2 years for `.year`.
Otherwise it's 1.0.

**Steps:**

- [ ] **Write the failing tests:**
  - `testShortPageIsNotArticle`: 119 words gives `.notArticle`; 120 gives
    `.keep`.
  - `testWikipediaExemptFromLength`.
  - `testWallPhraseOnShortPage`: 350 words plus "Subscribe to continue"
    gives `.wall`; 500 words with the same phrase gives `.keep`.
  - `testWrongLanguageDropped`: a French page with `allowedLanguages = ["en"]`.
  - `testPreferredLanguagePageIsKept` (Review Focus 1): a Japanese page with
    `["en", "ja"]`.
  - `testNearDuplicateDetected`: two 200-word texts sharing 80% of their
    sentences have a Jaccard similarity of at least 0.6, and unrelated texts
    score under 0.1.
  - `testStaleFactor`:

    | Recency | Page age | Factor |
    | --- | --- | --- |
    | `.week` | 15 days | 0.5 |
    | `.week` | 13 days | 1.0 |
    | `.day` | 3 days | 0.5 |
    | any | no date | 1.0 |
    | none | any | 1.0 |

- [ ] **Run** `SourceQualityTests`. Expect failures.
- [ ] **Implement** `PageChecks`.
- [ ] **Run** `SourceQualityTests` and `ArticleExtractorTests`. Expect them
  to pass.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- [ ] The extractor makes no network connection for any fixture, and no page
  script runs.
- [ ] Readability's files match the SHA-256 values in their README.

## Reviewer checklist

- **Every hop is checked.** Each redirect passes the guard and the blocklist.
  Try a DNS name that resolves to `127.0.0.1`.
- **No page HTML is parsed in the app process.** Only WebKit parses it, and
  the app receives plain JSON back.
- **The extractor is cleaned up:** the view is released, an in-flight
  extraction can't leak continuations, and a timeout after Stop doesn't
  crash.
- **The fixtures contain original text only,** with no copied articles.

## Hand-off

*Filled in by the CP4 worker (overnight run, 2026-10-30; decisions D61–D68, D70 and D72; D69 and D71 are the orchestrator's).*

1. **Summary:** Enigma can now download a result page safely and turn it
   into plain article text. `NetworkGuard` refuses local names and private,
   loopback, link-local, CGNAT, multicast and unspecified addresses, written
   or resolved, on every hop, and the address each response really came
   from is checked too. `PageReader` reads pages over https only (an `http`
   link is read as `https`; ATS blocks plain http, D71), sends one GET per
   hop with `SafariHeaders.standard` only, follows at most 5 redirects (each guarded and checked against the
   blocklist), reads at most 3 MB, sorts content types, and decodes by BOM,
   header, `<meta>`, UTF-8, then Windows-1252. `ArticleExtractor` runs
   Readability 0.6.0 and `EnigmaExtract.js` in one sealed, hidden
   `WKWebView` (non-persistent store, page scripts off, block-all rule
   list, a delegate that allows only the first main-frame load, no message
   handlers) and gets back JSON: title, site, byline, language, publish and
   modified dates, ordered blocks and the readerable flag. `PageChecks`
   judges wall, not-an-article and wrong-language pages, near-duplicates
   and staleness. Nothing calls this yet; CP5 wires it in.
2. **Files:**
   - `Enigma/Search/PageReader.swift` (new): `HostResolver`,
     `SystemHostResolver`, `NetworkGuard`, `FetchedPage`,
     `PageFetchOutcome`, `PageReader`.
   - `Enigma/Search/ArticleExtractor.swift` (new): `ArticleBlock`,
     `ExtractedArticle`, `TextWords`, `ArticleDates`, `ArticleExtracting`,
     `ArticleExtractorError`, `ArticleExtractor`, `SealedNavigation`, and the
     private `ExtractionJob` and `SealedWebView`.
   - `Enigma/Search/SourceQuality.swift`: `PageVerdict` and `PageChecks`.
   - `Enigma/Search/SearchHTTPClient.swift` (round 1): `SearchHTTPResponse.remoteAddress`
     and the per-task `RemoteAddressCollector` (D69, D70).
   - `EnigmaTests/SearchTestSupport.swift` (round 1): a fake reply can carry
     a `remoteAddress`.
   - The spec (round 1): "Amended overnight" notes in §4 and §7 naming the
     stored rule-list file (D69).
   - `Enigma/Resources/SearchData/readability/` (new, inside the existing
     folder reference, so no project entry): `Readability.js`,
     `Readability-readerable.js`, `LICENSE.md` (0.6.0, unmodified),
     `README.md` (source, commit, SHA-256 values) and `EnigmaExtract.js`.
   - `Enigma/Resources/ThirdPartyNotices.txt`: Readability's Apache-2.0
     notice.
   - `Enigma.xcodeproj/project.pbxproj`: the two app files and two test
     files.
   - `EnigmaTests/PageReaderTests.swift` (new, with `FakeHostResolver`),
     `EnigmaTests/ArticleExtractorTests.swift` (new, with
     `LoopbackListener`), `EnigmaTests/SourceQualityTests.swift` (the
     `PageChecks` tests and `PageCheckFixture`),
     `EnigmaTests/WebSearchLiveTests.swift` (`testLivePageReading`, opt-in).
   - `EnigmaTests/Fixtures/Search/articles/` (new): five original HTML
     fixtures and their README; one row in `Fixtures/Search/README.md`.
   - `overnight-decisions.md`: D61–D68, D70, D72 (D65 corrected by D71).
   - The plan's progress log: the CP4 row.
3. **Decisions** (details in the log):
   - **D61:** Readability sits in `SearchData/readability/`, outside the
     lists' 3 MB budget (the budget check and the list script count only
     top-level files). The files match tag `0.6.0` (commit `04fd32f7`): a
     raw download and a shallow clone gave the same SHA-256, and CP0's copy
     is byte-identical.
   - **D62:** more date sources, in order; a `modified` date; a
     plausibility window (1995 to now plus two days); a URL-path date as
     the last resort. The JSON carries `publishedTimes` and
     `modifiedTimes` (arrays of strings) instead of one `publishedTime`,
     and Swift parses them (`ArticleDates`).
   - **D63:** one view; extractions take turns in arrival order, and each
     one's limit starts with its turn. A queued extraction that's cancelled
     leaves at once. Any failed extraction discards the view. The limits are
     named constants.
   - **D64:** the guard also refuses `.localhost`, `.localdomain`, `.home`,
     `.corp`, `.intranet` and `.onion`, `fec0::/10`, and IPv4-compatible
     and NAT64 forms of refused IPv4 addresses. It fails closed, and links
     with credentials are refused. New outcome `.refused`: use neither the
     page nor its snippet.
   - **D65 (corrected by D71):** no http fallback (https only); status
     handling; type-less responses sniffed for `<html`; a cut UTF-8 tail
     trimmed; BOM first; ISO-8859-1 and ASCII labels decode as
     Windows-1252.
   - **D66:** 12 more wall phrases (whole-word matches); order: wall, then
     not an article, then wrong language; a non-readerable page with 250 or
     more words is kept; CJK-aware word counts; Wikipedia exempt from the
     wall check too; the language check reads prose blocks only and needs
     200 letters.
   - **D67, revised by D69:** the rule list lives in WebKit's default
     store as `EnigmaBlockAll-v1`, looked up at each launch and compiled
     only when missing; the unversioned `EnigmaBlockAll` entry is removed
     the one time v1 is compiled. One static file per rule version, holding
     only the rule text.
   - **D71 (orchestrator), D72:** review round 2. App Transport Security
     blocks plain http, so pages are https only: no http attempt or
     fallback, and a redirect to http is `.failed` (after the blocklist and
     guard checks, so a blocked or local target is still `.refused`). This
     corrects D65's fallback and spec §4 (amended). A byte-order mark now
     decodes leniently (UTF-8 and UTF-16, cut tails dropped). The proxy
     rule is `URLSessionSearchHTTPClient.reachedAddress(_:)`.
   - **D69 (orchestrator), D70:** review round 1's fixes. The guard answers
     allowed, refused or unresolved; unresolved (lookup error, empty
     answer, cancellation) gives `.failed`, not `.refused`. UTF-8 decodes
     with replacement characters unless more than half the non-ASCII bytes
     are invalid. A response whose connection reached a non-public address
     (`URLSessionTaskTransactionMetrics.remoteAddress`) is `.refused`,
     redirects included; through a proxy the address is unknown and the
     page is kept.
   - **D68:** extracted text capped at 200,000 characters, 20,000 per
     block.
   - Also: `SystemHostResolver` answers a cancelled caller at once, because
     `getaddrinfo` can't be cancelled (Review Focus 3, Stop). JSON-LD is
     read by a string scan of the HTML passed into the isolated world as an
     argument (CP0 Q2), never parsed in the app. `<noscript>` content is
     live DOM with scripts off; Readability removes it before extraction,
     so it doesn't reach the blocks. The navigation rule is a pure function
     (`SealedNavigation.allows`) so it's tested on its own: the rule list
     already blocks a meta refresh, so a broken delegate passed every
     WebKit test (mutant M3 below).
4. **Verification** (logs in a scratch folder outside the repository):
   - RED: `scripts/verify-xcode.sh test
     -only-testing:EnigmaTests/PageReaderTests
     -only-testing:EnigmaTests/ArticleExtractorTests
     -only-testing:EnigmaTests/SourceQualityTests`, against compiling
     stubs: 71 executed, 43 tests failed (127 assertion failures).
   - GREEN, the same three classes plus `WebSearchLiveTests`: 77 executed,
     3 skipped (the live tests), 0 failed. The first GREEN run failed 4
     tests: three asserted the docs title without the " - Lantern Docs"
     Readability keeps (now `hasPrefix`), and one found the recognizer calls
     a page of model numbers Polish, which D66 (6) fixed. In that test I
     also removed a case I had written myself, expecting mixed English,
     French and German text to stay undetermined: the recognizer gives it
     English at 99.7%, so the premise was wrong, not the code.
   - Mutants, in a scratch copy, `ArticleExtractorTests` or
     `PageReaderTests` only: M1, no rule list installed: 52 connections,
     `testNoSubresourceLoads` failed. M2, page scripts on:
     `testPageScriptsNeverRun` failed. M3, the delegate allows every
     navigation: no WebKit test failed (the rule list stops the refresh),
     hence `testOnlyTheFirstMainFrameLoadIsAllowed`. M4, the resolver
     ignores cancellation: `testSystemResolverReturnsOnCancellation`
     failed. `testNoSubresourceLoads` also runs a control: an unsealed view
     with scripts off does reach the listener.
   - `scripts/verify-xcode.sh build`: succeeded, no warnings in the new
     files; the built app holds `SearchData/readability/`. It ran before the
     resolver's cancellation change; the later test run built the app
     target too.
   - Live check: `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1 scripts/verify-xcode.sh
     test -only-testing:EnigmaTests/WebSearchLiveTests
     -skip-testing:EnigmaTests/WebSearchLiveTests/testLiveDuckDuckGo
     -skip-testing:EnigmaTests/WebSearchLiveTests/testLiveWikipedia`:
     1 executed, 0 failed. Six public pages (fixed in the test):

     | Page | Size | Fetch | Extract | Words | Verdict | Dates |
     | --- | --- | --- | --- | --- | --- | --- |
     | Wikipedia article (`http` link) | 1.33 M chars | 232 ms | 386 ms | 17,448 | keep | published, modified |
     | RFC 9110 | 1.18 M chars | 177 ms | timed out at 505 ms | — | — | — |
     | Python docs | 116 K | 67 ms | 94 ms | 3,799 | keep | none |
     | GOV.UK bank holidays | 176 K | 81 ms | 30 ms | 2,489 | keep | published, modified |
     | NHS condition page | 43 K | 1,346 ms | 93 ms | 746 | keep | modified only |
     | Apple docs (script-rendered) | 18 K | 229 ms | 15 ms | 0 | notArticle | none |

   - **Review round 1** (orchestrator's reviewer): no Blockers, 4 Should
     fixes, plus a fifth from the orchestrator (D69), all fixed test-first
     (D70):
     1. a cancelled or failed lookup came back `.refused`, losing the
        snippet → three guard answers;
     2. one invalid byte sent a declared-UTF-8 page to Windows-1252 →
        UTF-8 with replacement unless mostly invalid;
     3. the rule list was recompiled (a file rewritten) every launch →
        versioned identifier, looked up first;
     4. no test pinned the sealed configuration →
        `SealedWebView.makeConfiguration(contentController:)` and
        `testSealedConfiguration`, plus `testNoScriptMessageHandlers`
        (`window.webkit` is undefined in the page, client and
        `EnigmaExtract` worlds);
     5. responses from non-public addresses are dropped.

     RED, against compiling stubs, the four CP4 classes: 86 executed,
     3 skipped, 7 tests failed (20 failures): `testCancelledLookupFails`,
     `testLookupErrorFailsRatherThanRefuses`, `testGuardHasThreeAnswers`,
     `testDeclaredUTF8KeepsTextAroundOneBadByte`,
     `testResponseFromNonPublicAddressIsRefused`,
     `testClientReportsRemoteAddress` (a loopback HTTP server, offline) and
     `testRuleListIsVersionedAndKeptAcrossLaunches`. The two configuration
     tests passed at once: they pin behaviour that was already right.
     GREEN: `PageReaderTests` 31, `ArticleExtractorTests` 18,
     `SourceQualityTests` 34, `WebSearchLiveTests` 3 (skipped): 86
     executed, 3 skipped, 0 failed. `SearchHTTPClientTests`,
     `SearchEngineTests` and `SearchSiteRunnerTests`, which the client change
     touches, ran too: 65 executed, 0 failed.
   - **Review round 2** (orchestrator's reviewer): no Blockers, 4 Should
     fixes, all fixed test-first (D71, D72); no round 3 (D71):
     1. a byte-order mark still decoded strictly → lenient UTF-8 and UTF-16;
     2. plain http never works under ATS → https only;
     3. D70's proxy case was untested → `reachedAddress(_:)` and
        `testProxiedAddressIsUnknownAndPrivateIsRefused`;
     4. the rule-list test rewrote the installed app's store → a store in
        a temporary folder, checking the file's inode and modification
        date don't change on the second call.

     RED: `PageReaderTests` and `ArticleExtractorTests`, 52 executed, 4
     tests failed (9 failures): `testByteOrderMarkDecodesLeniently`,
     `testHttpLinksTryHttpsFirst` (now expecting no http fallback),
     `testProxiedAddressIsUnknownAndPrivateIsRefused`,
     `testRedirectToHttpFails`. GREEN: `PageReaderTests` 34,
     `ArticleExtractorTests` 18, `SourceQualityTests` 34,
     `WebSearchLiveTests` 3 (skipped), `SearchHTTPClientTests` 8,
     `SearchEngineTests` 39, `SearchSiteRunnerTests` 18: 154 executed,
     3 skipped, 0 failed.
   - **Final checks:**
     - `scripts/verify-xcode.sh build`: succeeded; `analyze`: succeeded,
       no warnings in the CP4 files.
     - Live check rerun (same command): 1 executed, 0 failed; all six pages
       read. Wikipedia 296 ms, RFC 9110 210 ms (it timed out at 505 ms in
       the first run, so the limit is marginal for 1 MB pages), Python docs
       39 ms, GOV.UK 26 ms, NHS 71 ms, Apple docs `notArticle` as before.
     - Full suite, `scripts/verify-xcode.sh test -test-timeouts-enabled YES
       -default-test-execution-time-allowance 60` (D31): 1,838 tests: 1,723
       passed, 34 skipped, 81 failed. The 81 are the same nine hosted-UI
       classes with the same counts as CP1b, CP2 and CP3 (D25, D32):
       AppCommandTests 2, ChatCopyTests 2, ComposerIntentChipsTests 2,
       EnigmaCompactPanelTests 15, EnigmaConversationTests 18,
       EnigmaMainWindowTests 29, FileModeUITests 1, ScreenCaptureTests 1,
       ScreenViewTests 11. None is in a Search class, so all 81 are
       environment failures, left for CI. The 62 tests above CP3's 1,776
       are CP4's.
5. **Limitations:**
   - **Pages over about 1 MB can miss the 500 ms extraction limit**
     (RFC 9110 did; Wikipedia's 1.3 MB page took 386 ms). CP5 and CP7
     should measure and tune: a longer limit (the speed bar allows it,
     D2), a smaller HTML cap before extraction, or a pool of views (D63).
   - Pages over plain http aren't read at all (ATS, D71); their snippets
     stay usable.
   - Extractions are serial on one view, so six pages at 30–400 ms each
     can use much of a 2.5 s window.
   - DNS rebinding: the remote-address check (D69) drops what a rebinding
     name serves from a private address, but the GET has already been sent
     by then, and the check is skipped through a proxy.
   - **From review round 1, for CP7:** the first `<time>` element ranks
     above the date in the URL (D62), which may pick a comment's or a
     related story's date; and keeping non-readerable pages of 250 or more
     words (D66 (3)) departs from spec §3.4, so CP7 should check it doesn't
     let listing or index pages through.
   - `getaddrinfo` keeps running after a cancelled lookup; only its answer
     is dropped.
   - Dates are only as good as the page's metadata; the URL-path date and
     the first `<time>` element are heuristics.
   - The live check ran once, from this Mac's network, on 2026-10-30.
   - The WebKit tests need the hosted test app (a real `WKWebView`); they
     passed overnight without a key window.
   - **macOS 26 (added by the CP5 worker, D77, D78):** CI (Xcode 26.6,
     macOS 26) failed four `ArticleExtractorTests` on 44e4711. The
     "InvalidTransition" text in the log comes from Apple's private Gestures
     framework when a view is released; the failures were most likely the
     500 ms limit on a slow runner (they ended at 0.585–0.795 s). CP5 gives the
     content tests a 10 s limit through a helper (`testExtractionTimesOut`
     still pins the limit), warms the WebContent process with a blank page in
     `warmUp`, and re-warms after a failed extraction. CI is the check.
6. **For the next checkpoint (CP5):**
   - Build: `PageReader(client: URLSessionSearchHTTPClient.live,
     networkGuard: NetworkGuard(), isBlocked: quality.isBlocked)` (the
     client is shared; `PageReader` asks for 3 MB per hop). Then
     `ArticleExtractor.shared.extract(html:url:)` on `.html` pages. A
     `.text` page has no extractor step; split its content into paragraphs
     yourself.
   - Outcomes: `.page`, `.skipped` (keep the snippet), `.failed` (keep the
     snippet; this includes a lookup that failed or was cancelled), `.refused`
     (drop the page and its snippet).
   - Call `ArticleExtractor.shared.warmUp()` when a search starts (spec
     §4). Extraction runs on the main actor's view but decodes and counts
     words off it. Pass `timeout:` from `OnDeviceSearchTiming` if you make
     a non-shared extractor; `ArticleExtractor.defaultTimeout` is 500 ms.
   - Errors: `.timedOut`, `.scriptFailed`, `.unavailable` (scripts or rule
     list missing), and `CancellationError`. All mean "page not read".
   - `PageChecks.basic(_:isWikipedia:allowedLanguages:)` takes the
     question's language plus `Locale.preferredLanguages`; codes are
     compared by base (`PageChecks.baseLanguage`). An empty set keeps every
     language. Wikipedia text from the API can go through it as an
     `ExtractedArticle` with `isWikipedia: true`.
   - Recency: `PageChecks.staleFactor(published:recency:now:)` uses
     `published` only; `ExtractedArticle.modified` is there if you want
     `published ?? modified` (D62).
   - Duplicates: `PageChecks.jaccard(shingles(a), shingles(b)) >=
     duplicateThreshold`; shingle each page once.
   - The pages-read count is still `RankingTuning.readBatch` (6), and every
     check value is a named constant in `PageChecks`.
   - Tests: `FakeHostResolver` (in `PageReaderTests.swift`) resolves any
     name to a public address unless told otherwise; `LoopbackListener`
     (in `ArticleExtractorTests.swift`) counts connections on 127.0.0.1.
   - Interface additions beyond the brief: `PageFetchOutcome.refused`;
     `PageReader.init(…, acceptLanguage:)` and `.charsetScanBytes`;
     `NetworkGuard.refusedSuffixes`, `.Verdict`, `.check(_:)`,
     `.isPublicRemoteAddress(_:)`; `SearchHTTPResponse.remoteAddress`,
     `URLSessionSearchHTTPClient.metricsWait`; `SealedWebView` (internal,
     with `makeConfiguration(contentController:)`);
     `ArticleExtractor.ruleList()`, `.storedRuleList(in:)`,
     `.retiredRuleListIdentifiers`; `SystemHostResolver.init(lookUp:)` and
     `.getAddresses`; `ExtractedArticle.modified` (an init parameter
     defaulting to nil; `wordCount` is stored); `TextWords`; `ArticleDates`;
     `SealedNavigation`; `ArticleExtractor.defaultTimeout`,
     `.defaultIdleRelease`, `.contentWorldName`, `.ruleListIdentifier`,
     `.blockAllRules`; `PageChecks.minimumWordsWhenNotReaderable`,
     `.shingleWords`, `.languageConfidence`, `.languageSampleCharacters`,
     `.languageMinimumLetters`, `.stalePenalty`, `.staleAfter`,
     `.baseLanguage(_:)`.
