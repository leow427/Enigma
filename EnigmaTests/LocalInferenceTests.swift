import Foundation
import XCTest
@testable import Enigma

final class LocalInferenceTests: XCTestCase {
  func testInstallationStoreCopiesGGUFAndRestoresSelection() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LocalModelInstallationStoreTests-\(UUID().uuidString)")
    let sourceURL = root.appending(path: "source.gguf")
    let modelsURL = root.appending(path: "models", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("GGUF fixture".utf8).write(to: sourceURL)

    let store = LocalModelInstallationStore(modelsDirectory: modelsURL)
    let installed = try store.install(
      LocalModel(id: "Fixture Model", displayName: "Fixture", fileURL: sourceURL)
    )

    XCTAssertEqual(installed.displayName, "Fixture")
    XCTAssertEqual(installed.fileURL.pathExtension, "gguf")
    XCTAssertEqual(installed.fileURL.deletingLastPathComponent(), modelsURL)
    XCTAssertEqual(try Data(contentsOf: installed.fileURL), Data("GGUF fixture".utf8))
    XCTAssertEqual(store.installedModel(), installed)

    try Data("replacement fixture".utf8).write(to: sourceURL)
    let replacement = try store.install(
      LocalModel(id: "Fixture Model", displayName: "Replacement", fileURL: sourceURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: replacement.fileURL),
      Data("replacement fixture".utf8)
    )
    XCTAssertNotEqual(replacement.fileURL, installed.fileURL)
    XCTAssertEqual(store.installedModels().count, 1)
    XCTAssertEqual(store.installedModel()?.displayName, "Replacement")

    let secondSourceURL = root.appending(path: "second.gguf")
    try Data("second fixture".utf8).write(to: secondSourceURL)
    let secondInstalled = try store.install(
      LocalModel(id: "Second Model", displayName: "Second", fileURL: secondSourceURL)
    )
    XCTAssertEqual(store.installedModels().map(\.id), ["Fixture Model", "Second Model"])

    try store.selectModel(id: installed.id)
    XCTAssertEqual(store.installedModel()?.id, installed.id)
    XCTAssertEqual(secondInstalled.id, "Second Model")
  }

  func testInstallationStoreRejectsNonGGUFFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LocalModelInstallationStoreTests-\(UUID().uuidString)")
    let sourceURL = root.appending(path: "model.txt")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not a model".utf8).write(to: sourceURL)

    let store = LocalModelInstallationStore(
      modelsDirectory: root.appending(path: "models")
    )

