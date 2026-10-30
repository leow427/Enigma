import XCTest
@testable import Enigma

/// Open-Meteo weather and geocoding, and Apple Maps places (spec §6.4, §6.5).
final class PlacesAndWeatherTests: XCTestCase {
  private let chicago = SearchCoordinate(latitude: 41.88, longitude: -87.63)

  private func forecast() throws -> WeatherForecast {
    try JSONDecoder().decode(WeatherForecast.self, from: SearchFixture.data("open-meteo-chicago.json"))
  }

  /// 2026-10-27 15:30 in Chicago (UTC−5), the fixture's `current.time`.
  private let fixtureNow = Date(timeIntervalSince1970: 1_793_133_000)

  private func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  // MARK: Weather

  func testOpenMeteoURLUsesRoundedCoordinatesAndUSUnits() {
    let url = OpenMeteoWeather.url(for: SearchCoordinate(latitude: 41.8812, longitude: -87.6298), units: .us)
    XCTAssertEqual(url.host(), "api.open-meteo.com")
    XCTAssertEqual(url.path(), "/v1/forecast")
    let items = queryItems(url)
    XCTAssertEqual(items["latitude"], "41.88")
    XCTAssertEqual(items["longitude"], "-87.63")
    XCTAssertEqual(items["current"],
                   "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m")
    XCTAssertEqual(items["hourly"], "temperature_2m,precipitation_probability,weather_code")
    XCTAssertEqual(items["daily"],
                   "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max,wind_speed_10m_max")
    XCTAssertEqual(items["timezone"], "auto")
    XCTAssertEqual(items["forecast_days"], "7")
    XCTAssertEqual(items["temperature_unit"], "fahrenheit")
    XCTAssertEqual(items["wind_speed_unit"], "mph")
    XCTAssertEqual(items["precipitation_unit"], "inch")
  }

  func testMetricUnitsOmitUnitParameters() {
    let items = queryItems(OpenMeteoWeather.url(for: chicago, units: .metric))
    XCTAssertNil(items["temperature_unit"])
    XCTAssertNil(items["wind_speed_unit"])
    XCTAssertNil(items["precipitation_unit"])
    XCTAssertEqual(items["latitude"], "41.88")
  }

  func testForecastDecodesFixture() throws {
    let forecast = try forecast()
    XCTAssertEqual(forecast.utcOffsetSeconds, -18_000)
    XCTAssertEqual(forecast.timezone, "America/Chicago")
    XCTAssertEqual(forecast.current.temperature, 63.1)
    XCTAssertEqual(forecast.current.weatherCode, 3)
    XCTAssertEqual(forecast.hourly.time.count, 168)
    XCTAssertEqual(forecast.daily.time.count, 7)
    XCTAssertEqual(forecast.currentUnits.temperature, "°F")
  }

  func testForecastLookupSendsTheURLAndDecodes() async throws {
    let client = FakeSearchHTTPClient()
    client.stub(OpenMeteoWeather.url(for: chicago, units: .us),
                .response(status: 200, body: SearchFixture.data("open-meteo-chicago.json")))
    let forecast = try await OpenMeteoWeather(client: client).forecast(at: chicago, units: .us)
    XCTAssertEqual(forecast.timezone, "America/Chicago")
    XCTAssertEqual(client.requests.count, 1)
  }

  func testForecastFailureThrows() async {
    let client = FakeSearchHTTPClient()
    client.fallback = .response(status: 503, body: Data())
    do {
      _ = try await OpenMeteoWeather(client: client).forecast(at: chicago, units: .metric)
      XCTFail("Expected a failure")
    } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
  }

  func testWeatherCodesReadAsWords() {
    let expected: [Int: String] = [
      0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
      51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "light freezing drizzle", 57: "freezing drizzle",
      61: "light rain", 63: "rain", 65: "heavy rain", 66: "light freezing rain", 67: "freezing rain",
      71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "light showers", 81: "showers",
      82: "violent showers", 85: "light snow showers", 86: "snow showers", 95: "thunderstorm",
      96: "thunderstorm with hail", 99: "thunderstorm with hail", 4: "unknown conditions", -1: "unknown conditions",
    ]
    for (code, words) in expected { XCTAssertEqual(WeatherLookup.description(forCode: code), words, "\(code)") }
  }

