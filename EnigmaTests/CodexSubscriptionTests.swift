import Foundation
import XCTest
@testable import Enigma

final class CodexSubscriptionTests: XCTestCase {
  func testJSONRoundTripPreservesUnicodeAndNestedValues() throws {
    let value = CodexValue.object([
      "text": .string("Hello 👋\nCopenhagen"), "id": .number(42),
      "items": .array([.bool(false), .null, .object(["ok": .bool(true)])]),
    ])
    XCTAssertEqual(try JSONDecoder().decode(CodexValue.self, from: JSONEncoder().encode(value)), value)
    XCTAssertEqual(value["id"].integer, 42)
    XCTAssertEqual(value["missing"], .null)
  }

  func testRuntimeIsolatesCredentialsAndDisablesExternalActions() {
    let configuration = CodexRuntimeConfiguration(directory: URL(fileURLWithPath: "/tmp/ai-spotlight-codex"))
    XCTAssertEqual(configuration.environment["CODEX_HOME"], "/tmp/ai-spotlight-codex")
    XCTAssertNil(configuration.environment["OPENAI_API_KEY"])
    XCTAssertNil(configuration.environment["CODEX_API_KEY"])
    XCTAssertNil(configuration.environment["OPENAI_BASE_URL"])
    XCTAssertTrue(configuration.arguments.contains("features.code_mode_host=false"))
    XCTAssertTrue(CodexRuntimeConfiguration.fileMode.arguments.contains("features.code_mode_host=true"))
    XCTAssertEqual(CodexRuntimeConfiguration.fileMode.directory, CodexRuntimeConfiguration.live.directory)
    for setting in [
      "forced_login_method=\"chatgpt\"", "cli_auth_credentials_store=\"keyring\"",
      "model_provider=\"openai\"", "web_search=\"disabled\"", "history.persistence=\"none\"",
      "features.shell_tool=false", "features.apps=false", "features.plugins=false",
      "features.hooks=false", "features.multi_agent=false", "features.computer_use=false",
    ] {
      XCTAssertTrue(configuration.arguments.contains(setting), setting)
    }
  }

  func testMissingCodexReturnsActionableErrorWithoutLaunching() async {
    let server = CodexAppServer(executable: { nil })
    do {
      _ = try await server.request("account/read", params: .object([:]))
      XCTFail("Expected missing runtime")
    } catch {
      XCTAssertEqual(error as? CodexError, .notInstalled)
    }
  }

