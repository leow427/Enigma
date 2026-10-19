import Foundation
import XCTest
@testable import Enigma

final class ChatPersistenceTests: XCTestCase {
  func testStoreKeepsTenMostRecentlyActiveChatsInDescendingOrder() throws {
    XCTAssertEqual(ChatSessionStore.maximumRetainedSessions, 10)
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 0)
    let sessions = (0..<11).map { index in
      ChatSession(
        title: "Chat \(index)",
        createdAt: epoch,
        lastActivityAt: epoch.addingTimeInterval(TimeInterval(index))
      )
    }

    try store.save(sessions)

    XCTAssertEqual(store.load().map(\.title), (1...10).reversed().map { "Chat \($0)" })
    // The oldest chat is dropped from the file itself, not just hidden.
    let saved = try String(decoding: Data(contentsOf: root.appending(path: "chats.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains("\"Chat 0\""))
    XCTAssertTrue(saved.contains("\"Chat 1\""))
  }

  /// A history saved when Enigma kept five chats loads as it was.
  func testStoreLoadsAnEarlierFiveChatHistoryUnchanged() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = (0..<5).map { index in
      ChatSession(title: "Chat \(index)", messages: [ChatMessage(role: .user, content: "Question \(index)",
        createdAt: epoch)], createdAt: epoch, lastActivityAt: epoch.addingTimeInterval(TimeInterval(-index)))
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(sessions).write(to: root.appending(path: "chats.json"))

    XCTAssertEqual(store.load(), sessions)
  }

  func testStoreRecoversToAnEmptyArchiveWhenJSONIsUnreadable() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let session = ChatSession(title: "Temporary chat")
    try store.save([session])
    XCTAssertEqual(store.load().map(\.title), [session.title])
    try Data("not json".utf8).write(to: root.appending(path: "chats.json"))

    XCTAssertEqual(store.load(), [])
  }

  func testBundledModelManifestHasValidDownloadMetadata() throws {
    XCTAssertFalse(LocalModelManifest.bundled.models.isEmpty)
    for model in LocalModelManifest.bundled.models {
      XCTAssertNoThrow(try model.validate())
    }
  }

  func testImagePreviewIsExcludedFromEncodedMessages() throws {
    var message = ChatMessage(role: .user, content: "Describe this image")
    message.imagePreview = Data("session-only image bytes".utf8)
    let data = try JSONEncoder().encode(message)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["id", "role", "content", "createdAt"])
    let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
    XCTAssertEqual(restored.content, message.content)
    XCTAssertNil(restored.imagePreview)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "ChatPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

@MainActor
final class ChatSessionWriterTests: XCTestCase {
  func testCoalescesOneThousandUpdatesBeforeTakingSnapshot() async {
    let probe = makeProbe()
    let delay = ControlledChatSaveDelay()
    let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
    var snapshotsTaken = 0
    var latest = ChatSession()
    for index in 1...1_000 {
      latest.title = "Fragment \(index)"
      writer.schedule {
        snapshotsTaken += 1
        return [latest]
      }
    }
    await fulfillment(of: [delay.started], timeout: 2)
    XCTAssertEqual(snapshotsTaken, 0)
    XCTAssertTrue(probe.snapshots.isEmpty)

    await delay.release()
    await fulfillment(of: [probe.started], timeout: 2)
    await writer.waitForPendingWrites()
    XCTAssertEqual(snapshotsTaken, 1)
    XCTAssertEqual(probe.snapshots.count, 1)
    XCTAssertEqual(probe.store.load().map(\.title), ["Fragment 1000"])
  }

  func testQueuedSnapshotsAndCancelledDelayCannotOverwriteNewerArchiveOrClear() async {
    for clear in [false, true] {
      let probe = makeProbe(blockFirst: true)
      defer { probe.release() }
      let delay = ControlledChatSaveDelay()
      let writer = ChatSessionWriter(sleep: { await delay.wait($0) }, write: probe.write)
      let old = ChatSession(title: "Old")
      writer.schedule(immediately: true) { [old] }
      await fulfillment(of: [probe.started], timeout: 2)
      writer.schedule { [ChatSession(title: "Stale delayed snapshot")] }
      await fulfillment(of: [delay.started], timeout: 2)
      for index in 1...100 {
        writer.schedule(immediately: true) { [ChatSession(title: "Superseded \(index)")] }
      }
      let latest = clear ? [] : [ChatSession(title: "Newest")]
      writer.schedule(immediately: true) { latest }
      // The fake delay deliberately ignores cancellation and wakes after the
      // newer snapshot/clear, exercising the cancelled timer's ownership check.
      await delay.release()
      XCTAssertEqual(probe.snapshots.count, 1, "A blocked write must not start concurrent replacements")
      probe.release()
      await writer.waitForPendingWrites()
      XCTAssertEqual(probe.snapshots.map { $0.map(\.title) }, [["Old"], latest.map(\.title)])
      XCTAssertEqual(probe.store.load().map(\.id), latest.map(\.id))
    }
  }

  private func makeProbe(blockFirst: Bool = false) -> ChatArchiveWriteProbe {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ChatWriterTests-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return ChatArchiveWriteProbe(store: ChatSessionStore(applicationSupportDirectory: directory), blockFirst: blockFirst)
  }
}

/// A gated real archive write: verifies encoding/replacement never run on the UI thread.
final class ChatArchiveWriteProbe: @unchecked Sendable {
  let store: ChatSessionStore
  let started = XCTestExpectation(description: "Background archive write started")
  let secondFinished = XCTestExpectation(description: "Second archive write finished")
  private let blockFirst: Bool
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var recorded: [[ChatSession]] = []
  private var finishedFirst = false
  var snapshots: [[ChatSession]] { lock.withLock { recorded } }
  /// Whether the first write has returned, which a blocked first write does only after `release()`.
  var firstWriteFinished: Bool { lock.withLock { finishedFirst } }

  init(store: ChatSessionStore, blockFirst: Bool = false) {
    self.store = store
    self.blockFirst = blockFirst
  }

  func write(_ sessions: [ChatSession]) throws {
    XCTAssertFalse(Thread.isMainThread, "Serialization and disk replacement must be off the main thread")
    let count = lock.withLock { recorded.append(sessions); return recorded.count }
    if count == 1 {
      started.fulfill()
      if blockFirst { gate.wait() }
    }
    defer { if count == 1 { lock.withLock { finishedFirst = true } } }
    try store.save(sessions)
    if count == 2 { secondFinished.fulfill() }
  }

  func release() { gate.signal() }
}

actor ControlledChatSaveDelay {
  nonisolated let started = XCTestExpectation(description: "Coalescing delay started")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait(_ duration: Duration) async {
    XCTAssertEqual(duration, .milliseconds(500))
    await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }
  func release() { continuation?.resume(); continuation = nil }
}
