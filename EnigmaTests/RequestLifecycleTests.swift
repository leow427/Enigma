import Combine
import Foundation
import XCTest
@testable import Enigma

@MainActor
final class RequestLifecycleTests: XCTestCase {
  private enum QueuedEnding: CaseIterable {
    case token, failure, completion
  }

  func testLocalReplacementIgnoresQueuedTokensFailuresAndCompletion() async throws {
    for ending in QueuedEnding.allCases {
      let first = ControlledStream<String>()
      let second = ControlledStream<String>()
      let engine = LifecycleLocalEngine(streams: [first, second])
      let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeStore())
      await viewModel.refreshInstalledModel()
      viewModel.submit("A")
      XCTAssertEqual(viewModel.presentationMessages.first?.content, "A")
      XCTAssertTrue(viewModel.isWaitingForResponse)
      await fulfillment(of: [first.started], timeout: 2)
      await receive("A partial", from: first, in: viewModel, expecting: "A partial")
      let firstSession = try XCTUnwrap(viewModel.selectedSessionID)
      let firstID = try XCTUnwrap(viewModel.activeRequest?.id)

      // No suspension between queuing A's event, Stop, and starting B: A's
      // MainActor consumer cannot process the event until B owns the lifecycle.
      queue(ending, on: first, token: "stale A")
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submit("B")
      let replacement = try XCTUnwrap(viewModel.activeRequest)
      XCTAssertNotEqual(replacement.id, firstID)
      await oldTask.value
      await fulfillment(of: [second.started], timeout: 2)

      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .preparing)
      XCTAssertEqual(viewModel.activeRequest, replacement)
      XCTAssertEqual(replacement.route, Route(mode: .local, providerID: "local", modelID: "fixture", usesNetwork: false))
      XCTAssertEqual(replacement.displayName, "Local · Fixture")
      XCTAssertEqual(viewModel.sessions.first { $0.id == firstSession }?.messages.last?.content, "A partial")
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
      viewModel.submit("Unintended third request")
      XCTAssertEqual(engine.requests.map(\.prompt), ["A", "B"])

