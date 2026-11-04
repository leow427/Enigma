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
    /// 1 by day, 0 at night (F36's sky).
    var isDay: Int? = nil

    enum CodingKeys: String, CodingKey {
      case time, precipitation
      case temperature = "temperature_2m", apparentTemperature = "apparent_temperature"
      case relativeHumidity = "relative_humidity_2m", weatherCode = "weather_code", windSpeed = "wind_speed_10m"
      case isDay = "is_day"
    }
  }

  struct Hourly: Decodable, Equatable, Sendable {
    let time: [String]
    let temperature: [Double?]
    let precipitationProbability: [Double?]
    let weatherCode: [Int?]
    /// 1 by day, 0 at night, for the card's hourly icons.
    var isDay: [Int?]? = nil

    enum CodingKeys: String, CodingKey {
      case time
      case temperature = "temperature_2m", precipitationProbability = "precipitation_probability"
      case weatherCode = "weather_code", isDay = "is_day"
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
    /// Centimetres, or inches in US units (F36's snow amount).
    var snowfallSum: [Double?]? = nil

    enum CodingKeys: String, CodingKey {
      case time, sunrise, sunset
      case snowfallSum = "snowfall_sum"
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
                   value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,is_day"),
      URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
      URLQueryItem(name: "daily",
                   value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max,wind_speed_10m_max,snowfall_sum"),
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

  /// Parses the forecast's calendar dates (`2026-11-02`).
  static var dateParser: DateFormatter { formatter("yyyy-MM-dd", .gmt) }

  static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
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

// MARK: The weather card (F36)

/// Which forecast days a weather card shows: from `get_weather`'s dates, or from the question's
/// time words on the wording route. Days are the forecast's own dates, local to the place.
enum WeatherDays: Equatable, Sendable {
  case today, tomorrow, weekend, week
  /// The next day with this weekday, today included: 1 is Sunday, 7 Saturday, as `Calendar`.
  case weekday(Int)
  /// `get_weather`'s range, as `YYYY-MM-DD`.
  case dates(start: String, end: String)

  private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

  /// "this weekend", "this week", "tomorrow" or a weekday name, also as "this weekend's" or
  /// "tomorrow’s"; anything else is today.
  init(question: String) {
    let text = question.replacingOccurrences(of: "’", with: "'").lowercased()
    // Simple word boundaries, so "weekend's" still has "weekend" as a word.
    if text.contains(/\bweekend\b/.wordBoundaryKind(.simple)) {
      self = .weekend
    } else if text.contains(/\b(?:week|next (?:7|seven) days)\b/.wordBoundaryKind(.simple)) {
      self = .week
    } else if text.contains(/\btomorrow\b/.wordBoundaryKind(.simple)) {
      self = .tomorrow
    } else if let index = Self.weekdays.firstIndex(where: { text.contains($0) }) {
      self = .weekday(index + 1)
    } else {
      self = .today
    }
  }

  /// The days among the forecast's `dates`, or nil when none of them is in the forecast.
  func indices(in dates: [String]) -> ClosedRange<Int>? {
    guard let last = dates.indices.last else { return nil }
    switch self {
    case .today: return 0...0
    case .tomorrow: return last >= 1 ? 1...1 : nil
    case .week: return 0...last
    case .weekend:
      // Saturday and Sunday, or Sunday alone once Saturday has passed.
      guard let start = dates.indices.first(where: { [7, 1].contains(Self.weekday(of: dates[$0])) }) else { return nil }
      return start...(Self.weekday(of: dates[start]) == 7 ? min(start + 1, last) : start)
    case .weekday(let day):
      return dates.indices.first { Self.weekday(of: dates[$0]) == day }.map { $0...$0 }
    case .dates(let start, let end):
      // ISO dates sort as text.
      guard let first = dates.firstIndex(where: { $0 >= start }), let final = dates.lastIndex(where: { $0 <= end }),
            first <= final else { return nil }
      return first...final
    }
  }

  static func weekday(of date: String) -> Int? {
    WeatherLookup.dateParser.date(from: date).map { Calendar.gregorianGMT.component(.weekday, from: $0) }
  }
}

/// What a weather card shows. Every figure comes from the Open-Meteo forecast, never from the
/// model's text, so the card can't show a made-up temperature. Session-only, like the map card.
struct WeatherCardModel: Equatable, Sendable {
  enum Sky: Equatable, Sendable, CaseIterable { case clear, partlyCloudy, overcast, fog, rain, snow, storm }
  /// Twilight is the 45 minutes either side of the day's sunrise and sunset.
  enum Light: Equatable, Sendable, CaseIterable { case day, twilight, night }

  struct Hour: Equatable, Sendable {
    var time: String
    var code: Int
    var isDay: Bool
    var temperature: Double
    var rainChance: Int?
  }

  struct Day: Equatable, Sendable {
    /// "Today", "Sat".
    var weekday: String
    var code: Int
    var high: Double
    var low: Double
    var rainChance: Int?
    var wind: Double?
  }

  enum Content: Equatable, Sendable {
    /// Today, from the current conditions.
    case now(temperature: Double, feelsLike: Double, high: Double, low: Double, rainChance: Int?, wind: Double?,
             hours: [Hour])
    /// A later single day, like tomorrow: its high, low and chance of rain instead of now. The
    /// amount is snow in snowy weather, otherwise rain.
    case day(high: Double, low: Double, rainChance: Int?, amount: Double?, wind: Double?, sunset: String?,
             hours: [Hour])
    /// One column per day, up to the forecast's 7.
    case days([Day])
  }

  var place: String
  /// "Now · Tue 3 Nov", "This weekend · Sat 7 – Sun 8 Nov".
  var caption: String
  /// The sky's weather code: now's, the day's, or the first day's.
  var code: Int
  var light: Light
  var units: MeasurementUnits = .metric
  var content: Content

  var sky: Sky { Self.sky(forCode: code) }

  /// Steps of the hourly strip: the next 6 hours today, 06:00 to 21:00 on a later day.
  static let hourCount = 6
  static let laterDayHours = ["06", "09", "12", "15", "18", "21"]
  static let twilight: TimeInterval = 45 * 60

  /// The card for `days` of `forecast`, or nil when those days aren't in it or its figures are missing.
  init?(forecast: WeatherForecast, placeName: String, days: WeatherDays, now: Date) {
    let daily = forecast.daily
    guard let range = days.indices(in: daily.time) else { return nil }
    let offset = TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .gmt
    let local = TimeZone(identifier: forecast.timezone) ?? offset
    let parse = WeatherLookup.formatter("yyyy-MM-dd'T'HH:mm", offset)
    // "4 PM" on the strip, "5:49 PM" for sunset.
    let clock = WeatherLookup.formatter("h a", local)
    let sunsetClock = WeatherLookup.formatter("h:mm a", local)
    func element<T>(_ values: [T?]?, _ index: Int) -> T? {
      guard let values, values.indices.contains(index) else { return nil }
      return values[index]
    }
    func chance(_ value: Double?) -> Int? { value.map { Int($0.rounded()) } }
    func dayLabel(_ index: Int, _ format: String) -> String {
      WeatherLookup.dateParser.date(from: daily.time[index])
        .map(WeatherLookup.formatter(format, .gmt).string(from:)) ?? daily.time[index]
    }
    func hour(_ index: Int) -> Hour? {
      let hourly = forecast.hourly
      guard let temperature = element(hourly.temperature, index), let code = element(hourly.weatherCode, index),
            let date = parse.date(from: hourly.time[index]) else { return nil }
      return Hour(time: clock.string(from: date), code: code, isDay: element(hourly.isDay, index).map { $0 != 0 } ?? true,
                  temperature: temperature, rainChance: chance(element(hourly.precipitationProbability, index)))
    }

    let first = range.lowerBound
    let name = placeName.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? placeName
    place = name.prefix(1).uppercased() + name.dropFirst()
    units = forecast.currentUnits.temperature == "°F" ? .us : .metric
    let dates = range.count == 1 ? dayLabel(first, "EEE d MMM")
      : (dayLabel(first, "MMM") == dayLabel(range.upperBound, "MMM") ? dayLabel(first, "EEE d")
        : dayLabel(first, "EEE d MMM")) + " – " + dayLabel(range.upperBound, "EEE d MMM")

    if range.count > 1 {
      var columns: [Day] = []
      for index in range {
        guard let code = element(daily.weatherCode, index), let high = element(daily.temperatureMax, index),
              let low = element(daily.temperatureMin, index) else { return nil }
        columns.append(Day(weekday: index == 0 ? "Today" : dayLabel(index, "EEE"), code: code, high: high, low: low,
                           rainChance: chance(element(daily.precipitationProbabilityMax, index)),
                           wind: element(daily.windSpeedMax, index)))
      }
      let weekend = range.count == 2 && WeatherDays.weekday(of: daily.time[first]) == 7
      let week = range == 0...(daily.time.count - 1) && range.count == 7
      caption = (weekend ? "This weekend · " : week ? "This week · " : "") + dates
      code = columns[0].code
      light = .day
      content = .days(columns)
      return
    }

    guard let high = element(daily.temperatureMax, first), let low = element(daily.temperatureMin, first) else { return nil }
    let rainChance = chance(element(daily.precipitationProbabilityMax, first))
    if first == 0 {
      let current = forecast.current
      guard let temperature = current.temperature, let code = current.weatherCode ?? element(daily.weatherCode, 0)
      else { return nil }
      let start = forecast.hourly.time.firstIndex { parse.date(from: $0).map { $0 > now } ?? false }
        ?? forecast.hourly.time.count
      let hours = (start..<forecast.hourly.time.count).lazy.compactMap(hour).prefix(Self.hourCount)
      caption = "Now · " + dates
      self.code = code
      light = Self.light(isDay: current.isDay, now: now,
                         sunrise: element(daily.sunrise, 0).flatMap(parse.date(from:)),
                         sunset: element(daily.sunset, 0).flatMap(parse.date(from:)))
      content = .now(temperature: temperature, feelsLike: current.apparentTemperature ?? temperature, high: high, low: low,
                     rainChance: rainChance, wind: current.windSpeed, hours: Array(hours))
    } else {
      guard let code = element(daily.weatherCode, first) else { return nil }
      let day = daily.time[first]
      let hours = Self.laterDayHours.compactMap { mark in
        forecast.hourly.time.firstIndex(of: "\(day)T\(mark):00").flatMap(hour)
      }
      caption = (first == 1 ? "Tomorrow · " : "") + dates
      self.code = code
      light = .day
      let snowy = Self.sky(forCode: code) == .snow
      content = .day(high: high, low: low, rainChance: rainChance,
                     amount: snowy ? element(daily.snowfallSum, first) : element(daily.precipitationSum, first),
                     wind: element(daily.windSpeedMax, first),
                     sunset: element(daily.sunset, first).flatMap(parse.date(from:)).map(sunsetClock.string(from:)), hours: hours)
    }
  }

  init(place: String, caption: String, code: Int, light: Light, units: MeasurementUnits = .metric, content: Content) {
    self.place = place
    self.caption = caption
    self.code = code
    self.light = light
    self.units = units
    self.content = content
  }

  /// Twilight near sunrise and sunset; otherwise Open-Meteo's `is_day`, or the sun's times.
  static func light(isDay: Int?, now: Date, sunrise: Date?, sunset: Date?) -> Light {
    for edge in [sunrise, sunset].compactMap({ $0 }) where abs(now.timeIntervalSince(edge)) <= twilight {
      return .twilight
    }
    if let isDay { return isDay != 0 ? .day : .night }
    guard let sunrise, let sunset else { return .day }
    return now >= sunrise && now < sunset ? .day : .night
  }

  static func sky(forCode code: Int) -> Sky {
    switch code {
    case 0, 1: .clear
    case 2: .partlyCloudy
    case 3: .overcast
    case 45, 48: .fog
    case 71...77, 85, 86: .snow
    case 95...99: .storm
    default: .rain
    }
  }

  /// How hard rain or snow falls; 1 is moderate.
  static func intensity(forCode code: Int) -> Double {
    switch code {
    case 51, 56, 77: 0.45
    case 61, 66, 71, 80, 85: 0.6
    case 53, 57: 0.7
    case 55: 0.9
    case 65, 75, 82: 1.5
    case 95...99: 1.3
    default: 1
    }
  }

  static func condition(forCode code: Int) -> String {
    let words = WeatherLookup.description(forCode: code)
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// An outline SF Symbol for a weather code.
  static func symbol(forCode code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1: isDay ? "sun.max" : "moon.stars"
    case 2: isDay ? "cloud.sun" : "cloud.moon"
    case 3: "cloud"
    case 45, 48: "cloud.fog"
    case 51...57: "cloud.drizzle"
    case 65, 67: "cloud.heavyrain"
    case 80...82: isDay ? "cloud.sun.rain" : "cloud.moon.rain"
    case 71...77, 85, 86: "cloud.snow"
    case 95...99: "cloud.bolt.rain"
    default: "cloud.rain"
    }
  }

  /// What falls, for the chance-of label.
  var precipitationWord: String { sky == .snow ? "Snow" : "Rain" }

  func degrees(_ value: Double) -> String {
    let whole = Int(value.rounded())
    return (whole < 0 ? "−" : "") + "\(abs(whole))°"
  }

  func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "–" }

  func speed(_ value: Double?) -> String {
    guard let value else { return "–" }
    return "\(Int(value.rounded())) \(units == .us ? "mph" : "km/h")"
  }

  /// Rain in mm and snow in cm, or both in inches.
  func amount(_ value: Double) -> String {
    if units == .us { return String(format: "%.2f in", locale: Locale(identifier: "en_US_POSIX"), value) }
    let unit = sky == .snow ? "cm" : "mm"
    return value > 0 && value < 1 ? String(format: "%.1f \(unit)", locale: Locale(identifier: "en_US_POSIX"), value)
      : "\(Int(value.rounded())) \(unit)"
  }

  /// VoiceOver reads the card as one summary.
  var accessibilityLabel: String {
    let condition = Self.condition(forCode: code).lowercased()
    let when = caption.replacingOccurrences(of: " · ", with: ", ")
    func whole(_ value: Double) -> Int { Int(value.rounded()) }
    func chanceOf(_ value: Int?, _ word: String) -> String {
      value.map { ", \($0) percent chance of \(word)" } ?? ""
    }
    switch content {
    case let .now(temperature, _, high, low, _, _, _):
      return "\(place), \(whole(temperature)) degrees, \(condition), high \(whole(high)), low \(whole(low))"
    case let .day(high, low, rainChance, _, _, _, _):
      return "\(place), \(when), \(condition), high \(whole(high)), low \(whole(low))"
        + chanceOf(rainChance, precipitationWord.lowercased())
    case let .days(days):
      return "\(place), \(when). " + days.map {
        "\($0.weekday), \(Self.condition(forCode: $0.code).lowercased()), high \(whole($0.high)), low \(whole($0.low))"
          + chanceOf($0.rainChance, Self.sky(forCode: $0.code) == .snow ? "snow" : "rain")
      }.joined(separator: ". ")
    }
  }
}

extension Calendar {
  static let gregorianGMT: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
}