  func testForecastExcerptReadsInWords() throws {
    let result = WeatherLookup.excerpt(try forecast(), placeName: "Chicago, Illinois, United States", now: fixtureNow)
    XCTAssertEqual(result.kind, .weather)
    let text = try XCTUnwrap(result.snippets.first)
    XCTAssertTrue(text.hasPrefix("Forecast for Chicago, Illinois, United States (local times)."), text)
    let lines = text.components(separatedBy: "\n")
    XCTAssertEqual(lines.filter { $0.hasPrefix("Now:") }.count, 1)
    let now = try XCTUnwrap(lines.first { $0.hasPrefix("Now:") })
    for part in ["63.1°F", "feels like 62.9°F", "overcast", "humidity 81%", "wind 6.0 mp/h", "precipitation 0.00 inch"] {
      XCTAssertTrue(now.contains(part), "\(part) in \(now)")
    }
    let hourStart = try XCTUnwrap(lines.firstIndex(of: "Next 24 hours:"))
    let dayStart = try XCTUnwrap(lines.firstIndex(of: "Next 7 days:"))
    let hours = lines[(hourStart + 1)..<dayStart].filter { $0.hasPrefix("- ") }
    XCTAssertEqual(hours.count, 8)
    // The current hour first, then 3-hour steps, in local time.
    XCTAssertTrue(hours[0].hasPrefix("- Tue 15:00"), hours[0])
    XCTAssertTrue(hours[1].hasPrefix("- Tue 18:00"), hours[1])
    let days = lines[(dayStart + 1)...].filter { $0.hasPrefix("- ") }
    XCTAssertEqual(days.count, 7)
    XCTAssertTrue(days[0].hasPrefix("- Tue 27 Oct:"), days[0])
    for part in ["high", "low", "chance of precipitation", "UV", "wind up to", "sunrise 07:17", "sunset"] {
      XCTAssertTrue(days[0].contains(part), "\(part) in \(days[0])")
    }
    XCTAssertFalse(text.contains("unknown conditions"))
  }

  func testDailyLabelAfterDaylightSavingChange() throws {
    let text = try XCTUnwrap(WeatherLookup.excerpt(try forecast(), placeName: "Chicago", now: fixtureNow).snippets.first)
    let day = try XCTUnwrap(text.components(separatedBy: "\n").last { $0.hasPrefix("- ") })
    // `daily.time` is a calendar date: 2 November stays 2 November after the clocks change.
    XCTAssertTrue(day.hasPrefix("- Mon 2 Nov:"), day)
    // Sunrise is parsed with the fixture's single offset (UTC−5) and shown in Chicago's time,
    // which is UTC−6 after 1 November.
    XCTAssertTrue(day.contains("sunrise 06:24"), day)
  }

  func testWeatherSourceCarriesNoLocation() throws {
    let result = WeatherLookup.excerpt(try forecast(), placeName: "Chicago", now: fixtureNow)
    XCTAssertEqual(result.source, WebSearchSource(title: "Open-Meteo forecast", url: URL(string: "https://open-meteo.com/")!))
    XCTAssertNil(result.places)
  }

  // MARK: Geocoding

  private func geocoder(_ body: Data, status: Int = 200) -> (OpenMeteoGeocoder, FakeSearchHTTPClient) {
    let client = FakeSearchHTTPClient()
    client.fallback = .response(status: status, body: body)
    return (OpenMeteoGeocoder(client: client, language: "en"), client)
  }

