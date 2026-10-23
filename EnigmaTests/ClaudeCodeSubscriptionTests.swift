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
    XCTAssertTrue(CloudModelCapabilities.visionModelIDs(for: .claudeCode).isEmpty)
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
