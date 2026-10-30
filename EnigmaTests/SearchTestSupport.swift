import Foundation
@testable import Enigma

/// A clock that moves only when a test calls `advance(by:)`.
final class ManualClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []

  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .zero }
  /// How many tasks are sleeping on this clock now.
  var sleeperCount: Int { lock.withLock { sleepers.count } }

  func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resumeNow: Bool = lock.withLock {
          if Task.isCancelled || deadline <= current { return true }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return false
        }
        if resumeNow {
          if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
        }
      }
    } onCancel: {
      let sleeper: Sleeper? = lock.withLock {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due: [Sleeper] = lock.withLock {
      current = current.advanced(by: duration)
      let due = sleepers.filter { $0.deadline <= current }
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  /// Waits (in real time, up to about 5 s) until at least `count` tasks sleep on this clock.
  func waitForSleepers(_ count: Int) async {
    for _ in 0..<5_000 where sleeperCount < count {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}

/// A search HTTP client that answers from a table and records what it was asked.
final class FakeSearchHTTPClient: SearchHTTPClient, @unchecked Sendable {
  enum Reply: Sendable {
    /// `remoteAddress` is the address the reply came from, as `URLSessionSearchHTTPClient` reports it.
    case response(status: Int, headers: [String: String] = [:], body: Data, remoteAddress: String? = nil)
    case failure(URLError.Code)
    /// Never answers; throws `CancellationError` once its task is cancelled.
    case hang
  }

  private let lock = NSLock()
  private var rules: [(@Sendable (URLRequest) -> Bool, Reply)] = []
  private var recordedRequests: [URLRequest] = []
  private var recordedLimits: [Int] = []
  private var cancelled = 0
  /// The reply for a request that matches no rule.
  var fallback: Reply = .failure(.cannotConnectToHost)

  var requests: [URLRequest] { lock.withLock { recordedRequests } }
  var maximumBytes: [Int] { lock.withLock { recordedLimits } }
  /// How many hanging requests saw their task cancelled.
  var cancellations: Int { lock.withLock { cancelled } }

  func stub(_ url: URL, _ reply: Reply) {
    stub(where: { $0.url == url }, reply)
  }

  /// Later rules win over earlier ones.
  func stub(where matches: @escaping @Sendable (URLRequest) -> Bool, _ reply: Reply) {
    lock.withLock { rules.insert((matches, reply), at: 0) }
  }

  func send(_ request: URLRequest, maximumBytes: Int) async throws -> SearchHTTPResponse {
    let reply: Reply = lock.withLock {
      recordedRequests.append(request)
      recordedLimits.append(maximumBytes)
      return rules.first { $0.0(request) }?.1 ?? fallback
    }
    switch reply {
    case .response(let status, let headers, let body, let remoteAddress):
      try Task.checkCancellation()
      let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
      let kept = body.prefix(maximumBytes)
      return SearchHTTPResponse(url: request.url!, statusCode: status, headers: lowered,
                                body: Data(kept), truncated: body.count > maximumBytes, remoteAddress: remoteAddress)
    case .failure(let code):
      throw URLError(code)
    case .hang:
      do {
        try await Task.sleep(for: .seconds(3_600))
      } catch {
        lock.withLock { cancelled += 1 }
        throw CancellationError()
      }
      throw CancellationError()
    }
  }

  /// Waits (in real time, up to about 5 s) until at least `count` requests arrived.
  func waitForRequests(_ count: Int) async {
    for _ in 0..<5_000 where requests.count < count {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}

/// Reads `EnigmaTests/Fixtures/Search/<name>`.
enum SearchFixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Search/\(name)")
  }

  static func data(_ name: String) -> Data {
    (try? Data(contentsOf: url(name))) ?? Data()
  }

  static func string(_ name: String) -> String {
    String(decoding: data(name), as: UTF8.self)
  }
}

/// Decodes an `application/x-www-form-urlencoded` body.
func formFields(_ body: Data?) -> [String: String] {
  guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
  var fields: [String: String] = [:]
  for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let decode = { (s: Substring) in String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
    fields[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
  }
  return fields
}
