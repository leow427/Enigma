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
  *Amended overnight (orchestrator, owner to confirm):* that page's rows
  live in eight transcluded subpages, which the script fetches the same way,
  recording each revision ID (decision D50).
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
  *Amended overnight (orchestrator, owner to confirm):* the Block List
  Project's malware list alone is seven times the budget, so the script
  fills `unsafe.bin` in a keep order (scam, fraud, phishing,
  Phishing.Database, malware) and drops from its end: malware first, then
  Phishing.Database (decision D49).
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
  from spec §3.3 too. Mark both "for owner review" in your Hand-off. Get the
  owner's approval in the chat before committing.

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
- [ ] The owner has approved `authority.txt` and `unreadable.txt` in the
  chat.

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

*Filled in by the CP3 worker (overnight run, 2026-10-30; decisions D49–D54, D56, D58 and D60; D55, D57 and D59 are the orchestrator's).*

1. **Summary:** Results can now be cleaned, merged, scored, filtered and
   picked for reading. `scripts/update-search-lists.py` downloads the
   pinned public lists and writes `Enigma/Resources/SearchData/` (3,129,228
   bytes of the 3,145,728 budget). A reviewed `overrides.tsv` (D55, D56)
   neutralizes the Perennial rating of Wikipedia, Stack Overflow, Stack
   Exchange sites and Investopedia, and un-blocks MSN and Healthline;
   it never lifts a security block. The app loads it once
   (`SearchDataBundle.bundled`); `SourceQuality` blocks and weighs sites;
   `URLNormalizer` and `ResultRanking` clean, merge (SearXNG's agreement
   score) and select (trust, then the 15% cut-off, one page per domain).
   `WebSearchSettings` keeps the user's blocked sites (registrable domains
   only, at most 500). Nothing calls the ranking yet; CP5 wires it in.
2. **Files:**
   - `scripts/update-search-lists.py` (new): the refresh script, standard
     library only. `scripts/tests/test_update_search_lists.py` and
     `scripts/tests/fixtures/search-lists/` (new): its tests and fixtures.
   - `Enigma/Resources/SearchData/` (new folder reference): `unsafe.bin`,
     `spam.bin`, `reliability.tsv`, `public_suffix_list.dat`,
     `manifest.json` (generated); `authority.txt`, `unreadable.txt`
     (**drafts for owner review**, D52); `enigma-blocked.txt` (header only);
     `overrides.tsv` (D55, D56, hand-curated, kept by the script).
   - `Enigma/Search/PublicSuffixList.swift` (new): the list, host
     normalization (lowercase, trailing dot, punycode).
   - `Enigma/Search/SourceQuality.swift` (new): `FNV1a64`, `DomainHashSet`,
     `SourceReliability`, `SearchDataBundle`, `SourceQuality`.
   - `Enigma/Search/ResultRanking.swift` (new): `RankingTuning`,
     `URLNormalizer`, `RankedCandidate`, `ResultRanking`.
   - `Enigma/Search/WebSearchSettings.swift`: the blocked-sites model.
   - `Enigma/Search/Engines/DuckDuckGoEngine.swift`, `SearchEngine.swift`:
     the weight now reads `RankingTuning.engineWeights`.
   - `Enigma/Resources/ThirdPartyNotices.txt`: the seven notices.
   - `Enigma.xcodeproj/project.pbxproj`: three app files, two test files,
     the `SearchData` folder in Resources.
   - `EnigmaTests/SourceQualityTests.swift`, `SearchRankingTests.swift`
     (new); `WebSearchTests.swift`: seven blocked-sites tests.
   - This brief (two "Amended overnight" notes) and `overnight-decisions.md`
     (D49–D54, D56, D58, D60).
