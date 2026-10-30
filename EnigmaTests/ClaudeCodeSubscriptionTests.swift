import Foundation
import XCTest
@testable import Enigma

final class ClaudeCodeSubscriptionTests: XCTestCase {
  func testRuntimeUsesSubscriptionLoginAndDisablesCustomizationsAndTools() {
    let runtime = ClaudeCodeRuntime(directory: URL(fileURLWithPath: "/tmp/enigma-claude-code"))
    XCTAssertEqual(runtime.environment["USER"], NSUserName())
    XCTAssertNotNil(runtime.environment["HOME"])
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
      XCTAssertNil(runtime.environment[key], key)
    }
    let arguments = ClaudeCodeRuntime.chatArguments(model: "opus", effort: .automatic)
    for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                 "--include-partial-messages", "--verbose"] {
      XCTAssertTrue(arguments.contains(flag), flag)
    }
    XCTAssertEqual(value(after: "--tools", in: arguments), "")
    XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
    XCTAssertEqual(value(after: "--model", in: arguments), "opus")
    XCTAssertEqual(value(after: "--system-prompt", in: arguments), ClaudeCodeRuntime.systemPrompt)
    XCTAssertFalse(arguments.contains("--effort"))
    XCTAssertEqual(value(after: "--effort", in: ClaudeCodeRuntime.chatArguments(model: "opus", effort: .xhigh)), "xhigh")
    XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
  }

  func testThinkRaisesEffortWithoutLoweringAHigherChoice() {
    XCTAssertEqual(ClaudeCodeEffort.automatic.forExtendedThinking, .high)
    XCTAssertEqual(ClaudeCodeEffort.low.forExtendedThinking, .high)
    XCTAssertEqual(ClaudeCodeEffort.max.forExtendedThinking, .max)
  }

  func testParserStreamsTextDeltasAcrossChunkBoundariesAndIgnoresThinking() throws {
    var parser = ClaudeCodeStreamParser()
    let lines = [
      #"{"type":"system","subtype":"init","model":"claude"}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret"}}}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello 👋"}}}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Hello 👋 there"}"#,
    ].joined(separator: "\n") + "\n"
    let data = Data(lines.utf8)
    let split = data.count / 2
    var events = try parser.consume(data.prefix(split))
    events += try parser.consume(data.suffix(from: split))
    XCTAssertEqual(events, [.token("Hello 👋"), .token(" there"), .completed(result: "Hello 👋 there")])
  }

  func testParserReportsErrorResultsAndRejectsInvalidJSON() throws {
    var parser = ClaudeCodeStreamParser()
    XCTAssertEqual(
      try parser.consume(Data(#"{"type":"result","subtype":"success","is_error":true,"result":"Usage limit reached"}"#.utf8 + [0x0a])),
      [.failed("Usage limit reached")]
    )
    var invalid = ClaudeCodeStreamParser()
    XCTAssertThrowsError(try invalid.consume(Data("not json\n".utf8))) {
      XCTAssertEqual($0 as? ClaudeCodeError, .invalidResponse)
    }
  }

  func testAccountReadsSubscriptionStatus() async throws {
    let root = try temporaryDirectory()
    let signedIn = try client(root: root, script: """
      #!/bin/sh
      [ "$1" = "auth" ] && [ "$2" = "status" ] || exit 9
      /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"max"}'
      """)
    let account = try await signedIn.account()
    XCTAssertEqual(account, ClaudeCodeAccount(email: "person@example.com", plan: "max"))
    let models = try await signedIn.models()
    XCTAssertEqual(models.map(\.id), ["sonnet", "opus", "fable", "haiku"])

    let signedOut = try client(root: root, name: "signed-out", script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      exit 1
      """)
    let missingAccount = try await signedOut.account()
    XCTAssertNil(missingAccount)
    await assertThrows(ClaudeCodeError.notSignedIn) { _ = try await signedOut.models() }

    let console = try client(root: root, name: "console", script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"console"}'
      """)
    await assertThrows(ClaudeCodeError.notSubscription) { _ = try await console.account() }
  }

  func testMissingClaudeCodeReturnsActionableErrorWithoutLaunching() async {
    let client = ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: FileManager.default.temporaryDirectory, executable: { nil }))
    XCTAssertFalse(client.isInstalled)
    await assertThrows(ClaudeCodeError.notInstalled) { _ = try await client.account() }
    await assertThrows(ClaudeCodeError.notInstalled) { _ = try await self.events(client.stream(self.request())) }
  }

  func testStreamSendsConversationOnStandardInputAndStreamsTokens() async throws {
    let root = try temporaryDirectory()
    let client = try client(root: root, effort: .low, script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' "$@" > '\(root.path)/arguments'
      /bin/cat > '\(root.path)/input'
      /usr/bin/printf '%s\\n' '{"type":"system","subtype":"init"}'
      /usr/bin/printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}'
      /usr/bin/printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}}'
      /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Hi there"}'
      """)
    let received = try await events(client.stream(request(modelID: "opus", latest: "/think Latest question")))
    XCTAssertEqual(received, [.token("Hi"), .token(" there"), .completed])
    let arguments = try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(value(after: "--model", in: arguments), "opus")
    XCTAssertEqual(value(after: "--effort", in: arguments), "high")
    let input = try String(contentsOf: root.appending(path: "input"), encoding: .utf8)
    XCTAssertTrue(input.hasPrefix("Continue this conversation:"))
    XCTAssertTrue(input.contains("Previous answer"))
    XCTAssertTrue(input.contains("Latest question"))
  }

  func testScreenshotIsSentAsOneStreamJSONUserMessage() async throws {
    let root = try temporaryDirectory()
    let client = try client(root: root, script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' "$@" > '\(root.path)/arguments'
      /bin/cat > '\(root.path)/input'
      /usr/bin/printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"A chart"}}}'
      /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"A chart"}'
      """)
    let image = PreparedScreenImage(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", pixelWidth: 2, pixelHeight: 2)
    var send = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "What is in this picture?")],
      route: Route(mode: .cloud, providerID: CloudProviderID.claudeCode.rawValue, modelID: "opus", usesNetwork: true),
      image: image)
    send.allowsCloudImages = false
    await assertThrowsScreenError(.cloudUploadNotAllowed) { _ = try await self.events(client.stream(send)) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "input").path), "Nothing ran")

    send.allowsCloudImages = true
    let received = try await events(client.stream(send))
    XCTAssertEqual(received, [.token("A chart"), .completed])
    let arguments = try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(Array(arguments.prefix(3)), ["-p", "--input-format", "stream-json"])
    XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
    XCTAssertEqual(value(after: "--tools", in: arguments), "")
    XCTAssertEqual(value(after: "--model", in: arguments), "opus")
    let input = try String(contentsOf: root.appending(path: "input"), encoding: .utf8)
    XCTAssertEqual(input, #"{"message":{"content":[{"source":{"data":"/9j/","media_type":"image/jpeg","type":"base64"},"type":"image"},{"text":"What is in this picture?","type":"text"}],"role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user"}"# + "\n")
    XCTAssertEqual(try ClaudeCodeSubscriptionClient.standardInput(prompt: "Hi", image: nil), Data("Hi".utf8),
                   "Text-only requests keep plain text")
    XCTAssertFalse(ClaudeCodeRuntime.chatArguments(model: "opus", effort: .automatic).contains("--input-format"))
    XCTAssertFalse(ClaudeCodeRuntime.systemPrompt.contains("text-only"))
  }

  func testALargeScreenshotSurvivesACLIThatExitsWithoutReadingIt() async throws {
    let root = try temporaryDirectory()
    let client = try client(root: root, script: """
      #!/bin/sh
      echo 'error: unknown option' >&2
      exit 2
      """)
    await assertThrows(.exited(2, "error: unknown option")) {
      _ = try await self.events(client.stream(self.largeScreenshotRequest()))
    }
  }

  func testToolModeWriteToAnExitedCLIReportsItsExit() async throws {
    let root = try temporaryDirectory()
    let process = try ClaudeCodeProcess(executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo 'bad flag' >&2; exit 3"], environment: [:], currentDirectory: root,
      input: nil, interactive: true)
    for await _ in process.output {}
    try await process.waitForExit()
    XCTAssertThrowsError(try process.send(.object(["type": .string("user")]))) {
      XCTAssertEqual($0 as? ClaudeCodeError, .exited(3, "bad flag"), "Not a file-saving error: \($0)")
    }
  }

  func testClosedInputReportsTheCLIsExitWhenItFollows() async throws {
    let root = try temporaryDirectory()
    let process = try ClaudeCodeProcess(executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exec 0<&-; /bin/sleep 0.3; echo 'stopped early' >&2; exit 4"], environment: [:],
      currentDirectory: root, input: nil, interactive: true)
    var sendError: ClaudeCodeError?
    for _ in 0..<50 where sendError == nil {
      do { try process.send(.object(["type": .string("user")])) } catch { sendError = error as? ClaudeCodeError }
      if sendError == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    XCTAssertEqual(sendError, .inputClosed, "Still running when the write fails")
    let reported = await process.errorAfterClosedInput()
    XCTAssertEqual(reported, .exited(4, "stopped early"), "The reason the CLI gave")
  }

  func testStoppingWhileTheCLIStartsWithALargeScreenshotIsSafe() async throws {
    let root = try temporaryDirectory()
    let client = try client(root: root, script: """
      #!/bin/sh
      exec /bin/sleep 5
      """)
    let stream = client.stream(largeScreenshotRequest())
    let task = Task {
      var received: [ChatEvent] = []
      for try await event in stream { received.append(event) }
      return received
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    // A cancelled stream ends (or throws CancellationError) without completing.
    do {
      let received = try await task.value
      XCTAssertFalse(received.contains(.completed))
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    // Give the blocked writer time to see the closed pipe; a SIGPIPE would end the test host here.
    try await Task.sleep(for: .milliseconds(300))
  }

  func testCompletedResultWithoutDeltasIsStillShown() async throws {
    let client = try client(root: try temporaryDirectory(), script: """
      #!/bin/sh
      /bin/cat > /dev/null
      /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Whole answer"}'
      """)
    let received = try await events(client.stream(request()))
    XCTAssertEqual(received, [.token("Whole answer"), .completed])
  }

  func testSignedOutAndUnexpectedExitBecomeErrors() async throws {
    let root = try temporaryDirectory()
    let signedOut = try client(root: root, script: """
      #!/bin/sh
      /bin/cat > /dev/null
      /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'
      """)
    await assertThrows(ClaudeCodeError.notSignedIn) { _ = try await self.events(signedOut.stream(self.request())) }

    let crashed = try client(root: root, name: "crashed", script: """
      #!/bin/sh
      /bin/cat > /dev/null
      echo "unknown option" >&2
      exit 3
      """)
    await assertThrows(ClaudeCodeError.exited(3, "unknown option")) { _ = try await self.events(crashed.stream(self.request())) }
  }

  func testStopTerminatesTheClaudeCodeProcess() async throws {
    let root = try temporaryDirectory()
    let pidFile = root.appending(path: "pid")
    let client = try client(root: root, script: """
      #!/bin/sh
      echo $$ > '\(pidFile.path)'
      /bin/cat > /dev/null
      /usr/bin/printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial"}}}'
      exec /bin/sleep 30
      """)
    let stream = client.stream(request())
    let task = Task {
      var tokens: [String] = []
      for try await event in stream {
        if case .token(let text) = event { tokens.append(text) }
      }
      return tokens
    }
    let pid = try await waitForPID(at: pidFile)
    task.cancel()
    _ = try? await task.value
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotEqual(kill(pid, 0), 0, "Claude Code kept running after Stop")
  }

  func testTerminalToolResultStopsTheProcessWithTheMessagesError() async throws {
    let root = try temporaryDirectory()
    let pidFile = root.appending(path: "pid")
    let call = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"mcp_message","server_name":"enigma","message":{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"lookup","arguments":{"query":"x"}}}}}"#
    let client = try client(root: root, script: """
      #!/bin/sh
      echo $$ > '\(pidFile.path)'
      /usr/bin/printf '%s\\n' '\(call)'
      /usr/bin/printf '%s\\n' '\(call)'
      exec /bin/sleep 10
      """)
    let toolbox = StoppingToolbox(.automationDenied)
    do {
      _ = try await events(client.stream(request(), toolbox: toolbox))
      XCTFail("Expected the request to stop")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    XCTAssertEqual(toolbox.callCount, 1, "A second call must not run the tool again")
    let pid = try await waitForPID(at: pidFile)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotEqual(kill(pid, 0), 0, "Claude Code kept running after the stop")
  }

  @MainActor
  func testSettingsUseClaudeCodeAccessAndDefaultModel() async throws {
    let root = try temporaryDirectory()
    let claudeCode = try client(root: root, script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"pro"}'
      """)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeCodeSettings-\(UUID())"))
    let preferences = CloudPreferencesStore(defaults: defaults)
    preferences.setPreferredProvider(.claudeCode)
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: preferences, codexAvailable: { false }, claudeCode: claudeCode
    )
    XCTAssertEqual(settings.preferredModelID, "sonnet")
    XCTAssertFalse(settings.hasCloudAccess(for: .claudeCode))
    XCTAssertFalse(settings.hasAPIKey(for: .claudeCode))
    await settings.refreshClaudeCodeAccount()
    XCTAssertEqual(settings.claudeCodeAccount?.plan, "pro")
    XCTAssertTrue(settings.hasCloudAccess(for: .claudeCode))
    XCTAssertTrue(settings.isConfigured)
    await settings.discoverModels(forceRefresh: true)
    XCTAssertEqual(settings.models.map(\.id), ["sonnet", "opus", "fable", "haiku"])
    XCTAssertEqual(settings.selectedModelCompatibility, .compatible)

    settings.claudeCodeEffort = .max
    XCTAssertEqual(preferences.preferredClaudeCodeEffort(), .max)
    settings.preferredModelID = "claude-sonnet-5-5"
    XCTAssertEqual(settings.selectedModelCompatibility, .unverified)
    XCTAssertTrue(settings.isConfigured)
  }

  @MainActor
  func testCheckSignInReportsEveryOutcomeAndClearsRunningFlag() async throws {
    let root = try temporaryDirectory()
    func model(script: String?, name: String) throws -> CloudSettingsModel {
      let claudeCode: ClaudeCodeSubscriptionClient
      if let script {
        claudeCode = try client(root: root, name: name, script: script)
      } else {
        let runtime = ClaudeCodeRuntime(directory: root.appending(path: "none"), executable: { nil })
        claudeCode = ClaudeCodeSubscriptionClient(runtime: runtime)
      }
      let credentials = ClaudeCodeTestCredentials()
      let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeCodeCheck-\(UUID())"))
      return CloudSettingsModel(
        credentialStore: credentials,
        catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                   cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
        preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false }, claudeCode: claudeCode
      )
    }
    let missing = try model(script: nil, name: "missing")
    await missing.checkClaudeCodeSignIn()
    XCTAssertEqual(missing.claudeCodeCheck, .notInstalled)
    XCTAssertFalse(missing.isCheckingClaudeCode)

    let out = try model(script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      """, name: "out")
    await out.checkClaudeCodeSignIn()
    XCTAssertEqual(out.claudeCodeCheck, .notSignedIn)
    XCTAssertFalse(out.isCheckingClaudeCode)

    let signedIn = try model(script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"pro"}'
      """, name: "in")
    await signedIn.checkClaudeCodeSignIn()
    XCTAssertEqual(signedIn.claudeCodeCheck, .signedIn("person@example.com"))
    XCTAssertFalse(signedIn.isCheckingClaudeCode)

    let broken = try model(script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' 'not json'
      """, name: "broken")
    await broken.checkClaudeCodeSignIn()
    guard case .failed(let message) = broken.claudeCodeCheck else { return XCTFail("Expected a failure") }
    XCTAssertFalse(message.isEmpty)
    XCTAssertFalse(broken.isCheckingClaudeCode)

    let quiet = try model(script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      """, name: "quiet")
    await quiet.refreshClaudeCodeAccount()
    XCTAssertNil(quiet.claudeCodeCheck)

    // A later refresh clears a result it may contradict.
    await quiet.checkClaudeCodeSignIn()
    XCTAssertEqual(quiet.claudeCodeCheck, .notSignedIn)
    await quiet.refreshClaudeCodeAccount()
    XCTAssertNil(quiet.claudeCodeCheck)
  }

  @MainActor
  func testSignInOpensTerminalScriptAndSelectsClaudeOnceStatusReportsLogin() async throws {
    let root = try temporaryDirectory()
    let marker = root.appending(path: "signed-in")
    let claudeCode = try client(root: root, script: """
      #!/bin/sh
      if [ -e '\(marker.path)' ]; then
        /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"max"}'
      else
        /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      fi
      """)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeCodeSignIn-\(UUID())"))
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
      claudeCode: claudeCode, claudeCodeSignInPollInterval: .milliseconds(20)
    )
    var openedScript: URL?
    settings.signInToClaudeCode { url in
      openedScript = url
      return true
    }
    XCTAssertTrue(settings.isWaitingForClaudeCodeSignIn)
    let script = try String(contentsOf: try XCTUnwrap(openedScript), encoding: .utf8)
    XCTAssertTrue(script.contains("auth login --claudeai"))
    try Data().write(to: marker)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while settings.isWaitingForClaudeCodeSignIn, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(settings.claudeCodeAccount?.email, "person@example.com")
    XCTAssertEqual(settings.preferredProvider, .claudeCode)
    XCTAssertEqual(settings.models.map(\.id), ["sonnet", "opus", "fable", "haiku"])
  }

  @MainActor
  func testInstallRunsTheOfficialInstallerThenWaitsForSignIn() async throws {
    let root = try temporaryDirectory()
    let installedMarker = root.appending(path: "installed")
    let signedInMarker = root.appending(path: "signed-in")
    let executable = root.appending(path: "fake-claude")
    try Data("""
      #!/bin/sh
      if [ -e '\(signedInMarker.path)' ]; then
        /usr/bin/printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"pro"}'
      else
        /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      fi
      """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runtime = ClaudeCodeRuntime(directory: root.appending(path: "runtime"), executable: {
      FileManager.default.fileExists(atPath: installedMarker.path) ? executable : nil
    })
    let claudeCode = ClaudeCodeSubscriptionClient(runtime: runtime, statusTimeout: .seconds(10))
    let suite = "ClaudeCodeInstall-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
      claudeCode: claudeCode, claudeCodeSignInPollInterval: .milliseconds(20)
    )
    XCTAssertFalse(settings.isClaudeCodeAvailable)
    var openedScript: URL?
    settings.installClaudeCode { url in
      openedScript = url
      return true
    }
    XCTAssertTrue(settings.isWaitingForClaudeCodeSignIn)
    XCTAssertTrue(settings.isInstallingClaudeCode)
    let scriptURL = try XCTUnwrap(openedScript)
    XCTAssertEqual(scriptURL.pathExtension, "command")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    XCTAssertTrue(script.hasPrefix("#!/bin/bash\nset -o pipefail\n"))
    XCTAssertTrue(script.contains("if \(ClaudeCodeRuntime.installCommand); then"))
    XCTAssertEqual(ClaudeCodeRuntime.installCommand, "curl -fsSL https://claude.ai/install.sh | bash")
    XCTAssertTrue(script.contains("\"$claude\" auth login --claudeai"))
    let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/bin/bash")
    check.arguments = ["-n", scriptURL.path]
    try check.run()
    check.waitUntilExit()
    XCTAssertEqual(check.terminationStatus, 0, "The install script is valid bash")

    // Installed but not signed in yet: Enigma keeps waiting.
    try Data().write(to: installedMarker)
    try await waitUntil { settings.isClaudeCodeAvailable }
    XCTAssertTrue(settings.isWaitingForClaudeCodeSignIn)
    try Data().write(to: signedInMarker)
    try await waitUntil { !settings.isWaitingForClaudeCodeSignIn }
    XCTAssertFalse(settings.isInstallingClaudeCode)
    XCTAssertEqual(settings.claudeCodeAccount?.email, "person@example.com")
    XCTAssertEqual(settings.preferredProvider, .claudeCode)
    XCTAssertEqual(settings.models.map(\.id), ["sonnet", "opus", "fable", "haiku"])
    XCTAssertGreaterThan(CloudSettingsModel.claudeCodeInstallAttempts, CloudSettingsModel.claudeCodeSignInAttempts)
  }

  @MainActor
  func testCancellingTheInstallWaitStopsWaitingAndTerminalFailureIsReported() async throws {
    let root = try temporaryDirectory()
    let claudeCode = ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root, executable: { nil }))
    let suite = "ClaudeCodeInstallCancel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
      claudeCode: claudeCode, claudeCodeSignInPollInterval: .milliseconds(20)
    )
    settings.installClaudeCode { _ in false }
    XCTAssertFalse(settings.isWaitingForClaudeCodeSignIn)
    XCTAssertEqual(settings.claudeCodeError, "Terminal could not be opened to install Claude Code.")

    settings.installClaudeCode { _ in true }
    XCTAssertTrue(settings.isWaitingForClaudeCodeSignIn)
    settings.cancelClaudeCodeSignIn()
    try await waitUntil { !settings.isWaitingForClaudeCodeSignIn }
    XCTAssertFalse(settings.isInstallingClaudeCode)
    XCTAssertNil(settings.claudeCodeAccount)
  }

  @MainActor
  func testChoosingClaudeCodeSavesOnlyAnExecutableFile() async throws {
    let root = try temporaryDirectory()
    let claudeCode = ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root, executable: { nil }))
    let suite = "ClaudeCodeChoose-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = ClaudeCodeTestCredentials()
    let preferences = CloudPreferencesStore(defaults: defaults)
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: preferences, codexAvailable: { false }, claudeCode: claudeCode
    )
    let document = root.appending(path: "notes.txt")
    try Data("text".utf8).write(to: document)
    let rejected = await settings.chooseClaudeCode(at: document)
    XCTAssertFalse(rejected)
    XCTAssertNotNil(settings.claudeCodeError)
    XCTAssertNil(preferences.chosenClaudeCodePath())

    let program = root.appending(path: "claude")
    try Data("#!/bin/sh\n".utf8).write(to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    let accepted = await settings.chooseClaudeCode(at: program)
    XCTAssertTrue(accepted)
    XCTAssertFalse(settings.isCheckingClaudeCode)
    XCTAssertNotNil(settings.claudeCodeCheck, "Choosing a file checks it, like Check again")
    XCTAssertEqual(preferences.chosenClaudeCodePath(), program.path)
    XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.contains("claudeCodePath") }.count, 1)
    XCTAssertEqual(ClaudeCodeRuntime.executableURL(environment: [:], home: root.appending(path: "home").path,
                                                   loginShellPath: nil, chosenPath: program.path), program)
  }

  @MainActor
  func testBackgroundRefreshSkipsTheShellWhenClaudeCodeIsFound() async throws {
    let root = try temporaryDirectory()
    let executable = root.appending(path: "fake-claude")
    try Data("""
      #!/bin/sh
      /usr/bin/printf '%s\\n' '{"loggedIn":false}'
      """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let asked = ShellCalls()
    let runtime = ClaudeCodeRuntime(directory: root.appending(path: "runtime"), executable: { executable },
                                    prepareLookup: { _ in asked.record() })
    let claudeCode = ClaudeCodeSubscriptionClient(runtime: runtime, statusTimeout: .seconds(10))
    let suite = "ClaudeCodeShellSkip-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false }, claudeCode: claudeCode
    )
    let result = await settings.refreshClaudeCodeAccount()
    XCTAssertEqual(result, .notSignedIn)
    XCTAssertEqual(asked.count, 0, "The shell ranks below a found Claude Code, so it isn't asked")
    await settings.checkClaudeCodeSignIn()
    XCTAssertEqual(asked.count, 1, "The explicit check still asks")
  }

  @MainActor
  func testCheckAgainAsksTheShellAgainAfterACachedNotFound() async throws {

    let root = try temporaryDirectory()
    let asked = ShellCalls()
    let lookup = LoginShellToolLookup(shell: "/bin/sh") { _, _, _ in asked.record(); return "" }
    let runtime = ClaudeCodeRuntime(directory: root, executable: { nil }, prepareLookup: { askAgain in
      if askAgain { lookup.forgetNotFound("claude") }
      _ = await lookup.resolve("claude")
    }, lookedIn: { "~/somewhere and PATH" })
    let claudeCode = ClaudeCodeSubscriptionClient(runtime: runtime)
    let suite = "ClaudeCodeShellRetry-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = ClaudeCodeTestCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: root.appending(path: "cache"), claudeCode: claudeCode),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false }, claudeCode: claudeCode
    )
    await settings.refreshClaudeCodeAccount()
    await settings.refreshClaudeCodeAccount()
    XCTAssertEqual(asked.count, 1, "Background refreshes use the cached \"not found\"")
    await settings.checkClaudeCodeSignIn()
    XCTAssertEqual(asked.count, 2, "Check again asks the shell again")
    XCTAssertEqual(settings.claudeCodeCheck, .notInstalled)
    XCTAssertEqual(settings.claudeCodeLookedIn, "~/somewhere and PATH", "\"Looked in\" comes from the injected runtime")
  }

  func testClaudeCodeBudgetLeavesRoomForReplies() {
    let budget = ModelContextPolicy.cloud(provider: .claudeCode, modelID: "sonnet")
    XCTAssertEqual(budget.availableInputTokens, 32_768)
    let manual = ModelContextPolicy.cloud(provider: .claudeCode, modelID: "claude-future-model")
    XCTAssertLessThan(manual.contextWindow, 128_000)
    XCTAssertEqual(manual.availableInputTokens, 32_768)
    XCTAssertEqual(CloudModelCapabilities.visionModelIDs(for: .claudeCode), ["sonnet", "opus", "fable", "haiku"])
    XCTAssertFalse(CloudModel(id: "claude-future-model", displayName: "x", provider: .claudeCode).supportsVision,
                   "Full model names typed in stay text-only")
  }

  // MARK: - Helpers

  private func client(
    root: URL, name: String = "fake-claude", effort: ClaudeCodeEffort = .automatic, script: String
  ) throws -> ClaudeCodeSubscriptionClient {
    let executable = root.appending(path: name)
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runtime = ClaudeCodeRuntime(directory: root.appending(path: "runtime-\(name)"), executable: { executable })
    return ClaudeCodeSubscriptionClient(runtime: runtime, effort: { effort }, statusTimeout: .seconds(10))
  }

  private func request(modelID: String = "sonnet", latest: String = "Latest question") -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [
      ChatMessage(role: .user, content: "Previous question"),
      ChatMessage(role: .assistant, content: "Previous answer"),
      ThinkCommand.message(latest),
    ], route: Route(mode: .cloud, providerID: CloudProviderID.claudeCode.rawValue, modelID: modelID, usesNetwork: true))
  }

  /// A screenshot payload far larger than a pipe buffer, so the write to the CLI blocks.
  private func largeScreenshotRequest() -> ChatRequest {
    var bytes = Data([0xFF, 0xD8, 0xFF])
    bytes.append(Data(repeating: 0x42, count: 400_000))
    return ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "What is this?")],
      route: Route(mode: .cloud, providerID: CloudProviderID.claudeCode.rawValue, modelID: "opus", usesNetwork: true),
      image: PreparedScreenImage(data: bytes, mimeType: "image/jpeg", pixelWidth: 800, pixelHeight: 600),
      allowsCloudImages: true)
  }

  @MainActor
  private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("Timed out", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func events(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func assertThrowsScreenError(
    _ expected: ScreenRequestError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ScreenRequestError, expected, file: file, line: line)
    }
  }

  private func assertThrows(
    _ expected: ClaudeCodeError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ClaudeCodeError, expected, file: file, line: line)
    }
  }

  private func waitForPID(at url: URL) async throws -> pid_t {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if let text = try? String(contentsOf: url, encoding: .utf8),
         let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ClaudeCodeError.timedOut
  }

  private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ClaudeCodeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}

private struct ClaudeCodeTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { nil }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private final class ShellCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var count: Int { lock.withLock { calls } }
  func record() { lock.withLock { calls += 1 } }
}

// MARK: - Provider search (F30 CP5)

extension ClaudeCodeSubscriptionTests {
  func testClaudeCodeSearchArguments() {
    let toolbox = RecordingToolbox()
    let plain = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .automatic, toolbox: toolbox)
    let search = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .automatic, toolbox: toolbox,
                                                 providerSearch: ProviderSearch())
    XCTAssertEqual(value(after: "--tools", in: search), "WebSearch")
    XCTAssertEqual(value(after: "--allowedTools", in: search), "WebSearch,mcp__enigma__lookup")
    for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                 "--include-partial-messages", "--verbose"] {
      XCTAssertTrue(search.contains(flag), flag)
    }
    for flag in ["--mcp-config", "--input-format", "--output-format", "--model"] {
      XCTAssertEqual(value(after: flag, in: search), value(after: flag, in: plain), flag)
    }
    XCTAssertFalse(search.contains("--dangerously-skip-permissions"))
    XCTAssertFalse(search.joined(separator: " ").contains("WebFetch"), "WebFetch stays off")
    // Only the tools and their permission list change.
    XCTAssertEqual(search.count, plain.count)
    let changed = search.indices.filter { search[$0] != plain[$0] }.map { plain[$0 - 1] }
    XCTAssertEqual(Set(changed), ["--tools", "--allowedTools", "--system-prompt"])
  }

  func testClaudeCodeArgumentsWithoutSearchUnchanged() {
    let toolbox = RecordingToolbox()
    let arguments = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .high, toolbox: toolbox)
    XCTAssertEqual(arguments, ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .high, toolbox: toolbox,
                                                              providerSearch: nil))
    XCTAssertEqual(value(after: "--tools", in: arguments), "")
    XCTAssertEqual(value(after: "--allowedTools", in: arguments), "mcp__enigma__lookup")
    XCTAssertEqual(value(after: "--system-prompt", in: arguments), ClaudeCodeToolMode.systemPrompt(toolbox))
    XCTAssertTrue(ClaudeCodeToolMode.systemPrompt(toolbox).contains(
      "Use only the Enigma tools. You cannot read local files, run commands, or browse."))
    XCTAssertFalse(arguments.joined(separator: " ").contains("WebSearch"))
  }

  func testClaudeCodeSearchSystemPrompt() throws {
    let toolbox = AssistantToolbox(parts: [RecordingToolbox(), ProviderSearchPart()], requiredTool: nil, extraInstructions: [])
    let arguments = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .automatic, toolbox: toolbox,
                                                    providerSearch: ProviderSearch())
    let prompt = try XCTUnwrap(value(after: "--system-prompt", in: arguments))
    XCTAssertEqual(prompt, ClaudeCodeToolMode.systemPrompt(toolbox, providerSearch: true))
    XCTAssertTrue(prompt.contains("Use only the Enigma tools and WebSearch. You cannot read local files or run commands."))
    XCTAssertFalse(prompt.contains("or browse"), "Browsing would contradict web search")
    // Spec §4's instruction, from the toolbox, before the tools line.
    let instruction = try XCTUnwrap(prompt.range(of: "You can search the web with your web search tool."))
    let tools = try XCTUnwrap(prompt.range(of: "Use only the Enigma tools and WebSearch."))
    XCTAssertLessThan(instruction.lowerBound, tools.lowerBound)
    XCTAssertTrue(prompt.contains("Search at most 5 times."))
    XCTAssertTrue(prompt.contains("Link the pages you rely on."))
    XCTAssertTrue(prompt.contains("ask which city they mean"), "No location: ask which city")
  }

  func testClaudeCodeSearchSystemPromptWithLocation() throws {
    let location = ProviderSearchLocation(city: "Springfield", region: "IL", countryCode: "US", timeZone: "America/Chicago")
    let toolbox = AssistantToolbox(parts: [RecordingToolbox(), ProviderSearchPart(location: location)],
                                   requiredTool: nil, extraInstructions: [])
    let arguments = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .automatic, toolbox: toolbox,
                                                    providerSearch: ProviderSearch(location: location))
    let prompt = try XCTUnwrap(value(after: "--system-prompt", in: arguments))
    XCTAssertTrue(prompt.contains(
      "The user's approximate location is Springfield, IL, United States; your web search tool uses it for places and weather near them."))
    XCTAssertFalse(prompt.contains("ask which city they mean"))
    // Claude Code has no location field: the area goes only in the system prompt, never coordinates or the time zone.
    let others = arguments.filter { $0 != prompt }.joined(separator: " ")
    XCTAssertFalse(others.contains("Springfield"))
    XCTAssertFalse(arguments.joined(separator: " ").contains("America/Chicago"))
  }

  func testParserSearchEventsFromFixture() throws {
    var parser = ClaudeCodeStreamParser()
    let events = try parser.consume(Data(contentsOf: CloudSearchFixture.url("claude-code-web-search.jsonl")))
    XCTAssertEqual(events.first { if case .toolsListed = $0 { true } else { false } },
                   .toolsListed(["WebSearch", "mcp__enigma__propose_edit"]))
    XCTAssertEqual(events.filter { $0 == .searchStarted }.count, 2, "Two WebSearch calls")
    let batches = events.compactMap { event -> [WebSearchSource]? in
      if case .searchResults(let sources) = event { sources } else { nil }
    }
    XCTAssertEqual(batches.count, 2)
    XCTAssertTrue(batches.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(batches.first?.first?.title, "Grab Huge Savings Today on Apple MacBook Air From $799")
    XCTAssertTrue(batches.joined().allSatisfy(\.isSafeWebLink))
    // The toolsListed event comes before any search, and the searches before the answer.
    let listed = try XCTUnwrap(events.firstIndex { if case .toolsListed = $0 { true } else { false } })
    let started = try XCTUnwrap(events.firstIndex(of: .searchStarted))
    let text = try XCTUnwrap(events.firstIndex { if case .token = $0 { true } else { false } })
    XCTAssertLessThan(listed, started)
    XCTAssertLessThan(started, text)
    XCTAssertEqual(events.last.map { if case .completed = $0 { true } else { false } }, true)
  }

  func testParserSkipsMalformedSearchResults() throws {
    var parser = ClaudeCodeStreamParser()
    let start = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-9","name":"WebSearch","input":{}}}}"#
    let results = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-9","type":"tool_result","content":"…"}]},"tool_use_result":{"query":"q","results":["A prose summary.",{"tool_use_id":"srvtoolu-1"},{"tool_use_id":"srvtoolu-2","content":"not a list"},{"tool_use_id":"srvtoolu-3","content":[{"title":"Script","url":"javascript:alert(1)"},{"title":"Login","url":"https://user:pass@example.com/"},{"title":"Relative","url":"/path"},{"title":"No URL"},{"title":7,"url":"https://numbers.example/"},{"title":"Good","url":"https://example.com/good"},{"url":"https://untitled.example/page"}]}]}}"#
    let failed = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-9","type":"tool_result","content":"Error","is_error":true}]},"tool_use_result":"Error: API Error: 400"}"#
    // Another tool's result never becomes sources.
    let other = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-other","type":"tool_result","content":"x"}]},"tool_use_result":{"results":[{"content":[{"title":"Mine","url":"https://other.example/"}]}]}}"#
    // An Enigma tool's call is not a search, even with a search-shaped result.
    let mcpStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu-mcp","name":"mcp__enigma__lookup","input":{}}}}"#
    let mcpResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-mcp","type":"tool_result","content":"x"}]},"tool_use_result":{"results":[{"content":[{"title":"Tool","url":"https://tool.example/"}]}]}}"#
    let lines = [start, results, failed, other, mcpStart, mcpResult]
    let events = try parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
    XCTAssertEqual(events, [
      .searchStarted,
      .searchResults([
        WebSearchSource(title: "numbers.example", url: URL(string: "https://numbers.example/")!),
        WebSearchSource(title: "Good", url: URL(string: "https://example.com/good")!),
        WebSearchSource(title: "untitled.example", url: URL(string: "https://untitled.example/page")!),
      ]),
      .searchResults([]),
    ])
  }

  func testInitWithoutWebSearchIsUnavailable() async throws {
    let root = try temporaryDirectory()
    let pidFile = root.appending(path: "pid")
    let fixture = CloudSearchFixture.url("claude-code-init-without-websearch.jsonl")
    let text = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Too early"}}}"#
    let client = try client(root: root, script: """
      #!/bin/sh
      echo $$ > '\(pidFile.path)'
      /usr/bin/printf '%s\\n' '\(text)'
      /bin/cat '\(fixture.path)'
      exec /bin/sleep 10
      """)
    var received: [ChatEvent] = []
    do {
      for try await event in client.stream(searchRequest(), toolbox: RecordingToolbox()) { received.append(event) }
      XCTFail("Expected web search to be unavailable")
    } catch {
      XCTAssertEqual(error as? CloudProviderError, .webSearchUnavailable(.claudeCode))
    }
    XCTAssertFalse(received.contains { if case .token = $0 { true } else { false } }, "No text before the check")
    let pid = try await waitForPID(at: pidFile)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotEqual(kill(pid, 0), 0, "Claude Code kept running")

    // Without provider search the same start-up is fine: no WebSearch was asked for.
    let plain = try self.client(root: root, name: "plain", script: """
      #!/bin/sh
      /bin/cat '\(fixture.path)'
      /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Fine"}'
      exec /bin/sleep 10
      """)
    let events = try await events(plain.stream(request(), toolbox: RecordingToolbox()))
    XCTAssertEqual(events.filter { if case .activity = $0 { false } else { true } }, [.token("Fine"), .completed])
  }

  func testClaudeCodeSourcesFromAnswerLinks() async throws {
    let root = try temporaryDirectory()
    let fixture = CloudSearchFixture.url("claude-code-web-search.jsonl")
    let client = try client(root: root, script: """
      #!/bin/sh
      /bin/cat '\(fixture.path)'
      exec /bin/sleep 10
      """)
    let received = try await events(client.stream(searchRequest(), toolbox: RecordingToolbox()))
    XCTAssertEqual(received.filter { $0 == .activity(.phase(.searching)) }.count, 2)
    let discovered = received.compactMap { event -> [WebSearchSource]? in
      if case .activity(.sourcesDiscovered(let sources)) = event { sources } else { nil }
    }
    XCTAssertEqual(discovered.count, 2)
    let selected = received.compactMap { event -> [WebSearchSource]? in
      if case .activity(.sourcesSelected(let sources)) = event { sources } else { nil }
    }
    XCTAssertEqual(selected.count, 1)
    let sources = try XCTUnwrap(selected.first)
    // The answer's links, in order, as the citations; capped at 8.
    XCTAssertEqual(sources.map(\.url.absoluteString), [
      "https://www.apple.com/macbook-air/",
      "https://9to5mac.com/2026/10/29/you-can-now-spend-between-1999-and-14549-on-a-macbook-pro/",
      "https://www.macprices.net/15-macbook-air/",
      "https://www.macrumors.com/2026/10/28/new-macbook-pro-maxed-out-cost/",
      "https://tech-insider.org/macbook-20-years-history-lineup-prices-2026/",
      "https://appleinsider.com/deals/best-macbook-air-deals",
      "https://www.theapplepost.com/2026/10/28/73731/new-macbook-pro-starts-at-2899-as-apple-opens-pre-orders/",
    ])
    XCTAssertTrue(sources.allSatisfy { !$0.title.isEmpty && $0.isSafeWebLink })
    // Selected before completing, after the last text.
    let selectedIndex = try XCTUnwrap(received.firstIndex { if case .activity(.sourcesSelected) = $0 { true } else { false } })
    XCTAssertEqual(received.last, .completed)
    XCTAssertEqual(selectedIndex, received.count - 2)
    let answer = received.compactMap { if case .token(let text) = $0 { text } else { nil } }.joined()
    XCTAssertTrue(answer.hasSuffix("as-apple-opens-pre-orders/)"), "The closing Sources: list stays in the reply")

    // Without provider search, no search events are reported.
    let plain = try self.client(root: root, name: "plain", script: """
      #!/bin/sh
      /bin/cat '\(fixture.path)'
      exec /bin/sleep 10
      """)
    let plainEvents = try await events(plain.stream(request(), toolbox: RecordingToolbox()))
    XCTAssertFalse(plainEvents.contains { if case .activity(.sourcesSelected) = $0 { true } else { false } })
    XCTAssertFalse(plainEvents.contains(.activity(.phase(.searching))))
  }

  func testClaudeCodeRestartDeliversNothing() async throws {
    let root = try temporaryDirectory()
    let pidFile = root.appending(path: "pid")
    let inputLog = root.appending(path: "input")
    let initLine = #"{"type":"system","subtype":"init","tools":["WebSearch","mcp__enigma__lookup"]}"#
    let call = #"{"type":"control_request","request_id":"req-call","request":{"subtype":"mcp_message","server_name":"enigma","message":{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lookup","arguments":{"query":"x"}}}}}"#
    let client = try client(root: root, script: """
      #!/bin/sh
      echo $$ > '\(pidFile.path)'
      /usr/bin/printf '%s\\n' '\(initLine)'
      /usr/bin/printf '%s\\n' '\(call)'
      exec /bin/cat > '\(inputLog.path)'
      """)
    let toolbox = RestartingToolbox()
    do {
      _ = try await events(client.stream(searchRequest(), toolbox: toolbox))
      XCTFail("Expected a restart")
    } catch {
      XCTAssertEqual(error as? ProviderSearchRestart, ProviderSearchRestart())
    }
    XCTAssertEqual(toolbox.callCount, 1)
    let pid = try await waitForPID(at: pidFile)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotEqual(kill(pid, 0), 0, "Claude Code kept running after the restart")
    let written = try String(contentsOf: inputLog, encoding: .utf8)
    XCTAssertFalse(written.contains("req-call"), "The held-back call is never answered")
    XCTAssertFalse(written.contains("The request was restarted."))
    XCTAssertFalse(written.contains("control_response"))
  }

  func testClaudeCodeFailureAfterSearchKeepsSources() async throws {
    let root = try temporaryDirectory()
    let lines = [
      #"{"type":"system","subtype":"init","tools":["WebSearch","mcp__enigma__lookup"]}"#,
      #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"WebSearch","input":{}}}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-1","type":"tool_result","content":"…"}]},"tool_use_result":{"query":"q","results":[{"tool_use_id":"srvtoolu-1","content":[{"title":"Found","url":"https://example.com/found"}]},"Summary."]}}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partly "}}}"#,
      #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Overloaded"}"#,
    ]
    let client = try client(root: root, script: """
      #!/bin/sh
      \(lines.map { "/usr/bin/printf '%s\\n' '\($0)'" }.joined(separator: "\n"))
      exec /bin/sleep 10
      """)
    var received: [ChatEvent] = []
    do {
      for try await event in client.stream(searchRequest(), toolbox: RecordingToolbox()) { received.append(event) }
      XCTFail("Expected the failure")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeError, .server("Overloaded"))
    }
    let found = [WebSearchSource(title: "Found", url: URL(string: "https://example.com/found")!)]
    XCTAssertEqual(received, [
      .activity(.phase(.searching)), .activity(.sourcesDiscovered(found)), .token("Partly "),
      .activity(.sourcesSelected(found)),
    ])
  }

  /// Every search failed (CP0 Q4: the model chose domains it couldn't reach), but the answer still links
  /// pages: the failed search counts, so the links become sources.
  func testClaudeCodeFailedSearchStillSelectsAnswerLinks() async throws {
    let lines = [
      #"{"type":"system","subtype":"init","tools":["WebSearch","mcp__enigma__lookup"]}"#,
      #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"WebSearch","input":{}}}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu-1","type":"tool_result","content":"Error","is_error":true}]},"tool_use_result":"Error: API Error: 400"}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"See [Example](https://example.com/page)."}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"See [Example](https://example.com/page)."}"#,
    ]
    let client = try client(root: try temporaryDirectory(), script: """
      #!/bin/sh
      \(lines.map { "/usr/bin/printf '%s\\n' '\($0)'" }.joined(separator: "\n"))
      exec /bin/sleep 10
      """)
    let received = try await events(client.stream(searchRequest(), toolbox: RecordingToolbox()))
    XCTAssertEqual(received, [
      .activity(.phase(.searching)), .token("See [Example](https://example.com/page)."),
      .activity(.sourcesSelected([WebSearchSource(title: "example.com", url: URL(string: "https://example.com/page")!)])),
      .completed,
    ])
  }

  /// A CLI whose `init` has no tools list can't be checked; its text is released at the result, once.
  func testClaudeCodeTextWithoutInitToolsIsReleasedAtTheResult() async throws {
    let lines = [
      #"{"type":"system","subtype":"init","model":"claude"}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"there"}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Hello there"}"#,
    ]
    let client = try client(root: try temporaryDirectory(), script: """
      #!/bin/sh
      \(lines.map { "/usr/bin/printf '%s\\n' '\($0)'" }.joined(separator: "\n"))
      exec /bin/sleep 10
      """)
    let received = try await events(client.stream(searchRequest(), toolbox: RecordingToolbox()))
    XCTAssertEqual(received, [.token("Hello "), .token("there"), .completed])
  }

  private func searchRequest() -> ChatRequest {
    var request = request()
    request.providerSearch = ProviderSearch()
    return request
  }
}

/// A Messages-like tool whose result the gate held back from a provider-search request (F30).
private final class RestartingToolbox: AgentToolbox, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var callCount: Int { lock.withLock { count } }
  let instructions = "Use lookup for facts."
  let definitions = RecordingToolbox().definitions

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    lock.withLock { count += 1 }
    return AgentToolResult(text: "The request was restarted.", success: false, terminal: true, stop: .restart)
  }
}
