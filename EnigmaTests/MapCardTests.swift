import AppKit
import MapKit
import SwiftUI
import XCTest
@testable import Enigma

/// The map card under replies whose evidence included places (F29 CP9, spec §6.6).
@MainActor
final class MapCardTests: XCTestCase {
  private var root: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!

  static let flore = MapPlace(id: "flore", name: "Café de Flore", coordinate: SearchCoordinate(latitude: 48.85, longitude: 2.33),
                              distanceMeters: 320)
  static let bean = MapPlace(id: "bean", name: "The Bean Counter", coordinate: SearchCoordinate(latitude: 48.86, longitude: 2.34),
                             distanceMeters: nil)
  static let door = MapPlace(id: "door", name: "Blue Door", coordinate: SearchCoordinate(latitude: 48.87, longitude: 2.35),
                             distanceMeters: nil)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("MapCardTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    suiteName = "MapCardTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Helpers

  private static func place(_ id: String, _ name: String) -> MapPlace {
    MapPlace(id: id, name: name, coordinate: SearchCoordinate(latitude: 40.72, longitude: -74.0), distanceMeters: nil)
  }

  private static func placesResult(_ places: [MapPlace]) -> WebSearchResult {
    WebSearchResult(source: WebSearchSource(title: "Apple Maps", url: URL(string: "https://maps.apple.com/?q=cafes")!),
                    snippets: ["Places from Apple Maps: " + places.map(\.name).joined(separator: ", ")],
                    site: "Apple Maps", kind: .places, places: places)
  }

  private static let webResult = WebSearchResult(source: WebSearchSource(title: "Cafes guide",
    url: URL(string: "https://example.com/cafes")!), snippets: ["Café de Flore is a classic."], kind: .snippet)
  private static let weatherResult = WebSearchResult(source: WebSearchSource(title: "Open-Meteo forecast",
    url: URL(string: "https://open-meteo.com/")!), snippets: ["Sunny, 21 °C."], site: "Open-Meteo", kind: .weather)

  /// A small model's chat (the plain `submit` route) answering `reply`.
  private func makeSmallChat(results: [WebSearchResult], engine: MapCardEngine = MapCardEngine(),
                             store: ChatSessionStore? = nil, vision: MapCardVision = MapCardVision(),
                             cloud: MapCardCloud = MapCardCloud()) -> LocalChatViewModel {
    let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: nil), defaults: defaults)
    return LocalChatViewModel(engine: engine, selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
                              toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
                              visionEngine: vision,
                              cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud),
                              webSearch: NativeSearchProvider(results: results), searchSettings: settings,
                              sessionStore: store ?? ChatSessionStore(applicationSupportDirectory: root),
                              nativeToolsEnabled: false)
  }

  /// A capable local model's chat whose tool loop plays `steps`.
  private func makeCapableChat(steps: [NativeScriptedInference.Step]) -> LocalChatViewModel {
    let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: nil), defaults: defaults)
    return LocalChatViewModel(
      engine: NativeTestEngine(model: NativeToolRequestTests.flaggedModel),
      selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
      toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
      localToolRuntime: { _ in true },
      fileInference: NativeScriptedInference(steps: steps),
      webSearch: NativeSearchProvider(results: NativeToolRequestTests.searchResults),
      searchSettings: settings,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root),
      nativeToolsEnabled: true)
  }

  private func waitUntil(_ description: @autoclosure () -> String, timeout: Duration = .seconds(3), file: StaticString = #filePath,
                         line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(description())", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func waitUntilIdle(_ chat: LocalChatViewModel, file: StaticString = #filePath, line: UInt = #line) async throws {
    try await waitUntil("the request to end (state \(chat.state))", file: file, line: line) {
      chat.activeRequest == nil && !chat.isBusy && chat.messages.last?.role == .assistant
    }
  }

  private func reply(of chat: LocalChatViewModel, file: StaticString = #filePath, line: UInt = #line) throws -> ChatMessage {
    let message = try XCTUnwrap(chat.messages.last, file: file, line: line)
    XCTAssertEqual(message.role, .assistant, file: file, line: line)
    return message
  }

  // MARK: Task 9.1: carrying the places onto the reply

  func testSmallModelPlacesReachTheReply() async throws {
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore, Self.bean]), Self.webResult], store: store)
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Saint-Germain, Paris", searchEnabled: true)
    try await waitUntilIdle(chat)
    XCTAssertEqual(try reply(of: chat).mapPlaces, [Self.flore, Self.bean])
    // The saved chat has the reply and its Apple Maps source, never the places.
    await chat.sessionWriter.waitForPendingWrites()
    let saved = try XCTUnwrap(store.load().first)
    XCTAssertEqual(saved.messages.last?.searchSources?.first?.title, "Apple Maps")
    XCTAssertNil(saved.messages.last?.mapPlaces)
  }

  func testToolPlacesReachTheReply() async throws {
    let chat = makeCapableChat(steps: [.call("find_places", #"{"query":"ramen","area":"Soho"}"#),
                                       .call("find_places", #"{"query":"ramen","area":"Covent Garden"}"#),
                                       .text("Try Bone Daddies.")])
    let first = PlaceResult(place: Self.place("a", "Bone Daddies"), category: nil, address: nil, phone: nil, website: nil)
    let second = PlaceResult(place: Self.place("b", "Kanada-Ya"), category: nil, address: nil, phone: nil, website: nil)
    let third = PlaceResult(place: Self.place("c", "Ippudo"), category: nil, address: nil, phone: nil, website: nil)
    let places = SequencedPlaces([[first, second], [second, third]])
    chat.placeSearch = places
    await chat.refreshInstalledModel()
    let prompt = "/maps ramen in Soho"
    chat.submitNative(prompt, route: NativeToolRequestTests.localRoute, plan: chat.nativeToolPlan(for: ComposerCommands(prompt)))
    try await waitUntilIdle(chat)
    XCTAssertEqual(places.callCount, 2)
    XCTAssertEqual(try reply(of: chat).mapPlaces?.map(\.id), ["a", "b", "c"], "In call order, without duplicates")
  }

  func testMapPlacesAreNeverSaved() throws {
    var message = ChatMessage(role: .assistant, content: "Café de Flore is near.")
    message.mapPlaces = [Self.flore]
    var session = ChatSession(title: "Cafes")
    session.messages = [message]
    let data = try JSONEncoder().encode([session])
    let json = String(decoding: data, as: UTF8.self)
    for secret in ["mapPlaces", "48.85", "2.33", "flore"] {
      XCTAssertFalse(json.contains(secret), secret)
    }
    let decoded = try JSONDecoder().decode([ChatSession].self, from: data)
    XCTAssertEqual(decoded.first?.messages.first?.content, "Café de Flore is near.")
    XCTAssertNil(decoded.first?.messages.first?.mapPlaces)
  }

  func testNoPlacesNoCard() async throws {
    for results in [[Self.webResult], [Self.weatherResult]] {
      let chat = makeSmallChat(results: results)
      await chat.refreshInstalledModel()
      chat.submit("/search what is open in Paris", searchEnabled: true)
      try await waitUntilIdle(chat)
      XCTAssertNil(try reply(of: chat).mapPlaces, "\(results.map(\.kind))")
    }
    let empty = makeSmallChat(results: [Self.placesResult([]), Self.webResult])
    await empty.refreshInstalledModel()
    empty.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntilIdle(empty)
    XCTAssertNil(try reply(of: empty).mapPlaces, "No places, no card")
  }

  func testScreenPathPlacesReachTheReply() async throws {
    let engine = MapCardEngine(model: try MapCardEngine.visionModel(in: root))
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore, Self.bean])], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntilIdle(chat)
    XCTAssertEqual(try reply(of: chat).content, "Café de Flore, from the vision model.")
    XCTAssertEqual(try reply(of: chat).mapPlaces, [Self.flore, Self.bean])
  }

  func testCloudSearchPlacesReachTheReply() async throws {
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore, Self.bean])])
    chat.submitCloud("/search cafes in Paris", provider: .chatGPT, modelID: "model", searchEnabled: true)
    try await waitUntilIdle(chat)
    XCTAssertEqual(try reply(of: chat).content, "Café de Flore, from the cloud.")
    XCTAssertEqual(try reply(of: chat).mapPlaces, [Self.flore, Self.bean])
  }

  func testWhitespaceReplyGetsNoCard() async throws {
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore])], engine: MapCardEngine(reply: "  \n "))
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntil("the request to end") { chat.activeRequest == nil && !chat.isBusy }
    XCTAssertTrue(chat.messages.allSatisfy { $0.mapPlaces == nil })
  }

  /// N6: a places result that didn't survive context fitting puts no places on the reply.
  func testPlacesTheModelNeverSawGetNoCard() async throws {
    var dropped = Self.placesResult([Self.flore])
    dropped = WebSearchResult(source: dropped.source, snippets: [" "], site: dropped.site, kind: .places, places: dropped.places)
    let chat = makeSmallChat(results: [dropped, Self.webResult])
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntilIdle(chat)
    XCTAssertNil(try reply(of: chat).mapPlaces)
  }

  /// S1: Stop keeps a reply's card (D146), and nothing stale reaches the next replies, in the same
  /// chat or a new one.
  func testStopAttachesAndLeavesNothingStale() async throws {
    let engine = MapCardEngine(reply: "Café de Flore is close.", holds: true)
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore, Self.bean])], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Café de Flore is close." }
    let stoppedID = try reply(of: chat).id
    _ = chat.stopStreaming()
    await engine.release()
    XCTAssertEqual(try reply(of: chat).mapPlaces, [Self.flore, Self.bean])
    chat.submit("hello there")
    try await waitUntilIdle(chat)
    XCTAssertNotEqual(try reply(of: chat).id, stoppedID)
    XCTAssertNil(try reply(of: chat).mapPlaces, "The next reply in the chat")
    chat.newChat()
    chat.submit("hello again")
    try await waitUntilIdle(chat)
    XCTAssertNil(try reply(of: chat).mapPlaces, "The next reply in a new chat")
    let stopped = chat.sessions.flatMap(\.messages).first { $0.id == stoppedID }
    XCTAssertEqual(stopped?.mapPlaces, [Self.flore, Self.bean])
  }

  /// After Stop, the tool's own cancellation check keeps a late find_places result off the reply.
  func testToolPlacesAfterStopAreDropped() async throws {
    let chat = makeCapableChat(steps: [.call("find_places", #"{"query":"ramen","area":"Soho"}"#), .text("Bone Daddies.")])
    let places = HeldPlaces([PlaceResult(place: Self.place("a", "Bone Daddies"), category: nil, address: nil, phone: nil,
                                         website: nil)])
    chat.placeSearch = places
    await chat.refreshInstalledModel()
    let prompt = "/maps ramen in Soho"
    chat.submitNative(prompt, route: NativeToolRequestTests.localRoute, plan: chat.nativeToolPlan(for: ComposerCommands(prompt)))
    try await waitUntil("the MapKit request") { places.isWaiting }
    _ = chat.stopStreaming()
    places.release()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(chat.messages.allSatisfy { $0.mapPlaces == nil })
    chat.submit("hello there")
    try await waitUntil("the next request to end") { chat.activeRequest == nil && !chat.isBusy }
    XCTAssertTrue(chat.messages.allSatisfy { $0.mapPlaces == nil }, "Nothing stale on the next reply")
  }

  /// Places that arrive for a stopped request are dropped, even once the next request runs.
  func testPlacesForAnEndedRequestAreDropped() async throws {
    let engine = MapCardEngine(reply: "Café de Flore is close.", holds: true)
    let chat = makeSmallChat(results: [Self.webResult], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Café de Flore is close." }
    let oldRequest = try XCTUnwrap(chat.activeRequest?.id)
    let stoppedID = try reply(of: chat).id
    _ = chat.stopStreaming()
    await engine.release()
    chat.submit("hello there")
    try await waitUntil("the next request") { chat.activeRequest != nil }
    chat.addReplyPlaces([Self.flore], messageID: stoppedID, requestID: oldRequest)
    try await waitUntilIdle(chat)
    XCTAssertTrue(chat.sessions.flatMap(\.messages).allSatisfy { $0.mapPlaces == nil })
  }

  // MARK: Task 9.2: choosing the pins

  func testPinsFollowReplyOrder() {
    let places = [Self.flore, Self.door, Self.bean]
    let pins = MapCard.pins(for: places, reply: "Start at The Bean Counter, then walk to Café de Flore.")
    XCTAssertEqual(pins, [MapPin(number: 1, place: Self.bean), MapPin(number: 2, place: Self.flore)])
    // Only the first mention counts.
    let again = MapCard.pins(for: places, reply: "Café de Flore first. Blue Door next. Café de Flore again.")
    XCTAssertEqual(again.map(\.place.id), ["flore", "door"])
  }

  func testPinsIgnoreCaseDiacriticsAndLeadingThe() {
    let places = [Self.flore, Self.bean]
    XCTAssertEqual(MapCard.pins(for: places, reply: "Try café de flore.").map(\.place.id), ["flore"])
    XCTAssertEqual(MapCard.pins(for: places, reply: "Try CAFE DE FLORE.").map(\.place.id), ["flore"])
    XCTAssertEqual(MapCard.pins(for: places, reply: "Bean Counter has good coffee.").map(\.place.id), ["bean"])
    XCTAssertEqual(MapCard.pins(for: places, reply: "the bean counter has good coffee.").map(\.place.id), ["bean"])
  }

  func testPinsMatchFullNamesOnly() {
    let bottle = Self.place("bottle", "Blue Bottle")
    XCTAssertEqual(MapCard.pins(for: [Self.door, bottle], reply: "Blue Bottle is best.").map(\.place.id), ["bottle"])
    let joes = Self.place("joes", "Joe's Pizza"), broadway = Self.place("broadway", "Joe's Pizza Broadway")
    XCTAssertEqual(MapCard.pins(for: [broadway, joes], reply: "Joe’s Pizza is a classic.").map(\.place.id), ["joes"])
    XCTAssertEqual(MapCard.pins(for: [broadway, joes], reply: "Joe's Pizza Broadway is open late.").map(\.place.id),
                   ["broadway"], "The longer name wins where both match")
    // Whole words only.
    let inn = Self.place("inn", "Inn")
    let blue = MapCard.pins(for: [inn, Self.door], reply: "Dinner at Blue Door.")
    XCTAssertEqual(blue.map(\.place.id), ["door"])
  }

  func testPinsTreatAmpersandAsAndAndSkipEmptyNames() {
    let barnes = Self.place("barnes", "Barnes & Noble"), ben = Self.place("ben", "Ben and Jerry's")
    XCTAssertEqual(MapCard.pins(for: [barnes, ben], reply: "Ben & Jerry's, then Barnes and Noble.").map(\.place.id),
                   ["ben", "barnes"])
    let the = Self.place("the", "The"), dash = Self.place("dash", "—")
    XCTAssertEqual(MapCard.pins(for: [the, dash, Self.flore], reply: "The best is Café de Flore.").map(\.place.id), ["flore"])
  }

  func testCameraFitsFarApartPins() {
    let sydney = MapPlace(id: "syd", name: "Sydney", coordinate: SearchCoordinate(latitude: -33.87, longitude: 151.21),
                          distanceMeters: nil)
    let losAngeles = MapPlace(id: "lax", name: "Los Angeles", coordinate: SearchCoordinate(latitude: 34.05, longitude: -118.24),
                              distanceMeters: nil)
    let pins = MapCard.pins(for: [sydney, losAngeles], reply: "")
    let rect = MapCard.rect(for: pins)
    XCTAssertLessThanOrEqual(rect.width, MKMapRect.world.width)
    XCTAssertTrue(MKMapRect.world.contains(rect))
    for place in [sydney, losAngeles] {
      XCTAssertTrue(rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: place.coordinate.latitude,
                                                                    longitude: place.coordinate.longitude))), place.name)
    }
    let one = MapCard.rect(for: MapCard.pins(for: [Self.flore], reply: ""))
    let meters = one.width / MKMapPointsPerMeterAtLatitude(Self.flore.coordinate.latitude)
    XCTAssertEqual(meters, 1_000, accuracy: 1, "One pin shows about 1 km")
  }

  func testNoMatchPinsEveryPlace() {
    let places = [Self.flore, Self.door, Self.bean]
    let pins = MapCard.pins(for: places, reply: "Here are a few cafes nearby.")
    XCTAssertEqual(pins, places.enumerated().map { MapPin(number: $0.offset + 1, place: $0.element) })
    XCTAssertTrue(MapCard.pins(for: [], reply: "Nothing.").isEmpty)
  }

  func testOnlyNamedPlacesArePinned() {
    let places = (1...10).map { Self.place("p\($0)", "Place Number \(["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"][$0 - 1])") }
    let pins = MapCard.pins(for: places, reply: "Place Number Seven is quiet; Place Number Two is busy.")
    XCTAssertEqual(pins.map(\.number), [1, 2])
    XCTAssertEqual(pins.map(\.place.id), ["p7", "p2"])
  }

  // MARK: Task 9.3: the card

  func testCardAppearsOnlyAfterTheReplyFinishes() async throws {
    let engine = MapCardEngine(reply: "Café de Flore is close.", holds: true)
    let chat = makeSmallChat(results: [Self.placesResult([Self.flore, Self.bean])], engine: engine)
    await chat.refreshInstalledModel()
    chat.submit("/search cafes in Paris", searchEnabled: true)
    try await waitUntil("the reply to stream") { chat.messages.last?.content == "Café de Flore is close." }
    XCTAssertNil(try reply(of: chat).mapPlaces)
    let streaming = ConversationTranscript(messages: chat.messages, activity: chat.activity, isResponding: true)
    XCTAssertNil(replies(streaming).last?.mapPins, "No card while streaming")
    await engine.release()
    try await waitUntilIdle(chat)
    XCTAssertEqual(try reply(of: chat).mapPlaces, [Self.flore, Self.bean])
    let finished = ConversationTranscript(messages: chat.messages, activity: nil, isResponding: false)
    XCTAssertEqual(replies(finished).last?.mapPins, [MapPin(number: 1, place: Self.flore)])
  }

  func testPlaceholderInTestHost() throws {
    XCTAssertFalse(MapCardView.drawsLiveMap, "The test host never builds a Map")
    let pins = MapCard.pins(for: [Self.flore, Self.bean], reply: "")
    let (hosting, _) = host(MapCardView(pins: pins, units: .metric, open: { _ in }))
    let marker = try XCTUnwrap(EnigmaMainWindowTests.Host.marker("Map card", in: hosting))
    let frame = frameFromTop(of: marker, in: hosting)
    XCTAssertEqual(frame.height, MapCard.height, accuracy: 0.5)
    XCTAssertEqual(frame.width, 420, accuracy: 0.5, "The reply's width")
    XCTAssertNotNil(EnigmaMainWindowTests.Host.marker("Open in Maps", in: hosting))
    XCTAssertFalse(containsMapView(hosting), "No MKMapView, so no tiles load")
    // Each pin is a control named by its VoiceOver label.
    XCTAssertNotNil(control("1, Café de Flore, 0.3 km away", in: hosting))
    XCTAssertNotNil(control("2, The Bean Counter", in: hosting))
  }

  func testCardAccessibility() {
    XCTAssertEqual(MapCard.label(count: 3), "Map of 3 places")
    XCTAssertEqual(MapCard.label(count: 1), "Map of 1 place")
    XCTAssertEqual(MapCard.pinLabel(MapPin(number: 1, place: Self.flore), units: .metric), "1, Café de Flore, 0.3 km away")
    XCTAssertEqual(MapCard.pinLabel(MapPin(number: 1, place: Self.flore), units: .us), "1, Café de Flore, 0.2 mi away")
    XCTAssertEqual(MapCard.pinLabel(MapPin(number: 2, place: Self.bean), units: .us), "2, The Bean Counter")
  }

  func testOpenInMapsOpensAllPins() async throws {
    var opened: [[MapPlace]] = []
    let pins = MapCard.pins(for: [Self.flore, Self.door, Self.bean], reply: "The Bean Counter or Café de Flore.")
    await MapCardView(pins: pins, units: .metric, open: { opened.append($0) }).actions.openAll()
    XCTAssertEqual(opened, [[Self.bean, Self.flore]], "The pins, in pin order; unpinned places stay out")
    let (hosting, _) = host(MapCardView(pins: pins, units: .metric, open: { _ in }))
    XCTAssertNotNil(control("Open in Maps", in: hosting))
  }

  func testPinOpensItsPlace() async throws {
    var opened: [[MapPlace]] = []
    let pins = MapCard.pins(for: [Self.flore, Self.bean], reply: "")
    await MapCardView(pins: pins, units: .metric, open: { opened.append($0) }).actions.open(pins[1])
    XCTAssertEqual(opened, [[Self.bean]])
  }

  /// N3: clicks while Open in Maps is looking places up are ignored.
  func testOpeningIgnoresClicksWhileRunning() async throws {
    var calls = 0
    var released = false
    let pins = MapCard.pins(for: [Self.flore], reply: "")
    let actions = MapCardView(pins: pins, units: .metric, open: { _ in
      calls += 1
      let deadline = ContinuousClock.now + .seconds(3)
      while !released, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }).actions
    let first = Task { @MainActor in await actions.openAll() }
    try await waitUntil("the first open") { calls == 1 }
    await actions.openAll()
    await actions.open(pins[0])
    XCTAssertEqual(calls, 1)
    released = true
    await first.value
    await actions.openAll()
    XCTAssertEqual(calls, 2, "Clicks work again once it's done")
  }

  /// The reply row draws the card under a finished reply only, at the reply's width.
  func testReplyRowShowsTheCardOnceFinished() throws {
    var message = ChatMessage(role: .assistant, content: "Café de Flore is close.")
    message.mapPlaces = [Self.flore, Self.bean]
    for (inProgress, shows) in [(true, false), (false, true)] {
      let reply = ConversationTranscript.Reply(id: message.id, message: message, activity: nil, isLatest: false,
                                               isInProgress: inProgress)
      let (hosting, _) = host(EnigmaReplyView(reply: reply), width: 520)
      XCTAssertEqual(control("Map card", in: hosting) != nil, shows, "in progress: \(inProgress)")
      XCTAssertEqual(control("1, Café de Flore, 0.3 km away", in: hosting) != nil || control("1, Café de Flore, 0.2 mi away", in: hosting) != nil,
                     shows, "Only the named place is pinned")
      XCTAssertNil(control("2, The Bean Counter", in: hosting))
    }
    message.mapPlaces = nil
    let saved = ConversationTranscript.Reply(id: message.id, message: message, activity: nil, isLatest: false, isInProgress: false)
    let (hosting, _) = host(EnigmaReplyView(reply: saved), width: 520)
    XCTAssertNil(control("Map card", in: hosting), "A reopened chat has no card")
  }

  /// MapKit never answers a request cancelled while loading: the time limit ends the wait.
  func testLookUpGivesUpWhenMapKitNeverAnswers() async throws {
    var cancels = 0
    var result: String?? = .none
    let lookUp = Task { @MainActor in
      result = .some(await MapCardOpener.lookUp(within: .milliseconds(50), start: { (_: @escaping @MainActor (String?) -> Void) in },
                                                 cancel: { cancels += 1 }))
    }
    try await waitUntil("the lookup to give up", timeout: .seconds(1)) { result != nil }
    XCTAssertEqual(result, .some(nil))
    XCTAssertEqual(cancels, 1)
    lookUp.cancel()
    // An answer comes back once, and stops the timer.
    let answered = await MapCardOpener.lookUp(within: .milliseconds(50), start: { finish in finish("place") },
                                              cancel: { cancels += 1 })
    XCTAssertEqual(answered, "place")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(cancels, 1, "No cancel after an answer")
  }

  func testScrollingPassesThroughTheMap() {
    XCTAssertTrue(MapScrollPassThrough.takes(.scrollWheel))
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .mouseMoved, .magnify] {
      XCTAssertFalse(MapScrollPassThrough.takes(type), "\(type)")
    }
  }

  // MARK: View helpers

  private func replies(_ transcript: ConversationTranscript) -> [ConversationTranscript.Reply] {
    transcript.rows.compactMap { if case .reply(let reply) = $0 { reply } else { nil } }
  }

  /// An offscreen window that's never ordered front, so no test takes the screen.
  private func host<V: View>(_ view: V, width: CGFloat = 420) -> (NSHostingView<AnyView>, NSWindow) {
    let content = AnyView(view.frame(width: width).environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) }))
    let hosting = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = CGRect(x: 0, y: 0, width: width, height: 400)
    hosting.layoutSubtreeIfNeeded()
    addTeardownBlock { window.close() }
    return (hosting, window)
  }

  private func containsMapView(_ view: NSView) -> Bool {
    if NSStringFromClass(type(of: view)).contains("MKMapView") { return true }
    return view.subviews.contains { containsMapView($0) }
  }

  private func control(_ name: String, in view: NSView) -> NSView? {
    EnigmaMainWindowTests.Host.marker(name, in: view)
  }
}

