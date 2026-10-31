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
}
