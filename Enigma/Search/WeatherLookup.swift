import Foundation

/// The units Open-Meteo answers in: the Mac's measurement system (spec §6.4).
enum MeasurementUnits: Equatable, Sendable {
  case metric, us

  static var current: MeasurementUnits { Locale.current.measurementSystem == .us ? .us : .metric }
}

/// Open-Meteo's forecast response (spec §6.4). Date-times are local to the place, without an
/// offset; `utcOffsetSeconds` gives their offset and `timezone` the place's time zone (CP0's Q8).
struct WeatherForecast: Decodable, Equatable, Sendable {
  struct Current: Decodable, Equatable, Sendable {
    let time: String
    let temperature: Double?
    let apparentTemperature: Double?
    let relativeHumidity: Double?
    let precipitation: Double?
    let weatherCode: Int?
    let windSpeed: Double?

    enum CodingKeys: String, CodingKey {
      case time, precipitation
      case temperature = "temperature_2m", apparentTemperature = "apparent_temperature"
      case relativeHumidity = "relative_humidity_2m", weatherCode = "weather_code", windSpeed = "wind_speed_10m"
    }
  }

  struct Hourly: Decodable, Equatable, Sendable {
    let time: [String]
    let temperature: [Double?]
    let precipitationProbability: [Double?]
    let weatherCode: [Int?]

    enum CodingKeys: String, CodingKey {
      case time
      case temperature = "temperature_2m", precipitationProbability = "precipitation_probability"
      case weatherCode = "weather_code"
    }
  }

  struct Daily: Decodable, Equatable, Sendable {
    /// Calendar dates (`2026-11-02`), never shifted by an offset.
    let time: [String]
    let weatherCode: [Int?]
    let temperatureMax: [Double?]
    let temperatureMin: [Double?]
    let precipitationProbabilityMax: [Double?]
    let precipitationSum: [Double?]
    let sunrise: [String?]
    let sunset: [String?]
    let uvIndexMax: [Double?]
    let windSpeedMax: [Double?]

    enum CodingKeys: String, CodingKey {
      case time, sunrise, sunset
      case weatherCode = "weather_code", temperatureMax = "temperature_2m_max", temperatureMin = "temperature_2m_min"
      case precipitationProbabilityMax = "precipitation_probability_max", precipitationSum = "precipitation_sum"
      case uvIndexMax = "uv_index_max", windSpeedMax = "wind_speed_10m_max"
    }
  }

  /// Open-Meteo's unit labels, such as "°F", "mp/h" and "inch".
  struct Units: Decodable, Equatable, Sendable {
    let temperature: String?
    let relativeHumidity: String?
    let precipitation: String?
    let windSpeed: String?

    enum CodingKeys: String, CodingKey {
      case precipitation
      case temperature = "temperature_2m", relativeHumidity = "relative_humidity_2m", windSpeed = "wind_speed_10m"
    }
  }

  let current: Current
  let hourly: Hourly
  let daily: Daily
  let currentUnits: Units
  let utcOffsetSeconds: Int
  let timezone: String

  enum CodingKeys: String, CodingKey {
    case current, hourly, daily, timezone
    case currentUnits = "current_units", utcOffsetSeconds = "utc_offset_seconds"
  }
}

protocol WeatherLooking: Sendable {
  func forecast(at coordinate: SearchCoordinate, units: MeasurementUnits) async throws -> WeatherForecast
}

/// What went wrong with Open-Meteo, in words a capable model passes on.
enum WeatherLookupError: LocalizedError, Equatable {
  case timedOut, unreachable, invalidResponse
  case failed(Int)

  var errorDescription: String? {
    switch self {
    case .timedOut: "Open-Meteo didn't answer in time."
    case .unreachable: "Open-Meteo could not be reached."
    case .invalidResponse: "Open-Meteo returned an invalid response."
    case .failed(let status): "Open-Meteo failed (\(status))."
    }
  }
}

/// A time limit around one lookup; the loser is cancelled, and the caller's cancellation wins.
enum LookupTimeLimit {
  static func run<T: Sendable>(_ limit: Duration, clock: any Clock<Duration> = ContinuousClock(),
                               timeoutError: any Error & Sendable,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await clock.sleep(for: limit)
        return nil
      }
      defer { group.cancelAll() }
      guard let first = try await group.next(), let value = first else {
        try Task.checkCancellation()
        throw timeoutError
      }
      return value
    }
  }

  /// One GET through search's own session, as JSON-ish data, with Open-Meteo's errors.
  static func get(_ url: URL, client: any SearchHTTPClient, maximumBytes: Int) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response: SearchHTTPResponse
    do {
      response = try await client.send(request, maximumBytes: maximumBytes)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      throw WeatherLookupError.unreachable
    }
    guard response.statusCode == 200 else { throw WeatherLookupError.failed(response.statusCode) }
    guard !response.truncated else { throw WeatherLookupError.invalidResponse }
    return response.body
  }
}

