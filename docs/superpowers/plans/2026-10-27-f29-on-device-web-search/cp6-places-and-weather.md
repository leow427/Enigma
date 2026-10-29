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

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