3. **Decisions** (details in the log):
   - **D49:** the unsafe lists can't fit 3 MB (Block List Project malware
     alone is 2.66 million domains, 21 MB of hashes). Keep order: scam,
     fraud, phishing, Phishing.Database, malware; the budget drops from the
     end, and within a list keeps whole domains before subdomains.
     Subdomains of a listed domain are removed first (lossless). 16 KB is
     left free for hand edits. Result: scam, fraud and phishing in full,
     about 65,600 Phishing.Database domains and about 64,300 malware domains
     still covered (dropped: 321,011 and 2,591,515).
   - **D50:** Perennial sources rows live in 8 transcluded subpages; `b=y`
     means blacklisted; `m` rows and path entries are skipped; conflicting
     rows give `nc` unless all are `d`/`b`.
   - **D51:** a list that parses to nothing, or to under half its last
     count, is a failure (previous file kept, exit 1).
   - **D52:** `authority.txt` and `unreadable.txt` drafted without the
     owner's approval, leaning to health, finance and developer docs.
   - **D53:** all ranking numbers in `RankingTuning`; ties go to the higher
     trust factor, then the better position. Recency isn't available here
     (DuckDuckGo's HTML has no dates).
   - **D54:** authority domains match the host's suffix (`nhs.uk` is a
     public suffix); the settings resolve the Public Suffix List lazily.
   - **D55 (orchestrator), D56:** `msn.com` is blocked by popcar2's
     `*://*.msn.com/*` (line 25, "Low Effort Articles"); `healthline.com` by
     Perennial sources' `{{WP:RSPSTATUS|d|b=y}}` (subpage 4). In
     `overrides.tsv`, `neutral` drops the Perennial status for a domain and
     its subdomains; `allow` lifts spam-list and Perennial `d`/`b` blocks.
     Neither lifts an unsafe-list block, the user's block or
     `enigma-blocked.txt`. As first built, the budget trim had dropped the
     five malware-listed msn.com subdomains from `unsafe.bin`, so
     `allow msn.com` unblocked them; D60 fixed that (review round 2), and
     they are blocked again. The manifest lists the four curated files under `curated`.
     A missing `overrides.tsv` loads as none.
   - **D57 (orchestrator), D58 (review round 1):** `allow` for kickstarter,
     gofundme, indiegogo, change.org and lulu.com (blocked only by `gu|b=y`);
     `neutral` for arxiv.org, biorxiv.org, medrxiv.org and aws.amazon.com;
     `!academia.edu` in `authority.txt` is a new exclusion line
     (`SearchDataBundle.authorityExclusions`). `URLNormalizer.key` now
     matches `/amp` case-sensitively, drops only `amp=1` and
     `outputType=amp`, and strips a host prefix only when a domain remains.
   - **D59 (orchestrator), D60 (review round 2):** the refresh script
     reads the `allow` domains from `overrides.tsv` and always keeps
     unsafe-list entries equal to or under them, before the keep order.
     The lists were regenerated with `--sources` from the cached
     2026-10-30 downloads at the same pins; every source's SHA-256 matched
     the earlier run. The 15% cut-off stays for CP7 to measure (D59).
   - Also: with Mojeek gone, `testMergeScoresLikeSearXNG` checks spec
     §3.3's two-site numbers on the new `ResultRanking.agreementScore` and
     the merge on DuckDuckGo alone. `clean` also unwraps DuckDuckGo's
     `/l/?uddg=` and Google's `/url?q=` wrappers (spec §3.1). The manifest
     adds `format` and `dropped` to each source. `DomainHashSet` gained
     `init(domains:)` and sorts an unsorted file; `SourceQuality` gained
     `domains(of:)`, `isAuthority(_:)` and `reliability(of:)`.