  func testAppServerInitializesAndCorrelatesARealPipeResponse() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"account/read"'*) /usr/bin/printf '%s\\n' '{"id":2,"result":{"account":null}}' ;;
        esac
      done
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")), executable: { executable }, requestTimeout: .seconds(5))
    let result = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(result, .object(["account": .null]))
    await server.disconnect()
  }

  func testFileModeProbeUsesIsolatedEnvironmentAndWorkingDirectory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: """
      #!/bin/sh
      [ "$1" = app-server ] && [ "$2" = generate-json-schema ] || exit 20
      [ "$CODEX_HOME" = "\(root.path)/runtime" ] || exit 21
      [ "$PWD" -ef "$4" ] || exit 22
      [ -z "$DYLD_INSERT_LIBRARIES" ] || exit 23
      /bin/mkdir -p "$4/v2"
      /usr/bin/printf '%s' '{"properties":{"environments":{"description":"Empty disables environment access"},"dynamicTools":{}},"definitions":{"DynamicToolSpec":{}}}' > "$4/v2/ThreadStartParams.json"
      /usr/bin/printf '%s' '{"required":["arguments","callId","threadId","tool","turnId"],"properties":{"callId":{"type":"string"},"threadId":{"type":"string"},"tool":{"type":"string"},"turnId":{"type":"string"}}}' > "$4/DynamicToolCallParams.json"
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")), executable: { executable })
    try await server.prepareFileMode()
  }

  func testFileModeSchemaAcceptsBothLayoutsAndRejectsMissingSafetyContracts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "v2"), withIntermediateDirectories: true)
    let thread = root.appending(path: "v2/ThreadStartParams.json")
    let validThread = #"{"properties":{"environments":{"description":"Empty disables environment access"},"dynamicTools":{}},"definitions":{"DynamicToolSpec":{}}}"#
    try Data(validThread.utf8).write(to: thread)
    XCTAssertThrowsError(try CodexFileModeSupport.validateSchema(at: root))
    for layout in ["DynamicToolCallParams.json", "v2/DynamicToolCallParams.json"] {
      let call = root.appending(path: layout)
      try Data(#"{"required":["arguments","callId","threadId","tool","turnId"],"properties":{"callId":{"type":"string"},"threadId":{"type":"string"},"tool":{"type":"string"},"turnId":{"type":"string"}}}"#.utf8).write(to: call)
      XCTAssertNoThrow(try CodexFileModeSupport.validateSchema(at: root))
      try Data(validThread.replacingOccurrences(of: "environments", with: "unsupported").utf8).write(to: thread)
      XCTAssertThrowsError(try CodexFileModeSupport.validateSchema(at: root))
      try Data(validThread.utf8).write(to: thread)
      try Data("{}".utf8).write(to: call)
      XCTAssertThrowsError(try CodexFileModeSupport.validateSchema(at: root))
      try FileManager.default.removeItem(at: call)
    }
  }

  func testFileModeStartupFailureIdentifiesTheCheckWithoutPrescribingAnUpdate() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: "#!/bin/sh\nexit 42\n")
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")), executable: { executable })
    do { try await server.prepareFileMode(); XCTFail("Expected a startup error") }
    catch {
      XCTAssertEqual(error as? CodexError, .fileModePreparationFailed(42))
      XCTAssertFalse(error.localizedDescription.contains("Update"))
    }
  }

  func testInstalledCodexFileModePreparation() async throws {
    guard let path = ProcessInfo.processInfo.environment["AI_SPOTLIGHT_CODEX_TEST_PATH"] else {
      throw XCTSkip("Set AI_SPOTLIGHT_CODEX_TEST_PATH to check the installed CLI through the app-hosted File Mode path.")
    }
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
      executable: { URL(fileURLWithPath: path) })
    try await server.prepareFileMode()
    try await server.prepareFileMode()
  }

  func testAppServerTimesOutAnUnansweredRequestAfterInitialization() async throws {
    let root = try temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = try makeUnansweredServer(in: root)
    let deadline = ControlledCodexDeadline()
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
      executable: { executable }, sleep: { try await deadline.sleep($0) })
    addTeardownBlock { await server.disconnect() }
    // A timeout during startup must not satisfy the unanswered-request assertion.
    let notifications = try await initializeTestServer(server)
    let received = expectation(description: "Fake process received the unanswered request")
    let observer = Task {
      for try await notification in notifications.stream where notification.method == "fixture/received" {
        XCTAssertEqual(notification.params["method"].string, "unanswered")
        received.fulfill()
        return
      }
    }
    defer { observer.cancel() }
    let completed = expectation(description: "Unanswered request timed out")
    let request = Task {
      do {
        _ = try await server.request("unanswered", params: .object([:]))
        XCTFail("Expected a timeout")
      } catch { XCTAssertEqual(error as? CodexError, .timedOut) }
      completed.fulfill()
    }
    defer { request.cancel() }
    await fulfillment(of: [received, deadline.armed], timeout: 5)
    await deadline.expire()
    await fulfillment(of: [completed], timeout: 5)
    await notifications.cancel()
  }

  func testAppServerEOFDisconnectsAnUnansweredRequest() async throws {
    let root = try temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = try makeUnansweredServer(in: root)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
      executable: { executable }, requestTimeout: .seconds(5))
    addTeardownBlock { await server.disconnect() }
    let notifications = try await initializeTestServer(server)
    let completed = expectation(description: "EOF disconnects the request")
    let request = Task {
      do {
        _ = try await server.request("exit", params: .object([:]))
        XCTFail("Expected disconnection")
      } catch { XCTAssertEqual(error as? CodexError, .disconnected) }
      completed.fulfill()
    }
    defer { request.cancel() }
    await fulfillment(of: [completed], timeout: 5)
    await notifications.cancel()
  }

  /// A call still running when its thread's handler is removed (Stop, or a provider-search restart
  /// in F30) is never answered; a call that finishes while the handler is set is.
  func testAppServerDropsTheAnswerOfACallWhoseHandlerWasRemoved() async throws {
    let root = try temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(in: root, script: """
      #!/bin/sh
      while IFS= read -r line; do
        id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"call"'*) call=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"call":"\\([a-z0-9-]*\\)".*/\\1/p')
            /usr/bin/printf '{"id":"%s","method":"item/tool/call","params":{"threadId":"t1","turnId":"u1","callId":"%s","tool":"x","arguments":{}}}\\n' "$call" "$call"
            /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"ping"'*) /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          # An answer to a server request: only Enigma writes these.
          *'"srv-'*) call=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"\\(srv-[0-9]\\)".*/\\1/p')
            /usr/bin/printf '{"method":"fixture/answered","params":{"id":"%s"}}\\n' "$call" ;;
        esac
      done
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
      executable: { executable }, requestTimeout: .seconds(5))
    addTeardownBlock { await server.disconnect() }
    let notifications = try await initializeTestServer(server)
    let answered = AnsweredCalls()
    let observer = Task {
      for try await notification in notifications.stream where notification.method == "fixture/answered" {
        if let id = notification.params["id"].string { await answered.add(id) }
      }
    }
    defer { observer.cancel() }
    let held = expectation(description: "The held call is running")
    // Through the protocol, as the clients call it.
    let transport: any CodexRPCTransport = server
    try await transport.setFileHandler(threadID: "t1") { _, params in
      guard params["callId"].string == "srv-2" else { return .object(["success": .bool(true)]) }
      held.fulfill()
      try? await Task.sleep(for: .seconds(60))
      return .object(["success": .bool(false)])
    }
    _ = try await server.request("call", params: .object(["call": .string("srv-1")]))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !answered.ids.contains("srv-1"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let first = await answered.ids
    XCTAssertEqual(first, ["srv-1"], "A call that finishes while its handler is set is answered")

    _ = try await server.request("call", params: .object(["call": .string("srv-2")]))
    await fulfillment(of: [held], timeout: 5)
    try await transport.setFileHandler(threadID: "t1", handler: nil)
    try await Task.sleep(for: .milliseconds(300))
    _ = try await server.request("ping", params: .object([:]))
    let after = await answered.ids
    XCTAssertEqual(after, ["srv-1"], "The removed handler's call is never answered")
    await notifications.cancel()
  }

  private func makeUnansweredServer(in root: URL) throws -> URL {
    try makeExecutable(in: root, script: """
      #!/bin/sh
      while IFS= read -r line; do
        id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"unanswered"'*) /usr/bin/printf '%s\\n' '{"method":"fixture/received","params":{"method":"unanswered"}}' ;;
          *'"method":"exit"'*) exit 0 ;;
        esac
      done
      """)
  }

  private func initializeTestServer(_ server: CodexAppServer) async throws -> CodexNotificationSubscription {
    let initialized = expectation(description: "Real pipe initialization completed")
    let startup = Task {
      defer { initialized.fulfill() }
      return try await server.notifications()
    }
    defer { startup.cancel() }
    let result = await XCTWaiter.fulfillment(of: [initialized], timeout: 5)
    _ = try XCTUnwrap(result == .completed ? true : nil, "The fake process must initialize before testing request failure")
    return try await startup.value
  }

  func testSignInAndSignOutInvalidateTheSeparateFileModeConnection() async throws {
    let changed = expectation(description: "File Mode authentication invalidated")
    changed.expectedFulfillmentCount = 2
    let client = CodexSubscriptionClient(transport: MockCodexTransport(loginSuccess: true),
      authenticationChanged: { changed.fulfill() })
    _ = try await client.signIn { _ in true }
    try await client.signOut()
    await fulfillment(of: [changed], timeout: 1)
  }

  func testAPIKeyAccountIsRejectedBySubscriptionRoute() async {
    let transport = MockCodexTransport(account: .object(["type": .string("apiKey")]))
    let client = CodexSubscriptionClient(transport: transport)
    do {
      _ = try await client.account()
      XCTFail("API billing must not masquerade as subscription access")
    } catch { XCTAssertEqual(error as? CodexError, .notSignedIn) }
  }

  func testBrowserLoginUsesSupportedOAuthAndHandlesEarlyCompletion() async throws {
    let transport = MockCodexTransport(loginSuccess: true)
    let client = CodexSubscriptionClient(transport: transport)
    let opened = expectation(description: "Official OAuth URL opened")
    let account = try await client.signIn { url in
      XCTAssertEqual(url.host, "auth.openai.com")
      opened.fulfill()
      return true
    }
    XCTAssertEqual(account, CodexAccount(email: "person@example.com", plan: "plus"))
    await fulfillment(of: [opened], timeout: 1)
    let requests = await transport.recordedRequests
    let login = try XCTUnwrap(requests.first { $0.method == "account/login/start" })
    XCTAssertEqual(login.params["type"].string, "chatgpt")
    XCTAssertEqual(login.params["useHostedLoginSuccessPage"].bool, true)
    XCTAssertEqual(login.params["apiKey"], .null)
  }

  func testFailedLoginAndUnsafeBrowserURLAreRejected() async {
    let failed = CodexSubscriptionClient(transport: MockCodexTransport(loginSuccess: false))
    do {
      _ = try await failed.signIn { _ in true }
      XCTFail("Expected login failure")
    } catch { XCTAssertEqual(error as? CodexError, .server("Login denied")) }
    let unsafe = CodexSubscriptionClient(transport: MockCodexTransport(loginURL: "http://untrusted.example/login"))
    do {
      _ = try await unsafe.signIn { _ in XCTFail("Must not open untrusted URL"); return true }
      XCTFail("Expected invalid URL")
    } catch { XCTAssertEqual(error as? CodexError, .invalidResponse) }
  }

  func testCancellingLoginCancelsServerSideBrowserFlow() async {
    let opened = expectation(description: "Login opened")
    let cancelled = expectation(description: "Login cancelled on server")
    let transport = MockCodexTransport(onRequest: { method in
      if method == "account/login/cancel" { cancelled.fulfill() }
    })
    let client = CodexSubscriptionClient(transport: transport)
    let task = Task { try await client.signIn { _ in opened.fulfill(); return true } }
    await fulfillment(of: [opened], timeout: 2)
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    await fulfillment(of: [cancelled], timeout: 2)
  }

  func testModelsUseRunnableModelNamesAndFollowPagination() async throws {
    let client = CodexSubscriptionClient(transport: MockCodexTransport())
    let models = try await client.models()
    XCTAssertEqual(models.map(\.id), ["model-one", "model-two"])
    XCTAssertEqual(models.map(\.provider), [.chatGPT, .chatGPT])
  }

  func testModelListRecordsInputTypesAndTheDefault() async throws {
    let transport = MockCodexTransport(modelEntries: [
      modelEntry("gpt-6-sol", modalities: ["text", "image"]),
      modelEntry("gpt-6-luna", isDefault: true),
      modelEntry("gpt-6-text", modalities: ["text"]),
    ])
    let models = try await CodexSubscriptionClient(transport: transport).models()
    XCTAssertEqual(models, [
      CloudModel(id: "gpt-6-sol", displayName: "gpt-6-sol", provider: .chatGPT, inputModalities: ["text", "image"]),
      CloudModel(id: "gpt-6-luna", displayName: "gpt-6-luna", provider: .chatGPT, inputModalities: ["text", "image"],
                 isDefault: true),
      CloudModel(id: "gpt-6-text", displayName: "gpt-6-text", provider: .chatGPT, inputModalities: ["text"]),
    ], "A missing inputModalities is text and image, as the app-server schema says")
    XCTAssertEqual(models.map(\.supportsVision), [true, true, false])
    XCTAssertEqual(CodexSubscriptionClient.automaticModelID(in: models), "gpt-6-luna")
    XCTAssertEqual(CodexSubscriptionClient.automaticModelID(in: [models[0], models[2]]), "gpt-6-sol", "Else the first listed")
    XCTAssertEqual(CodexSubscriptionClient.automaticModelID(in: []), CodexSubscriptionClient.defaultModelID)
  }

  func testOldCachesWithoutInputTypesCountAsTextOnlyUntilRefreshed() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fetchedAt = ISO8601DateFormatter().string(from: Date())
    try Data("""
      {"providers":{"chatgpt-codex":{"fetchedAt":"\(fetchedAt)","models":[
        {"id":"gpt-5.6-luna","displayName":"GPT-5.6 Luna","provider":"chatgpt-codex"}]}}}
      """.utf8).write(to: root.appending(path: "cloud-models.json"))
    let listed = CodexListedModels()
    let transport = MockCodexTransport(modelEntries: [modelEntry("gpt-5.6-luna", isDefault: true)])
    let catalog = CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(),
      cacheDirectory: root, codex: CodexSubscriptionClient(transport: transport), codexListedModels: listed)
    let maybeCached = await catalog.cachedModels(for: .chatGPT)
    let cached = try XCTUnwrap(maybeCached)
    XCTAssertEqual(cached, [CloudModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", provider: .chatGPT)])
    XCTAssertNil(cached[0].inputModalities)
    XCTAssertFalse(cached[0].isDefault)
    XCTAssertFalse(cached[0].supportsVision)
    XCTAssertEqual(listed.models, cached, "Reading the cache shares Codex's last list")

    let refreshed = try await catalog.models(for: .chatGPT, forceRefresh: true)
    XCTAssertEqual(refreshed.first?.inputModalities, ["text", "image"])
    XCTAssertEqual(listed.models.first?.isDefault, true)
    let maybeReread = await CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(),
      cacheDirectory: root, codexListedModels: CodexListedModels()).cachedModels(for: .chatGPT)
    let reread = try XCTUnwrap(maybeReread)
    XCTAssertEqual(reread, refreshed, "The new fields are cached")

    try await catalog.clearCache(for: .chatGPT)
    XCTAssertEqual(listed.models, [], "Signing out forgets the list")
  }

  func testCodexListedModelsAreCompatibleWithConservativeLimits() {
    CodexListedModels.shared.replace(with: [CloudModel(id: "gpt-6-sol", displayName: "GPT-6 Sol", provider: .chatGPT),
                                            CloudModel(id: "gpt-5.6-luna", displayName: "Luna", provider: .chatGPT)])
    addTeardownBlock { CodexListedModels.shared.replace(with: []) }
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .chatGPT, modelID: "gpt-6-sol"), .compatible)
    let listed = ModelContextPolicy.cloud(provider: .chatGPT, modelID: "gpt-6-sol")
    XCTAssertEqual(listed.contextWindow, CloudModelCapabilities.codexListedContextWindow)
    XCTAssertEqual(listed.outputTokens, CloudModelCapabilities.codexListedOutputTokens)
    XCTAssertEqual(ModelContextPolicy.cloud(provider: .chatGPT, modelID: "gpt-5.6-luna").contextWindow, 1_050_000,
                   "Reviewed limits are kept")
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .chatGPT, modelID: "gpt-7-unlisted"), .unverified)
    XCTAssertEqual(ModelContextPolicy.cloud(provider: .chatGPT, modelID: "gpt-7-unlisted").contextWindow, 32_768)
    XCTAssertEqual(CloudModelCapabilities.compatibility(provider: .openAI, modelID: "gpt-6-sol"), .unverified,
                   "Codex's list says nothing about the API")
  }

  func testTurnInputIsTextOrAScreenshotThenTextExactly() throws {
    CodexListedModels.shared.replace(with: [
      CloudModel(id: "model-one", displayName: "One", provider: .chatGPT, inputModalities: ["text", "image"])])
    addTeardownBlock { CodexListedModels.shared.replace(with: []) }
    // One message, so the expected text is a literal rather than a second encoding.
    var send = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "Describe the chart")],
      route: Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: "model-one", usesNetwork: true))
    let text = "Describe the chart"
    XCTAssertEqual(try CodexSubscriptionClient.turnParameters(threadID: "thread-one", request: send)["input"],
                   .array([.object(["type": .string("text"), "text": .string(text)])]))

    send.image = screenshot
    send.allowsCloudImages = true
    XCTAssertEqual(try CodexSubscriptionClient.turnParameters(threadID: "thread-one", request: send)["input"], .array([
      .object(["type": .string("image"), "url": .string("data:image/jpeg;base64,/9j/"), "detail": .null]),
      .object(["type": .string("text"), "text": .string(text)]),
    ]))

    var denied = send
    denied.allowsCloudImages = false
    XCTAssertThrowsError(try CodexSubscriptionClient.turnParameters(threadID: "thread-one", request: denied)) {
      XCTAssertEqual($0 as? ScreenRequestError, .cloudUploadNotAllowed)
    }
    CodexListedModels.shared.replace(with: [
      CloudModel(id: "model-one", displayName: "One", provider: .chatGPT, inputModalities: ["text"])])
    XCTAssertThrowsError(try CodexSubscriptionClient.turnParameters(threadID: "thread-one", request: send)) {
      XCTAssertEqual($0 as? ScreenRequestError, .textOnlyModel)
    }
  }

  func testStreamSendsTheScreenshotInTheTurn() async throws {
    CodexListedModels.shared.replace(with: [
      CloudModel(id: "model-one", displayName: "One", provider: .chatGPT, inputModalities: ["text", "image"])])
    addTeardownBlock { CodexListedModels.shared.replace(with: []) }
    let transport = MockCodexTransport(turnNotifications: [delta("A chart"), completion("completed")])
    var send = request()
    send.image = screenshot
    send.allowsCloudImages = true
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(send))
    XCTAssertEqual(events, [.token("A chart"), .completed])
    let requests = await transport.recordedRequests
    let thread = try XCTUnwrap(requests.first { $0.method == "thread/start" })
    let instructions = try XCTUnwrap(thread.params["developerInstructions"].string)
    XCTAssertFalse(instructions.contains("text-only"))
    XCTAssertTrue(instructions.contains("Do not use tools, read local files, browse, or take external actions."))
    let input = try XCTUnwrap(requests.first { $0.method == "turn/start" }?.params["input"].array)
    XCTAssertEqual(input.map { $0["type"].string }, ["image", "text"])
    XCTAssertEqual(input[0]["url"].string, "data:image/jpeg;base64,/9j/")
  }

  func testCodexDefaultPreferenceMigrationKeepsOnlyRealChoices() {
    func preferences(saved: String?, lunaMigrationRan: Bool) -> CloudPreferencesStore {
      let suite = "CodexSettings.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
      if let saved { defaults.set(saved, forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex") }
      if lunaMigrationRan { defaults.set(true, forKey: "aiSpotlight.cloud.didAdoptLunaDefault") }
      return CloudPreferencesStore(defaults: defaults)
    }
    XCTAssertNil(preferences(saved: nil, lunaMigrationRan: false).chosenModel(for: .chatGPT))
    XCTAssertNil(preferences(saved: "gpt-5.6-luna", lunaMigrationRan: true).chosenModel(for: .chatGPT),
                 "The saved built-in default was never chosen")
    XCTAssertNil(preferences(saved: "gpt-5.6-sol", lunaMigrationRan: false).chosenModel(for: .chatGPT),
                 "Nor was the first-discovered Sol before the Luna migration")
    XCTAssertEqual(preferences(saved: "gpt-5.6-sol", lunaMigrationRan: true).chosenModel(for: .chatGPT), "gpt-5.6-sol",
                   "Sol chosen after the Luna migration is a real choice")
    XCTAssertEqual(preferences(saved: "gpt-6-sol", lunaMigrationRan: true).chosenModel(for: .chatGPT), "gpt-6-sol")

    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    CloudPreferencesStore(defaults: defaults).setPreferredModel("gpt-5.6-luna", for: .chatGPT)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT), "gpt-5.6-luna",
                   "The migration runs once, so a later explicit Luna stays")
  }

  @MainActor
  func testChatGPTFollowsCodexDefaultUntilThePersonChooses() async throws {
    let root = try temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let transport = MockCodexTransport(modelEntries: [modelEntry("gpt-6-sol"), modelEntry("gpt-6-luna", isDefault: true)])
    let client = CodexSubscriptionClient(transport: transport)
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let settings = CloudSettingsModel(
      credentialStore: CodexTestCredentials(),
      catalog: CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(),
                                 cacheDirectory: root, codex: client),
      preferences: CloudPreferencesStore(defaults: defaults), codex: client, codexAvailable: { true })
    await settings.refreshChatGPTAccount()
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "gpt-6-luna")
    XCTAssertTrue(settings.isConfigured)
    XCTAssertNil(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT), "Codex's default isn't saved")

    settings.preferredProvider = .openAI
    settings.preferredProvider = .chatGPT
    XCTAssertNil(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT),
                 "Switching providers and back doesn't save the default either")
    XCTAssertNotEqual(settings.preferredModelID, "", "Codex's default is still shown")

    await settings.discoverModels(forceRefresh: true)
    settings.useChatGPTModelFromFileMode("gpt-6-luna")
    XCTAssertEqual(settings.preferredModelID, "gpt-6-luna")
    XCTAssertNil(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT),
                 "File Mode's handoff of Codex's default isn't saved as a choice")

    settings.preferredModelID = "gpt-6-sol"
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "gpt-6-sol", "A choice is never replaced by Codex's default")
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT), "gpt-6-sol")
    settings.useChatGPTModelFromFileMode("gpt-6-sol")
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT), "gpt-6-sol")

    // A chosen model Codex no longer lists makes File Mode fall back to Codex's default.
    settings.preferredModelID = "gpt-5.6-terra"
    settings.useChatGPTModelFromFileMode("gpt-6-luna")
    XCTAssertEqual(settings.preferredModelID, "gpt-6-luna", "The fallback is used for this draft")
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).chosenModel(for: .chatGPT), "gpt-5.6-terra",
                   "but never replaces the person's choice")
  }

  func testNewCloudPreferencesDefaultToLunaWithoutChangingAPIDefaults() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = CloudPreferencesStore(defaults: defaults)
    XCTAssertEqual(preferences.preferredProvider(), .chatGPT)
    XCTAssertEqual(preferences.preferredModel(for: .chatGPT), "gpt-5.6-luna")
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "")
    XCTAssertEqual(preferences.preferredCodexThinkingCapacity(), .high)

    preferences.setPreferredModel(" \n", for: .chatGPT)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "gpt-5.6-luna")
    preferences.setPreferredCodexThinkingCapacity(.ultra)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredCodexThinkingCapacity(), .ultra)
  }

  func testPreviousSolDefaultMigratesOnlyOnceAndPreservesAPISettings() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("gpt-5.6-sol", forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex")
    defaults.set("openai", forKey: "aiSpotlight.cloud.preferredProvider")
    defaults.set("openai-model", forKey: "aiSpotlight.cloud.preferredModel.openai")
    defaults.set("anthropic-model", forKey: "aiSpotlight.cloud.preferredModel.anthropic")

    let preferences = CloudPreferencesStore(defaults: defaults)
    XCTAssertEqual(preferences.preferredModel(for: .chatGPT), "gpt-5.6-luna")
    XCTAssertEqual(preferences.preferredProvider(), .openAI)
    XCTAssertEqual(preferences.preferredModel(for: .openAI), "openai-model")
    XCTAssertEqual(preferences.preferredModel(for: .anthropic), "anthropic-model")

    preferences.setPreferredModel("gpt-5.6-sol", for: .chatGPT)
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "gpt-5.6-sol")
  }

  func testLunaDefaultMigrationPreservesOtherSavedChatGPTModels() {
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("custom-model", forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex")
    XCTAssertEqual(CloudPreferencesStore(defaults: defaults).preferredModel(for: .chatGPT), "custom-model")
  }

  func testCodexStreamSendsTheSelectedThinkingCapacity() async throws {
    let transport = MockCodexTransport(turnNotifications: [delta("Hello"), completion("completed")])
    let client = CodexSubscriptionClient(transport: transport, thinkingCapacity: { .ultra })
    let events = try await collect(client.stream(request(modelID: "gpt-5.6-luna")))
    XCTAssertEqual(events, [.token("Hello"), .completed])
    let requests = await transport.recordedRequests
    let thread = try XCTUnwrap(requests.first { $0.method == "thread/start" })
    XCTAssertEqual(thread.params["model"].string, "gpt-5.6-luna")
    XCTAssertTrue(thread.params["baseInstructions"].string?.contains(ChatResponseStyle.instructions) == true)
    let turn = try XCTUnwrap(requests.first { $0.method == "turn/start" })
    XCTAssertEqual(turn.params["threadId"].string, "thread-one")
    XCTAssertEqual(turn.params["effort"].string, "ultra")
  }

  func testSubscriptionStreamIsEphemeralAndPreservesConversationContext() async throws {
    let cleanup = expectation(description: "Thread unloaded")
    let transport = MockCodexTransport(turnNotifications: [
      delta("Ignore", thread: "other"), delta("Hello"), delta(" 👋"), completion("completed"),
    ], onRequest: { method in
      if method == "thread/unsubscribe" { cleanup.fulfill() }
    })
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(request()))
    XCTAssertEqual(events, [.token("Hello"), .token(" 👋"), .completed])
    await fulfillment(of: [cleanup], timeout: 2)
    let requests = await transport.recordedRequests
    let thread = try XCTUnwrap(requests.first { $0.method == "thread/start" })
    XCTAssertEqual(thread.params["ephemeral"].bool, true)
    XCTAssertEqual(thread.params["sandbox"].string, "read-only")
    XCTAssertEqual(thread.params["approvalPolicy"].string, "never")
    XCTAssertEqual(thread.params["modelProvider"].string, "openai")
    let turn = try XCTUnwrap(requests.first { $0.method == "turn/start" })
    XCTAssertEqual(turn.params["effort"].string, "high")
    let text = try XCTUnwrap(turn.params["input"].array?.first?["text"].string)
    XCTAssertTrue(text.contains("Previous answer"))
    XCTAssertTrue(text.contains("Latest question"))
    XCTAssertFalse(requests.contains { $0.method == "turn/interrupt" })
  }

  func testPartialTextIsPreservedWhenCodexReportsFailure() async {
    let client = CodexSubscriptionClient(transport: MockCodexTransport(turnNotifications: [
      delta("Partial"), completion("failed", message: "Usage limit reached"),
    ]))
    var events: [ChatEvent] = []
    do {
      for try await event in client.stream(request()) { events.append(event) }
      XCTFail("Expected failure")
    } catch { XCTAssertEqual(error as? CodexError, .server("Usage limit reached")) }
    XCTAssertEqual(events, [.token("Partial")])
  }

  func testStopInterruptsEvenWhenTurnStartResponseIsStillPending() async {
    let started = expectation(description: "Turn submitted")
    let interrupted = expectation(description: "Turn interrupted")
    let unloaded = expectation(description: "Thread unloaded")
    let transport = MockCodexTransport(delayTurnStart: true, onRequest: { method in
      if method == "turn/start" { started.fulfill() }
      if method == "turn/interrupt" { interrupted.fulfill() }
      if method == "thread/unsubscribe" { unloaded.fulfill() }
    })
    let client = CodexSubscriptionClient(transport: transport)
    let request = request()
    let task = Task { for try await _ in client.stream(request) {} }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    await transport.releaseTurnStart()
    _ = await task.result
    await fulfillment(of: [interrupted, unloaded], timeout: 2)
    let calls = await transport.recordedRequests
    XCTAssertEqual(calls.first { $0.method == "turn/interrupt" }?.params["turnId"].string, "turn-one")
  }

  func testMissingLoginNeverFallsBackToStoredAPIKey() async {
    let codex = CodexSubscriptionClient(transport: MockCodexTransport(account: .null))
    let registry = CloudProviderRegistry(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), chatGPT: codex)
    do {
      _ = try await collect(registry.provider(for: .chatGPT).stream(request()))
      XCTFail("Expected sign-in requirement")
    } catch { XCTAssertEqual(error as? CodexError, .notSignedIn) }
  }

  @MainActor
  func testSettingsRestoreAccountAndSignOutWithoutTouchingAPIKeys() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "CodexSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = MockCodexTransport()
    let client = CodexSubscriptionClient(transport: transport)
    let catalog = CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client)
    let settings = CloudSettingsModel(
      credentialStore: CodexTestCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: defaults), codex: client, codexAvailable: { true }
    )
    XCTAssertEqual(settings.preferredProvider, .chatGPT)
    XCTAssertFalse(settings.isConfigured)
    XCTAssertEqual(settings.preferredModelID, "gpt-5.6-luna", "Before any list, the built-in fallback")
    await settings.refreshChatGPTAccount()
    await settings.discoverModels()
    XCTAssertTrue(settings.isConfigured)
    XCTAssertEqual(settings.models.map(\.id), ["model-one", "model-two"])
    XCTAssertEqual(settings.preferredModelID, "model-one", "Without a choice or a marked default, the first listed")
    settings.preferredModelID = ""
    await settings.loadCachedModels()
    XCTAssertEqual(settings.preferredModelID, "model-one", "A cleared choice follows Codex's list again")
    settings.preferredModelID = "model-two"
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.preferredModelID, "model-two", "Refresh must preserve an explicit model selection")
    XCTAssertFalse(settings.hasAPIKey(for: .chatGPT))
    await settings.signOutOfChatGPT()
    XCTAssertFalse(settings.isConfigured)
    XCTAssertTrue(settings.models.isEmpty)
    XCTAssertTrue(settings.hasAPIKey(for: .openAI))
    let cached = await catalog.cachedModels(for: .chatGPT)
    XCTAssertNil(cached)
    XCTAssertFalse((defaults.persistentDomain(forName: suite) ?? [:]).keys.contains { $0.lowercased().contains("token") })
  }

  @MainActor
  func testCheckSignInReportsEveryOutcomeAndClearsRunningFlag() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    func model(_ transport: any CodexRPCTransport, installed: Bool) -> CloudSettingsModel {
      let client = CodexSubscriptionClient(transport: transport)
      let defaults = UserDefaults(suiteName: "CodexCheck.\(UUID().uuidString)")!
      return CloudSettingsModel(
        credentialStore: CodexTestCredentials(),
        catalog: CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client),
        preferences: CloudPreferencesStore(defaults: defaults), codex: client, codexAvailable: { installed }
      )
    }
    let missing = model(MockCodexTransport(), installed: false)
    XCTAssertNil(missing.chatGPTCheck)
    await missing.checkChatGPTSignIn()
    XCTAssertEqual(missing.chatGPTCheck, .notSignedInNeedsCodexDownload, "No Codex yet is not a problem: Sign in downloads it")
    XCTAssertFalse(missing.isCheckingChatGPT)

    let out = model(MockCodexTransport(account: .null), installed: true)
    await out.checkChatGPTSignIn()
    XCTAssertEqual(out.chatGPTCheck, .notSignedIn)
    XCTAssertFalse(out.isCheckingChatGPT)

    let signedIn = model(MockCodexTransport(), installed: true)
    await signedIn.checkChatGPTSignIn()
    XCTAssertEqual(signedIn.chatGPTCheck, .signedIn("person@example.com"))
    XCTAssertFalse(signedIn.isCheckingChatGPT)

    let broken = model(FailingCodexTransport(), installed: true)
    await broken.checkChatGPTSignIn()
    XCTAssertEqual(broken.chatGPTCheck, .failed(CodexError.disconnected.localizedDescription))
    XCTAssertFalse(broken.isCheckingChatGPT)

    // Only the explicit check records a result.
    let quiet = model(MockCodexTransport(account: .null), installed: true)
    await quiet.refreshChatGPTAccount()
    XCTAssertNil(quiet.chatGPTCheck)

    // A later refresh clears a result it may contradict.
    await signedIn.checkChatGPTSignIn()
    XCTAssertNotNil(signedIn.chatGPTCheck)
    await signedIn.refreshChatGPTAccount()
    XCTAssertNil(signedIn.chatGPTCheck)

    let noEmail = model(MockCodexTransport(account: .object(["type": .string("chatgpt"), "planType": .string("plus")])), installed: true)
    await noEmail.checkChatGPTSignIn()
    XCTAssertEqual(noEmail.chatGPTCheck, .signedIn(nil))
  }

  @MainActor
  func testSignInWithoutCodexDownloadsItThenContinuesIntoBrowserSignIn() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = InstallState()
    let transport = MockCodexTransport(loginSuccess: true)
    let settings = settingsModel(transport: transport, root: root, installed: installed) { progress in
      installed.record("started")
      await progress(ModelDownloadProgress(receivedByteCount: 50, expectedByteCount: 100))
      await progress(ModelDownloadProgress(receivedByteCount: 100, expectedByteCount: 100))
      installed.isInstalled = true
    }
    XCTAssertFalse(settings.isCodexAvailable)
    let opened = InstallState()
    settings.signInWithChatGPT { url in opened.record(url.host ?? ""); return true }
    XCTAssertTrue(settings.isSigningIn)
    try await waitUntil { !settings.isSigningIn }
    XCTAssertEqual(installed.events, ["started"])
    XCTAssertEqual(opened.events, ["auth.openai.com"], "Sign-in continues without a second click")
    XCTAssertEqual(settings.chatGPTAccount?.email, "person@example.com")
    XCTAssertTrue(settings.isCodexAvailable)
    XCTAssertFalse(settings.isDownloadingCodex)
    XCTAssertEqual(settings.codexDownloadProgress, 1)
    XCTAssertNil(settings.accountError)
  }

  @MainActor
  func testCancellingOrFailingTheCodexDownloadNeverStartsSignInAndCanRetry() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = InstallState()
    let transport = MockCodexTransport(loginSuccess: true)
    let settings = settingsModel(transport: transport, root: root, installed: installed) { progress in
      installed.record("attempt")
      switch installed.events.count {
      case 1:
        await progress(ModelDownloadProgress(receivedByteCount: 10, expectedByteCount: 100))
        try await Task.sleep(for: .seconds(60))
      case 2:
        throw CodexRuntimeError.cannotStart
      default:
        installed.isInstalled = true
      }
    }
    settings.signInWithChatGPT { _ in true }
    try await waitUntil { settings.isDownloadingCodex && settings.codexDownloadProgress > 0 }
    settings.cancelSignIn()
    try await waitUntil { !settings.isSigningIn }
    XCTAssertFalse(settings.isDownloadingCodex)
    XCTAssertNil(settings.accountError, "Cancelling is not an error")

    settings.signInWithChatGPT { _ in true }
    try await waitUntil { !settings.isSigningIn }
    let failure = CodexInstallFailure(CodexRuntimeError.cannotStart)
    XCTAssertEqual(settings.accountError, failure.localizedDescription)
    XCTAssertTrue(failure.localizedDescription.hasPrefix("Codex was downloaded but could not be started."))
    XCTAssertTrue(failure.localizedDescription.contains("Choose Sign in to try again"))
    XCTAssertNil(settings.chatGPTAccount)
    var requests = await transport.recordedRequests
    XCTAssertFalse(requests.contains { $0.method == "account/login/start" })

    settings.signInWithChatGPT { _ in true }
    try await waitUntil { !settings.isSigningIn }
    XCTAssertEqual(installed.events.count, 3)
    XCTAssertNil(settings.accountError)
    XCTAssertEqual(settings.chatGPTAccount?.email, "person@example.com")
    requests = await transport.recordedRequests
    XCTAssertEqual(requests.filter { $0.method == "account/login/start" }.count, 1)
  }

  func testCodexInstallFailureSaysWhichStepFailed() {
    XCTAssertTrue(CodexInstallFailure(URLError(.notConnectedToInternet)).localizedDescription
      .hasPrefix("Codex could not be downloaded from OpenAI."))
    XCTAssertTrue(CodexInstallFailure(LocalModelCatalogError.checksumMismatch).localizedDescription
      .hasPrefix("Codex could not be downloaded from OpenAI."))
    for error in [CodexRuntimeError.invalidArchive, .incomplete, .wrongPackage] {
      XCTAssertTrue(CodexInstallFailure(error).localizedDescription
        .hasPrefix("Codex was downloaded but could not be installed."), "\(error)")
    }
    XCTAssertEqual(CodexInstallFailure(CodexRuntimeError.cannotStart).stage, .start)
    XCTAssertEqual(CodexInstallFailure(CodexRuntimeError.timedOut).stage, .install)
    XCTAssertEqual(CodexInstallFailure(CodexRuntimeError.installFailed("The disk is full.")).stage, .install,
                   "Anything after the download, such as a full disk, is an install failure")
  }

  @MainActor
  func testCheckSignInAsksTheShellAgainAfterACachedNotFound() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = InstallState()
    let lookup = LoginShellToolLookup(shell: "/bin/sh") { _, _, _ in asked.record("asked"); return "" }
    let client = CodexSubscriptionClient(transport: MockCodexTransport())
    let suite = "CodexShellRetry.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CloudSettingsModel(
      credentialStore: CodexTestCredentials(),
      catalog: CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client),
      preferences: CloudPreferencesStore(defaults: defaults), codex: client,
      codexAvailable: { false }, codexShellLookup: lookup
    )
    await settings.refreshChatGPTAccount()
    await settings.refreshChatGPTAccount()
    XCTAssertEqual(asked.events.count, 1, "Background refreshes use the cached \"not found\"")
    await settings.checkChatGPTSignIn()
    XCTAssertEqual(asked.events.count, 2, "Check sign-in status asks the shell again")
    XCTAssertEqual(settings.chatGPTCheck, .notSignedInNeedsCodexDownload)
  }

  @MainActor
  func testBackgroundRefreshSkipsTheShellWhenCodexIsFound() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = InstallState()
    let lookup = LoginShellToolLookup(shell: "/bin/sh") { _, _, _ in asked.record("asked"); return "" }
    let client = CodexSubscriptionClient(transport: MockCodexTransport())
    let suite = "CodexShellSkip.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CloudSettingsModel(
      credentialStore: CodexTestCredentials(),
      catalog: CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client),
      preferences: CloudPreferencesStore(defaults: defaults), codex: client,
      codexAvailable: { true }, codexShellLookup: lookup
    )
    await settings.refreshChatGPTAccount()
    await settings.refreshChatGPTAccount()
    XCTAssertTrue(asked.events.isEmpty, "The shell ranks below a found Codex, so it isn't asked")
    XCTAssertEqual(settings.chatGPTAccount?.email, "person@example.com")
    await settings.checkChatGPTSignIn()
    XCTAssertEqual(asked.events.count, 1, "The explicit check still asks")
  }

  @MainActor
  func testSignInWithCodexPresentSkipsTheDownload() async throws {

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = InstallState()
    installed.isInstalled = true
    let settings = settingsModel(transport: MockCodexTransport(loginSuccess: true), root: root, installed: installed) { _ in
      XCTFail("Codex is already available")
    }
    settings.signInWithChatGPT { _ in true }
    try await waitUntil { !settings.isSigningIn }
    XCTAssertEqual(settings.chatGPTAccount?.email, "person@example.com")
  }

  func testCodexBoundsSerializedContextAndKeepsOriginalMessages() async throws {
    let transport = MockCodexTransport(turnNotifications: [completion("completed")])
    let base = request()
    let messages = [
      ChatMessage(role: .user, content: String(repeating: "old", count: 20_000)),
      ChatMessage(role: .assistant, content: "old answer"),
    ] + base.messages
    let fullRequest = ChatRequest(sessionID: base.sessionID, messages: messages, route: base.route)
    _ = try await collect(CodexSubscriptionClient(transport: transport).stream(fullRequest))
    let requests = await transport.recordedRequests
    let turn = try XCTUnwrap(requests.first { $0.method == "turn/start" })
    let text = try XCTUnwrap(turn.params["input"].array?.first?["text"].string)
    XCTAssertFalse(text.contains(String(repeating: "old", count: 10)))
    XCTAssertTrue(text.contains("Previous answer"))
    XCTAssertTrue(text.contains("Latest question"))
    XCTAssertLessThanOrEqual(text.utf8.count, ModelContextPolicy.cloud(provider: .chatGPT, modelID: base.route.modelID).availableInputTokens)
    XCTAssertEqual(fullRequest.messages.count, messages.count)
  }

  func testCodexRejectsOversizedInputBeforeStartingServerRequests() async {
    let transport = MockCodexTransport()
    let base = request()
    let oversized = ChatRequest(sessionID: base.sessionID, messages: [
      ChatMessage(role: .user, content: String(repeating: "x", count: 40_000)),
    ], route: base.route)
    do {
      _ = try await collect(CodexSubscriptionClient(transport: transport).stream(oversized))
      XCTFail("Oversized request was accepted")
    } catch { XCTAssertTrue(error is ChatContextError) }
    let requests = await transport.recordedRequests
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor
  private func settingsModel(transport: MockCodexTransport, root: URL, installed: InstallState,
                             install: @escaping CloudSettingsModel.CodexInstall) -> CloudSettingsModel {
    let client = CodexSubscriptionClient(transport: transport)
    let suite = "CodexInstall.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    return CloudSettingsModel(
      credentialStore: CodexTestCredentials(),
      catalog: CloudModelCatalog(credentialStore: CodexTestCredentials(), transport: NoNetworkTransport(), cacheDirectory: root, codex: client),
      preferences: CloudPreferencesStore(defaults: defaults), codex: client,
      codexAvailable: { installed.isInstalled }, installCodex: install
    )
  }

  @MainActor
  private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("Timed out", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func request(modelID: String = "model-one") -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [
      ChatMessage(role: .user, content: "Previous question"),
      ChatMessage(role: .assistant, content: "Previous answer"),
      ChatMessage(role: .user, content: "Latest question"),
    ], route: Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: modelID, usesNetwork: true))
  }

  private let screenshot = PreparedScreenImage(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg",
                                               pixelWidth: 2, pixelHeight: 2)

  private func modelEntry(_ model: String, modalities: [String]? = nil, isDefault: Bool = false) -> CodexValue {
    var entry: [String: CodexValue] = [
      "id": .string(model), "model": .string(model), "displayName": .string(model),
      "hidden": .bool(false), "isDefault": .bool(isDefault),
    ]
    if let modalities { entry["inputModalities"] = .array(modalities.map(CodexValue.string)) }
    return .object(entry)
  }

  private func delta(_ text: String, thread: String = "thread-one") -> CodexNotification {
    CodexNotification(method: "item/agentMessage/delta", params: .object([
      "threadId": .string(thread), "turnId": .string("turn-one"), "itemId": .string("message-one"), "delta": .string(text),
    ]))
  }

  private func completion(_ status: String, message: String = "") -> CodexNotification {
    CodexNotification(method: "turn/completed", params: .object([
      "threadId": .string("thread-one"),
      "turn": .object(["id": .string("turn-one"), "status": .string(status), "error": .object(["message": .string(message)])]),
    ]))
  }

  private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "CodexTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeExecutable(in directory: URL, script: String) throws -> URL {
    let url = directory.appending(path: "fake-codex")
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private final class InstallState: @unchecked Sendable {
  private let lock = NSLock()
  private var installed = false
  private var recorded: [String] = []
  var isInstalled: Bool {
    get { lock.withLock { installed } }
    set { lock.withLock { installed = newValue } }
  }
  var events: [String] { lock.withLock { recorded } }
  func record(_ event: String) { lock.withLock { recorded.append(event) } }
}