/// Open-Meteo's forecast (spec §6.4): coordinates rounded to 2 decimals, within 3 s.
struct OpenMeteoWeather: WeatherLooking {
  static let timeout: Duration = .seconds(3)
  static let maximumBytes = 512 * 1_024

  private let client: any SearchHTTPClient
  private let clock: any Clock<Duration>

  init(client: any SearchHTTPClient = URLSessionSearchHTTPClient.live, clock: any Clock<Duration> = ContinuousClock()) {
    self.client = client
    self.clock = clock
  }

  static func url(for coordinate: SearchCoordinate, units: MeasurementUnits) -> URL {
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    var items = [
      URLQueryItem(name: "latitude", value: rounded(coordinate.latitude)),
      URLQueryItem(name: "longitude", value: rounded(coordinate.longitude)),
      URLQueryItem(name: "current",
                   value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m"),
      URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
      URLQueryItem(name: "daily",
                   value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max,wind_speed_10m_max"),
      URLQueryItem(name: "timezone", value: "auto"),
      URLQueryItem(name: "forecast_days", value: "7"),
    ]
    if units == .us {
      items += [URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
                URLQueryItem(name: "wind_speed_unit", value: "mph"),
                URLQueryItem(name: "precipitation_unit", value: "inch")]
    }
    components.queryItems = items
    return components.url!
  }

  /// About 1 km: 2 decimals, whatever the caller passed.
  static func rounded(_ value: Double) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), (value * 100).rounded() / 100)
  }

  func forecast(at coordinate: SearchCoordinate, units: MeasurementUnits) async throws -> WeatherForecast {
    let url = Self.url(for: coordinate, units: units)
    let data = try await LookupTimeLimit.run(Self.timeout, clock: clock, timeoutError: WeatherLookupError.timedOut) {
      [client] in try await LookupTimeLimit.get(url, client: client, maximumBytes: Self.maximumBytes)
    }
    do {
      return try JSONDecoder().decode(WeatherForecast.self, from: data)
    } catch {
      throw WeatherLookupError.invalidResponse
    }
  }
}

protocol Geocoding: Sendable {
  /// The place's coordinate (rounded to 2 decimals) and its resolved name with country, or nil
  /// when nothing matches.
  func locate(_ place: String) async throws -> (coordinate: SearchCoordinate, name: String)?
}

/// Open-Meteo's geocoding (spec §6.4, CP0b's Q4), within 2 s. It asks for a few matches and
/// prefers an exact name, since a typo otherwise resolves to another place (D81).
struct OpenMeteoGeocoder: Geocoding {
  static let timeout: Duration = .seconds(2)
  static let resultCount = 5
  static let maximumBytes = 256 * 1_024

  private let client: any SearchHTTPClient
  private let language: String
  private let clock: any Clock<Duration>

  init(client: any SearchHTTPClient = URLSessionSearchHTTPClient.live,
       language: String = Locale.current.language.languageCode?.identifier ?? "en",
       clock: any Clock<Duration> = ContinuousClock()) {
    self.client = client
    self.language = language
    self.clock = clock
  }

  struct Match: Decodable, Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let countryCode: String?
    let admin1: String?

    enum CodingKeys: String, CodingKey {
      case name, latitude, longitude, country, admin1
      case countryCode = "country_code"
    }

