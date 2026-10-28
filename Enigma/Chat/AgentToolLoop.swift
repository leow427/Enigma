import Foundation

/// A set of host-implemented tools a model may call during one request. Only the host
/// executes calls; assistant text is never parsed for commands.
protocol AgentToolbox: Sendable {
  var instructions: String { get }
  var definitions: [AgentToolDefinition] { get }
  func execute(name: String, arguments: CodexValue) async -> AgentToolResult
  /// Reported while a call runs, for the assistant activity row.
  func phase(for name: String) -> AssistantActivity.Phase
  /// A tool the model must call on its first step, where the provider can force one.
  var requiredTool: String? { get }
}

extension AgentToolbox {
  func phase(for _: String) -> AssistantActivity.Phase { .thinking }
  var requiredTool: String? { nil }

  /// The required tool, if it is one of this toolbox's definitions.
  var offeredRequiredTool: String? {
    requiredTool.flatMap { name in definitions.contains { $0.name == name } ? name : nil }
  }

  /// Decodes a provider's JSON argument string and executes the call.
  func execute(name: String, jsonArguments: String) async -> AgentToolResult {
    let text = jsonArguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let arguments = text.isEmpty ? .object([:]) : try? JSONDecoder().decode(CodexValue.self, from: Data(text.utf8)) else {
      return AgentToolResult(text: "Invalid tool arguments: expected a JSON object matching the tool schema.", success: false)
    }
    return await execute(name: name, arguments: arguments)
  }
}

enum AgentToolError: LocalizedError, Equatable {
  case stepLimit
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .stepLimit: "The model used too many tool calls without answering. Ask a more specific question."
    case .invalidResponse(let detail): detail
    }
  }
}

/// How a terminal tool result ends its request. The request fails with this error rather
/// than handing it back to the model, so a permission problem reaches the user unchanged.
enum AgentToolStop: Sendable, Equatable {
  /// The user stopped the request.
  case cancelled
  /// macOS withheld a permission Messages needs.
  case messages(MessagesError)

  var error: Error {
    switch self {
    case .cancelled: CancellationError()
    case .messages(let error): error
    }
  }
}

extension AgentToolResult {
  /// The error a non-file tool loop ends the request with, or nil when the model may carry on.
  /// File Mode reads `terminal` itself; these loops key off `stop`.
  var stopError: Error? { stop?.error }
}

/// The local tool loop for non-file toolboxes. One call per step, so each call is
/// chosen after the model has seen the previous result.
struct LocalToolAgent: Sendable {
  let inference: any LocalToolInference
  var maximumSteps = 12

  static let localInstructions = """
  Make exactly ONE tool call per response, then wait for its result. When you have enough information, answer without calling a tool.
  """

  func run(messages: [ChatMessage], model: LocalModel, toolbox: any AgentToolbox,
           onActivity: @Sendable (AssistantActivityEvent) async -> Void = { _ in },
           onText: @Sendable (String) async -> Void) async throws {
    var history = [AgentInferenceMessage(role: "system", content:
      ChatResponseStyle.instructions + "\n" + toolbox.instructions + "\n" + Self.localInstructions)]
      + messages.map { AgentInferenceMessage(role: $0.role.rawValue, content: $0.content) }
    if ThinkCommand.enabled(in: messages) {
      history[0].extendedThinking = true
      history[0].content = ThinkCommand.guidance + "\n\n" + (history[0].content ?? "")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    for step in 0..<maximumSteps {
      try Task.checkCancellation()
      var response = try await inference.completeTools(messages: history, tools: toolbox.definitions, model: model)
      try Task.checkCancellation()
      guard response.role == "assistant" else { throw AgentToolError.invalidResponse("The local runtime returned an unexpected message role.") }
      guard let first = response.toolCalls?.first else {
        await onActivity(.phase(.generating))
        if let content = response.content, !content.isEmpty { await onText(content) }
        return
      }
      // Discarded batch members never enter history and never run.
      let call = AgentToolCall(id: String(format: "tool%05d", step), function: first.function)
      response.toolCalls = [call]
      response.content = nil
      history.append(response)
      await onActivity(.phase(toolbox.phase(for: call.function.name)))
      let result = await toolbox.execute(name: call.function.name, jsonArguments: call.function.arguments)
      try Task.checkCancellation()
      if let error = result.stopError { throw error }
      let output = (try? JSONDecoder().decode(CodexValue.self, from: Data(result.text.utf8))) ?? .string(result.text)
      let content = String(decoding: try encoder.encode(CodexValue.object([
        "success": .bool(result.success), "result": output,
      ])), as: UTF8.self)
      history.append(AgentInferenceMessage(role: "tool", content: content, toolCallID: call.id))
      await onActivity(.phase(.thinking))
    }
    throw AgentToolError.stepLimit
  }
}