private struct FailingCodexTransport: CodexRPCTransport {
  func request(_ method: String, params: CodexValue) async throws -> CodexValue { throw CodexError.disconnected }
  func notifications() async throws -> CodexNotificationSubscription { throw CodexError.disconnected }
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws {}
}

private actor MockCodexTransport: CodexRPCTransport {
  struct Request: Sendable {
    let method: String
    let params: CodexValue
  }

  static let signedIn = CodexValue.object([
    "type": .string("chatgpt"), "email": .string("person@example.com"), "planType": .string("plus"),
  ])
  private var accountValue: CodexValue
  private let loginSuccess: Bool?
  private let loginURL: String
  private let turnNotifications: [CodexNotification]
  private let onRequest: @Sendable (String) -> Void
  private let delayTurnStart: Bool
  private let modelEntries: [CodexValue]?
  private var turnStartWaiter: CheckedContinuation<Void, Never>?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private(set) var recordedRequests: [Request] = []

  init(
    account: CodexValue = MockCodexTransport.signedIn,
    loginSuccess: Bool? = nil,
    loginURL: String = "https://auth.openai.com/oauth/authorize?example=1",
    turnNotifications: [CodexNotification] = [],
    delayTurnStart: Bool = false,
    modelEntries: [CodexValue]? = nil,
    onRequest: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    accountValue = account
    self.modelEntries = modelEntries
    self.loginSuccess = loginSuccess
    self.loginURL = loginURL
    self.turnNotifications = turnNotifications
    self.delayTurnStart = delayTurnStart
    self.onRequest = onRequest
  }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    recordedRequests.append(Request(method: method, params: params))
    onRequest(method)
    switch method {
    case "account/read": return .object(["account": accountValue])
    case "account/logout": accountValue = .null; return .object([:])
    case "account/login/start":
      if let loginSuccess {
        emit(CodexNotification(method: "account/login/completed", params: .object([
          "loginId": .string("login-one"), "success": .bool(loginSuccess), "error": .string("Login denied"),
        ])))
      }
      return .object(["type": .string("chatgpt"), "loginId": .string("login-one"), "authUrl": .string(loginURL)])
    case "model/list":
      if let modelEntries { return .object(["data": .array(modelEntries), "nextCursor": .null]) }
      let secondPage = params["cursor"].string != nil
      return .object([
        "data": .array([.object([
          "id": .string("opaque-id"), "model": .string(secondPage ? "model-two" : "model-one"),
          "displayName": .string(secondPage ? "Second model" : "First model"), "hidden": .bool(false),
        ]), .object(["model": .string("hidden"), "displayName": .string("Hidden"), "hidden": .bool(true)])]),
        "nextCursor": secondPage ? .null : .string("page-two"),
      ])
    case "thread/start": return .object(["thread": .object(["id": .string("thread-one")])])
    case "turn/start":
      if delayTurnStart { await withCheckedContinuation { turnStartWaiter = $0 } }
      for notification in turnNotifications { emit(notification) }
      return .object(["turn": .object(["id": .string("turn-one")])])
    default: return .object([:])
    }
  }

  func releaseTurnStart() {
    turnStartWaiter?.resume()
    turnStartWaiter = nil
  }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    }
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in
      await self?.removeObserver(id)
    })
  }

  private func emit(_ notification: CodexNotification) {
    for continuation in observers.values { continuation.yield(notification) }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

private struct CodexTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { provider == .chatGPT ? nil : "unused-api-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws { XCTFail("Subscription sign-out must not remove API keys") }
}

private struct NoNetworkTransport: CloudNetworkTransport {
  func data(for request: URLRequest) async throws -> CloudDataResponse {
    XCTFail("Subscription mode must not use an API-key transport")
    throw CodexError.invalidResponse
  }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    XCTFail("Subscription mode must not use an API-key transport")
    return AsyncThrowingStream { $0.finish(throwing: CodexError.invalidResponse) }
  }
}

