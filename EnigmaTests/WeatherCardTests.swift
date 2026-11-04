import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// F36: the weather card above weather answers, and the character's weather costumes.
@MainActor
final class WeatherCardTests: XCTestCase {
  /// 2026-10-27 15:30 in Chicago (UTC−5), the fixture's `current.time`. The fixture is a Tuesday;
  /// its 7 days run to Monday 2 November, with sunset at 17:51 today.
  nonisolated private static let fixtureNow = Date(timeIntervalSince1970: 1_793_133_000)
  private static let hour: TimeInterval = 3_600

  private var root: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("WeatherCardTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    suiteName = "WeatherCardTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Fixtures

  /// The Chicago fixture, changed by `edit` on its JSON.
  static func forecast(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> WeatherForecast {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SearchFixture.data("open-meteo-chicago.json")) as? [String: Any])
    edit(&json)
    return try JSONDecoder().decode(WeatherForecast.self, from: JSONSerialization.data(withJSONObject: json))
  }

  /// Sets `key` in the fixture's `section` ("current", "daily", "hourly", "current_units").
  static func set(_ json: inout [String: Any], _ section: String, _ key: String, _ value: Any) {
    var part = json[section] as? [String: Any] ?? [:]
    part[key] = value
    json[section] = part
  }

  private func card(_ days: WeatherDays = .today, now: Date = fixtureNow, place: String = "Chicago, Illinois, United States",
                    _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> WeatherCardModel {
    try XCTUnwrap(WeatherCardModel(forecast: Self.forecast(edit), placeName: place, days: days, now: now))
  }

  // MARK: The card from the forecast

  func testTodaysCardIsNowWithTheNextSixHours() throws {
    let card = try card { Self.set(&$0, "current", "is_day", 1) }
    XCTAssertEqual(card.place, "Chicago")
    XCTAssertEqual(card.caption, "Now · Tue 27 Oct")
    XCTAssertEqual(card.sky, .overcast)
    XCTAssertEqual(card.light, .day)
    XCTAssertEqual(card.units, .us, "Units follow the forecast's")
    guard case let .now(temperature, feelsLike, high, low, rainChance, wind, hours) = card.content else {
      return XCTFail("Today shows now")
    }
    XCTAssertEqual([temperature, feelsLike, high, low], [63.1, 62.9, 63.7, 52.8])
    XCTAssertEqual(rainChance, 6)
    XCTAssertEqual(wind, 6.0)
    XCTAssertEqual(hours.map(\.time), ["4 PM", "5 PM", "6 PM", "7 PM", "8 PM", "9 PM"])
    XCTAssertEqual(card.speed(wind), "6 mph")
    XCTAssertEqual(card.accessibilityLabel, "Chicago, 63 degrees, overcast, high 64, low 53")
  }

  func testNightComesFromIsDayAndTwilightFromTheSun() throws {
    let night = try card(now: Self.fixtureNow + 5 * Self.hour) {
      Self.set(&$0, "current", "is_day", 0)
      Self.set(&$0, "current", "weather_code", 0)
    }
    XCTAssertEqual(night.light, .night)
    XCTAssertEqual(night.sky, .clear)
    // 17:40 is 11 minutes before sunset.
    let dusk = try card(now: Self.fixtureNow + 2 * Self.hour + 10 * 60) {
      Self.set(&$0, "current", "is_day", 1)
      Self.set(&$0, "current", "weather_code", 1)
    }
    XCTAssertEqual(dusk.light, .twilight)
    // Without is_day, the sun's times decide.
    XCTAssertEqual(try card(now: Self.fixtureNow + 5 * Self.hour).light, .night)
    XCTAssertEqual(try card().light, .day)
  }

  func testRainSnowAndStormSkies() throws {
    XCTAssertEqual(try card { Self.set(&$0, "current", "weather_code", 61) }.sky, .rain)
    XCTAssertEqual(try card { Self.set(&$0, "current", "weather_code", 75) }.sky, .snow)
    XCTAssertEqual(try card { Self.set(&$0, "current", "weather_code", 95) }.sky, .storm)
    XCTAssertEqual(try card { Self.set(&$0, "current", "weather_code", 45) }.sky, .fog)
    XCTAssertEqual(try card { Self.set(&$0, "current", "weather_code", 75) }.precipitationWord, "Snow")
  }

  func testTomorrowShowsItsHighLowAndDaytimeHours() throws {
    let card = try card(.tomorrow)
    XCTAssertEqual(card.caption, "Tomorrow · Wed 28 Oct")
    XCTAssertEqual(card.light, .day)
    guard case let .day(high, low, rainChance, amount, wind, sunset, hours) = card.content else {
      return XCTFail("A later day shows its high and low")
    }
    XCTAssertEqual([high, low], [74.6, 50.7])
    XCTAssertEqual(rainChance, 3)
    XCTAssertEqual(amount, 0)
    XCTAssertEqual(wind, 11.0)
    XCTAssertEqual(sunset, "5:49 PM")
    XCTAssertEqual(hours.map(\.time), ["6 AM", "9 AM", "12 PM", "3 PM", "6 PM", "9 PM"],
                   "The forecast's 168 hours cover tomorrow's strip")
    XCTAssertTrue(card.accessibilityLabel.hasPrefix("Chicago, Tomorrow, Wed 28 Oct, overcast, high 75, low 51"))
  }

  func testSnowyDayShowsSnowfallInCentimetres() throws {
    let card = try card(.tomorrow) {
      Self.set(&$0, "current_units", "temperature_2m", "°C")
      var codes = ($0["daily"] as? [String: Any])?["weather_code"] as? [Int] ?? []
      codes[1] = 73
      Self.set(&$0, "daily", "weather_code", codes)
      Self.set(&$0, "daily", "snowfall_sum", [0, 6.2, 0, 0, 0, 0, 0])
    }
    XCTAssertEqual(card.units, .metric)
    XCTAssertEqual(card.sky, .snow)
    guard case let .day(_, _, _, amount, _, _, _) = card.content else { return XCTFail("One day") }
    XCTAssertEqual(amount.map(card.amount), "6 cm")
    XCTAssertEqual(card.amount(0.4), "0.4 cm")
    XCTAssertEqual(card.speed(14.2), "14 km/h")
    XCTAssertEqual(card.degrees(-3.6), "−4°")
  }

  func testWeekendAndWeekAreColumns() throws {
    let weekend = try card(.weekend)
    XCTAssertEqual(weekend.caption, "This weekend · Sat 31 Oct – Sun 1 Nov")
    guard case .days(let days) = weekend.content else { return XCTFail("A weekend is columns") }
    XCTAssertEqual(days.map(\.weekday), ["Sat", "Sun"])
    XCTAssertEqual(days.map(\.code), [51, 51])
    XCTAssertEqual(weekend.code, 51, "The sky is the first day's")

    let week = try card(.week)
    XCTAssertEqual(week.caption, "This week · Tue 27 Oct – Mon 2 Nov")
    guard case .days(let all) = week.content else { return XCTFail("A week is columns") }
    XCTAssertEqual(all.map(\.weekday), ["Today", "Wed", "Thu", "Fri", "Sat", "Sun", "Mon"])
    XCTAssertTrue(week.accessibilityLabel.hasPrefix("Chicago, This week, Tue 27 Oct – Mon 2 Nov. Today, overcast, high 64, low 53"))
  }

  func testDateRangesAreClampedToTheForecast() throws {
    let range = try card(.dates(start: "2026-10-29", end: "2026-10-30"))
    XCTAssertEqual(range.caption, "Thu 29 – Fri 30 Oct")
    let overlapping = try card(.dates(start: "2026-11-01", end: "2026-11-09"))
    guard case .days(let days) = overlapping.content else { return XCTFail("Two days are left") }
    XCTAssertEqual(days.map(\.weekday), ["Sun", "Mon"])
    XCTAssertNil(WeatherCardModel(forecast: try Self.forecast(), placeName: "Chicago",
                                  days: .dates(start: "2026-11-05", end: "2026-11-08"), now: Self.fixtureNow),
                 "A range past the forecast has no card")
    XCTAssertEqual(try card(.dates(start: "2026-10-27", end: "2026-10-27")).caption, "Now · Tue 27 Oct")
    XCTAssertEqual(try card(.weekday(6)).caption, "Fri 30 Oct")
  }

  func testTimeWordsPickTheDays() {
    XCTAssertEqual(WeatherDays(question: "What will tomorrow be like in Oslo?"), .tomorrow)
    XCTAssertEqual(WeatherDays(question: "Lisbon or Porto this weekend?"), .weekend)
    XCTAssertEqual(WeatherDays(question: "What's the weather in Berlin this week?"), .week)
    XCTAssertEqual(WeatherDays(question: "Will it rain on Friday?"), .weekday(6))
    XCTAssertEqual(WeatherDays(question: "What's the weather like in Lisbon right now?"), .today)
    XCTAssertEqual(WeatherDays(question: "Tomorrow's forecast"), .tomorrow)
    XCTAssertEqual(WeatherDays(question: "What's this weekend's forecast in Lisbon?"), .weekend)
    XCTAssertEqual(WeatherDays(question: "this week's weather in Berlin"), .week)
    XCTAssertEqual(WeatherDays(question: "Tomorrow’s weather in Oslo"), .tomorrow)
    XCTAssertEqual(WeatherDays(question: "Weekly weather in Oslo"), .today, "Not a week: no word \"week\"")
  }

  // MARK: get_weather

  private final class Cards: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WeatherCardModel] = []
    var values: [WeatherCardModel] { lock.withLock { stored } }
    func add(_ card: WeatherCardModel) { lock.withLock { stored.append(card) } }
  }

  private func weatherTool(_ weather: FakeWeather = FakeWeather(), cards: Cards) -> WeatherTool {
    WeatherTool(weather: weather, geocoder: FakeGeocoder((PlacesAndWeatherFixtures.chicago, "Chicago, Illinois, United States")),
                location: { nil }, units: { .us }, mayQuery: { _ in true }, onSources: { _ in },
                onCard: { cards.add($0) }, now: { Self.fixtureNow })
  }

  private func json(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func testGetWeatherOffersADateRange() throws {
    let definition = try XCTUnwrap(weatherTool(cards: Cards()).definitions.first)
    XCTAssertEqual(Set(definition.properties.keys), ["place", "start_date", "end_date"])
    XCTAssertEqual(definition.required, [])
  }

  /// F32's warm-up reads the tools into the prompt cache while the user types, so the definition
  /// must be the same at send time: nothing in it follows the clock.
  func testGetWeatherDefinitionDoesNotFollowTheClock() throws {
    func definition(_ now: Date) throws -> AgentToolDefinition {
      try XCTUnwrap(WeatherTool(weather: FakeWeather(), geocoder: FakeGeocoder(), location: { nil }, units: { .metric },
                                mayQuery: { _ in true }, onSources: { _ in }, now: { now }).definitions.first)
    }
    let today = try definition(Self.fixtureNow), later = try definition(Self.fixtureNow + 3 * 24 * Self.hour)
    XCTAssertEqual(today.description, later.description)
    XCTAssertEqual(today.properties, later.properties)
  }

  func testGetWeatherWithoutARangeShowsToday() async throws {
    let cards = Cards()
    let result = await weatherTool(cards: cards).execute(name: "get_weather", arguments: .object(["place": .string("Chicago")]))
    XCTAssertTrue(result.success)
    XCTAssertEqual(cards.values.map(\.caption), ["Now · Tue 27 Oct"])
    let answer = try json(result.text)
    XCTAssertNotNil(answer["forecast"] as? [String: Any], "The model still gets the whole forecast")
    XCTAssertEqual(answer["card"] as? String, "A weather card above your reply already shows the figures for Chicago, Now, Tue 27 Oct. Write a short, friendly description under it: what it's like, and what to bring or plan for. Don't recite every figure.")
  }

  func testGetWeatherWithARangeShowsThoseDays() async throws {
    let cards = Cards()
    let result = await weatherTool(cards: cards).execute(name: "get_weather", arguments: .object([
      "place": .string("Chicago"), "start_date": .string("2026-10-31"), "end_date": .string("2026-11-01")]))
    XCTAssertTrue(result.success)
    XCTAssertEqual(cards.values.map(\.caption), ["This weekend · Sat 31 Oct – Sun 1 Nov"])
    let single = Cards()
    _ = await weatherTool(cards: single).execute(name: "get_weather", arguments: .object([
      "place": .string("Chicago"), "start_date": .string("2026-10-28")]))
    XCTAssertEqual(single.values.map(\.caption), ["Tomorrow · Wed 28 Oct"])
  }

  func testGetWeatherPastTheForecastShowsNoCard() async throws {
    let cards = Cards()
    let result = await weatherTool(cards: cards).execute(name: "get_weather", arguments: .object([
      "place": .string("Chicago"), "start_date": .string("2026-11-10"), "end_date": .string("2026-11-12")]))
    XCTAssertTrue(result.success, "The forecast still answers")
    XCTAssertTrue(cards.values.isEmpty)
    XCTAssertEqual(try json(result.text)["card"] as? String,
                   "No weather card is shown: those dates are outside the forecast, which covers 2026-10-27 to 2026-11-02.")
  }

  func testGetWeatherRejectsBadDates() async {
    for arguments: [String: CodexValue] in [["start_date": .string("tomorrow")], ["end_date": .string("2026-10-28")],
                                            ["start_date": .string("2026-10-29"), "end_date": .string("2026-10-28")],
                                            ["start_date": .string("2026-02-30")], ["start_date": .number(20261028)]] {
      let cards = Cards()
      let result = await weatherTool(cards: cards).execute(name: "get_weather", arguments: .object(arguments))
      XCTAssertFalse(result.success, "\(arguments)")
      XCTAssertTrue(result.text.hasPrefix("Invalid tool arguments"), "\(arguments)")
      XCTAssertTrue(cards.values.isEmpty)
    }
  }

  func testAFailedLookupShowsNoCard() async {
    let cards = Cards()
    let result = await weatherTool(FakeWeather(error: WeatherLookupError.timedOut), cards: cards)
      .execute(name: "get_weather", arguments: .object(["place": .string("Chicago")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(cards.values.isEmpty)
  }

  // MARK: The chat

  private static let weatherSource = WebSearchSource(title: "Open-Meteo forecast", url: URL(string: "https://open-meteo.com/")!)

  private func weatherResult(_ card: WeatherCardModel?) -> WebSearchResult {
    WebSearchResult(source: Self.weatherSource, snippets: ["Forecast for Chicago (local times)."], site: "Open-Meteo",
                    kind: .weather, weatherCard: card)
  }

  private func makeSmallChat(results: [WebSearchResult], engine: MapCardEngine,
                             store: ChatSessionStore? = nil) -> (LocalChatViewModel, NativeSearchProvider) {
    let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: nil), defaults: defaults)
    let search = NativeSearchProvider(results: results)
    let cloud = MapCardCloud()
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
                                  toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
                                  visionEngine: MapCardVision(),
                                  cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud),
                                  webSearch: search, searchSettings: settings,
                                  sessionStore: store ?? ChatSessionStore(applicationSupportDirectory: root),
                                  nativeToolsEnabled: false)
    return (chat, search)
  }

  private func waitUntil(_ description: String, timeout: Duration = .seconds(3), file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(description)", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func testWordingRouteShowsTheCardWhileTheReplyStreamsAndNeverSavesIt() async throws {
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let engine = MapCardEngine(reply: "Cool and grey; bring a jacket.", holds: true)
    let today = try card()
    let (chat, search) = makeSmallChat(results: [weatherResult(today)], engine: engine, store: store)
    await chat.refreshInstalledModel()
    chat.submit("/search weather in Chicago this weekend", searchEnabled: true)
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Cool and grey; bring a jacket." }
    XCTAssertEqual(search.requests.last?.weatherDays, .weekend, "The days come from the typed question")
    XCTAssertEqual(chat.messages.last?.weatherCards, [today], "The card is there before the reply finishes")
    await engine.release()
    try await waitUntil("the request to end") { chat.activeRequest == nil && !chat.isBusy }
    XCTAssertEqual(chat.messages.last?.weatherCards, [today])
    await chat.sessionWriter.waitForPendingWrites()
    let saved = try XCTUnwrap(store.load().first)
    XCTAssertNil(saved.messages.last?.weatherCards, "A chat reopened from Recents shows the text only")
    XCTAssertEqual(saved.messages.last?.content, "Cool and grey; bring a jacket.")
  }

  /// A capable model's get_weather puts its card on the reply; a failed lookup puts none.
  func testToolLookupPutsItsCardOnTheReply() async throws {
    for fails in [false, true] {
      let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: nil), defaults: defaults)
      let chat = LocalChatViewModel(
        engine: NativeTestEngine(model: NativeToolRequestTests.flaggedModel),
        selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
        toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
        localToolRuntime: { _ in true },
        fileInference: NativeScriptedInference(steps: [
          .call("get_weather", #"{"place":"Chicago","start_date":"2026-10-28"}"#), .text("Dry and mild tomorrow.")]),
        webSearch: NativeSearchProvider(results: NativeToolRequestTests.searchResults),
        searchSettings: settings,
        sessionStore: ChatSessionStore(applicationSupportDirectory: root),
        nativeToolsEnabled: true)
      chat.weatherLookup = fails ? FakeWeather(error: WeatherLookupError.timedOut) : FakeWeather()
      chat.weatherGeocoder = FakeGeocoder((PlacesAndWeatherFixtures.chicago, "Chicago, Illinois, United States"))
      await chat.refreshInstalledModel()
      let prompt = "/search weather in Chicago tomorrow"
      chat.submitNative(prompt, route: NativeToolRequestTests.localRoute, plan: chat.nativeToolPlan(for: ComposerCommands(prompt)))
      try await waitUntil("the reply") { chat.activeRequest == nil && !chat.isBusy && chat.messages.last?.role == .assistant }
      XCTAssertEqual(chat.messages.last?.content, "Dry and mild tomorrow.")
      XCTAssertEqual(chat.messages.last?.weatherCards?.map(\.caption), fails ? nil : ["Tomorrow · Wed 28 Oct"], "fails: \(fails)")
    }
  }

  func testWeatherCardsAreNeverEncoded() throws {
    var message = ChatMessage(role: .assistant, content: "Mild.")
    message.weatherCards = [try card()]
    let data = try JSONEncoder().encode(message)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("weather"))
    XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: data).weatherCards)
  }

  func testOneCardPerPlaceAndNoneForARequestThatEnded() async throws {
    let engine = MapCardEngine(reply: "Lisbon is the better bet.", holds: true)
    let (chat, _) = makeSmallChat(results: [], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("hello there")
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Lisbon is the better bet." }
    let request = try XCTUnwrap(chat.activeRequest?.id)
    let replyID = try XCTUnwrap(chat.messages.last?.id)
    let lisbon = try card(.weekend, place: "Lisbon, Lisbon, Portugal")
    let porto = try card(.weekend, place: "Porto, Porto, Portugal")
    let portoAgain = try card(.week, place: "Porto, Porto, Portugal")
    chat.addWeatherCards([lisbon], messageID: replyID, requestID: request)
    chat.addWeatherCards([porto], messageID: replyID, requestID: request)
    chat.addWeatherCards([portoAgain], messageID: replyID, requestID: request)
    XCTAssertEqual(chat.messages.last?.weatherCards?.map(\.place), ["Lisbon", "Porto"])
    XCTAssertEqual(chat.messages.last?.weatherCards?.last, portoAgain, "A second lookup for a place replaces its card")
    _ = chat.stopStreaming()
    await engine.release()
    chat.addWeatherCards([try card()], messageID: replyID, requestID: request)
    XCTAssertEqual(chat.messages.last?.weatherCards?.count, 2, "A card for a request that ended is dropped")
  }

  /// The reply row draws the cards above its text, one per place, even while it streams.
  func testReplyShowsCardsAboveTheText() throws {
    var message = ChatMessage(role: .assistant, content: "Lisbon is the better bet.")
    message.weatherCards = [try card(.weekend, place: "Lisbon"), try card(.weekend, place: "Porto")]
    let reply = ConversationTranscript.Reply(id: message.id, message: message, activity: nil, isLatest: true,
                                             isInProgress: true)
    let hosting = host(EnigmaReplyView(reply: reply))
    let cards = markers("Weather card", in: hosting)
    XCTAssertEqual(cards.count, 2)
    let text = try XCTUnwrap(EnigmaMainWindowTests.Host.marker("Reply", in: hosting))
    let textTop = text.convert(text.bounds, to: nil).maxY
    for card in cards { XCTAssertGreaterThan(card.convert(card.bounds, to: nil).minY, textTop, "Cards sit above the text") }
    message.weatherCards = nil
    let saved = ConversationTranscript.Reply(id: message.id, message: message, activity: nil, isLatest: true, isInProgress: false)
    XCTAssertTrue(markers("Weather card", in: host(EnigmaReplyView(reply: saved))).isEmpty, "A reopened chat has no card")
  }

  // MARK: Motion

  func testReduceMotionStillsTheSky() throws {
    XCTAssertTrue(WeatherSkyView.animates(reduceMotion: false, isOnScreen: true, isWindowVisible: true))
    XCTAssertFalse(WeatherSkyView.animates(reduceMotion: true, isOnScreen: true, isWindowVisible: true))
    XCTAssertFalse(WeatherSkyView.animates(reduceMotion: false, isOnScreen: false, isWindowVisible: true))
    XCTAssertFalse(WeatherSkyView.animates(reduceMotion: false, isOnScreen: true, isWindowVisible: false))
    // The card as drawn: on screen in a scrolling chat, it moves; under Reduce Motion it's still.
    for reduceMotion in [false, true] {
      let card = try card { Self.set(&$0, "current", "weather_code", 61) }
      let hosting = host(ScrollView { WeatherCardView(model: card) }.frame(height: 400)
        .environment(\._accessibilityReduceMotion, reduceMotion))
      let expected = reduceMotion ? "Weather sky still" : "Weather sky moving"
      try awaitMarker(expected, in: hosting)
    }
    XCTAssertNil(EnigmaCharacterStage.costumeTime(.now, reduceMotion: true), "A still costume under Reduce Motion")
    XCTAssertNotNil(EnigmaCharacterStage.costumeTime(.now, reduceMotion: false))
  }

  private func awaitMarker(_ name: String, in view: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
    let deadline = Date().addingTimeInterval(2)
    while markers(name, in: view).isEmpty, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      view.layoutSubtreeIfNeeded()
    }
    XCTAssertFalse(markers(name, in: view).isEmpty, "Expected \(name)", file: file, line: line)
  }

  func testOnlyACardWhoseResultWasKeptShows() async throws {
    let engine = MapCardEngine(reply: "Mild.", holds: true)
    let (chat, _) = makeSmallChat(results: [], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("hello there")
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Mild." }
    let request = try XCTUnwrap(chat.activeRequest?.id)
    let replyID = try XCTUnwrap(chat.messages.last?.id)
    chat.addWeatherCards([weatherResult(try card())], kept: [], messageID: replyID, requestID: request)
    XCTAssertNil(chat.messages.last?.weatherCards, "Context fitting dropped the forecast, so no card")
    chat.addWeatherCards([weatherResult(try card())], kept: [Self.weatherSource], messageID: replyID, requestID: request)
    XCTAssertEqual(chat.messages.last?.weatherCards?.count, 1)
    _ = chat.stopStreaming()
    await engine.release()
  }

  /// The tour's weather stop shows a card above its example reply, and the character dresses for it.
  @MainActor
  func testTheToursWeatherReplyShowsACard() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeatherTour-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      sessionStore: ChatSessionStore(applicationSupportDirectory: root), nativeToolsEnabled: false)
    var script = TourScript.weather
    script.phaseDuration = 1
    let card = try XCTUnwrap(script.weatherCard)
    XCTAssertTrue(card.caption.hasPrefix("Tomorrow · "))
    await withCheckedContinuation { done in
      chat.playTourExchange(TourDemo(prompt: "will it rain in Chicago tomorrow?", script: script), onFinish: { done.resume() })
    }
    let reply = try XCTUnwrap(chat.messages.last)
    XCTAssertEqual(reply.weatherCards, [card])
    XCTAssertEqual(ConversationTranscript.costume(messages: chat.messages, activity: chat.activity), .sunglasses)
  }

  // MARK: The character's costume

  func testCostumeFollowsTheCondition() throws {
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.clear, light: .day), .sunglasses)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.partlyCloudy, light: .twilight), .sunglasses)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.clear, light: .night), .nightcap)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.rain, light: .day), .umbrella)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.storm, light: .night), .umbrellaInsideOut)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.snow, light: .day), .woollyHat)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.fog, light: .day), .scarf)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(.overcast, light: .night), .scarf)
    XCTAssertEqual(EnigmaCharacterCostume.forWeather(try card { Self.set(&$0, "current", "weather_code", 63) }), .umbrella)
  }

  func testTheLatestReplysFirstCardDressesTheCharacter() throws {
    let question = ChatMessage(role: .user, content: "Rain in Chicago?")
    var reply = ChatMessage(role: .assistant, content: "Yes, take one.")
    reply.weatherCards = [try card { Self.set(&$0, "current", "weather_code", 61) }, try card(place: "Sunny Place")]
    XCTAssertEqual(ConversationTranscript.costume(messages: [question, reply], activity: nil), .umbrella)
    let next = ChatMessage(role: .user, content: "Thanks")
    XCTAssertNil(ConversationTranscript.costume(messages: [question, reply, next],
                                                activity: AssistantActivity(id: UUID())),
                 "A newer request's reply takes it off")
    XCTAssertNil(ConversationTranscript.costume(messages: [question, ChatMessage(role: .assistant, content: "Hi")],
                                                activity: nil))
  }

  /// A change of outfit puffs smoke and hops, and the new outfit shows inside the smoke; taking it off does the same.
  func testChangingOutfitPuffsAndHops() {
    let slot = EnigmaCharacterModel.Slot(center: CGPoint(x: 60, y: 300), size: 30)
    let controller = EnigmaCharacterController(seed: 3)
    controller.move(to: "reply")
    var time = 10.0
    func frame() -> EnigmaCharacterFrame {
      time += 1.0 / 60
      return controller.frame(at: time, slots: ["reply": slot], targets: [:], reduceMotion: false)
    }
    for _ in 0..<120 { _ = frame() }
    for (outfit, previous) in [(EnigmaCharacterCostume.umbrella, nil), (nil, EnigmaCharacterCostume.umbrella),
                               (.sunglasses, nil), (.nightcap, .sunglasses)] {
      controller.costume = outfit
      let first = frame()
      XCTAssertFalse(first.puffs.isEmpty, "Smoke as \(String(describing: outfit)) goes on")
      XCTAssertEqual(controller.wornCostume, previous, "The old outfit until the smoke is thick")
      var lowest = Double(slot.center.y), swapped = false
      for _ in 0..<90 {
        lowest = min(lowest, Double(controller.model.position.y))
        _ = frame()
        swapped = swapped || controller.wornCostume == outfit
      }
      XCTAssertTrue(swapped)
      XCTAssertLessThan(lowest, Double(slot.center.y) - 10, "A little hop")
      XCTAssertEqual(Double(controller.model.position.y), Double(slot.center.y), accuracy: 0.5, "Back on the slot")
    }
  }

  /// Leaving a weather chat: the move and the costume change land in one update, and the smoke
  /// forms where the character now is.
  func testSmokeFormsWhereTheCharacterLands() {
    let reply = EnigmaCharacterModel.Slot(center: CGPoint(x: 60, y: 300), size: 30)
    let main = EnigmaCharacterModel.Slot(center: CGPoint(x: 400, y: 100), size: 92)
    let slots: [EnigmaCharacterSlotID: EnigmaCharacterModel.Slot] = ["reply": reply, "main": main]
    let controller = EnigmaCharacterController(seed: 3)
    controller.move(to: "reply")
    var time = 10.0
    for _ in 0..<120 { time += 1.0 / 60; _ = controller.frame(at: time, slots: slots, targets: [:], reduceMotion: false) }
    controller.costume = .umbrella
    for _ in 0..<60 { time += 1.0 / 60; _ = controller.frame(at: time, slots: slots, targets: [:], reduceMotion: false) }
    XCTAssertEqual(controller.wornCostume, .umbrella)
    controller.costume = nil
    controller.move(to: "main", .instant)
    time += 1.0 / 60
    let frame = controller.frame(at: time, slots: slots, targets: [:], reduceMotion: false)
    XCTAssertFalse(frame.puffs.isEmpty)
    for puff in frame.puffs {
      XCTAssertLessThan(hypot(puff.center.x - main.center.x, puff.center.y - main.center.y), 120, "Smoke at the new slot")
    }
  }

  func testUnderReduceMotionTheOutfitChangesAtOnce() {
    let slot = EnigmaCharacterModel.Slot(center: CGPoint(x: 60, y: 300), size: 30)
    let controller = EnigmaCharacterController(seed: 3)
    controller.move(to: "reply")
    _ = controller.frame(at: 1, slots: ["reply": slot], targets: [:], reduceMotion: true)
    controller.costume = .scarf
    XCTAssertEqual(controller.wornCostume, .scarf)
    let frame = controller.frame(at: 1.1, slots: ["reply": slot], targets: [:], reduceMotion: true)
    XCTAssertTrue(frame.puffs.isEmpty)
    XCTAssertEqual(Double(controller.model.position.y), Double(slot.center.y), accuracy: 0.01)
  }

  // MARK: Screenshots

  /// The docs' screenshots (docs/Web-Search.md): one day, several days, and the costumes with a
  /// change of outfit's smoke. Skipped unless `ENIGMA_SNAPSHOT_DIR` is set.
  func testSaveScreenshots() throws {
    let rainy = try card {
      Self.set(&$0, "current", "weather_code", 61)
      Self.set(&$0, "current", "is_day", 1)
    }
    let week = try card(.week)
    func reply(_ cards: [WeatherCardModel], _ text: String) -> some View {
      var message = ChatMessage(role: .assistant, content: text)
      message.weatherCards = cards
      let reply = ConversationTranscript.Reply(id: message.id, message: message, activity: nil, isLatest: false,
                                               isInProgress: true)
      return EnigmaReplyView(reply: reply).padding(20)
    }
    try EnigmaSnapshot.save("weather-one-day", size: CGSize(width: 600, height: 520)) {
      reply([rainy], "Light rain on and off this afternoon, so take an umbrella; it dries up this evening.")
    }
    try EnigmaSnapshot.save("weather-several-days", size: CGSize(width: 600, height: 330)) {
      reply([week], "A grey, mild week that turns damp from Saturday.")
    }
    let cell = 120.0
    let still = EnigmaCharacterCostume.allCases.enumerated().map { index, costume in
      (EnigmaCharacterModel.stillFrame(fitting: CGRect(x: cell * Double(index) + 20, y: 50, width: 80, height: 90), legs: true),
       costume)
    }
    // A change of outfit as the new one goes on, inside the smoke.
    let controller = EnigmaCharacterController(seed: 3)
    let slot = EnigmaCharacterModel.Slot(center: CGPoint(x: cell * 6.5, y: 110), size: 60)
    controller.move(to: "slot")
    var time = 10.0
    for _ in 0..<120 { time += 1.0 / 60; _ = controller.frame(at: time, slots: ["slot": slot], targets: [:], reduceMotion: false) }
    controller.costume = .umbrella
    var puff = EnigmaCharacterFrame.empty
    for _ in 0..<7 { time += 1.0 / 60; puff = controller.frame(at: time, slots: ["slot": slot], targets: [:], reduceMotion: false) }
    try EnigmaSnapshot.save("weather-costumes", size: CGSize(width: cell * 7, height: 190)) {
      CostumeLineUp(frames: still + [(puff, nil)], labels: EnigmaCharacterCostume.allCases.map(\.rawValue) + ["changing"], cell: cell)
    }
  }

  // MARK: Hosting

  /// An offscreen window that's never ordered front, so no test takes the screen.
  private func host<V: View>(_ view: V, width: CGFloat = 520) -> NSView {
    let content = AnyView(view.frame(width: width).enigmaTheme(.paper)
      .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) }))
    let hosting = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: 900), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = CGRect(x: 0, y: 0, width: width, height: 900)
    hosting.layoutSubtreeIfNeeded()
    addTeardownBlock { window.close() }
    return hosting
  }

  private func markers(_ name: String, in view: NSView) -> [NSView] {
    var found: [NSView] = []
    func walk(_ view: NSView) {
      if view is TestControlMarker.Marker, view.identifier?.rawValue == name { found.append(view) }
      view.subviews.forEach(walk)
    }
    walk(view)
    return found
  }
}

/// Costumed frames in a row with their labels, for the screenshots.
private struct CostumeLineUp: View {
  let frames: [(EnigmaCharacterFrame, EnigmaCharacterCostume?)]
  let labels: [String]
  let cell: Double
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        for (frame, costume) in frames {
          EnigmaCharacterCostume.draw(frame, wearing: costume, palette: palette, in: &context)
        }
      }
      ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
        Text(label).font(EnigmaTypography.mono(11)).foregroundStyle(palette.textSecondary.color)
          .position(x: cell * (Double(index) + 0.5), y: 172)
      }
    }
  }
}
