import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// F36 prototype: renders the weather card and the character's weather costumes from fixture
/// forecasts, in Paper and Ink, to PNGs for review.
@MainActor
final class WeatherCardSnapshotTests: XCTestCase {
  static let outputDirectory = URL(fileURLWithPath: "/private/tmp/claude-501/EnigmaWeatherCards", isDirectory: true)

  func testCostumeFollowsTheWeather() {
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.clear, light: .day), .sunglasses)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.partlyCloudy, light: .twilight), .sunglasses)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.clear, light: .night), .nightcap)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.rain, light: .day), .umbrella)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.storm, light: .night), .umbrellaInsideOut)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.snow, light: .day), .woollyHat)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.fog, light: .day), .scarf)
  }

  func testCardReadsAsOneSummary() {
    XCTAssertEqual(WeatherCardExamples.lisbon.cards[0].accessibilityLabel,
                   "Lisbon, 18 degrees, partly cloudy, high 21, low 14")
    XCTAssertEqual(WeatherCardModel.sky(forCode: 61), .rain)
    XCTAssertEqual(WeatherCardModel.sky(forCode: 86), .snow)
    XCTAssertEqual(WeatherCardExamples.lisbon.cards[0].degrees(-3.6), "−4°")
  }

  func testRendersExamples() throws {
    try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
    for appearance in [EnigmaAppearance.paper, .ink] {
      for example in WeatherCardExamples.all {
        try write(ReplyPreview(example: example), appearance: appearance, name: example.name)
      }
      try write(CostumeLineUp(), appearance: appearance, name: "costumes")
      try write(SkyGrid(), appearance: appearance, name: "skies")
    }
    print("Weather card snapshots: \(Self.outputDirectory.path)")
  }

  private func write(_ view: some View, appearance: EnigmaAppearance, name: String) throws {
    let renderer = ImageRenderer(content: view.enigmaTheme(appearance))
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage, name)
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: Self.outputDirectory.appendingPathComponent("\(name)-\(appearance.rawValue).png"))
  }
}

// MARK: Fixtures

struct WeatherCardExample {
  let name: String
  let question: String
  let cards: [WeatherCardModel]
  let reply: String
  let seconds: String
}

enum WeatherCardExamples {
  typealias Hour = WeatherCardModel.Hour
  typealias Day = WeatherCardModel.Day

  static func hours(_ rows: [(String, Int, Bool, Double, Int)]) -> [Hour] {
    rows.map { Hour(time: $0.0, code: $0.1, isDay: $0.2, temperature: $0.3, rainChance: $0.4) }
  }

  static let lisbon = WeatherCardExample(
    name: "1-lisbon-now", question: "What's the weather like in Lisbon right now?",
    cards: [WeatherCardModel(place: "Lisbon", caption: "Now · Tue 3 Nov", code: 2, light: .day, content: .now(
      temperature: 18, feelsLike: 17, high: 21, low: 14, rainChance: 10, wind: 14,
      hours: hours([("15:00", 2, true, 19, 10), ("16:00", 1, true, 19, 5), ("17:00", 1, true, 18, 0),
                    ("18:00", 0, false, 17, 0), ("19:00", 0, false, 16, 0), ("20:00", 1, false, 15, 0)])))],
    reply: "Mild and bright, with the sun breaking through now and then. It stays dry all evening, so a light jacket for later is all you need.",
    seconds: "1.9 s")

  static let london = WeatherCardExample(
    name: "2-london-rain", question: "Do I need an umbrella in London today?",
    cards: [WeatherCardModel(place: "London", caption: "Now · Tue 3 Nov", code: 61, light: .day, content: .now(
      temperature: 11, feelsLike: 8, high: 12, low: 7, rainChance: 80, wind: 24,
      hours: hours([("15:00", 63, true, 11, 85), ("16:00", 61, true, 11, 75), ("17:00", 61, false, 10, 60),
                    ("18:00", 3, false, 10, 30), ("19:00", 3, false, 9, 15), ("20:00", 2, false, 9, 10)])))],
    reply: "Yes, take one. Light rain keeps going until about 17:00, and the wind makes 11° feel more like 8°. It dries up this evening.",
    seconds: "2.2 s")

  static let reykjavik = WeatherCardExample(
    name: "3-reykjavik-night", question: "Will it be clear in Reykjavík tonight?",
    cards: [WeatherCardModel(place: "Reykjavík", caption: "Now · Tue 3 Nov", code: 0, light: .night, content: .now(
      temperature: 2, feelsLike: -3, high: 4, low: -1, rainChance: 0, wind: 18,
      hours: hours([("22:00", 0, false, 1, 0), ("23:00", 0, false, 1, 0), ("00:00", 1, false, 0, 0),
                    ("01:00", 1, false, 0, 0), ("02:00", 2, false, -1, 5), ("03:00", 2, false, -1, 5)])))],
    reply: "Yes, clear skies all night, so it's a good night for stargazing. Wrap up well: the wind makes it feel like −3°.",
    seconds: "1.7 s")