/// Advance only the deadline under test; initialization still uses the real pipe.
private actor ControlledCodexDeadline {
  nonisolated let armed: XCTestExpectation = {
    let expectation = XCTestExpectation(description: "Initialization and request deadlines armed")
    expectation.expectedFulfillmentCount = 2
    return expectation
  }()
  private var pending: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]

  func sleep(_ duration: Duration) async throws {
    XCTAssertEqual(duration, .seconds(60), "Keep the production request deadline")
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
    pending[id] = continuation
    defer { pending.removeValue(forKey: id) }
    armed.fulfill()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    try Task.checkCancellation()
  }

  func expire() {
    for continuation in pending.values { continuation.yield(()); continuation.finish() }
  }
}

// MARK: - Provider search (F30 CP4)

extension CodexSubscriptionTests {
  func testCodexSearchThreadParameters() throws {
    let toolbox = SearchNoteToolbox()
    for mode in ["live", "cached"] {
      let thread = try CodexToolMode.threadParameters(model: "gpt-5.6-luna", toolbox: toolbox,
                                                      providerSearch: ProviderSearch(), searchMode: mode)
      XCTAssertEqual(thread["config"]["web_search"].string, mode)
      XCTAssertEqual(thread["dynamicTools"].array?.compactMap { $0["name"].string }, ["get_saved_note"])
      XCTAssertEqual(thread["config"]["features.shell_tool"], .bool(false), "F32's isolation stays")
      XCTAssertEqual(thread["sandbox"].string, "read-only")
      XCTAssertEqual(thread["environments"], .array([]))
      let developer = try XCTUnwrap(thread["developerInstructions"].string)
      XCTAssertTrue(developer.hasPrefix(toolbox.instructions), "The toolbox's instructions, the search instruction among them, come first")
      XCTAssertTrue(developer.hasSuffix("\nUse only the supplied tools and web search. You cannot run commands or read files."))
    }
  }

