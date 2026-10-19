import CryptoKit
import Foundation
import XCTest
@testable import Enigma

final class ResumableArtifactTransferTests: XCTestCase {
  func testDroppedConnectionResumesWithRangeRequestOnTheOriginalURL() async throws {
    let fixture = try Fixture(in: self, bytes: 300_000, steps: [.drop(after: 100_000), .serve])
    let sleeps = TransferSleepRecorder()
    let progress = TransferProgressRecorder()
    try await fixture.artifact.download(to: fixture.output, session: fixture.session,
      policy: fixture.observing(sleeps.policy(progressInterval: .zero))) { await progress.record($0) }
    XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
    XCTAssertEqual(fixture.ranges, [nil, "bytes=100000-"])
    XCTAssertEqual(sleeps.durations, [.seconds(1)])
    let values = await progress.values.map(\.receivedByteCount)
    XCTAssertEqual(values, values.sorted(), "Progress must not move backwards across a resume")
    XCTAssertEqual(values.last, 300_000)
  }

  func testServerIgnoringRangeRestartsTheFileFromZero() async throws {
    let fixture = try Fixture(in: self, bytes: 300_000, steps: [.drop(after: 100_000), .ignoreRange])
    let progress = TransferProgressRecorder()
    try await fixture.artifact.download(to: fixture.output, session: fixture.session,
      policy: fixture.observing(TransferSleepRecorder().policy(progressInterval: .zero))) { await progress.record($0) }
    XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
    XCTAssertEqual(fixture.ranges, [nil, "bytes=100000-"])
    // Progress may move back here, because the file restarts from zero.
    let values = await progress.values.map(\.receivedByteCount)
    XCTAssertEqual(values.last, 300_000)
  }

  func testServerThatAlwaysIgnoresRangeAndDropsExhaustsTheBudget() async throws {
    // Refilling a restarted file is not progress until it passes the furthest
    // point reached before, so this cannot loop forever.
    let fixture = try Fixture(in: self, bytes: 300_000, steps: [.ignoreRangeAndDrop(after: 50_000)])
    let sleeps = TransferSleepRecorder()
    do {
      try await fixture.artifact.download(to: fixture.output, session: fixture.session,
        policy: fixture.observing(sleeps.policy())) { _ in }
      XCTFail("Expected the retry budget to run out")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")
    }
    XCTAssertEqual(fixture.ranges, [nil] + Array(repeating: "bytes=50000-", count: 5))
    XCTAssertEqual(sleeps.durations, [1, 1, 2, 4, 8].map { Duration.seconds($0) })
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
  }

