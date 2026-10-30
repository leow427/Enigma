import Combine
@preconcurrency import CoreLocation
import Foundation
import MapKit

/// Only the current question can request location, never quoted or attached content.
enum LocationIntent {
  static func needsLocation(_ prompt: String) -> Bool {
    needsLocation(normalized: WebSearchPolicy.questionText(prompt))
  }

  /// `needsLocation` for text already normalized by `WebSearchPolicy.questionText`.
  static func needsLocation(normalized text: String) -> Bool {
    guard !WebSearchPolicy.isOfflineOrTransformation(text),
          !matches(optOutLocation, text) else { return false }
    if matches(namedPlace, text) || cityBeforeWeather(text) != nil { return false }
    if matches(nearbyCue, text) || hasLocalPlaceCue(text) { return true }
    guard asksAboutWeather(text) else { return false }
    // Named destinations take precedence over the device's location.
    if matches(namedDestination, text) { return false }
    // "what's the forecast for home prices": in a forecast-only question a time or home word counts only on its own.
    if !matches(weatherWord, text) && !matches(bareWeatherTopic, text) && matches(forecastDestination, text) { return false }
    return !matches(conceptualWeather, text)
  }

  /// "near me", "nearby", "around me", "in my area", "locally", or "local" before a place word.
  static func hasNearbyCue(normalized text: String) -> Bool {
    matches(SearchRouting.nearbyPhrase, text) || hasLocalPlaceCue(text)
  }

  /// "local <place word>", except an ambiguous word in a how-to or developer question:
  /// "how do i import a local library" and "best local library for python" stay on the Mac.
  static func hasLocalPlaceCue(_ text: String) -> Bool {
    // "how to open a local bakery" is about running a business, not finding one.
    if matches(businessHowTo, text) { return false }
    if matches(SearchRouting.localUnambiguousPlace, text) { return true }
    return matches(SearchRouting.localAmbiguousPlace, text) && !isDeveloperQuestion(text)
  }

  /// A question about weather software ("weather api for python", "best weather app"), not the weather.
  static func isAboutWeatherSoftware(_ text: String) -> Bool {
    isDeveloperQuestion(text) || matches(softwareWords, text)
  }

  /// A how-to question, or one with a developer word: "pip install", "import", "python".
  static func isDeveloperQuestion(_ text: String) -> Bool {
    matches(SearchRouting.howTo, text) || matches(developerWords, text)
  }

  /// A weather question about now, the coming days or right here, not about climate, records or the news.
  static func asksAboutWeatherNow(normalized text: String) -> Bool {
    guard !WebSearchPolicy.isOfflineOrTransformation(text), asksAboutWeather(text),
          !matches(conceptualWeather, text), !matches(weatherBackground, text) else { return false }
    return true
  }

  /// "weather" or "forecast" with a now word or a nearby cue; a bare topic word ("rain jackets",
  /// "temperature to bake salmon") only with a time word, a weather verb or "do i need", or
  /// "temperature in <named place>" (D12).
  private static func asksAboutWeather(_ text: String) -> Bool {
    // "forecast" alone is a weather word only after a topic word or leading the question: "sales
    // forecast" and "how to forecast demand" aren't about the weather (D24).
    if matches(weatherWord, text) || matches(forecastAsWeather, text) {
      if matches(asksAboutNow, text) || matches(forecastAfterTopic, text) || matches(shortForecastQuestion, text)
        || cityBeforeWeather(text) != nil { return true }
      // "weather near me", "local weather". Snow and umbrellas near me are places, not forecasts.
      if matches(nearbyCue, text) { return true }
      // A forecast for a named place can be days away: "weather in Paris this weekend".
      return matches(comingDays, text) && weatherPlace(normalized: text) != nil
    }
    guard matches(bareWeatherTopic, text) else { return false }
    if matches(bareWeatherTiming, text) || matches(temperatureNow, text) || matches(bareTopicNow, text) { return true }
    // "rain in seattle this weekend": these times count anywhere only with a place, so "my baby's
    // temperature is 101 right now" isn't a weather question (D24).
    if matches(placedTime, text) && weatherPlace(normalized: text) != nil { return true }
    return matches(temperatureInPlace, text) && weatherPlace(normalized: text) != nil
  }