  func testCodexThreadWithoutSearchUnchanged() throws {
    let toolbox = SearchNoteToolbox()
    let thread = try CodexToolMode.threadParameters(model: "gpt-5.6-luna", toolbox: toolbox,
                                                    providerSearch: nil, searchMode: nil)
    XCTAssertEqual(thread["config"]["web_search"], .null)
    XCTAssertEqual(thread["config"]["tools.web_search.location"], .null)
    XCTAssertEqual(thread["developerInstructions"].string,
                   toolbox.instructions + "\nUse only the supplied tools. You cannot run commands, read files, or browse.")
    XCTAssertEqual(thread, try CodexToolMode.threadParameters(model: "gpt-5.6-luna", toolbox: toolbox),
                   "F32's thread is unchanged")
    // Even a mode without provider search adds nothing.
    let stray = try CodexToolMode.threadParameters(model: "gpt-5.6-luna", toolbox: toolbox, providerSearch: nil, searchMode: "live")
    XCTAssertEqual(stray["config"]["web_search"], .null)
    XCTAssertTrue(CodexRuntimeConfiguration.fileMode.arguments.contains("web_search=\"disabled\""), "The launch setting stays")
  }

  func testCodexSearchThreadLocation() throws {
    let toolbox = SearchNoteToolbox()
    let full = ProviderSearch(location: ProviderSearchLocation(city: "Cupertino", region: "CA", countryCode: "US",
                                                               timeZone: "America/Los_Angeles"))
    let thread = try CodexToolMode.threadParameters(model: "m", toolbox: toolbox, providerSearch: full, searchMode: "live")
    XCTAssertEqual(thread["config"]["tools.web_search.location"], .object([
      "city": .string("Cupertino"), "region": .string("CA"), "country": .string("US"),
      "timezone": .string("America/Los_Angeles"),
    ]))
    let partial = ProviderSearch(location: ProviderSearchLocation(city: nil, region: " ", countryCode: "FR", timeZone: "Europe/Paris"))
    let partialThread = try CodexToolMode.threadParameters(model: "m", toolbox: toolbox, providerSearch: partial, searchMode: "live")
    XCTAssertEqual(partialThread["config"]["tools.web_search.location"], .object([
      "country": .string("FR"), "timezone": .string("Europe/Paris"),
    ]), "Missing parts are left out")
    let none = try CodexToolMode.threadParameters(model: "m", toolbox: toolbox, providerSearch: ProviderSearch(), searchMode: "live")
    XCTAssertEqual(none["config"]["tools.web_search.location"], .null)
    let empty = ProviderSearch(location: ProviderSearchLocation())
    let emptyThread = try CodexToolMode.threadParameters(model: "m", toolbox: toolbox, providerSearch: empty, searchMode: "live")
    XCTAssertEqual(emptyThread["config"]["tools.web_search.location"], .null, "An empty area sends no key")
    // Never coordinates: only the four documented fields can be sent.
    guard case .object(let sent) = thread["config"]["tools.web_search.location"] else { return XCTFail("No location") }
    XCTAssertEqual(Set(sent.keys), ["city", "region", "country", "timezone"])
  }