  static let porto = WeatherCardExample(
    name: "4-porto-sunset", question: "Is it nice in Porto this evening?",
    cards: [WeatherCardModel(place: "Porto", caption: "Now · Tue 3 Nov", code: 1, light: .twilight, content: .now(
      temperature: 16, feelsLike: 16, high: 19, low: 11, rainChance: 0, wind: 9,
      hours: hours([("18:00", 0, false, 15, 0), ("19:00", 0, false, 14, 0), ("20:00", 0, false, 13, 0),
                    ("21:00", 1, false, 13, 0), ("22:00", 1, false, 12, 0), ("23:00", 2, false, 12, 0)])))],
    reply: "Lovely: calm and dry, with the sun setting at 17:31. It cools off quickly after dark, so bring a layer if you're staying out.",
    seconds: "1.8 s")

  static let oslo = WeatherCardExample(
    name: "5-oslo-tomorrow", question: "What will tomorrow be like in Oslo?",
    cards: [WeatherCardModel(place: "Oslo", caption: "Tomorrow · Wed 4 Nov", code: 73, light: .day, content: .day(
      high: 1, low: -4, rainChance: 70, precipitation: 6, wind: 15, sunset: "16:12",
      hours: hours([("06:00", 71, false, -3, 40), ("09:00", 73, true, -2, 70), ("12:00", 73, true, 0, 75),
                    ("15:00", 71, true, 1, 55), ("18:00", 3, false, -1, 20), ("21:00", 3, false, -3, 10)])))],
    reply: "Snowy for most of the day, heaviest around midday, and it barely gets above freezing. Wear boots and a warm coat, and allow extra time if you're travelling.",
    seconds: "2.0 s")

  static let miami = WeatherCardExample(
    name: "6-miami-storm", question: "Is there a storm in Miami right now?",
    cards: [WeatherCardModel(place: "Miami", caption: "Now · Tue 3 Nov", code: 95, light: .day, content: .now(
      temperature: 27, feelsLike: 31, high: 30, low: 24, rainChance: 90, wind: 32,
      hours: hours([("15:00", 95, true, 27, 90), ("16:00", 95, true, 26, 85), ("17:00", 81, true, 26, 60),
                    ("18:00", 80, true, 25, 40), ("19:00", 3, false, 25, 20), ("20:00", 2, false, 25, 10)])))],
    reply: "Yes, thunderstorms are passing through this afternoon, with heavy downpours and strong gusts. It should ease by 18:00, so stay indoors until then if you can.",
    seconds: "2.1 s")

  static let weekend = WeatherCardExample(
    name: "7-weekend-two-places", question: "Lisbon or Porto this weekend?",
    cards: [
      WeatherCardModel(place: "Lisbon", caption: "This weekend · Sat 7 – Sun 8 Nov", code: 0, light: .day, content: .days([
        Day(weekday: "Sat", code: 0, high: 23, low: 15, rainChance: 0, wind: 12),
        Day(weekday: "Sun", code: 2, high: 22, low: 14, rainChance: 10, wind: 15),
      ])),
      WeatherCardModel(place: "Porto", caption: "This weekend · Sat 7 – Sun 8 Nov", code: 3, light: .day, content: .days([
        Day(weekday: "Sat", code: 3, high: 18, low: 12, rainChance: 30, wind: 18),
        Day(weekday: "Sun", code: 63, high: 16, low: 11, rainChance: 85, wind: 26),
      ])),
    ],
    reply: "Lisbon is the better bet: sunny on Saturday and only a few clouds on Sunday. Porto turns wet on Sunday, so save it for another weekend.",
    seconds: "2.6 s")

  static let berlin = WeatherCardExample(
    name: "8-berlin-week", question: "What's the weather in Berlin this week?",
    cards: [WeatherCardModel(place: "Berlin", caption: "This week · Tue 3 – Mon 9 Nov", code: 3, light: .day, content: .days([
      Day(weekday: "Today", code: 3, high: 9, low: 4, rainChance: 20, wind: 16),
      Day(weekday: "Wed", code: 61, high: 8, low: 5, rainChance: 75, wind: 22),
      Day(weekday: "Thu", code: 80, high: 9, low: 3, rainChance: 60, wind: 19),
      Day(weekday: "Fri", code: 2, high: 10, low: 2, rainChance: 10, wind: 11),
      Day(weekday: "Sat", code: 0, high: 11, low: 1, rainChance: 0, wind: 8),
      Day(weekday: "Sun", code: 45, high: 7, low: 2, rainChance: 10, wind: 5),
      Day(weekday: "Mon", code: 71, high: 3, low: -1, rainChance: 55, wind: 14),
    ]))],
    reply: "A grey, damp start, with rain on Wednesday and showers on Thursday. Friday and Saturday are the bright days, then it turns foggy and colder, with a chance of light snow on Monday.",
    seconds: "2.4 s")

