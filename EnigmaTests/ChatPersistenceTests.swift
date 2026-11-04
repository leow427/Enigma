import Foundation
import XCTest
@testable import Enigma

final class ChatPersistenceTests: XCTestCase {
  func testStoreKeepsTenMostRecentlyActiveChatsInDescendingOrder() throws {
    XCTAssertEqual(ChatSessionStore.maximumRetainedSessions, 10)
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 0)
    let sessions = (0..<11).map { index in
      ChatSession(
        title: "Chat \(index)",
        createdAt: epoch,
        lastActivityAt: epoch.addingTimeInterval(TimeInterval(index))
      )
    }

    try store.save(sessions)

    XCTAssertEqual(store.load().map(\.title), (1...10).reversed().map { "Chat \($0)" })
    // The oldest chat is dropped from the file itself, not just hidden.
    let saved = try String(decoding: Data(contentsOf: root.appending(path: "chats.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains("\"Chat 0\""))
    XCTAssertTrue(saved.contains("\"Chat 1\""))
  }

  /// A history saved when Enigma kept five chats loads as it was.
  func testStoreLoadsAnEarlierFiveChatHistoryUnchanged() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = (0..<5).map { index in
      ChatSession(title: "Chat \(index)", messages: [ChatMessage(role: .user, content: "Question \(index)",
        createdAt: epoch)], createdAt: epoch, lastActivityAt: epoch.addingTimeInterval(TimeInterval(-index)))
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(sessions).write(to: root.appending(path: "chats.json"))

    XCTAssertEqual(store.load(), sessions)
  }

  func testStoreRecoversToAnEmptyArchiveWhenJSONIsUnreadable() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let session = ChatSession(title: "Temporary chat")
    try store.save([session])
    XCTAssertEqual(store.load().map(\.title), [session.title])
    try Data("not json".utf8).write(to: root.appending(path: "chats.json"))

    XCTAssertEqual(store.load(), [])
  }

  func testBundledModelManifestHasValidDownloadMetadata() throws {
    XCTAssertFalse(LocalModelManifest.bundled.models.isEmpty)
    for model in LocalModelManifest.bundled.models {
      XCTAssertNoThrow(try model.validate())
    }
  }

  func testImagePreviewIsExcludedFromEncodedMessages() throws {
    var message = ChatMessage(role: .user, content: "Describe this image")
    message.imagePreview = Data("session-only image bytes".utf8)
    message.turnKind = .screen
    let data = try JSONEncoder().encode(message)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["id", "role", "content", "createdAt"])
    let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
    XCTAssertEqual(restored.content, message.content)
    XCTAssertNil(restored.imagePreview)
    XCTAssertNil(restored.turnKind, "The turn kind is session-only (F3)")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "ChatPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

@MainActor
final class ChatSessionWriterTests: XCTestCase {
  func testCoalescesOneThousandUpdatesBeforeTakingSnapshot() async {
    let probe = makeProbe()
    let delay = ControlledChatSaveDelay()
    let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
    var snapshotsTaken = 0
    var latest = ChatSession()
    for index in 1...1_000 {
      latest.title = "Fragment \(index)"
      writer.schedule {
        snapshotsTaken += 1
        return [latest]
      }
    }
    await fulfillment(of: [delay.started], timeout: 2)
    XCTAssertEqual(snapshotsTaken, 0)
    XCTAssertTrue(probe.snapshots.isEmpty)

    await delay.release()
    await fulfillment(of: [probe.started], timeout: 2)
    await writer.waitForPendingWrites()
    XCTAssertEqual(snapshotsTaken, 1)
    XCTAssertEqual(probe.snapshots.count, 1)
    XCTAssertEqual(probe.store.load().map(\.title), ["Fragment 1000"])
  }

  func testQueuedSnapshotsAndCancelledDelayCannotOverwriteNewerArchiveOrClear() async {
    for clear in [false, true] {
      let probe = makeProbe(blockFirst: true)
      defer { probe.release() }
      let delay = ControlledChatSaveDelay()
      let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
      let old = ChatSession(title: "Old")
      writer.schedule(immediately: true) { [old] }
      await fulfillment(of: [probe.started], timeout: 2)
      writer.schedule { [ChatSession(title: "Stale delayed snapshot")] }
      await fulfillment(of: [delay.started], timeout: 2)
      for index in 1...100 {
        writer.schedule(immediately: true) { [ChatSession(title: "Superseded \(index)")] }
      }
      let latest = clear ? [] : [ChatSession(title: "Newest")]
      writer.schedule(immediately: true) { latest }
      // The fake delay deliberately ignores cancellation and wakes after the
      // newer snapshot/clear, exercising the cancelled timer's ownership check.
      await delay.release()
      XCTAssertEqual(probe.snapshots.count, 1, "A blocked write must not start concurrent replacements")
      probe.release()
      await writer.waitForPendingWrites()
      XCTAssertEqual(probe.snapshots.map { $0.map(\.title) }, [["Old"], latest.map(\.title)])
      XCTAssertEqual(probe.store.load().map(\.id), latest.map(\.id))
    }
  }

