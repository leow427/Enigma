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

*Filled in by the CP1 worker. Use the template in agent-workflow.md.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
