import Foundation

/// A message typed while a reply ran, waiting to be sent. It's text only:
/// its commands are resolved when it sends, on the route selected then.
struct QueuedMessage: Identifiable, Equatable, Sendable {
  let id: UUID
  let text: String
  /// Recognized commands the person turned off for this draft before queueing it.
  let dismissed: Set<SlashCommand>

  init(id: UUID = UUID(), text: String, dismissed: Set<SlashCommand> = []) {
    self.id = id
    self.text = text
    self.dismissed = dismissed
  }
}

/// The open chat's queued messages, in the order they send. Draining sends
/// the head each time a reply ends; a failed or stopped reply holds the
/// queue until the person chooses Send now. It lives in memory only.
struct MessageQueue: Equatable, Sendable {
  static let capacity = 5

  private(set) var messages: [QueuedMessage] = []
  /// A reply failed or was stopped: nothing sends until Send now. Never true while empty.
  private(set) var isHeld = false

  var isEmpty: Bool { messages.isEmpty }
  var isFull: Bool { messages.count >= Self.capacity }

  /// Adds a message at the end. Returns nil for blank text or at the cap.
  @discardableResult
  mutating func enqueue(_ text: String, dismissed: Set<SlashCommand> = []) -> QueuedMessage? {
    guard !isFull, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let message = QueuedMessage(text: text, dismissed: dismissed)
    messages.append(message)
    return message
  }

  mutating func cancel(id: UUID) {
    messages.removeAll { $0.id == id }
    if messages.isEmpty { isHeld = false }
  }

  /// The next message to send, removed from the queue; nil while held.
  mutating func popNext() -> QueuedMessage? {
    guard !isHeld, !messages.isEmpty else { return nil }
    return messages.removeFirst()
  }

  /// Removes one message to send it now, ahead of the others.
  mutating func take(id: UUID) -> QueuedMessage? {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
    let message = messages.remove(at: index)
    if messages.isEmpty { isHeld = false }
    return message
  }

  /// A message that never reached the chat goes back in front, not lost. Past
  /// the cap only by the one message it already held, so nothing is dropped.
  mutating func returnToHead(_ message: QueuedMessage) {
    guard !messages.contains(where: { $0.id == message.id }) else { return }
    messages.insert(message, at: 0)
  }

  mutating func hold() { isHeld = !messages.isEmpty }

  mutating func resume() { isHeld = false }

  mutating func clear() {
    messages = []
    isHeld = false
  }
}
