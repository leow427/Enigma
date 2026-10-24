import Foundation
import XCTest
@testable import Enigma

final class SubscriptionModelRefreshTests: XCTestCase {
  // MARK: Daily schedule

  func testFirstRunFollowsTheLaunchDelayAndTheNextComesTwentyFourHoursLater() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clock = FakeClock(now: start, sleepLimit: 1 + 144 + 1)
    await schedule(clock).run { clock.recordRun(); return true }
    XCTAssertEqual(clock.runs, [start.addingTimeInterval(120), start.addingTimeInterval(120 + 86_400)])
    XCTAssertEqual(clock.sleeps.first, 120)
    XCTAssertTrue(clock.sleeps.dropFirst().allSatisfy { $0 <= 600 }, "The due time is rechecked every ten minutes")
  }

  func testARunMissedDuringSleepHappensOnceAfterWake() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // The second sleep (the first after the launch run) spans three days of system sleep.
    let clock = FakeClock(now: start, sleepLimit: 20, jumps: [1: 3 * 86_400])
    await schedule(clock).run { clock.recordRun(); return true }
    let wake = start.addingTimeInterval(120 + 600 + 3 * 86_400)
    XCTAssertEqual(clock.runs, [start.addingTimeInterval(120), wake], "One run on wake, not one per missed day")
  }

  func testAClockSetBackDoesNotPostponeTheNextRunBeyondADay() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // After the launch run the clock moves back ten days.
    let clock = FakeClock(now: start, sleepLimit: 1 + 1 + 145, jumps: [1: -10 * 86_400])
    await schedule(clock).run { clock.recordRun(); return true }
    XCTAssertEqual(clock.runs.count, 2)
    XCTAssertLessThanOrEqual(clock.runs[1].timeIntervalSince(start.addingTimeInterval(120 + 600 - 10 * 86_400)), 86_400 + 600)
  }

  func testAFailedRunIsRetriedAfterAnHourNotInABurst() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Launch run fails, the retry an hour later succeeds, then a day passes.
    let clock = FakeClock(now: start, sleepLimit: 1 + 6 + 144 + 1)
    let outcomes = EventLog()
    await schedule(clock).run {
      clock.recordRun()
      let succeeded = clock.runs.count > 1
      outcomes.record("\(succeeded)")
      return succeeded
    }
    XCTAssertEqual(clock.runs, [start.addingTimeInterval(120), start.addingTimeInterval(120 + 3_600),
                                start.addingTimeInterval(120 + 3_600 + 86_400)])
    XCTAssertEqual(outcomes.events, ["false", "true", "true"])
  }

  // MARK: What a run does

  func testUnusedRoutesRunNothingAndUsedOnesRefresh() async {
    let log = EventLog()
    _ = await refresh(log, codexInstalled: false, claudeInstalled: false).run()
    XCTAssertEqual(log.events, [], "No CLI, no process and no network")

    _ = await refresh(log, codexInstalled: true, signedIn: false, claudeInstalled: true).run()
    XCTAssertEqual(log.events, ["local", "account", "maintain(false)", "refresh(claude-code)"],
                   "A signed-out ChatGPT gets no list refresh; Claude Code checks its own sign-in")

    log.clear()
    _ = await refresh(log, codexInstalled: true, signedIn: true, claudeInstalled: false).run()
    XCTAssertEqual(log.events, ["local", "account", "maintain(true)", "refresh(chatgpt-codex)"])
  }

  func testCodexIsNotStartedWithoutALocalSignOfChatGPT() async {
    let log = EventLog()
    let succeeded = await refresh(log, codexInstalled: true, mayUseChatGPT: false, signedIn: true, claudeInstalled: false).run()
    XCTAssertTrue(succeeded)
    XCTAssertEqual(log.events, ["local"], "No account/read, so no resident app server")
  }

  func testAFailedRefreshMakesTheRunFail() async {
    let log = EventLog()
    let failed = await refresh(log, codexInstalled: true, signedIn: true, refreshSucceeds: false, claudeInstalled: true).run()
    XCTAssertFalse(failed)
    XCTAssertEqual(log.events.last, "refresh(claude-code)", "Claude Code is still refreshed")
  }

  func testAnOldCodexStillStreamingIsNotAskedForTheListAndTheRunRetries() async {
    let log = EventLog()
    let succeeded = await refresh(log, codexInstalled: true, signedIn: true, installs: true, codexIsCurrent: false,
                                  claudeInstalled: false).run()
    XCTAssertFalse(succeeded, "Retried in an hour, once the new Codex runs")
    XCTAssertEqual(log.events, ["local", "account", "maintain(true)", "restart"], "No list from the old binary")
  }

  func testClaudeCodeIsNotRunWithoutALocalSignOfUse() async {
    let log = EventLog()
    let succeeded = await refresh(log, codexInstalled: false, claudeInstalled: true, mayUseClaudeCode: false).run()
    XCTAssertTrue(succeeded)
    XCTAssertEqual(log.events, [], "No auth status for someone who doesn't use Claude Code")
  }

  func testANewCodexRestartsTheAppServersBeforeTheListIsRefreshed() async {
    let log = EventLog()
    _ = await refresh(log, codexInstalled: true, signedIn: true, installs: true, claudeInstalled: false).run()
    XCTAssertEqual(log.events, ["local", "account", "maintain(true)", "restart", "refresh(chatgpt-codex)"])
  }

  @MainActor
  func testLocalSignsOfChatGPT() async throws {
    let root = try temporaryDirectory()
    let defaults = try temporaryDefaults()
    let transport = ListingCodexTransport()
    let client = CodexSubscriptionClient(transport: transport)
    let catalog = CloudModelCatalog(credentialStore: NoCredentials(), transport: NoNetwork(), cacheDirectory: root,
                                    codex: client, codexListedModels: CodexListedModels())
    let settings = CloudSettingsModel(credentialStore: NoCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: defaults), codex: client, codexAvailable: { true })
    var isPossible = await settings.mayUseChatGPT()
    XCTAssertFalse(isPossible, "The built-in default provider alone is not a sign")

    settings.preferredProvider = .openAI
    settings.preferredProvider = .chatGPT
    isPossible = await settings.mayUseChatGPT()
    XCTAssertTrue(isPossible, "Choosing ChatGPT is")

    let other = try temporaryDefaults()
    other.set("gpt-6-sol", forKey: "aiSpotlight.cloud.preferredModel.chatgpt-codex")
    other.set("openai", forKey: "aiSpotlight.cloud.preferredProvider")
    let chosen = CloudSettingsModel(credentialStore: NoCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: other), codex: client, codexAvailable: { true })
    isPossible = await chosen.mayUseChatGPT()
    XCTAssertTrue(isPossible, "So is a chosen ChatGPT model")

    let cachedOnly = try temporaryDefaults()
    cachedOnly.set("openai", forKey: "aiSpotlight.cloud.preferredProvider")
    let cached = CloudSettingsModel(credentialStore: NoCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: cachedOnly), codex: client, codexAvailable: { true })
    isPossible = await cached.mayUseChatGPT()
    XCTAssertFalse(isPossible)
    _ = try await catalog.models(for: .chatGPT, forceRefresh: true)
    isPossible = await cached.mayUseChatGPT()
    XCTAssertTrue(isPossible, "And a cached ChatGPT list")
  }

  @MainActor
  func testQuietRefreshUpdatesTheListAndKeepsTheCacheWhenItFails() async throws {
    let root = try temporaryDirectory()
    let transport = ListingCodexTransport()
    let client = CodexSubscriptionClient(transport: transport)
    let listed = CodexListedModels()
    let settings = CloudSettingsModel(
      credentialStore: NoCredentials(),
      catalog: CloudModelCatalog(credentialStore: NoCredentials(), transport: NoNetwork(), cacheDirectory: root,
                                 codex: client, codexListedModels: listed),
      preferences: CloudPreferencesStore(defaults: try temporaryDefaults()), codex: client, codexAvailable: { true })
    settings.preferredProvider = .chatGPT

    var succeeded = await settings.refreshModelsQuietly(for: .chatGPT)
    XCTAssertTrue(succeeded)
    XCTAssertEqual(settings.models.map(\.id), ["gpt-6-sol", "gpt-6-luna"])
    XCTAssertEqual(settings.preferredModelID, "gpt-6-luna", "Codex's default, not the first listed")
    XCTAssertEqual(listed.models.map(\.id), ["gpt-6-sol", "gpt-6-luna"])
    let cache = root.appending(path: "cloud-models.json")
    let cached = try Data(contentsOf: cache)

    await transport.setFails(true)
    succeeded = await settings.refreshModelsQuietly(for: .chatGPT)
    XCTAssertFalse(succeeded, "Retried sooner")
    XCTAssertEqual(settings.models.map(\.id), ["gpt-6-sol", "gpt-6-luna"], "The shown list stays")
    XCTAssertNil(settings.discoveryError, "Background failures are silent")
    XCTAssertEqual(try Data(contentsOf: cache), cached, "The cached list stays")
    XCTAssertEqual(listed.models.map(\.id), ["gpt-6-sol", "gpt-6-luna"])

    await transport.setSignedIn(false)
    succeeded = await settings.refreshModelsQuietly(for: .chatGPT)
    XCTAssertTrue(succeeded, "Signed out leaves nothing to refresh, which is not a failure")
  }

  @MainActor
  func testClaudeCodeRefreshNeverReplacesTheShownChatGPTList() async throws {
    let root = try temporaryDirectory()
    let claude = try claudeCode(in: root, status: #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#)
    let settings = try settingsModel(root: root, claudeCode: claude)
    _ = await settings.refreshModelsQuietly(for: .chatGPT)
    let shown = settings.models, model = settings.preferredModelID

    var isPossible = await settings.mayUseClaudeCode()
    XCTAssertFalse(isPossible, "Nothing yet says this person uses Claude Code")
    let succeeded = await settings.refreshModelsQuietly(for: .claudeCode)
    XCTAssertTrue(succeeded)
    XCTAssertEqual(settings.models, shown, "Another route's refresh leaves the ChatGPT list alone")
    XCTAssertEqual(settings.preferredModelID, model)
    isPossible = await settings.mayUseClaudeCode()
    XCTAssertTrue(isPossible, "A cached Claude Code list is a sign of use")
  }

  @MainActor
  func testClaudeCodeSignsOfUseAndAnUnexpectedStatusIsNotRetriedHourly() async throws {
    let root = try temporaryDirectory()
    let claude = try claudeCode(in: root, status: "Usage: claude [options]", exitStatus: 1)
    let settings = try settingsModel(root: root, claudeCode: claude)
    var isPossible = await settings.mayUseClaudeCode()
    XCTAssertFalse(isPossible)
    settings.preferredProvider = .claudeCode
    isPossible = await settings.mayUseClaudeCode()
    XCTAssertTrue(isPossible, "Choosing Claude Code is a sign of use")
    let succeeded = await settings.refreshModelsQuietly(for: .claudeCode)
    XCTAssertTrue(succeeded, "Output that isn't auth status JSON won't improve in an hour")
  }

  // MARK: Codex runtime

  func testOlderSystemCodexIsReplacedOnlyForPeopleWhoUseChatGPT() async throws {
    let installs = try temporaryDirectory().appending(path: "Codex Runtime")
    let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    let asked = EventLog(), installed = EventLog()

    func maintain(usesChatGPT: Bool, version: [Int]?, signed: Bool = true, defaults: UserDefaults, now: Date = Date())
      async -> (step: CodexRuntime.DailyStep, installed: Bool) {
      await CodexRuntime.maintainDaily(
        in: installs, defaults: defaults, now: now, usesChatGPT: usesChatGPT, systemExecutable: homebrew,
        systemVersion: { asked.record($0.path); return version },
        systemSignedByOpenAI: { asked.record("signature \($0.path)"); return signed },
        upgrade: { installed.record($0.path) })
    }

    let older = await maintain(usesChatGPT: true, version: [0, 153, 4], defaults: try temporaryDefaults())
    XCTAssertEqual(older.step, .replaceOlderSystemCodex)
    XCTAssertTrue(older.installed)
    XCTAssertEqual(asked.events, [homebrew.path, "signature \(homebrew.path)"],
                   "The version and signature come from the Codex Enigma would use")
    XCTAssertEqual(installed.events, [installs.path])

    installed.clear()
    let unsigned = await maintain(usesChatGPT: true, version: [0, 153, 4], signed: false, defaults: try temporaryDefaults())
    XCTAssertEqual(unsigned.step, .nothing, "Without OpenAI's signature the Keychain sign-in might prompt")
    asked.clear()
    for version in [[0, 164, 0], [0, 165, 0], [1, 0]] {
      let result = await maintain(usesChatGPT: true, version: version, defaults: try temporaryDefaults())
      XCTAssertEqual(result.step, .nothing, "\(version) is not older than the pin")
    }
    XCTAssertFalse(asked.events.contains { $0.hasPrefix("signature") }, "The signature is checked only for an older Codex")
    let unknown = await maintain(usesChatGPT: true, version: nil, defaults: try temporaryDefaults())
    XCTAssertEqual(unknown.step, .nothing, "An unreadable version is left alone")
    XCTAssertEqual(installed.events, [])

    asked.clear()
    let notUsed = await maintain(usesChatGPT: false, version: [0, 1, 0], defaults: try temporaryDefaults())
    XCTAssertEqual(notUsed.step, .nothing)
    XCTAssertEqual(asked.events, [], "Nobody else's Codex is even asked")
    XCTAssertEqual(installed.events, [])
  }

  func testAFailedInstallOverTheSystemCodexWaitsADay() async throws {
    let installs = try temporaryDirectory().appending(path: "Codex Runtime")
    let defaults = try temporaryDefaults()
    let attempts = EventLog()
    let now = Date()
    let failing: @Sendable (URL) async throws -> Void = { _ in
      attempts.record("install")
      throw URLError(.notConnectedToInternet)
    }
    let first = await CodexRuntime.maintainDaily(in: installs, defaults: defaults, now: now, usesChatGPT: true,
      systemExecutable: URL(fileURLWithPath: "/usr/local/bin/codex"), systemVersion: { _ in [0, 153, 4] }, systemSignedByOpenAI: { _ in true }, upgrade: failing)
    XCTAssertEqual(first.step, .replaceOlderSystemCodex)
    XCTAssertFalse(first.installed)
    _ = await CodexRuntime.maintainDaily(in: installs, defaults: defaults, now: now.addingTimeInterval(3_600), usesChatGPT: true,
      systemExecutable: URL(fileURLWithPath: "/usr/local/bin/codex"), systemVersion: { _ in [0, 153, 4] }, systemSignedByOpenAI: { _ in true }, upgrade: failing)
    XCTAssertEqual(attempts.events.count, 1, "Not again within a day")
    XCTAssertEqual(defaults.string(forKey: "aiSpotlight.codexRuntime.lastFailedUpgradeVersion"), CodexRuntime.version)
    _ = await CodexRuntime.maintainDaily(in: installs, defaults: defaults, now: now.addingTimeInterval(25 * 3_600), usesChatGPT: true,
      systemExecutable: URL(fileURLWithPath: "/usr/local/bin/codex"), systemVersion: { _ in [0, 153, 4] }, systemSignedByOpenAI: { _ in true }, upgrade: failing)
    XCTAssertEqual(attempts.events.count, 2)
  }

  func testADailyInstallWaitsForAQuietInstallAlreadyRunning() async throws {
    let installs = try temporaryDirectory().appending(path: "Codex Runtime")
    let defaults = try temporaryDefaults()
    XCTAssertTrue(CodexRuntime.quietInstall.begin(), "The launch upgrade is downloading")
    let skipped = await CodexRuntime.maintainDaily(in: installs, defaults: defaults, usesChatGPT: true,
      systemExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), systemVersion: { _ in [0, 153, 4] },
      systemSignedByOpenAI: { _ in true }, upgrade: { _ in XCTFail("Only one quiet install at a time") })
    CodexRuntime.quietInstall.end()
    XCTAssertEqual(skipped.step, .replaceOlderSystemCodex)
    XCTAssertFalse(skipped.installed)
    XCTAssertNil(defaults.string(forKey: "aiSpotlight.codexRuntime.lastFailedUpgradeVersion"), "Skipping is not a failure")
  }

  func testBuiltInCodexStepsTakePrecedenceOverTheSystemCodex() async throws {
    let installs = try temporaryDirectory().appending(path: "Codex Runtime")
    _ = try executable(at: installs.appending(path: "codex-0.100.0/bin/codex"))
    let upgrade = await CodexRuntime.maintainDaily(in: installs, defaults: try temporaryDefaults(), usesChatGPT: false,
      systemExecutable: nil, systemVersion: { _ in XCTFail("Not asked"); return nil }, upgrade: { _ in })
    XCTAssertEqual(upgrade.step, .upgrade, "The launch upgrade is retried daily")

    _ = try executable(at: installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex"))
    let current = await CodexRuntime.maintainDaily(in: installs, defaults: try temporaryDefaults(), usesChatGPT: true,
      systemExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), systemVersion: { _ in [0, 1, 0] },
      upgrade: { _ in XCTFail("Already installed") })
    XCTAssertEqual(current.step, .nothing)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installs.appending(path: "codex-0.100.0").path),
                  "The daily check never cleans up; a running app server may use the folder")
  }

  func testSystemCodexExcludesTheOverrideAndBuiltInCopies() {
    let runtime = URL(fileURLWithPath: "/tmp/Codex Runtime", isDirectory: true)
    let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    XCTAssertEqual(CodexRuntime.systemExecutable(environment: [:], runtimeDirectory: runtime, resolved: homebrew), homebrew)
    XCTAssertNil(CodexRuntime.systemExecutable(environment: ["AI_SPOTLIGHT_CODEX_PATH": homebrew.path],
                                               runtimeDirectory: runtime, resolved: homebrew))
    XCTAssertNil(CodexRuntime.systemExecutable(environment: [:], runtimeDirectory: runtime,
                                               resolved: runtime.appending(path: "codex-0.100.0/bin/codex")))
    XCTAssertNil(CodexRuntime.systemExecutable(environment: [:], runtimeDirectory: runtime, resolved: nil))
  }

  func testNpmCodexIsJudgedByTheNativeBinaryItRuns() throws {
    let root = try temporaryDirectory()
    let package = root.appending(path: "lib/node_modules/@openai/codex")
    let script = try executable(at: package.appending(path: "bin/codex.js"), script: "#!/usr/bin/env node\n")
    #if arch(arm64)
    let platform = "codex-darwin-arm64"
    #else
    let platform = "codex-darwin-x64"
    #endif
    let native = try executable(at: package.appending(
      path: "node_modules/@openai/\(platform)/vendor/\(CodexRuntime.target)/bin/codex"))
    let link = root.appending(path: "bin/codex")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    XCTAssertEqual(CodexRuntime.nativeExecutable(for: link).resolvingSymlinksInPath().path,
                   native.resolvingSymlinksInPath().path)
    let plain = try executable(at: root.appending(path: "other/codex"))
    XCTAssertEqual(CodexRuntime.nativeExecutable(for: plain).path, plain.resolvingSymlinksInPath().path)
    XCTAssertFalse(CodexRuntime.isSignedByOpenAI(native), "An unsigned file is not OpenAI's")
    XCTAssertFalse(CodexRuntime.isSignedByOpenAI(URL(fileURLWithPath: "/bin/ls")), "Nor is Apple's")
    XCTAssertEqual(CodexRuntime.keychainRequirement,
                   #"identifier "codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#,
                   "The identifier and team the Keychain item's access is tied to")
  }

  func testVersionOutputIsParsed() async throws {
    XCTAssertEqual(CodexRuntime.versionNumbers(fromVersionOutput: "codex-cli 0.153.4\n"), [0, 153, 4])
    XCTAssertEqual(CodexRuntime.versionNumbers(fromVersionOutput: "codex-cli 0.165.0-alpha.1"), [0, 165, 0])
    XCTAssertNil(CodexRuntime.versionNumbers(fromVersionOutput: "codex-cli"))
    XCTAssertNil(CodexRuntime.versionNumbers(fromVersionOutput: ""))
    XCTAssertNil(CodexRuntime.versionNumbers(fromVersionOutput: "node v22.1.0"), "Only the codex-cli line counts")
    XCTAssertEqual(CodexRuntime.versionNumbers(fromVersionOutput: "codex-cli 0.153.4\nWARNING: config 9.9.9 ignored\n"),
                   [0, 153, 4])
    XCTAssertEqual(CodexRuntime.versionNumbers(fromVersionOutput: "WARNING: proxy 1.2.3 unset\ncodex-cli 0.153.4\n"),
                   [0, 153, 4])
    // Standard error is merged with the output; a stray number there must not win.
    let fake = try executable(at: try temporaryDirectory().appending(path: "codex"), script: """
      #!/bin/sh
      [ "$1" = --version ] || exit 1
      echo 'codex-cli 0.153.4'
      echo 'WARNING: plugin 9.9.9 is deprecated' >&2
      """)
    let version = await CodexRuntime.reportedVersion(of: fake)
    XCTAssertEqual(version, [0, 153, 4])
  }

  func testAppServerSwitchesToANewCodexOnlyWhenIdle() async throws {
    let root = try temporaryDirectory()
    let launches = root.appending(path: "launches")
    let fake = try executable(at: root.appending(path: "codex"), script: """
      #!/bin/sh
      echo launch >> '\(launches.path)'
      while IFS= read -r line; do
        id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"account/read"'*) /usr/bin/printf '{"id":%s,"result":{"account":null}}\\n' "$id" ;;
        esac
      done
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(5))
    addTeardownBlock { await server.disconnect() }
    func launchCount() throws -> Int {
      try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count
    }

    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 1)
    await server.restartWhenIdle()
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 2, "Idle: the next request starts the new Codex")

    let streaming = try await server.notifications()
    await server.restartWhenIdle()
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 2, "A reply is streaming, so the process stays")
    await streaming.cancel()
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 3, "Once nothing is in flight, it switches")
  }

  func testAppServerWaitsForUnansweredRequestsAndFileHandlersBeforeSwitching() async throws {
    let root = try temporaryDirectory()
    let launches = root.appending(path: "launches")
    let received = root.appending(path: "received")
    let fake = try executable(at: root.appending(path: "codex"), script: """
      #!/bin/sh
      echo launch >> '\(launches.path)'
      while IFS= read -r line; do
        id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*) /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"account/read"'*) /usr/bin/printf '{"id":%s,"result":{"account":null}}\\n' "$id" ;;
          *'"method":"unanswered"'*) echo got > '\(received.path)' ;;
        esac
      done
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(30))
    addTeardownBlock { await server.disconnect() }
    func launchCount() throws -> Int {
      try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count
    }

    let hanging = Task { _ = try? await server.request("unanswered", params: .object([:])) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: received.path) {
      guard ContinuousClock.now < deadline else { return XCTFail("The fake Codex never received the request") }
      try await Task.sleep(for: .milliseconds(10))
    }
    await server.restartWhenIdle()
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 1, "A request is still waiting for its answer")
    hanging.cancel()
    await hanging.value
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 2)

    // Through the protocol, as File Mode calls it (the extension's default would win otherwise).
    let transport: any CodexRPCTransport = server
    try await transport.setFileHandler(threadID: "thread-one") { _, _ in .null }
    await server.restartWhenIdle()
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 2, "A File Mode thread still has its handler")
    try await transport.setFileHandler(threadID: "thread-one", handler: nil)
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try launchCount(), 3)
  }

  func testAppServerSwitchesWhenTheLookupFindsANewCodex() async throws {
    let root = try temporaryDirectory()
    let launches = root.appending(path: "launches")
    let old = try fakeCodex(at: root.appending(path: "old/codex"), name: "old", log: launches)
    let new = try fakeCodex(at: root.appending(path: "new/codex"), name: "new", log: launches)
    let found = Locked(old)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { found.value }, requestTimeout: .seconds(10))
    addTeardownBlock { await server.disconnect() }

    _ = try await server.request("account/read", params: .object([:]))
    let streaming = try await server.notifications()
    found.value = new  // For example, the launch upgrade finished installing the pinned Codex.
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try lines(launches), ["old"], "A reply is streaming on the old Codex")
    var isCurrent = await server.usesCurrentExecutable()
    XCTAssertFalse(isCurrent)
    await streaming.cancel()
    isCurrent = await server.usesCurrentExecutable()
    XCTAssertTrue(isCurrent)
    _ = try await server.request("account/read", params: .object([:]))
    XCTAssertEqual(try lines(launches), ["old", "new"], "Idle again, so the next request starts the new Codex")
  }

  func testARestartRequestedDuringStartupWaitsAndBothRequestsSucceed() async throws {
    let root = try temporaryDirectory()
    let launches = root.appending(path: "launches")
    let fake = try fakeCodex(at: root.appending(path: "codex"), name: "codex", log: launches, initializeDelay: "0.5")
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(10))
    addTeardownBlock { await server.disconnect() }
    let first = Task { try await server.request("account/read", params: .object([:])) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (try? lines(launches))?.isEmpty != false {
      guard ContinuousClock.now < deadline else { return XCTFail("The fake Codex never started") }
      try await Task.sleep(for: .milliseconds(10))
    }
    await server.restartWhenIdle()
    let second = try await server.request("account/read", params: .object([:]))
    let firstResult = try await first.value
    XCTAssertEqual(firstResult, .object(["account": .null]))
    XCTAssertEqual(second, .object(["account": .null]))
    XCTAssertEqual(try lines(launches), ["codex"], "The starting process is not closed under its requests")
  }

  func testAppServerSurvivesACodexThatExitsWhileARequestIsWritten() async throws {
    let root = try temporaryDirectory()
    let fake = try executable(at: root.appending(path: "codex"), script: """
      #!/bin/sh
      IFS= read -r line
      id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id"
      /usr/bin/head -c 1000 > /dev/null
      exit 0
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(10))
    addTeardownBlock { await server.disconnect() }
    // Larger than the pipe buffer, so the write is still blocked when the server exits.
    let large = CodexValue.object(["text": .string(String(repeating: "x", count: 1_000_000))])
    do {
      _ = try await server.request("large", params: large)
      XCTFail("The request can't succeed")
    } catch {
      XCTAssertEqual(error as? CodexError, .disconnected, "Not a file-saving error: \(error)")
    }
  }

  func testACodexThatStopsReadingCannotBlockTimeoutsOrDisconnect() async throws {
    let root = try temporaryDirectory()
    let fake = try executable(at: root.appending(path: "codex"), script: """
      #!/bin/sh
      IFS= read -r line
      id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id"
      exec /bin/sleep 30
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(1))
    let large = CodexValue.object(["text": .string(String(repeating: "x", count: 1_000_000))])
    let started = ContinuousClock.now
    do {
      _ = try await server.request("large", params: large)
      XCTFail("Nothing answers")
    } catch {
      XCTAssertEqual(error as? CodexError, .timedOut, "The timeout still runs while the write is stuck")
    }
    await server.disconnect()
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "Neither the timeout nor disconnect waited on the pipe")
  }

  func testACodexThatClosesItsInputDisconnectsInsteadOfTimingOut() async throws {
    let root = try temporaryDirectory()
    let fake = try executable(at: root.appending(path: "codex"), script: """
      #!/bin/sh
      reply() {
        id=$(/usr/bin/printf '%s' "$1" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        /usr/bin/printf '{"id":%s,"result":%s}\\n' "$id" "$2"
      }
      IFS= read -r line; reply "$line" '{}'
      IFS= read -r line
      IFS= read -r line; reply "$line" '{"account":null}'
      exec 0<&-
      exec /bin/sleep 30
      """)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")),
                                executable: { fake }, requestTimeout: .seconds(5))
    addTeardownBlock { await server.disconnect() }
    _ = try await server.request("account/read", params: .object([:]))
    try await Task.sleep(for: .milliseconds(500))
    let started = ContinuousClock.now
    do {
      _ = try await server.request("account/read", params: .object([:]))
      XCTFail("Codex no longer reads its input")
    } catch {
      XCTAssertEqual(error as? CodexError, .disconnected, "The failed write closes the connection: \(error)")
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), "Not left to time out")
  }

  func testFileModeChecksANewCodexAgain() async throws {
    let root = try temporaryDirectory()
    let probes = root.appending(path: "probes")
    func schemaCodex(_ name: String) throws -> URL {
      try executable(at: root.appending(path: "\(name)/codex"), script: """
        #!/bin/sh
        echo '\(name)' >> '\(probes.path)'
        /bin/mkdir -p "$4/v2"
        /usr/bin/printf '%s' '{"properties":{"environments":{"description":"Empty disables environment access"},"dynamicTools":{}},"definitions":{"DynamicToolSpec":{}}}' > "$4/v2/ThreadStartParams.json"
        /usr/bin/printf '%s' '{"required":["arguments","callId","threadId","tool","turnId"],"properties":{"callId":{"type":"string"},"threadId":{"type":"string"},"tool":{"type":"string"},"turnId":{"type":"string"}}}' > "$4/DynamicToolCallParams.json"
        """)
    }
    let old = try schemaCodex("old"), new = try schemaCodex("new")
    let found = Locked(old)
    let server = CodexAppServer(configuration: .init(directory: root.appending(path: "runtime")), executable: { found.value })
    try await server.prepareFileMode()
    try await server.prepareFileMode()
    XCTAssertEqual(try lines(probes), ["old"], "Checked once per binary")
    found.value = new
    try await server.prepareFileMode()
    XCTAssertEqual(try lines(probes), ["old", "new"], "A different Codex is checked again")
  }

  @MainActor
  func testASignOutDuringARefreshIsNotUndone() async throws {
    let root = try temporaryDirectory()
    let transport = GatedCodexTransport(lists: [["gpt-6-sol"]], holdFirst: true)
    let listed = CodexListedModels()
    let client = CodexSubscriptionClient(transport: transport)
    let catalog = CloudModelCatalog(credentialStore: NoCredentials(), transport: NoNetwork(), cacheDirectory: root,
                                    codex: client, codexListedModels: listed)
    let settings = CloudSettingsModel(credentialStore: NoCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: try temporaryDefaults()), codex: client, codexAvailable: { true })
    let refresh = Task { await settings.refreshModelsQuietly(for: .chatGPT) }
    try await Self.waitForListCalls(1, on: transport)
    await settings.signOutOfChatGPT()
    await transport.release()
    _ = await refresh.value
    let cached = await catalog.hasCachedModels(for: .chatGPT)
    XCTAssertFalse(cached, "The stale list isn't saved after sign-out")
    XCTAssertEqual(listed.models, [], "Nor shared")
    XCTAssertEqual(settings.models, [], "Nor shown")
  }

  func testAnOlderRefreshFinishingLastDoesNotReplaceANewerList() async throws {
    let root = try temporaryDirectory()
    let transport = GatedCodexTransport(lists: [["old-model"], ["new-model"]], holdFirst: true)
    let catalog = CloudModelCatalog(credentialStore: NoCredentials(), transport: NoNetwork(), cacheDirectory: root,
                                    codex: CodexSubscriptionClient(transport: transport), codexListedModels: CodexListedModels())
    let older = Task { try await catalog.models(for: .chatGPT, forceRefresh: true) }
    try await Self.waitForListCalls(1, on: transport)
    let newer = try await catalog.models(for: .chatGPT, forceRefresh: true)
    XCTAssertEqual(newer.map(\.id), ["new-model"])
    await transport.release()
    _ = try await older.value
    let cached = await catalog.cachedModels(for: .chatGPT)
    XCTAssertEqual(cached?.map(\.id), ["new-model"])
  }

  // MARK: Helpers

  private func schedule(_ clock: FakeClock) -> DailySchedule {
    DailySchedule(initialDelay: 120, interval: 86_400, checkInterval: 600,
                  now: { clock.now }, sleep: { try clock.sleep($0) })
  }

  private func refresh(_ log: EventLog, codexInstalled: Bool, mayUseChatGPT: Bool = true, signedIn: Bool = false,
                       installs: Bool = false, codexIsCurrent: Bool = true, refreshSucceeds: Bool = true,
                       claudeInstalled: Bool, mayUseClaudeCode: Bool = true) -> SubscriptionModelRefresh {
    SubscriptionModelRefresh(
      codexIsInstalled: { codexInstalled },
      mayUseChatGPT: { log.record("local"); return mayUseChatGPT },
      codexIsSignedIn: { log.record("account"); return signedIn },
      maintainCodex: { log.record("maintain(\($0))"); return installs },
      restartCodexWhenIdle: { log.record("restart") },
      codexIsCurrent: { codexIsCurrent },
      claudeCodeIsInstalled: { claudeInstalled },
      mayUseClaudeCode: { mayUseClaudeCode },
      refreshModels: { log.record("refresh(\($0.rawValue))"); return refreshSucceeds })
  }

  @MainActor
  private func settingsModel(root: URL, claudeCode: ClaudeCodeSubscriptionClient) throws -> CloudSettingsModel {
    let client = CodexSubscriptionClient(transport: ListingCodexTransport())
    let catalog = CloudModelCatalog(credentialStore: NoCredentials(), transport: NoNetwork(), cacheDirectory: root,
                                    codex: client, claudeCode: claudeCode, codexListedModels: CodexListedModels())
    return CloudSettingsModel(credentialStore: NoCredentials(), catalog: catalog,
      preferences: CloudPreferencesStore(defaults: try temporaryDefaults()), codex: client, codexAvailable: { true },
      claudeCode: claudeCode)
  }

  private func claudeCode(in root: URL, status: String, exitStatus: Int = 0) throws -> ClaudeCodeSubscriptionClient {
    let script = try executable(at: root.appending(path: "claude"), script: """
      #!/bin/sh
      /usr/bin/printf '%s\\n' '\(status)'
      exit \(exitStatus)
      """)
    return ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root.appending(path: "claude-runtime"),
                                                                    executable: { script }), statusTimeout: .seconds(10))
  }

  private func fakeCodex(at url: URL, name: String, log: URL, initializeDelay: String = "0") throws -> URL {
    try executable(at: url, script: """
      #!/bin/sh
      echo '\(name)' >> '\(log.path)'
      while IFS= read -r line; do
        id=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*) /bin/sleep \(initializeDelay); /usr/bin/printf '{"id":%s,"result":{}}\\n' "$id" ;;
          *'"method":"account/read"'*) /usr/bin/printf '{"id":%s,"result":{"account":null}}\\n' "$id" ;;
        esac
      done
      """)
  }

  private static func waitForListCalls(_ count: Int, on transport: GatedCodexTransport) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await transport.listCalls < count {
      guard ContinuousClock.now < deadline else { throw CodexError.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SubscriptionRefresh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func temporaryDefaults() throws -> UserDefaults {
    let suite = "SubscriptionRefresh-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    return defaults
  }

  private func executable(at url: URL, script: String = "#!/bin/sh\nexit 0\n") throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}

/// A wall clock that each sleep advances; `jumps` adds time to the sleep with that index
/// (system sleep, or a clock change), and the loop ends after `sleepLimit` sleeps.
private final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private let sleepLimit: Int
  private let jumps: [Int: TimeInterval]
  private var recordedSleeps: [TimeInterval] = []
  private var recordedRuns: [Date] = []

  init(now: Date, sleepLimit: Int, jumps: [Int: TimeInterval] = [:]) {
    current = now
    self.sleepLimit = sleepLimit
    self.jumps = jumps
  }

  var now: Date { lock.withLock { current } }
  var sleeps: [TimeInterval] { lock.withLock { recordedSleeps } }
  var runs: [Date] { lock.withLock { recordedRuns } }

  func sleep(_ duration: TimeInterval) throws {
    try lock.withLock {
      guard recordedSleeps.count < sleepLimit else { throw CancellationError() }
      current = current.addingTimeInterval(duration + (jumps[recordedSleeps.count] ?? 0))
      recordedSleeps.append(duration)
    }
  }

  func recordRun() { lock.withLock { recordedRuns.append(current) } }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var events: [String] { lock.withLock { recorded } }
  func record(_ event: String) { lock.withLock { recorded.append(event) } }
  func clear() { lock.withLock { recorded.removeAll() } }
}

