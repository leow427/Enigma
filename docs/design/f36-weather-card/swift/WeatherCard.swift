import SwiftUI

// F36 prototype: the card above a weather answer (docs/design/f36-weather-card/).
// Not wired into the chat yet; WeatherCardSnapshotTests renders it from fixture forecasts.

/// What a weather card shows. Every figure comes from the Open-Meteo forecast, never from the
/// model's text, so the card can't show a made-up temperature.
struct WeatherCardModel: Equatable, Sendable {
  enum Sky: Equatable, Sendable, CaseIterable { case clear, partlyCloudy, overcast, fog, rain, snow, storm }
  /// Twilight is the 45 minutes either side of the day's sunrise and sunset.
  enum Light: Equatable, Sendable, CaseIterable { case day, twilight, night }

  struct Hour: Equatable, Sendable {
    var time: String
    var code: Int
    var isDay: Bool
    var temperature: Double
    var rainChance: Int
  }

  struct Day: Equatable, Sendable {
    /// "Today", "Sat".
    var weekday: String
    var code: Int
    var high: Double
    var low: Double
    var rainChance: Int
    var wind: Double
  }

  enum Content: Equatable, Sendable {
    /// Today, from the current conditions.
    case now(temperature: Double, feelsLike: Double, high: Double, low: Double, rainChance: Int, wind: Double,
             hours: [Hour])
    /// A later single day, like tomorrow: its high, low and chance of rain instead of now.
    case day(high: Double, low: Double, rainChance: Int, precipitation: Double, wind: Double, sunset: String,
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

  /// An outline SF Symbol, drawn multicolor so the sun is yellow and the rain blue.
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

  func speed(_ value: Double) -> String { "\(Int(value.rounded())) \(units == .us ? "mph" : "km/h")" }

  func amount(_ value: Double) -> String {
    units == .us ? String(format: "%.2f in", value) : "\(Int(value.rounded())) mm"
  }

  /// VoiceOver reads the card as one summary.
  var accessibilityLabel: String {
    let condition = Self.condition(forCode: code).lowercased()
    let when = caption.replacingOccurrences(of: " · ", with: ", ")
    func whole(_ value: Double) -> Int { Int(value.rounded()) }
    switch content {
    case let .now(temperature, _, high, low, _, _, _):
      return "\(place), \(whole(temperature)) degrees, \(condition), high \(whole(high)), low \(whole(low))"
    case let .day(high, low, rainChance, _, _, _, _):
      return "\(place), \(when), \(condition), high \(whole(high)), low \(whole(low)), "
        + "\(rainChance) percent chance of \(precipitationWord.lowercased())"
    case let .days(days):
      return "\(place), \(when). " + days.map {
        "\($0.weekday), \(Self.condition(forCode: $0.code).lowercased()), high \(whole($0.high)), low \(whole($0.low))"
      }.joined(separator: ". ")
    }
  }
}

/// The weather card: an illustrated sky with the place and the headline figures, over the
/// app's own surface with the details, so the figures follow Paper and Ink.
struct WeatherCardView: View {
  static let cornerRadius: CGFloat = 10

  let model: WeatherCardModel
  /// A fixed moment of the sky's animation, for snapshots. Nil animates.
  var time: Double?

  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  @State private var isOnScreen = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    VStack(spacing: 0) {
      header
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { WeatherSkyView(model: model, time: time, paused: reduceMotion || !isOnScreen) }
      Rectangle().fill(palette.border.color).frame(height: 1 / displayScale)
      details
        .frame(maxWidth: .infinity)
        .background(palette.surface.color)
    }
    .clipShape(shape)
    .overlay { EnigmaEdgeStroke(shape: shape) }
    .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.accessibilityLabel)
  }

  private var isDays: Bool { if case .days = model.content { true } else { false } }

