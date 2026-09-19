import Foundation
import XCTest
@testable import Enigma

final class ChatPersistenceTests: XCTestCase {
  func testStoreKeepsFiveMostRecentlyActiveChatsInDescendingOrder() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 0)
    let sessions = (0..<6).map { index in
      ChatSession(
        title: "Chat \(index)",
        createdAt: epoch,
        lastActivityAt: epoch.addingTimeInterval(TimeInterval(index))
      )
    }

    try store.save(sessions)

    XCTAssertEqual(store.load().map(\.title), ["Chat 5", "Chat 4", "Chat 3", "Chat 2", "Chat 1"])
  }

  func testStoreRecoversToAnEmptyArchiveWhenJSONIsUnreadable() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "AI Spotlight", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appending(path: "chats.json"))

    XCTAssertEqual(ChatSessionStore(applicationSupportDirectory: root).load(), [])
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
  var snapshots: [[ChatSession]] { lock.withLock { recorded } }

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