  func testCodexWebSearchModeFromRequirements() {
    func requirements(_ modes: CodexValue) -> CodexValue {
      .object(["requirements": .object(["allowedWebSearchModes": modes])])
    }
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: nil), "live")
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: .object(["requirements": .null])), "live")
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: requirements(.null)), "live")
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: .object(["requirements": .object([:])])), "live")
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: requirements(.array([.string("cached"), .string("live")]))), "live")
    XCTAssertEqual(CodexSubscriptionClient.webSearchMode(requirements: requirements(.array([.string("disabled"), .string("cached")]))), "cached")
    XCTAssertNil(CodexSubscriptionClient.webSearchMode(requirements: requirements(.array([.string("disabled"), .string("indexed")]))))
    XCTAssertNil(CodexSubscriptionClient.webSearchMode(requirements: requirements(.array([]))), "An empty list allows nothing")
  }

  func testCodexNoAllowedModeIsUnavailable() async throws {
    // A regression that starts the turn completes it, and fails below instead of hanging.
    let transport = SearchCodexTransport(requirements: .object(["requirements": .object([
      "allowedWebSearchModes": .array([.string("disabled")])])]), script: [completion("completed")])
    do {
      _ = try await collect(CodexSubscriptionClient(transport: transport)
        .stream(searchRequest(), toolbox: SearchNoteToolbox()))
      XCTFail("Expected provider search to be unavailable")
    } catch { XCTAssertEqual(error as? CloudProviderError, .webSearchUnavailable(.chatGPT)) }
    let methods = await transport.methods
    XCTAssertTrue(methods.contains("configRequirements/read"))
    XCTAssertFalse(methods.contains("thread/start"))
    XCTAssertFalse(methods.contains("turn/start"))
  }

  func testCodexAsksForCachedWhenOnlyCachedIsAllowed() async throws {
    let transport = SearchCodexTransport(requirements: .object(["requirements": .object([
      "allowedWebSearchModes": .array([.string("cached")])])]), script: [delta("Hi"), completion("completed")])
    _ = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()))
    let thread = await transport.threadStart
    XCTAssertEqual(thread?["config"]["web_search"].string, "cached")
  }

  func testCodexToolTurnWithoutProviderSearchSkipsThePolicy() async throws {
    let transport = SearchCodexTransport(script: [delta("Hi"), completion("completed")])
    var request = searchRequest()
    request.providerSearch = nil
    _ = try await collect(CodexSubscriptionClient(transport: transport).stream(request, toolbox: SearchNoteToolbox()))
    let methods = await transport.methods
    XCTAssertFalse(methods.contains("configRequirements/read"))
    let thread = await transport.threadStart
    XCTAssertEqual(thread?["config"]["web_search"], .null)
  }

  func testCodexWebSearchEventsFromFixture() async throws {
    let script = try fixtureNotifications("codex-web-search.jsonl")
    let transport = SearchCodexTransport(script: script)
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()))
    let thread = await transport.threadStart
    XCTAssertEqual(thread?["config"]["web_search"].string, "live")

    let searching = try XCTUnwrap(events.firstIndex(of: .activity(.phase(.searching))))
    let discovered = events.enumerated().compactMap { index, event -> (Int, [WebSearchSource])? in
      if case .activity(.sourcesDiscovered(let sources)) = event { return (index, sources) }
      return nil
    }
    XCTAssertEqual(discovered.count, 4, "One batch per completed search")
    XCTAssertGreaterThan(try XCTUnwrap(discovered.first?.0), searching, "Searching shows before its results")
    let urls = discovered.flatMap { $0.1.map(\.url.absoluteString) }
    XCTAssertTrue(urls.contains("https://www.apple.com/shop/buy-mac"))
    XCTAssertTrue(discovered.allSatisfy { $0.1.allSatisfy { $0.isSafeWebLink && !$0.title.isEmpty } })

    XCTAssertEqual(events.last, .completed)
    guard case .activity(.sourcesSelected(let selected)) = events[events.count - 2] else {
      return XCTFail("The selection comes right before completion")
    }
    let answer = events.compactMap { if case .token(let text) = $0 { text } else { nil } }.joined()
    let links = NativeWebSearch.links(in: answer)
    XCTAssertFalse(links.isEmpty)
    XCTAssertEqual(selected.map(\.url), Array(links.prefix(NativeWebSearch.maximumSources)), "The answer's links are the citations")
    XCTAssertTrue(selected.allSatisfy { !$0.title.isEmpty })
  }

  func testCodexFailureAfterSearchKeepsSources() async throws {
    let transport = SearchCodexTransport(script: [
      webSearchStarted(), webSearchCompleted(results: [result("https://www.swift.org/blog/", title: "Swift.org Blog")]),
      delta("The latest is on [the blog](https://www.swift.org/blog/)"),
      completion("failed", message: "Codex lost the connection."),
    ])
    var events: [ChatEvent] = []
    do {
      for try await event in CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()) {
        events.append(event)
      }
      XCTFail("Expected the turn to fail")
    } catch { XCTAssertEqual(error as? CodexError, .server("Codex lost the connection.")) }
    XCTAssertEqual(events.last, .activity(.sourcesSelected([WebSearchSource(title: "Swift.org Blog",
                                                                             url: URL(string: "https://www.swift.org/blog/")!)])))
  }

  func testCodexFailureBeforeAnySearchSendsNoSelection() async throws {
    let transport = SearchCodexTransport(script: [delta("See https://www.swift.org/"), completion("failed", message: "Boom")])
    var events: [ChatEvent] = []
    do {
      for try await event in CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()) {
        events.append(event)
      }
      XCTFail("Expected the turn to fail")
    } catch {}
    XCTAssertFalse(events.contains { if case .activity(.sourcesSelected) = $0 { true } else { false } },
                   "A reply that never searched has no search sources")
  }

  func testMalformedSearchResultsAreSkipped() async throws {
    let transport = SearchCodexTransport(script: [
      webSearchStarted(),
      webSearchCompleted(results: [
        .object(["type": .string("text_result"), "url": .number(5), "title": .string("Number")]),
        .object(["type": .string("text_result"), "title": .string("No URL")]),
        result("javascript:alert(1)", title: "Script"),
        result("https://user:secret@example.com/", title: "Credentials"),
        result("/relative/path", title: "Relative"),
        .string("A plain string summary"),
        .object(["type": .string("text_result"), "url": .string("https://good.example/a")]),
        result("https://good.example/b", title: "Good B"),
      ], action: .object(["type": .string("openPage"), "url": .string("https://page.example/opened")])),
      webSearchCompleted(results: .string("not a list"), action: .object(["type": .string("findInPage"),
                                                                           "url": .string("javascript:void(0)")])),
      delta("No links here."),
      completion("completed"),
    ])
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()))
    let discovered = events.flatMap { event -> [WebSearchSource] in
      if case .activity(.sourcesDiscovered(let sources)) = event { return sources }
      return []
    }
    XCTAssertEqual(discovered.map(\.url.absoluteString),
                   ["https://good.example/a", "https://good.example/b", "https://page.example/opened"])
    XCTAssertEqual(discovered.first?.title, "good.example", "A missing title becomes the site name")
    guard case .activity(.sourcesSelected(let selected)) = events[events.count - 2] else { return XCTFail("No selection") }
    XCTAssertEqual(selected.map(\.url), discovered.map(\.url), "Nothing cited, so the results the model saw")
  }

  func testCodexSearchAndDynamicToolTogether() async throws {
    let toolbox = SearchNoteToolbox()
    let transport = SearchCodexTransport(script: try fixtureNotifications("codex-search-and-dynamic-tool.jsonl"))
    let events = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: toolbox))
    XCTAssertEqual(toolbox.calls, ["get_saved_note"])
    let responses = await transport.responses
    XCTAssertEqual(responses.count, 1)
    XCTAssertEqual(responses.first?["success"].bool, true)
    XCTAssertTrue(events.contains(.activity(.phase(.searching))))
    XCTAssertEqual(events.last, .completed)
    guard case .activity(.sourcesSelected(let selected)) = events[events.count - 2] else { return XCTFail("No selection") }
    XCTAssertEqual(selected.first?.url.host(), "www.apple.com")
    XCTAssertEqual(selected.count, 1)
  }

  func testCodexThreadStartErrorIsUnavailable() async throws {
    let transport = SearchCodexTransport(threadStartError: "Invalid config: web_search mode \"live\" is not allowed by requirements")
    do {
      _ = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: SearchNoteToolbox()))
      XCTFail("Expected provider search to be unavailable")
    } catch { XCTAssertEqual(error as? CloudProviderError, .webSearchUnavailable(.chatGPT)) }

    // Another thread error, or the same one without provider search, stays as it is.
    let other = SearchCodexTransport(threadStartError: "Model not found")
    do {
      _ = try await collect(CodexSubscriptionClient(transport: other).stream(searchRequest(), toolbox: SearchNoteToolbox()))
      XCTFail("Expected the error")
    } catch { XCTAssertEqual(error as? CodexError, .server("Model not found")) }
    var plain = searchRequest()
    plain.providerSearch = nil
    let unsearched = SearchCodexTransport(threadStartError: "web search is off")
    do {
      _ = try await collect(CodexSubscriptionClient(transport: unsearched).stream(plain, toolbox: SearchNoteToolbox()))
      XCTFail("Expected the error")
    } catch { XCTAssertEqual(error as? CodexError, .server("web search is off")) }
  }

  func testCodexTurnFailingOnWebSearchBeforeTextIsUnavailable() async throws {
    let before = SearchCodexTransport(script: [completion("failed", message: "Web search is not enabled for this workspace.")])
    do {
      _ = try await collect(CodexSubscriptionClient(transport: before).stream(searchRequest(), toolbox: SearchNoteToolbox()))
      XCTFail("Expected provider search to be unavailable")
    } catch { XCTAssertEqual(error as? CloudProviderError, .webSearchUnavailable(.chatGPT)) }

    let after = SearchCodexTransport(script: [delta("Partly"), completion("failed", message: "Web search is not enabled for this workspace.")])
    do {
      _ = try await collect(CodexSubscriptionClient(transport: after).stream(searchRequest(), toolbox: SearchNoteToolbox()))
      XCTFail("Expected the error")
    } catch {
      XCTAssertEqual(error as? CodexError, .server("Web search is not enabled for this workspace."),
                     "After text arrived it's an ordinary failure")
    }
  }

  func testCodexRestartDeliversNothing() async throws {
    let toolbox = SearchNoteToolbox(stop: .restart)
    let transport = SearchCodexTransport(script: [
      webSearchStarted(), webSearchCompleted(results: [result("https://www.swift.org/", title: "Swift")]),
      toolCall("get_saved_note"),
      delta("This must never arrive."),
      completion("completed"),
    ])
    do {
      _ = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: toolbox))
      XCTFail("Expected a restart")
    } catch { XCTAssertTrue(error is ProviderSearchRestart, "\(error)") }
    try await waitForInterrupt(transport)
    let responses = await transport.responses
    XCTAssertEqual(responses, [], "The held-back result is never answered")
    XCTAssertEqual(toolbox.calls, ["get_saved_note"])
    let order = await transport.methods
    XCTAssertEqual(order.filter { $0 == "turn/interrupt" }.count, 1)
  }

  func testCodexMessagesStopStillInterruptsTheTurn() async throws {
    let toolbox = SearchNoteToolbox(stop: .messages(.automationDenied))
    let transport = SearchCodexTransport(script: [toolCall("get_saved_note"), delta("Never."), completion("completed")])
    do {
      _ = try await collect(CodexSubscriptionClient(transport: transport).stream(searchRequest(), toolbox: toolbox))
      XCTFail("Expected the Messages stop")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    try await waitForInterrupt(transport)
  }

  // MARK: Provider search helpers

  private func searchRequest() -> ChatRequest {
    var request = request(modelID: "gpt-5.6-luna")
    request.providerSearch = ProviderSearch()
    return request
  }

  private func waitForInterrupt(_ transport: SearchCodexTransport) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await !transport.methods.contains("turn/interrupt"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let methods = await transport.methods
    XCTAssertTrue(methods.contains("turn/interrupt"), "The Codex turn must be interrupted")
  }

  private func fixtureNotifications(_ name: String) throws -> [CodexNotification] {
    let text = try String(contentsOf: CloudSearchFixture.url(name), encoding: .utf8)
    return try text.split(separator: "\n").map { line in
      let value = try JSONDecoder().decode(CodexValue.self, from: Data(line.utf8))
      return CodexNotification(method: value["method"].string ?? "", params: value["params"])
    }
  }

  private func result(_ url: String, title: String) -> CodexValue {
    .object(["type": .string("text_result"), "url": .string(url), "title": .string(title), "domain": .string("example")])
  }

  private func webSearchStarted() -> CodexNotification {
    CodexNotification(method: "item/started", params: .object([
      "threadId": .string("thread-one"), "turnId": .string("turn-one"),
      "item": .object(["type": .string("webSearch"), "id": .string("search-one"), "query": .string(""),
                       "action": .null, "results": .null]),
    ]))
  }

  private func webSearchCompleted(results: [CodexValue], action: CodexValue? = nil) -> CodexNotification {
    webSearchCompleted(results: .array(results), action: action)
  }

  private func webSearchCompleted(results: CodexValue, action: CodexValue? = nil) -> CodexNotification {
    CodexNotification(method: "item/completed", params: .object([
      "threadId": .string("thread-one"), "turnId": .string("turn-one"),
      "item": .object(["type": .string("webSearch"), "id": .string("search-one"), "query": .string("swift"),
                       "action": action ?? .object(["type": .string("search"), "query": .string("swift")]),
                       "results": results]),
    ]))
  }

  private func toolCall(_ name: String) -> CodexNotification {
    CodexNotification(method: "item/tool/call", params: .object([
      "threadId": .string("thread-one"), "turnId": .string("turn-one"), "callId": .string("call-one"),
      "namespace": .null, "tool": .string(name), "arguments": .object([:]),
    ]))
  }
}