  // MARK: Sky

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(model.place)
        .font(EnigmaTypography.ui(15, weight: .semibold))
        .tracking(-0.15)
      Text(model.caption)
        .font(EnigmaTypography.mono(11))
        .opacity(0.8)
        .padding(.top, 2)
      switch model.content {
      case let .now(temperature, _, high, low, _, _, _):
        headline(model.degrees(temperature), low: nil)
        Text(WeatherCardModel.condition(forCode: model.code)).font(EnigmaTypography.ui(14, weight: .medium))
        HStack(spacing: 4) {
          Text("H")
          Text(model.degrees(high)).fontWeight(.medium)
          Text("L").padding(.leading, 6)
          Text(model.degrees(low)).fontWeight(.medium)
        }
        .font(EnigmaTypography.ui(13))
        .monospacedDigit()
        .opacity(0.88)
        .padding(.top, 1)
      case let .day(high, low, _, _, _, _, _):
        headline(model.degrees(high), low: model.degrees(low))
        Text(WeatherCardModel.condition(forCode: model.code)).font(EnigmaTypography.ui(14, weight: .medium))
      case .days:
        EmptyView()
      }
    }
    .foregroundStyle(WeatherSky.colors(for: model.sky, light: model.light).text.color)
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, WeatherSky.groundHeight + 6)
    .frame(minHeight: isDays ? 0 : 176, alignment: .topLeading)
  }

  private func headline(_ value: String, low: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(value)
        .font(EnigmaTypography.ui(54, weight: .light))
        .tracking(-2.2)
      if let low {
        Text("/ \(low)")
          .font(EnigmaTypography.ui(22))
          .opacity(0.8)
      }
    }
    .monospacedDigit()
    .padding(.leading, -2)
    .padding(.top, 8)
    .padding(.bottom, 2)
  }

  // MARK: Details

  @ViewBuilder private var details: some View {
    switch model.content {
    case let .now(_, feelsLike, _, _, rainChance, wind, hours):
      VStack(spacing: 10) {
        stats([("Feels like", model.degrees(feelsLike)), (model.precipitationWord, "\(rainChance)%"),
               ("Wind", model.speed(wind))])
        hourly(hours)
      }
      .padding(.horizontal, 16)
      .padding(.top, 11)
      .padding(.bottom, 12)
    case let .day(_, _, rainChance, precipitation, wind, sunset, hours):
      VStack(spacing: 10) {
        stats([(model.precipitationWord, "\(rainChance)% · \(model.amount(precipitation))"),
               ("Wind", model.speed(wind)), ("Sunset", sunset)])
        hourly(hours)
      }
      .padding(.horizontal, 16)
      .padding(.top, 11)
      .padding(.bottom, 12)
    case let .days(days):
      daily(days)
        .padding(.horizontal, 6)
        .padding(.vertical, 11)
    }
  }

  private func stats(_ items: [(String, String)]) -> some View {
    HStack(spacing: 22) {
      ForEach(items, id: \.0) { label, value in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(label)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textSecondary.color)
          Text(value)
            .font(EnigmaTypography.ui(13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(palette.textPrimary.color)
        }
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
  }

  private func hourly(_ hours: [WeatherCardModel.Hour]) -> some View {
    VStack(spacing: 9) {
      Rectangle().fill(palette.hairline.color).frame(height: 1 / displayScale)
      HStack(spacing: 0) {
        ForEach(hours.indices, id: \.self) { index in
          let hour = hours[index]
          VStack(spacing: 4) {
            Text(hour.time)
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textSecondary.color)
            WeatherGlyph(code: hour.code, isDay: hour.isDay, size: 17)
            Text(model.degrees(hour.temperature))
              .font(EnigmaTypography.ui(13, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(palette.textPrimary.color)
            RainChanceLabel(percent: hour.rainChance)
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private func daily(_ days: [WeatherCardModel.Day]) -> some View {
    // A weekend has room for words; a week keeps to figures so 7 fit the compact panel.
    let roomy = days.count <= 3
    return HStack(spacing: 0) {
      ForEach(days.indices, id: \.self) { index in
        let day = days[index]
        VStack(spacing: 5) {
          Text(day.weekday)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textSecondary.color)
          WeatherGlyph(code: day.code, isDay: true, size: roomy ? 22 : 19)
          if roomy {
            Text(WeatherCardModel.condition(forCode: day.code))
              .font(EnigmaTypography.ui(12))
              .foregroundStyle(palette.textSecondary.color)
              .lineLimit(1)
          }
          HStack(spacing: 5) {
            Text(model.degrees(day.high))
              .font(EnigmaTypography.ui(13, weight: .semibold))
              .foregroundStyle(palette.textPrimary.color)
            Text(model.degrees(day.low))
              .font(EnigmaTypography.ui(13))
              .foregroundStyle(palette.textSecondary.color)
          }
          .monospacedDigit()
          RainChanceLabel(percent: day.rainChance)
          if roomy {
            Text(model.speed(day.wind))
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textSecondary.color)
          }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
          if index > 0 { Rectangle().fill(palette.hairline.color).frame(width: 1 / displayScale) }
        }
      }
    }
  }
}

/// A weather code's SF Symbol, sized for the card's rows.
struct WeatherGlyph: View {
  let code: Int
  let isDay: Bool
  var size: CGFloat = 17
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let symbol = WeatherCardModel.symbol(forCode: code, isDay: isDay)
    let ink = palette.textPrimary.color, sun = WeatherSky.sunYellow.color, rain = WeatherSky.rainBlue.color
    // Outline symbols ignore multicolor, so their layers are coloured here: cloud, then sun or rain.
    let (secondary, tertiary): (Color, Color) = switch symbol {
    case "cloud.sun", "cloud.sun.rain": (sun, rain)
    case "cloud.bolt.rain": (sun, rain)
    case "cloud.rain", "cloud.drizzle", "cloud.heavyrain", "cloud.moon.rain", "cloud.snow": (rain, rain)
    default: (palette.textSecondary.color, rain)
    }
    Image(systemName: symbol)
      .font(EnigmaTypography.symbol(size))
      .symbolRenderingMode(.palette)
      .foregroundStyle(symbol == "sun.max" ? sun : ink, secondary, tertiary)
      .frame(height: size * 1.35)
      .accessibilityHidden(true)
  }
}

/// A drop and "80%": the chance of rain under an hour or a day.
struct RainChanceLabel: View {
  let percent: Int
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "drop")
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(WeatherSky.rainBlue.color.opacity(percent < 20 ? 0.45 : 1))
      Text("\(percent)%")
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textSecondary.color)
    }
    .lineLimit(1)
  }
}

/// The animated sky behind the card's header: slow loops at 24 fps, paused off screen and
/// under Reduce Motion.
struct WeatherSkyView: View {
  let model: WeatherCardModel
  var time: Double?
  var paused: Bool

  var body: some View {
    Group {
      if let time {
        sky(at: time, animated: true)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { context in
          sky(at: context.date.timeIntervalSinceReferenceDate, animated: !paused)
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func sky(at time: Double, animated: Bool) -> some View {
    Canvas { context, size in
      WeatherSky.draw(model, at: time, animated: animated, in: size, context: &context)
    }
  }
}