    XCTAssertThrowsError(
      try store.install(LocalModel(id: "bad", displayName: "Bad", fileURL: sourceURL))
    ) { error in
      XCTAssertEqual(error as? LocalInferenceError, .invalidModelFile)
    }
  }

  @MainActor
  func testViewModelStreamsPartialMarkdownIntoAssistantMessage() async {
    let installedModel = fixtureModel()
    let engine = MockLocalModelEngine(
      installedModel: installedModel,
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("**Local")
          continuation.yield(" response**")
          continuation.finish()
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await viewModel.refreshInstalledModel()

    viewModel.submit("Hello")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }

    XCTAssertEqual(viewModel.messages[0].content, "Hello")
    XCTAssertEqual(viewModel.messages[1].content, "**Local response**")
    XCTAssertEqual(engine.requests.map(\.prompt), ["Hello"])
  }

  @MainActor
  func testViewModelInstallsSelectedModelThroughEngine() async {
    let engine = MockLocalModelEngine()
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    let selectedURL = URL(fileURLWithPath: "/tmp/My Model.gguf")

    viewModel.installModel(from: selectedURL)
    await waitUntil { viewModel.installedModel != nil && viewModel.modelOperation == nil && !viewModel.isManagingModels }

    XCTAssertEqual(viewModel.installedModel?.displayName, "My Model")
    XCTAssertEqual(viewModel.installedModel?.fileURL, selectedURL)
  }

  @MainActor
  func testViewModelDeletesInstalledModelAfterUnloadingIt() async {
    let installed = fixtureModel()
    let engine = MockLocalModelEngine(installedModel: installed)
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await viewModel.refreshInstalledModel()

    viewModel.deleteModel(id: installed.id)
    await waitUntil { viewModel.modelOperation == nil && !viewModel.isManagingModels && viewModel.installedModels.isEmpty }

    XCTAssertNil(viewModel.installedModel)
    XCTAssertEqual(engine.deletedIDs, [installed.id])
    XCTAssertEqual(engine.unloadCount, 1)
  }

  @MainActor
  func testViewModelPreservesPartialOutputWhenStreamFails() async {
    let engine = MockLocalModelEngine(
      installedModel: fixtureModel(),
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Partial")
          continuation.finish(throwing: MockError.failed)
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())

    viewModel.submit("Hello")
    await waitUntil {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertEqual(viewModel.messages.last?.content, "Partial")
    XCTAssertEqual(viewModel.state, .failed("The mocked stream failed."))
  }

  @MainActor
  func testStopStreamingCancelsTheUnderlyingStream() async {
    let cancellation = CancellationProbe()
    let engine = MockLocalModelEngine(
      installedModel: fixtureModel(),
      stream: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("First")
          continuation.onTermination = { @Sendable _ in
            cancellation.record()
          }
        }
      }
    )
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())

    viewModel.submit("Hello")
    await waitUntil { viewModel.messages.last?.content == "First" }
    viewModel.stopStreaming()
    await waitUntil { cancellation.wasRecorded }

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.messages.last?.content, "First")
  }

  @MainActor
  func testIdlePolicyUnloadsModelWithoutPollingDelays() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(
      engine: engine,
      sessionStore: makeSessionStore(),
      sleep: { XCTAssertEqual($0, .seconds(60)) }
    )

    viewModel.applicationBecameInactive()
    await waitUntil { engine.unloadCount == 1 }

    XCTAssertEqual(engine.unloadCount, 1)
  }

  @MainActor
  func testCompletedReplyUnloadsAfterOneMinuteEvenWithTheChatOpen() async {
    let deadline = ControlledLocalIdleSleep()
    addTeardownBlock { await deadline.close() }
    let engine = MockLocalModelEngine(installedModel: fixtureModel(), stream: { _ in
      AsyncThrowingStream { $0.yield("Reply"); $0.finish() }
    })
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore(),
      sleep: { try await deadline.sleep($0) })

    viewModel.submit("Hello")
    await fulfillment(of: [deadline.armed[0]], timeout: 2)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(engine.unloadCount, 0)
    // Repeated panel and app notifications must neither cancel nor reset the deadline.
    viewModel.applicationBecameInactive()
    viewModel.applicationBecameActive()
    viewModel.applicationBecameInactive()
    viewModel.applicationBecameActive()
    await deadline.expire(0)
    await waitUntil { engine.unloadCount == 1 }

    XCTAssertEqual(viewModel.messages.map(\.content), ["Hello", "Reply"])
    let delays = await deadline.delays
    XCTAssertEqual(delays, [.seconds(60)])
    viewModel.submit("Follow-up")
    await waitUntil { engine.requests.count == 2 && viewModel.state == .idle }
    XCTAssertEqual(engine.requests.last?.messages.map(\.content), ["Hello", "Reply", "Follow-up"])
  }

  @MainActor
  func testFollowupCancelsOldIdleDeadlineAndStartsANewOneAfterFinishing() async {
    let deadline = ControlledLocalIdleSleep(expectedSleeps: 2)
    addTeardownBlock { await deadline.close() }
    let (followup, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let engine = MockLocalModelEngine(installedModel: fixtureModel(), stream: { request in
      request.prompt == "Follow-up" ? followup : AsyncThrowingStream { $0.yield("Reply"); $0.finish() }
    })
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore(),
      sleep: { try await deadline.sleep($0) })
    viewModel.submit("Hello")
    await fulfillment(of: [deadline.armed[0]], timeout: 2)

    viewModel.submit("Follow-up")
    await waitUntil { engine.requests.count == 2 }
    viewModel.applicationBecameInactive()
    // Deliberately wake a cancelled sleeper while the replacement is still generating.
    await deadline.expire(0)
    continuation.yield("Still working")
    await waitUntil { viewModel.messages.last?.content == "Still working" }
    XCTAssertEqual(engine.unloadCount, 0)
    XCTAssertTrue(viewModel.isBusy)

    continuation.finish()
    await fulfillment(of: [deadline.armed[1]], timeout: 2)
    XCTAssertEqual(engine.unloadCount, 0)
    await deadline.expire(1)
    await waitUntil { engine.unloadCount == 1 }
    let delays = await deadline.delays
    XCTAssertEqual(delays, [.seconds(60), .seconds(60)])
  }

  @MainActor
  func testRejectedCloudRequestPreservesPendingLocalUnload() async {
    let deadline = ControlledLocalIdleSleep()
    addTeardownBlock { await deadline.close() }
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore(),
      sleep: { try await deadline.sleep($0) })
    viewModel.submit("Hello")
    await fulfillment(of: [deadline.armed[0]], timeout: 2)

    viewModel.submitCloud("Invalid chat model", provider: .openAI, modelID: "dall-e-3")
    XCTAssertEqual(viewModel.state, .failed(CloudProviderError.unsupportedModel(.openAI, modelID: "dall-e-3").localizedDescription))
    XCTAssertFalse(viewModel.isBusy)
    await deadline.expire(0)
    await waitUntil { engine.unloadCount == 1 }
  }

  @MainActor
  func testStoppedAndFailedRepliesStillScheduleIdleUnloading() async {
    for shouldStop in [true, false] {
      let deadline = ControlledLocalIdleSleep()
      addTeardownBlock { await deadline.close() }
      let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
      let engine = MockLocalModelEngine(installedModel: fixtureModel(), stream: { _ in stream })
      let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore(),
        sleep: { try await deadline.sleep($0) })
      viewModel.submit("Hello")
      continuation.yield("Partial reply")
      await waitUntil { viewModel.messages.last?.content == "Partial reply" }
      if shouldStop {
        await viewModel.stopStreaming()?.value
      } else {
        continuation.finish(throwing: MockError.failed)
      }
      await fulfillment(of: [deadline.armed[0]], timeout: 2)
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertEqual(engine.unloadCount, 0)
      await deadline.expire(0)
      await waitUntil { engine.unloadCount == 1 }
      XCTAssertEqual(viewModel.messages.last?.content, "Partial reply")
      let delays = await deadline.delays
      XCTAssertEqual(delays, [.seconds(60)])
    }
  }

  func testLlamaEngineDoesNotLoadWithoutAnInstalledModel() async {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "LlamaCPPModelEngineTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = LlamaCPPModelEngine(
      installationStore: LocalModelInstallationStore(modelsDirectory: root)
    )

    do {
      for try await _ in engine.stream(LocalModelRequest(prompt: "Hello")) {}
      XCTFail("Expected the stream to reject a missing local model")
    } catch {
      XCTAssertEqual(error as? LocalInferenceError, .noModelInstalled)
    }
  }

  @MainActor
  func testLocalFollowupReceivesHistoryAndSwitchingChatsDoesNotLeakIt() async throws {
    let engine = MockLocalModelEngine(installedModel: fixtureModel(), stream: { _ in
      AsyncThrowingStream { $0.yield("response"); $0.finish() }
    })
    let store = makeSessionStore()
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store)
    viewModel.submit("First question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }
    let firstSession = try XCTUnwrap(viewModel.selectedSessionID)
    viewModel.submit("Second question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 4 }
    XCTAssertEqual(engine.requests[1].messages.map(\.content), ["First question", "response", "Second question"])
    XCTAssertEqual(engine.requests[1].messages.map(\.role), [.user, .assistant, .user])
    viewModel.newChat()
    viewModel.submit("Separate question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 2 }
    XCTAssertEqual(engine.requests[2].messages.map(\.content), ["Separate question"])
    viewModel.selectSession(id: firstSession)
    viewModel.submit("Third question")
    await waitUntil { viewModel.state == .idle && viewModel.messages.count == 6 }
    XCTAssertEqual(engine.requests[3].messages.map(\.content), ["First question", "response", "Second question", "response", "Third question"])
    await viewModel.sessionWriter.waitForPendingWrites()
    let saved = try XCTUnwrap(store.load().first { $0.id == firstSession }?.messages)
    XCTAssertEqual(saved.map(\.id), viewModel.messages.map(\.id))
    XCTAssertEqual(saved.map(\.role), viewModel.messages.map(\.role))
    XCTAssertEqual(saved.map(\.content), viewModel.messages.map(\.content))
  }

  @MainActor
  func testLocalTrimmingDoesNotDeletePersistedHistory() async throws {
    let store = makeSessionStore()
    let original = [
      ChatMessage(role: .user, content: String(repeating: "old", count: 2_000)),
      ChatMessage(role: .assistant, content: "old reply"),
      ChatMessage(role: .user, content: "recent"),
      ChatMessage(role: .assistant, content: "recent reply"),
    ]
    try store.save([ChatSession(messages: original)])
    let persistedOriginal = store.load()[0].messages
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store)
    viewModel.submit("current")
    await waitUntil { viewModel.state == .idle && engine.requests.count == 1 }
    XCTAssertEqual(engine.requests[0].messages.map(\.content), ["recent", "recent reply", "current"])
    await viewModel.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(Array(store.load()[0].messages.prefix(4)), persistedOriginal)
    XCTAssertEqual(store.load()[0].messages.count, 6)
    XCTAssertNotNil(viewModel.contextNotice)
  }

  @MainActor
  func testContextRejectionPreservesDraftAndDoesNotPersistOrGenerate() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let store = makeSessionStore()
    let probe = ChatArchiveWriteProbe(store: store)
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store,
      sessionWriter: ChatSessionWriter(write: probe.write))
    let original = "  " + String(repeating: "x", count: 40_000) + "\n"
    var draft = original
    viewModel.submit(draft, onAccepted: { draft = "" })
    await waitUntil { if case .failed = viewModel.state { return true }; return false }
    XCTAssertEqual(draft, original)
    XCTAssertTrue(engine.requests.isEmpty)
    await viewModel.sessionWriter.waitForPendingWrites()
    XCTAssertTrue(store.load().isEmpty)
    for provider in CloudProviderID.allCases {
      viewModel.submitCloud(draft, provider: provider, modelID: "manual", onAccepted: { draft = "" })
      XCTAssertEqual(draft, original)
      XCTAssertTrue(viewModel.messages.isEmpty)
      await viewModel.sessionWriter.waitForPendingWrites()
      XCTAssertTrue(store.load().isEmpty)
      guard case .failed(let message) = viewModel.state else { return XCTFail("Expected context rejection") }
      XCTAssertTrue(message.contains("Shorten"))
    }
    XCTAssertTrue(probe.snapshots.isEmpty, "A rejected draft must not schedule an archive write")
  }

  @MainActor
  func testAcceptedLocalRequestClearsDraftOnlyAfterPreparation() async {
    let engine = MockLocalModelEngine(installedModel: fixtureModel())
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    var draft = "Hello"
    viewModel.submit(draft, onAccepted: { draft = "" })
    XCTAssertEqual(draft, "Hello")
    await waitUntil { viewModel.state == .idle && engine.requests.count == 1 }
    XCTAssertEqual(draft, "")
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    iterations: Int = 1_000
  ) async {
    for _ in 0..<iterations {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Condition was not satisfied")
  }

  private func fixtureModel() -> LocalModel {
    LocalModel(
      id: "fixture",
      displayName: "Fixture",
      fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf")
    )
  }

  private func makeSessionStore() -> ChatSessionStore {
    ChatSessionStore(
      applicationSupportDirectory: FileManager.default.temporaryDirectory
        .appending(path: "LocalInferenceTests-\(UUID().uuidString)")
    )
  }
}

