import Foundation
import XCTest
@testable import Enigma

final class FreeModelsTests: XCTestCase {
  // synthetic until Task 7 captures a real body
  private let perDay = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"3600s"}]}}"#
  private var perMinute: String {
    perDay.replacingOccurrences(of: "PerDay", with: "PerMinute").replacingOccurrences(of: "3600s", with: "21s")
  }
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Task 1: usage errors

  func testPerDayQuotaIsExhaustedWithResetTime() {
    XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data(perDay.utf8), now: now),
                   .quotaExhausted(.gemini, resetsAt: now.addingTimeInterval(3600)))
  }

  func testPerMinuteQuotaStaysRateLimited() {
    XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data(perMinute.utf8), now: now),
                   .rateLimited(.gemini))
  }

  func testUnparsable429StaysRateLimited() {
    XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data("<html>".utf8), now: now),
                   .rateLimited(.gemini))
  }

  func testQuotaExhaustedMessageNamesResetTime() {
    let message = CloudProviderError.quotaExhausted(.gemini, resetsAt: now).errorDescription!
    XCTAssertTrue(message.contains(now.formatted(date: .omitted, time: .shortened)), message)
  }

  // MARK: - Task 2: notice

  func testNoticeIsKeptOnTheActivity() {
    var activity = AssistantActivity(id: UUID())
    activity.apply(.notice("Switched to Apple's cloud model"))
    activity.apply(.phase(.generating))
    XCTAssertEqual(activity.notice, "Switched to Apple's cloud model")
  }

  func testNoticeArrivingAfterTheReplyEndedIsStillShown() {
    var activity = AssistantActivity(id: UUID())
    activity.apply(.phase(.completed))
    activity.apply(.notice("Answered on this Mac."))
    XCTAssertEqual(activity.notice, "Answered on this Mac.")
  }

  // MARK: - Task 3: the Free models provider

  func testRankingAndAvailability() {
    XCTAssertEqual(FreeModelCatalog.ranked, ["gemini-2.5-pro", "apple-pcc", "gemini-2.5-flash", "gemini-2.5-flash-lite"])
    XCTAssertEqual(FreeModelCatalog.available(hasGeminiKey: true, appleAvailable: false).map(\.id),
                   ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"])
    XCTAssertEqual(FreeModelCatalog.available(hasGeminiKey: false, appleAvailable: true).map(\.id), ["apple-pcc"])
    XCTAssertTrue(FreeModelCatalog.available(hasGeminiKey: true, appleAvailable: true).allSatisfy { $0.provider == .free })
  }

  func testExhaustionExpiresAtResetTime() {
    let usage = FreeModelUsage()
    usage.markExhausted("gemini-2.5-pro", until: now.addingTimeInterval(60))
    XCTAssertTrue(usage.isExhausted("gemini-2.5-pro", now: now))
    XCTAssertFalse(usage.isExhausted("gemini-2.5-pro", now: now.addingTimeInterval(61)))
    XCTAssertFalse(usage.isExhausted("gemini-2.5-flash", now: now))
  }

  func testExhaustionWithoutResetTimeLastsAnHour() {
    let usage = FreeModelUsage()
    usage.markExhausted("apple-pcc", until: nil, now: now)
    XCTAssertTrue(usage.isExhausted("apple-pcc", now: now.addingTimeInterval(3_599)))
    XCTAssertFalse(usage.isExhausted("apple-pcc", now: now.addingTimeInterval(3_601)))
  }

  func testFreeDefersToTheUnderlyingModel() {
    XCTAssertEqual(FreeModelCatalog.underlyingProvider("gemini-2.5-flash"), .gemini)
    XCTAssertNil(FreeModelCatalog.underlyingProvider("apple-pcc"))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .free, modelID: "gemini-2.5-flash"))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .free, modelID: "apple-pcc"))
    XCTAssertEqual(ToolDestination(route: Route(mode: .cloud, providerID: "free", modelID: "apple-pcc", usesNetwork: true)), .apple)
    XCTAssertEqual(ToolDestination(route: Route(mode: .cloud, providerID: "free", modelID: "gemini-2.5-pro", usesNetwork: true)), .google)
    XCTAssertEqual(CloudProviderID.free.displayName, "Free models")
  }

  @MainActor
  func testFreeAccessFollowsTheGeminiKey() throws {
    let credentials = MemoryCredentials()
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "FreeModels-\(UUID())")),
      preferences: CloudPreferencesStore(defaults: UserDefaults(suiteName: "FreeModels-\(UUID())")!), codexAvailable: { false })
    XCTAssertFalse(settings.hasCloudAccess(for: .free))
    try settings.saveAPIKey("test-only-key", for: .gemini)
    XCTAssertTrue(settings.hasCloudAccess(for: .free))
    try settings.removeAPIKey(for: .gemini)
    XCTAssertFalse(settings.hasCloudAccess(for: .free))
  }

  // MARK: - Task 4: fallback in the pool

  private let ranked = ["gemini-2.5-pro", "apple-pcc", "gemini-2.5-flash"]

  private func pool(_ fake: ScriptedFreeProvider, usage: FreeModelUsage, models: [String]? = nil,
                    allowsGeminiInAuto: Bool = false, switches: SwitchLog = SwitchLog()) -> FreeModelPool {
    let models = models ?? ranked
    return FreeModelPool(gemini: fake, apple: fake, usage: usage, models: { models },
                         allowsGeminiInAuto: { allowsGeminiInAuto }, onSwitch: { switches.append($0) }, now: { [now] in now })
  }

  private func request(_ model: String, mode: ChatMode = .cloud) -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "hi")],
                route: Route(mode: mode, providerID: CloudProviderID.free.rawValue, modelID: model, usesNetwork: true))
  }

  private func events(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var all: [ChatEvent] = []
    for try await event in stream { all.append(event) }
    return all
  }

  func testDailyLimitSwitchesSavesAndRetries() async throws {
    let reset = now.addingTimeInterval(3_600)
    let fake = ScriptedFreeProvider(["gemini-2.5-pro": .fail(CloudProviderError.quotaExhausted(.gemini, resetsAt: reset))])
    let usage = FreeModelUsage(), switches = SwitchLog()
    let all = try await events(pool(fake, usage: usage, switches: switches).stream(request("gemini-2.5-pro")))
    let time = reset.formatted(date: .omitted, time: .shortened)
    XCTAssertEqual(all.first, .activity(.notice("Switched to Apple's cloud model: Gemini 2.5 Pro reached its free daily limit (resets \(time)).")))
    XCTAssertEqual(all.dropFirst().first, .token("from apple-pcc"))
    XCTAssertEqual(switches.items, ["apple-pcc"])
    XCTAssertEqual(fake.calls, ["gemini:gemini-2.5-pro", "free:apple-pcc"])
    XCTAssertTrue(usage.isExhausted("gemini-2.5-pro", now: now))
  }

  func testPerMinuteLimitRetriesWithoutSaving() async throws {
    let fake = ScriptedFreeProvider(["gemini-2.5-pro": .fail(CloudProviderError.rateLimited(.gemini))])
    let usage = FreeModelUsage(), switches = SwitchLog()
    let all = try await events(pool(fake, usage: usage, switches: switches).stream(request("gemini-2.5-pro")))
    XCTAssertTrue(all.contains(.token("from apple-pcc")))
    XCTAssertEqual(switches.items, [])
    XCTAssertFalse(usage.isExhausted("gemini-2.5-pro", now: now))
  }

  func testNoRetryAfterTextStreamed() async throws {
    let fake = ScriptedFreeProvider(["gemini-2.5-pro": .tokenThenFail("Hi", CloudProviderError.rateLimited(.gemini))])
    do {
      _ = try await events(pool(fake, usage: FreeModelUsage()).stream(request("gemini-2.5-pro")))
      XCTFail("A reply that already started must not be retried")
    } catch { XCTAssertEqual(error as? CloudProviderError, .rateLimited(.gemini)) }
    XCTAssertEqual(fake.calls, ["gemini:gemini-2.5-pro"])
  }

  func testExhaustedChoiceIsSkipped() async throws {
    let usage = FreeModelUsage(), switches = SwitchLog()
    usage.markExhausted("gemini-2.5-pro", until: now.addingTimeInterval(600))
    let fake = ScriptedFreeProvider([:])
    let all = try await events(pool(fake, usage: usage, switches: switches).stream(request("gemini-2.5-pro")))
    XCTAssertEqual(fake.calls, ["free:apple-pcc"])
    XCTAssertEqual(switches.items, ["apple-pcc"])
    if case .activity(.notice(let text)) = all.first { XCTAssertTrue(text.hasPrefix("Switched to Apple's cloud model: Gemini 2.5 Pro")) }
    else { XCTFail("Expected a notice first, got \(all)") }
  }

  func testAutoSkipsGeminiWithoutTheToggle() async throws {
    let fake = ScriptedFreeProvider([:])
    _ = try await events(pool(fake, usage: FreeModelUsage()).stream(request("gemini-2.5-pro", mode: .auto)))
    XCTAssertEqual(fake.calls, ["free:apple-pcc"])
  }

  func testAllOutThrowsStopTextWithEarliestReset() async throws {
    let usage = FreeModelUsage()
    usage.markExhausted("gemini-2.5-pro", until: now.addingTimeInterval(900))
    usage.markExhausted("apple-pcc", until: now.addingTimeInterval(300))
    usage.markExhausted("gemini-2.5-flash", until: now.addingTimeInterval(600))
    let fake = ScriptedFreeProvider([:])
    do {
      _ = try await events(pool(fake, usage: usage).stream(request("gemini-2.5-pro")))
      XCTFail("Every free model is out")
    } catch {
      let earliest = now.addingTimeInterval(300)
      XCTAssertEqual(error as? CloudProviderError, .quotaExhausted(.free, resetsAt: earliest))
      XCTAssertEqual((error as? CloudProviderError)?.errorDescription,
                     "Free limits reached. They reset at \(earliest.formatted(date: .omitted, time: .shortened)), or connect another provider in Settings.")
    }
    XCTAssertEqual(fake.calls, [])
  }

  @MainActor
  func testSettingsFollowAPoolSwitch() async throws {
    let credentials = MemoryCredentials()
    try credentials.setAPIKey("test-only-key", for: .gemini)
    let settings = CloudSettingsModel(
      credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: URLSessionCloudTransport.shared,
                                 cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "FreeModels-\(UUID())")),
      preferences: CloudPreferencesStore(defaults: UserDefaults(suiteName: "FreeModels-\(UUID())")!), codexAvailable: { false })
    settings.preferredProvider = .free
    settings.preferredModelID = "gemini-2.5-pro"
    NotificationCenter.default.post(name: .freeModelSwitched, object: "gemini-2.5-flash")
    await Task.yield()
    XCTAssertEqual(settings.preferredModelID, "gemini-2.5-flash")
  }
}

