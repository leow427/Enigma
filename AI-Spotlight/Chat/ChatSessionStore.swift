import Foundation

struct ChatSessionStore: Sendable {
  static let maximumRetainedSessions = 5

  private let fileURL: URL

  init(applicationSupportDirectory: URL? = nil) {
    let directory = applicationSupportDirectory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight", directoryHint: .isDirectory)
    fileURL = directory.appending(path: "chats.json")
  }

  func load() -> [ChatSession] {
    guard let data = try? Data(contentsOf: fileURL),
          let sessions = try? decoder.decode([ChatSession].self, from: data) else {
      return []
    }
    return normalized(sessions)
  }

  func save(_ sessions: [ChatSession]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(normalized(sessions)).write(to: fileURL, options: .atomic)
  }

  private func normalized(_ sessions: [ChatSession]) -> [ChatSession] {
    Array(
      sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        .prefix(Self.maximumRetainedSessions)
    )
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// Best-effort temporary history: one background write and one replaceable pending snapshot.
@MainActor
final class ChatSessionWriter {
  typealias Snapshot = @MainActor () -> [ChatSession]?
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private let write: @Sendable ([ChatSession]) throws -> Void
  private let sleep: Sleep
  private let queue = DispatchQueue(label: "Enigma.chat-history", qos: .utility)
  private var pendingSnapshot: Snapshot?
  private var delayedSave: Task<Void, Never>?
  private var writeTask: Task<Void, Never>?

  init(
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    write: @escaping @Sendable ([ChatSession]) throws -> Void
  ) {
    self.sleep = sleep
    self.write = write
  }

  func schedule(immediately: Bool = false, snapshot: @escaping Snapshot) {
    // Snapshot lazily so each token need not copy the growing transcript.
    pendingSnapshot = snapshot
    if immediately { flush(); return }
    guard delayedSave == nil else { return }
    delayedSave = Task { [weak self, sleep] in
      do { try await sleep(.milliseconds(500)) }
      catch { return }
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func flush() {
    delayedSave?.cancel()
    delayedSave = nil
    guard writeTask == nil, let snapshot = pendingSnapshot else { return }
    pendingSnapshot = nil
    guard let sessions = snapshot() else { return }
    writeTask = Task { [weak self, queue, write] in
      await withCheckedContinuation { continuation in
        queue.async {
          // Encoding and atomic replacement both run off the UI thread. A failed
          // temporary-history save must not change a live request's state.
          try? write(sessions)
          continuation.resume()
        }
      }
      guard let self else { return }
      self.writeTask = nil
      // Never start a newer write until the previous replacement has finished.
      if self.delayedSave == nil { self.flush() }
    }
  }

  /// Await best-effort saves when verifying the archive; UI actions only enqueue them.
  func waitForPendingWrites() async {
    flush()
    while let task = writeTask {
      await task.value
      flush()
    }
  }
}