private enum MockError: LocalizedError {
  case failed

  var errorDescription: String? { "The mocked stream failed." }
}

/// Lets lifecycle tests fire old and current deadlines without wall-clock delays.
/// Cancellation is intentionally ignored so the production ownership checks run.
actor ControlledLocalIdleSleep {
  nonisolated let armed: [XCTestExpectation]
  private(set) var delays: [Duration] = []
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  private var isClosed = false

  init(expectedSleeps: Int = 1) {
    armed = (0..<expectedSleeps).map { XCTestExpectation(description: "Idle deadline \($0) armed") }
  }

  func sleep(_ duration: Duration) async throws {
    guard !isClosed else { throw CancellationError() }
    let index = delays.count
    delays.append(duration)
    await withCheckedContinuation { continuation in
      pending[index] = continuation
      if armed.indices.contains(index) { armed[index].fulfill() }
    }
  }

  func expire(_ index: Int) {
    pending.removeValue(forKey: index)?.resume()
  }

  func close() {
    isClosed = true
    let waiters = pending.values
    pending.removeAll()
    for continuation in waiters { continuation.resume() }
  }
}

private final class MockLocalModelEngine: LocalModelEngine, @unchecked Sendable {
  typealias StreamFactory = @Sendable (LocalModelRequest) -> AsyncThrowingStream<String, Error>