      await receive("B partial", from: second, in: viewModel, expecting: "B partial")
      let newTask = try XCTUnwrap(viewModel.stopStreaming())
      await newTask.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertEqual(viewModel.messages.last?.content, "B partial")
      XCTAssertEqual(viewModel.messages.last?.activity?.phase, .cancelled)
      XCTAssertNil(viewModel.activity)
    }
  }

  func testCloudReplacementIgnoresQueuedTokensFailuresAndCompletion() async throws {
    for ending in QueuedEnding.allCases {
      let first = ControlledStream<ChatEvent>()
      let second = ControlledStream<ChatEvent>()
      let provider = LifecycleCloudProvider(streams: [first, second])
      let viewModel = LocalChatViewModel(
        engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
      )
      viewModel.submitCloud("A", provider: .chatGPT, modelID: "first-model")
      await fulfillment(of: [first.started], timeout: 2)
      await receive(.token("A partial"), from: first, in: viewModel, expecting: "A partial")
      let sessionID = viewModel.selectedSessionID
      queue(ending, on: first, token: .token("stale A"))
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "second-model")
      let replacement = try XCTUnwrap(viewModel.activeRequest)
      await oldTask.value
      await fulfillment(of: [second.started], timeout: 2)

      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .preparing)
      XCTAssertEqual(viewModel.activeRequest, replacement)
      XCTAssertEqual(viewModel.selectedSessionID, sessionID)
      XCTAssertEqual(viewModel.messages.map(\.content), ["A", "A partial", "B", ""])
      XCTAssertEqual(provider.requests.last?.messages.map(\.content), ["A", "A partial", "B"])
      viewModel.submitCloud("Unintended third request", provider: .chatGPT, modelID: "third")
      XCTAssertEqual(provider.requests.count, 2)

      await receive(.token("B partial"), from: second, in: viewModel, expecting: "B partial")
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertEqual(viewModel.state, .idle)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertEqual(viewModel.messages.last?.content, "B partial")
      XCTAssertEqual(viewModel.messages.last?.activity?.phase, .cancelled)
      XCTAssertNil(viewModel.activity)
    }
  }

  func testLateLocalPreparationCannotAcceptDraftOrMutateReplacement() async throws {
    for fails in [false, true] {
      let gate = PreparationGate()
      let first = LifecycleLocalEngine(prepare: { request in
        await gate.wait()
        if fails { throw LifecycleError.failed }
        return try LifecycleLocalEngine.prepareContext(request)
      })
      let cloud = ControlledStream<ChatEvent>()
      let viewModel = LocalChatViewModel(
        engine: first, cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [cloud])),
        sessionStore: makeStore()
      )
      let original = "  A draft\n"
      var draft = original
      viewModel.submit(draft, onAccepted: { draft = "" })
      await fulfillment(of: [gate.entered], timeout: 2)
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
      let active = viewModel.activeRequest
      await fulfillment(of: [cloud.started], timeout: 2)
      await gate.release()
      await oldTask.value

      XCTAssertEqual(draft, original)
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
      XCTAssertTrue(first.requests.isEmpty)
      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.activeRequest, active)
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [cloud.cancelled], timeout: 2)
    }
  }

  func testStopBeforeCloudTaskStartsDoesNotLaunchProducer() async throws {
    let provider = LifecycleCloudProvider()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    let task = try XCTUnwrap(viewModel.stopStreaming())
    viewModel.newChat()
    await task.value
    XCTAssertTrue(provider.requests.isEmpty)
    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertFalse(viewModel.isBusy)
  }

  func testAcceptanceCallbackCanReplaceCloudRequestWithoutLosingNewHandle() async throws {
    let stream = ControlledStream<ChatEvent>()
    let provider = LifecycleCloudProvider(streams: [stream])
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    var oldTask: Task<Void, Never>?
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first", onAccepted: {
      oldTask = viewModel.stopStreaming()
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
    })
    await oldTask?.value
    await fulfillment(of: [stream.started], timeout: 2)
    XCTAssertEqual(provider.requests.map { $0.route.modelID }, ["replacement"])
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "replacement")
    XCTAssertTrue(viewModel.isBusy)
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
  }

  func testAutoWithoutCloudStartsOnlyTheLocalProducer() async throws {
    let stream = ControlledStream<String>()
    let engine = LifecycleLocalEngine(streams: [stream])
    let provider = LifecycleCloudProvider()
    let viewModel = LocalChatViewModel(
      engine: engine, cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    await viewModel.refreshInstalledModel()
    viewModel.submitAuto("Design a resilient payment system and evaluate its failure modes.", cloud: nil)
    await fulfillment(of: [stream.started], timeout: 2)
    XCTAssertEqual(viewModel.activeRequest?.route.mode, .local)
    XCTAssertEqual(viewModel.activeRequest?.route.usesNetwork, false)
    XCTAssertEqual(viewModel.autoRouteDecision?.reason, .cloudUnavailable)
    XCTAssertEqual(engine.requests.count, 1)
    XCTAssertTrue(provider.requests.isEmpty)
    await receive("Local answer", from: stream, in: viewModel, expecting: "Local answer")
    await viewModel.stopStreaming()?.value
  }

  func testAutoRejectionsPreserveOriginalDraftWithoutStartingAnyProducer() async {
    let engine = LifecycleLocalEngine()
    let provider = LifecycleCloudProvider()
    let viewModel = LocalChatViewModel(
      engine: engine, cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    await viewModel.refreshInstalledModel()
    let cloud = AutoRouter.CloudConfiguration(provider: .chatGPT, modelID: "manual")
    viewModel.submitCloud(String(repeating: "x", count: 210_000), provider: .chatGPT, modelID: "manual")
    guard case .failed = viewModel.state else { return XCTFail("Expected initial context rejection") }
    for original in ["  Search the web for today's news\n", "  " + String(repeating: "x", count: 210_000) + "\n"] {
      var draft = original
      viewModel.submitAuto(draft, cloud: cloud, onAccepted: { draft = "" })
      XCTAssertEqual(draft, original)
      XCTAssertNil(viewModel.autoRouteDecision?.route)
      XCTAssertNotNil(viewModel.autoRouteDecision?.limitation)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertTrue(viewModel.messages.isEmpty)
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertEqual(viewModel.state, .idle, "An earlier error must not hide the current routing limitation")
    }
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertTrue(provider.requests.isEmpty)
  }

  func testLocalAcceptanceCallbackCanStopBeforeStartingProducer() async {
    let engine = LifecycleLocalEngine()
    let cloud = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: engine, cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [cloud])), sessionStore: makeStore()
    )
    var oldTask: Task<Void, Never>?
    viewModel.submit("A", onAccepted: {
      oldTask = viewModel.stopStreaming()
      viewModel.newChat()
      viewModel.submitCloud("B", provider: .chatGPT, modelID: "replacement")
    })
    await fulfillment(of: [cloud.started], timeout: 2)
    await oldTask?.value
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertEqual(viewModel.messages.map(\.content), ["B", ""])
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "replacement")
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [cloud.cancelled], timeout: 2)
  }

  func testDirectAPIReplacementStillCancelsItsOwnNetworkSource() async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let first = ControlledStream<CloudNetworkEvent>()
      let second = ControlledStream<CloudNetworkEvent>()
      let transport = LifecycleNetworkTransport(streams: [first, second])
      let viewModel = LocalChatViewModel(
        engine: LifecycleLocalEngine(),
        cloudProviders: CloudProviderRegistry(credentialStore: LifecycleCredentials(), transport: transport),
        sessionStore: makeStore()
      )
      viewModel.submitCloud("A", provider: provider, modelID: "model-a")
      await fulfillment(of: [first.started], timeout: 2)
      first.continuation.yield(.response(statusCode: 200))
      await receive(apiToken("A partial", provider: provider), from: first, in: viewModel, expecting: "A partial")
      first.continuation.yield(apiToken("stale A", provider: provider))
      let oldTask = try XCTUnwrap(viewModel.stopStreaming())
      viewModel.newChat()
      viewModel.submitCloud("B", provider: provider, modelID: "model-b")
      let active = viewModel.activeRequest
      await oldTask.value
      await fulfillment(of: [first.cancelled, second.started], timeout: 2)
      XCTAssertEqual(viewModel.activeRequest, active)
      XCTAssertTrue(viewModel.isBusy)
      second.continuation.yield(.response(statusCode: 200))
      await receive(apiToken("B partial", provider: provider), from: second, in: viewModel, expecting: "B partial")
      XCTAssertEqual(viewModel.messages.map(\.content), ["B", "B partial"])
      await viewModel.stopStreaming()?.value
      await fulfillment(of: [second.cancelled], timeout: 2)
      XCTAssertFalse(viewModel.isBusy)
    }
  }

  func testCurrentCompletionReleasesActiveRouteAndAllowsNextRequest() async {
    let first = ControlledStream<ChatEvent>()
    let second = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [first, second])),
      sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first")
    await fulfillment(of: [first.started], timeout: 2)
    let completed = expectation(description: "Request completed")
    let observation = viewModel.$state.sink { if $0 == .idle { completed.fulfill() } }
    first.continuation.yield(.token("Answer"))
    first.continuation.yield(.completed)
    first.continuation.finish()
    await fulfillment(of: [completed], timeout: 2)
    observation.cancel()
    XCTAssertNil(viewModel.activeRequest)
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertEqual(viewModel.messages.last?.content, "Answer")
    viewModel.submitCloud("B", provider: .chatGPT, modelID: "second")
    await fulfillment(of: [second.started], timeout: 2)
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "second")
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [second.cancelled], timeout: 2)
  }

  func testActiveCloudFeedbackSurvivesNextModeProviderAndModelChanges() async throws {
    let stream = ControlledStream<ChatEvent>()
    let provider = LifecycleCloudProvider(streams: [stream])
    let credentials = LifecycleCredentials()
    let suite = "RequestLifecycleTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: LifecycleNoNetwork(), cacheDirectory: temporaryDirectory()),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false }
    )
    settings.preferredProvider = .chatGPT
    settings.preferredModelID = "captured-model"
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: settings.preferredProvider, modelID: settings.preferredModelID)
    let active = try XCTUnwrap(viewModel.activeRequest)
    XCTAssertEqual(active.displayName, "Cloud · ChatGPT via Codex · captured-model")
    await fulfillment(of: [stream.started], timeout: 2)
    await receive(.token("Partial"), from: stream, in: viewModel, expecting: "Partial")
    // The mode control calls this when the next mode changes. Its decision must
    // not be the source of the active request's route label.
    viewModel.clearAutoRouteDecision()
    settings.preferredProvider = .anthropic
    settings.preferredModelID = "next-model"
    XCTAssertEqual(viewModel.activeRequest, active)
    XCTAssertEqual(viewModel.activeRequest?.displayName, "Cloud · ChatGPT via Codex · captured-model")
    XCTAssertEqual(provider.requests.first?.route, active.route)
    XCTAssertEqual(viewModel.state, .streaming)
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
    XCTAssertNil(viewModel.activeRequest)
  }

  func testCurrentCloudFailureKeepsPartialOutputAndReleasesOwnership() async {
    let stream = ControlledStream<ChatEvent>()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [stream])),
      sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [stream.started], timeout: 2)
    await receive(.token("Partial"), from: stream, in: viewModel, expecting: "Partial")
    let failed = expectation(description: "Current failure is displayed")
    let observation = viewModel.$state.sink { if case .failed = $0 { failed.fulfill() } }
    stream.continuation.finish(throwing: LifecycleError.failed)
    await fulfillment(of: [failed], timeout: 2)
    observation.cancel()
    XCTAssertEqual(viewModel.state, .failed("Controlled failure"))
    XCTAssertEqual(viewModel.messages.last?.content, "Partial")
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertNil(viewModel.activeRequest)
  }

  func testCodexReplacementRemainsCancellableAfterOldServerCleanup() async throws {
    let transport = LifecycleCodexTransport()
    let viewModel = LocalChatViewModel(
      engine: LifecycleLocalEngine(),
      cloudProviders: registry(chatGPT: CodexSubscriptionClient(transport: transport)), sessionStore: makeStore()
    )
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "first")
    await fulfillment(of: [transport.firstTurnStarted], timeout: 2)
    let oldTask = try XCTUnwrap(viewModel.stopStreaming())
    viewModel.newChat()
    viewModel.submitCloud("B", provider: .chatGPT, modelID: "second")
    let replacement = viewModel.activeRequest
    await fulfillment(of: [transport.secondTurnStarted], timeout: 2)

    // A's turn/start reply arrives after B has already started. The real Codex
    // client must still interrupt/unsubscribe A without losing B's consumer.
    await transport.releaseFirstTurn()
    await oldTask.value
    await fulfillment(of: [transport.firstUnsubscribed], timeout: 2)
    XCTAssertTrue(viewModel.isBusy)
    XCTAssertEqual(viewModel.activeRequest, replacement)
    let received = expectation(description: "B receives its own Codex token")
    let observation = viewModel.$sessions.dropFirst().prefix(1).sink { _ in received.fulfill() }
    await transport.emitToken("B partial", thread: "thread-2")
    await fulfillment(of: [received], timeout: 2)
    observation.cancel()
    XCTAssertEqual(viewModel.messages.map(\.content), ["B", "B partial"])
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [transport.secondUnsubscribed], timeout: 2)
    let interruptions = await transport.interruptions
    XCTAssertEqual(interruptions.map { $0["threadId"].string }, ["thread-1", "thread-2"])
    XCTAssertEqual(interruptions.map { $0["turnId"].string }, ["turn-thread-1", "turn-thread-2"])
    XCTAssertFalse(viewModel.isBusy)
  }

  func testModelSelectionBlocksSubmissionUntilEngineAndFeedbackAgree() async {
    let gate = PreparationGate()
    let engine = LifecycleLocalEngine(select: { await gate.wait() })
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: makeStore())
    await viewModel.refreshInstalledModel()
    viewModel.selectModel(id: "fixture")
    XCTAssertTrue(viewModel.isBusy)
    await fulfillment(of: [gate.entered], timeout: 2)
    var draft = "Keep while selecting"
    viewModel.submit(draft, onAccepted: { draft = "" })
    XCTAssertEqual(draft, "Keep while selecting")
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertNil(viewModel.stopStreaming(), "Model selection is not a generation task")
    XCTAssertTrue(viewModel.isBusy)
    let selected = expectation(description: "Model selection completed")
    let observation = viewModel.$state.sink { if $0 == .idle { selected.fulfill() } }
    await gate.release()
    await fulfillment(of: [selected], timeout: 2)
    observation.cancel()
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertEqual(viewModel.installedModel?.id, "fixture")
  }

  func testPersistenceFailureCannotAllowOverlappingGenerationOrDisableStop() async throws {
    let root = temporaryDirectory()
    try Data("Not a directory".utf8).write(to: root)
    let stream = ControlledStream<String>()
    let engine = LifecycleLocalEngine(streams: [stream])
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    viewModel.submit("A")
    await fulfillment(of: [stream.started], timeout: 2)
    XCTAssertEqual(viewModel.activeRequest?.route.modelID, "fixture", "Capture the engine's model even before library refresh")
    await receive("Partial", from: stream, in: viewModel, expecting: "Partial")
    await viewModel.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(viewModel.state, .streaming, "Best-effort history failures must not replace request feedback")
    XCTAssertTrue(viewModel.isBusy)
    viewModel.submit("B")
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"])
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
    await viewModel.sessionWriter.waitForPendingWrites()
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testFastLocalStreamPublishesEveryFragmentAndStopDoesNotWaitForArchive() async throws {
    let probe = ChatArchiveWriteProbe(store: makeStore(), blockFirst: true)
    defer { probe.release() }
    let delay = ControlledChatSaveDelay()
    let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
    let stream = ControlledStream<String>()
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(streams: [stream]),
      sessionStore: probe.store, sessionWriter: writer)
    viewModel.submit("Fast stream")
    await fulfillment(of: [stream.started, probe.started], timeout: 2)
    let received = expectation(description: "All fragments visible while disk is blocked")
    var lengths: Set<Int> = []
    let observation = viewModel.$sessions.sink { sessions in
      let count = sessions.first?.messages.last?.content.count ?? 0
      if lengths.insert(count).inserted && count == 1_000 { received.fulfill() }
    }
    for _ in 0..<1_000 { stream.continuation.yield("x") }
    await fulfillment(of: [received, delay.started], timeout: 5)
    observation.cancel()
    XCTAssertEqual(lengths, Set(0...1_000), "Visible updates must not be coalesced")
    XCTAssertEqual(probe.snapshots.count, 1)
    XCTAssertTrue(viewModel.isBusy)
    await viewModel.stopStreaming()?.value
    await fulfillment(of: [stream.cancelled], timeout: 2)
    XCTAssertFalse(viewModel.isBusy)
    XCTAssertNil(viewModel.activeRequest)
    XCTAssertEqual(viewModel.messages.last?.activity?.phase, .cancelled)
    XCTAssertEqual(probe.snapshots.count, 1, "Stop must finish before the blocked archive write")

    await delay.release()
    probe.release()
    await writer.waitForPendingWrites()
    XCTAssertEqual(probe.snapshots.count, 2, "1,000 fragments should produce only the initial and final writes")
    XCTAssertEqual(probe.store.load().first?.messages.map(\.content), ["Fast stream", String(repeating: "x", count: 1_000)])
    let evidence = XCTAttachment(string: "1,000 local fragments: all 1,000 incremental lengths published; 2 background archive writes (initial + Stop). Stop and producer cancellation completed with the first write blocked.")
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  func testCloudCompletionAndFailureFlushPartialHistoryWithoutWaitingForDelay() async {
    for fails in [false, true] {
      let probe = ChatArchiveWriteProbe(store: makeStore(), blockFirst: true)
      defer { probe.release() }
      let delay = ControlledChatSaveDelay()
      let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
      let stream = ControlledStream<ChatEvent>()
      let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(),
        cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: [stream])),
        sessionStore: probe.store, sessionWriter: writer)
      viewModel.submitCloud("Question", provider: .chatGPT, modelID: "model")
      await fulfillment(of: [stream.started, probe.started], timeout: 2)
      await receive(.token("Partial"), from: stream, in: viewModel, expecting: "Partial")
      await fulfillment(of: [delay.started], timeout: 2)
      let ended = expectation(description: "Request ended without waiting for disk")
      let observation = viewModel.$state.sink {
        if $0 == .idle || $0 == .failed("Controlled failure") { ended.fulfill() }
      }
      if fails { stream.continuation.finish(throwing: LifecycleError.failed) }
      else { stream.continuation.finish() }
      await fulfillment(of: [ended], timeout: 2)
      observation.cancel()
      XCTAssertFalse(viewModel.isBusy)
      probe.release()
      // Do not release the coalescing clock until the final write is complete.
      await fulfillment(of: [probe.secondFinished], timeout: 2)
      await writer.waitForPendingWrites()
      XCTAssertEqual(probe.snapshots.count, 2)
      XCTAssertEqual(probe.store.load().first?.messages.map(\.content), ["Question", "Partial"])
      await delay.release()
    }
  }

  func testTemporaryChatAndRetentionSurvivePendingArchiveWrites() async throws {
    let probe = ChatArchiveWriteProbe(store: makeStore(), blockFirst: true)
    defer { probe.release() }
    // Recents is full of chats with messages, so a new chat that's used evicts the oldest.
    let limit = ChatSessionStore.maximumRetainedSessions
    let earlier = (0..<limit).map { index in
      ChatSession(messages: [ChatMessage(role: .user, content: "Earlier")],
                  lastActivityAt: Date(timeIntervalSinceNow: -Double(1_000 - index)))
    }
    try probe.store.save(earlier)
    let writer = ChatSessionWriter(write: probe.write)
    let kept = ControlledStream<String>()
    let stream = ControlledStream<String>()
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(streams: [kept, stream]),
      sessionStore: probe.store, sessionWriter: writer)
    viewModel.submit("Kept question")
    await fulfillment(of: [kept.started], timeout: 2)
    let evicted = earlier[0].id
    // The question landing is the first write, which is held while more queue behind it.
    await fulfillment(of: [probe.started], timeout: 2)
    await receive("Kept answer", from: kept, in: viewModel, expecting: "Kept answer")
    await viewModel.stopStreaming()?.value
    viewModel.startTemporaryChat(context: nil)
    let temporary = viewModel.selectedSessionID
    viewModel.submit("Never archive this")
    await fulfillment(of: [stream.started], timeout: 2)
    await receive("Temporary answer", from: stream, in: viewModel, expecting: "Temporary answer")
    await viewModel.stopStreaming()?.value
    probe.release()
    await writer.waitForPendingWrites()
    XCTAssertEqual(probe.snapshots.count, 2)
    let saved = probe.store.load()
    XCTAssertEqual(saved.count, limit)
    XCTAssertFalse(saved.contains { $0.id == temporary || $0.id == evicted })
    XCTAssertEqual(saved.flatMap(\.messages).map(\.content).sorted(),
                   (["Kept question", "Kept answer"] + Array(repeating: "Earlier", count: limit - 1)).sorted(),
                   "None of the temporary chat's messages")
    viewModel.newChat()
    await writer.waitForPendingWrites()
    XCTAssertEqual(probe.store.load().map(\.id), viewModel.sessions.map(\.id))
    XCTAssertFalse(viewModel.sessions.contains { $0.id == temporary })
  }

  // MARK: Message queue (F2)

  /// A chat whose queued messages send as local questions, as AppShellView sends them in Local mode.
  private func queueingChat(_ engine: LifecycleLocalEngine, store: ChatSessionStore? = nil) async -> LocalChatViewModel {
    let viewModel = LocalChatViewModel(engine: engine, sessionStore: store ?? makeStore())
    await viewModel.refreshInstalledModel()
    viewModel.queuedMessageSender = { [unowned viewModel] message, accepted in
      viewModel.submit(message.text, onAccepted: accepted)
    }
    return viewModel
  }

  private func waitUntil(_ description: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), description)
  }

  func testQueuedMessagesSendOneAtATimeInOrder() async throws {
    let streams = (0..<3).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B", "C"])
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"], "Nothing sends while a reply runs")
    XCTAssertEqual(viewModel.presentationMessages.filter { $0.role == .user }.map(\.content), ["A"],
                   "Queued messages aren't part of the chat")

    streams[0].continuation.finish()
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["C"])
    streams[1].continuation.finish()
    await fulfillment(of: [streams[2].started], timeout: 2)
    XCTAssertTrue(viewModel.messageQueue.isEmpty)
    streams[2].continuation.finish()
    await waitUntil("the last reply ends") { !viewModel.isBusy }
    XCTAssertEqual(engine.requests.map(\.prompt), ["A", "B", "C"])
    XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.map(\.content), ["A", "B", "C"])
  }

  func testAFailedReplyHoldsTheQueueUntilSendNow() async throws {
    let streams = (0..<3).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    streams[0].continuation.finish(throwing: LifecycleError.failed)
    await waitUntil("the failure lands") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.state, .failed("Controlled failure"), "The failed reply shows its error")
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B", "C"])
    viewModel.drainQueue()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"], "A held queue sends nothing by itself")

    let c = try XCTUnwrap(viewModel.messageQueue.messages.last)
    viewModel.sendQueuedMessageNow(id: c.id)
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertFalse(viewModel.messageQueue.isHeld, "Send now resumes the queue")
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B"])
    streams[1].continuation.finish()
    await fulfillment(of: [streams[2].started], timeout: 2)
    XCTAssertEqual(engine.requests.map(\.prompt), ["A", "C", "B"])
  }

  func testAQueuedReplyThatFailsAfterReachingTheChatStaysSentAndHoldsTheRest() async throws {
    let streams = (0..<2).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    streams[0].continuation.finish()
    await fulfillment(of: [streams[1].started], timeout: 2)
    streams[1].continuation.finish(throwing: LifecycleError.failed)
    await waitUntil("B's failure lands") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.map(\.content), ["A", "B"])
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["C"], "B isn't queued twice")
  }

  func testStopHoldsTheQueue() async throws {
    let streams = [ControlledStream<String>()]
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    let task = try XCTUnwrap(viewModel.stopStreaming())
    await task.value
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B"])
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"])
  }

  func testAQueuedMessageThatFailsBeforeReachingTheChatReturnsToTheHead() async throws {
    let streams = [ControlledStream<String>()]
    let engine = LifecycleLocalEngine(streams: streams, prepare: { request in
      if request.messages.last?.content == "B" { throw LifecycleError.failed }
      return try LifecycleLocalEngine.prepareContext(request)
    })
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    streams[0].continuation.finish()
    await waitUntil("B's preparation fails") { viewModel.state == .failed("Controlled failure") }
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B", "C"], "B goes back in front, not lost")
    XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.map(\.content), ["A"])
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"])
  }

  func testStoppingAQueuedMessageBeforeItReachesTheChatReturnsItToTheHead() async throws {
    let streams = [ControlledStream<String>()]
    let preparing = XCTestExpectation(description: "B preparing")
    let engine = LifecycleLocalEngine(streams: streams, prepare: { request in
      if request.messages.last?.content == "B" {
        preparing.fulfill()
        try await Task.sleep(for: .seconds(30))
      }
      return try LifecycleLocalEngine.prepareContext(request)
    })
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    streams[0].continuation.finish()
    await fulfillment(of: [preparing], timeout: 2)
    let task = try XCTUnwrap(viewModel.stopStreaming())
    await task.value
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B", "C"])
    XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.map(\.content), ["A"])
  }

  func testAQueuedMessageThatStartsNothingWaitsInFront() async throws {
    let engine = LifecycleLocalEngine()
    let viewModel = await queueingChat(engine)
    // As when no model is ready for the selected mode: the send starts no request.
    viewModel.queuedMessageSender = { _, _ in }
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B"])
    XCTAssertFalse(viewModel.isBusy)
  }

  func testSendNowStopsTheReplyAndJumpsTheQueue() async throws {
    let streams = (0..<3).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    await receive("A partial", from: streams[0], in: viewModel, expecting: "A partial")
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    let c = try XCTUnwrap(viewModel.messageQueue.messages.last)
    viewModel.sendQueuedMessageNow(id: c.id)
    await fulfillment(of: [streams[0].cancelled, streams[1].started], timeout: 2)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B"])
    XCTAssertFalse(viewModel.messageQueue.isHeld)
    XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.map(\.content), ["A", "C"])
    XCTAssertEqual(viewModel.messages.first { $0.role == .assistant }?.content, "A partial", "The stopped reply keeps its text")
    streams[1].continuation.finish()
    await fulfillment(of: [streams[2].started], timeout: 2)
    XCTAssertEqual(engine.requests.map(\.prompt), ["A", "C", "B"])
  }

  func testNewChatAndSwitchingChatsEraseTheQueue() async throws {
    let streams = (0..<4).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    viewModel.newChat()
    XCTAssertTrue(viewModel.messageQueue.isEmpty)
    XCTAssertFalse(viewModel.messageQueue.isHeld)
    let first = try XCTUnwrap(viewModel.sessions.first?.id)

    viewModel.submit("X")
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("Y"))
    viewModel.stopStreaming()
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    viewModel.selectSession(id: viewModel.selectedSessionID!)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["Y"], "Reselecting the open chat keeps it")
    viewModel.selectSession(id: first)
    XCTAssertTrue(viewModel.messageQueue.isEmpty)

    viewModel.submit("Z")
    await fulfillment(of: [streams[2].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("W"))
    viewModel.stopStreaming()
    XCTAssertTrue(viewModel.cycleRecentChat())
    XCTAssertTrue(viewModel.messageQueue.isEmpty)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(engine.requests.map(\.prompt), ["A", "X", "Z"], "Nothing erased was sent")

    viewModel.submit("V")
    await fulfillment(of: [streams[3].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("U"))
    viewModel.startTemporaryChat(context: nil)
    XCTAssertTrue(viewModel.messageQueue.isEmpty, "The selection shortcut's chat starts with no queue")
    XCTAssertFalse(viewModel.messageQueue.isHeld)
  }

  func testSendNowWhileSomethingElseHoldsTheChatSendsItOnceThatEnds() async throws {
    let streams = (0..<2).map { _ in ControlledStream<String>() }
    let engine = LifecycleLocalEngine(streams: streams)
    let viewModel = await queueingChat(engine)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    XCTAssertTrue(viewModel.queueMessage("C"))
    viewModel.stopStreaming()
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    // A performance check holds the chat, as File Mode does while it closes its workspace after Stop.
    viewModel.runModelBenchmark()
    XCTAssertTrue(viewModel.isBusy)
    let c = try XCTUnwrap(viewModel.messageQueue.messages.last)
    viewModel.sendQueuedMessageNow(id: c.id)
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["C", "B"], "It waits in front, not lost")
    XCTAssertFalse(viewModel.messageQueue.isHeld)
    XCTAssertEqual(engine.requests.map(\.prompt), ["A"])
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertEqual(engine.requests.map(\.prompt), ["A", "C"], "Sent once the check ends, by the chat itself")
    XCTAssertEqual(viewModel.messageQueue.messages.map(\.text), ["B"])
  }

  func testQueuedMessagesAreNeverSaved() async throws {
    let streams = [ControlledStream<String>()]
    let engine = LifecycleLocalEngine(streams: streams)
    let store = makeStore()
    let viewModel = await queueingChat(engine, store: store)
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("Queued secret"))
    let task = try XCTUnwrap(viewModel.stopStreaming())
    await task.value
    XCTAssertTrue(viewModel.messageQueue.isHeld)
    await waitUntil("the sent message is saved by the usual path") {
      store.load().flatMap(\.messages).contains { $0.content == "A" }
    }
    let saved = store.load().flatMap(\.messages).map(\.content)
    XCTAssertFalse(saved.contains { $0.contains("Queued secret") })
    XCTAssertFalse(viewModel.sessions.flatMap(\.messages).contains { $0.content.contains("Queued secret") })
  }

  func testAHeldQueueKeepsTheChatOnReturn() async throws {
    let streams = [ControlledStream<String>()]
    let viewModel = await queueingChat(LifecycleLocalEngine(streams: streams))
    viewModel.submit("A")
    await fulfillment(of: [streams[0].started], timeout: 2)
    XCTAssertTrue(viewModel.queueMessage("B"))
    viewModel.stopStreaming()
    XCTAssertTrue(ChatReturnState(chat: viewModel, screen: nil).hasUnsentWork, "A held queue is unsent work")
    viewModel.cancelQueuedMessage(id: try XCTUnwrap(viewModel.messageQueue.messages.first?.id))
    XCTAssertFalse(ChatReturnState(chat: viewModel, screen: nil).hasUnsentWork)
  }

  private func queue<Element>(_ ending: QueuedEnding, on stream: ControlledStream<Element>, token: Element) {
    switch ending {
    case .token: stream.continuation.yield(token)
    case .failure: stream.continuation.finish(throwing: LifecycleError.failed)
    case .completion: stream.continuation.finish()
    }
  }

  private func apiToken(_ text: String, provider: CloudProviderID) -> CloudNetworkEvent {
    let payload = provider == .openAI
      ? "{\"type\":\"response.output_text.delta\",\"delta\":\"\(text)\"}"
      : "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}"
    return .data(Data("data: \(payload)\n\n".utf8))
  }

  // MARK: Regenerate (F3)

  func testRegenerateKeepsTheOldReplyUntilItsFirstTokenThenReplacesIt() async throws {
    let streams = (0..<4).map { _ in ControlledStream<ChatEvent>() }
    let provider = LifecycleCloudProvider(streams: streams)
    let writes = SavedSessions()
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider),
                                       sessionStore: makeStore(), sessionWriter: ChatSessionWriter { writes.append($0) })
    var prompts: [String] = []
    let send = { (prompt: String, searches: Bool) in
      prompts.append(prompt)
      XCTAssertFalse(searches, "The old turn didn't search")
      viewModel.submitCloud(prompt, provider: .chatGPT, modelID: "model", searchEnabled: searches, allowsAutomaticSearch: false)
    }
    viewModel.submitCloud("/think A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [streams[0].started], timeout: 2)
    await receive(.token("Old"), from: streams[0], in: viewModel, expecting: "Old")
    streams[0].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }
    let old = viewModel.messages
    let question = try XCTUnwrap(old.first)
    XCTAssertEqual(old.map(\.content), ["A", "Old"])

    // A plain-cloud offline error before the first token puts the old reply back, and shows the error.
    viewModel.resend(fromUserMessage: question.id, send: send)
    XCTAssertEqual(prompts, ["/think A"], "The same text and /think choice")
    XCTAssertFalse(viewModel.presentationMessages.contains { $0.content == "Old" }, "The old reply is hidden meanwhile")
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertFalse(provider.requests[1].messages.contains { $0.content.contains("Old") }, "History stops before the question")
    streams[1].continuation.finish(throwing: CloudProviderError.offline)
    await waitUntil("the reply ends") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.messages, old)
    XCTAssertEqual(viewModel.state, .failed(CloudProviderError.offline.localizedDescription))

    // So does Stop before the first token.
    viewModel.resend(fromUserMessage: question.id, send: send)
    await fulfillment(of: [streams[2].started], timeout: 2)
    await viewModel.stopStreaming()?.value
    XCTAssertEqual(viewModel.messages, old)

    // After the first token the new reply replaces the old turn, which is reported as removed.
    var removed = Set<UUID>()
    viewModel.resend(fromUserMessage: question.id, send: send, removed: { removed = $0 })
    await fulfillment(of: [streams[3].started], timeout: 2)
    await receive(.token("New"), from: streams[3], in: viewModel, expecting: "New")
    XCTAssertEqual(viewModel.messages.map(\.content), ["A", "New"])
    XCTAssertEqual(viewModel.messages.first?.extendedThinking, true)
    XCTAssertTrue(Set(old.map(\.id)).isDisjoint(with: viewModel.messages.map(\.id)))
    XCTAssertTrue(removed.isSuperset(of: old.map(\.id)))
    streams[3].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.selectedSession?.messages.map(\.content), ["A", "New"])

    // The saved file held the old turn until the new reply's first token, and never both.
    viewModel.sessionWriter.flush()
    await waitUntil("the new reply is saved") { writes.last?.first?.messages.map(\.content) == ["A", "New"] }
    let newIDs = Set(viewModel.messages.map(\.id))
    for saved in writes.all {
      let messages = saved.first?.messages ?? []
      XCTAssertLessThanOrEqual(messages.count, 2, "\(messages.map(\.content))")
      if messages.contains(where: { newIDs.contains($0.id) }) {
        XCTAssertEqual(messages.last?.content.isEmpty, false, "Saved before the first token: \(messages.map(\.content))")
      }
    }
  }

  func testRegenerateSearchesOnlyWhenTheOldReplyDidAndDropsItsRevision() async throws {
    let streams = (0..<3).map { _ in ControlledStream<ChatEvent>() }
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(),
                                       cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: streams)),
                                       sessionStore: makeStore())
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [streams[0].started], timeout: 2)
    await receive(.token("First"), from: streams[0], in: viewModel, expecting: "First")
    streams[0].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }
    // A turn whose reply searched and proposed a revision.
    let source = WebSearchSource(title: "Example", url: URL(string: "https://example.com")!)
    let question = ChatMessage(role: .user, content: "B")
    var finished = false
    viewModel.tourAppend(question, script: TourScript(reply: "Searched", phases: [], sources: [source], phaseDuration: 0,
                                                      revision: "R")) { finished = true }
    await waitUntil("the tour reply ends") { finished }
    let reply = try XCTUnwrap(viewModel.messages.last)
    XCTAssertNotNil(viewModel.selectionRevisions[reply.id])

    var searched: [Bool] = []
    viewModel.resend(fromUserMessage: question.id, send: { prompt, searches in
      searched.append(searches)
      viewModel.submitCloud(prompt, provider: .chatGPT, modelID: "model", searchEnabled: false, allowsAutomaticSearch: false)
    })
    viewModel.resend(fromUserMessage: viewModel.messages[0].id, send: { _, _ in XCTFail("One resend at a time") })
    XCTAssertEqual(searched, [true], "Search runs again because the old reply searched")
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertNotNil(viewModel.selectionRevisions[reply.id], "Kept until the first token")
    await receive(.token("Fresh"), from: streams[1], in: viewModel, expecting: "Fresh")
    XCTAssertNil(viewModel.selectionRevisions[reply.id])
    XCTAssertEqual(viewModel.messages.map(\.content), ["A", "First", "B", "Fresh"])
    await viewModel.stopStreaming()?.value

    // A route that starts nothing leaves the chat as it was.
    let before = viewModel.messages
    viewModel.resend(fromUserMessage: before[2].id, send: { _, _ in })
    XCTAssertEqual(viewModel.messages, before)
    XCTAssertEqual(viewModel.presentationMessages, before)

    // Regenerating an earlier reply drops everything after it, and searches only if that reply did.
    let tour = ChatMessage(role: .user, content: "C")
    finished = false
    viewModel.tourAppend(tour, script: TourScript(reply: "Searched", phases: [], sources: [source], phaseDuration: 0)) {
      finished = true
    }
    await waitUntil("the tour reply ends") { finished }
    searched = []
    viewModel.resend(fromUserMessage: before[0].id, send: {
      searched.append($1)
      viewModel.submitCloud($0, provider: .chatGPT, modelID: "model", searchEnabled: $1, allowsAutomaticSearch: false)
    })
    XCTAssertEqual(searched, [false], "A later turn's search doesn't count")
    XCTAssertEqual(viewModel.presentationMessages.map(\.content), ["A", ""], "Later turns are hidden meanwhile")
    await fulfillment(of: [streams[2].started], timeout: 2)
    await receive(.token("Again"), from: streams[2], in: viewModel, expecting: "Again")
    XCTAssertEqual(viewModel.messages.map(\.content), ["A", "Again"])
    await viewModel.stopStreaming()?.value
  }

  func testRegeneratingInATemporaryChatWritesNothing() async throws {
    let streams = (0..<3).map { _ in ControlledStream<ChatEvent>() }
    let writes = SavedSessions()
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(),
                                       cloudProviders: registry(chatGPT: LifecycleCloudProvider(streams: streams)),
                                       sessionStore: makeStore(), sessionWriter: ChatSessionWriter { writes.append($0) })
    viewModel.startTemporaryChat(context: nil)
    viewModel.submitCloud("A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [streams[0].started], timeout: 2)
    await receive(.token("Old"), from: streams[0], in: viewModel, expecting: "Old")
    streams[0].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }
    viewModel.resend(fromUserMessage: viewModel.messages[0].id, send: {
      viewModel.submitCloud($0, provider: .chatGPT, modelID: "model", searchEnabled: $1, allowsAutomaticSearch: false)
    })
    await fulfillment(of: [streams[1].started], timeout: 2)
    await receive(.token("New"), from: streams[1], in: viewModel, expecting: "New")
    streams[1].continuation.finish()
    await waitUntil("the new reply ends") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.messages.map(\.content), ["A", "New"])
    // Editing it (F9) writes nothing either.
    viewModel.resend(fromUserMessage: viewModel.messages[0].id, text: "A edited", send: {
      viewModel.submitCloud($0, provider: .chatGPT, modelID: "model", searchEnabled: $1, allowsAutomaticSearch: false)
    })
    await fulfillment(of: [streams[2].started], timeout: 2)
    await receive(.token("Edited"), from: streams[2], in: viewModel, expecting: "Edited")
    streams[2].continuation.finish()
    await waitUntil("the edited reply ends") { !viewModel.isBusy }
    XCTAssertEqual(viewModel.messages.map(\.content), ["A edited", "Edited"])
    viewModel.sessionWriter.flush()
    XCTAssertTrue(writes.all.allSatisfy { $0.isEmpty }, "\(writes.all)")
  }

  // MARK: Edit (F9)

  func testEditingAMessageRewindsTheChatToItOnlyOnceTheNewReplyStarts() async throws {
    let streams = (0..<3).map { _ in ControlledStream<ChatEvent>() }
    let provider = LifecycleCloudProvider(streams: streams)
    let writes = SavedSessions()
    let viewModel = LocalChatViewModel(engine: LifecycleLocalEngine(), cloudProviders: registry(chatGPT: provider),
                                       sessionStore: makeStore(), sessionWriter: ChatSessionWriter { writes.append($0) })
    viewModel.submitCloud("/think A", provider: .chatGPT, modelID: "model")
    await fulfillment(of: [streams[0].started], timeout: 2)
    await receive(.token("Reply 0"), from: streams[0], in: viewModel, expecting: "Reply 0")
    streams[0].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }
    // A later turn whose reply searched.
    let source = WebSearchSource(title: "Example", url: URL(string: "https://example.com")!)
    var finished = false
    viewModel.tourAppend(ChatMessage(role: .user, content: "B"),
                         script: TourScript(reply: "Reply 1", phases: [], sources: [source], phaseDuration: 0)) { finished = true }
    await waitUntil("the tour reply ends") { finished }
    let old = viewModel.messages
    XCTAssertEqual(old.map(\.content), ["A", "Reply 0", "B", "Reply 1"])
    XCTAssertEqual(viewModel.selectedSession?.title, "A")

    // An edit is new text: it never inherits the old reply's search.
    var searched: [Bool] = []
    viewModel.resend(fromUserMessage: old[2].id, text: "Private notes", send: { searched.append($1) })
    XCTAssertEqual(searched, [false])
    XCTAssertEqual(viewModel.takeReturnedEdit(for: old[2].id), "Private notes", "A route that starts nothing hands it back")
    XCTAssertNil(viewModel.takeReturnedEdit(for: old[2].id), "Only once")
    XCTAssertEqual(viewModel.messages, old)

    let send = { (prompt: String, searches: Bool) in
      viewModel.submitCloud(prompt, provider: .chatGPT, modelID: "model", searchEnabled: searches, allowsAutomaticSearch: false)
    }

    // Stop before the first token: nothing was lost.
    viewModel.resend(fromUserMessage: old[0].id, text: "A edited", send: send)
    XCTAssertEqual(viewModel.presentationMessages.map(\.content), ["A edited", ""], "Shown as edited meanwhile")
    await fulfillment(of: [streams[1].started], timeout: 2)
    XCTAssertEqual(provider.requests[1].messages.filter { $0.role == .user }.count, 1, "History stops before the edited message")
    await viewModel.stopStreaming()?.value
    XCTAssertEqual(viewModel.messages, old)
    XCTAssertNil(viewModel.takeReturnedEdit(for: old[2].id))
    XCTAssertEqual(viewModel.takeReturnedEdit(for: old[0].id), "A edited", "Stop hands the edited text back")

    // After the first token the edited message and its reply replace it and everything after it.
    var removed = Set<UUID>()
    viewModel.resend(fromUserMessage: old[0].id, text: "A edited", send: send, removed: { removed = $0 })
    await fulfillment(of: [streams[2].started], timeout: 2)
    await receive(.token("New"), from: streams[2], in: viewModel, expecting: "New")
    XCTAssertEqual(viewModel.messages.map(\.content), ["A edited", "New"])
    XCTAssertEqual(viewModel.selectedSession?.title, "A edited", "An edited first message retitles the chat")
    XCTAssertNil(viewModel.takeReturnedEdit(for: old[0].id), "A started edit hands nothing back")
    XCTAssertEqual(viewModel.messages.first?.extendedThinking, true, "The /think choice is kept")
    XCTAssertTrue(Set(old.map(\.id)).isDisjoint(with: viewModel.messages.map(\.id)))
    XCTAssertTrue(removed.isSuperset(of: old.map(\.id)), "Every dropped message is reported, so its activity can close")
    XCTAssertTrue(removed.isSuperset(of: old.compactMap(\.activity?.id)))
    streams[2].continuation.finish()
    await waitUntil("the reply ends") { !viewModel.isBusy }

    // The saved file held the old chat until the edited message's first token, and never both.
    viewModel.sessionWriter.flush()
    await waitUntil("the edit is saved") { writes.last?.first?.messages.map(\.content) == ["A edited", "New"] }
    let newIDs = Set(viewModel.messages.map(\.id))
    for saved in writes.all {
      let messages = saved.first?.messages ?? []
      if messages.contains(where: { newIDs.contains($0.id) }) {
        XCTAssertEqual(messages.map(\.content).first, "A edited", "\(messages.map(\.content))")
        XCTAssertFalse(messages.contains { Set(old.map(\.id)).contains($0.id) }, "\(messages.map(\.content))")
        XCTAssertEqual(messages.last?.content.isEmpty, false, "Saved before the first token: \(messages.map(\.content))")
      }
    }
  }

  private func receive<Element>(_ token: Element, from stream: ControlledStream<Element>,
                                in viewModel: LocalChatViewModel, expecting content: String) async {
    let received = expectation(description: "Presented token: \(content)")
    let sessionID = viewModel.selectedSessionID
    // Activity and route updates also publish sessions. Only the expected text
    // in this request's session proves the consumer has received the token.
    let observation = viewModel.$sessions.filter {
      $0.first(where: { $0.id == sessionID })?.messages.last?.content == content
    }.prefix(1).sink { _ in received.fulfill() }
    stream.continuation.yield(token)
    await fulfillment(of: [received], timeout: 2)
    observation.cancel()
  }

  private func registry(chatGPT: any ChatProvider) -> CloudProviderRegistry {
    CloudProviderRegistry(credentialStore: LifecycleCredentials(), transport: LifecycleNoNetwork(), chatGPT: chatGPT)
  }

  private func makeStore() -> ChatSessionStore {
    ChatSessionStore(applicationSupportDirectory: temporaryDirectory())
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "RequestLifecycleTests-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

/// Every chat list the writer saved, in order.
private final class SavedSessions: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [[ChatSession]] = []
  func append(_ sessions: [ChatSession]) { lock.withLock { stored.append(sessions) } }
  var all: [[ChatSession]] { lock.withLock { stored } }
  var last: [ChatSession]? { all.last }
}

