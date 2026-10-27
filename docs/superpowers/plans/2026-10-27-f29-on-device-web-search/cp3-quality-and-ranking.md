# CP3: Quality data and ranking

Read [agent-workflow.md](agent-workflow.md), the spec (§3, §7), and the
Hand-offs of [CP1](cp1-foundations.md#hand-off) and
[CP2](cp2-search-sites.md#hand-off).

## Goal

Search results can be cleaned, merged, scored, filtered and picked for
reading, using bundled quality lists and the user's blocked sites. The lists
come from a refresh script and ship inside the app. This checkpoint doesn't
read any pages (CP4) or touch the UI (CP8).

## Starting point

- CP2's `EngineResult`, `SearchEngineID` and the engine weights (DuckDuckGo
  1.0, Startpage 1.0, Mojeek 0.8) are in
  `Enigma/Search/Engines/SearchEngine.swift`.
- `Enigma/Search/WebSearchSettings.swift` holds the automatic-search switch
  and the Brave key. Its blocked-sites list is new in this checkpoint.
- `Enigma/Resources/SearchData/` doesn't exist yet.
- Python script tests live in `scripts/tests/` and run with
  `python3 -I -B -m unittest discover -s scripts/tests`.

## Tasks

### Task 3.1: The list refresh script

**Files:**

- Create `scripts/update-search-lists.py`, standard library only.
- Create `scripts/tests/test_update_search_lists.py`, with fixtures in
  `scripts/tests/fixtures/search-lists/`.

**Interfaces.** This task produces the files in `Enigma/Resources/SearchData/`:

| File | Contents |
| --- | --- |
| `unsafe.bin`, `spam.bin` | Sorted little-endian `UInt64` FNV-1a-64 hashes of lowercase domains |
| `reliability.tsv` | `domain<TAB>status`, where the status is `gr`, `nc`, `gu`, `d` or `b` |
| `authority.txt` | Suffix rules starting with `.` (`.gov`) and plain domains, one per line |
| `unreadable.txt` | One domain per line |
| `enigma-blocked.txt` | One domain per line; a comment header only, at first |
| `public_suffix_list.dat` | Mozilla's Public Suffix List |
| `manifest.json` | Described below |

**`manifest.json`:**

- top-level keys: `generated` (ISO date), `budgetBytes: 3145728`,
  `totalBytes` and `sources`;
- each source records `name`, `url`, `version`, `fetched`, `entries`,
  `skipped`, `licence` and `sha256`.

**FNV-1a-64:**

- offset basis `0xcbf29ce484222325`, prime `0x100000001b3`;
- input: the UTF-8 bytes of the lowercased domain;
- test vectors:

  | Input | Hash |
  | --- | --- |
  | `"example.com"` | `0x576846634e2714c6` |
  | `"bbc.co.uk"` | `0x37560e87b6fc872c` |
  | `""` | `0xcbf29ce484222325` |

**Sources.** Spec §3.2 lists them. The script keeps a `SOURCES` table:

- **Pinning:** each GitHub list is pinned to a commit SHA you look up today.
  The Public Suffix List is recorded by fetch date and SHA-256.
- **Wikipedia's Perennial sources:** fetched as wikitext through
  `https://en.wikipedia.org/w/api.php?action=parse&page=Wikipedia:Reliable_sources/Perennial_sources&prop=wikitext&format=json`,
  recording the revision ID.
- **Which lists go where:**
  - Phishing.Database active domains, and the Block List Project's malware,
    phishing, scam and fraud lists, go to `unsafe.bin`;
  - the three uBlacklist-format lists go to `spam.bin`;
  - the Perennial sources go to `reliability.tsv`. Entries marked `d` or `b`
    are also blocked by the app.

**Script behavior:**

- **Formats:**
  - hosts files (`0.0.0.0 bad.example`);
  - plain domain lists;
  - uBlacklist match patterns. Only domain-level entries such as
    `*://*.example.com/*` and `*://example.com/*` are kept. Path and regex
    entries are skipped and counted.
- **Budget:** if the folder would exceed `3145728` bytes, drop Phishing.Database
  entries, the largest list, until it fits, and record how many were
  dropped. Fail if it still doesn't fit.
- **Failures:** if any source fails to download or parse, leave that list's
  previous file untouched, print what failed, and exit with status 1. Write
  each file through a temporary file and a rename, never partially.
- **Arguments:** `--output <folder>` (default
  `Enigma/Resources/SearchData`) and `--sources <folder>`, which reads saved
  copies instead of downloading. The tests use `--sources`.

**Steps:**

- [ ] **Write the failing tests:**
  - `test_fnv1a64_vectors`: the three vectors above;
  - `test_hosts_format`;
  - `test_domains_format`;
  - `test_ublacklist_domain_entries`: `*://*.example.com/*` gives
    `example.com`, and `*://example.org/*` gives `example.org`. A path entry
    and a `/regex/` entry are skipped, so `skipped == 2`;
  - `test_hash_file_is_sorted_little_endian`;
  - `test_rsp_statuses`: a saved wikitext excerpt containing one row per
    status gives the expected `domain → status` map;
  - `test_budget_drops_phishing_first`;
  - `test_failure_keeps_last_good`;
  - `test_manifest_fields`.
- [ ] **Run** `python3 -I -B -m unittest discover -s scripts/tests`. Expect
  failures.
- [ ] **Implement** the script.
- [ ] **Run the tests,** then run the script for real:
  `python3 -I scripts/update-search-lists.py`. Expect exit status 0, a
  folder of at most 3 MB, and a complete `manifest.json`.
- [ ] **Draft `authority.txt`** from spec §3.3, including the health bodies
  nhs.uk, mayoclinic.org and clevelandclinic.org. Draft `unreadable.txt`
  from spec §3.3 too. Mark both "for owner review" in your Hand-off. The
  coordinator gets the owner's approval before committing.

### Task 3.2: The Public Suffix List, the hash set and the bundle

**Files:**

- Create `Enigma/Search/PublicSuffixList.swift` and
  `Enigma/Search/SourceQuality.swift`, registered in the app target.
- **Register `SearchData` in the project:** a folder reference with
  `lastKnownFileType = folder` and
  `path = "Enigma/Resources/SearchData"`, plus an entry in the Resources phase
  `A90000000000000000000001`. Model it on the `release-notes` entries
  (`F25A…05` and `…06`).
- Test: create `EnigmaTests/SourceQualityTests.swift`.

**Interfaces.** This task produces:

```swift
struct PublicSuffixList: Sendable {
  init(contents: String)                                  // the .dat format: "//" comments, "*." wildcards, "!" exceptions
  func registrableDomain(of host: String) -> String?      // nil for IP addresses, single labels, and public suffixes themselves
}
enum FNV1a64 { static func hash(_ text: String) -> UInt64 }   // the text is lowercased first
struct DomainHashSet: Sendable {
  init(data: Data) throws                                 // throws when the length isn't a multiple of 8
  var count: Int { get }
  func contains(_ domain: String) -> Bool                 // binary search
}
enum SourceReliability: String, Sendable { case generallyReliable = "gr", noConsensus = "nc", generallyUnreliable = "gu", deprecated = "d", blacklisted = "b" }
struct SearchDataBundle: Sendable {
  let publicSuffixes: PublicSuffixList
  let unsafe: DomainHashSet
  let spam: DomainHashSet
  let reliability: [String: SourceReliability]
  let authoritySuffixes: [String]                        // ".gov", ".gov.uk", …
  let authorityDomains: Set<String>
  let unreadable: Set<String>
  let enigmaBlocked: Set<String>
  static func load(from directory: URL) throws -> SearchDataBundle
  static let bundled: SearchDataBundle?                  // loaded once from Bundle.main; nil, and logged, if missing
}
```

**Steps:**

- [ ] **Write the failing tests:**
  - `testFNV1aMatchesScriptVectors`: the same three vectors as the script.
  - `testDomainHashSetLookup`.
  - `testRegistrableDomains`:

    | Host | Registrable domain |
    | --- | --- |
    | `www.example.com` | `example.com` |
    | `a.b.example.co.uk` | `example.co.uk` |
    | `foo.github.io` | `foo.github.io` |
    | `github.io` | `nil` |
    | `localhost` | `nil` |
    | `192.168.1.1` | `nil` |
    | `www.city.kawasaki.jp` | `city.kawasaki.jp` |

    The last row uses the rules `*.kawasaki.jp` and `!city.kawasaki.jp`.
  - `testBundledDataLoads`, in the test host: `SearchDataBundle.bundled` isn't
    `nil`; `unsafe.count` and `spam.count` are above 0; the Public Suffix List
    answers `www.example.com`; the folder totals at most 3,145,728 bytes.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SourceQualityTests`.
  Expect failures.
- [ ] **Implement** `PublicSuffixList`, the hash set and the bundle loader.
- [ ] **Run** the tests. Expect them to pass.

### Task 3.3: `SourceQuality`

**Files:** add to `Enigma/Search/SourceQuality.swift`. Tests go in
`SourceQualityTests`, using a small in-memory bundle.

**Interfaces.** This task produces:

```swift
struct SourceQuality: Sendable {
  init(data: SearchDataBundle, userBlocked: Set<String>)
  func registrableDomain(of url: URL) -> String?
  func isBlocked(_ url: URL) -> Bool        // the user list, unsafe, spam, reliability d or b, enigma-blocked: on the host and each parent domain
  func isUnreadable(_ url: URL) -> Bool
  func trustFactor(for url: URL) -> Double  // the product of: 1.3 authority, 1.15 gr, 0.5 gu, 0.5 unreadable
}
```

**Steps:**

- [ ] **Write the failing tests:**
  - `testBlocksSubdomainsOfListedDomain`: with `spam.example` listed,
    `https://a.b.spam.example/x` is blocked.
  - `testUserBlockWins`.
  - `testDeprecatedAndBlacklistedSourcesAreBlocked`.
  - `testTrustFactors`, with the in-memory bundle:

    | URL | Factor |
    | --- | --- |
    | `https://www.gov.uk/x` | 1.3 |
    | `https://developer.apple.com/documentation` | 1.3 |
    | a `gr` domain | 1.15 |
    | a `gu` domain | 0.5 |
    | `https://www.pinterest.com/pin/1` | 0.5 |
    | `https://example.com` | 1.0 |

  - `testTrustFactorsMultiply`: a domain that's both `gu` and unreadable
    gives 0.25.
- [ ] **Run** `SourceQualityTests`. Expect failures.
- [ ] **Implement** `SourceQuality`.
- [ ] **Run** `SourceQualityTests`. Expect them to pass.

### Task 3.4: Cleaning, merging and selecting

**Files:**

- Create `Enigma/Search/ResultRanking.swift`.
- Test: create `EnigmaTests/SearchRankingTests.swift`.

**Interfaces.** This task produces:

```swift
enum URLNormalizer {
  static let trackingParameters: Set<String>   // spec §3.1; any name starting "utm_" counts too
  static func clean(_ url: URL) -> URL?        // nil: not http(s), credentials, over 2,048 bytes, or a search-site result page. Unwraps AMP; strips tracking parameters
  static func key(_ url: URL) -> String        // the normalized dedupe key, spec §3.1
}
struct RankedCandidate: Equatable, Sendable {
  let url: URL
  var title: String
  var snippet: String
  var positions: [SearchEngineID: Int]         // best position per engine
  var score: Double
  let domain: String                           // registrable domain
}
enum ResultRanking {
  static func merge(_ results: [EngineResult], weights: [SearchEngineID: Double],
                    quality: SourceQuality) -> [RankedCandidate]             // SearXNG score, highest first
  struct Selection: Equatable, Sendable {
    var readQueue: [RankedCandidate]           // eligible to read, one per domain, best first; the pipeline reads 6 at a time and refills
    var snippetOnly: [RankedCandidate]         // unreadable sites, second pages from a domain; snippet evidence only
  }
  static func select(_ candidates: [RankedCandidate], quality: SourceQuality, cutoff: Double = 0.15) -> Selection
}
```

**The score** comes from SearXNG and spec §3.3. For each candidate:

- `weight` = the product of the weights of the engines that returned it,
  multiplied by the number of those engines;
- `score` = the sum over its positions of `weight / position`.

`select` then:

1. drops blocked candidates;
2. multiplies each score by `trustFactor`;
3. sorts, and drops anything below `cutoff` × the top score;
4. sends unreadable sites, and every page after the first from a domain, to
   `snippetOnly`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testNormalizationKey`. These pairs give equal keys:
    - `http://www.example.com/a/` and `https://example.com/a`;
    - `https://m.example.com/a#x` and `https://example.com/a`;
    - `https://example.com/a?b=2&a=1` and `https://example.com/a?a=1&b=2`;
    - `https://amp.example.com/a/amp` and `https://example.com/a`;
    - `https://example.com/a?amp=1` and `https://example.com/a`.
  - `testTrackingParametersRemoved`:
    `clean("https://example.com/a?utm_source=x&id=7&fbclid=y")` gives
    `https://example.com/a?id=7`.
  - `testAMPCacheUnwrapped`: both
    `https://example-com.cdn.ampproject.org/c/s/example.com/a` and
    `https://www.google.com/amp/s/example.com/a` give
    `https://example.com/a`.
  - `testSearchSiteLinksDropped`: `clean` returns `nil` for result pages on
    duckduckgo.com, startpage.com, mojeek.com, google.com and bing.com.
  - `testUnsafeURLsDropped`: `ftp://`, `https://user:pw@example.com`, and a
    URL over 2,048 bytes.
  - `testMergeScoresLikeSearXNG`, to within 1e-9:
    - DuckDuckGo position 1 plus Mojeek position 3 scores 2.1333…
      (weight 1.0 × 0.8 × 2 = 1.6; then 1.6/1 + 1.6/3);
    - DuckDuckGo alone at position 1 scores 1.0;
    - Mojeek alone at position 1 scores 0.8.
  - `testMergeKeepsLongerTitleAndSnippet`.
  - `testSelectAppliesTrustThenCutoff`: with a top score of 2.0, a 0.29
    candidate is dropped and a 0.31 candidate kept.
  - `testSelectOnePerDomain`: a second `example.com` page goes to
    `snippetOnly`.
  - `testSelectNeverReturnsBlocked`.
  - `testUnreadableGoesToSnippetOnly`.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchRankingTests`.
  Expect failures.
- [ ] **Implement** `ResultRanking.swift`.
- [ ] **Run** the tests. Expect them to pass.

### Task 3.5: The blocked-sites model

**Files:** modify `Enigma/Search/WebSearchSettings.swift`. Tests go in
`WebSearchTests`, with an injected `UserDefaults(suiteName:)`.

**Interfaces.** This task produces these members of `WebSearchSettings`
(`@MainActor`):

```swift
static let blockedSitesKey = "webSearch.blockedSites"
static let maximumBlockedSites = 500
@Published private(set) var blockedSites: [String]       // oldest first
func block(_ url: URL)        // stores the registrable domain from SearchDataBundle.bundled; falls back to the host without "www."
func unblock(_ domain: String)
```

The initializer gains `publicSuffixes: PublicSuffixList? = SearchDataBundle.bundled?.publicSuffixes`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testBlockingStoresRegistrableDomain`: `https://news.bbc.co.uk/x` gives
    `["bbc.co.uk"]`;
  - `testBlockingTwiceKeepsOne`;
  - `testBlockListCapsAt500DroppingOldest`;
  - `testUnblockRemoves`;
  - `testBlockedSitesPersist`: a new instance on the same suite reads them
    back.
- [ ] **Run** `WebSearchTests`. Expect failures.
- [ ] **Implement** the blocked-sites model.
- [ ] **Run** `WebSearchTests` and `SourceQualityTests`. Expect them to pass.

### Task 3.6: Notices

- [ ] **Add to `Enigma/Resources/ThirdPartyNotices.txt`:**
  - the Public Suffix List (MPL-2.0, with its source URL);
  - Phishing.Database (MIT notice);
  - the Block List Project (Unlicense);
  - popcar2/BadWebsiteBlocklist and agsimmons/ai-content-blocklist (CC0);
  - quenhus/uBlock-Origin-dev-filter (Unlicense);
  - "reliability.tsv contains data derived from Wikipedia: Reliable
    sources/Perennial sources, licensed CC BY-SA 4.0", with the page URL.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass, and
  `python3 -I -B -m unittest discover -s scripts/tests` passes.
- [ ] `SearchData/` is at most 3 MB, and `manifest.json` lists every source
  with its licence.
- [ ] The owner has approved `authority.txt` and `unreadable.txt`, through
  the coordinator.

## Reviewer checklist

- **The hash vectors match** between Python and Swift. Recompute one by hand.
- **Public Suffix List edge cases:** wildcard and exception rules, uppercase
  hosts, trailing dots, IDN hosts (compare the punycode form).
- **The SearXNG numbers** are correct, and trust factors apply before the
  cut-off.
- **Lists:** no list is fetched at app runtime, and the script never leaves
  a half-written file.
- **The blocked-sites model** never stores a full URL or a path, only a
  domain.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