  private let lock = NSLock()
  private let streamFactory: StreamFactory
  private var storedModel: LocalModel?
  private var storedRequests: [LocalModelRequest] = []
  private var storedUnloadCount = 0
  private var storedDeletedIDs: [String] = []

  init(
    installedModel: LocalModel? = nil,
    stream: @escaping StreamFactory = { _ in
      AsyncThrowingStream { $0.finish() }
    }
  ) {
    storedModel = installedModel
    streamFactory = stream
  }

  var requests: [LocalModelRequest] {
    access { storedRequests }
  }

  var unloadCount: Int {
    access { storedUnloadCount }
  }

  var deletedIDs: [String] {
    access { storedDeletedIDs }
  }

  func install(_ model: LocalModel) async throws {
    access { storedModel = model }
  }

  func installedModel() async -> LocalModel? {
    access { storedModel }
  }

  func installedModels() async -> [LocalModel] {
    access { storedModel.map { [$0] } ?? [] }
  }

  func selectModel(id: String) async throws {
    guard access({ storedModel?.id == id }) else {
      throw LocalInferenceError.unknownInstalledModel
    }
  }

  func deleteModel(id: String) async throws {
    guard access({ storedModel?.id == id }) else {
      throw LocalInferenceError.unknownInstalledModel
    }
    access {
      storedModel = nil
      storedDeletedIDs.append(id)
    }
  }

  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    let localModel = LocalModel(
      id: model.id,
      displayName: model.displayName,
      fileURL: URL(fileURLWithPath: "/tmp/\(model.id).gguf")
    )
    access { storedModel = localModel }
    await progress(ModelDownloadProgress(
      receivedByteCount: model.expectedByteCount,
      expectedByteCount: model.expectedByteCount
    ))
    return localModel
  }

  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    access { storedRequests.append(request) }
    return streamFactory(request)
  }

  func unload() async {
    access { storedUnloadCount += 1 }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false

  var wasRecorded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record() {
    lock.lock()
    recorded = true
    lock.unlock()
  }
}