    /// "Paris, Île-de-France Region, France": name, region and country as returned.
    var displayName: String {
      var parts = [name]
      if let admin1, !admin1.isEmpty, admin1 != name { parts.append(admin1) }
      if let country, !country.isEmpty { parts.append(country) }
      return parts.joined(separator: ", ")
    }
  }

  private struct Response: Decodable { let results: [Match]? }

  func url(for name: String) -> URL {
    var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    components.queryItems = [URLQueryItem(name: "name", value: name),
                             URLQueryItem(name: "count", value: String(Self.resultCount)),
                             URLQueryItem(name: "language", value: language),
                             URLQueryItem(name: "format", value: "json")]
    return components.url!
  }

  func locate(_ place: String) async throws -> (coordinate: SearchCoordinate, name: String)? {
    // Open-Meteo matches names only: "springfield, illinois" is searched as "springfield".
    let parts = place.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let name = parts.first, !name.isEmpty else { return nil }
    let qualifier = parts.count > 1 ? parts[1] : nil
    let url = url(for: name)
    let data = try await LookupTimeLimit.run(Self.timeout, clock: clock, timeoutError: WeatherLookupError.timedOut) {
      [client] in try await LookupTimeLimit.get(url, client: client, maximumBytes: Self.maximumBytes)
    }
    let matches: [Match]
    do {
      matches = try JSONDecoder().decode(Response.self, from: data).results ?? []
    } catch {
      throw WeatherLookupError.invalidResponse
    }
    guard let best = Self.best(matches, name: name, qualifier: qualifier) else { return nil }
    return (SearchCoordinate(latitude: (best.latitude * 100).rounded() / 100,
                             longitude: (best.longitude * 100).rounded() / 100), best.displayName)
  }

  /// An exact name that also matches the qualifier, then an exact name, then the first match.
  static func best(_ matches: [Match], name: String, qualifier: String?) -> Match? {
    let wanted = folded(name)
    let exact = matches.filter { folded($0.name) == wanted }
    if let qualifier = qualifier.map(folded), !qualifier.isEmpty,
       let qualified = exact.first(where: { match in
         [match.admin1, match.country, match.countryCode].compactMap { $0.map(folded) }.contains(qualifier)
       }) {
      return qualified
    }
    return exact.first ?? matches.first
  }

  private static func folded(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The forecast as words, for the small models' excerpt and `get_weather`'s JSON (spec §6.2, §6.4).
struct WeatherReport: Encodable, Equatable, Sendable {
  struct Now: Encodable, Equatable, Sendable {
    let temperature: String
    let feelsLike: String
    let conditions: String
    let humidity: String
    let wind: String
    let precipitation: String

    enum CodingKeys: String, CodingKey {
      case temperature, conditions, humidity, wind, precipitation
      case feelsLike = "feels_like"
    }
  }

  struct Hour: Encodable, Equatable, Sendable {
    let time: String
    let temperature: String
    let conditions: String
    let precipitationChance: String

    enum CodingKeys: String, CodingKey {
      case time, temperature, conditions
      case precipitationChance = "precipitation_chance"
    }
  }

  struct Day: Encodable, Equatable, Sendable {
    let date: String
    let conditions: String
    let high: String
    let low: String
    let precipitationChance: String
    let precipitation: String
    let uvIndex: String
    let maximumWind: String
    let sunrise: String
    let sunset: String

    enum CodingKeys: String, CodingKey {
      case date, conditions, high, low, precipitation, sunrise, sunset
      case precipitationChance = "precipitation_chance", uvIndex = "uv_index", maximumWind = "maximum_wind"
    }
  }

  let place: String
  let timeZone: String
  let now: Now
  let next24Hours: [Hour]
  let next7Days: [Day]

  enum CodingKeys: String, CodingKey {
    case place, now
    case timeZone = "time_zone", next24Hours = "next_24_hours", next7Days = "next_7_days"
  }
}

enum WeatherLookup {
  static let source = WebSearchSource(title: "Open-Meteo forecast", url: URL(string: "https://open-meteo.com/")!)
  /// The next 24 hours, in 3-hour steps.
  static let hourSteps = 8, hourStride = 3

  /// Open-Meteo's WMO weather codes, as its documentation words them.
  static func description(forCode code: Int) -> String {
    switch code {
    case 0: "clear sky"
    case 1: "mainly clear"
    case 2: "partly cloudy"
    case 3: "overcast"
    case 45: "fog"
    case 48: "freezing fog"
    case 51: "light drizzle"
    case 53: "drizzle"
    case 55: "heavy drizzle"
    case 56: "light freezing drizzle"
    case 57: "freezing drizzle"
    case 61: "light rain"
    case 63: "rain"
    case 65: "heavy rain"
    case 66: "light freezing rain"
    case 67: "freezing rain"
    case 71: "light snow"
    case 73: "snow"
    case 75: "heavy snow"
    case 77: "snow grains"
    case 80: "light showers"
    case 81: "showers"
    case 82: "violent showers"
    case 85: "light snow showers"
    case 86: "snow showers"
    case 95: "thunderstorm"
    case 96, 99: "thunderstorm with hail"
    default: "unknown conditions"
    }
  }

  /// The forecast in words: now, the next 24 hours from the current hour, and 7 days. Date-times
  /// are parsed with the response's offset and shown in the place's time zone; days stay dates.
  static func report(_ forecast: WeatherForecast, placeName: String, now: Date) -> WeatherReport {
    let offset = TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .gmt
    let local = TimeZone(identifier: forecast.timezone) ?? offset
    let parse = formatter("yyyy-MM-dd'T'HH:mm", offset)
    let hourLabel = formatter("EEE HH:mm", local)
    let clockLabel = formatter("HH:mm", local)
    let dateParse = formatter("yyyy-MM-dd", .gmt)
    let dateLabel = formatter("EEE d MMM", .gmt)
    let units = forecast.currentUnits
    let temperature = units.temperature ?? ""
    let wind = units.windSpeed ?? ""
    let rain = units.precipitation ?? ""

    let current = forecast.current
    let nowLine = WeatherReport.Now(
      temperature: number(current.temperature, temperature), feelsLike: number(current.apparentTemperature, temperature),
      conditions: current.weatherCode.map(description(forCode:)) ?? "unknown conditions",
      humidity: number(current.relativeHumidity, units.relativeHumidity ?? "%", decimals: 0),
      wind: number(current.windSpeed, wind, spaced: true), precipitation: amount(current.precipitation, rain))

    let hourly = forecast.hourly
    let start = hourly.time.firstIndex { text in
      parse.date(from: text).map { $0.addingTimeInterval(3_600) > now } ?? false
    } ?? hourly.time.count
    let hours = stride(from: start, to: hourly.time.count, by: hourStride).prefix(hourSteps).map { index in
      WeatherReport.Hour(
        time: parse.date(from: hourly.time[index]).map(hourLabel.string(from:)) ?? hourly.time[index],
        temperature: number(element(hourly.temperature, index), temperature),
        conditions: element(hourly.weatherCode, index).map(description(forCode:)) ?? "unknown conditions",
        precipitationChance: number(element(hourly.precipitationProbability, index), "%", decimals: 0))
    }

    let daily = forecast.daily
    let days = daily.time.indices.map { index in
      WeatherReport.Day(
        date: dateParse.date(from: daily.time[index]).map(dateLabel.string(from:)) ?? daily.time[index],
        conditions: element(daily.weatherCode, index).map(description(forCode:)) ?? "unknown conditions",
        high: number(element(daily.temperatureMax, index), temperature),
        low: number(element(daily.temperatureMin, index), temperature),
        precipitationChance: number(element(daily.precipitationProbabilityMax, index), "%", decimals: 0),
        precipitation: amount(element(daily.precipitationSum, index), rain),
        uvIndex: number(element(daily.uvIndexMax, index), ""),
        maximumWind: number(element(daily.windSpeedMax, index), wind, spaced: true),
        sunrise: element(daily.sunrise, index).flatMap(parse.date(from:)).map(clockLabel.string(from:)) ?? "unknown",
        sunset: element(daily.sunset, index).flatMap(parse.date(from:)).map(clockLabel.string(from:)) ?? "unknown")
    }
    return WeatherReport(place: placeName, timeZone: forecast.timezone, now: nowLine, next24Hours: hours, next7Days: days)
  }

  /// The small models' excerpt (kind `.weather`), sourced to Open-Meteo with no location.
  static func excerpt(_ forecast: WeatherForecast, placeName: String, now: Date) -> WebSearchResult {
    let report = report(forecast, placeName: placeName, now: now)
    var lines = ["Forecast for \(report.place) (local times)."]
    let current = report.now
    lines.append("Now: \(current.temperature), feels like \(current.feelsLike), \(current.conditions), humidity \(current.humidity), wind \(current.wind), precipitation \(current.precipitation).")
    lines.append("Next 24 hours:")
    lines += report.next24Hours.map { "- \($0.time): \($0.temperature), \($0.conditions), \($0.precipitationChance) chance of precipitation" }
    lines.append("Next 7 days:")
    lines += report.next7Days.map { day in
      "- \(day.date): \(day.conditions), high \(day.high), low \(day.low), \(day.precipitationChance) chance of precipitation, \(day.precipitation), UV \(day.uvIndex), wind up to \(day.maximumWind), sunrise \(day.sunrise), sunset \(day.sunset)"
    }
    return WebSearchResult(source: source, snippets: [lines.joined(separator: "\n")], site: "Open-Meteo", kind: .weather)
  }

  // MARK: Formatting

  private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }

  private static func element<T>(_ values: [T?], _ index: Int) -> T? {
    values.indices.contains(index) ? values[index] : nil
  }

  private static func number(_ value: Double?, _ unit: String, decimals: Int = 1, spaced: Bool = false) -> String {
    guard let value else { return "unknown" }
    let text = String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    if unit.isEmpty { return text }
    return text + (spaced ? " " : "") + unit
  }

  /// Rain and snow: two decimals in inches, one in millimetres.
  private static func amount(_ value: Double?, _ unit: String) -> String {
    number(value, unit, decimals: unit == "inch" ? 2 : 1, spaced: true)
  }
}