  private func makeProbe(blockFirst: Bool = false) -> ChatArchiveWriteProbe {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ChatWriterTests-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return ChatArchiveWriteProbe(store: ChatSessionStore(applicationSupportDirectory: directory), blockFirst: blockFirst)
  }
}

/// A gated real archive write: verifies encoding/replacement never run on the UI thread.
final class ChatArchiveWriteProbe: @unchecked Sendable {
  let store: ChatSessionStore
  let started = XCTestExpectation(description: "Background archive write started")
  let secondFinished = XCTestExpectation(description: "Second archive write finished")
  private let blockFirst: Bool
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var recorded: [[ChatSession]] = []
  private var finishedFirst = false
  var snapshots: [[ChatSession]] { lock.withLock { recorded } }
  /// Whether the first write has returned, which a blocked first write does only after `release()`.
  var firstWriteFinished: Bool { lock.withLock { finishedFirst } }

  init(store: ChatSessionStore, blockFirst: Bool = false) {
    self.store = store
    self.blockFirst = blockFirst
  }

  func write(_ sessions: [ChatSession]) throws {
    XCTAssertFalse(Thread.isMainThread, "Serialization and disk replacement must be off the main thread")
    let count = lock.withLock { recorded.append(sessions); return recorded.count }
    if count == 1 {
      started.fulfill()
      if blockFirst { gate.wait() }
    }
    defer { if count == 1 { lock.withLock { finishedFirst = true } } }
    try store.save(sessions)
    if count == 2 { secondFinished.fulfill() }
  }

  func release() { gate.signal() }
}

actor ControlledChatSaveDelay {
  nonisolated let started = XCTestExpectation(description: "Coalescing delay started")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait(_ duration: Duration) async {
    XCTAssertEqual(duration, .milliseconds(500))
    await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }
  func release() { continuation?.resume(); continuation = nil }
}

// MARK: Model-written chat titles (F38)

