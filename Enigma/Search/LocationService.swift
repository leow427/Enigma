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
    if matches(namedPlace, text) { return false }
    if matches(nearbyCue, text) { return true }
    guard matches(weatherTopic, text) else { return false }
    // Named destinations take precedence over the device's location.
    if matches(namedDestination, text) { return false }
    if matches(conceptualWeather, text) { return false }
    return matches(asksAboutNow, text)
  }

  /// "near me", "nearby", "around me", "in my area", "locally", or "local" before a place word.
  static func hasNearbyCue(normalized text: String) -> Bool {
    matches(SearchRouting.nearbyPhrase, text) || matches(SearchRouting.localPlace, text)
  }

  /// A weather question about now, the coming days or right here, not about climate, records or the news.
  static func asksAboutWeatherNow(normalized text: String) -> Bool {
    guard !WebSearchPolicy.isOfflineOrTransformation(text), matches(weatherTopic, text),
          !matches(conceptualWeather, text), !matches(weatherBackground, text) else { return false }
    if matches(asksAboutNow, text) { return true }
    // "weather near me", "local weather". Snow and umbrellas near me are places, not forecasts.
    if matches(forecastWord, text) && matches(nearbyCue, text) { return true }
    // A forecast for a named place can be days away: "weather in Paris this weekend".
    return weatherPlace(normalized: text) != nil && matches(comingDays, text)
  }

  /// "paris" in "weather in paris this weekend": the words after in, at, for or near, up to a time word.
  /// A time is never a place: "in 2 hours", "in the morning", "in december".
  static func weatherPlace(normalized text: String) -> String? {
    guard let match = weatherPlacePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    let place = text[range].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    guard !place.isEmpty, place != "the", !matches(timePhrase, place) else { return nil }
    return place
  }

  static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  // Compiled once. All patterns are fixed, tested source literals, never user-provided regexes.
  private static let optOutLocation = try! NSRegularExpression(pattern: #"\b(?:(?:do not|don't|dont|never) (?:use|access|share|detect) (?:my |the )?location|without (?:my )?location)\b"#)
  static let namedPlace = try! NSRegularExpression(pattern: #"\b(?:in|at|near)\s+(?!(?:me|my|this|the|here)\b)[a-z]"#)
  private static let nearbyCue = try! NSRegularExpression(pattern: #"\b(?:near me|around me|nearby|my (?:current )?location|where am i|in my area|locally|local (?:weather|restaurants?|cafes?|events|places))\b"#)
  private static let weatherTopic = try! NSRegularExpression(pattern: #"\b(?:weather|forecast|temperature|rain|snow|umbrella)\b"#)
  private static let namedDestination = try! NSRegularExpression(pattern: #"\b(?:in|at|for|near)\s+(?!(?:today|tonight|tomorrow|this|the next)\b)[a-z]"#)
  private static let conceptualWeather = try! NSRegularExpression(pattern: #"^(?:what is|what's|define|explain|how does) (?:the |a )?(?:weather|rain|snow|temperature)(?: work| mean)?[?.!]*$"#)
  private static let asksAboutNow = try! NSRegularExpression(pattern: #"\b(?:today|tonight|tomorrow|this week|forecast|will it|is it|what's|what is|what are|do i need)\b"#)
  private static let weatherBackground = try! NSRegularExpression(pattern: #"\b(?:news|latest|record|average|historical|history|climate)\b"#)
  private static let comingDays = try! NSRegularExpression(pattern: #"\b(?:this weekend|next week)\b"#)
  private static let forecastWord = try! NSRegularExpression(pattern: #"\b(?:weather|forecast)\b"#)
  // Starts with a letter, like `namedDestination`, so the two agree on what a place is.
  private static let weatherPlacePattern = try! NSRegularExpression(pattern: #"\b(?:in|at|for|near)\s+(?!(?:me|my|this|here|today|tonight|tomorrow|next|on|a|an)\b)([a-z].*?)(?=\s+(?:today|tonight|tomorrow|this|next|on)\b|$)"#)
  private static let timePhrase = try! NSRegularExpression(pattern: #"^(?:the )?(?:morning|afternoon|evening|night|weekend|week|month|year|hours?|minutes?|days?|january|february|march|april|may|june|july|august|september|october|november|december|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#)
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