  func testMismatchedOrShortContentRangeFailsWithoutKeepingData() async throws {
    // The last header is a 206 that stops short of the end: it is rejected
    // rather than accepted and left to fail the final size check.
    for header in ["bytes 0-299999/300000", "bytes 100000-299999/999999", "bytes */300000",
                   "bytes 100000-199999/300000"] {
      let fixture = try Fixture(in: self, bytes: 300_000, steps: [.drop(after: 100_000), .partial(contentRange: header)])
      do {
        try await fixture.artifact.download(to: fixture.output, session: fixture.session,
          policy: fixture.observing(TransferSleepRecorder().policy())) { _ in }
        XCTFail("A mismatched Content-Range must fail: \(header)")
      } catch {
        XCTAssertEqual(error as? LocalModelCatalogError, .invalidResponse, header)
      }
      XCTAssertEqual(fixture.ranges, [nil, "bytes=100000-"], header)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path), header)
    }
  }

  func testResponseValidationRequiresTheRestOfTheFile() throws {
    let url = URL(string: "https://example.test/model.gguf")!
    func response(_ status: Int, _ range: String?) -> HTTPURLResponse {
      HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: range.map { ["Content-Range": $0] } ?? [:])!
    }
    XCTAssertEqual(try ResumableArtifactTransfer.validate(response(200, nil), offset: 0, expectedByteCount: 10), .append)
    XCTAssertEqual(try ResumableArtifactTransfer.validate(response(206, "bytes 4-9/10"), offset: 4, expectedByteCount: 10), .append)
    XCTAssertEqual(try ResumableArtifactTransfer.validate(response(200, nil), offset: 4, expectedByteCount: 10), .restart)
    XCTAssertThrowsError(try ResumableArtifactTransfer.validate(response(206, "bytes 4-8/10"), offset: 4, expectedByteCount: 10))
    XCTAssertThrowsError(try ResumableArtifactTransfer.validate(response(206, "bytes 0-9/10"), offset: 0, expectedByteCount: 10))
    XCTAssertThrowsError(try ResumableArtifactTransfer.validate(
      HTTPURLResponse(url: URL(string: "http://example.test/model.gguf")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      offset: 0, expectedByteCount: 10))
  }

  func testPersistentDropExhaustsTheRetryBudgetWithTheNetworkError() async throws {
    let fixture = try Fixture(in: self, bytes: 4_096, steps: [.fail(.networkConnectionLost)])
    let sleeps = TransferSleepRecorder()
    do {
      try await fixture.artifact.download(to: fixture.output, session: fixture.session, policy: sleeps.policy()) { _ in }
      XCTFail("Expected the retry budget to run out")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")
    }
    XCTAssertEqual(fixture.ranges.count, 5)
    XCTAssertEqual(sleeps.durations, [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
  }

  func testProgressResetsTheRetryBudget() async throws {
    // Each drop delivers new bytes, so six interrupted attempts still finish.
    let steps: [ScriptedArtifactProtocol.Step] = Array(repeating: .drop(after: 1_000), count: 6) + [.serve]
    let fixture = try Fixture(in: self, bytes: 10_000, steps: steps)
    let sleeps = TransferSleepRecorder()
    try await fixture.artifact.download(to: fixture.output, session: fixture.session,
      policy: fixture.observing(sleeps.policy())) { _ in }
    XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
    XCTAssertEqual(fixture.ranges, [nil] + (1...6).map { "bytes=\($0 * 1_000)-" })
    XCTAssertEqual(sleeps.durations, Array(repeating: .seconds(1), count: 6))
  }

  func testTransientStatusesRetryAndPermanentStatusesFailImmediately() async throws {
    for status in [408, 429, 500, 502, 503, 504] {
      let fixture = try Fixture(in: self, bytes: 4_096, steps: [.status(status), .serve])
      try await fixture.artifact.download(to: fixture.output, session: fixture.session,
        policy: TransferSleepRecorder().policy()) { _ in }
      XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body, "\(status)")
      XCTAssertEqual(fixture.ranges, [nil, nil], "\(status)")
    }
    for status in [401, 403, 404] {
      let fixture = try Fixture(in: self, bytes: 4_096, steps: [.status(status), .serve])
      let sleeps = TransferSleepRecorder()
      do {
        try await fixture.artifact.download(to: fixture.output, session: fixture.session, policy: sleeps.policy()) { _ in }
        XCTFail("HTTP \(status) must not be retried into success")
      } catch {
        XCTAssertEqual(error as? LocalModelCatalogError, .invalidResponse, "\(status)")
      }
      XCTAssertEqual(fixture.ranges.count, 1, "\(status)")
      XCTAssertTrue(sleeps.durations.isEmpty)
    }
    let unavailable = try Fixture(in: self, bytes: 4_096, steps: [.status(503)])
    do {
      try await unavailable.artifact.download(to: unavailable.output, session: unavailable.session,
        policy: TransferSleepRecorder().policy()) { _ in }
      XCTFail("A server that stays unavailable must fail")
    } catch {
      XCTAssertEqual(error as? LocalModelCatalogError, .invalidResponse)
    }
    XCTAssertEqual(unavailable.ranges.count, 5)
  }

  func testCancellationDuringBackoffThrowsPromptly() async throws {
    let fixture = try Fixture(in: self, bytes: 4_096, steps: [.fail(.networkConnectionLost)])
    let backingOff = expectation(description: "The transfer is waiting to retry")
    var policy = ArtifactTransferPolicy()
    policy.sleep = { _ in
      backingOff.fulfill()
      try await Task.sleep(for: .seconds(600))
    }
    let task = Task { [policy] in
      try await fixture.artifact.download(to: fixture.output, session: fixture.session, policy: policy) { _ in }
    }
    await fulfillment(of: [backingOff], timeout: 5)
    let cancelled = ContinuousClock.now
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertLessThan(cancelled.duration(to: .now), .seconds(2))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
  }

  func testOversizedBodyIsRejectedWhileItArrives() async throws {
    let fixture = try Fixture(in: self, bytes: 512 * 1024, expectedByteCount: 65_536, steps: [.chunks(of: 16_384)])
    do {
      try await fixture.artifact.download(to: fixture.output, session: fixture.session,
        policy: TransferSleepRecorder().policy()) { _ in }
      XCTFail("Expected the size limit")
    } catch {
      guard case .unexpectedDownloadSize(let expected, let actual) = error as? LocalModelCatalogError else {
        return XCTFail("Wrong error: \(error)")
      }
      // URLSession may coalesce chunks; stopping before a paused server
      // finishes is covered by LocalVisionTests.
      XCTAssertEqual(expected, 65_536)
      XCTAssertGreaterThan(actual, expected)
    }
    XCTAssertEqual(fixture.ranges.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
  }

  func testProgressThrottleSpacesUpdatesByTheInterval() {
    let start = ContinuousClock.now
    var throttle = ProgressThrottle(interval: .milliseconds(100))
    XCTAssertTrue(throttle.shouldEmit(at: start), "The first update is sent at once")
    XCTAssertFalse(throttle.shouldEmit(at: start + .milliseconds(99)))
    XCTAssertTrue(throttle.shouldEmit(at: start + .milliseconds(100)))
    XCTAssertTrue(throttle.shouldEmit(at: start + .milliseconds(101), force: true), "A restart is always sent")
    XCTAssertFalse(throttle.shouldEmit(at: start + .milliseconds(150)))
    // 2,000 chunks a millisecond apart produce about one update per 100 chunks.
    var paced = ProgressThrottle(interval: .milliseconds(100))
    let sent = (0..<2_000).filter { paced.shouldEmit(at: start + .milliseconds($0)) }
    XCTAssertEqual(sent.count, 20)
    XCTAssertEqual(sent.prefix(3), [0, 100, 200])
  }

  func testFrozenClockSendsOnlyTheFirstUpdateAndTheFinalCount() async throws {
    let fixture = try Fixture(in: self, bytes: 200_000, steps: [.chunks(of: 100)])
    let start = ContinuousClock.now
    var policy = TransferSleepRecorder().policy()
    policy.now = { start }
    let progress = TransferProgressRecorder()
    try await fixture.artifact.download(to: fixture.output, session: fixture.session, policy: policy) { await progress.record($0) }
    let values = await progress.values
    XCTAssertLessThanOrEqual(values.count, 2)
    XCTAssertEqual(values.last?.receivedByteCount, 200_000)
  }

  func testSlowProgressConsumerSeesOnlyTheNewestUpdate() async throws {
    let fixture = try Fixture(in: self, bytes: 200_000, steps: [.chunks(of: 100)])
    let gate = TransferGate()
    let progress = TransferProgressRecorder()
    var policy = TransferSleepRecorder().policy(progressInterval: .zero)
    // The consumer stays stuck on its first update until every byte is on disk.
    policy.didWrite = { written in
      if written == 200_000 { Task { await gate.open() } }
    }
    try await fixture.artifact.download(to: fixture.output, session: fixture.session, policy: policy) { update in
      await gate.wait()
      await progress.record(update)
    }
    let values = await progress.values
    // The stalled first update, the one newest buffered update, and the final count.
    XCTAssertLessThanOrEqual(values.count, 3)
    XCTAssertEqual(values.last?.receivedByteCount, 200_000)
  }

  func testContentRangeParsing() {
    XCTAssertEqual(ContentRange("bytes 1000000-1000999/8413576000"),
                   ContentRange(start: 1_000_000, end: 1_000_999, total: 8_413_576_000))
    XCTAssertNil(ContentRange("bytes */8413576000"))
    XCTAssertNil(ContentRange("items 0-1/2"))
    XCTAssertNil(ContentRange("bytes 0-1"))
  }

  func testBackoffDoublesAndIsCapped() {
    XCTAssertEqual((0...7).map { ArtifactTransferPolicy.backoff(attemptsWithoutProgress: $0) },
                   [1, 1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
  }
}

extension ArtifactTransferPolicy {
  /// Retries without waiting, for tests that exercise failures.
  static let immediate = ArtifactTransferPolicy(sleep: { _ in try Task.checkCancellation() })
}

final class DownloadActivityRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var beginCount = 0
  private var endCount = 0
  var began: Int { lock.withLock { beginCount } }
  var ended: Int { lock.withLock { endCount } }
  var active: Int { lock.withLock { beginCount - endCount } }
  var activity: DownloadActivity {
    DownloadActivity { _ in
      self.lock.withLock { self.beginCount += 1 }
      return { self.lock.withLock { self.endCount += 1 } }
    }
  }
}

private final class TransferSleepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []
  var durations: [Duration] { lock.withLock { recorded } }
  func policy(progressInterval: Duration = .milliseconds(100)) -> ArtifactTransferPolicy {
    ArtifactTransferPolicy(progressInterval: progressInterval, sleep: { duration in
      self.lock.withLock { self.recorded.append(duration) }
      try Task.checkCancellation()
    })
  }
}

private actor TransferProgressRecorder {
  var values: [ModelDownloadProgress] = []
  func record(_ value: ModelDownloadProgress) { values.append(value) }
}

private actor TransferGate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func open() {
    isOpen = true
    waiting.forEach { $0.resume() }
    waiting.removeAll()
  }
}