@MainActor
final class ChatTitleTests: XCTestCase {
  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appending(path: "ChatTitleTests-\(UUID())")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
  }

  func testFirstQuestionIsTheInstantPlaceholder() {
    var session = ChatSession()
    session.append(ChatMessage(role: .user, content: "  " + String(repeating: "word ", count: 20)))
    XCTAssertEqual(session.title, String(String(repeating: "word ", count: 20).prefix(48)))
  }

  func testGeneratedTitleReplacesOnlyTheAutoTitleOnce() {
    var session = ChatSession()
    session.append(ChatMessage(role: .user, content: "my swift build fails with an error about actors"))
    XCTAssertTrue(session.applyGeneratedTitle("Fix Swift build error"))
    XCTAssertEqual(session.title, "Fix Swift build error")
    XCTAssertFalse(session.applyGeneratedTitle("Something else"), "A chat is titled once")
    XCTAssertEqual(session.title, "Fix Swift build error")

    var renamed = ChatSession()
    renamed.append(ChatMessage(role: .user, content: "Hello"))
    renamed.title = "Mine"
    XCTAssertFalse(renamed.applyGeneratedTitle("Greeting"))
    XCTAssertEqual(renamed.title, "Mine")
    var empty = ChatSession()
    XCTAssertFalse(empty.applyGeneratedTitle("No question yet"))
  }

  func testModelOutputIsCleanedUp() {
    XCTAssertEqual(ChatSession.generatedTitle(from: "\"Weekend trip to Lisbon.\""), "Weekend trip to Lisbon")
    XCTAssertEqual(ChatSession.generatedTitle(from: "Title: **Fix   Swift build error!**\nMore text"), "Fix Swift build error")
    XCTAssertEqual(ChatSession.generatedTitle(from: "\n\n“Why is the sky blue?”"), "Why is the sky blue")
    XCTAssertEqual(ChatSession.generatedTitle(from: "<think>short</think>\nRecipe ideas"), "Recipe ideas")
    XCTAssertNil(ChatSession.generatedTitle(from: "<think>still thinking about"), "Cut off mid-thought")
    XCTAssertNil(ChatSession.generatedTitle(from: "   \n \"\" "), "Nothing usable")
    XCTAssertNil(ChatSession.generatedTitle(from: "one two three four five six seven eight nine"), "Over eight words")
    XCTAssertEqual(ChatSession.generatedTitle(from: "one two three four five six seven eight"), "one two three four five six seven eight")
    XCTAssertNil(ChatSession.generatedTitle(from: String(repeating: "a", count: 49)), "Over 48 characters")
    XCTAssertEqual(ChatSession.generatedTitle(from: "Here's a short title:\n\nWeekend Trip to Lisbon"), "Weekend Trip to Lisbon")
    XCTAssertEqual(ChatSession.generatedTitle(from: "Sure! Here is a title for this chat:\n**Lisbon Weekend Plan**"),
                   "Lisbon Weekend Plan")
    XCTAssertEqual(ChatSession.generatedTitle(from: "Async await in C#"), "Async await in C#")
    XCTAssertEqual(ChatSession.generatedTitle(from: "## Learning F#"), "Learning F#")
  }

  private func chat(_ engine: TitleEngine, keepsPrivate: Bool = false) async -> LocalChatViewModel {
    let settings = SelectionEditingSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.keepsChatsPrivate = keepsPrivate
    let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: settings,
                                  sessionStore: ChatSessionStore(applicationSupportDirectory: root),
                                  sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }, writesTitles: true)
    await chat.refreshInstalledModel()
    return chat
  }

  private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("Timed out", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func reply(_ chat: LocalChatViewModel, _ prompt: String) async throws {
    let count = chat.messages.count
    chat.submit(prompt)
    try await waitUntil { !chat.isBusy && chat.messages.count == count + 2 }
  }

  private static let question = "can you help me plan a long weekend in lisbon with good food and some museums"

  func testTitleIsWrittenAfterTheFirstReplyAndSaved() async throws {
    let engine = TitleEngine(title: "\"Weekend trip to Lisbon.\"")
    let chat = await chat(engine)
    try await reply(chat, Self.question)
    try await waitUntil { chat.selectedSession?.title == "Weekend trip to Lisbon" }
    let request = try XCTUnwrap(engine.titleRequests.first)
    XCTAssertEqual(request.messages.count, 1, "Only the request, no chat history")
    XCTAssertTrue(request.prompt.contains(Self.question))
    XCTAssertTrue(request.prompt.contains("Reply."), "With the start of the reply")
    XCTAssertEqual(request.temperature, 0)
    XCTAssertEqual(request.maximumTokenCount, LocalChatViewModel.titleOutputTokens)
    try await waitUntil {
      ChatSessionStore(applicationSupportDirectory: self.root).load().first?.title == "Weekend trip to Lisbon"
    }

    // Later turns don't retitle it.
    try await reply(chat, "And day two?")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(engine.titleRequests.count, 1)
    XCTAssertEqual(chat.selectedSession?.title, "Weekend trip to Lisbon")
  }

  func testFailureOrUnusableOutputKeepsTheFirstQuestionTitle() async throws {
    for engine in [TitleEngine(fails: true), TitleEngine(title: ""),
                   TitleEngine(title: "A very long rambling title that has far too many words")] {
      let chat = await chat(engine)
      try await reply(chat, Self.question)
      try await waitUntil { engine.titleRequests.count == 1 }
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(chat.selectedSession?.title, ChatSession.title(for: Self.question))
      try await reply(chat, "And day two?")
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(engine.titleRequests.count, 1, "Not asked again on later turns")
    }
  }

  func testNoTitleAfterAFailedReply() async throws {
    let engine = TitleEngine(title: "Lisbon", replyFails: true)
    let chat = await chat(engine)
    chat.submit(Self.question)
    try await waitUntil { !chat.isBusy && engine.replies == 1 }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(engine.titleRequests.isEmpty)
  }

  func testANewSendCancelsTheTitleCall() async throws {
    let engine = TitleEngine(title: "Weekend trip to Lisbon", titleWaits: true)
    let chat = await chat(engine)
    try await reply(chat, Self.question)
    try await waitUntil { engine.titleRequests.count == 1 }
    try await reply(chat, "And day two?")
    XCTAssertTrue(engine.titleCancelled, "The send cancels the title call rather than waiting behind it")
    await engine.titleGate.open()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(chat.selectedSession?.title, ChatSession.title(for: Self.question))
    XCTAssertEqual(engine.titleRequests.count, 1)
  }

  func testTitleAfterAFailedFirstReplyComesFromTheAnsweredQuestion() async throws {
    let engine = TitleEngine(title: "Weekend trip to Lisbon", failsFirstReply: true)
    let chat = await chat(engine)
    chat.submit(Self.question)
    try await waitUntil { !chat.isBusy && engine.replies == 1 }
    XCTAssertTrue(engine.titleRequests.isEmpty)
    try await reply(chat, "plan three days in lisbon please")
    try await waitUntil { chat.selectedSession?.title == "Weekend trip to Lisbon" }
    XCTAssertTrue(engine.titleRequests.first?.prompt.contains("plan three days in lisbon please") == true)
  }

  func testTitleAfterAFirstReplyStoppedWithText() async throws {
    let engine = TitleEngine(title: "Weekend trip to Lisbon", partialFirstReply: true)
    let chat = await chat(engine)
    chat.submit(Self.question)
    try await waitUntil { chat.messages.last?.content == "Partial" }
    await chat.stopStreaming()?.value
    try await waitUntil { !chat.isBusy }
    try await reply(chat, "plan three days in lisbon please")
    try await waitUntil { chat.selectedSession?.title == "Weekend trip to Lisbon" }
  }

  func testNoTitleWhileAMessageIsQueued() async throws {
    let engine = TitleEngine(title: "Weekend trip to Lisbon", replyWaits: true)
    let chat = await chat(engine)
    chat.submit(Self.question)
    try await waitUntil { engine.replies == 1 }
    XCTAssertTrue(chat.queueMessage("And day two?"))
    await engine.replyGate.open()
    // No sender is wired here, so the queued message stays queued once the reply finishes.
    try await waitUntil { !chat.isBusy && chat.messages.count == 2 }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(chat.messageQueue.isEmpty)
    XCTAssertTrue(engine.titleRequests.isEmpty, "The queued message sends next, and would only cancel it")
  }

  func testTemporaryChatsAreNotTitled() async throws {
    let engine = TitleEngine(title: "Explain the passage")
    let chat = await chat(engine, keepsPrivate: true)
    chat.startTemporaryChat(context: nil)
    try await reply(chat, Self.question)
    chat.openTemporaryChatInWindow()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(engine.titleRequests.isEmpty, "A private selection chat is never titled")
    XCTAssertTrue(chat.isTemporaryChat)
  }

  func testTemporaryChatOpenedAsAnOrdinaryChatIsTitled() async throws {
    let engine = TitleEngine(title: "Explain the passage")
    let chat = await chat(engine)
    chat.startTemporaryChat(context: nil)
    try await reply(chat, Self.question)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(engine.titleRequests.isEmpty, "Not while it's temporary")
    chat.openTemporaryChatInWindow()
    try await waitUntil { chat.selectedSession?.title == "Explain the passage" }
    XCTAssertEqual(engine.titleRequests.count, 1)
  }
}

