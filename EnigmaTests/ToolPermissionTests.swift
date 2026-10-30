import XCTest
@testable import Enigma

@MainActor
final class ToolPermissionTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private let sessionA = UUID(), sessionB = UUID()
  private let mom = ToolPermission.readChat(chatGUID: "iMessage;-;+15550100", name: "Mom")

  override func setUpWithError() throws {
    suiteName = "ToolPermissionTests-\(UUID())"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
  }

  private func store() -> ToolGrantStore { ToolGrantStore(defaults: defaults) }

  // MARK: Grant store

  func testDestinationForEveryProvider() {
    func route(_ mode: ChatMode, _ provider: String) -> Route {
      Route(mode: mode, providerID: provider, modelID: "m", usesNetwork: mode != .local)
    }
    let expected: [CloudProviderID: ToolDestination] = [.chatGPT: .openAI, .openAI: .openAI,
      .claudeCode: .anthropic, .anthropic: .anthropic, .gemini: .google]
    for provider in CloudProviderID.allCases {
      XCTAssertEqual(ToolDestination(route: route(.cloud, provider.rawValue)), expected[provider], provider.rawValue)
    }
    XCTAssertEqual(ToolDestination(route: route(.local, "llama.cpp")), .thisMac)
    XCTAssertEqual(ToolDestination(route: route(.local, "local")), .thisMac)
    XCTAssertNil(ToolDestination(route: route(.cloud, "someone-else")), "No card names a company Enigma doesn't know")
    XCTAssertEqual(ToolDestination.allCases.map(\.displayName), ["this Mac", "OpenAI", "Anthropic", "Google"])
  }

  func testConversationGrantIsPerSession() {
    let store = store()
    store.record(.conversation, for: mom, destination: .thisMac, session: sessionA)
    XCTAssertTrue(store.isGranted(mom, destination: .thisMac, session: sessionA))
    XCTAssertFalse(store.isGranted(mom, destination: .thisMac, session: sessionB))
    XCTAssertTrue(store.alwaysGrants.isEmpty)
    XCTAssertNil(defaults.object(forKey: ToolGrantStore.defaultsKey), "Conversation grants never reach settings")
  }

  func testAlwaysGrantPersists() {
    store().record(.always, for: mom, destination: .anthropic, session: sessionA)
    let reopened = store()
    XCTAssertTrue(reopened.isGranted(mom, destination: .anthropic, session: sessionB))
    XCTAssertEqual(reopened.alwaysGrants, [ToolAlwaysGrant(kind: .readChat, chatGUID: "iMessage;-;+15550100",
                                                           chatName: "Mom", destination: .anthropic)])
  }

  func testAlwaysIsKeyedPerDestination() {
    let store = store()
    store.record(.always, for: mom, destination: .thisMac, session: sessionA)
    XCTAssertFalse(store.isGranted(mom, destination: .anthropic, session: sessionA))
    XCTAssertFalse(store.isGranted(.readChat(chatGUID: "other", name: "Mom"), destination: .thisMac, session: sessionA),
                   "Another chat with the same name")
    XCTAssertTrue(store.isGranted(.readChat(chatGUID: "iMessage;-;+15550100", name: "Mother"), destination: .thisMac,
                                  session: sessionA), "Only the chat GUID keys a read")
    store.record(.conversation, for: .searchChats(query: "x"), destination: .google, session: sessionA)
    XCTAssertFalse(store.isGranted(.searchChats(query: "x"), destination: .openAI, session: sessionA))
  }

  func testSearchChatsIgnoresQuery() {
    let store = store()
    store.record(.always, for: .searchChats(query: "dinner"), destination: .openAI, session: sessionA)
    XCTAssertTrue(store.isGranted(.searchChats(query: "rent"), destination: .openAI, session: sessionB))
  }

  func testSearchAfterMessagesIgnoresDestination() {
    let store = store()
    store.record(.conversation, for: .searchAfterMessages(query: "a"), destination: .thisMac, session: sessionA)
    for destination in ToolDestination.allCases {
      XCTAssertTrue(store.isGranted(.searchAfterMessages(query: "b"), destination: destination, session: sessionA))
    }
    XCTAssertFalse(store.isGranted(.searchAfterMessages(query: "a"), destination: .thisMac, session: sessionB))
  }

  /// Gate 3's tools each ask for themselves: allowing web search, places or weather, for the chat or
  /// always, never lets the other two through (owner, 2026-10-31).
  func testGateThreeToolsHaveTheirOwnGrants() {
    let tools: [ToolPermission] = [.searchAfterMessages(query: "pizza"), .placesAfterMessages(title: "Find pizza near you?"),
                                   .weatherAfterMessages(title: "Check the weather for your area?")]
    for answer in [ToolPermissionAnswer.conversation, .always] {
      for granted in tools {
        defaults.removeObject(forKey: ToolGrantStore.defaultsKey)
        let store = store()
        store.record(answer, for: granted, destination: .thisMac, session: sessionA)
        for tool in tools {
          XCTAssertEqual(store.isGranted(tool, destination: .anthropic, session: sessionA), tool == granted,
                         "\(answer) on \(granted) for \(tool)")
        }
      }
    }
  }

  func testDenyRecordsNothing() {
    let store = store()
    store.record(.deny, for: mom, destination: .thisMac, session: sessionA)
    XCTAssertFalse(store.isGranted(mom, destination: .thisMac, session: sessionA))
    XCTAssertTrue(store.alwaysGrants.isEmpty)
    XCTAssertNil(defaults.object(forKey: ToolGrantStore.defaultsKey))
  }

  func testRemoveDropsAlwaysGrant() throws {
    let store = store()
    store.record(.always, for: mom, destination: .thisMac, session: sessionA)
    store.record(.always, for: .searchChats(query: "q"), destination: .thisMac, session: sessionA)
    store.remove(try XCTUnwrap(store.alwaysGrants.first))
    XCTAssertFalse(store.isGranted(mom, destination: .thisMac, session: sessionA))
    XCTAssertFalse(self.store().isGranted(mom, destination: .thisMac, session: sessionA), "Removed from settings too")
    XCTAssertTrue(self.store().isGranted(.searchChats(query: "z"), destination: .thisMac, session: sessionA))
  }

  func testEndSessionClearsConversationGrantsAndMark() {
    let store = store()
    store.record(.conversation, for: mom, destination: .thisMac, session: sessionA)
    store.record(.always, for: .searchChats(query: "q"), destination: .thisMac, session: sessionA)
    store.markMessageText(session: sessionA)
    store.markMessageText(session: sessionB)
    XCTAssertTrue(store.hasMessageText(session: sessionA))
    store.endSession(sessionA)
    XCTAssertFalse(store.isGranted(mom, destination: .thisMac, session: sessionA))
    XCTAssertFalse(store.hasMessageText(session: sessionA))
    XCTAssertTrue(store.hasMessageText(session: sessionB), "Other chats keep their mark")
    XCTAssertTrue(store.isGranted(.searchChats(query: "q"), destination: .thisMac, session: sessionA), "Always stays")
  }

  /// A chat's history may go to a company only if all of its message text was allowed there.
  func testMessageTextDestinationsOnlyNarrowUntilASharedAllow() {
    let store = store()
    XCTAssertTrue(store.messageTextAllowed(session: sessionA, destination: .anthropic), "No message text yet")
    store.markMessageText(session: sessionA, destination: .anthropic)
    XCTAssertTrue(store.messageTextAllowed(session: sessionA, destination: .anthropic))
    XCTAssertTrue(store.messageTextAllowed(session: sessionA, destination: .thisMac))
    XCTAssertFalse(store.messageTextAllowed(session: sessionA, destination: .openAI))
    store.markMessageText(session: sessionA, destination: .thisMac)
    XCTAssertFalse(store.messageTextAllowed(session: sessionA, destination: .anthropic),
                   "Text kept on this Mac takes Anthropic out")
    store.markMessageText(session: sessionA, destination: .anthropic)
    XCTAssertFalse(store.messageTextAllowed(session: sessionA, destination: .anthropic), "A later read doesn't widen it")
    store.record(.conversation, for: .shareMessageText, destination: .anthropic, session: sessionA)
    XCTAssertTrue(store.messageTextAllowed(session: sessionA, destination: .anthropic), "Only the share card widens it")
    store.markMessageText(session: sessionA, destination: .openAI)
    XCTAssertFalse(store.messageTextAllowed(session: sessionA, destination: .anthropic))
    XCTAssertFalse(store.messageTextAllowed(session: sessionA, destination: .openAI))
    XCTAssertTrue(store.messageTextAllowed(session: sessionA, destination: .thisMac))
  }

  /// An Always grant saved when gate 3's tools shared one grant still allows web search, and now only it.
  func testSavedSearchGrantNowCoversOnlyWebSearch() {
    defaults.set(Data(#"[{"kind":"searchAfterMessages"}]"#.utf8), forKey: ToolGrantStore.defaultsKey)
    let store = store()
    XCTAssertEqual(store.alwaysGrants.map(MessagesSettingsSection.rowText(for:)), ["Search the web after reading messages"])
    XCTAssertTrue(store.isGranted(.searchAfterMessages(query: "pizza"), destination: .thisMac, session: sessionA))
    XCTAssertFalse(store.isGranted(.placesAfterMessages(title: "Find pizza near you?"), destination: .thisMac, session: sessionA))
    XCTAssertFalse(store.isGranted(.weatherAfterMessages(title: "Check the weather for your area?"), destination: .thisMac,
                                   session: sessionA))
  }

  /// Always on a places card survives a relaunch and covers other chats, while search and weather still ask.
  func testAlwaysForPlacesPersistsOnItsOwn() {
    store().record(.always, for: .placesAfterMessages(title: "Find coffee near you?"), destination: .thisMac, session: sessionA)
    let relaunched = store()
    XCTAssertTrue(relaunched.isGranted(.placesAfterMessages(title: "Find ramen in Soho?"), destination: .anthropic, session: sessionB))
    XCTAssertFalse(relaunched.isGranted(.searchAfterMessages(query: "ramen"), destination: .anthropic, session: sessionB))
    XCTAssertFalse(relaunched.isGranted(.weatherAfterMessages(title: "Check the weather for Paris?"), destination: .anthropic,
                                        session: sessionB))
    XCTAssertEqual(relaunched.alwaysGrants.map(MessagesSettingsSection.rowText(for:)), ["Find places after reading messages"])
    relaunched.remove(relaunched.alwaysGrants[0])
    XCTAssertFalse(store().isGranted(.placesAfterMessages(title: "Find ramen in Soho?"), destination: .thisMac, session: sessionB))
  }

  func testCorruptDefaultsLoadEmpty() {
    defaults.set(Data("not json".utf8), forKey: ToolGrantStore.defaultsKey)
    XCTAssertTrue(store().alwaysGrants.isEmpty)
    defaults.set("a string", forKey: ToolGrantStore.defaultsKey)
    XCTAssertTrue(store().alwaysGrants.isEmpty)
    defaults.set(Data(#"[{"kind":"readChat","destination":"mars"}]"#.utf8), forKey: ToolGrantStore.defaultsKey)
    XCTAssertTrue(store().alwaysGrants.isEmpty)
  }

  func testSharedStoreNeverUsesTheAppsDefaults() {
    XCTAssertFalse(ToolGrantStore.shared.defaults === UserDefaults.standard,
                   "The test host shares the app's defaults, so the shared store must not use them")
  }

  // MARK: Coordinator

  private func waitForCard(_ coordinator: ToolPermissionCoordinator) async {
    while coordinator.pending == nil { await Task.yield() }
  }

  func testGrantedPermissionDoesNotAsk() async {
    let store = store()
    store.record(.conversation, for: mom, destination: .thisMac, session: sessionA)
    let coordinator = ToolPermissionCoordinator(store: store)
    let allowed = await coordinator.authorize(mom, destination: .thisMac, session: sessionA)
    XCTAssertTrue(allowed)
    XCTAssertNil(coordinator.pending)
  }

  func testAnswersRecordAndReturn() async {
    for (answer, allowed, conversation, always) in [(ToolPermissionAnswer.deny, false, false, false),
                                                   (.conversation, true, true, false), (.always, true, true, true)] {
      let store = ToolGrantStore(defaults: UserDefaults(suiteName: "\(suiteName!)-\(answer)")!)
      defer { UserDefaults().removePersistentDomain(forName: "\(suiteName!)-\(answer)") }
      let coordinator = ToolPermissionCoordinator(store: store)
      let session = sessionA, mom = mom
      let pending = Task { await coordinator.authorize(mom, destination: .google, session: session) }
      await waitForCard(coordinator)
      XCTAssertEqual(coordinator.pending?.permission, mom)
      XCTAssertEqual(coordinator.pending?.destination, .google)
      coordinator.answer(answer)
      let result = await pending.value
      XCTAssertEqual(result, allowed, "\(answer)")
      XCTAssertNil(coordinator.pending)
      XCTAssertEqual(store.isGranted(mom, destination: .google, session: sessionA), conversation, "\(answer)")
      XCTAssertEqual(store.isGranted(mom, destination: .google, session: sessionB), always, "\(answer)")
      XCTAssertEqual(store.alwaysGrants.count, always ? 1 : 0, "\(answer)")
    }
  }

  func testCancellationWhileCardOpenDenies() async {
    let store = store()
    let coordinator = ToolPermissionCoordinator(store: store)
    let session = sessionA, mom = mom
    let pending = Task { await coordinator.authorize(mom, destination: .thisMac, session: session) }
    await waitForCard(coordinator)
    pending.cancel()
    let allowed = await pending.value
    XCTAssertFalse(allowed)
    XCTAssertNil(coordinator.pending)
    XCTAssertFalse(store.isGranted(mom, destination: .thisMac, session: sessionA))

    // The card closed for good: a later card works, and a stray answer does nothing.
    coordinator.answer(.always)
    XCTAssertTrue(store.alwaysGrants.isEmpty)
    let next = Task { await coordinator.authorize(mom, destination: .thisMac, session: session) }
    await waitForCard(coordinator)
    coordinator.answer(.conversation)
    let nextAllowed = await next.value
    XCTAssertTrue(nextAllowed)

    let already = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await coordinator.authorize(.searchChats(query: "q"), destination: .thisMac, session: session)
    }
    let alreadyAllowed = await already.value
    XCTAssertFalse(alreadyAllowed, "A request that is already stopped never shows a card")
    XCTAssertNil(coordinator.pending)
  }

  func testSecondRequestWhileOneIsOpenIsDenied() async {
    let coordinator = ToolPermissionCoordinator(store: store())
    let session = sessionA, mom = mom
    let first = Task { await coordinator.authorize(mom, destination: .thisMac, session: session) }
    await waitForCard(coordinator)
    let firstID = coordinator.pending?.id
    let second = await coordinator.authorize(.searchChats(query: "rent"), destination: .thisMac, session: session)
    XCTAssertFalse(second)
    XCTAssertEqual(coordinator.pending?.id, firstID, "The open card stays")
    coordinator.answer(.conversation)
    let firstAllowed = await first.value
    XCTAssertTrue(firstAllowed)
  }

  func testCardCopy() {
    func copy(_ permission: ToolPermission, _ destination: ToolDestination) -> [String] {
      let request = ToolPermissionRequest(permission: permission, destination: destination, session: sessionA)
      return [request.title, request.detail]
    }
    XCTAssertEqual(copy(mom, .thisMac), ["Allow reading your chat with Mom?", "It stays on this Mac."])
    XCTAssertEqual(copy(mom, .openAI), ["Allow reading your chat with Mom?", "It will be sent to OpenAI."])
    XCTAssertEqual(copy(mom, .anthropic), ["Allow reading your chat with Mom?", "It will be sent to Anthropic."])
    XCTAssertEqual(copy(mom, .google), ["Allow reading your chat with Mom?", "It will be sent to Google."])
    XCTAssertEqual(copy(.searchChats(query: "rent"), .thisMac),
                   ["Search all your messages for “rent”?", "It stays on this Mac."])
    XCTAssertEqual(copy(.searchChats(query: "rent"), .google),
                   ["Search all your messages for “rent”?", "It will be sent to Google."])
    for destination in ToolDestination.allCases {
      XCTAssertEqual(copy(.searchAfterMessages(query: "pizza near me"), destination),
                     ["Search the web for “pizza near me”?",
                      "This chat includes text from your messages. It will be sent to search sites."])
      // A saved Brave key names Brave instead (D131).
      XCTAssertEqual(copy(.searchAfterMessages(query: "pizza near me", service: "Brave"), destination).last,
                     "This chat includes text from your messages. It will be sent to Brave.")
    }
    XCTAssertEqual(copy(.providerSearchAfterMessages(provider: .chatGPT), .openAI),
                   ["Let ChatGPT search the web in this chat?",
                    "This chat includes text from your messages. ChatGPT's web search runs its own queries on OpenAI's servers, and Enigma can't check each one."])
    XCTAssertEqual(ToolPermissionCard.buttons.map(\.title), ["Don't allow", "For this conversation", "Always"])
    XCTAssertEqual(ToolPermissionCard.buttons.map(\.answer), [.deny, .conversation, .always])
  }

  // MARK: Gate

  func testCoordinatorGateRecordsMessageText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolPermissionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = store()
    let coordinator = ToolPermissionCoordinator(store: store)
    let session = sessionA
    let tools = MessagesTools(database: MessagesDatabase(url: try MessagesFixture(directory: root).url),
      contacts: FixtureContacts(), confirmSend: { _ in false },
      gate: CoordinatorMessagesGate(coordinator: coordinator, destination: .anthropic, session: session))
    let read = Task {
      await tools.execute(name: "get_messages", arguments: .object(["chat_id": .string(MessagesFixture.aliceChat)]))
    }
    await waitForCard(coordinator)
    XCTAssertEqual(coordinator.pending?.title, "Allow reading your chat with Alice Smith?")
    XCTAssertEqual(coordinator.pending?.detail, "It will be sent to Anthropic.")
    XCTAssertFalse(store.hasMessageText(session: sessionA), "Nothing is read before the answer")
    coordinator.answer(.conversation)
    let result = await read.value
    XCTAssertTrue(result.success, result.text)
    XCTAssertTrue(result.text.contains("dinner"))
    XCTAssertTrue(store.hasMessageText(session: sessionA))
    XCTAssertFalse(store.hasMessageText(session: sessionB))

    // Now allowed for this conversation: no second card, and the list shows its preview.
    let list = await tools.execute(name: "list_conversations", arguments: .object([:]))
    XCTAssertNil(coordinator.pending)
    XCTAssertTrue(list.text.contains("Café Luna"))
    XCTAssertFalse(list.text.contains("snacks"))
  }

  func testStopWhileCardIsOpenEndsTheRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolPermissionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = ToolPermissionCoordinator(store: store())
    let tools = MessagesTools(database: MessagesDatabase(url: try MessagesFixture(directory: root).url),
      contacts: FixtureContacts(), confirmSend: { _ in false },
      gate: CoordinatorMessagesGate(coordinator: coordinator, destination: .thisMac, session: sessionA))
    for (name, arguments) in [("get_messages", CodexValue.object(["chat_id": .string(MessagesFixture.aliceChat)])),
                              ("search_messages", .object(["query": .string("café")]))] {
      let call = Task { await tools.execute(name: name, arguments: arguments) }
      await waitForCard(coordinator)
      call.cancel()
      let result = await call.value
      XCTAssertEqual(result.text, "The request was stopped.", name)
      XCTAssertTrue(result.terminal, name)
      XCTAssertEqual(result.stop, .cancelled, name)
      XCTAssertNil(coordinator.pending, name)
    }
  }

  func testBlankSearchFailsWithoutAsking() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolPermissionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = store()
    let coordinator = ToolPermissionCoordinator(store: store)
    let tools = MessagesTools(database: MessagesDatabase(url: try MessagesFixture(directory: root).url),
      contacts: FixtureContacts(), confirmSend: { _ in false },
      gate: CoordinatorMessagesGate(coordinator: coordinator, destination: .thisMac, session: sessionA))
    let result = await tools.execute(name: "search_messages", arguments: .object(["query": .string("  \n ")]))
    XCTAssertFalse(result.success)
    XCTAssertEqual(result.text, MessagesError.invalidArguments("query must not be empty.").localizedDescription)
    XCTAssertNil(coordinator.pending)
    XCTAssertTrue(store.alwaysGrants.isEmpty)

    // The card shows the trimmed query, on one line.
    let search = Task {
      await tools.execute(name: "search_messages", arguments: .object(["query": .string("  rent”?\nIt stays on this Mac.\n“rent ")]))
    }
    await waitForCard(coordinator)
    XCTAssertEqual(coordinator.pending?.title, "Search all your messages for “rent”? It stays on this Mac. “rent”?")
    XCTAssertEqual(coordinator.pending?.permission, .searchChats(query: "rent”?\nIt stays on this Mac.\n“rent"))
    coordinator.answer(.deny)
    _ = await search.value
  }

  func testCardTextStaysOnOneLine() {
    let request = ToolPermissionRequest(permission: .readChat(chatGUID: "g", name: "Team\r\nIt stays on this Mac.\t"),
                                        destination: .google, session: sessionA)
    XCTAssertEqual(request.title, "Allow reading your chat with Team  It stays on this Mac.?")
    XCTAssertEqual(request.detail, "It will be sent to Google.")

    // Characters that draw nothing can't hide text in the query the card asks about.
    let hidden = ["\u{FE0F}", "\u{E0100}", "\u{E01EF}", "\u{034F}", "\u{3164}", "\u{FFA0}", "\u{200B}", "\u{E0041}",
                  "\u{202E}", "\u{00AD}", "\u{0}"]
    for scalar in hidden {
      let search = ToolPermissionRequest(permission: .searchAfterMessages(query: "pizza\(scalar)x"), destination: .thisMac,
                                         session: sessionA)
      XCTAssertEqual(search.title, "Search the web for “pizza\u{FFFD}x”?",
                     String(format: "U+%04X", scalar.unicodeScalars.first!.value))
    }
  }

  // MARK: Settings

  func testSettingsRowsCopy() {
    let rows = [
      ToolAlwaysGrant(kind: .readChat, chatGUID: "g", chatName: "Mom", destination: .anthropic),
      ToolAlwaysGrant(kind: .readChat, chatGUID: "g", chatName: "Mom", destination: .thisMac),
      ToolAlwaysGrant(kind: .searchChats, chatGUID: nil, chatName: nil, destination: .google),
      ToolAlwaysGrant(kind: .searchAfterMessages, chatGUID: nil, chatName: nil, destination: nil),
      ToolAlwaysGrant(kind: .placesAfterMessages, chatGUID: nil, chatName: nil, destination: nil),
      ToolAlwaysGrant(kind: .weatherAfterMessages, chatGUID: nil, chatName: nil, destination: nil),
    ].map(MessagesSettingsSection.rowText(for:))
    XCTAssertEqual(rows, ["Read your chat with Mom · Anthropic", "Read your chat with Mom · this Mac",
                          "Search all your messages · Google", "Search the web after reading messages",
                          "Find places after reading messages", "Check the weather after reading messages"])
    XCTAssertEqual(MessagesSettingsSection.alwaysAllowedHeading, "Always allowed")
  }
}