/// Records each write the transfer makes, so a scripted drop can wait until
/// its bytes are really on disk instead of guessing with a delay.
final class TransferWriteSignal: @unchecked Sendable {
  private let condition = NSCondition()
  private var writes = 0
  private var bytesOnDisk: Int64 = 0

  var generation: Int { condition.withLock { writes } }

  func record(_ written: Int64) {
    condition.withLock {
      writes += 1
      bytesOnDisk = written
      condition.broadcast()
    }
  }

  /// Waits for a write after `generation` that leaves `target` bytes on disk.
  func wait(after generation: Int, until target: Int64) {
    let deadline = Date(timeIntervalSinceNow: 10)
    condition.withLock {
      while !(writes > generation && bytesOnDisk == target) {
        guard condition.wait(until: deadline) else { return }
      }
    }
  }
}

private struct Fixture {
  let url: URL
  let body: Data
  let artifact: VerifiedModelArtifact
  let output: URL
  let session: URLSession
  let signal: TransferWriteSignal

  init(in test: XCTestCase, bytes count: Int, expectedByteCount: Int? = nil,
       steps: [ScriptedArtifactProtocol.Step]) throws {
    var generator = SystemRandomNumberGenerator()
    body = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    url = URL(string: "https://example.test/\(UUID()).gguf")!
    artifact = VerifiedModelArtifact(url: url, expectedByteCount: Int64(expectedByteCount ?? count),
      checksumSHA256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    let directory = FileManager.default.temporaryDirectory.appending(path: "ResumableTransferTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    output = directory.appending(path: "artifact.gguf")
    signal = TransferWriteSignal()
    ScriptedArtifactProtocol.script.set(url, body: body, steps: steps, signal: signal)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedArtifactProtocol.self]
    let session = URLSession(configuration: configuration)
    self.session = session
    let url = url
    test.addTeardownBlock {
      session.invalidateAndCancel()
      ScriptedArtifactProtocol.script.remove(url)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  var ranges: [String?] { ScriptedArtifactProtocol.script.ranges(for: url) }

  /// Lets scripted drops see the transfer's writes.
  func observing(_ policy: ArtifactTransferPolicy) -> ArtifactTransferPolicy {
    var policy = policy
    let signal = signal
    policy.didWrite = { signal.record($0) }
    return policy
  }
}

/// Serves each request from a per-URL script, honouring `Range` the way the
/// Hugging Face CDN does. The last step repeats for every later request.
final class ScriptedArtifactProtocol: URLProtocol, @unchecked Sendable {
  enum Step: Sendable {
    /// 200 for the whole body, or 206 for the requested range.
    case serve
    /// Like `serve`, but the connection drops once this many more bytes are on
    /// disk. The transfer's policy must be `Fixture.observing`.
    case drop(after: Int)
    /// 200 with the whole body regardless of `Range`, dropping once this many
    /// bytes are on disk. The transfer's policy must be `Fixture.observing`.
    case ignoreRangeAndDrop(after: Int)
    /// 200 with the whole body in chunks of this size, regardless of `Range`.
    case chunks(of: Int)
    /// 200 with the whole body, ignoring `Range`.
    case ignoreRange
    /// 206 with the rest of the body and this `Content-Range`.
    case partial(contentRange: String)
    case status(Int)
    case fail(URLError.Code)
  }

  final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [URL: Data] = [:]
    private var steps: [URL: [Step]] = [:]
    private var signals: [URL: TransferWriteSignal] = [:]
    private var requests: [URL: [String?]] = [:]
    func set(_ url: URL, body: Data, steps: [Step], signal: TransferWriteSignal) {
      lock.withLock { bodies[url] = body; self.steps[url] = steps; signals[url] = signal; requests[url] = [] }
    }
    func remove(_ url: URL) {
      lock.withLock { bodies[url] = nil; steps[url] = nil; signals[url] = nil; requests[url] = nil }
    }
    func ranges(for url: URL) -> [String?] { lock.withLock { requests[url] ?? [] } }
    func next(_ url: URL, range: String?) -> (Data, Step, TransferWriteSignal)? {
      lock.withLock {
        guard let body = bodies[url], var queue = steps[url], let step = queue.first,
              let signal = signals[url] else { return nil }
        requests[url, default: []].append(range)
        if queue.count > 1 { queue.removeFirst(); steps[url] = queue }
        return (body, step, signal)
      }
    }
  }

  static let script = Script()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let range = request.value(forHTTPHeaderField: "Range")
    guard let url = request.url, let (body, step, signal) = Self.script.next(url, range: range) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
    }
    let offset = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
    switch step {
    case .serve, .drop:
      let rest = body.dropFirst(offset)
      var headers = ["Content-Length": String(rest.count)]
      if range != nil { headers["Content-Range"] = "bytes \(offset)-\(body.count - 1)/\(body.count)" }
      respond(url, status: range == nil ? 200 : 206, headers: headers)
      if case .drop(let after) = step {
        let sent = min(after, rest.count)
        dropAfterDelivering(Data(rest.prefix(sent)), until: Int64(offset + sent), signal: signal)
        return
      }
      client?.urlProtocol(self, didLoad: Data(rest))
    case .ignoreRangeAndDrop(let after):
      respond(url, status: 200, headers: ["Content-Length": String(body.count)])
      dropAfterDelivering(Data(body.prefix(after)), until: Int64(after), signal: signal)
      return
    case .chunks(let size):
      respond(url, status: 200, headers: ["Content-Length": String(body.count)])
      var start = 0
      while start < body.count {
        client?.urlProtocol(self, didLoad: Data(body[start..<min(body.count, start + size)]))
        start += size
      }
    case .ignoreRange:
      respond(url, status: 200, headers: ["Content-Length": String(body.count)])
      client?.urlProtocol(self, didLoad: body)
    case .partial(let contentRange):
      let rest = body.dropFirst(offset)
      respond(url, status: 206, headers: ["Content-Length": String(rest.count), "Content-Range": contentRange])
      client?.urlProtocol(self, didLoad: Data(rest))
    case .status(let status):
      respond(url, status: status, headers: ["Content-Length": "0"])
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
      return
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { }

  /// URLSession discards body bytes still queued when a failure arrives, so the
  /// drop waits until the transfer has written them, then fails on the
  /// protocol's own thread and run-loop mode.
  private func dropAfterDelivering(_ data: Data, until target: Int64, signal: TransferWriteSignal) {
    let generation = signal.generation
    client?.urlProtocol(self, didLoad: data)
    let thread = Thread.current
    let modes = [(RunLoop.current.currentMode ?? .default).rawValue]
    DispatchQueue.global().async { [self] in
      signal.wait(after: generation, until: target)
      perform(#selector(deliverDrop), on: thread, with: nil, waitUntilDone: false, modes: modes)
    }
  }

  @objc private func deliverDrop() {
    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
  }

  private func respond(_ url: URL, status: Int, headers: [String: String]) {
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: headers)!, cacheStoragePolicy: .notAllowed)
  }
}