/// Installing a model runs beside chat: only the final commit and the
/// performance check wait for, and briefly hold, an idle chat.
@MainActor
final class ConcurrentModelInstallTests: XCTestCase {
  func testCloudAndLocalChatRunWhileAModelDownloads() async throws {
    let engine = InstallingEngine()
    let cloud = InstantCloud()
    let chat = LocalChatViewModel(engine: engine,
      cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud, gemini: cloud),
      sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    XCTAssertEqual(chat.modelOperation, .downloading(ModelDownloadProgress(receivedByteCount: 1, expectedByteCount: 2)))
    XCTAssertTrue(chat.isManagingModels)
    XCTAssertFalse(chat.isBusy, "A download must not lock the composer")

    chat.submit("Hello locally")
    try await until { chat.state == .idle && chat.messages.last?.content == "Local reply" }
    XCTAssertEqual(engine.requests.count, 1)
    chat.submitCloud("Hello cloud", provider: .openAI, modelID: "gpt-test")
    try await until { chat.state == .idle && chat.messages.last?.content == "Cloud reply" }
    XCTAssertEqual(chat.modelOperation, .downloading(ModelDownloadProgress(receivedByteCount: 1, expectedByteCount: 2)),
                   "Chat state changes must not overwrite download progress")

    engine.finishDownload()
    try await until { chat.modelOperation == nil && !chat.isManagingModels }
    XCTAssertEqual(chat.installedModel?.id, InstallingEngine.newID)
  }

