# CP6: Places and weather

Read [agent-workflow.md](agent-workflow.md), the spec (§6 in full, §7, §8,
"Failure handling"), and the Hand-offs of [CP0](cp0-spike.md#hand-off) (Q7
MapKit, Q8 Open-Meteo), [CP0b](cp0b-second-probe.md#hand-off) (Q4
geocoding), [CP1b](cp1b-routing-fixes.md#hand-off) and
[CP5](cp5-passages-and-pipeline.md#hand-off).

## Goal

Weather comes from Open-Meteo, and places from Apple Maps, on both kinds of
turn:

- **small models:** `SearchRouting`'s weather and places routes, in the
  provider (places run with web search at the same time);
- **capable models:** two new tools, `find_places` and `get_weather`,
  offered with `web_search`;
- **`/maps`** on both.

A places result carries its places for CP9's map card. Saved sources never
carry a location. Brave still serves the web route by default; the Debug
switch reaches all of it.

## Starting point

- **Routing:** `WebSearchRequest.route`, `.namedPlace`, `.city` and
  `.coordinate` reach the provider (CP1, CP1b).
- **The provider:** `OnDeviceSearchProvider` handles `.places` and
  `.weather` as web searches (CP5).
- **Capable turns:** `NativeToolPlan` and `AssistantToolbox`
  (`Enigma/Chat/AssistantToolbox.swift`), `WebSearchTool` with CP5's
  excerpts, `nativeToolbox` in `LocalChatViewModel`, gate 3 through
  `mayQuery`, and F30's `ProviderSearchPart` with its near-me clause.
- **Commands:** `SlashCommand` (`Enigma/App/SlashCommand.swift`) and
  `ComposerCommands` (`Enigma/Screen/ScreenAttachment.swift`); conflicts in
  `ComposerSubmission`.
- **Fixtures:** `open-meteo-chicago.json` (CP0) and
  `open-meteo-geocoding-paris.json` (CP0b).
- **MapKit:** `LocationService` already uses `MKReverseGeocodingRequest` and
  `MKMapItem.addressRepresentations` (macOS 26 APIs).

## Tasks

### Task 6.1: Weather

**Files:** create `Enigma/Search/WeatherLookup.swift`. Tests in the new
`EnigmaTests/PlacesAndWeatherTests.swift`.

**Interfaces:**

```swift
enum MeasurementUnits: Equatable, Sendable { case metric, us; static var current: MeasurementUnits { get } }
struct WeatherForecast: Decodable, Equatable, Sendable          // current, hourly, daily, units, utc_offset_seconds, timezone
protocol WeatherLooking: Sendable {
  func forecast(at coordinate: SearchCoordinate, units: MeasurementUnits) async throws -> WeatherForecast
}
struct OpenMeteoWeather: WeatherLooking {
  static let timeout: Duration = .seconds(3)
  init(client: any SearchHTTPClient = URLSessionSearchHTTPClient.live)
  static func url(for coordinate: SearchCoordinate, units: MeasurementUnits) -> URL
}
protocol Geocoding: Sendable { func locate(_ place: String) async throws -> (coordinate: SearchCoordinate, name: String)? }
struct OpenMeteoGeocoder: Geocoding {                             // spec §6.4; 2 s; coordinate rounded to 2 decimals
  init(client: any SearchHTTPClient = URLSessionSearchHTTPClient.live, language: String = <the Mac's>)
}
enum WeatherLookup {
  static func description(forCode code: Int) -> String
  static func excerpt(_ forecast: WeatherForecast, placeName: String, now: Date) -> WebSearchResult
}
```

**The request** is exactly spec §6.4's URL, plus the US unit parameters for
`.us`. **Times** follow spec §6.4 (CP0's Q8): parse with
`utc_offset_seconds`, show in `timezone`, keep `daily.time` as dates, and
pick the next 24 hours by comparing with `now`.

**Weather code words,** from Open-Meteo's documentation:

| Codes | Words |
| --- | --- |
| 0, 1, 2, 3 | "clear sky", "mainly clear", "partly cloudy", "overcast" |
| 45, 48 | "fog", "freezing fog" |
| 51, 53, 55 | "light drizzle", "drizzle", "heavy drizzle" |
| 56, 57 | "light freezing drizzle", "freezing drizzle" |
| 61, 63, 65 | "light rain", "rain", "heavy rain" |
| 66, 67 | "light freezing rain", "freezing rain" |
| 71, 73, 75 | "light snow", "snow", "heavy snow" |
| 77 | "snow grains" |
| 80, 81, 82 | "light showers", "showers", "violent showers" |
| 85, 86 | "light snow showers", "snow showers" |
| 95 | "thunderstorm" |
| 96, 99 | "thunderstorm with hail" |
| Anything else | "unknown conditions" |

**The excerpt:** `Forecast for <placeName> (local times).`, a `Now:` line
(temperature, feels-like, words, humidity, wind, precipitation), `Next 24
hours:` 8 entries at 3-hour steps, and `Next 7 days:` (words, high, low,
precipitation chance and amount, UV, top wind, sunrise and sunset), with
Open-Meteo's units. Kind `.weather`; source "Open-Meteo forecast",
`https://open-meteo.com/`, with no location.

- [ ] **Write the failing tests:** `testOpenMeteoURLUsesRoundedCoordinatesAndUSUnits`
  (`latitude=41.88`, `longitude=-87.63`), `testMetricUnitsOmitUnitParameters`,
  `testForecastDecodesFixture`, `testWeatherCodesReadAsWords`,
  `testForecastExcerptReadsInWords` (one `Now:`, 8 hourly, 7 daily),
  `testDailyLabelAfterDaylightSavingChange` (the 2 November label reads 2
  November), `testWeatherSourceCarriesNoLocation`,
  `testGeocoderDecodesFixture` ("Paris, Île-de-France, France", 48.86,
  2.35), `testGeocoderNoResultIsNil`.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/PlacesAndWeatherTests`;
  expect failures. **Implement.** **Run** again.

### Task 6.2: Places

**Files:** create `Enigma/Search/PlaceSearch.swift`. Tests in
`PlacesAndWeatherTests`.

**Interfaces:**

```swift
struct MapPlace: Equatable, Sendable, Identifiable {   // for CP9; in memory only
  let id: String                                        // MKMapItem.identifier, or a stable fallback
  let name: String; let coordinate: SearchCoordinate; let distanceMeters: Double?
}
struct PlaceResult: Equatable, Sendable {
  let place: MapPlace; let category: String?; let address: String?
  let phone: String?; let website: URL?
}
protocol PlaceSearching: Sendable {
  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult]
}
struct MapKitPlaceSearch: PlaceSearching {
  static let nearSpanMeters = 5_000.0, wideSpanMeters = 20_000.0
  static let maximumResults = 10, minimumBeforeWidening = 3
  static let timeout: Duration = .seconds(3)
  init(run: @escaping @Sendable (_ query: String, _ center: SearchCoordinate?, _ spanMeters: Double?) async throws -> [PlaceResult] = MapKitPlaceSearch.live)
}
enum PlaceSearch {
  /// The text excerpt, and `places` on the result for the map card.
  static func excerpt(_ places: [PlaceResult], query: String, units: MeasurementUnits) -> WebSearchResult
}
// WebSearch.swift: WebSearchResult gains `var places: [MapPlace]? = nil`.
```

**Rules,** from spec §6.5: `.pointOfInterest` results; near the user a 5 km
region, widened to 20 km under 3 places; a named area, no region. Each item
maps to category, `fullAddress(includingRegion: false, singleLine: true)`,
phone, website and the distance computed on the Mac. The excerpt is a
numbered list of at most 10, distances in km or mi; kind `.places`; source
"Apple Maps", `https://maps.apple.com/?q=<percent-encoded query>`.

- [ ] **Write the failing tests:** `testPlacesExcerptListsUpToTen`,
  `testPlacesResultCarriesMapPlaces`, `testPlacesSourceCarriesNoLocation`
  (exactly `https://maps.apple.com/?q=cafes`),
  `testRegionWidensWhenFewerThanThree`, `testNoRegionForNamedArea`.
- [ ] **Run, implement, run.**

### Task 6.3: The routes in the provider (small models)

**Files:** `Enigma/Search/OnDeviceSearch.swift`. Tests in
`OnDeviceSearchTests` and `WebSearchTests`.

`OnDeviceSearchProvider.init` gains `places: any PlaceSearching =
MapKitPlaceSearch()`, `weather: any WeatherLooking = OpenMeteoWeather()`,
`geocoder: any Geocoding = OpenMeteoGeocoder()` and `units: @escaping
@Sendable () -> MeasurementUnits = { .current }`; `live()` passes the real
ones.

- **Weather:** the coordinate is `request.coordinate` or the geocoded
  `namedPlace`; the name is the geocoder's, the city, or "your area". Only
  the weather result; no search site is contacted. On any failure, or a
  place the geocoder can't find, the web route runs "weather <place>".
- **Places:** MapKit and the web route run at the same time; the places
  result comes first; a MapKit failure or no places means web results
  alone. The web query is `webQuery(request.query, city: request.city)`.

- [ ] **Write the failing tests:** `testWeatherRouteSkipsWebSearch`,
  `testWeatherFailureFallsBackToWeb` ("weather Chicago"),
  `testUnknownPlaceFallsBackToWeb`, `testPlacesRouteRunsMapsAndWeb`,
  `testPlacesFailureUsesWebOnly`, `testPlacesWithoutCityStillSearchMaps`
  (Review Focus 4), and in `WebSearchTests`
  `testSavedSourcesNeverContainLocation` (a weather and a places search
  through `LocalChatViewModel`; the saved JSON has no `41.88`, `-87.63` or
  `Chicago`).
- [ ] **Run, implement, run.**

### Task 6.4: The tools (capable models)

**Files:** create `Enigma/Search/PlacesAndWeatherTools.swift`; modify
`Enigma/Chat/AssistantToolbox.swift`, `LocalChatViewModel.swift`
(`nativeToolPlan`, `nativeToolbox`), `Enigma/Cloud/NativeWebSearch.swift`
(the near-me clause). Tests in the new
`EnigmaTests/PlacesAndWeatherToolTests.swift` and `NativeToolPlanTests`.

```swift
struct PlaceSearchTool: AgentToolbox {     // find_places(query, area?)
  init(places: any PlaceSearching, location: @escaping @Sendable () async -> ApproximateLocation?,
       units: @escaping @Sendable () -> MeasurementUnits, mayQuery: @escaping @Sendable (String) async -> Bool,
       onSources: @escaping @Sendable ([WebSearchSource]) async -> Void,
       onPlaces: @escaping @Sendable ([MapPlace]) async -> Void)
}
struct WeatherTool: AgentToolbox {         // get_weather(place?)
  init(weather: any WeatherLooking, geocoder: any Geocoding, location: …, units: …, mayQuery: …, onSources: …)
}
enum NativeToolPart { /* … */ case places, weather }
```

**Rules,** from spec §6.2:

- **Schemas and results** exactly as spec §6.2's table; results are JSON
  with sorted keys. `find_places` returns up to 10 places; `get_weather`
  the excerpt's content as structured fields (current, next 24 hours, next
  7 days, place name).
- **Instructions:** spec §6.2's sentences, added after `web_search`'s.
- **Near the user:** with no `area`/`place`, ask `location`; without one,
  return spec §6.2's text and make no MapKit or Open-Meteo request.
- **Gate 3:** in a chat that holds message text, `mayQuery` shows spec
  §6.2's card text first; Don't allow returns F32's declined result.
- **Activity:** **Finding places…** and **Checking the weather…**.
- **Failures** are tool results ("No places found.", "I couldn't find
  ‹place›.", the Open-Meteo error); the model carries on.
- **The plan:** `.places` and `.weather` join `.search` whenever search is
  offered (automatic search on, `/search` or `/maps`), on either backend:
  on a provider-search turn (F30) they're offered beside the provider's
  search. `ProviderSearchPart`'s near-me clause becomes spec §6.2's
  sentence when they're offered.
- **Saved sources** carry no location; `onPlaces` reaches the reply for
  CP9.

- [ ] **Write the failing tests:** `testFindPlacesSchema`,
  `testFindPlacesNearUser` (rounded coordinate to the fake, distances in the
  result), `testFindPlacesInArea` (no coordinate, "ramen in Soho, London"),
  `testFindPlacesWithoutLocationAsksForArea` (Review Focus 6),
  `testGetWeatherNearUser`, `testGetWeatherUnknownPlace`,
  `testSearchToolsAskFirstAfterMessageText`, `testToolActivityText`,
  `testToolSourcesCarryNoLocation`; in `NativeToolPlanTests`,
  `testPlacesAndWeatherOfferedWithSearch` (both backends, not without
  search) and `testProviderSearchNearMeClause`.
- [ ] **Run, implement, run.** F32's and F30's existing tests stay green
  unchanged.

### Task 6.5: `/maps`

**Files:** `SlashCommand.swift`, `ScreenAttachment.swift`
(`ComposerCommands.maps`), `ComposerIntent.swift`,
`ComposerSubmission.swift`, `SearchRouting.swift`, `AssistantToolbox.swift`,
`LocalChatViewModel.swift`. Tests in `ComposerIntentTests`,
`SearchRoutingTests`, `NativeToolPlanTests`, `AppShellStateTests`.

Spec §6.3: description "Find places with Apple Maps"; in suggestions, Help
and the welcome tour (with the key requirement `/search` has until CP8);
small models take the places route whatever the wording; capable models
must call `find_places` first; `/maps` wins over `/search`; it conflicts
with files, `/messages` and a screenshot like `/search`; alone, it keeps the
draft with "There's nothing to look for."

- [ ] **Write the failing tests:** `testMapsIsACommand`,
  `testMapsRoutesToPlacesOnSmallModels` ("/maps bookshops", "/maps where
  can I get a haircut"), `testMapsRequiresFindPlaces`,
  `testMapsWinsOverSearch` (Review Focus 8), `testMapsAloneKeepsDraft`
  (Review Focus 8), `testMapsConflicts`.
- [ ] **Run, implement, run.**

### Task 6.6: Live checks and the notice

- [ ] **Add to `WebSearchLiveTests`:** `testLiveOpenMeteo` (Chicago, decodes),
  `testLiveGeocoder` ("Paris", latitude 48.7–49.0), `testLiveMapKitPlaces`
  ("coffee" near 41.88, -87.63, at least 3).
- [ ] **Run** them with `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1`.
- [ ] **Add the notice** to `ThirdPartyNotices.txt`: "Weather data by
  Open-Meteo.com (https://open-meteo.com/), CC BY 4.0." (geocoding
  included).

## Exit criteria

- [ ] `build` and `analyze` pass, the touched test classes pass, the full
  `test` runs once before the commit, and the live checks pass.
- [ ] **A manual Debug-switch check** (as in CP5), on a small and a capable
  model: "will it rain tomorrow", "weather in Paris this weekend", "cafe
  near me", "ramen in Soho", "/maps bookshops", and "what is the
  temperature to bake salmon" (no weather lookup). Each answers from the
  right source; the sources show "Open-Meteo forecast" or "Apple Maps" with
  no location in the link.

## Reviewer checklist

- **Who gets the location:** Open-Meteo and MapKit get coordinates rounded
  to 2 decimals; search sites only the city; no provider search ever gets
  it.
- **Saved sources carry no location;** mutate the assertions in
  `testSavedSourcesNeverContainLocation` and confirm it fails.
- **Fallbacks and timeouts** on every path: geocoding timeout, MapKit 3 s.
- **Gate 3** covers both new tools; mutation: skip `mayQuery`, a test fails.
- **No MapKit data in weather:** weather geocodes with Open-Meteo only.

## Hand-off

*Filled in by the CP6 worker.*

1. **Summary:** Tasks 6.1–6.6 are done (no review round yet). Weather comes
   from Open-Meteo (`OpenMeteoWeather`, 3 s) with Open-Meteo geocoding
   (`OpenMeteoGeocoder`, 2 s, 5 matches, exact name preferred, name and
   country stated, D81); places from Apple Maps (`MapKitPlaceSearch`, 5 km
   widened to 20 km under 3 places, 3 s, distances computed on the Mac).
   On small models `OnDeviceSearchProvider` answers the weather route from
   Open-Meteo alone (web "weather <place>" on any failure or unknown place) and
   runs MapKit beside the web route for places (places first; web alone when
   MapKit fails or finds nothing). Capable models get `find_places` and
   `get_weather` whenever search is offered, on either backend, or with `/maps`
   (D83), with gate 3 (D85), their own activity text (D82) and F30's new
   near-me clause. `/maps` is a command: places route on small models,
   `find_places` required on capable ones, wins over `/search`, conflicts with
   files, `/messages` and a screenshot, and alone keeps the draft (D84). Saved
   sources never carry the location. Brave stays the default; the Debug switch
   reaches all of it.
2. **Files:**
   - New: `Enigma/Search/WeatherLookup.swift` (`MeasurementUnits`,
     `WeatherForecast`, `WeatherLooking`, `OpenMeteoWeather`, `Geocoding`,
     `OpenMeteoGeocoder`, `WeatherReport`, `WeatherLookup`, `WeatherLookupError`,
     `LookupTimeLimit`), `Enigma/Search/PlaceSearch.swift` (`MapPlace`,
     `PlaceResult`, `PlaceSearching`, `MapKitPlaceSearch`, `PlaceSearch`,
     `PlaceSearchError`), `Enigma/Search/PlacesAndWeatherTools.swift`
     (`PlaceSearchTool`, `WeatherTool`, `PlacesAndWeatherTools`),
     `EnigmaTests/PlacesAndWeatherTests.swift` (with the shared fakes
     `FakeWeather`, `FakeGeocoder`, `FakePlaces`),
     `EnigmaTests/PlacesAndWeatherToolTests.swift`; all five registered in the
     Xcode project.
   - Search: `WebSearch.swift` (`WebSearchResult.places`),
     `WebSearchContext.swift` (`fitted` keeps `places`), `OnDeviceSearch.swift`
     (the two routes, new `init` parameters, `live()`), `SearchRouting.swift`
     (`decide(question:maps:)`).
   - Chat: `AssistantToolbox.swift` (`NativeToolPart.places/.weather`,
     `offersPlacesAndWeather`, `offeredParts`, `/maps`; empty instructions
     skipped), `AssistantActivity.swift`/`AssistantActivityView.swift` (phases),
     `ToolPermissions.swift`, `ToolPermissionCoordinator.swift`,
     `ToolPermissionCard.swift` (`lookUpAfterMessages`), `NativeWebSearch.swift`
     (`ProviderSearchPart.offersPlacesAndWeather`), `LocalChatViewModel.swift`
     (`nativeToolbox` tools, `replyPlaces`, `shouldSearch` and `search` read
     `/maps`).
   - App: `SlashCommand.swift`, `ScreenAttachment.swift` (`ComposerCommands.maps`),
     `ComposerIntent.swift`, `ComposerSubmission.swift` (`.nothingToFind`,
     `.mapsConflict`), `AppShellView.swift`, `EnigmaMainWindowLogic.swift`,
     `KeyboardShortcutsHelpView.swift`.
   - `Enigma/Resources/ThirdPartyNotices.txt`: the Open-Meteo notice.
   - Tests extended: `OnDeviceSearchTests` (harness gains the fakes and
     `route`/`namedPlace`), `WebSearchTests`, `SearchRoutingTests`,
     `ComposerIntentResolveTests`, `ComposerSubmissionTests`,
     `NativeToolPlanTests`, `WebSearchLiveTests`; `NativeToolRequestTests`
     changed on purpose (D86).
3. **Decisions:** D81 (geocoding count 5, exact name, names as returned, so the
   Paris fixture reads "Paris, Île-de-France Region, France", 48.85), D82
   (two activity phases), D83 (`offeredParts`), D84 (how `/maps` travels; its
   conflicts; Help and welcome), D85 (tool details: source without the area,
   location before the card, `lookUpAfterMessages`, `replyPlaces`), D86
   (three F30/F32 assertions follow spec §6.2).
   Beyond the brief: `testForecastLookupSendsTheURLAndDecodes`,
   `testForecastFailureThrows`, `testGeocoderPrefersExactNameAndQualifier`,
   `testGeocoderFailureThrows`, `testPlaceDistanceIsComputedOnTheMac`,
   `testPlaceCategoryReadsAsWords`, `testWeatherWithoutCityIsYourArea`,
   `testNamedPlaceIsGeocodedWithOpenMeteo`, `testNamedAreaPlacesHaveNoRegion`,
   `testPlacesSurviveAWebFailure`, `testMapsSearchesPlacesNearTheUser`.
4. **Verification** (`scripts/verify-xcode.sh`, logs outside the repo):
   - Task 6.1–6.2: the tests were written before the code but first run
     after it: `PlacesAndWeatherTests` 20 executed, 0 failed. Task 6.3: RED
     (compile failure: the provider had no `places:`/`weather:` parameters),
     then `OnDeviceSearchTests` 37 executed, 0 failed. Tasks 6.3–6.5 together:
     `PlacesAndWeatherToolTests`, `NativeToolPlanTests`, `SearchRoutingTests`,
     `ComposerIntentResolveTests`, `ComposerSubmissionTests`, `WebSearchTests`,
     `PlacesAndWeatherTests`, `OnDeviceSearchTests`: 214 executed, 0 skipped,
     0 failed (`WebSearchTests` 81).
   - Wider classes (27 non-UI classes touching the changed names, with the
     D31 time-limit flags): 512 executed, 3 skipped, 5 failed, all in
     `NativeToolRequestTests` and all from the intended changes (D86); after
     D86, `NativeToolRequestTests` 83 executed, 0 failed.
   - Live (`TEST_RUNNER_ENIGMA_LIVE_SEARCH=1`, Chicago test coordinates):
     `testLiveOpenMeteo` 0.17 s, 168 hours, 7 days; `testLiveGeocoder` 0.64 s,
     "Paris, Île-de-France Region, France"; `testLiveMapKitPlaces` 0.63 s,
     10 places, all with addresses. 3 executed, 0 failed.
   - `build`: succeeded.
   - Final, after review round 2: the CP6 classes plus
     `NativeToolRequestTests`, `SearchRoutingTests` and `WebSearchTests`
     (`PlacesAndWeatherTests`, `PlacesAndWeatherToolTests`,
     `OnDeviceSearchTests`, `NativeToolPlanTests`, `ComposerIntentResolveTests`,
     `ComposerSubmissionTests`): 306 executed, 0 skipped, 0 failed.
   - `build` and `analyze` succeeded.
   - Full suite (`-test-timeouts-enabled YES
     -default-test-execution-time-allowance 60`, screen locked): 1,957 test
     cases, 1,838 passed, 38 skipped, 81 failed. The 81 are the same classes
     and counts as D32's and CP5's environment failures (D25): AppCommandTests 2,
     ChatCopyTests 2, ComposerIntentChipsTests 2, EnigmaCompactPanelTests 15,
     EnigmaConversationTests 18, EnigmaMainWindowTests 29, FileModeUITests 1,
     ScreenCaptureTests 1, ScreenViewTests 11. Each one is a key-window or UI
     wait, and none is in Search. CI is the check for them.
   - Not run: the manual Debug-switch check (exit criteria).
5. **Limitations:**
   - Mutation checks from the reviewer checklist (saved-source assertions,
     skipping `mayQuery`) weren't run; `testSavedSourcesNeverContainLocation`
     and `testSearchToolsAskFirstAfterMessageText` are where they'd fail.
   - `MKLocalSearch` is cancelled on the main actor when the 3 s limit ends;
     the limit waits for the search to stop, which MapKit does promptly but
     isn't measured.
   - The places excerpt's link carries a named area the user typed ("ramen in
     soho") on small models, as the brief's URL rule says; `find_places`
     leaves the area out (D85).
   - `docs/Web-Search.md` isn't updated: places and weather stay behind the
     Debug switch until CP8/CP9, and CP10 owns the docs.
   - The welcome page's command line doesn't mention `/maps` (D84).
6. **Review round 1 (1 Blocker, 4 Should fixes, plus the notice; all six fixed; D87, D88):**
   - Blocker: "Don't allow" on F30's location card now also keeps that
     turn's `find_places`/`get_weather` from the location (they answer "The
     user's location isn't available…"), and the "ask which city they mean"
     clause stays; spec §6.2 is marked amended. `testLocationDeclinedSendsNothing`
     checks the original clause again (`askClause` is F30's; the location-off
     and unavailable tests use the new `toolsClause`). New
     `testLocationDeclinedKeepsPlacesToolsFromTheLocation`.
   - `/maps` no longer counts times, home, work or school as named areas
     (`LocationIntent.mapsArea`; `testMapsTimesAndWorkAreNotAreas`).
   - `find_places`'s saved link drops the city's words near the user, or is
     bare `https://maps.apple.com/` (`testFindPlacesSourceDropsTheCity`).
   - Gate 3 on both tools and both backends, through the view model
     (`testPlacesAndWeatherAskFirstAfterMessageText`).
   - Time limits on a test clock (`testLookupsTimeOut`), and the provider's
     fallback on a weather timeout (`testWeatherTimeoutFallsBackToWeb`).
   - GeoNames (CC BY 4.0) credited beside Open-Meteo.
   - The fixes were written before their tests this round, so no failing run
     was seen first. After the fixes: `PlacesAndWeatherTests`,
     `PlacesAndWeatherToolTests`, `OnDeviceSearchTests`, `NativeToolPlanTests`,
     `ComposerIntentResolveTests`, `ComposerSubmissionTests`,
     `NativeToolRequestTests`, `SearchRoutingTests`, `WebSearchTests`:
     303 executed, 0 skipped, 0 failed (`NativeToolRequestTests` 85).
7. **Review round 2 (no Blockers, 4 Should fixes, all fixed test-first; D89, D90; no round 3):**
   - A declined location card is remembered in memory for the chat and
     provider until a later Allow, and it now covers `web_search` too: the
     fallback after a decline sends no city or coordinate
     (`testDeclinedLocationFallbackWebSearchSendsNoLocation`,
     `testLocationDeclineLastsForTheChat`).
   - `find_places`'s link strips `near?.searchCity ?? area`, and a city word
     inside an unspaced query gives the bare link
     (`testFindPlacesSourceDropsTheAreaAndUnspacedCities`).
   - `MapKitPlaceSearch.timeout` is pinned at 3 s.
   - RED: the 3 new tests failed (9 assertions) before the fixes; after them,
     306 executed, 0 failed.
8. **For the next checkpoint:**
   - CP9: `WebSearchResult.places` carries a small-model places result's
     places; capable turns put theirs in `LocalChatViewModel.replyPlaces[messageID]`
     (in memory). Neither reaches `ChatMessage` yet; CP9 adds `mapPlaces`.
   - CP7: `OpenMeteoWeather`, `OpenMeteoGeocoder` and `MapKitPlaceSearch` take a
     clock; `WeatherLookup.report` is the structured forecast both paths use.
   - `LookupTimeLimit.run` is the shared time limit for one lookup.