  func testGeocoderDecodesFixture() async throws {
    let (geocoder, client) = geocoder(SearchFixture.data("open-meteo-geocoding-paris.json"))
    let found = try await XCTUnwrapAsync(await geocoder.locate("Paris"))
    XCTAssertEqual(found.name, "Paris, Île-de-France Region, France")
    XCTAssertEqual(found.coordinate, SearchCoordinate(latitude: 48.85, longitude: 2.35))
    let url = try XCTUnwrap(client.requests.first?.url)
    XCTAssertEqual(url.host(), "geocoding-api.open-meteo.com")
    let items = queryItems(url)
    XCTAssertEqual(items["name"], "Paris")
    XCTAssertEqual(items["language"], "en")
    XCTAssertEqual(items["format"], "json")
    XCTAssertEqual(items["count"], String(OpenMeteoGeocoder.resultCount))
  }

  func testGeocoderNoResultIsNil() async throws {
    let (geocoder, _) = geocoder(Data(#"{"generationtime_ms":0.2}"#.utf8))
    let found = try await geocoder.locate("東京")
    XCTAssertNil(found)
  }

  func testGeocoderPrefersExactNameAndQualifier() async throws {
    let body = Data(#"""
    {"results":[
      {"name":"Parisse","latitude":19.1,"longitude":-72.1,"country":"Haiti","country_code":"HT","admin1":"Nord-Est"},
      {"name":"Springfield","latitude":37.21,"longitude":-93.29,"country":"United States","country_code":"US","admin1":"Missouri"},
      {"name":"Springfield","latitude":39.80,"longitude":-89.64,"country":"United States","country_code":"US","admin1":"Illinois"}
    ]}
    """#.utf8)
    let (geocoder, client) = geocoder(body)
    let illinois = try await XCTUnwrapAsync(await geocoder.locate("springfield, illinois"))
    XCTAssertEqual(illinois.name, "Springfield, Illinois, United States")
    XCTAssertEqual(queryItems(try XCTUnwrap(client.requests.first?.url))["name"], "springfield")
    let plain = try await XCTUnwrapAsync(await geocoder.locate("Springfield"))
    XCTAssertEqual(plain.name, "Springfield, Missouri, United States")
    // No exact match: the first result, with its name stated so a typo shows.
    let typo = try await XCTUnwrapAsync(await geocoder.locate("Pariss"))
    XCTAssertEqual(typo.name, "Parisse, Nord-Est, Haiti")
  }

  func testGeocoderFailureThrows() async {
    let (geocoder, _) = geocoder(Data(), status: 500)
    do {
      _ = try await geocoder.locate("Paris")
      XCTFail("Expected a failure")
    } catch {}
  }

  // MARK: Places

  func testPlacesExcerptListsUpToTen() throws {
    let places = (1...12).map { testPlace($0, distance: Double($0) * 400) }
    let result = PlaceSearch.excerpt(places, query: "cafes", units: .metric)
    XCTAssertEqual(result.kind, .places)
    let text = try XCTUnwrap(result.snippets.first)
    let items = text.components(separatedBy: "\n").filter { $0.first?.isNumber == true }
    XCTAssertEqual(items.count, 10)
    XCTAssertTrue(items[0].hasPrefix("1. Cafe 1"), items[0])
    for part in ["Cafe", "1 Main St, Chicago", "0.4 km away", "+1 312 555 011", "https://cafe1.example"] {
      XCTAssertTrue(items[0].contains(part), "\(part) in \(items[0])")
    }
    XCTAssertFalse(text.contains("Cafe 11"))
    let miles = try XCTUnwrap(PlaceSearch.excerpt([testPlace(1, distance: 1_609.344)], query: "cafes", units: .us).snippets.first)
    XCTAssertTrue(miles.contains("1.0 mi away"), miles)
    let area = try XCTUnwrap(PlaceSearch.excerpt([testPlace(1)], query: "ramen in Soho, London", units: .metric).snippets.first)
    XCTAssertFalse(area.contains("away"), area)
  }

  func testPlacesResultCarriesMapPlaces() {
    let places = (1...12).map { testPlace($0) }
    let result = PlaceSearch.excerpt(places, query: "cafes", units: .metric)
    XCTAssertEqual(result.places, places.prefix(10).map(\.place))
  }

  func testPlacesSourceCarriesNoLocation() {
    let result = PlaceSearch.excerpt([testPlace(1, distance: 300)], query: "cafes", units: .metric)
    XCTAssertEqual(result.source, WebSearchSource(title: "Apple Maps", url: URL(string: "https://maps.apple.com/?q=cafes")!))
    let spaced = PlaceSearch.excerpt([testPlace(1)], query: "ramen in soho", units: .metric)
    XCTAssertEqual(spaced.source.url.absoluteString, "https://maps.apple.com/?q=ramen%20in%20soho")
  }

  func testRegionWidensWhenFewerThanThree() async throws {
    let calls = LockedCalls()
    let search = MapKitPlaceSearch(run: { query, center, span in
      calls.append(query, center, span)
      return span == MapKitPlaceSearch.nearSpanMeters ? [testPlace(1), testPlace(2)] : (1...12).map { testPlace($0) }
    })
    let found = try await search.places(matching: "cafes", near: chicago)
    XCTAssertEqual(calls.all.map(\.span), [MapKitPlaceSearch.nearSpanMeters, MapKitPlaceSearch.wideSpanMeters])
    XCTAssertEqual(calls.all.map(\.center), [chicago, chicago])
    XCTAssertEqual(found.count, MapKitPlaceSearch.maximumResults)
    // Three near places are enough.
    let enough = LockedCalls()
    let near = MapKitPlaceSearch(run: { query, center, span in
      enough.append(query, center, span)
      return [testPlace(1), testPlace(2), testPlace(3)]
    })
    _ = try await near.places(matching: "cafes", near: chicago)
    XCTAssertEqual(enough.all.count, 1)
  }

  func testNoRegionForNamedArea() async throws {
    let calls = LockedCalls()
    let search = MapKitPlaceSearch(run: { query, center, span in
      calls.append(query, center, span)
      return [testPlace(1)]
    })
    let found = try await search.places(matching: "ramen in Soho, London", near: nil)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(calls.all.count, 1)
    XCTAssertEqual(calls.all.first?.query, "ramen in Soho, London")
    XCTAssertNil(calls.all.first?.center ?? nil)
    XCTAssertNil(calls.all.first?.span ?? nil)
  }

  func testPlaceDistanceIsComputedOnTheMac() {
    let meters = MapKitPlaceSearch.distance(from: chicago, to: SearchCoordinate(latitude: 41.89, longitude: -87.63))
    XCTAssertEqual(meters, 1_112, accuracy: 15)
  }

  func testPlaceCategoryReadsAsWords() {
    XCTAssertEqual(MapKitPlaceSearch.categoryName("MKPOICategoryCafe"), "Cafe")
    XCTAssertEqual(MapKitPlaceSearch.categoryName("MKPOICategoryGasStation"), "Gas Station")
  }

  /// The 3 s and 2 s limits (spec §6.4, §6.5), on a test clock with lookups that never answer.
  func testLookupsTimeOut() async throws {
    let client = FakeSearchHTTPClient()
    client.fallback = .hang
    let chicago = PlacesAndWeatherFixtures.chicago
    let weatherClock = ManualClock()
    let weather = Task { try await OpenMeteoWeather(client: client, clock: weatherClock).forecast(at: chicago, units: .metric) }
    await weatherClock.waitForSleepers(1)
    weatherClock.advance(by: OpenMeteoWeather.timeout)
    do { _ = try await weather.value; XCTFail("Expected a timeout") } catch {
      XCTAssertEqual(error as? WeatherLookupError, .timedOut)
    }
    let geocodeClock = ManualClock()
    let geocode = Task { try await OpenMeteoGeocoder(client: client, language: "en", clock: geocodeClock).locate("Paris") }
    await geocodeClock.waitForSleepers(1)
    geocodeClock.advance(by: OpenMeteoGeocoder.timeout)
    do { _ = try await geocode.value; XCTFail("Expected a timeout") } catch {
      XCTAssertEqual(error as? WeatherLookupError, .timedOut)
    }
    XCTAssertEqual(OpenMeteoWeather.timeout, .seconds(3))
    XCTAssertEqual(OpenMeteoGeocoder.timeout, .seconds(2))
    XCTAssertEqual(MapKitPlaceSearch.timeout, .seconds(3))
    let mapsClock = ManualClock()
    let maps = MapKitPlaceSearch(run: { _, _, _ in
      try await Task.sleep(for: .seconds(3_600))
      return []
    }, clock: mapsClock)
    let places = Task { try await maps.places(matching: "coffee", near: chicago) }
    await mapsClock.waitForSleepers(1)
    mapsClock.advance(by: MapKitPlaceSearch.timeout)
    do { _ = try await places.value; XCTFail("Expected a timeout") } catch {
      XCTAssertEqual(error as? PlaceSearchError, .timedOut)
    }
  }
}

/// A place for the tests.
func testPlace(_ index: Int, distance: Double? = nil) -> PlaceResult {
  PlaceResult(place: MapPlace(id: "id-\(index)", name: "Cafe \(index)",
                              coordinate: SearchCoordinate(latitude: 41.88, longitude: -87.63),
                              distanceMeters: distance),
              category: "Cafe", address: "\(index) Main St, Chicago", phone: "+1 312 555 01\(index)",
              website: URL(string: "https://cafe\(index).example"))
}

/// The run closure's calls, for tests.
final class LockedCalls: @unchecked Sendable {
  struct Call { let query: String; let center: SearchCoordinate?; let span: Double? }
  private let lock = NSLock()
  private var calls: [Call] = []
  var all: [Call] { lock.withLock { calls } }
  func append(_ query: String, _ center: SearchCoordinate?, _ span: Double?) {
    lock.withLock { calls.append(Call(query: query, center: center, span: span)) }
  }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
  let unwrapped = try await value()
  return try XCTUnwrap(unwrapped, file: file, line: line)
}

// MARK: Fakes shared with the provider, tool and view-model tests

enum PlacesAndWeatherFixtures {
  static let chicago = SearchCoordinate(latitude: 41.88, longitude: -87.63)
  static let paris = SearchCoordinate(latitude: 48.85, longitude: 2.35)
  static var forecast: WeatherForecast {
    try! JSONDecoder().decode(WeatherForecast.self, from: SearchFixture.data("open-meteo-chicago.json"))
  }
}

final class FakeWeather: WeatherLooking, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(coordinate: SearchCoordinate, units: MeasurementUnits)] = []
  let error: (any Error)?
  init(error: (any Error)? = nil) { self.error = error }
  var calls: [(coordinate: SearchCoordinate, units: MeasurementUnits)] { lock.withLock { recorded } }
  func forecast(at coordinate: SearchCoordinate, units: MeasurementUnits) async throws -> WeatherForecast {
    lock.withLock { recorded.append((coordinate, units)) }
    if let error { throw error }
    return PlacesAndWeatherFixtures.forecast
  }
}

final class FakeGeocoder: Geocoding, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  let answer: (coordinate: SearchCoordinate, name: String)?
  let error: (any Error)?
  init(_ answer: (coordinate: SearchCoordinate, name: String)? = nil, error: (any Error)? = nil) {
    self.answer = answer
    self.error = error
  }
  var calls: [String] { lock.withLock { recorded } }
  func locate(_ place: String) async throws -> (coordinate: SearchCoordinate, name: String)? {
    lock.withLock { recorded.append(place) }
    if let error { throw error }
    return answer
  }
}

final class FakePlaces: PlaceSearching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(query: String, coordinate: SearchCoordinate?)] = []
  let results: [PlaceResult]
  let error: (any Error)?
  init(_ results: [PlaceResult] = [], error: (any Error)? = nil) {
    self.results = results
    self.error = error
  }
  var calls: [(query: String, coordinate: SearchCoordinate?)] { lock.withLock { recorded } }
  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult] {
    lock.withLock { recorded.append((query, coordinate)) }
    if let error { throw error }
    return results
  }
}