  func testModelChangesAreRefusedWhileAnInstallRuns() async throws {
    let engine = InstallingEngine()
    let chat = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    XCTAssertFalse(chat.canChangeModels)
    chat.downloadModel(LocalModelManifest.bundled.models[1])
    chat.selectModel(id: InstallingEngine.oldID)
    chat.deleteModel(id: InstallingEngine.oldID)
    chat.installModel(from: URL(fileURLWithPath: "/tmp/imported.gguf"))
    chat.runModelBenchmark()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(engine.downloadCount, 1)
    XCTAssertEqual(engine.managementCalls, [])
    XCTAssertEqual(chat.modelOperation, .downloading(ModelDownloadProgress(receivedByteCount: 1, expectedByteCount: 2)))

    chat.cancelInstallation()
    XCTAssertTrue(chat.isManagingModels, "Model changes stay refused until cancellation is acknowledged")
    XCTAssertFalse(chat.isBusy)
    engine.finishDownload()
    try await until { !chat.isManagingModels }
    XCTAssertTrue(chat.canChangeModels)
    XCTAssertEqual(engine.commitCount, 0)
    XCTAssertEqual(chat.installedModel?.id, InstallingEngine.oldID)
  }

  func testAnInstallFinishingDuringALocalReplySwitchesModelsOnlyAfterTheReply() async throws {
    let (reply, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let engine = InstallingEngine(stream: reply)
    let chat = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    chat.submit("Keep answering with the old model")
    continuation.yield("Partial")
    try await until { chat.messages.last?.content == "Partial" }

    engine.finishDownload()
    try await until { engine.isWaitingToCommit }
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(engine.commitCount, 0, "The install must not switch models mid-reply")
    XCTAssertEqual(chat.installedModel?.id, InstallingEngine.oldID)
    XCTAssertEqual(chat.activeRequest?.route.modelID, InstallingEngine.oldID)
    XCTAssertTrue(chat.isManagingModels)

    continuation.yield(" and done")
    continuation.finish()
    try await until { chat.modelOperation == nil && !chat.isManagingModels }
    XCTAssertEqual(chat.messages.last?.content, "Partial and done")
    XCTAssertEqual(engine.commitCount, 1)
    XCTAssertEqual(chat.installedModel?.id, InstallingEngine.newID)
    XCTAssertFalse(chat.isBusy)
  }

  func testTheModelSheetCanCloseWhileAModelDownloads() async throws {
    let engine = InstallingEngine()
    let chat = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    XCTAssertTrue(LocalModelSettingsLogic.canDismissModelSheet(chat: chat))
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    XCTAssertFalse(chat.canChangeModels)
    XCTAssertTrue(LocalModelSettingsLogic.canDismissModelSheet(chat: chat), "A download must not trap the sheet open")
    engine.finishDownload(failing: CancellationError())
    try await until { !chat.isManagingModels }
  }

  func testADownloadFailureDuringAReplyIsKeptApartFromTheChat() async throws {
    let (first, firstReply) = AsyncThrowingStream<String, Error>.makeStream()
    let (second, secondReply) = AsyncThrowingStream<String, Error>.makeStream()
    let engine = InstallingEngine(replies: { request in
      request.prompt == "First" ? first : request.prompt == "Second" ? second : nil
    })
    let chat = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    chat.submit("First")
    firstReply.yield("Partial")
    try await until { chat.messages.last?.content == "Partial" }
    engine.finishDownload(failing: DownloadFailure())
    try await until { !chat.isManagingModels }
    XCTAssertEqual(chat.modelFailure, DownloadFailure().errorDescription)
    XCTAssertEqual(chat.state, .streaming)

    await chat.stopStreaming()?.value
    XCTAssertEqual(chat.state, .idle)
    XCTAssertEqual(chat.modelFailure, DownloadFailure().errorDescription, "Stop must not drop the install failure")

    chat.submit("Second")
    secondReply.yield("Answer")
    secondReply.finish(throwing: MockError.failed)
    try await until { chat.activeRequest == nil && chat.state != .streaming }
    XCTAssertEqual(chat.state, .failed(MockError.failed.localizedDescription))
    XCTAssertEqual(chat.modelFailure, DownloadFailure().errorDescription, "A failed reply must not drop the install failure")

    chat.submit("Third")
    try await until { chat.activeRequest == nil && chat.messages.last?.content == "Local reply" }
    XCTAssertEqual(chat.state, .idle, "An old install failure must never fail a later reply")
    XCTAssertEqual(chat.modelFailure, DownloadFailure().errorDescription)

    chat.downloadModel(LocalModelManifest.bundled.models[0])
    XCTAssertNil(chat.modelFailure, "A new install clears the old failure")
    try await until { engine.isDownloading }
    engine.finishDownload(failing: CancellationError())
    try await until { !chat.isManagingModels }
  }

  func testTheCommitUnloadsBothEnginesBeforeInstallingAndShowsWhatItWaitsFor() async throws {
    let (reply, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let engine = InstallingEngine(stream: reply)
    let chat = LocalChatViewModel(engine: engine, visionEngine: RecordingVision(engine: engine), sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    chat.submit("Keep answering")
    continuation.yield("Partial")
    try await until { chat.messages.last?.content == "Partial" }
    engine.finishDownload()
    try await until { chat.modelOperation == .waitingToInstall }
    XCTAssertFalse(LocalChatViewModel.ModelOperation.waitingToInstall.blocksChat, "Waiting must not hold chat")
    XCTAssertEqual(ChatRouteStatus.make(.init(mode: .local, modelOperation: .waitingToInstall, localModelName: "Old")).text,
                   "Installing after this reply…")
    continuation.finish()
    try await until { !chat.isManagingModels }
    let events = engine.events
    let commit = try XCTUnwrap(events.firstIndex(of: "commit"))
    XCTAssertTrue(events[..<commit].contains("unload"), "\(events)")
    XCTAssertTrue(events[..<commit].contains("vision-unload"), "\(events)")
  }

  func testCancellingWhileTheCommitWaitsKeepsThePreviousModelAndChat() async throws {
    let (reply, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let engine = InstallingEngine(stream: reply)
    let chat = LocalChatViewModel(engine: engine, sessionStore: makeSessionStore())
    await chat.refreshInstalledModel()
    chat.downloadModel(LocalModelManifest.bundled.models[0])
    try await until { engine.isDownloading }
    chat.submit("Keep answering")
    continuation.yield("Partial")
    try await until { chat.messages.last?.content == "Partial" }
    engine.finishDownload()
    try await until { engine.isWaitingToCommit }
    chat.cancelInstallation()
    try await until { !chat.isManagingModels }
    XCTAssertNil(chat.modelOperation)
    XCTAssertNil(chat.modelFailure)
    XCTAssertEqual(engine.commitCount, 0)
    XCTAssertEqual(chat.installedModel?.id, InstallingEngine.oldID)
    XCTAssertEqual(chat.state, .streaming, "Cancelling the install leaves the reply running")
    continuation.yield(" and done")
    continuation.finish()
    try await until { chat.activeRequest == nil }
    XCTAssertEqual(chat.messages.last?.content, "Partial and done")
    XCTAssertTrue(chat.canChangeModels)
  }

  func testRouteStatusShowsTheHeldInstallInsteadOfAnOldChatError() {
    let status = ChatRouteStatus.make(.init(mode: .local, state: .failed("Old reply error"), modelOperation: .installing,
                                            localModelName: "Old"))
    XCTAssertEqual(status, ChatRouteStatus(kind: .busy, text: "Installing local model…"))
    let failure = ChatRouteStatus.make(.init(mode: .local, modelFailure: "The download couldn't be verified.", localModelName: "Old"))
    XCTAssertEqual(failure, ChatRouteStatus(kind: .problem, text: "The download couldn't be verified."))
  }

  private func until(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not met in time", file: file, line: line)
  }

  private func makeSessionStore() -> ChatSessionStore {
    ChatSessionStore(applicationSupportDirectory: FileManager.default.temporaryDirectory
      .appending(path: "ConcurrentModelInstallTests-\(UUID().uuidString)"))
  }
}

private final class InstallingEngine: LocalModelEngine, @unchecked Sendable {
  static let oldID = "old-text"
  static let newID = "new-package"
  private let lock = NSLock()
  private let replies: @Sendable (LocalModelRequest) -> AsyncThrowingStream<String, Error>?
  private var downloadFailure: Error?
  private var storedEvents: [String] = []
  private var models = [LocalModel(id: oldID, displayName: "Old", fileURL: URL(fileURLWithPath: "/tmp/old.gguf"))]
  private var selectedID: String? = oldID
  private var gate: CheckedContinuation<Void, Never>?
  private var downloading = false
  private var waitingToCommit = false
  private var storedRequests: [LocalModelRequest] = []
  private var storedDownloadCount = 0
  private var storedCommitCount = 0
  private var storedManagementCalls: [String] = []

  init(stream: AsyncThrowingStream<String, Error>? = nil) { replies = { _ in stream } }
  init(replies: @escaping @Sendable (LocalModelRequest) -> AsyncThrowingStream<String, Error>?) { self.replies = replies }

  /// Unloads and commits, in order, for checking what the commit waits for.
  var events: [String] { lock.withLock { storedEvents } }
  func record(_ event: String) { lock.withLock { storedEvents.append(event) } }

  var isDownloading: Bool { lock.withLock { downloading } }
  var isWaitingToCommit: Bool { lock.withLock { waitingToCommit } }
  var requests: [LocalModelRequest] { lock.withLock { storedRequests } }
  var downloadCount: Int { lock.withLock { storedDownloadCount } }
  var commitCount: Int { lock.withLock { storedCommitCount } }
  var managementCalls: [String] { lock.withLock { storedManagementCalls } }

  func finishDownload(failing error: Error? = nil) {
    let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      downloadFailure = error
      defer { self.gate = nil }
      return self.gate
    }
    gate?.resume()
  }

  func download(_ model: LocalModelDescriptor,
                progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    try await download(model, beforeCommit: {}, progress: progress)
  }

  func download(_ model: LocalModelDescriptor, beforeCommit: @escaping @Sendable () async throws -> Void,
                progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    lock.withLock { storedDownloadCount += 1 }
    await progress(ModelDownloadProgress(receivedByteCount: 1, expectedByteCount: 2))
    await withCheckedContinuation { continuation in
      lock.withLock { gate = continuation; downloading = true }
    }
    lock.withLock { downloading = false }
    if let failure = lock.withLock({ downloadFailure }) { throw failure }
    try Task.checkCancellation()
    lock.withLock { waitingToCommit = true }
    defer { lock.withLock { waitingToCommit = false } }
    try await beforeCommit()
    try Task.checkCancellation()
    let installed = LocalModel(id: Self.newID, displayName: "New", fileURL: URL(fileURLWithPath: "/tmp/new.gguf"))
    lock.withLock {
      models.append(installed)
      selectedID = installed.id
      storedCommitCount += 1
      storedEvents.append("commit")
    }
    return installed
  }

  func install(_ model: LocalModel) async throws { lock.withLock { storedManagementCalls.append("install") } }
  func installedModel() async -> LocalModel? { lock.withLock { models.first { $0.id == selectedID } } }
  func installedModels() async -> [LocalModel] { lock.withLock { models } }
  func selectModel(id: String) async throws { lock.withLock { storedManagementCalls.append("select") } }
  func deleteModel(id: String) async throws { lock.withLock { storedManagementCalls.append("delete") } }
  func benchmark() async throws -> LocalBenchmarkMetrics? {
    lock.withLock { storedManagementCalls.append("benchmark") }
    return nil
  }
  func unload() async { record("unload") }

  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    lock.withLock { storedRequests.append(request) }
    return replies(request) ?? AsyncThrowingStream { $0.yield("Local reply"); $0.finish() }
  }
}

private struct RecordingVision: LocalVisionServing {
  let engine: InstallingEngine
  func stream(messages: [ChatMessage], image: PreparedScreenImage?, model: LocalModel) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async { engine.record("vision-unload") }
}

private struct DownloadFailure: LocalizedError {
  var errorDescription: String? { "The download couldn't be verified." }
}

private struct InstantCloud: ChatProvider {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.yield(.token("Cloud reply")); $0.yield(.completed); $0.finish() }
  }
}