private actor ListingCodexTransport: CodexRPCTransport {
  private var fails = false
  private var signedIn = true

  func setFails(_ fails: Bool) { self.fails = fails }
  func setSignedIn(_ signedIn: Bool) { self.signedIn = signedIn }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    switch method {
    case "account/read":
      guard signedIn else { return .object(["account": .null]) }
      return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "model/list":
      if fails { throw CodexError.disconnected }
      return .object(["data": .array([
        .object(["model": .string("gpt-6-sol"), "displayName": .string("GPT-6 Sol"), "hidden": .bool(false),
                 "isDefault": .bool(false), "inputModalities": .array([.string("text"), .string("image")])]),
        .object(["model": .string("gpt-6-luna"), "displayName": .string("GPT-6 Luna"), "hidden": .bool(false),
                 "isDefault": .bool(true), "inputModalities": .array([.string("text"), .string("image")])]),
      ]), "nextCursor": .null])
    default:
      XCTFail("The refresh must not start a model turn: \(method)")
      throw CodexError.invalidResponse
    }
  }

  func notifications() async throws -> CodexNotificationSubscription {
    XCTFail("The refresh needs no notifications")
    throw CodexError.invalidResponse
  }
}

/// Lists `lists[n]` for the nth `model/list`; the first waits for `release()` when held.
private actor GatedCodexTransport: CodexRPCTransport {
  private let lists: [[String]]
  private let holdFirst: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var listCalls = 0

  init(lists: [[String]], holdFirst: Bool) {
    self.lists = lists
    self.holdFirst = holdFirst
  }

  func release() {
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    switch method {
    case "account/read":
      return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "account/logout":
      return .object([:])
    case "model/list":
      let index = listCalls
      listCalls += 1
      if index == 0, holdFirst { await withCheckedContinuation { waiters.append($0) } }
      let ids = lists[min(index, lists.count - 1)]
      return .object(["data": .array(ids.map {
        .object(["model": .string($0), "displayName": .string($0), "hidden": .bool(false)])
      }), "nextCursor": .null])
    default:
      throw CodexError.invalidResponse
    }
  }

  func notifications() async throws -> CodexNotificationSubscription { throw CodexError.invalidResponse }
}

private struct NoCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? {
    XCTFail("The subscription refresh never reads the Keychain")
    return nil
  }
  func containsAPIKey(for provider: CloudProviderID) throws -> Bool { false }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private struct NoNetwork: CloudNetworkTransport {
  func data(for request: URLRequest) async throws -> CloudDataResponse {
    XCTFail("Subscription lists never use the API transport")
    throw CodexError.invalidResponse
  }
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    XCTFail("Subscription lists never use the API transport")
    return AsyncThrowingStream { $0.finish(throwing: CodexError.invalidResponse) }
  }
}
