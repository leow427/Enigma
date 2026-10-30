import Foundation

/// What `find_places` and `get_weather` share (spec §6.2).
enum PlacesAndWeatherTools {
  /// Added after `web_search`'s instructions.
  static let instructions = "Use find_places for shops, restaurants, services and other places to visit, and get_weather for current conditions and forecasts. Leave out the area or place to use the user's approximate location. Use web_search as well for reviews, opening hours and anything else the places list doesn't say."
  static let locationUnavailable = "The user's location isn't available. Ask which city or area they mean."
  static let noPlaces = "No places found."
  static let stopped = AgentToolResult(text: "The request was stopped.", success: false, terminal: true, stop: .cancelled)

  /// JSON with sorted keys, as every tool result.
  static func json(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  /// An optional text argument: `.some(nil)` when absent or blank, nil when it isn't a string.
  static func optionalText(_ value: CodexValue?) -> String?? {
    guard let value else { return .some(nil) }
    guard let text = value.string else { return nil }
    let line = ToolPermissionRequest.oneLine(text)
    return .some(line.isEmpty ? nil : line)
  }
}

/// `find_places(query, area?)` for capable models (spec §6.2): Apple Maps near the user's rounded
/// location, or in a named area. The card asks first in a chat that holds message text (gate 3).
struct PlaceSearchTool: AgentToolbox {
  private let places: any PlaceSearching
  private let location: @Sendable () async -> ApproximateLocation?
  private let units: @Sendable () -> MeasurementUnits
  private let mayQuery: @Sendable (String) async -> Bool
  private let onSources: @Sendable ([WebSearchSource]) async -> Void
  private let onPlaces: @Sendable ([MapPlace]) async -> Void

  init(places: any PlaceSearching, location: @escaping @Sendable () async -> ApproximateLocation?,
       units: @escaping @Sendable () -> MeasurementUnits, mayQuery: @escaping @Sendable (String) async -> Bool,
       onSources: @escaping @Sendable ([WebSearchSource]) async -> Void,
       onPlaces: @escaping @Sendable ([MapPlace]) async -> Void) {
    self.places = places
    self.location = location
    self.units = units
    self.mayQuery = mayQuery
    self.onSources = onSources
    self.onPlaces = onPlaces
  }

  var instructions: String { PlacesAndWeatherTools.instructions }

  var definitions: [AgentToolDefinition] {
    [AgentToolDefinition(name: "find_places",
      description: "Find places with Apple Maps. Returns up to 10 places with their name, category, address, distance, phone and website.",
      properties: [
        "query": .object(["type": .string("string"),
          "description": .string("What to find, without the area, such as \"ramen\".")]),
        "area": .object(["type": .string("string"),
          "description": .string("A named area, such as \"Soho, London\". Leave it out to search near the user.")]),
      ],
      required: ["query"])]
  }

  func phase(for _: String) -> AssistantActivity.Phase { .findingPlaces }

  private struct Found: Encodable {
    let name: String
    let category: String?
    let address: String?
    let distance: String?
    let phone: String?
    let website: String?
  }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    guard name == "find_places", case .object(let fields) = arguments,
          fields.keys.allSatisfy({ $0 == "query" || $0 == "area" }), let raw = fields["query"]?.string,
          case .some(let area) = PlacesAndWeatherTools.optionalText(fields["area"]) else {
      return Self.invalidArguments
    }
    let query = ToolPermissionRequest.oneLine(raw)
    guard !query.isEmpty else { return Self.invalidArguments }
    // Near the user: the rounded location, or ask the model to ask which area. Nothing is sent.
    var near: ApproximateLocation?
    if area == nil {
      near = await location()
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      guard near != nil else { return AgentToolResult(text: PlacesAndWeatherTools.locationUnavailable, success: false) }
    }
    let title = area.map { "Find \(query) in \($0)?" } ?? "Find \(query) near you?"
    guard await mayQuery(title) else {
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      return AgentToolResult(text: MessagesTools.declinedResult, success: false)
    }
    let found: [PlaceResult]
    do {
      found = try await places.places(matching: area.map { "\(query) in \($0)" } ?? query, near: near?.coordinate)
      try Task.checkCancellation()
    } catch is CancellationError {
      return PlacesAndWeatherTools.stopped
    } catch {
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      return AgentToolResult(text: (error as? PlaceSearchError)?.localizedDescription ?? PlacesAndWeatherTools.noPlaces,
                             success: false)
    }
    guard !found.isEmpty else { return AgentToolResult(text: PlacesAndWeatherTools.noPlaces, success: false) }
    let listed = Array(found.prefix(MapKitPlaceSearch.maximumResults))
    // The saved source names the query only: never the area, which a model could fill with the
    // user's city, nor coordinates.
    await onSources([WebSearchSource(title: PlaceSearch.sourceTitle, url: Self.sourceURL(query: query, city: near?.searchCity ?? area))])
    await onPlaces(listed.map(\.place))
    let unitSystem = units()
    let items = listed.map { result in
      Found(name: result.place.name, category: result.category, address: result.address,
            distance: result.place.distanceMeters.map { PlaceSearch.distance($0, units: unitSystem) },
            phone: result.phone, website: result.website?.absoluteString)
    }
    return AgentToolResult(text: PlacesAndWeatherTools.json(["places": items]), success: true)
  }

