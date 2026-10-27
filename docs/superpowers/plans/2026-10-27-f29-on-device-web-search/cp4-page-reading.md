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
- **`http` links** are tried as `https` first, then as `http` if that fails.
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

*Filled in by the CP4 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
