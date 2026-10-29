import Foundation
@testable import Enigma

/// The recorded and synthetic provider-search fixtures (F30 CP0), read from the source tree:
/// the test target has no resources phase.
enum CloudSearchFixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/CloudSearch/\(name)")
  }
}

/// A ToolCallingChatProvider that records each request and toolbox, and replays a script of
/// events, tool calls or errors per run. Like `CloudToolLoop`, a call whose result carries a stop
/// ends the run with its error, and the provider never receives that result.
final class ScriptedSearchProvider: ChatProvider, ToolCallingChatProvider, @unchecked Sendable {
  enum Event: Sendable {
    case token(String)
    case activity(AssistantActivityEvent)
    case call(String, String)
    case fail(CloudProviderError)
    /// Waits until the run is cancelled.
    case hang
  }

  struct Run: Sendable {
    let request: ChatRequest
    let toolNames: [String]
    let instructions: String
    let requiredTool: String?
  }

  /// A tool result the provider received.
  struct Delivered: Sendable, Equatable {
    let name: String
    let text: String
  }

  private let lock = NSLock()
  private var scripts: [[Event]]
  private var recordedRuns: [Run] = []
  private var recordedDeliveries: [Delivered] = []
  /// Runs before a call's stop ends the run, as when the user presses Stop just then.
  var beforeStop: (@Sendable () async -> Void)?

  init(runs: [[Event]]) { scripts = runs }

  var runs: [Run] { lock.withLock { recordedRuns } }
  var delivered: [Delivered] { lock.withLock { recordedDeliveries } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.yield(.token("Plain cloud.")); $0.finish() }
  }

  func stream(_ request: ChatRequest, toolbox: any AgentToolbox) -> AsyncThrowingStream<ChatEvent, Error> {
    let script = lock.withLock { () -> [Event] in
      recordedRuns.append(Run(request: request, toolNames: toolbox.definitions.map(\.name),
                              instructions: toolbox.instructions, requiredTool: toolbox.requiredTool))
      return scripts.isEmpty ? [] : scripts.removeFirst()
    }
    let beforeStop = beforeStop
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for event in script {
            try Task.checkCancellation()
            switch event {
            case .token(let text): continuation.yield(.token(text))
            case .activity(let update): continuation.yield(.activity(update))
            case .call(let name, let arguments):
              let result = await toolbox.execute(name: name, jsonArguments: arguments)
              if let error = result.stopError {
                await beforeStop?()
                throw error
              }
              try Task.checkCancellation()
              lock.withLock { recordedDeliveries.append(Delivered(name: name, text: result.text)) }
            case .fail(let error): throw error
            case .hang: while true { try await Task.sleep(for: .seconds(60)) }
            }
          }
          continuation.yield(.completed)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