  /// The saved link: the query without the user's city or the named area (D87–D89). Their words
  /// and a dangling in/near/at come out; if nothing is left, a number survives, or a city word still
  /// appears anywhere inside the query (Japanese or Chinese without spaces), the link is bare Apple Maps.
  static func sourceURL(query: String, city: String?) -> URL {
    guard let city else { return PlaceSearch.sourceURL(query: query) }
    let bare = URL(string: "https://maps.apple.com/")!
    let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    let cityWords = Set(fold(city).components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    var words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
      !cityWords.contains(fold(word).trimmingCharacters(in: CharacterSet.letters.inverted))
    }
    while let last = words.last, ["in", "near", "at", "around"].contains(fold(last)) { words.removeLast() }
    let cleaned = words.joined(separator: " ")
    guard !cleaned.isEmpty, cleaned.rangeOfCharacter(from: .decimalDigits) == nil else { return bare }
    let folded = fold(cleaned)
    let foldedWords = Set(folded.components(separatedBy: CharacterSet.letters.inverted))
    for word in cityWords {
      if foldedWords.contains(word) { return bare }
      // Inside a longer word: scripts written without spaces, and "渋谷区" as "渋谷". Latin words of
      // one or two letters ("tx") only count as whole words.
      let ascii = word.unicodeScalars.allSatisfy(\.isASCII)
      for stem in [word] + (ascii ? [] : [Self.withoutAdministrativeSuffix(word)]) where stem.count >= (ascii ? 3 : 2) {
        if folded.contains(stem) { return bare }
      }
    }
    return PlaceSearch.sourceURL(query: cleaned)
  }

  /// "渋谷区" → "渋谷", "東京都" → "東京": the ward, city or prefecture ending dropped.
  private static func withoutAdministrativeSuffix(_ word: String) -> String {
    guard word.count > 2, let last = word.last, "区市都府県道町村省县".contains(last) else { return word }
    return String(word.dropLast())
  }

  private static let invalidArguments = AgentToolResult(
    text: "Invalid tool arguments: call find_places with {\"query\": string, \"area\"?: string}.", success: false)
}

/// `get_weather(place?)` for capable models (spec §6.2): Open-Meteo for the user's rounded location
/// or a place Open-Meteo geocodes. The card asks first in a chat that holds message text (gate 3).
struct WeatherTool: AgentToolbox {
  private let weather: any WeatherLooking
  private let geocoder: any Geocoding
  private let location: @Sendable () async -> ApproximateLocation?
  private let units: @Sendable () -> MeasurementUnits
  private let mayQuery: @Sendable (String) async -> Bool
  private let onSources: @Sendable ([WebSearchSource]) async -> Void
  private let now: @Sendable () -> Date

  init(weather: any WeatherLooking, geocoder: any Geocoding, location: @escaping @Sendable () async -> ApproximateLocation?,
       units: @escaping @Sendable () -> MeasurementUnits, mayQuery: @escaping @Sendable (String) async -> Bool,
       onSources: @escaping @Sendable ([WebSearchSource]) async -> Void,
       now: @escaping @Sendable () -> Date = Date.init) {
    self.weather = weather
    self.geocoder = geocoder
    self.location = location
    self.units = units
    self.mayQuery = mayQuery
    self.onSources = onSources
    self.now = now
  }

  /// `find_places` carries the shared instructions.
  var instructions: String { "" }

  var definitions: [AgentToolDefinition] {
    [AgentToolDefinition(name: "get_weather",
      description: "Get the current weather, the next 24 hours and the next 7 days from Open-Meteo.",
      properties: ["place": .object(["type": .string("string"),
        "description": .string("A named place, such as \"Paris\". Leave it out for the user's location.")])],
      required: [])]
  }

  func phase(for _: String) -> AssistantActivity.Phase { .checkingWeather }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    guard name == "get_weather", case .object(let fields) = arguments, fields.keys.allSatisfy({ $0 == "place" }),
          case .some(let place) = PlacesAndWeatherTools.optionalText(fields["place"]) else {
      return Self.invalidArguments
    }
    var near: ApproximateLocation?
    if place == nil {
      near = await location()
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      guard near != nil else { return AgentToolResult(text: PlacesAndWeatherTools.locationUnavailable, success: false) }
    }
    guard await mayQuery("Check the weather for \(place ?? "your area")?") else {
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      return AgentToolResult(text: MessagesTools.declinedResult, success: false)
    }
    do {
      let coordinate: SearchCoordinate
      let placeName: String
      if let near {
        coordinate = near.coordinate
        placeName = near.searchCity ?? "your area"
      } else if let place, let found = try await geocoder.locate(place) {
        coordinate = found.coordinate
        placeName = found.name
      } else {
        return AgentToolResult(text: "I couldn't find \(place ?? "that place").", success: false)
      }
      let forecast = try await weather.forecast(at: coordinate, units: units())
      try Task.checkCancellation()
      await onSources([WeatherLookup.source])
      let report = WeatherLookup.report(forecast, placeName: placeName, now: now())
      return AgentToolResult(text: PlacesAndWeatherTools.json(["forecast": report]), success: true)
    } catch is CancellationError {
      return PlacesAndWeatherTools.stopped
    } catch {
      if Task.isCancelled { return PlacesAndWeatherTools.stopped }
      return AgentToolResult(text: error.localizedDescription, success: false)
    }
  }

  private static let invalidArguments = AgentToolResult(
    text: "Invalid tool arguments: call get_weather with {\"place\"?: string}.", success: false)
}
