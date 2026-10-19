import Foundation

/// Keeps the Mac from idle-sleeping, and the menu-bar app from being napped,
/// while a model package downloads and installs. The display may still sleep.
struct DownloadActivity: Sendable {
  /// Begins an activity and returns the call that ends it.
  var begin: @Sendable (_ reason: String) -> @Sendable () -> Void

  static let system = DownloadActivity { reason in
    let token = ProcessActivityToken(ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: reason))
    return { token.end() }
  }
}

private final class ProcessActivityToken: @unchecked Sendable {
  private let lock = NSLock()
  private var token: (any NSObjectProtocol)?
  init(_ token: any NSObjectProtocol) { self.token = token }
  /// Ends the activity even if the end closure is never called.
  deinit { end() }
  /// Ends the activity once; later calls do nothing.
  func end() {
    let active: (any NSObjectProtocol)? = lock.withLock {
      defer { token = nil }
      return token
    }
    guard let active else { return }
    ProcessInfo.processInfo.endActivity(active)
  }
}

/// Retry, backoff and progress pacing for artifact transfers. Tests inject the
/// sleep and clock so they never wait in real time.
struct ArtifactTransferPolicy: Sendable {
  /// Consecutive attempts that write no new bytes before the transfer gives up.
  var attemptsWithoutProgress = 5
  /// The shortest time between two progress updates; the final count is always delivered.
  var progressInterval: Duration = .milliseconds(100)
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  /// Called on the delegate queue with the bytes on disk after each write, so
  /// tests can act once bytes have really landed instead of waiting for time.
  var didWrite: (@Sendable (Int64) -> Void)? = nil

  static let standard = ArtifactTransferPolicy()

  /// 1 s after an attempt that made progress, then 1, 2, 4, 8 s for each
  /// consecutive attempt without progress (doubling, capped at 30 s).
  static func backoff(attemptsWithoutProgress count: Int) -> Duration {
    .seconds(min(30, 1 << min(max(count - 1, 0), 5)))
  }

  static let transientStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

  static func isTransient(_ error: Error) -> Bool {
    if case ArtifactTransferFailure.transientStatus = error { return true }
    guard let error = error as? URLError else { return false }
    return [URLError.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed].contains(error.code)
  }
}

enum ArtifactTransferFailure: Error, Equatable {
  /// A retryable HTTP status. It is reported as an invalid response if the
  /// retry budget runs out.
  case transientStatus(Int)
}

/// Writes one artifact to `destination`, resuming with a `Range` request on
/// the original URL after a transient failure. The original URL is always
/// re-requested because the redirected CDN URL is signed and expires.
struct ResumableArtifactTransfer: Sendable {
  let url: URL
  let expectedByteCount: Int64
  let destination: URL
  let policy: ArtifactTransferPolicy
  let updates: AsyncStream<ModelDownloadProgress>.Continuation

  func run(session: URLSession) async throws {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
    let handle = try FileHandle(forWritingTo: destination)
    let delegate = ArtifactTransferDelegate(handle: handle, expectedByteCount: expectedByteCount,
                                            policy: policy, updates: updates)
    let transferSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
    do {
      try await withTaskCancellationHandler {
        try await transfer(with: transferSession, delegate: delegate)
      } onCancel: { delegate.cancel() }
      transferSession.invalidateAndCancel()
      try handle.close()
    } catch {
      transferSession.invalidateAndCancel()
      Self.close(handle)
      throw error
    }
  }

  private func transfer(with session: URLSession, delegate: ArtifactTransferDelegate) async throws {
    var attemptsWithoutProgress = 0
    // The furthest the file has reached. After a server ignores `Range` the
    // file restarts from zero, and refilling it is not progress until it
    // passes this point, so a server that always restarts and drops still
    // exhausts the budget.
    var highWaterMark: Int64 = 0
    while true {
      try Task.checkCancellation()
      let offset = delegate.bytesOnDisk
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
      if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
      do {
        try await delegate.perform(session.dataTask(with: request), offset: offset)
        let received = delegate.bytesOnDisk
        guard received == expectedByteCount else {
          throw LocalModelCatalogError.unexpectedDownloadSize(expected: expectedByteCount, actual: received)
        }
        return
      } catch {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        guard ArtifactTransferPolicy.isTransient(error) else { throw error }
        // Every byte arrived before the connection closed; the checksum decides.
        if delegate.bytesOnDisk == expectedByteCount { return }
        let onDisk = delegate.bytesOnDisk
        if onDisk > highWaterMark {
          highWaterMark = onDisk
          attemptsWithoutProgress = 0
        } else {
          attemptsWithoutProgress += 1
        }
        guard attemptsWithoutProgress < policy.attemptsWithoutProgress else {
          if case ArtifactTransferFailure.transientStatus = error { throw LocalModelCatalogError.invalidResponse }
          throw error
        }
        try await policy.sleep(ArtifactTransferPolicy.backoff(attemptsWithoutProgress: attemptsWithoutProgress))
      }
    }
  }

  /// Decides how a response continues the bytes already on disk.
  enum ResponsePlan: Equatable { case append, restart }

  static func validate(_ response: URLResponse, offset: Int64, expectedByteCount: Int64) throws -> ResponsePlan {
    guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
      throw LocalModelCatalogError.invalidResponse
    }
    if ArtifactTransferPolicy.transientStatusCodes.contains(http.statusCode) {
      throw ArtifactTransferFailure.transientStatus(http.statusCode)
    }
    if offset == 0 {
      guard http.statusCode == 200 else { throw LocalModelCatalogError.invalidResponse }
      return .append
    }
    switch http.statusCode {
    case 200:
      // The server ignored the range and is sending the whole file again.
      return .restart
    case 206:
      guard let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init),
            range.start == offset, range.total == expectedByteCount, range.end == expectedByteCount - 1 else {
        // A range that stops short of the end is not requested, so it is rejected.
        throw LocalModelCatalogError.invalidResponse
      }
      return .append
    default:
      throw LocalModelCatalogError.invalidResponse
    }
  }

  private static func close(_ handle: FileHandle) {
    do { try handle.close() } catch { }
  }
}