final class SwitchLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var items: [String] { lock.withLock { stored } }
  func append(_ item: String) { lock.withLock { stored.append(item) } }
}

/// Answers every free model with one token naming it, unless scripted otherwise. Records each call
/// as "<route provider>:<model>".
final class ScriptedFreeProvider: ChatProvider, ToolCallingChatProvider, @unchecked Sendable {
  enum Script { case fail(Error), tokenThenFail(String, Error) }
  private let lock = NSLock()
  private let scripts: [String: Script]
  private var stored: [String] = []
  init(_ scripts: [String: Script]) { self.scripts = scripts }
  var calls: [String] { lock.withLock { stored } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    let model = request.route.modelID
    lock.withLock { stored.append("\(request.route.providerID):\(model)") }
    return AsyncThrowingStream { continuation in
      switch scripts[model] {
      case .fail(let error)?: continuation.finish(throwing: error)
      case .tokenThenFail(let text, let error)?: continuation.yield(.token(text)); continuation.finish(throwing: error)
      case nil: continuation.yield(.token("from \(model)")); continuation.yield(.completed); continuation.finish()
      }
    }
  }

  func stream(_ request: ChatRequest, toolbox: any AgentToolbox) -> AsyncThrowingStream<ChatEvent, Error> { stream(request) }
}


final class MemoryCredentials: CloudCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [CloudProviderID: String] = [:]
  func apiKey(for provider: CloudProviderID) throws -> String? { lock.withLock { keys[provider] } }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws { lock.withLock { keys[provider] = apiKey } }
  func removeAPIKey(for provider: CloudProviderID) throws { _ = lock.withLock { keys.removeValue(forKey: provider) } }
}