  /// "paris" in "weather in paris this weekend": the words after in, at, for or near, up to the next of
  /// those or a time word. Candidates are tried in order and the first that isn't a time, home, work,
  /// school or a language wins, so "will it rain in the afternoon in london" finds "london".
  /// Each candidate ends at the next preposition and the search stops at the first place, so long
  /// drafts stay linear.
  static func weatherPlace(normalized text: String) -> String? {
    if let city = cityBeforeWeather(text) { return city }
    var found: String?
    weatherPlacePattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
      guard let match, let range = Range(match.range(at: 1), in: text) else { return }
      let place = text[range].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
      guard !place.isEmpty, place != "the", !matches(timePhrase, place), !matches(notAPlace, place) else { return }
      found = place
      stop.pointee = true
    }
    return found
  }

  /// "nyc" in "nyc weather today" (D18): up to three words before "weather" and only time words
  /// after it. Never "local", "my", "current", an adjective, a time, a language or a developer word.
  static func cityBeforeWeather(_ text: String) -> String? {
    guard let match = cityWeatherPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    var words = text[range].split(separator: " ").map(String.init)
    // A descriptive first word describes the weather ("hourly weather", "beach weather"); later, a place
    // name can hold one ("bay area", "long beach").
    guard let first = words.first, !descriptiveWeatherWord.contains(first) else { return nil }
    for word in words {
      if functionWord.contains(word) || matches(timePhrase, word) || matches(developerWords, word)
        || matches(notAPlace, word) { return nil }
    }
    // "boston hourly weather": a trailing modifier isn't part of the city.
    while words.count > 1, let last = words.last, weatherModifier.contains(last) { words.removeLast() }
    return words.joined(separator: " ")
  }

  static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  // Compiled once. All patterns are fixed, tested source literals, never user-provided regexes.
  private static let cityWeatherPattern = try! NSRegularExpression(pattern: #"^([a-z][a-z'.-]*(?: [a-z][a-z'.-]*){0,2}) weather(?: (?:today|tonight|tomorrow|this week|this weekend|right now|now|forecast))*[?.!]*$"#)
  /// Words that never belong to a city before "weather", wherever they are ("hows the weather").
  private static let functionWord: Set<String> = ["my", "our", "your", "the", "a", "an", "what", "what's", "whats",
    "how", "how's", "hows", "is", "are", "any", "check", "show", "get", "give", "tell", "me", "this", "next", "now",
    "here", "there", "see", "today", "tomorrow", "tonight", "today's", "tomorrow's", "tonight's", "todays", "tomorrows",
    "tonights"]
  /// Words that describe the weather: never the city's first word ("hourly weather today", "beach weather"),
  /// but a later word can be part of a place ("bay area", "long beach") (D22).
  private static let descriptiveWeatherWord: Set<String> = ["local", "current", "outside", "live", "real", "time",
    "bad", "good", "nice", "great", "cold", "hot", "warm", "cool", "wet", "dry", "rainy", "snowy", "sunny", "cloudy",
    "windy", "stormy", "severe", "extreme", "mild", "fair", "crazy", "weird", "summer", "winter", "spring", "fall",
    "autumn", "marine", "aviation", "ski", "beach", "sweater", "golf", "fishing", "space", "hurricane", "storm",
    "flying", "driving", "travel", "nearby", "hourly", "area", "regional", "outdoor", "real-time", "hiking",
    "running", "picnic", "humid", "foggy", "chilly", "perfect", "beautiful", "daily", "weekly",
    // Found by the regression probe (D23).
    "awful", "lovely", "terrible", "horrible", "pleasant", "gloomy", "dreary", "muggy", "icy", "hazy", "smoky",
    "freezing", "frigid", "wild", "snow", "rain", "tornado", "fire", "flood", "camping", "biking", "cycling",
    "boating", "sailing", "surfing", "football", "baseball", "soccer", "bbq", "barbecue", "world", "national",
    "global", "international", "realtime", "weather"]
  /// Descriptive words dropped from the end of a city: "boston hourly weather" is "boston".
  private static let weatherModifier: Set<String> = ["local", "current", "live", "hourly", "daily", "weekly",
    "regional", "real-time", "outdoor"]
  /// Words that end a weather place, and a holiday or time of day that is also a place name.
  private static let stopWords = #"(?:today|tonight|tomorrow|this|next|on|in|at|for|near|and|or|with|will|is|right now|now|later)"#
  /// Holidays and times of day that are also place names ("easter island", "sunrise florida"): a time
  /// only on their own, or with "eve" or "day", before the end, punctuation or a stop word.
  private static let placeLikeTimes = #"(?:easter|christmas|sunrise|sunset|dinner)(?: eve| day)?(?=\s*$|\s*[.,!?;:]|\s+\#(stopWords)\b)"#
  /// Times that mean today here, and home, work and school: never a named place, so they leave the
  /// current location in use ("rain at noon", "weather at home", "rain in the afternoon", D7, D11).
  /// Months, weekdays and "the weekend" still count as a destination there, so seasonal questions stay
  /// on the web (owner decision 2 of 2026-10-27).
  private static let nearTime = #"(?:\#(placeLikeTimes)|(?:the |this )?(?:morning|afternoon|evening|night)|the moment|noon|midnight|breakfast|lunch|lunchtime|dawn|dusk|thanksgiving|new year(?:'s)?(?: eve| day)?|halloween|home|work|school)"#
  private static let times = #"(?:morning|afternoon|evening|night|weekend|week|month|year|hours?|minutes?|days?|january|february|march|april|may|june|july|august|september|october|november|december|monday|tuesday|wednesday|thursday|friday|saturday|sunday|noon|midnight|breakfast|lunch|lunchtime|dawn|dusk|thanksgiving|new year(?:'s)?|halloween)"#
  /// Language names: "restaurant in spanish" and "weather in spanish" aren't about a place.
  static let languages = #"(?:english|spanish|french|german|italian|portuguese|chinese|mandarin|cantonese|japanese|korean|arabic|russian|hindi|dutch|swedish|norwegian|danish|finnish|polish|turkish|greek|hebrew|latin|vietnamese|thai|indonesian|ukrainian|czech|hungarian|romanian|irish|welsh|swahili|tagalog|persian|farsi|urdu|bengali|punjabi|sign language)"#
  private static let softwareWords = try! NSRegularExpression(pattern: #"\b(?:apps?|widgets?)\b"#)
  private static let businessHowTo = try! NSRegularExpression(pattern: #"^how (?:to|do i|do you|can i) (?:open|start|run|own|market)\b"#)
  private static let developerWords = try! NSRegularExpression(pattern: #"\b(?:import|imports|install|installing|installed|link|linking|linker|package|packages|module|modules|dependency|dependencies|pip|npm|yarn|pnpm|cargo|cmake|gradle|maven|cocoapods|spm|python|swift|swiftui|java|javascript|typescript|node|rust|golang|ruby|php|cpp|xcode|compile|compiler|framework|sdk|api|code|repo|git|github|docker|project|elixir|kotlin|haskell|scala|dart|flutter|react|vue|angular|django|rails|laravel|dotnet|csharp|unity)\b"#)
  private static let optOutLocation = try! NSRegularExpression(pattern: #"\b(?:(?:do not|don't|dont|never) (?:use|access|share|detect) (?:my |the )?location|without (?:my )?location)\b"#)
  static let namedPlace = try! NSRegularExpression(pattern: #"\b(?:in|at|near)\s+(?!(?:me|my|this|the|here|\#(nearTime))\b)[a-z]"#)
  private static let nearbyCue = try! NSRegularExpression(pattern: #"\b(?:near me|around me|nearby|my (?:current )?location|where am i|in my area|locally|local (?:weather|events|places))\b"#)
  /// A destination after in/at/for/near where a time, home, work or school word must stand alone (D29).
  private static let forecastDestination = try! NSRegularExpression(pattern: #"\b(?:in|at|for|near)\s+(?!(?:today|tonight|tomorrow|this|the next|(?:\#(nearTime))(?=\s*$|\s*[.,!?;:]|\s+\#(stopWords)\b))\b)[a-z]"#)
  private static let weatherWord = try! NSRegularExpression(pattern: #"\bweather\b"#)
  private static let forecastPrefix = #"(?:local |\d+[- ]?day |hourly |daily |weekly |extended |weekend )?"#
  /// "forecast" as a weather word: after a topic word, or leading the question ("what's the forecast for
  /// new york tomorrow", "10 day forecast").
  private static let forecastAsWeather = try! NSRegularExpression(pattern: #"\b(?:weather|rain|snow|temperature|local|(?:today|tonight|tomorrow)(?:'s|s)?|this week(?:end)?'s) forecast\b|^(?:what's |what is |how's |how is |check |show me |get )?(?:the )?\#(forecastPrefix)forecast\b"#)
  /// "weather forecast", "rain forecast", "local forecast", "tomorrow's forecast": a now word, like "today".
  /// "local forecast" is no nearby cue, so "local forecast for boston" names Boston (D27).
  private static let forecastAfterTopic = try! NSRegularExpression(pattern: #"\b(?:weather|rain|snow|temperature|local|(?:today|tonight|tomorrow)(?:'s|s)?|this week(?:end)?'s) forecast\b"#)
  /// "forecast", "the forecast", "10 day forecast", "hourly forecast tomorrow" as the whole question.
  private static let shortForecastQuestion = try! NSRegularExpression(pattern: #"^(?:what's |what is |how's |how is |check |show me |get )?(?:the )?\#(forecastPrefix)forecast(?: (?:for )?(?:today|tonight|tomorrow|this week|this weekend))*(?: looking)?[?.!]*$"#)
  /// A bare topic word with "this weekend", "right now" or a part of the day, as the whole question (D24).
  private static let bareTopicNow = try! NSRegularExpression(pattern: #"^(?:(?:what's|what is|any|is there|will there be|how much) )?(?:the )?(?:rain|snow|temperature|umbrella) (?:this weekend|right now|this (?:morning|afternoon|evening))[?.!]*$"#)
  private static let placedTime = try! NSRegularExpression(pattern: #"\b(?:this weekend|right now|this (?:morning|afternoon|evening))\b"#)
  private static let bareWeatherTopic = try! NSRegularExpression(pattern: #"\b(?:temperature|rain|raining|snow|snowing|umbrella)\b"#)
  /// A time word, a weather verb ("will it rain", "is it gonna snow", "chance of rain"), "do i need",
  /// "outside" next to the topic word, or "temperature near me" (D15). "Outside" alone isn't enough:
  /// "too cold to sleep outside" isn't a forecast question.
  private static let bareWeatherTiming = try! NSRegularExpression(pattern: #"\b(?:today|tonight|tomorrow|this week|do i need|(?:raining|snowing) outside|temperature (?:near me|around me|in my area|nearby)|(?:will|is) it (?:going to |gonna |supposed to |expected to )?(?:be )?(?:rain|raining|snow|snowing)|chances? of (?:rain|snow))\b"#)
  /// The whole question asks for the temperature here and now: "what's the current temperature", "what
  /// temperature is it now", "what's the outside temperature". A phrase inside a longer question ("my cpu's
  /// current temperature") never counts (D20).
  private static let temperatureNow = try! NSRegularExpression(pattern: #"^(?:(?:what's|what is|how's|is) )?(?:the )?(?:current outside temperature|current temperature|temperature (?:right now|now|at the moment)|temperature like|temperature (?:is it )?outside|outside temperature)(?: (?:here|outside|now|right now|today|at the moment))*[?.!]*$|^what temperature is it(?: (?:right now|now|outside))*[?.!]*$"#)
  /// "what's the temperature in denver", not "in fahrenheit", "in the oven", "in python" or "in your
  /// bedroom", and only when the question starts with it: "normal body temperature in adults" isn't (D12, D15).
  private static let temperatureInPlace = try! NSRegularExpression(pattern: #"^(?:what's |what is |what )?(?:the )?(?:current )?temperature (?:is it )?(?:(?:like|now|right now|outside) )*(?:in|at|near) (?!(?:the|which|what|whom|who|your|my|our|their|his|her|its|this|that|these|those|me|us|them|a|an|fahrenheit|celsius|centigrade|kelvin|degrees?|f|c|k|python|swift|java|javascript|excel|space|mars|the moon|moon|sun|venus|jupiter|refrigerator|fridge|freezer|oven|room|house|car|pool|body|water|\#(languages))\b)[a-z]"#)
  private static let namedDestination = try! NSRegularExpression(pattern: #"\b(?:in|at|for|near)\s+(?!(?:today|tonight|tomorrow|this|the next|\#(nearTime))\b)[a-z]"#)
  /// "what is weather", "define rain", "how does the weather work"; not "what's the weather", which asks
  /// about here and now (D18).
  private static let conceptualWeather = try! NSRegularExpression(pattern: #"^(?:(?:what is|what's) (?:a )?(?:weather|rain|snow|temperature)|(?:define|explain) (?:the |a )?(?:weather|rain|snow|temperature)|(?:what is|what's|how does) (?:the |a )?(?:weather|rain|snow|temperature) (?:work|mean))[?.!]*$"#)
  private static let asksAboutNow = try! NSRegularExpression(pattern: #"\b(?:today|tonight|tomorrow|todays|tonights|tomorrows|this week|will it|is it|what's|what is|what are|do i need)\b"#)
  /// Background words, and a month or season after in/during ("paris in may", "rome in the summer"): a
  /// seasonal question is better answered by the web than by a 7-day forecast (D18).
  private static let weatherBackground = try! NSRegularExpression(pattern: #"\b(?:news|latest|record|average|historical|history|climate|(?:in|during) (?:the )?(?:early |late |mid-?)?(?:january|february|march|april|may|june|july|august|september|october|november|december|spring|summer|fall|autumn|winter))\b"#)
  private static let comingDays = try! NSRegularExpression(pattern: #"\b(?:this weekend|next week)\b"#)
  // Starts with a letter, like `namedDestination`, so the two agree on what a place is. The candidate is
  // captured inside a lookahead so every in, at, for or near is tried, and it ends at the next one.
  /// /maps (spec §6.3): the first area after in/at/near that isn't a time, home, work or school.
  static func mapsArea(normalized text: String) -> String? {
    var found: String?
    mapsAreaPattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
      guard let match, let range = Range(match.range(at: 1), in: text) else { return }
      let place = text[range].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
      guard !place.isEmpty, place != "the", !matches(timePhrase, place), !matches(notAPlace, place) else { return }
      found = place
      stop.pointee = true
    }
    return found
  }

  private static let mapsAreaPattern = try! NSRegularExpression(pattern: #"\b(?:in|at|near)\s+(?=(?!(?:me|my|this|here|today|tonight|tomorrow|next|on|a|an)\b)([a-z](?:(?!\s+(?:today|tonight|tomorrow|this|next|on|in|at|for|near|right now|now|later)\b).)*))"#)
  private static let weatherPlacePattern = try! NSRegularExpression(pattern: #"\b(?:in|at|for|near)\s+(?=(?!(?:me|my|this|here|today|tonight|tomorrow|next|on|a|an)\b)([a-z](?:(?!\s+(?:today|tonight|tomorrow|this|next|on|in|at|for|near|right now|now|later)\b).)*))"#)
  private static let timePhrase = try! NSRegularExpression(pattern: #"^(?:the )?(?:\#(times)\b|\#(placeLikeTimes))"#)
  /// A language only as the whole candidate: "spanish" isn't a place, "dutch harbor" and "latin america" are.
  private static let notAPlace = try! NSRegularExpression(pattern: #"^(?:home|work|school)\b|^\#(languages)$"#)
}

struct ApproximateLocation: Equatable, Sendable {
  /// The area when reverse geocoding found no city.
  static let unknownArea = "current area"
  let area: String
  let coordinates: String
  /// Rounded to 2 decimals, about 1 km.
  let latitude: Double
  let longitude: Double
  var coordinate: SearchCoordinate { SearchCoordinate(latitude: latitude, longitude: longitude) }
  /// The geocoded parts a provider's search may get (F30), when the geocoder gave them.
  var city: String?
  var region: String?
  /// ISO 3166-1 alpha-2.
  var countryCode: String?
  /// What search sites get for "near me" (F29): the area with its context, such as "Austin, TX", since they
  /// never get coordinates. Nil when reverse geocoding found nothing.
  var searchCity: String? { area == Self.unknownArea ? nil : area }
  var searchContext: String { "Approximate current location: \(area) (\(coordinates))" }

  /// What a provider's own web search gets once the user allows it (spec §2a): the area and this
  /// Mac's time zone. Coordinates stay on the Mac.
  var providerSearchLocation: ProviderSearchLocation {
    ProviderSearchLocation(city: city, region: region, countryCode: countryCode, timeZone: TimeZone.current.identifier)
  }

  init(latitude: Double, longitude: Double, area: String = ApproximateLocation.unknownArea,
       city: String? = nil, region: String? = nil, countryCode: String? = nil) {
    self.area = area
    let latitude = (latitude * 100).rounded() / 100
    let longitude = (longitude * 100).rounded() / 100
    self.latitude = latitude
    self.longitude = longitude
    coordinates = String(format: "%.2f, %.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    self.city = city
    self.region = region
    self.countryCode = countryCode
  }
}

enum LocationError: LocalizedError {
  case unavailable
  var errorDescription: String? {
    "Your location is unavailable. Include a city or area in your question, or enable location access in Settings."
  }
}

@MainActor
protocol LocationProviding: AnyObject {
  func currentLocation() async throws -> ApproximateLocation
}

/// A bounded, cancellable one-shot request. The service does not persist location.
@MainActor
final class LocationService: NSObject, ObservableObject, @MainActor CLLocationManagerDelegate, LocationProviding {
  static let shared = LocationService()
  @Published var isEnabled: Bool {
    didSet {
      defaults.set(isEnabled, forKey: "location.enabled")
      if !isEnabled { finish(.failure(LocationError.unavailable)) }
    }
  }
  @Published private(set) var status = "Location is requested only for nearby questions."
  /// Location Services in System Settings, where access is allowed or denied.
  static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
  private let defaults: UserDefaults
  private var manager: CLLocationManager?
  private var geocoder: MKReverseGeocodingRequest?
  private var continuation: CheckedContinuation<ApproximateLocation, Error>?
  private var requestID: UUID?
  private var timeout: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: "location.enabled") as? Bool ?? true
    super.init()
  }

  func currentLocation() async throws -> ApproximateLocation {
    try Task.checkCancellation()
    guard isEnabled, continuation == nil else { throw LocationError.unavailable }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        requestID = id
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        status = "Finding your approximate location…"
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(20)) } catch { return }
          guard self?.requestID == id else { return }
          self?.finish(.failure(LocationError.unavailable))
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(.failure(LocationError.unavailable))
        default:
          // macOS presents its permission prompt when location is first requested.
          manager.requestLocation()
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.requestID == id else { return }
        self?.finish(.failure(CancellationError()))
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard self.manager === manager else { return }
    if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      finish(.failure(LocationError.unavailable))
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard self.manager === manager, geocoder == nil,
          let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 300 }) else { return }
    manager.stopUpdatingLocation()
    // Round before reverse geocoding or sharing with search/model providers.
    let latitude = (location.coordinate.latitude * 100).rounded() / 100
    let longitude = (location.coordinate.longitude * 100).rounded() / 100
    let fallback = ApproximateLocation(latitude: latitude, longitude: longitude)
    guard let geocoder = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
      finish(.success(fallback))
      return
    }
    self.geocoder = geocoder
    geocoder.getMapItems { [weak self, weak manager] items, _ in
      guard let self, let manager, self.manager === manager else { return }
      let address = items?.first?.addressRepresentations
      let area = address?.cityWithContext ?? ""
      self.finish(.success(area.isEmpty ? fallback : ApproximateLocation(latitude: latitude, longitude: longitude, area: area,
        city: address?.cityName, region: Self.region(cityWithContext: area, city: address?.cityName, country: address?.regionName),
        countryCode: address?.region?.identifier)))
    }
  }

  /// The state or province in "Cupertino, CA": what follows the city, unless it's the country.
  nonisolated static func region(cityWithContext: String, city: String?, country: String?) -> String? {
    guard let city, cityWithContext.hasPrefix(city + ", ") else { return nil }
    let rest = cityWithContext.dropFirst(city.count + 2).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty || rest == country ? nil : rest
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard self.manager === manager else { return }
    finish(.failure(LocationError.unavailable))
  }

  private func finish(_ result: Result<ApproximateLocation, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    requestID = nil
    timeout?.cancel()
    timeout = nil
    manager?.stopUpdatingLocation()
    manager?.delegate = nil
    manager = nil
    geocoder?.cancel()
    geocoder = nil
    switch result {
    case .success: status = "Location was used for your last nearby question."
    case .failure(let error): status = error is CancellationError ? "Location request cancelled." : LocationError.unavailable.localizedDescription
    }
    continuation.resume(with: result)
  }
}