  static let all = [lisbon, london, reykjavik, porto, oslo, miami, weekend, berlin]
}

// MARK: Previews

/// The character at rest in a slot, wearing a costume. The canvas is larger than the slot so
/// the antenna, umbrella and legs aren't clipped, as the chat's stage draws past its slots.
private struct CostumedCharacter: View {
  let costume: EnigmaCharacterCostume?
  let slot: CGFloat
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height * 0.56)
      let frame = EnigmaCharacterModel.stillFrame(on: .init(center: center, size: slot))
      EnigmaCharacterCostume.draw(frame, wearing: costume, palette: palette, in: &context)
    }
    .frame(width: slot * 2.6, height: slot * 2.6)
    .frame(width: slot, height: slot)
  }
}

/// A chat reply as the window draws it: the question, the character in its 30 pt slot, the
/// activity line, the cards, the serif reply and its meta line.
private struct ReplyPreview: View {
  let example: WeatherCardExample
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let first = example.cards[0]
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Spacer(minLength: 120)
        Text(example.question)
          .font(EnigmaTypography.ui(14))
          .foregroundStyle(palette.textPrimary.color)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .background(palette.userBubble.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      HStack(alignment: .top, spacing: 10) {
        CostumedCharacter(costume: .forWeather(first.sky, light: first.light), slot: 30)
          .padding(.top, 12)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Text("›").foregroundStyle(palette.accentText.color)
            Text("Checked the weather")
            Text("· Open-Meteo").opacity(0.75)
          }
          .font(EnigmaTypography.mono(12))
          .foregroundStyle(palette.textTertiary.color)
          ForEach(example.cards.indices, id: \.self) { index in
            let card = example.cards[index]
            WeatherCardView(model: card, time: card.sky == .storm ? WeatherSky.strikeTime(for: card) : 6)
          }
          Text(example.reply)
            .font(EnigmaTypography.reply)
            .lineSpacing(5)
            .foregroundStyle(palette.textPrimary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
          Text("gemini-3.6-flash · cloud · \(example.seconds)")
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
        }
      }
    }
    .padding(.horizontal, 26)
    .padding(.top, 50)
    .padding(.bottom, 22)
    .frame(width: 640)
    .background(palette.background.color)
  }
}

/// Every costume, large, with the weather that brings it.
private struct CostumeLineUp: View {
  @Environment(\.enigmaPalette) private var palette
  private let looks: [(EnigmaCharacterCostume?, String)] = [
    (nil, "No card"), (.sunglasses, "Sun"), (.umbrella, "Rain"), (.umbrellaInsideOut, "Storm"),
    (.woollyHat, "Snow"), (.scarf, "Grey or fog"), (.nightcap, "Clear night"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 8) {
        ForEach(looks.indices, id: \.self) { index in
          VStack(spacing: 8) {
            CostumedCharacter(costume: looks[index].0, slot: 72)
              .frame(width: 112, height: 150)
            Text(looks[index].1)
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textSecondary.color)
          }
        }
      }
      HStack(alignment: .bottom, spacing: 26) {
        ForEach(looks.indices.dropFirst(), id: \.self) { index in
          CostumedCharacter(costume: looks[index].0, slot: 30)
            .frame(width: 60, height: 70)
        }
        Text("at the chat's 30 pt")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
          .padding(.bottom, 12)
      }
      .padding(.leading, 26)
    }
    .padding(24)
    .background(palette.background.color)
  }
}

/// Each sky at day, twilight and night, as the card's header.
private struct SkyGrid: View {
  @Environment(\.enigmaPalette) private var palette
  private let codes = [0, 2, 3, 45, 63, 73, 95]

  var body: some View {
    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
      ForEach(codes, id: \.self) { code in
        GridRow {
          ForEach(WeatherCardModel.Light.allCases, id: \.self) { light in
            let model = WeatherCardModel(place: "Sky \(code)", caption: "", code: code, light: light,
                                         content: .days([]))
            VStack(alignment: .leading, spacing: 4) {
              WeatherSkyView(model: model, time: code >= 95 ? WeatherSky.strikeTime(for: model) : 6, paused: false)
                .frame(width: 200, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { EnigmaEdgeStroke(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
              Text("\(WeatherCardModel.condition(forCode: code)) · \(String(describing: light))")
                .font(EnigmaTypography.mono(11))
                .foregroundStyle(palette.textSecondary.color)
            }
          }
        }
      }
    }
    .padding(24)
    .background(palette.background.color)
  }
}
