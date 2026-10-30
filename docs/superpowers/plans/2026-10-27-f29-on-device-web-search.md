# On-device web search (F29) — implementation plan

This plan drives **F29** in `to-do.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to build your checkpoint yourself, task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Here, each checkpoint is one worker's job, in a chat the owner starts; the worker starts its own reviewers. Read [agent-workflow.md](2026-10-27-f29-on-device-web-search/agent-workflow.md), then your checkpoint's brief. They and the spec are all you need.

**Goal:** Replace Brave web search with search that runs on the user's Mac.
It needs no key, ranks for quality, and adds Apple Maps places and
Open-Meteo weather, with a `/maps` command and a map card. Capable models
reach it through three tools; small models through today's routing. *Amended (owner approved
2026-10-30), D128:* Brave isn't removed; it runs only while a Brave key is saved. Brave
is removed once a quality gate against it passes.

**Architecture:** `OnDeviceSearchProvider` implements the existing
`WebSearchProvider` protocol. It has two callers:

- **small models:** the private `search` method in `LocalChatViewModel`,
  which the Local, Cloud, Auto and Screen paths call, with the route from
  `SearchRouting`;
- **capable models (F32):** `WebSearchTool` (`web_search`), plus the new
  `find_places` and `get_weather` tools, in `submitNative`'s toolbox.

The provider:

1. queries the search sites, using engines ported from ddgs;
2. merges the results and filters them with bundled quality lists;
3. reads the best pages in a sealed `WKWebView` running Readability.js;
4. hands BM25-ranked passages to `WebSearchContext` (small models) or
   returns them as the tool's result (capable models);
5. answers places from MapKit and weather from Open-Meteo.

A places result carries its places, and the reply shows them on a map card.

**Tech Stack:**

- Swift 6 and SwiftUI on macOS 26.0;
- Foundation `XMLDocument` for search pages;
- WebKit, MapKit (search and the SwiftUI `Map`), NaturalLanguage and
  URLSession;
- Python 3, standard library only, for the scripts;
- XCTest.

**Spec:** [2026-10-27-f29-on-device-web-search-design.md](../specs/2026-10-27-f29-on-device-web-search-design.md),
revised and approved by the owner on 2026-10-29. Every agent reads it in
full. This plan doesn't repeat its reasoning.

**Prerequisites:** F32 is on `main`. F30 runs first; F29 resumes after F30
merges. CP0b starts by merging `main` into the branch, which brings both.

## Global Constraints

- **Platform.** macOS 26.0 deployment target, Swift 6 strict concurrency, and
  the rules in `AGENTS.md`.
- **Dependencies.** No new Swift package or binary dependency. If a fallback
  would need one (for example SwiftSoup after CP0b), stop and report: the
  owner decides.
- **Two kinds of turn.** Every behavior is built for both, and tested on
  both:
  - small models (`NativeTools.isCapable` false): routing, chips and typed
    commands, as today;
  - capable models: tools in `submitNative`, with F32's gates.
- **F32 and F30 names this plan uses:** `NativeToolPlan`, `NativeToolPart`,
  `AssistantToolbox`, `WebSearchTool`, `submitNative`, `SavingMessagesGate`,
  `ChatSession.holdsMessageText`, `NativeToolsEvalTests`,
  `EnigmaTests/Fixtures/F32/eval.jsonl`; F30's `ProviderSearch`,
  `ProviderSearchPart`, `SearchBackend`, `scripts/web-search-queries.json`
  and `scripts/evaluate-native-search.py`. CP1b checks each against the
  merged code and records any difference.
- **Brave until CP8.** Brave stays the default provider until CP8. Before
  then, the on-device provider is reached only through the Debug-only switch
  `webSearch.debugProvider` (CP5), on both kinds of turn.
- **The branch merges after CP10,** so places never ship without the map
  card (CP9).
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
  | `web_search` evidence on capable models | 2,048 tokens on local routes, 8,192 on cloud routes (F32) |
  | Places per result | 10 |
  | Map card height | about 190 pt |

- **Privacy:**
  - coordinates never go to a search site;
  - saved `WebSearchSource` titles and URLs never contain the city or
    coordinates;
  - `ChatMessage.mapPlaces` is never saved;
  - the only new data on disk is `webSearch.blockedSites`;
  - log messages never contain a query, a URL or a place;
  - in a chat that holds message text, every search tool asks first
    (gate 3).
- **Tests:**
  - offline and deterministic; network only behind `ENIGMA_LIVE_SEARCH` or
    `ENIGMA_SEARCH_EVAL`;
  - never delete, disable or weaken a test; replace Brave-specific tests one
    for one;
  - tests that use `UserDefaults` inject their own suite, and `.shared`
    singletons stay inert in the test host (`TestHost.isActive`);
  - the map card's `Map` is replaced by a placeholder in the test host.
- **Copy:** use the exact strings in the spec: errors in §2, the prompt and
  tool instructions in §5 and §6.2, the tool results and cards in §6.2,
  `/maps` in §6.3, the map card's labels in §6.6, the UI in §8. Views follow
  `docs/design/UI-Style.md` and reuse the shared controls in
  `EnigmaControls.swift`.
- **Licences:** the checkpoint that bundles a third-party file adds its
  notice to `Enigma/Resources/ThirdPartyNotices.txt`.
- **Git:** each worker commits its checkpoint once, after the last review
  round, on `feat/f29-on-device-search`, with its progress-log row in the
  same commit. No other commits or git operations (CP0b's merge of `main`
  is the one exception), and no attribution lines anywhere.

## Review Focus

Eight inputs the spec implies but doesn't spell out, most likely first. Each
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
6. **A capable model calls `find_places` with no area while location is
   off.**
   - **Expected:** the tool returns the spec §6.2 text, no MapKit request is
     made, and the reply carries on; no map card.
   - **Pinned by:** CP6 `testFindPlacesWithoutLocationAsksForArea`.
7. **A reply names two places that share a word** ("Blue Bottle" and "Blue
   Door"), or names a place differently from MapKit ("Joe's Pizza" vs
   "Joe's Pizza Broadway").
   - **Expected:** each pin matches only its own full name; a place the
     reply doesn't name fully gets no pin; with no match at all, every
     place gets a pin.
   - **Pinned by:** CP9 `testPinsMatchFullNamesOnly` and
     `testNoMatchPinsEveryPlace`.
8. **`/maps` typed with nothing after it, or with `/search`.**
   - **Expected:** nothing to look for, draft kept; with `/search`, places
     wins.
   - **Pinned by:** CP6 `testMapsAloneKeepsDraft` and
     `testMapsWinsOverSearch`.

---

## How this plan runs

The rules every agent follows are in
[agent-workflow.md](2026-10-27-f29-on-device-web-search/agent-workflow.md).
In short, for each checkpoint in order:

1. **Worker.** The owner starts a fresh chat with a worker (Opus, medium
   effort) and points it at the checkpoint's brief. The worker builds it
   test-first, runs the exit checks, and fills in the brief's **Hand-off**
   section.
2. **Reviewer.** The worker starts a fresh reviewer agent (Opus, extra high
   effort) with `docs/reviewer.md`, the workflow's reviewer rules and the
   brief's checklist.
3. **Fixes.** The same worker fixes every Blocker and Should fix. A new
   reviewer runs each round, until a round has neither, for at most three
   rounds.
4. **Commit.** The worker reruns the exit checks, commits
   `<summary> (F29 CPn)` on `feat/f29-on-device-search`, with the progress
   log below updated in the same commit, pushes the branch and checks CI. It
   then reports to the owner, and the next checkpoint starts in a new chat.

The next checkpoint starts only after that commit. A failed quality gate
(CP7), a spec conflict, an owner decision a brief marks, or a needed
dependency stops the line until the owner decides.

## Checkpoints

| Checkpoint | Brief | Depends on | Produces |
| --- | --- | --- | --- |
| CP0 | [Spike](2026-10-27-f29-on-device-web-search/cp0-spike.md) | — | Done. Answers to the first 9 open questions; sanitized fixtures |
| CP0b | [Second probe](2026-10-27-f29-on-device-web-search/cp0b-second-probe.md) | F30 merged | `main` merged into the branch; acceptance from another network, DuckDuckGo's headers and region, Open-Meteo geocoding; the owner's site lineup |
| CP1 | [Foundations](2026-10-27-f29-on-device-web-search/cp1-foundations.md) | CP0 | Done. `WebSearchRequest` and the shared types, `WebSearchLimits`, `SearchRouting`, the recency hint, numeric `ApproximateLocation`; Brave adapted |
| CP1b | [Routing fixes](2026-10-27-f29-on-device-web-search/cp1b-routing-fixes.md) | CP0b | Spec §6.1's fixes and their test rows; the two untested rules pinned; the draft pull request |
| CP2 | [Search sites](2026-10-27-f29-on-device-web-search/cp2-search-sites.md) | CP1b | `SearchHTTPClient`, the ports CP0b keeps, `EngineHealth`, `SearchSiteRunner`, `UPSTREAM.json`, live check |
| CP3 | [Quality data and ranking](2026-10-27-f29-on-device-web-search/cp3-quality-and-ranking.md) | CP2 | List refresh script and `SearchData/`, Public Suffix List, `SourceQuality`, `URLNormalizer`, `ResultRanking`, the blocked-sites model |
| CP4 | [Page reading](2026-10-27-f29-on-device-web-search/cp4-page-reading.md) | CP3 | `NetworkGuard`, `PageReader`, `ArticleExtractor` with Readability.js, `PageChecks` |
| CP5 | [Passages and pipeline](2026-10-27-f29-on-device-web-search/cp5-passages-and-pipeline.md) | CP4 | `PassageRanker`, `OnDeviceSearchProvider` for the web route, the new prompt, `web_search`'s excerpt result and `recency`, the Debug switch |
| CP6 | [Places and weather](2026-10-27-f29-on-device-web-search/cp6-places-and-weather.md) | CP5 | `WeatherLookup` with Open-Meteo geocoding, `PlaceSearch`, the small-model routes, `find_places` and `get_weather`, `/maps` |
| CP7 | [Evaluation](2026-10-27-f29-on-device-web-search/cp7-evaluation.md) | CP6 | The 60-question set with model-style queries, evaluation test and script, the tool-use prompts, tuning, the gate report |
| CP8 | [Switch-over](2026-10-27-f29-on-device-web-search/cp8-switch-over.md) | CP7 gate (owner's D128 instead) | On-device default, Brave only with a saved key (*amended, D128*: not removed, no key cleanup), new Settings and welcome, "Never use this site" with F30's blocked domains |
| CP9 | [Map card](2026-10-27-f29-on-device-web-search/cp9-map-card.md) | CP8 | `MapCard`, `ChatMessage.mapPlaces`, the pin choice, the test-host placeholder |
| CP10 | [Docs and maintenance](2026-10-27-f29-on-device-web-search/cp10-docs-and-maintenance.md) | CP9 | Docs, screenshots, notices check, upstream watch, `release.sh` warning, final audit and merge |

## Interface map

Names every checkpoint shares. A brief's **Interfaces** blocks give the full
signatures. When a name or type changes, update this table and the briefs
that use it.

| Name | File | Defined in | Used in |
| --- | --- | --- | --- |
| `WebSearchRequest`, `SearchRoute`, `SearchRecency`, `SearchCoordinate`, `EvidenceKind`, `WebSearchLimits` | `Enigma/Search/WebSearch.swift` | CP1 | CP2–CP9 |
| `SearchRouting.decide(question:)`, `SearchRouting.webQuery(_:city:)` | `Enigma/Search/SearchRouting.swift` | CP1 (CP1b fixes) | CP5, CP6 |
| `WebSearchPolicy.recency(_:now:)` | `Enigma/Search/WebSearchPolicy.swift` | CP1 | CP1, CP2, CP5 |
| `ApproximateLocation.coordinate`, `.searchCity` (the area for search sites, such as "Austin, TX"; nil for an unknown area); `LocationIntent`. `.city`, `.region`, `.countryCode` and `.providerSearchLocation` are F30's, for provider search | `Enigma/Search/LocationService.swift` | CP1 (CP1b fixes); `.searchCity` CP0b | CP1, CP6 |
| `SearchHTTPClient`, `SearchHTTPResponse`, `URLSessionSearchHTTPClient`, `SafariHeaders` | `Enigma/Search/SearchHTTPClient.swift` | CP2 | CP2, CP4, CP6 |
| `SearchEngine`, `SearchEngineID`, `EngineQuery`, `EngineResult`, `EngineOutcome`, `SearchRegion` | `Enigma/Search/Engines/SearchEngine.swift` | CP2 | CP2, CP3, CP5 |
| `WikipediaSearch`, `WikipediaArticle` | `Enigma/Search/Engines/WikipediaSearch.swift` | CP2 | CP5 |
| `SERPDocument`, `EngineHealth`, `SearchLogging`, `OSSearchLog` | `Enigma/Search/Engines/SearchEngine.swift` | CP2 | CP2, CP5 |
| `SearchSiteRunner`, `SiteRunResult` | `Enigma/Search/Engines/SearchSiteRunner.swift` | CP2 | CP5 |
| `ManualClock`, `FakeSearchHTTPClient`, `SearchFixture` (tests) | `EnigmaTests/SearchTestSupport.swift` | CP2 | CP2–CP9 tests |
| `PublicSuffixList`, `FNV1a64`, `DomainHashSet`, `SearchDataBundle`, `SourceQuality` | `Enigma/Search/PublicSuffixList.swift`, `SourceQuality.swift` | CP3 | CP3–CP8 |
| `URLNormalizer`, `RankedCandidate`, `ResultRanking`, `RankingTuning` | `Enigma/Search/ResultRanking.swift` | CP3 | CP5, CP7 |
| `WebSearchSettings.blockedSites`, `.block(_:)`, `.unblock(_:)` | `Enigma/Search/WebSearchSettings.swift` | CP3 | CP5, CP8 |
| `NetworkGuard`, `HostResolver`, `PageReader`, `FetchedPage` | `Enigma/Search/PageReader.swift` | CP4 | CP5 |
| `ArticleExtracting`, `ArticleExtractor`, `ExtractedArticle`, `ArticleBlock` | `Enigma/Search/ArticleExtractor.swift` | CP4 | CP5 |
| `PageChecks` | `Enigma/Search/SourceQuality.swift` | CP4 (CP5 adds off-topic) | CP5 |
| `Passage`, `PassageRanker` | `Enigma/Search/PassageRanker.swift` | CP5 | CP5, CP6 |
| `OnDeviceSearchProvider`, `OnDeviceSearchTiming`, `WebSearchProviderFactory` | `Enigma/Search/OnDeviceSearch.swift` | CP5 | CP6–CP9 |
| `WebSearchExcerpts` (the shared excerpt JSON) | `Enigma/Search/WebSearchContext.swift` | CP5 | CP5, CP6 |
| `PlaceSearching`, `MapKitPlaceSearch`, `PlaceResult`, `MapPlace` | `Enigma/Search/PlaceSearch.swift` | CP6 | CP6, CP9 |
| `WeatherLooking`, `OpenMeteoWeather`, `OpenMeteoGeocoder`, `MeasurementUnits`, `WeatherForecast` | `Enigma/Search/WeatherLookup.swift` | CP6 | CP6, CP7 |
| `PlaceSearchTool`, `WeatherTool`; `NativeToolPart.places`, `.weather`; `ComposerCommands.maps`, `SlashCommand.maps` | `Enigma/Search/PlacesAndWeatherTools.swift`, `Enigma/Chat/AssistantToolbox.swift`, `Enigma/App/` | CP6 | CP7–CP9 |
| `SearchTraceEvent`, `SearchTracing` | `Enigma/Search/OnDeviceSearch.swift` | CP7 | CP7 |
| `LocalChatViewModel.braveSearch`, `.usesBraveSearch` (a saved key selects Brave, D129); `WebSearchSettings.isBlocked(_:)`, `.domain(of:)`, `.blockedDomainsMostRecentFirst`; `OfflineSearchHTTPClient` (`BraveKeyCleanup` dropped, D134) | `Enigma/LocalInference/LocalChatViewModel.swift`, `Enigma/Search/WebSearchSettings.swift`, `OnDeviceSearch.swift` | CP8 | CP8–CP10 |
| `WebSearchSource.allowsBlocking`, `SourceBlocking`, `EnvironmentValues.sourceBlocking` | `Enigma/Chat/AssistantActivity.swift`, `AssistantActivityView.swift` | CP8 | CP8 |
| `ChatMessage.mapPlaces`, `MapCard`, `MapCard.pins(for:reply:)` | `Enigma/Chat/ChatDomain.swift`, `Enigma/Chat/MapCard.swift` | CP9 | CP10 |

## Progress log

Each worker updates its row in the checkpoint's own commit. There's no
commit column, since a commit can't name its own hash: find a checkpoint's
commit with `git log --grep "(F29 CP<N>)"`. The worker's full hand-off note
stays in its brief.

| Checkpoint | Status | Review rounds | Notes |
| --- | --- | --- | --- |
| CP0 | done | 4 | Spike done. Q4 (sites), Q1 (parser if Startpage stays) carried into CP0b; Q7 (MapKit terms) answered by the map card and the owner's 2026-10-29 decision |
| CP0b | done | 2 | Home network. Owner: drop Mojeek and Startpage (both blocked on two networks), header set A, DuckDuckGo `kl`; ChatGPT and Claude Code always use their provider's search, and F30's Don't-allow and fallback behavior stays. Open-Meteo geocoding works; typos and Japanese names are its gaps |
| CP1 | done | 2 | Request, shared types, limits, routing and recency in place; Brave unchanged. Owner widened spec §6 routing; see the CP1 Hand-off. Round 2 (2026-10-28) found 6 Should fixes, not made in CP1; CP1b makes them |
| CP1b | done | 8 | Routing fixes per spec §6.1 plus overnight amendments; capable models unchanged; overnight decisions D7–D30 and D32 (D25 and D31 cover the full-suite environment failures) |
| CP2 | done | 3 | DuckDuckGo (header set A, `kl`) and Wikipedia ports, HTTP client, health and runner; Mojeek and Startpage skipped; only block signs and two different challenged queries cool DuckDuckGo down; overnight decisions D33–D43 and D45–D48 |
| CP3 | done | 2 | Quality lists (3 MB: unsafe trimmed by a keep order, malware first), Public Suffix List, trust factors, SearXNG merge, selection and blocked sites; reviewed `overrides.tsv` (never lifts a security block); `authority.txt`/`unreadable.txt`/`overrides.tsv` await owner review; overnight decisions D49–D60 |
| CP4 | done | 2 | Network guard (also checks the reached address), https-only page download, sealed WebKit extraction with Readability 0.6.0 and dates, checks after reading; pages over ~1 MB can near the 500 ms extraction limit (CP7 tunes); overnight decisions D61–D72 (D69, D71 the orchestrator's); the macOS 26 CI fix (slow-runner timeouts, WebKit warm-up) landed in CP5 (D77, D78) |
| CP5 | done | 2 | Passages (BM25 on lemmas), the on-device web pipeline with reading window, checks, snippet fallback and budget, spec §5 envelope and excerpts, `web_search` recency, Debug-only `webSearch.debugProvider` (Brave stays default); tuning in `OnDeviceSearchTiming` (3.0 s window, stop at 5, 800 ms extraction, cut-off 0.08); live median 1.65 s; overnight decisions D73–D80 (D77, D79 the orchestrator's) |
| CP6 | done | 2 | Open-Meteo weather and geocoding (5 matches, exact name, name and country stated), Apple Maps places (5 km widened to 20 km), the small-model weather and places routes, `find_places` and `get_weather` with gate 3, `/maps`; a declined location card holds for the chat and every tool; saved links carry no location; live Open-Meteo 0.17 s, geocoder 0.64 s, MapKit 0.63 s (10 places); overnight decisions D81–D90 (D87, D89 the orchestrator's) |
| CP7 | done | 2 | Harness, 60 questions and gate report; D104's rewrite, "enough?" check, Wikidata and Google News; round 1 stopped after the typed half (on-device 26, Brave 32, tie 2 of 60); both gates fail on the judge share; decisions D92–D126 |
| CP8 | done | 1 (orchestrator's reviewer; fixes D138–D143) | Owner's D128: on-device default for everyone, Brave only with a saved key (choice per search in the view model, D129); no key gates, `/search` and `/maps` always; Settings Web search section with optional Brave row and blocked sites; welcome row; "Never use this site" with Undo; blocked sites to F30's provider search and filtering Brave; footer and gate 3 name the provider used; Brave gets only the city (D136); Brave answers web searches only (D138); decisions D128–D143 |
| CP9 | not started | | |
| CP10 | not started | | |
