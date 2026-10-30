import XCTest
@testable import Enigma

/// `find_places` and `get_weather` for capable models (spec §6.2).
final class PlacesAndWeatherToolTests: XCTestCase {
  private let chicago = ApproximateLocation(latitude: 41.8781, longitude: -87.6298, area: "Chicago")

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTitles: [String] = []
    private var storedSources: [WebSearchSource] = []
    private var storedPlaces: [MapPlace] = []
    var titles: [String] { lock.withLock { storedTitles } }
    var sources: [WebSearchSource] { lock.withLock { storedSources } }
    var places: [MapPlace] { lock.withLock { storedPlaces } }
    func ask(_ title: String) { lock.withLock { storedTitles.append(title) } }
    func add(_ sources: [WebSearchSource]) { lock.withLock { storedSources += sources } }
    func add(_ places: [MapPlace]) { lock.withLock { storedPlaces += places } }
  }

  private func placeTool(_ places: FakePlaces, location: ApproximateLocation?, allows: Bool = true,
                         recorder: Recorder) -> PlaceSearchTool {
    PlaceSearchTool(places: places, location: { location }, units: { .metric },
                    mayQuery: { recorder.ask($0); return allows }, onSources: { recorder.add($0) },
                    onPlaces: { recorder.add($0) })
  }

  private func weatherTool(_ weather: FakeWeather, geocoder: FakeGeocoder = FakeGeocoder(),
                           location: ApproximateLocation?, allows: Bool = true, recorder: Recorder) -> WeatherTool {
    WeatherTool(weather: weather, geocoder: geocoder, location: { location }, units: { .us },
                mayQuery: { recorder.ask($0); return allows }, onSources: { recorder.add($0) },
                now: { Date(timeIntervalSince1970: 1_793_133_000) })
  }

  private func cafe(_ name: String, distance: Double? = nil) -> PlaceResult {
    PlaceResult(place: MapPlace(id: name, name: name, coordinate: PlacesAndWeatherFixtures.chicago, distanceMeters: distance),
                category: "Cafe", address: "1 Main St", phone: "+1 312 555 0100", website: URL(string: "https://cafe.example"))
  }

  private func json(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func testFindPlacesSchema() async throws {
    let tool = placeTool(FakePlaces(), location: chicago, recorder: Recorder())
    let definition = try XCTUnwrap(tool.definitions.first)
    XCTAssertEqual(tool.definitions.map(\.name), ["find_places"])
    XCTAssertEqual(definition.required, ["query"])
    XCTAssertEqual(Set(definition.properties.keys), ["query", "area"])
    XCTAssertEqual(tool.instructions, PlacesAndWeatherTools.instructions)
    let weather = weatherTool(FakeWeather(), location: chicago, recorder: Recorder())
    XCTAssertEqual(weather.definitions.map(\.name), ["get_weather"])
    XCTAssertEqual(weather.definitions.first?.required, [])
    XCTAssertEqual(weather.definitions.first.map { Set($0.properties.keys) }, ["place"])
    let invalid = await tool.execute(name: "find_places", arguments: .object(["area": .string("Soho")]))
    XCTAssertFalse(invalid.success)
  }

  func testFindPlacesNearUser() async throws {
    let places = FakePlaces([cafe("Blue Bottle", distance: 400)])
    let recorder = Recorder()
    let result = await placeTool(places, location: chicago, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("coffee")]))
    XCTAssertTrue(result.success)
    XCTAssertEqual(places.calls.map(\.query), ["coffee"])
    XCTAssertEqual(places.calls.map(\.coordinate), [SearchCoordinate(latitude: 41.88, longitude: -87.63)])
    let found = try XCTUnwrap(try json(result.text)["places"] as? [[String: Any]])
    XCTAssertEqual(found.first?["name"] as? String, "Blue Bottle")
    XCTAssertEqual(found.first?["distance"] as? String, "0.4 km")
    XCTAssertEqual(found.first?["website"] as? String, "https://cafe.example")
    XCTAssertEqual(recorder.titles, ["Find coffee near you?"])
    XCTAssertEqual(recorder.places.map(\.name), ["Blue Bottle"])
  }

  func testFindPlacesInArea() async throws {
    let places = FakePlaces([cafe("Ramen House")])
    let recorder = Recorder()
    let result = await placeTool(places, location: nil, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("ramen"), "area": .string("Soho, London")]))
    XCTAssertTrue(result.success)
    XCTAssertEqual(places.calls.map(\.query), ["ramen in Soho, London"])
    XCTAssertNil(places.calls.first?.coordinate ?? nil)
    XCTAssertNil((try json(result.text)["places"] as? [[String: Any]])?.first?["distance"])
    XCTAssertEqual(recorder.titles, ["Find ramen in Soho, London?"])
  }

  func testFindPlacesWithoutLocationAsksForArea() async {
    let places = FakePlaces([cafe("Blue Bottle")])
    let recorder = Recorder()
    let result = await placeTool(places, location: nil, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("coffee")]))
    XCTAssertEqual(result.text, "The user's location isn't available. Ask which city or area they mean.")
    XCTAssertFalse(result.terminal)
    XCTAssertTrue(places.calls.isEmpty, "No MapKit request")
    XCTAssertTrue(recorder.places.isEmpty, "No map card")
    XCTAssertTrue(recorder.sources.isEmpty)
    let empty = await placeTool(FakePlaces(), location: chicago, recorder: Recorder())
      .execute(name: "find_places", arguments: .object(["query": .string("coffee")]))
    XCTAssertEqual(empty.text, "No places found.")
  }

  func testGetWeatherNearUser() async throws {
    let weather = FakeWeather()
    let recorder = Recorder()
    let result = await weatherTool(weather, location: chicago, recorder: recorder)
      .execute(name: "get_weather", arguments: .object([:]))
    XCTAssertTrue(result.success)
    XCTAssertEqual(weather.calls.map(\.coordinate), [SearchCoordinate(latitude: 41.88, longitude: -87.63)])
    let forecast = try XCTUnwrap(try json(result.text)["forecast"] as? [String: Any])
    XCTAssertEqual(forecast["place"] as? String, "Chicago")
    XCTAssertEqual((forecast["next_24_hours"] as? [Any])?.count, 8)
    XCTAssertEqual((forecast["next_7_days"] as? [Any])?.count, 7)
    XCTAssertNotNil(forecast["now"] as? [String: Any])
    XCTAssertEqual(recorder.titles, ["Check the weather for your area?"])
    let unavailable = await weatherTool(FakeWeather(), location: nil, recorder: Recorder())
      .execute(name: "get_weather", arguments: .object([:]))
    XCTAssertEqual(unavailable.text, PlacesAndWeatherTools.locationUnavailable)
    let failed = await weatherTool(FakeWeather(error: WeatherLookupError.timedOut), location: chicago, recorder: Recorder())
      .execute(name: "get_weather", arguments: .object([:]))
    XCTAssertEqual(failed.text, "Open-Meteo didn't answer in time.")
  }

  func testGetWeatherUnknownPlace() async {
    let weather = FakeWeather()
    let recorder = Recorder()
    let result = await weatherTool(weather, geocoder: FakeGeocoder(), location: chicago, recorder: recorder)
      .execute(name: "get_weather", arguments: .object(["place": .string("Atlantis")]))
    XCTAssertEqual(result.text, "I couldn't find Atlantis.")
    XCTAssertTrue(weather.calls.isEmpty)
    XCTAssertEqual(recorder.titles, ["Check the weather for Atlantis?"])
    let paris = FakeGeocoder((PlacesAndWeatherFixtures.paris, "Paris, Île-de-France Region, France"))
    let found = await weatherTool(FakeWeather(), geocoder: paris, location: nil, recorder: Recorder())
      .execute(name: "get_weather", arguments: .object(["place": .string("Paris")]))
    XCTAssertTrue(found.text.contains("Paris, Île-de-France Region, France"))
  }

  func testSearchToolsAskFirstAfterMessageText() async {
    let places = FakePlaces([cafe("Blue Bottle")])
    let declined = await placeTool(places, location: chicago, allows: false, recorder: Recorder())
      .execute(name: "find_places", arguments: .object(["query": .string("coffee")]))
    XCTAssertEqual(declined.text, MessagesTools.declinedResult)
    XCTAssertTrue(places.calls.isEmpty)
    let weather = FakeWeather()
    let geocoder = FakeGeocoder((PlacesAndWeatherFixtures.paris, "Paris, France"))
    let refused = await weatherTool(weather, geocoder: geocoder, location: chicago, allows: false, recorder: Recorder())
      .execute(name: "get_weather", arguments: .object(["place": .string("Paris")]))
    XCTAssertEqual(refused.text, MessagesTools.declinedResult)
    XCTAssertTrue(geocoder.calls.isEmpty, "Nothing is sent before the card is answered")
    XCTAssertTrue(weather.calls.isEmpty)
    // The card's question and who gets it.
    let request = ToolPermissionRequest(permission: .lookUpAfterMessages(title: "Find coffee near you?", service: "Apple Maps"),
                                        destination: .thisMac, session: UUID())
    XCTAssertEqual(request.title, "Find coffee near you?")
    XCTAssertEqual(request.detail, "This chat includes text from your messages. It will be sent to Apple Maps.")
    // Remembered with gate 3's answer.
    XCTAssertEqual(ToolAlwaysGrant(.lookUpAfterMessages(title: "x", service: "Open-Meteo"), destination: .thisMac).key,
                   ToolAlwaysGrant(.searchAfterMessages(query: "y"), destination: .thisMac).key)
  }

  func testToolActivityText() {
    let places = placeTool(FakePlaces(), location: chicago, recorder: Recorder())
    let weather = weatherTool(FakeWeather(), location: chicago, recorder: Recorder())
    XCTAssertEqual(places.phase(for: "find_places").label, "Finding places…")
    XCTAssertEqual(weather.phase(for: "get_weather").label, "Checking the weather…")
    XCTAssertTrue(places.phase(for: "find_places").isSearching)
    XCTAssertTrue(weather.phase(for: "get_weather").isSearching)
  }

  func testToolSourcesCarryNoLocation() async {
    let recorder = Recorder()
    _ = await placeTool(FakePlaces([cafe("Blue Bottle", distance: 300)]), location: chicago, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("coffee"), "area": .string("Chicago")]))
    _ = await weatherTool(FakeWeather(), location: chicago, recorder: recorder)
      .execute(name: "get_weather", arguments: .object([:]))
    XCTAssertEqual(recorder.sources, [
      WebSearchSource(title: "Apple Maps", url: URL(string: "https://maps.apple.com/?q=coffee")!),
      WebSearchSource(title: "Open-Meteo forecast", url: URL(string: "https://open-meteo.com/")!),
    ])
    for source in recorder.sources {
      for secret in ["41.88", "87.63", "Chicago"] {
        XCTAssertFalse(source.title.contains(secret) || source.url.absoluteString.contains(secret), secret)
      }
    }
  }

  /// D87: near the user, the saved link never holds the city the model wrote into the query.
  func testFindPlacesSourceDropsTheCity() async {
    let recorder = Recorder()
    let austin = ApproximateLocation(latitude: 30.27, longitude: -97.74, area: "Austin, TX")
    _ = await placeTool(FakePlaces([cafe("Blue Bottle")]), location: austin, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("coffee in Austin")]))
    XCTAssertEqual(recorder.sources.map(\.url.absoluteString), ["https://maps.apple.com/?q=coffee"])
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "Austin", city: "Austin, TX").absoluteString, "https://maps.apple.com/")
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "cafes near 30.27", city: "Austin, TX").absoluteString,
                   "https://maps.apple.com/")
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "ramen", city: nil).absoluteString, "https://maps.apple.com/?q=ramen")
  }

  /// D89: the area's words come out too, and a city inside an unspaced query gives the bare link.
  func testFindPlacesSourceDropsTheAreaAndUnspacedCities() async {
    let recorder = Recorder()
    _ = await placeTool(FakePlaces([cafe("Franklin")]), location: nil, recorder: recorder)
      .execute(name: "find_places", arguments: .object(["query": .string("bbq in Austin"), "area": .string("Austin, TX")]))
    XCTAssertEqual(recorder.sources.map(\.url.absoluteString), ["https://maps.apple.com/?q=bbq"])
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "渋谷のラーメン", city: "渋谷区, 東京都").absoluteString,
                   "https://maps.apple.com/")
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "東京 ラーメン", city: "東京都").absoluteString, "https://maps.apple.com/")
    XCTAssertEqual(PlaceSearchTool.sourceURL(query: "ラーメン", city: "東京都").absoluteString,
                   "https://maps.apple.com/?q=%E3%83%A9%E3%83%BC%E3%83%A1%E3%83%B3")
  }
}