// MARK: Test doubles


/// A small local model that answers `reply`, holding the stream open after it while `holds`.
private actor MapCardEngine: LocalModelEngine {
  /// A vision model whose files exist in `directory` (screen requests check them).
  static func visionModel(in directory: URL) throws -> LocalModel {
    let file = directory.appendingPathComponent("vision.gguf"), projector = directory.appendingPathComponent("vision-mmproj.gguf")
    let header = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
    try header.write(to: file)
    try header.write(to: projector)
    return LocalModel(id: "vision", displayName: "Vision", fileURL: file,
                      visionConfiguration: LocalVisionConfiguration(projectorURL: projector,
                                                                    serverExecutableURL: URL(fileURLWithPath: "/bin/echo")))
  }
  let model: LocalModel
  let reply: String
  private var holds: Bool
  private var held: CheckedContinuation<Void, Never>?

  init(model: LocalModel = LocalModel(id: "fixture", displayName: "Fixture", fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf")),
       reply: String = "Here are some cafes.", holds: Bool = false) {
    self.model = model
    self.reply = reply
    self.holds = holds
  }

  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  func unload() async {}

  func release() {
    holds = false
    held?.resume()
    held = nil
  }

  private func waitWhileHeld() async {
    guard holds else { return }
    await withCheckedContinuation { held = $0 }
  }

  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(reply)
        await waitWhileHeld()
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// Answers each call with the next list of places.
private final class SequencedPlaces: PlaceSearching, @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: [[PlaceResult]]
  private var calls = 0
  init(_ answers: [[PlaceResult]]) { remaining = answers }
  var callCount: Int { lock.withLock { calls } }
  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult] {
    lock.withLock {
      calls += 1
      return remaining.isEmpty ? [] : remaining.removeFirst()
    }
  }
}

/// A vision model's server that answers at once.
private struct MapCardVision: LocalVisionServing {
  func prepare(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) async throws -> PreparedConversation {
    PreparedConversation(messages: messages, inputTokenCount: 0, omittedMessageCount: 0,
                         budget: ContextBudget(contextWindow: 8_192, outputTokens: 512, overheadTokens: 256))
  }
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.yield("Café de Flore, from the vision model."); $0.finish() }
  }
  func unload() async {}
}

/// A cloud model that answers at once.
private struct MapCardCloud: ChatProvider {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.yield(.token("Café de Flore, from the cloud.")); $0.yield(.completed); $0.finish() }
  }
}

/// A MapKit search that waits until released.
private final class HeldPlaces: PlaceSearching, @unchecked Sendable {
  private let lock = NSLock()
  private let results: [PlaceResult]
  private var waiting: CheckedContinuation<Void, Never>?
  private var released = false
  init(_ results: [PlaceResult]) { self.results = results }
  var isWaiting: Bool { lock.withLock { waiting != nil } }
  func release() {
    let continuation = lock.withLock {
      released = true
      defer { waiting = nil }
      return waiting
    }
    continuation?.resume()
  }
  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult] {
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock {
        if released { return true }
        waiting = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
    return results
  }
}