4. **Verification:**
   - `python3 -I -B -m unittest discover -s scripts/tests`: 55 run, 0
     failed before review (58 after round 1). The curated-files test failed first (no `curated` key), then
     passed. (17 new in `test_update_search_lists.py`; the tests were written
     before the script, but the first run was after it existed, so no RED
     run was recorded for them).
   - `python3 -I scripts/update-search-lists.py` (real downloads, twice):
     exit 0; 14 sources; folder 3,129,231 bytes after `overrides.tsv`.
   - `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SourceQualityTests
     -only-testing:EnigmaTests/SearchRankingTests
     -only-testing:EnigmaTests/WebSearchTests
     -only-testing:EnigmaTests/SearchEngineTests`: 151 executed, 0 skipped,
     0 failed. The five override tests went RED first against a stub type
     with no effect: 4 failed and
     `testOverrideNeverLiftsUserOrCuratedBlock` passed, since it guards
     behavior that already held. `testBundleLoadParsesTextFiles` also
     failed; it then passed. RED was only a build failure (the first build had a compile
     error), so instead, in a scratch copy, six mutants (big-endian reads,
     no PSL exceptions, trust after the cut-off, no trust tie-break, no
     500 cap, `d` not blocked) failed 9 tests across all three classes.
   - `scripts/verify-xcode.sh build`: succeeded, no warnings in the new
     files. `plutil -lint` on the project: OK.
   - **Review round 1** (orchestrator's reviewer): no Blockers, 4 Should
     fixes, all fixed test-first (D57, D58):
     1. crowdfunding and petition sites hard-blocked → `allow` overrides;
     2. authority sites (arXiv, AWS docs) ranked below neutral, and
        academia.edu got the `.edu` bonus → `neutral` overrides and the
        exclusion line;
     3. tests that couldn't fail. New or tightened: the cut-off after
        trust, a candidate exactly at the cut-off, the position tie-break,
        the cap on a loaded list, the commit pin (the old check never ran),
        collapse stopping at a private-section suffix, the atomic write,
        and gr+d giving `nc`;
     4. `URLNormalizer.key` merged too much → three narrower rules.

     RED for the new behavior: 4 Swift tests failed against stubs
     (`testNormalizationKeyDoesNotOverMerge`,
     `testAuthorityExclusionBeatsSuffix`, `testBundleLoadParsesTextFiles`,
     `testBundledRoundOneOverrides`). The mutant-killing tests pass on the
     real code; each fails on its mutant:
     - Swift, in a scratch copy: cut-off on the raw top, `>` for `>=`, no
       position tie-break, no load cap (4 tests failed);
     - Python, in scratch copies: collapse past the registrable domain, a
       direct write, most-severe status merge, an unpinned `main` (each
       caught).

     GREEN: the four Swift classes ran 158 executed, 0 skipped, 0 failed;
     Python ran 58, 0 failed. The refresh script ran again (exit 0).
   - **Review round 2** (orchestrator's reviewer): one security bug, no
     other findings. `allow msn.com` lifted the block on five
     malware-listed msn.com hosts, because the budget trim had dropped them
     from `unsafe.bin`. It was fixed test-first (D59, D60), with no round 3.
     RED: the new Python test
     `test_budget_keeps_security_entries_under_allowed_domains` failed. The
     bundled-data assertion in `testBundledRoundOneOverrides` failed for all
     five hosts on the old `unsafe.bin`. GREEN: after the fix and the
     regeneration from cached downloads, Python ran 59, 0 failed; the four
     Swift classes ran 158 executed, 0 skipped, 0 failed.
   - **Final checks:**
     - `scripts/verify-xcode.sh build`: succeeded.
     - `scripts/verify-xcode.sh analyze`: succeeded, with no warnings in
       the CP3 files.
     - Full suite, `scripts/verify-xcode.sh test -test-timeouts-enabled YES
       -default-test-execution-time-allowance 60` (D31, screen locked):
       1,776 tests: 1,662 passed, 33 skipped, 81 failed. The 81 failures are
       the same nine hosted-UI classes, with the same counts, as CP1b's and
       CP2's (D25, D32): AppCommandTests 2, ChatCopyTests 2,
       ComposerIntentChipsTests 2, EnigmaCompactPanelTests 15,
       EnigmaConversationTests 18, EnigmaMainWindowTests 29,
       FileModeUITests 1, ScreenCaptureTests 1, ScreenViewTests 11. None is
       in a Search class, so all 81 are environment failures, left for CI.
       The 53 tests above CP2's 1,723 are CP3's new tests.
5. **Limitations:**
   - **Owner review needed:** `authority.txt` and `unreadable.txt` (D52).
   - **Owner review needed:** `overrides.tsv` (D55). CP7 should measure
     its effect. `reddit.com` and `medium.com` remain `gu` (0.5).
   - `unsafe.bin` covers about 2.4% of the malware list and 17% of
     Phishing.Database (D49).
   - Loading the bundle takes about 31 ms in a release build (measured
     outside the app); the first search pays it, not launch (D54).
   - The 60-day manifest warning in `release.sh` is CP10's.
6. **For the next checkpoint:**
   - Build the quality object with `SourceQuality(data:
     SearchDataBundle.bundled, userBlocked: Set(settings.blockedSites))`;
     when `bundled` is nil, CP5 must decide the fallback (it is logged).
   - `ResultRanking.merge(results, weights: RankingTuning.engineWeights,
     quality:)` then `select(_:quality:)`; read `readQueue` in batches of
     `RankingTuning.readBatch` (6) and use `snippetOnly` for snippet
     evidence. `RankedCandidate.url` is the cleaned link to fetch.
   - `isBlocked` treats a URL without a host as blocked.
   - Use `url.host(percentEncoded: false)` (punycode) for hosts; plain
     `host()` percent-encodes IDN hosts.
   - Refresh: update the five commit SHAs in `SOURCES`, run
     `python3 -I scripts/update-search-lists.py`, check the printed counts.
