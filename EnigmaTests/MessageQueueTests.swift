import XCTest
@testable import Enigma

final class MessageQueueTests: XCTestCase {
  func testMessagesSendInOrderUpToTheCap() {
    XCTAssertEqual(MessageQueue.capacity, 5)
    var queue = MessageQueue()
    for index in 1...MessageQueue.capacity {
      XCTAssertNotNil(queue.enqueue("Message \(index)"))
    }
    XCTAssertTrue(queue.isFull)
    XCTAssertNil(queue.enqueue("One too many"), "Nothing joins at the cap")
    XCTAssertEqual(queue.messages.count, MessageQueue.capacity)
    XCTAssertEqual(queue.popNext()?.text, "Message 1")
    XCTAssertFalse(queue.isFull)
    XCTAssertEqual(queue.popNext()?.text, "Message 2")
    XCTAssertEqual(queue.messages.map(\.text), ["Message 3", "Message 4", "Message 5"])
  }

  func testBlankTextIsNeverQueued() {
    var queue = MessageQueue()
    XCTAssertNil(queue.enqueue(""))
    XCTAssertNil(queue.enqueue("  \n\t "))
    XCTAssertTrue(queue.isEmpty)
    XCTAssertNil(queue.popNext())
  }

  func testQueuedTextKeepsItsDismissedCommands() {
    var queue = MessageQueue()
    let message = queue.enqueue("what's the weather today", dismissed: [.search])
    XCTAssertEqual(message?.dismissed, [.search])
    XCTAssertEqual(queue.popNext(), message)
  }

  func testHeldQueueSendsNothingUntilResumed() {
    var queue = MessageQueue()
    queue.enqueue("A")
    queue.enqueue("B")
    queue.hold()
    XCTAssertTrue(queue.isHeld)
    XCTAssertNil(queue.popNext())
    XCTAssertEqual(queue.messages.map(\.text), ["A", "B"])
    queue.resume()
    XCTAssertFalse(queue.isHeld)
    XCTAssertEqual(queue.popNext()?.text, "A")
  }

  func testHoldingAnEmptyQueueLeavesItReady() {
    var queue = MessageQueue()
    queue.hold()
    XCTAssertFalse(queue.isHeld, "A failed reply with nothing queued doesn't hold what's queued next")
    queue.enqueue("A")
    XCTAssertEqual(queue.popNext()?.text, "A")
  }

  func testSendNowTakesAMessageAheadOfTheOthers() {
    var queue = MessageQueue()
    queue.enqueue("A")
    let b = queue.enqueue("B")!
    queue.enqueue("C")
    queue.hold()
    XCTAssertEqual(queue.take(id: b.id), b)
    XCTAssertEqual(queue.messages.map(\.text), ["A", "C"])
    XCTAssertTrue(queue.isHeld, "Taking one doesn't resume the rest by itself")
    XCTAssertNil(queue.take(id: b.id), "Already taken")
  }

  func testCancelRemovesOneAndCancellingTheLastHeldEndsTheHold() {
    var queue = MessageQueue()
    let a = queue.enqueue("A")!
    let b = queue.enqueue("B")!
    queue.hold()
    queue.cancel(id: a.id)
    XCTAssertEqual(queue.messages, [b])
    XCTAssertTrue(queue.isHeld)
    queue.cancel(id: UUID())
    XCTAssertEqual(queue.messages, [b], "An unknown id changes nothing")
    queue.cancel(id: b.id)
    XCTAssertTrue(queue.isEmpty)
    XCTAssertFalse(queue.isHeld)
    XCTAssertNotNil(queue.enqueue("C"))
    XCTAssertEqual(queue.popNext()?.text, "C", "A fresh message isn't held by an old failure")
  }

  func testTakingTheLastHeldMessageEndsTheHold() {
    var queue = MessageQueue()
    let a = queue.enqueue("A")!
    queue.hold()
    XCTAssertEqual(queue.take(id: a.id), a)
    XCTAssertFalse(queue.isHeld)
  }

  func testAMessageThatNeverReachedTheChatReturnsToTheHead() {
    var queue = MessageQueue()
    queue.enqueue("A")
    queue.enqueue("B")
    let a = queue.popNext()!
    queue.returnToHead(a)
    XCTAssertEqual(queue.messages.map(\.text), ["A", "B"])
    queue.returnToHead(a)
    XCTAssertEqual(queue.messages.map(\.text), ["A", "B"], "Never twice")
  }

  func testReturningToAFullQueueKeepsEveryMessage() {
    var queue = MessageQueue()
    queue.enqueue("Sent")
    let sent = queue.popNext()!
    for index in 1...MessageQueue.capacity { queue.enqueue("Message \(index)") }
    queue.returnToHead(sent)
    XCTAssertEqual(queue.messages.count, MessageQueue.capacity + 1, "Nothing typed is dropped")
    XCTAssertEqual(queue.messages.first, sent)
    XCTAssertTrue(queue.isFull)
    XCTAssertNil(queue.enqueue("More"))
  }

  func testClearEmptiesAndEndsTheHold() {
    var queue = MessageQueue()
    queue.enqueue("A")
    queue.hold()
    queue.clear()
    XCTAssertEqual(queue, MessageQueue())
  }

  func testOnlyTextBelowTheCapCanBeQueuedAndNeverACapture() {
    var queue = MessageQueue()
    XCTAssertTrue(ComposerSubmission.canQueue("Next question", in: queue))
    XCTAssertTrue(ComposerSubmission.canQueue("/search latest news", in: queue), "Other commands resolve when it sends")
    XCTAssertFalse(ComposerSubmission.canQueue("   ", in: queue))
    XCTAssertFalse(ComposerSubmission.canQueue("/screen what's this?", in: queue))
    XCTAssertFalse(ComposerSubmission.canQueue("/snapshot", in: queue))
    XCTAssertFalse(ComposerSubmission.canQueue("explain /screen here", in: queue),
                   "A capture command anywhere in the draft stays in the field")
    XCTAssertFalse(ComposerSubmission.canQueue("/search", in: queue), "Commands alone have nothing to send")
    XCTAssertFalse(ComposerSubmission.canQueue("/messages", in: queue))
    XCTAssertTrue(ComposerSubmission.canQueue("/translate", in: queue), "Translate works on the selection")
    XCTAssertFalse(ComposerSubmission.canQueue("Next question", in: queue, hasAttachments: true),
                   "A draft with a screenshot or files stays in the field with them")
    for index in 1...MessageQueue.capacity { queue.enqueue("Message \(index)") }
    XCTAssertFalse(ComposerSubmission.canQueue("Next question", in: queue), "Off at the cap")
  }
}