/// One dynamic tool, `get_saved_note`, as in the recorded fixture. With `stop`, its result is terminal.
private final class SearchNoteToolbox: AgentToolbox, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private let stop: AgentToolStop?

  init(stop: AgentToolStop? = nil) { self.stop = stop }

  var calls: [String] { lock.withLock { recorded } }
  var instructions: String { "Use get_saved_note for the user's notes.\nSEARCH INSTRUCTION" }
  var definitions: [AgentToolDefinition] {
    [AgentToolDefinition(name: "get_saved_note", description: "Reads a saved note.",
                         properties: ["topic": .object(["type": .string("string")])], required: [])]
  }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    lock.withLock { recorded.append(name) }
    if let stop {
      return AgentToolResult(text: "The request was restarted.", success: false, terminal: true, stop: stop)
    }
    return AgentToolResult(text: "Note on the conference: it's WWDC; check this year's dates.", success: true)
  }
}

/// Plays a turn's notifications and server requests, as the Codex app server does: a dynamic tool
/// call goes to the thread's handler, and its answer is written only while that handler is set.
/// Removing the handler cancels a call still running, as `CodexAppServer.setFileHandler` does.
/// `NativeToolRequestTests` uses it for ChatGPT turns through `submitNative`.
actor SearchCodexTransport: CodexRPCTransport {
  private let requirements: CodexValue
  private let threadStartError: String?
  private let script: [CodexNotification]
  private var handler: CodexServerRequestHandler?
  private var running: Task<CodexValue, Never>?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private var interrupted = false
  private(set) var methods: [String] = []
  private(set) var responses: [CodexValue] = []
  private(set) var threadStart: CodexValue?

  init(requirements: CodexValue = .object(["requirements": .null]), threadStartError: String? = nil,
       script: [CodexNotification] = []) {
    self.requirements = requirements
    self.threadStartError = threadStartError
    self.script = script
  }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    methods.append(method)
    switch method {
    case "account/read": return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "configRequirements/read": return requirements
    case "thread/start":
      threadStart = params
      if let threadStartError { throw CodexError.server(threadStartError) }
      return .object(["thread": .object(["id": .string("thread-one")])])
    case "turn/start":
      Task { await play() }
      return .object(["turn": .object(["id": .string("turn-one")])])
    case "turn/interrupt":
      interrupted = true
      emit(CodexNotification(method: "turn/completed", params: .object([
        "threadId": .string("thread-one"), "turn": .object(["id": .string("turn-one"), "status": .string("interrupted")])])))
      return .object([:])
    default: return .object([:])
    }
  }

  func prepareFileMode() async throws {}

  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws {
    self.handler = handler
    if handler == nil { running?.cancel() }
  }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    }
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in await self?.removeObserver(id) })
  }

  private func play() async {
    for notification in script {
      guard !interrupted else { return }
      if notification.method == "item/tool/call" {
        guard let handler else { return }
        let task = Task { await handler(notification.method, notification.params) }
        running = task
        let answer = await task.value
        running = nil
        guard self.handler != nil else { return }
        responses.append(answer)
      } else {
        emit(notification)
      }
    }
  }

  private func emit(_ notification: CodexNotification) {
    for continuation in observers.values { continuation.yield(notification) }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

private actor AnsweredCalls {
  private(set) var ids: [String] = []
  func add(_ id: String) { ids.append(id) }
}
