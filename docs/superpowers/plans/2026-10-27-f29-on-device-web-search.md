# On-device web search (F29) — implementation plan

This plan drives **F29** in `to-do.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to build your checkpoint yourself, task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Here, each checkpoint is one worker's job, in a chat the owner starts; the worker starts its own reviewers. Read [agent-workflow.md](2026-10-27-f29-on-device-web-search/agent-workflow.md), then your checkpoint's brief. They and the spec are all you need.

**Goal:** Replace Brave web search with search that runs on the user's Mac.
It needs no key, ranks for quality, and uses Apple Maps for places and
Open-Meteo for weather. Brave is removed once a quality gate against it
passes.

**Architecture:** `OnDeviceSearchProvider` implements the existing
`WebSearchProvider` protocol, so every route still calls the private
`search` method in `LocalChatViewModel`. The provider:

1. queries the search sites, using engines ported from ddgs;
2. merges the results and filters them with bundled quality lists;
3. reads the best pages in a sealed `WKWebView` running Readability.js;
4. hands BM25-ranked passages to `WebSearchContext`.

**Tech Stack:**

- Swift 6 and SwiftUI on macOS 26.0;
- Foundation `XMLDocument` for search pages;
- WebKit, MapKit, NaturalLanguage and URLSession;
- Python 3, standard library only, for the scripts;
- XCTest.

**Spec:** [2026-10-27-f29-on-device-web-search-design.md](../specs/2026-10-27-f29-on-device-web-search-design.md),
approved by the owner on 2026-10-27. Every agent reads it in full. This plan
doesn't repeat its reasoning.

## Global Constraints

- **Platform.** macOS 26.0 deployment target, Swift 6 strict concurrency, and
  the rules in `AGENTS.md`.
- **Dependencies.** No new Swift package or binary dependency. If a fallback
  would need one (for example SwiftSoup after CP0), stop and report: the
  owner decides.
- **Brave until CP8.** Brave stays the default provider until CP8. Before
  then, the on-device provider is reached only through the Debug-only switch
  `webSearch.debugProvider` (CP5).
- **Timing:**

  | What | Limit |
  | --- | --- |
  | Each site request | 2.0 s |
  | Startpage, token plus search | 2.5 s together |
  | Reading window, from when the candidates are known | 2.5 s |
  | One extraction | 500 ms |
  | Open-Meteo | 3 s, plus 2 s to geocode a named place |
  | MapKit | 3 s |

- **Size limits:**

  | What | Limit |
  | --- | --- |
  | Result page | 2 MB |
  | Article page | 3 MB |
  | Wikipedia text | 30,000 characters |
  | Pages read per search | 6, stopping early at 4 that pass |
  | `WebSearchLimits` | `maximumSources = 8`, `tokensPerSource = 2_048`, `evidenceTokens = 8_192` |

- **Privacy:**
  - coordinates never go to a search site;
  - saved `WebSearchSource` titles and URLs never contain the city or
    coordinates;
  - the only new data on disk is `webSearch.blockedSites`;
  - log messages never contain a query or a URL.
- **Tests:**
  - offline and deterministic; network only behind `ENIGMA_LIVE_SEARCH` or
    `ENIGMA_SEARCH_EVAL`;
  - never delete, disable or weaken a test; replace Brave-specific tests one
    for one;
  - tests that use `UserDefaults` inject their own suite, and `.shared`
    singletons stay inert in the test host (`TestHost.isActive`).
- **Copy:** use the exact strings in the spec: errors in §2, the prompt in
  §5, the UI in §8. Views follow `docs/design/UI-Style.md` and reuse the
  shared controls in `EnigmaControls.swift`.
- **Licences:** the checkpoint that bundles a third-party file adds its
  notice to `Enigma/Resources/ThirdPartyNotices.txt`.
- **Git:** each worker commits its checkpoint once, after the last review
  round, on `feat/f29-on-device-search`, with its progress-log row in the same commit. No other
  commits or git operations, and no attribution lines anywhere.

## Review Focus

Five inputs the spec implies but doesn't spell out, most likely first. Each
is pinned by a test in the checkpoint that owns the code:

1. **A question in a non-Latin script** ("東京の天気は？", Arabic).
   - **Expected:** every site request carries percent-encoded UTF-8;
     Wikipedia uses the user's language edition; words without lemma support
     fall back to lowercase; pages in the user's languages are kept.
   - **Pinned by:** CP2 `testDuckDuckGoEncodesNonLatinQuery`, CP4
     `testPreferredLanguagePageIsKept`, CP5
     `testUnsupportedLanguageFallsBackToLowercase`.
2. **Every chosen page is a wall, a script-only shell or a paywall**, which
   is common for news.
   - **Expected:** snippets become the evidence (kind `.snippet`); the search
     doesn't fail with `noResults`.
   - **Pinned by:** CP5 `testAllPagesFailingUseSnippets`.
3. **A site accepts the connection and then trickles bytes forever.**
   - **Expected:** the search finishes when the reading window ends, and
     Stop cancels at once.
   - **Pinned by:** CP5 `testHangingPageEndsAtWindow` and
     `testStopCancelsEverything`.
4. **Location was found, but reverse geocoding failed** (the area is
   "current area").
   - **Expected:** no query says "near current area"; the nearby words are
     dropped for search sites, and MapKit still uses the coordinate.
   - **Pinned by:** CP1 `testWebQueryDropsCueWithoutCity`, CP6
     `testPlacesWithoutCityStillSearchMaps`.
5. **A question with no content words** ("what is it?", "who?").
   - **Expected:** pages are kept in rank order, with their opening
     passages, rather than all dropped as off-topic.
   - **Pinned by:** CP5 `testOffTopicNeedsQuestionWords`.

---

## How this plan runs

The rules every agent follows are in
[agent-workflow.md](2026-10-27-f29-on-device-web-search/agent-workflow.md).
In short, for each checkpoint in order:

1. **Worker.** The owner starts a fresh chat with a worker (Opus, medium
   effort) and points it at the checkpoint's brief. The worker builds it test-first,
   runs the exit checks, and fills in the brief's **Hand-off** section.
2. **Reviewer.** The worker starts a fresh reviewer agent (Opus, extra
   high effort) with `docs/reviewer.md`, the workflow's reviewer rules and
   the brief's checklist.
3. **Fixes.** The same worker fixes every Blocker and Should-fix. A new
   reviewer runs each round, until a round has neither.
4. **Commit.** The worker reruns the exit checks, commits
   `<summary> (F29 CPn)` on `feat/f29-on-device-search`, with the progress
   log below updated in the same commit, and pushes the branch. It then
   reports to the owner, and the next checkpoint starts in a new chat.

The next checkpoint starts only after that commit. A failed quality gate
(CP7), a spec conflict, or a needed dependency stops the line until the owner
decides.

## Checkpoints

| Checkpoint | Brief | Depends on | Produces |
| --- | --- | --- | --- |
| CP0 | [Spike](2026-10-27-f29-on-device-web-search/cp0-spike.md) | — | Answers to the spec's 9 open questions; sanitized result-page and Open-Meteo fixtures |
| CP1 | [Foundations](2026-10-27-f29-on-device-web-search/cp1-foundations.md) | CP0 | `WebSearchRequest` and the shared types, `WebSearchLimits`, `SearchRouting`, the recency hint, numeric `ApproximateLocation`; Brave adapted |
| CP2 | [Search sites](2026-10-27-f29-on-device-web-search/cp2-search-sites.md) | CP1 | `SearchHTTPClient`, four engine ports, `EngineHealth`, `SearchSiteRunner`, `UPSTREAM.json`, live check |
| CP3 | [Quality data and ranking](2026-10-27-f29-on-device-web-search/cp3-quality-and-ranking.md) | CP2 | List refresh script and `SearchData/`, Public Suffix List, `SourceQuality`, `URLNormalizer`, `ResultRanking`, the blocked-sites model |
| CP4 | [Page reading](2026-10-27-f29-on-device-web-search/cp4-page-reading.md) | CP3 | `NetworkGuard`, `PageReader`, `ArticleExtractor` with Readability.js, `PageChecks` |
| CP5 | [Passages and pipeline](2026-10-27-f29-on-device-web-search/cp5-passages-and-pipeline.md) | CP4 | `PassageRanker`, `OnDeviceSearchProvider` for the web route, the new prompt, the Debug switch |
| CP6 | [Places and weather](2026-10-27-f29-on-device-web-search/cp6-places-and-weather.md) | CP5 | `WeatherLookup`, `PlaceSearch`, the places and weather routes in the provider |
| CP7 | [Evaluation](2026-10-27-f29-on-device-web-search/cp7-evaluation.md) | CP6 | Query set, evaluation test and script, tuning, the gate report |
| CP8 | [Switch-over](2026-10-27-f29-on-device-web-search/cp8-switch-over.md) | CP7 gate passed | On-device default, Brave removed, key cleanup, new Settings and welcome, "Never use this site" |
| CP9 | [Docs and maintenance](2026-10-27-f29-on-device-web-search/cp9-docs-and-maintenance.md) | CP8 | Docs, screenshot, notices check, upstream watch, `release.sh` warning, final audit and merge |

## Interface map

Names every checkpoint shares. A brief's **Interfaces** blocks give the full
signatures. When a name or type changes, update this table and the briefs
that use it.

| Name | File | Defined in | Used in |
| --- | --- | --- | --- |
| `WebSearchRequest`, `SearchRoute`, `SearchRecency`, `SearchCoordinate`, `EvidenceKind`, `WebSearchLimits` | `Enigma/Search/WebSearch.swift` | CP1 | CP2–CP8 |
| `SearchRouting.decide(question:)`, `SearchRouting.webQuery(_:city:)` | `Enigma/Search/SearchRouting.swift` | CP1 | CP5, CP6 |
| `WebSearchPolicy.recency(_:now:)` | `Enigma/Search/WebSearchPolicy.swift` | CP1 | CP1 (request), CP2 (engines) |
| `ApproximateLocation.coordinate`, `.city` | `Enigma/Search/LocationService.swift` | CP1 | CP1, CP6 |
| `SearchHTTPClient`, `SearchHTTPResponse`, `URLSessionSearchHTTPClient`, `SafariHeaders` | `Enigma/Search/SearchHTTPClient.swift` | CP2 | CP2, CP4, CP6 |
| `SearchEngine`, `SearchEngineID`, `EngineQuery`, `EngineResult`, `EngineOutcome`, `SearchRegion` | `Enigma/Search/Engines/SearchEngine.swift` | CP2 | CP2, CP3, CP5 |
| `WikipediaSearch`, `WikipediaArticle` | `Enigma/Search/Engines/WikipediaSearch.swift` | CP2 | CP5 |
| `SERPDocument`, `EngineHealth`, `SearchLogging`, `OSSearchLog` | `Enigma/Search/Engines/SearchEngine.swift` | CP2 | CP2, CP5 |
| `SearchSiteRunner`, `SiteRunResult` | `Enigma/Search/Engines/SearchSiteRunner.swift` | CP2 | CP5 |
| `ManualClock`, `FakeSearchHTTPClient`, `SearchFixture` (tests) | `EnigmaTests/SearchTestSupport.swift` | CP2 | CP2–CP8 tests |
| `PublicSuffixList`, `FNV1a64`, `DomainHashSet`, `SearchDataBundle`, `SourceQuality` | `Enigma/Search/PublicSuffixList.swift`, `SourceQuality.swift` | CP3 | CP3–CP8 |
| `URLNormalizer`, `RankedCandidate`, `ResultRanking` | `Enigma/Search/ResultRanking.swift` | CP3 | CP5 |
| `WebSearchSettings.blockedSites`, `.block(_:)`, `.unblock(_:)` | `Enigma/Search/WebSearchSettings.swift` | CP3 | CP5, CP8 |
| `NetworkGuard`, `HostResolver`, `PageReader`, `FetchedPage` | `Enigma/Search/PageReader.swift` | CP4 | CP5 |
| `ArticleExtracting`, `ArticleExtractor`, `ExtractedArticle`, `ArticleBlock` | `Enigma/Search/ArticleExtractor.swift` | CP4 | CP5 |
| `PageChecks` | `Enigma/Search/SourceQuality.swift` | CP4 (CP5 adds off-topic) | CP5 |
| `Passage`, `PassageRanker` | `Enigma/Search/PassageRanker.swift` | CP5 | CP5, CP6 |
| `OnDeviceSearchProvider`, `OnDeviceSearchTiming`, `WebSearchProviderFactory` | `Enigma/Search/OnDeviceSearch.swift` | CP5 | CP6–CP8 |
| `PlaceSearching`, `MapKitPlaceSearch`, `PlaceResult`, `WeatherLooking`, `OpenMeteoWeather`, `Geocoding` | `Enigma/Search/PlaceSearch.swift`, `WeatherLookup.swift` | CP6 | CP6, CP7 |
| `MeasurementUnits`, `WeatherForecast`, `WeatherLookup` | `Enigma/Search/WeatherLookup.swift` | CP6 | CP6 |
| `SearchTraceEvent`, `SearchTracing` | `Enigma/Search/OnDeviceSearch.swift` | CP7 | CP7 |
| `BraveKeyCleanup` | `Enigma/Search/WebSearchSettings.swift` | CP8 | CP8 |
| `WebSearchSource.allowsBlocking`, `SourceBlocking`, `EnvironmentValues.sourceBlocking` | `Enigma/Chat/AssistantActivity.swift`, `AssistantActivityView.swift` | CP8 | CP8 |

## Progress log

Each worker updates its row in the checkpoint's own commit. There's no
commit column, since a commit can't name its own hash: find a checkpoint's
commit with `git log --grep "(F29 CP<N>)"`. The worker's full hand-off note
stays in its brief.

| Checkpoint | Status | Review rounds | Notes |
| --- | --- | --- | --- |
| CP0 | not started | | |
| CP1 | not started | | |
| CP2 | not started | | |
| CP3 | not started | | |
| CP4 | not started | | |
| CP5 | not started | | |
| CP6 | not started | | |
| CP7 | not started | | |
| CP8 | not started | | |
| CP9 | not started | | |