/// `Content-Range: bytes <start>-<end>/<total>`.
struct ContentRange: Equatable {
  let start: Int64
  let end: Int64
  let total: Int64

  init(start: Int64, end: Int64, total: Int64) {
    self.start = start
    self.end = end
    self.total = total
  }

  init?(_ header: String) {
    let value = header.trimmingCharacters(in: .whitespaces)
    guard value.lowercased().hasPrefix("bytes ") else { return nil }
    let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
          let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    self.init(start: start, end: end, total: total)
  }
}

/// Spaces progress updates at least `interval` apart. A forced update (a
/// restart) is always sent.
struct ProgressThrottle {
  let interval: Duration
  private var lastEmission: ContinuousClock.Instant?

  init(interval: Duration) { self.interval = interval }

  mutating func shouldEmit(at now: ContinuousClock.Instant, force: Bool = false) -> Bool {
    if !force, let lastEmission, lastEmission.duration(to: now) < interval { return false }
    lastEmission = now
    return true
  }
}

/// Appends response bodies to one file handle. URLSession calls the delegate
/// methods on its own serial queue, so the file is only touched there and
/// without the lock; the lock guards the state that `perform`, `cancel` and
/// `bytesOnDisk` share with the transfer task, so they never wait on disk I/O.
private final class ArtifactTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let handle: FileHandle
  private let expectedByteCount: Int64
  private let policy: ArtifactTransferPolicy
  private let updates: AsyncStream<ModelDownloadProgress>.Continuation
  private let lock = NSLock()
  // Shared state, guarded by `lock`.
  private var written: Int64 = 0
  private var offset: Int64 = 0
  private var accepted = false
  private var failure: Error?
  private var cancelled = false
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<Void, Error>?
  // Used only on the delegate queue.
  private var throttle: ProgressThrottle

  init(handle: FileHandle, expectedByteCount: Int64, policy: ArtifactTransferPolicy,
       updates: AsyncStream<ModelDownloadProgress>.Continuation) {
    self.handle = handle
    self.expectedByteCount = expectedByteCount
    self.policy = policy
    self.updates = updates
    throttle = ProgressThrottle(interval: policy.progressInterval)
  }

  var bytesOnDisk: Int64 { lock.withLock { written } }

  func perform(_ task: URLSessionDataTask, offset: Int64) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let shouldCancel = lock.withLock {
        self.task = task
        self.continuation = continuation
        self.offset = offset
        accepted = false
        failure = nil
        return cancelled
      }
      // Cancellation can arrive before the task has been registered.
      if shouldCancel { task.cancel() }
      task.resume()
    }
  }

  func cancel() {
    let active = lock.withLock { cancelled = true; return task }
    active?.cancel()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    let offset = lock.withLock { self.offset }
    do {
      if try ResumableArtifactTransfer.validate(response, offset: offset, expectedByteCount: expectedByteCount) == .restart {
        try handle.truncate(atOffset: 0)
        lock.withLock { written = 0 }
        emit(0, force: true)
      }
      lock.withLock { accepted = true }
      completionHandler(.allow)
    } catch {
      lock.withLock { failure = error }
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // Only this serial queue changes `written`, `accepted` and `failure` while a task runs.
    let (current, proceed) = lock.withLock { (written, accepted && failure == nil) }
    guard proceed else { return }
    let next = current + Int64(data.count)
    guard next <= expectedByteCount else {
      // Stop as soon as the bytes on disk would exceed the manifest size.
      fail(dataTask, LocalModelCatalogError.unexpectedDownloadSize(expected: expectedByteCount, actual: next))
      return
    }
    do { try handle.write(contentsOf: data) } catch {
      fail(dataTask, error)
      return
    }
    lock.withLock { written = next }
    policy.didWrite?(next)
    emit(next, force: false)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                  completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let completion = lock.withLock {
      let outcome: Result<Void, Error>
      if let failure { outcome = .failure(failure) }
      else if cancelled { outcome = .failure(CancellationError()) }
      else if let error { outcome = .failure(error) }
      else if !accepted { outcome = .failure(LocalModelCatalogError.invalidResponse) }
      else { outcome = .success(()) }
      let waiting = continuation
      continuation = nil
      self.task = nil
      return (waiting, outcome)
    }
    completion.0?.resume(with: completion.1)
  }

  private func fail(_ task: URLSessionDataTask, _ error: Error) {
    lock.withLock { failure = error }
    task.cancel()
  }

  /// The stream keeps only the newest update, so the main actor never works
  /// through a backlog of stale values.
  private func emit(_ byteCount: Int64, force: Bool) {
    guard throttle.shouldEmit(at: policy.now(), force: force) else { return }
    updates.yield(ModelDownloadProgress(receivedByteCount: byteCount, expectedByteCount: expectedByteCount))
  }
}

extension FileManager {
  /// Removes an item if it exists, ignoring failures. Download cleanup uses it
  /// so that cleanup can never replace the error that ended a transfer.
  func removeItemIfPresent(at url: URL) {
    guard fileExists(atPath: url.path) else { return }
    do { try removeItem(at: url) } catch { }
  }
}
