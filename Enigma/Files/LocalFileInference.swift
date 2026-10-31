import Foundation

enum LocalFileRuntime {
  static func executable(for model: LocalModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let candidates = [model.visionConfiguration?.serverExecutableURL.path, LocalFileRuntimeSetup.executable.path,
      environment["AI_SPOTLIGHT_LLAMA_SERVER_PATH"], "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
      .compactMap { $0 }
      + LocalModelInstallationStore().installedModels().compactMap { $0.visionConfiguration?.serverExecutableURL.path }
    return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  static func textArguments(model: LocalModel, port: UInt16, key: String, alias: String) throws -> [String] {
    guard model.fileURL.isFileURL, model.fileURL.pathExtension.lowercased() == "gguf",
          FileManager.default.isReadableFile(atPath: model.fileURL.path), executable(for: model) != nil else {
      throw FileModeError.operation("Local File Mode needs llama-server. Open Settings → On this Mac → Files → Local file tools → Install, or choose a recommended model with its included runtime. Your files stay on this Mac.")
    }
    return ["-m", model.fileURL.path, "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
      "--alias", alias, "--ctx-size", String(contextWindow(for: model)), "--parallel", "1", "--offline",
      "--no-webui", "--jinja", "--no-context-shift", "--cache-ram", "0", "--reasoning-budget", "-1", "--fit", "off"]
  }

  static func contextWindow(for model: LocalModel) -> Int {
    model.visionConfiguration?.contextWindow ?? max(4_096, min(16_384, model.catalogDescriptor?.recommendedContextSize ?? 8_192))
  }

  static func validateBudget(promptTokens: Int, maximumTokens: Int, contextWindow: Int) throws {
    guard promptTokens >= 0, (128...4_096).contains(maximumTokens), (4_096...32_768).contains(contextWindow) else {
      throw FileModeError.invalidArguments
    }
    guard promptTokens < contextWindow - maximumTokens - 64 else { throw FileModeError.contextExhausted }
  }

  /// `stream` and `cachePrompt` are for chat tool turns, whose system prompt and tools are a
  /// stable prefix the server can reuse; File Mode sends neither.
  static func payload(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], alias: String,
                      maximumTokens: Int = 1_024, stream: Bool = false, cachePrompt: Bool = false,
                      requiresTool: Bool = false) throws -> CodexValue {
    let encoded = try JSONEncoder().encode(messages)
    return .object(["model": .string(alias), "messages": try JSONDecoder().decode(CodexValue.self, from: encoded),
      "tools": .array(tools.map(\.llama)), "tool_choice": .string(requiresTool ? "required" : "auto"), "parallel_tool_calls": .bool(false),
      "chat_template_kwargs": .object(["enable_thinking": .bool(messages.first?.extendedThinking == true)]),
      "reasoning_budget": .number(messages.first?.extendedThinking == true ? 1_024 : 0),
      "stream": .bool(stream), "max_tokens": .number(Double(maximumTokens)), "temperature": .number(0), "cache_prompt": .bool(cachePrompt)])
  }

  static func response(_ data: Data) throws -> AgentInferenceMessage {
    let value = try JSONDecoder().decode(CodexValue.self, from: data)
    guard let choice = value["choices"].array?.first else { throw FileModeError.invalidArguments }
    if choice["finish_reason"].string == "length" { throw FileModeError.incompleteResponse }
    guard ["stop", "tool_calls"].contains(choice["finish_reason"].string ?? "") else {
      throw FileModeError.operation("The local runtime stopped with an unsupported finish reason. No calls from that response were executed. Review keeps earlier edits.")
    }
    let message = try JSONDecoder().decode(AgentInferenceMessage.self, from: JSONEncoder().encode(choice["message"]))
    guard message.role == "assistant",
          !(message.content ?? "").isEmpty || !(message.toolCalls ?? []).isEmpty else { throw FileModeError.invalidArguments }
    return message
  }
}

/// Assembles a streamed chat completion into one assistant message. Reasoning is dropped,
/// and a call is returned only from a stream the server finished.
struct LocalToolStreamAssembler {
  private var content = ""
  private var calls: [Int: (id: String?, name: String, arguments: String)] = [:]
  private var finishReason: String?

  /// Whether the server finished its reply, usable or not.
  var isComplete: Bool { finishReason != nil }

  /// Takes one server-sent event's data and returns the answer text it adds, if any.
  mutating func consume(_ data: String) throws -> String? {
    if data == "[DONE]" { return nil }
    let value = try JSONDecoder().decode(CodexValue.self, from: Data(data.utf8))
    guard value["error"] == .null else {
      throw LocalInferenceError.bridgeFailure("The local model returned an error. Verify the model and projector match.")
    }
    guard let choice = value["choices"].array?.first else { return nil }
    if let reason = choice["finish_reason"].string { finishReason = reason }
    let delta = choice["delta"]
    for call in delta["tool_calls"].array ?? [] {
      guard let index = call["index"].integer else { throw FileModeError.invalidArguments }
      var entry = calls[index] ?? (nil, "", "")
      if let id = call["id"].string { entry.id = id }
      entry.name += call["function"]["name"].string ?? ""
      entry.arguments += call["function"]["arguments"].string ?? ""
      calls[index] = entry
    }
    guard let text = delta["content"].string, !text.isEmpty else { return nil }
    content += text
    return text
  }

  /// The finished message. A stream that never finished (cut, or still mid-call) throws.
  /// As on plain turns, an answer that reaches the output limit simply ends there; a call
  /// it cut off never runs.
  func finish() throws -> AgentInferenceMessage {
    guard let finishReason else { throw CloudProviderError.streamEndedUnexpectedly }
    guard ["stop", "tool_calls", "length"].contains(finishReason) else {
      throw AgentToolError.invalidResponse("The local model stopped for an unexpected reason. Nothing from that reply was run.")
    }
    if finishReason == "length" && !calls.isEmpty {
      throw AgentToolError.invalidResponse("The local model reached its reply limit in the middle of a tool call. Nothing from that reply was run.")
    }
    let toolCalls = try calls.keys.sorted().map { index in
      let call = calls[index]!
      guard !call.name.isEmpty else {
        throw AgentToolError.invalidResponse("The local model sent a tool call without a name. Nothing from that reply was run.")
      }
      return AgentToolCall(id: call.id ?? "call\(index)", function: .init(name: call.name, arguments: call.arguments))
    }
    guard !content.isEmpty || !toolCalls.isEmpty else {
      throw AgentToolError.invalidResponse("The local model returned an empty reply. Try again.")
    }
    return AgentInferenceMessage(role: "assistant", content: content.isEmpty ? nil : content,
                                 toolCalls: toolCalls.isEmpty ? nil : toolCalls)
  }
}