private enum LifecycleError: LocalizedError {
  case failed
  var errorDescription: String? { "Controlled failure" }
}

private final class ControlledStream<Element: Sendable>: Sendable {
  let stream: AsyncThrowingStream<Element, Error>
  let continuation: AsyncThrowingStream<Element, Error>.Continuation
  let started = XCTestExpectation(description: "Producer started")
  let cancelled = XCTestExpectation(description: "Producer cancelled")

  init() {
    (stream, continuation) = AsyncThrowingStream.makeStream()
    continuation.onTermination = { [cancelled] reason in
      if case .cancelled = reason { cancelled.fulfill() }
    }
  }
}

private final class LifecycleLocalEngine: LocalModelEngine, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<String>]
  private let preparation: @Sendable (LocalModelRequest) async throws -> PreparedConversation
  private let selection: @Sendable () async -> Void
  private var storedRequests: [LocalModelRequest] = []

  init(
    streams: [ControlledStream<String>] = [],
    prepare: @escaping @Sendable (LocalModelRequest) async throws -> PreparedConversation = { try prepareContext($0) },
    select: @escaping @Sendable () async -> Void = {}
  ) {
    self.streams = streams
    preparation = prepare
    selection = select
  }

  var requests: [LocalModelRequest] { lock.withLock { storedRequests } }
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? {
    LocalModel(id: "fixture", displayName: "Fixture", fileURL: URL(fileURLWithPath: "/tmp/fixture.gguf"))
  }
  func installedModels() async -> [LocalModel] { await installedModel().map { [$0] } ?? [] }
  func selectModel(id: String) async throws { await selection() }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LifecycleError.failed
  }
  func unload() async {}
  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation { try await preparation(request) }
  static func prepareContext(_ request: LocalModelRequest) throws -> PreparedConversation {
    try ChatContextPreparer.prepare(request.messages,
      budget: ContextBudget(contextWindow: 4_096, outputTokens: request.maximumTokenCount, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count + 32 } })
  }

  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    let index = lock.withLock { storedRequests.append(request); return storedRequests.count - 1 }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected local producer")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}

