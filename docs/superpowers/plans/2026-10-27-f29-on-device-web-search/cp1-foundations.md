# CP1: Foundations — shared types, routing, recency

Read [agent-workflow.md](agent-workflow.md), the spec (§1, §2 "Query", §6
"Routing"), and [CP0's Hand-off](cp0-spike.md#hand-off).

## Goal

Lay down the types and decisions every later checkpoint builds on, without
changing what users see:

- the search interface takes a `WebSearchRequest`;
- routing to weather, places or web is decided from the typed question;
- the recency hint exists;
- `ApproximateLocation` keeps numeric coordinates.

Brave still serves every search, and its request stays byte-for-byte the same.

## Starting point

- **`Enigma/Search/BraveSearchClient.swift`.** Lines 1–66 hold the shared
  types: `WebSearchSource`, `WebSearchResult`, `AssistantActivitySink`,
  `WebSearchProvider` and its `onActivity` extension, and `WebSearchError`.
  `BraveSearchClient` follows, with `maximumSources` 10, `evidenceTokens`
  8,192 and `tokensPerSource` 2,048.
- **`Enigma/LocalInference/LocalChatViewModel.swift`:**
  - `init(... webSearch: any WebSearchProvider = BraveSearchClient(), ...)`
    is at line 370;
  - the private `search(_:writtenQuery:maximumTokens:requestID:)` is at
    1455. It appends `"\n" + location.searchContext` to the query when
    `LocationIntent.needsLocation(ScreenSearchContext.question(prompt))`;
  - the call sites pass `BraveSearchClient.evidenceTokens`, at lines 800, 964
    and 1150.
- **`Enigma/Search/WebSearchContext.swift`** uses
  `BraveSearchClient.maximumSources` (line 28) and `.tokensPerSource`
  (line 59).
- **`Enigma/Search/LocationService.swift`** holds three relevant pieces:
  - `LocationIntent` (lines 7–34), whose patterns are private;
  - `ApproximateLocation` (36–46). It stores only `area` and the string
    `coordinates`, and `area` is `"current area"` when reverse geocoding
    fails;
  - `LocationService`, which rounds to 2 decimals before building one.
- **Test doubles that implement `WebSearchProvider`:**
  - in `EnigmaTests/WebSearchTests.swift`: `SearchSpy` (line 1340, records
    `queries` and `budgets`) and `ProgressiveSearch` (1414);
  - in `SelectionContextTests`, `ScreenNativeSmokeTests`, `ScreenViewTests`
    and `ScreenPipelineTests`.

  There are 34 assertions on `search.queries`.
  `WebSearchTests.swift:1082` uses `BraveSearchClient.evidenceTokens`.

## Tasks

### Task 1.1: `WebSearchRequest` and the shared types

**Files:**

- Create `Enigma/Search/WebSearch.swift`, registered in the app target.
- Modify `Enigma/Search/BraveSearchClient.swift` (the moved types,
  `search(_ request:)`), `Enigma/Search/WebSearchContext.swift`, and
  `Enigma/LocalInference/LocalChatViewModel.swift` (call sites only; the
  routing comes in Task 1.5).
- Tests: `EnigmaTests/WebSearchTests.swift`, plus the four other test files
  above.

**Interfaces.** This task produces the following. CP2–CP8 use every name
exactly as written.

```swift
// Enigma/Search/WebSearch.swift
struct WebSearchSource: Codable, Equatable, Sendable, Identifiable   // moved unchanged
enum EvidenceKind: String, Codable, Sendable { case article, snippet, wikipedia, places, weather }
struct WebSearchResult: Equatable, Sendable {
  let source: WebSearchSource
  let snippets: [String]
  var site: String? = nil
  var published: Date? = nil
  var kind: EvidenceKind = .article
}
enum SearchRoute: String, Equatable, Sendable { case web, places, weather }
enum SearchRecency: String, Equatable, Sendable { case day = "d", week = "w", month = "m", year = "y" }
struct SearchCoordinate: Equatable, Sendable { let latitude: Double; let longitude: Double }
struct WebSearchRequest: Equatable, Sendable {
  var query: String
  var route: SearchRoute = .web
  var city: String? = nil
  var coordinate: SearchCoordinate? = nil
  var namedPlace: String? = nil
  var recency: SearchRecency? = nil
  var maximumTokens: Int
}
typealias AssistantActivitySink                                  // moved unchanged
protocol WebSearchProvider: Sendable {
  func search(_ request: WebSearchRequest) async throws -> [WebSearchResult]
  func search(_ request: WebSearchRequest,
              onActivity: @escaping AssistantActivitySink) async throws -> [WebSearchResult]
}                                                                // the onActivity default moves too
enum WebSearchError                                              // moved unchanged in CP1
enum WebSearchLimits {
  static let maximumSources = 8
  static let tokensPerSource = 2_048
  static let evidenceTokens = 8_192
}
```

**Steps:**

- [ ] **Write the failing tests** in `WebSearchTests`:
  - `testWebSearchResultDefaultsToArticleKind`: `kind == .article`;
    `site` and `published` are `nil`.
  - `testBraveAppendsLocationFromRequest`. Brave's JSON body field `q` for
    `WebSearchRequest(query: "What are some good restaurants around me?", city: "Chicago", coordinate: SearchCoordinate(latitude: 41.88, longitude: -87.63), maximumTokens: 8_192)`
    equals
    `"What are some good restaurants around me?\nApproximate current location: Chicago (41.88, -87.63)"`.
  - `testBraveUsesUnknownAreaWithoutCity`: with `city: nil`, the body
    contains `"Approximate current location: current area (41.88, -87.63)"`.
  - `testWebSearchContextCapsAtEightSources`: with 10 candidate results,
    `GroundedConversation.sources.count <= 8`.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchTests`.
  Expect a compile failure: the new types don't exist yet.
- [ ] **Implement:**
  - Move the types into `WebSearch.swift`, and add the new ones above.
  - **Brave:** `BraveSearchClient.search(_ request:)` builds its query from
    `request.query`. When `request.coordinate` is set, it appends `"\n"` plus
    `ApproximateLocation(latitude:longitude:area: request.city ?? ApproximateLocation.unknownArea).searchContext`.
    Then it applies the existing `query(from:)` trimming. Its own request
    count stays at 10 (`BraveSearchClient.maximumSources` remains for the
    Brave body only).
  - **`WebSearchContext`** uses `WebSearchLimits`.
  - **Call sites** pass `WebSearchLimits.evidenceTokens`.
  - **Test doubles:**
    - each spy records `requests: [WebSearchRequest]`, and keeps
      `var queries: [String] { requests.map(\.query) }` so the 34 existing
      query assertions stay as they are;
    - `budgets` becomes `requests.map(\.maximumTokens)`;
    - an assertion that looked for location text in a query moves to the
      request fields. For example, in
      `testNearbySearchUsesLocationAcrossRoutesWithoutPersistingIt`:
      `XCTAssertEqual(requests.last?.city, "Chicago")` and
      `XCTAssertEqual(requests.last?.coordinate, SearchCoordinate(latitude: 41.88, longitude: -87.63))`.
- [ ] **Run** the five affected test classes. Expect them all to pass.

### Task 1.2: Numeric `ApproximateLocation`

**Files:** modify `Enigma/Search/LocationService.swift`. Tests go in
`WebSearchTests`.

**Interfaces.** This task produces:

```swift
struct ApproximateLocation: Equatable, Sendable {
  static let unknownArea = "current area"
  let area: String
  let coordinates: String                      // unchanged text, "%.2f, %.2f"
  let latitude: Double                         // rounded to 2 decimals
  let longitude: Double                        // rounded to 2 decimals
  var coordinate: SearchCoordinate { get }
  var city: String? { get }                    // nil when area == unknownArea
  var searchContext: String { get }            // unchanged
  init(latitude: Double, longitude: Double, area: String = ApproximateLocation.unknownArea)
}
```

**Steps:**

- [ ] **Write the failing tests:**
  - `testApproximateLocationKeepsRoundedCoordinates`:
    `ApproximateLocation(latitude: 41.8781136, longitude: -87.6297982, area: "Chicago")`
    has `latitude == 41.88`, `longitude == -87.63`, `city == "Chicago"`, and
    `coordinates == "41.88, -87.63"`.
  - `testUnknownAreaHasNoCity`:
    `ApproximateLocation(latitude: 41.88, longitude: -87.63).city == nil`.
- [ ] **Run** the tests. Expect failures.
- [ ] **Implement:** round with `(value * 100).rounded() / 100` in the
  initializer.
- [ ] **Run** `WebSearchTests`. Expect them to pass.

### Task 1.3: Recency hint

**Files:** modify `Enigma/Search/WebSearchPolicy.swift`. Tests go in
`WebSearchTests`.

**Interfaces.** This task produces
`static func recency(_ prompt: String, now: Date = Date()) -> SearchRecency?`
on `WebSearchPolicy`. It normalizes with `questionText(_:)`.

**The mapping.** This is spec §2's table, with one precision fix: "live"
counts only in the phrases "live score(s)", "live updates", "live results",
"live coverage" and "live blog". Otherwise "where do penguins live" would
filter results to the past day. When several hints match, the shortest
window wins.

| Words | Hint |
| --- | --- |
| "today", "tonight", "right now", "this morning", "this afternoon", "this evening", the live phrases | `.day` |
| "latest", "recent", "news", "breaking", "this week", "yesterday" | `.week` |
| "this month" | `.month` |
| "this year", or the current year's number | `.year` |

**Steps:**

- [ ] **Write the failing test** `testRecencyHints`, table-driven, with `now`
  = 2026-10-27:

  | Question | Hint |
  | --- | --- |
  | "what happened today" | `.day` |
  | "live scores premier league" | `.day` |
  | "where do penguins live" | `nil` |
  | "latest swift release" | `.week` |
  | "breaking news" | `.week` |
  | "what did the fed say yesterday" | `.week` |
  | "latest news today" | `.day` |
  | "best laptops this month" | `.month` |
  | "oscars 2026" | `.year` |
  | "oscars 2024" | `nil` |
  | "how do magnets work" | `nil` |
  | "`/search latest swift release`", given after slash commands are removed | `.week` |

- [ ] **Run** the test. Expect failures.
- [ ] **Implement** with fixed `NSRegularExpression` literals, in the file's
  existing style.
- [ ] **Run** `WebSearchTests`. Expect them to pass.

### Task 1.4: `SearchRouting`

**Files:**

- Create `Enigma/Search/SearchRouting.swift`, registered in the app target.
- Modify `Enigma/Search/LocationService.swift`, adding internal helpers to
  `LocationIntent`.
- Create `EnigmaTests/SearchRoutingTests.swift`, registered in the test
  target.

**Interfaces.** This task produces:

```swift
enum SearchRouting {
  struct Decision: Equatable, Sendable {
    let route: SearchRoute
    let needsCurrentLocation: Bool
    let namedPlace: String?          // weather only; lowercased, from the normalized question
  }
  static func decide(question: String) -> Decision      // question: typed text, slash commands removed
  static func webQuery(_ query: String, city: String?) -> String
}
extension LocationIntent {           // internal, reusing the existing private patterns
  static func hasNearbyCue(normalized text: String) -> Bool
  static func asksAboutWeatherNow(normalized text: String) -> Bool
  static func weatherPlace(normalized text: String) -> String?
}
```

**Rules,** from spec §6:

- **Weather:** the weather topic, plus a "now" word from `asksAboutNow`. Not
  `conceptualWeather`, and none of the words news, latest, record, average,
  historical, history or climate.
- **Weather's named place:** the words after "in", "at", "for" or "near", up
  to a time word ("today", "tonight", "tomorrow", "this", "next", "on") or
  the end of the question.
- **Places:** a nearby cue, or a place-type word with `namedPlace`. The
  place-type words are a fixed list: cafe(s), coffee, restaurant(s), bar(s),
  pub(s), pharmacy, pharmacies, hospital(s), clinic(s), gym(s), hotel(s),
  museum(s), park(s), bakery, bakeries, supermarket(s), grocery, gas
  station(s), petrol station(s), atm(s), pizza, sushi, ramen, tacos, burger(s),
  library, libraries.
- **Location:** `needsCurrentLocation` must equal
  `LocationIntent.needsLocation(question)` for every input.
- **`webQuery`** replaces "near me", "nearby", "around me", "in my area" and
  "locally" with "near <city>". With no city, it removes the phrase and tidies
  the spaces. It keeps the rest of the text as written.

**Steps:**

- [ ] **Write the failing tests.**
  - `testRoutes`, table-driven:

    | Question | Route | Needs location | Named place |
    | --- | --- | --- | --- |
    | "cafe near me" | places | true | nil |
    | "coffee nearby" | places | true | nil |
    | "What are some good restaurants around me?" | places | true | nil |
    | "events near me this weekend" | places | true | nil |
    | "ramen in Soho" | places | false | nil |
    | "will it rain tomorrow" | weather | true | nil |
    | "weather in Paris this weekend" | weather | false | "paris" |
    | "what's the forecast for new york tomorrow" | weather | false | "new york" |
    | "hurricane latest news" | web | false | nil |
    | "average rainfall in Seattle in May" | web | false | nil |
    | "what is weather" | web | false | nil |
    | "taxes in California" | web | false | nil |
    | "history of Rome" | web | false | nil |

  - `testRouteLocationMatchesLocationIntent`: for every row above,
    `decide(question:).needsCurrentLocation == LocationIntent.needsLocation(question)`.
  - `testWebQueryRewritesNearbyCues`:
    - `("cafes near me", "Chicago")` gives `"cafes near Chicago"`;
    - `("What are some good restaurants around me?", "Chicago")` gives
      `"What are some good restaurants near Chicago?"`;
    - `("weather in my area", "Chicago")` gives `"weather near Chicago"`;
    - `("swift actors", "Chicago")` is unchanged.
  - `testWebQueryDropsCueWithoutCity` (Review Focus 4):
    - `("cafes near me", nil)` gives `"cafes"`;
    - `("best pizza nearby", nil)` gives `"best pizza"`;
    - the result never contains "current area".
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchRoutingTests`.
  Expect failures.
- [ ] **Implement** `SearchRouting` and the `LocationIntent` helpers.
- [ ] **Run** `SearchRoutingTests` and `WebSearchTests`. Expect them to pass.

### Task 1.5: Build the request in `LocalChatViewModel.search`

**Files:** modify `Enigma/LocalInference/LocalChatViewModel.swift` (the
private `search` method). Tests go in `WebSearchTests`.

**Interfaces:**

- **Consumes:** `SearchRouting.decide(question:)`,
  `WebSearchPolicy.recency(_:)`, `ApproximateLocation.coordinate` and `.city`.
- **Produces:** every provider now receives these fields:
  - `query`: today's contextual query, without the location line;
  - `route` and `namedPlace`: from `decide(question: ScreenSearchContext.question(prompt))`,
    so from the typed question only, never from a written query;
  - `city` and `coordinate`: when `needsCurrentLocation` is true;
  - `recency`: from the typed question.

  `requestLocationContext`, which grounds the model, is unchanged.

**Steps:**

- [ ] **Write the failing tests:**
  - `testSearchCommandNearbyQuestionUsesPlacesRoute`. Submit
    `"/search cafe near me"` on the Local route, with `SearchLocation()`.
    Expect:
    - the request's `route == .places`, `city == "Chicago"`,
      `coordinate == SearchCoordinate(latitude: 41.88, longitude: -87.63)`
      and `query == "cafe near me"`;
    - `location.calls == 1`.
  - `testNamedPlaceWeatherNeedsNoLocation`. Submit
    `"/search weather in Paris this weekend"`. Expect `route == .weather`,
    `namedPlace == "paris"` and `location.calls == 0`.
  - `testWrittenQueryCannotChooseRoute`. Type `"/search what is this?"` with
    an attached selection context whose text is `"cafes near me"`, so the
    query gets refined. Expect `route == .web` and `location.calls == 0`.
  - `testRecencyHintReachesRequest`. Submit `"/search latest swift release"`.
    Expect `recency == .week`.
- [ ] **Run** `WebSearchTests`. Expect these four to fail.
- [ ] **Implement:**
  - replace the `LocationIntent.needsLocation` call with
    `decide(...).needsCurrentLocation`;
  - stop appending the location to the query;
  - fill in the request.
- [ ] **Run** `WebSearchTests`, `ScreenViewTests`, `ScreenPipelineTests`,
  `ComposerIntentTests` and `SelectionContextTests`. Expect them to pass.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` all pass.
- [ ] Brave's request body is unchanged.
  `testBraveAppendsLocationFromRequest` passes, and every pre-existing Brave
  test passes unedited.
- [ ] No production code still refers to `BraveSearchClient.evidenceTokens`,
  `.maximumSources` or `.tokensPerSource`, except inside
  `BraveSearchClient`.

## Reviewer checklist

- **Routing:** comes only from the typed question, never from a written
  query, and the location rule hasn't changed (compare with
  `LocationIntent.needsLocation`).
- **Test doubles:** the 34 query assertions still check what they did, and
  no location assertion was dropped.
- **Recency:** "live" only counts in the listed phrases; the shortest window
  wins.
- **Interfaces:** the names and types match the Interface block exactly,
  because later checkpoints compile against them.

## Hand-off

*Filled in by the CP1 worker.*

1. **Summary:** The search interface now takes a `WebSearchRequest`. The
   shared types and `WebSearchLimits` live in `WebSearch.swift`.
   `SearchRouting` picks weather, places or web from the typed question.
   `WebSearchPolicy.recency` gives the date hint. `ApproximateLocation` keeps
   rounded numeric coordinates and an optional city. `LocalChatViewModel.search`
   fills in the route, named place, recency, city and coordinate, and no longer
   appends location to the query. Brave still serves every search: it appends
   the same location line itself, so its request body is unchanged.
2. **Files:**
   - `Enigma/Search/WebSearch.swift` (new): the moved shared types, plus
     `EvidenceKind`, `SearchRoute`, `SearchRecency`, `SearchCoordinate`,
     `WebSearchRequest` and `WebSearchLimits`.
   - `Enigma/Search/SearchRouting.swift` (new): `SearchRouting.decide(question:)`
     and `webQuery(_:city:)`.
   - `Enigma/Search/BraveSearchClient.swift`: the shared types moved out;
     `search(_ request:)` appends the location line and calls the existing
     string search.
   - `Enigma/Search/WebSearchContext.swift`: uses `WebSearchLimits`.
   - `Enigma/Search/WebSearchPolicy.swift`: `recency(_:now:)` and its patterns.
   - `Enigma/Search/LocationService.swift`: numeric `ApproximateLocation`;
     `LocationIntent` gains `hasNearbyCue`, `asksAboutWeatherNow` and
     `weatherPlace`, and its `matches` and `namedPlace` become internal so
     `SearchRouting` can use them.
   - `Enigma/LocalInference/LocalChatViewModel.swift`: builds the request; the
     call sites pass `WebSearchLimits.evidenceTokens`.
   - `Enigma.xcodeproj/project.pbxproj`: registers the two new app files and
     `SearchRoutingTests.swift`.
   - `EnigmaTests/SearchRoutingTests.swift` (new), and the brief's new tests in
     `WebSearchTests.swift`.
   - Test doubles in `WebSearchTests`, `SelectionContextTests`,
     `ScreenNativeSmokeTests`, `ScreenViewTests` and `ScreenPipelineTests`
     record `requests` and derive `queries` (and `budgets`, and
     `ScreenPipelineTests`' `Query` values) from them.
   - `docs/Web-Search.md`: "How it works" names the new files and the request.
     It's outside the brief, but `AGENTS.md` asks for the feature doc to match
     the code.
3. **Decisions:**
   - **Brave keeps its string `search(_:maximumTokens:)`,** and
     `search(_ request:)` calls it. That's how every pre-existing Brave test
     passes unedited. The method goes with Brave in CP8.
   - **`testBraveAppendsLocationFromRequest` expects a space, not `"\n"`.**
     Brave's `query(from:)` collapses whitespace, so the old body always had
     `"…around me? Approximate current location: Chicago (41.88, -87.63)"`.
     The brief's literal `"\n"` contradicts its own "byte-for-byte" goal, so
     the test pins what Brave actually sent before.
   - **Owner decisions after review round 1 (2026-10-27)** widen spec §6's
     routing rules, so later checkpoints and the spec should follow them:
     1. **A weather or forecast word plus a nearby cue is weather:**
        "weather near me", "weather in my area", "local weather". Snow and
        umbrella words aren't included, so "snow removal near me" stays a
        places question.
     2. **Weather needs somewhere to look up:** the current location or a
        named place. Otherwise the question falls through to places or web,
        as Brave handles it today ("what's the forecast for the weekend",
        "will it snow in december"). A named place starts with a letter, like
        `LocationIntent`'s `namedDestination`. It may start with "the" ("the
        uk"), but not with "a" or "an", and a time is never a place: "in 2
        hours", "at 5pm", "in the morning", months and weekdays. When both
        the location and a place are found, only the location is kept, so
        exactly one is set.
     3. **A named area needs a place word just before it:** a place word, at
        most two words, then "in", "at" or "near" and an area. The area can't
        start with a, an, the, home, me, my, this or here, and the question
        can't be a "how to/do/does/can/should" question. So "caffeine in
        coffee", "calories in a burger", "best pizza at home recipe" and "how
        to use bars in matplotlib" stay on the web route; "ramen in Soho" and
        "best pizza in Brooklyn" are places.
     4. **"local <place word>"** ("local restaurants", "local cafes") is a
        nearby question: it routes to places, and `webQuery` makes it
        "<place word> near <city>", or just "<place word>" without a city.
   - **Weather also counts "this weekend" and "next week",** but only together
     with a named place (`LocationIntent.comingDays`). The brief's
     `asksAboutNow` rule alone can't route its own example, "weather in Paris
     this weekend": `\bthis week\b` doesn't match "this weekend".
   - **A nearby cue routes to places only when `needsLocation` is true,** so
     transformations ("Rewrite: good restaurants around me") and location
     opt-outs stay on the web route. The weather and named-area rules ignore
     transformations and offline requests too.
   - **`hasNearbyCue`** is spec §6's five phrases plus "local <place word>",
     not `LocationIntent`'s wider private `nearbyCue` ("where am i", "my
     location", "local events"). Those still need location, but take the web
     route.
   - **`webQuery`** matches cues as whole words regardless of case
     ("locally-sourced" isn't one), and escapes the city as a template. Without
     a city it removes the cue and the spaces before it, then trims the ends,
     so "What's open around me?" gives "What's open?" and the rest stays as
     written.
   - **`ApproximateLocation`** rounds in its initializer, and builds
     `coordinates` from the rounded values. `LocationService` already rounds,
     and rounding twice gives the same value.
   - **`testRecencyHints`'s "now"** is noon UTC on 2026-10-27, so the year is
     2026 in every time zone.
   - **Changed tests,** where behavior changed on purpose:
     - `testNearbySearchUsesLocationAcrossRoutesWithoutPersistingIt` checks
       `requests.last?.city` and `.coordinate`, not the location text in the
       query, as the brief says;
     - `testEvidenceScalesWithCapacityReservesHalfAndDisplacesOldHistory`
       now expects 8 sources, not 10 (`WebSearchLimits.maximumSources`). It
       still checks that the larger windows keep every allowed source.
     - `testCancelledLocationCannotLeakIntoReplacementRequest` also checks
       that the replacement request has no city or coordinate, because the
       location no longer travels in the query.
   - **Tests added after review round 1:** the routing rows for the owner's
     decisions, transformations and opt-outs, background words, and the
     tightened named-area rule; `testWeatherHasExactlyOneWayToFindItsPlace`;
     more `webQuery` cases; and `testLocationWithoutCitySendsNoCity` (a found
     location without a city sends `city == nil` with the coordinate).
     `SearchLocation` can now return a given location.
4. **Verification** (`scripts/verify-xcode.sh`, from the worktree):
   - RED: the first run failed to compile (the new files didn't exist); with
     stubs in place, `WebSearchTests` and `SearchRoutingTests` ran 68 tests
     with 39 failures, all on the new assertions. After review round 1, the
     new tests failed 30 assertions before the fixes.
   - `test -only-testing:EnigmaTests/WebSearchTests -only-testing:EnigmaTests/SearchRoutingTests`:
     70 executed, 0 failed.
   - `build`: succeeded.
   - `test`: 1,350 executed, 20 skipped, 1 failed:
     `EnigmaMainWindowTests.testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`
     timed out waiting for the UI. It passed twice when run alone, touches no
     search code, and the round-1 reviewer saw the same timeout once.
   - `analyze`: succeeded, with no warnings in the changed files.
   - Review: round 1 (Opus, xhigh) found no Blockers, 5 Should fixes and
     6 Nits. Four Should fixes went to the owner (the decisions above); all
     five are fixed, along with the Nits except the duplicated
     `recency`/`recently` naming. Round 2 was stopped early at the owner's
     request before it reported, so the round-1 fixes weren't reviewed again.
5. **Limitations:**
   - The round-1 fixes have had no second review (round 2 was stopped).
     *Added 2026-10-29:* round 2 ran on 2026-10-28 (Opus, xhigh, against
     `b5f07c4..421ed81`): no Blockers, 6 Should fixes, none made here.
     [CP1b](cp1b-routing-fixes.md) lists and makes them.
   - The routes change nothing yet: Brave ignores `route`, `namedPlace` and
     `recency` until CP5 and CP6 use them.
   - Routing and recency read English wording only, like the rest of
     `WebSearchPolicy`.
   - `weatherPlace` can catch a non-place ("for work"); CP6's geocoding
     failure falls back to web search. It needs a Latin letter first, like
     `needsLocation`, so "weather in Évian today" uses the current location
     (a limitation of today's `LocationIntent` too).
   - The named-area rule still sends some non-place questions to places,
     such as "is coffee bad in pregnancy". CP7's evaluation should watch the
     places route.
   - "where am i", "my location" and "local events" need location but take
     the web route, and `webQuery` doesn't add the city to them.
6. **For the next checkpoint:**
   - The names match the Interface block. `WebSearchRequest`'s memberwise
     initializer takes its arguments in declaration order: `query`, `route`,
     `city`, `coordinate`, `namedPlace`, `recency`, `maximumTokens`.
   - `request.query` holds no location. CP5's step 1,
     `SearchRouting.webQuery(request.query, city: request.city)`, is safe on
     every request: without a city it only drops the nearby words. A query
     that was only a cue ("near me" with no city) becomes empty, so CP5 and
     CP6 should fall back to `request.query` then.
   - On the weather route, `SearchRouting.decide` sets exactly one of
     `needsCurrentLocation` and `namedPlace`. So a weather request carries a
     coordinate or a named place. It has neither only when the view model has
     no location provider, as in some tests.
   - `request.city` is `nil` when reverse geocoding found no city, even when
     `coordinate` is set.
   - `SearchRecency.rawValue` is the `d/w/m/y` date-filter code.
   - Test spies record `requests: [WebSearchRequest]`; assert on fields there.
