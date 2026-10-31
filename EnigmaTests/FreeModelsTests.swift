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
}

final class MemoryCredentials: CloudCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [CloudProviderID: String] = [:]
  func apiKey(for provider: CloudProviderID) throws -> String? { lock.withLock { keys[provider] } }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws { lock.withLock { keys[provider] = apiKey } }
  func removeAPIKey(for provider: CloudProviderID) throws { _ = lock.withLock { keys.removeValue(forKey: provider) } }
}