private final class LifecycleCloudProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<ChatEvent>]
  private var storedRequests: [ChatRequest] = []

  init(streams: [ControlledStream<ChatEvent>] = []) { self.streams = streams }
  var requests: [ChatRequest] { lock.withLock { storedRequests } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let index = lock.withLock { storedRequests.append(request); return storedRequests.count - 1 }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected cloud producer")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}

private actor PreparationGate {
  nonisolated let entered = XCTestExpectation(description: "Preparation suspended")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered.fulfill()
    }
  }
  func release() { continuation?.resume(); continuation = nil }
}

private struct LifecycleCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { "test-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private struct LifecycleNoNetwork: CloudNetworkTransport {
  func data(for request: URLRequest) async throws -> CloudDataResponse {
    XCTFail("Unexpected network request")
    throw LifecycleError.failed
  }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    XCTFail("Unexpected network stream")
    return AsyncThrowingStream { $0.finish(throwing: LifecycleError.failed) }
  }
}

private actor LifecycleCodexTransport: CodexRPCTransport {
  nonisolated let firstTurnStarted = XCTestExpectation(description: "A turn/start pending")
  nonisolated let secondTurnStarted = XCTestExpectation(description: "B turn started")
  nonisolated let firstUnsubscribed = XCTestExpectation(description: "A server cleanup finished")
  nonisolated let secondUnsubscribed = XCTestExpectation(description: "B server cleanup finished")
  private var threadCount = 0
  private var firstTurnReply: CheckedContinuation<Void, Never>?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private(set) var interruptions: [CodexValue] = []

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    switch method {
    case "account/read":
      return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "thread/start":
      threadCount += 1
      return .object(["thread": .object(["id": .string("thread-\(threadCount)")])])
    case "turn/start":
      let thread = params["threadId"].string ?? ""
      if thread == "thread-1" {
        await withCheckedContinuation {
          firstTurnReply = $0
          firstTurnStarted.fulfill()
        }
      } else { secondTurnStarted.fulfill() }
      return .object(["turn": .object(["id": .string("turn-\(thread)")])])
    case "turn/interrupt": interruptions.append(params)
    case "thread/unsubscribe":
      if params["threadId"].string == "thread-1" { firstUnsubscribed.fulfill() }
      else { secondUnsubscribed.fulfill() }
    default: XCTFail("Unexpected Codex method: \(method)")
    }
    return .object([:])
  }

  func releaseFirstTurn() { firstTurnReply?.resume(); firstTurnReply = nil }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<CodexNotification, Error>.makeStream()
    observers[id] = continuation
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in await self?.removeObserver(id) })
  }

  func emitToken(_ token: String, thread: String) {
    for continuation in observers.values {
      continuation.yield(CodexNotification(method: "item/agentMessage/delta", params: .object([
        "threadId": .string(thread), "turnId": .string("turn-\(thread)"), "delta": .string(token),
      ])))
    }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

private final class LifecycleNetworkTransport: CloudNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let streams: [ControlledStream<CloudNetworkEvent>]
  private var count = 0
  init(streams: [ControlledStream<CloudNetworkEvent>]) { self.streams = streams }

  func data(for request: URLRequest) async throws -> CloudDataResponse { throw LifecycleError.failed }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    let index = lock.withLock { defer { count += 1 }; return count }
    guard streams.indices.contains(index) else {
      XCTFail("Unexpected network source")
      return AsyncThrowingStream { $0.finish() }
    }
    streams[index].started.fulfill()
    return streams[index].stream
  }
}
