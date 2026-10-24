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