private actor TitleGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

/// Replies "Reply."; a title request gets `title`, or fails, or waits for `titleGate`.
private final class TitleEngine: LocalModelEngine, @unchecked Sendable {
  let model = LocalModel(id: "titles", displayName: "Titles", fileURL: URL(fileURLWithPath: "/tmp/titles.gguf"))
  let titleGate = TitleGate()
  let replyGate = TitleGate()
  private let title: String, fails: Bool, titleWaits: Bool, replyFails: Bool, replyWaits: Bool, failsFirstReply: Bool, partialFirstReply: Bool
  private let lock = NSLock()
  private var recorded: [LocalModelRequest] = []
  private var cancelled = false
  var titleRequests: [LocalModelRequest] { lock.withLock { recorded.filter(Self.titles) } }
  var replies: Int { lock.withLock { recorded.filter { !Self.titles($0) }.count } }
  var titleCancelled: Bool { lock.withLock { cancelled } }

  init(title: String = "", fails: Bool = false, titleWaits: Bool = false, replyFails: Bool = false, replyWaits: Bool = false,
       failsFirstReply: Bool = false, partialFirstReply: Bool = false) {
    (self.title, self.fails, self.titleWaits, self.replyFails, self.replyWaits) = (title, fails, titleWaits, replyFails, replyWaits)
    (self.failsFirstReply, self.partialFirstReply) = (failsFirstReply, partialFirstReply)
  }

  private static func titles(_ request: LocalModelRequest) -> Bool { request.prompt.hasPrefix("Write a title") }

  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor,
                progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.noModelInstalled
  }
  func unload() async {}
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    let isTitle = Self.titles(request)
    let isFirstReply = lock.withLock {
      recorded.append(request)
      return !isTitle && recorded.filter { !Self.titles($0) }.count == 1
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        if isTitle, self.titleWaits { await self.titleGate.wait() }
        if !isTitle, self.replyWaits { await self.replyGate.wait() }
        if self.partialFirstReply, isFirstReply {
          continuation.yield("Partial")
          await self.replyGate.wait()  // Until stopped: the gate never opens.
        }
        if Task.isCancelled { return continuation.finish(throwing: CancellationError()) }
        if isTitle ? self.fails : self.replyFails || (self.failsFirstReply && isFirstReply) {
          return continuation.finish(throwing: LocalInferenceError.bridgeFailure("failed"))
        }
        continuation.yield(isTitle ? self.title : "Reply.")
        continuation.finish()
      }
      continuation.onTermination = { reason in
        if isTitle, case .cancelled = reason { self.lock.withLock { self.cancelled = true } }
        task.cancel()
      }
    }
  }
}
