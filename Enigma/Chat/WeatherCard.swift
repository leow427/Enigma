import SwiftUI

// The card above a weather answer (F36, docs/design/f36-weather-card/). Its model,
// `WeatherCardModel`, is built from the Open-Meteo forecast in WeatherLookup.swift.

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
  @State private var isWindowVisible = true

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    VStack(spacing: 0) {
      header
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          WeatherSkyView(model: model, time: time,
                         paused: !WeatherSkyView.animates(reduceMotion: reduceMotion, isOnScreen: isOnScreen,
                                                          isWindowVisible: isWindowVisible))
        }
      Rectangle().fill(palette.border.color).frame(height: 1 / displayScale)
      details
        .frame(maxWidth: .infinity)
        .background(palette.surface.color)
    }
    .clipShape(shape)
    .overlay { EnigmaEdgeStroke(shape: shape) }
    .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    .background(EnigmaWindowVisibilityReader { isWindowVisible = $0 })
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.accessibilityLabel)
    .enigmaTestMarker("Weather card")
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
        stats([("Feels like", model.degrees(feelsLike)), (model.precipitationWord, model.percent(rainChance)),
               ("Wind", model.speed(wind))])
        if !hours.isEmpty { hourly(hours) }
      }
      .padding(.horizontal, 16)
      .padding(.top, 11)
      .padding(.bottom, 12)
    case let .day(_, _, rainChance, amount, wind, sunset, hours):
      VStack(spacing: 10) {
        let fall = model.percent(rainChance) + (amount.map { $0 > 0 ? " · " + model.amount($0) : "" } ?? "")
        stats([(model.precipitationWord, fall), ("Wind", model.speed(wind))]
              + (sunset.map { [("Sunset", $0)] } ?? []))
        if !hours.isEmpty { hourly(hours) }
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
  let percent: Int?
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "drop")
        .font(EnigmaTypography.symbol(8.5))
        .foregroundStyle(WeatherSky.rainBlue.color.opacity((percent ?? 0) < 20 ? 0.45 : 1))
      Text(percent.map { "\($0)%" } ?? "–")
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textSecondary.color)
    }
    .lineLimit(1)
  }
}

/// The animated sky behind the card's header: slow loops at 24 fps, paused off screen, while
/// the window is hidden, and under Reduce Motion.
struct WeatherSkyView: View {
  let model: WeatherCardModel
  var time: Double?
  var paused: Bool

  static func animates(reduceMotion: Bool, isOnScreen: Bool, isWindowVisible: Bool) -> Bool {
    !reduceMotion && isOnScreen && isWindowVisible
  }

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
    .enigmaTestMarker(paused ? "Weather sky still" : "Weather sky moving")
    .accessibilityHidden(true)
  }

  private func sky(at time: Double, animated: Bool) -> some View {
    Canvas { context, size in
      WeatherSky.draw(model, at: time, animated: animated, in: size, context: &context)
    }
  }
}
