# CP6: Places and weather

Read [agent-workflow.md](agent-workflow.md), the spec (§6, §7), and the
Hand-offs of [CP0](cp0-spike.md#hand-off), where Q7 covers MapKit and Q8
covers Open-Meteo, and [CP5](cp5-passages-and-pipeline.md#hand-off).

## Goal

Weather questions are answered from Open-Meteo, and nearby questions from
Apple Maps together with web search. Saved sources never carry a location.
This applies however the search started, `/search` included: CP1's routing
already decides the route from the typed question.

## Starting point

- **Routing:** `WebSearchRequest.route`, `.namedPlace`, `.city` and
  `.coordinate` reach the provider (CP1).
- **The provider:** `OnDeviceSearchProvider` handles `.places` and
  `.weather` as web searches (CP5).
- **Fixtures:** `EnigmaTests/Fixtures/Search/open-meteo-chicago.json` came
  from CP0.
- **MapKit:** `LocationService` already uses `MKReverseGeocodingRequest` and
  `MKMapItem.addressRepresentations` (macOS 26 APIs).

## Tasks

### Task 6.1: Weather

**Files:**

- Create `Enigma/Search/WeatherLookup.swift`.
- Test: create `EnigmaTests/PlacesAndWeatherTests.swift`.

**Interfaces.** This task produces:

```swift
enum MeasurementUnits: Equatable, Sendable { case metric, us; static var current: MeasurementUnits { get } }  // Locale.current.measurementSystem == .us
struct WeatherForecast: Decodable, Equatable, Sendable                 // current, hourly and daily blocks, with their units, as requested
protocol WeatherLooking: Sendable {
  func forecast(at coordinate: SearchCoordinate, units: MeasurementUnits) async throws -> WeatherForecast
}
struct OpenMeteoWeather: WeatherLooking {
  static let timeout: Duration = .seconds(3)
  init(client: any SearchHTTPClient = URLSessionSearchHTTPClient.live)
  static func url(for coordinate: SearchCoordinate, units: MeasurementUnits) -> URL
}
protocol Geocoding: Sendable { func locate(_ place: String) async throws -> (coordinate: SearchCoordinate, name: String) }
struct MapKitGeocoder: Geocoding       // MKGeocodingRequest; coordinate rounded to 2 decimals; 2 s timeout
enum WeatherLookup {
  static func description(forCode code: Int) -> String                 // the WMO code table, in words
  static func excerpt(_ forecast: WeatherForecast, placeName: String) -> WebSearchResult
}
```

**The request** is exactly spec §6's URL. For `.us` it adds
`temperature_unit=fahrenheit`, `wind_speed_unit=mph` and
`precipitation_unit=inch`.

**Weather code words**, from Open-Meteo's documentation:

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

**The excerpt:**

- **Text,** with the units Open-Meteo reports in `current_units` and
  `daily_units`:
  - `Forecast for <placeName> (local times).`
  - a `Now:` line: temperature, feels-like, words, humidity, wind,
    precipitation;
  - `Next 24 hours:` 8 entries at 3-hour steps;
  - `Next 7 days:` one entry per day: words, high, low, precipitation chance
    and amount, UV, top wind, sunrise and sunset.
- **Kind:** `.weather`.
- **Source:** `WebSearchSource(title: "Open-Meteo forecast", url: https://open-meteo.com/)`,
  with no location in it.

**Steps:**

- [ ] **Write the failing tests:**
  - `testOpenMeteoURLUsesRoundedCoordinatesAndUSUnits`: every query item,
    with `latitude=41.88` and `longitude=-87.63`;
  - `testMetricUnitsOmitUnitParameters`;
  - `testForecastDecodesFixture`;
  - `testWeatherCodesReadAsWords`: 0 gives "clear sky", 61 "light rain",
    95 "thunderstorm", and 1234 "unknown conditions";
  - `testForecastExcerptReadsInWords`: it contains "Forecast for Chicago",
    one `Now:` line, 8 hourly entries and 7 daily entries;
  - `testWeatherSourceCarriesNoLocation`;
  - `testNamedPlaceIsGeocodedAndStated`. A fake geocoder maps "paris" to
    48.86, 2.35 and "Paris, Île-de-France, France". The excerpt names it, and
    the request URL has `latitude=48.86`.
- [ ] **Run**
  `scripts/verify-xcode.sh test -only-testing:EnigmaTests/PlacesAndWeatherTests`.
  Expect failures.
- [ ] **Implement** `WeatherLookup.swift`.
- [ ] **Run** the tests. Expect them to pass.

### Task 6.2: Places

**Files:** create `Enigma/Search/PlaceSearch.swift`. Tests go in
`PlacesAndWeatherTests`.

**Interfaces.** This task produces:

```swift
struct PlaceResult: Equatable, Sendable {
  let name: String; let category: String?; let address: String?
  let distanceMeters: Double?; let phone: String?; let website: URL?
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
  static func excerpt(_ places: [PlaceResult], query: String, units: MeasurementUnits) -> WebSearchResult
}
```

**Rules, from spec §6:**

- **The MapKit query** is `SearchRouting.webQuery(question, city: nil)`, so
  the nearby words are removed. A named area stays in the text.
- **The request** is `MKLocalSearch` with `.pointOfInterest` results:
  - with a coordinate: a 5 km region, widened to 20 km when fewer than 3
    places come back;
  - with no coordinate: no region at all.
- **Mapping each `MKMapItem`:**
  - the category name from `pointOfInterestCategory`;
  - the address from `addressRepresentations`;
  - the phone number, and the website from `url`;
  - the distance, computed on the Mac.
- **The excerpt** is a numbered list of at most 10 places, with distances in
  km or mi. Its kind is `.places`, and its source is
  `WebSearchSource(title: "Apple Maps", url: https://maps.apple.com/?q=<percent-encoded query>)`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testPlacesExcerptListsUpToTen`: 12 places in, 10 lines out;
  - `testPlacesSourceCarriesNoLocation`: the URL is exactly
    `https://maps.apple.com/?q=cafes`;
  - `testRegionWidensWhenFewerThanThree`: the seam sees span 5,000, then
    20,000;
  - `testNoRegionForNamedArea`: the seam sees a `nil` span.
- [ ] **Run** `PlacesAndWeatherTests`. Expect failures.
- [ ] **Implement** `PlaceSearch.swift`.
- [ ] **Run** `PlacesAndWeatherTests`. Expect them to pass.

### Task 6.3: The routes in the provider

**Files:** modify `Enigma/Search/OnDeviceSearch.swift`. Tests go in
`OnDeviceSearchTests` and `WebSearchTests`.

**Interfaces.**

- **Consumes:** `request.route`, `.namedPlace`, `.coordinate` and `.city`.
- **Produces:** `OnDeviceSearchProvider.init` gains four parameters, each
  with a default, and `live()` passes the real ones:
  - `places: any PlaceSearching = MapKitPlaceSearch()`;
  - `weather: any WeatherLooking = OpenMeteoWeather()`;
  - `geocoder: any Geocoding = MapKitGeocoder()`;
  - `units: @escaping @Sendable () -> MeasurementUnits = { .current }`.

**Rules:**

- **Weather:**
  - The coordinate is `request.coordinate`, or the geocoded `namedPlace`.
  - The place name is the geocoder's name, the city, or "your area".
  - It returns only the weather result, and never contacts a search site.
  - On any failure, it runs the web route with the query "weather <place>".
- **Places:**
  - MapKit and the web route run at the same time. The places result comes
    first.
  - A MapKit failure, or no places, means web results alone.
  - The web query is `webQuery(request.query, city: request.city)`.

**Steps:**

- [ ] **Write the failing tests:**
  - `testWeatherRouteSkipsWebSearch`: the fake client gets no requests;
  - `testWeatherFailureFallsBackToWeb`: the engine sees "weather Chicago";
  - `testPlacesRouteRunsMapsAndWeb`;
  - `testPlacesFailureUsesWebOnly`;
  - `testPlacesWithoutCityStillSearchMaps` (Review Focus 4): with a
    coordinate and `city == nil`, MapKit gets "cafes" and the coordinate, and
    the web query is "cafes";
  - `testSavedSourcesNeverContainLocation`, in `WebSearchTests`. Through
    `LocalChatViewModel` with fakes and `SearchLocation()`, run a weather
    search and a places search. The saved store's JSON contains no `41.88`,
    no `-87.63`, and no `Chicago` in any `searchSources`.
- [ ] **Run** `OnDeviceSearchTests` and `WebSearchTests`. Expect failures.
- [ ] **Implement** the routes.
- [ ] **Run** them again. Expect them to pass.

### Task 6.4: Live checks and the notice

- [ ] **Add to `WebSearchLiveTests`:**
  - `testLiveOpenMeteo`: Chicago, HTTP 200, and the response decodes;
  - `testLiveMapKitPlaces`: "coffee" near 41.88, -87.63 returns at least 3
    places;
  - `testLiveGeocoder`: "Paris" gives a latitude between 48.7 and 49.0.
- [ ] **Run the live checks:**
  `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1 scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchLiveTests`.
  Expect them to pass.
- [ ] **Add the notice** to `ThirdPartyNotices.txt`: "Weather data by
  Open-Meteo.com (https://open-meteo.com/), CC BY 4.0."

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass, and the
  live checks pass.
- [ ] **A manual Debug-switch check** (as in CP5) of "will it rain
  tomorrow", "/search weather in Paris this weekend", "/search cafe near me"
  and "ramen in Soho". Each answers from the right source, and the reply's
  sources list shows "Open-Meteo forecast" or "Apple Maps" with no location
  in the link.

## Reviewer checklist

- **Who gets the location:** Open-Meteo and MapKit get coordinates rounded to
  2 decimals; search sites only ever get the city.
- **Saved sources carry no location.** Run
  `testSavedSourcesNeverContainLocation` with the assertions mutated, and
  confirm it fails.
- **Fallbacks and timeouts:** weather falls back to web on every failure
  path, including a geocoding timeout, and MapKit gets 3 s.
- **The terms match CP0's Q7 finding.** Text-only use of MapKit results is
  allowed, or the owner approved otherwise.

## Hand-off

*Filled in by the CP6 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
