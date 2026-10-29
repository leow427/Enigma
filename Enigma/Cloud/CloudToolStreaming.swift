import Foundation

/// Builds one tool-loop step from a provider's server-sent events. Text deltas are returned
/// as they arrive; calls are only handed out by `finish()`, once the step's stream is complete,
/// so a call cut off mid-stream never runs.
protocol ToolStreamAssembler {
  /// Returns any text delta in this event (never an empty one).
  mutating func consume(_ event: ServerSentEvent) throws -> String?
  /// The finished turn; throws CloudProviderError.invalidResponse if a call is incomplete.
  func finish() throws -> CloudToolLoop.Turn
}

private func eventObject(_ event: ServerSentEvent) throws -> [String: Any] {
  guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
    throw CloudProviderError.invalidResponse
  }
  return object
}

/// OpenAI Responses: text from `response.output_text.delta`, items from `response.output_item.done`.
struct OpenAIToolStreamAssembler: ToolStreamAssembler {
  private var items: [(index: Int, item: [String: Any])] = []
  private var openCalls: Set<Int> = []
  private var status: String?

  /// The output items in order, as the whole-response path appended them to the input.
  var replayItems: [[String: Any]] { output.compactMap(OpenAIResponsesClient.replayable) }

  private var output: [[String: Any]] {
    items.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element.item)
  }

  mutating func consume(_ event: ServerSentEvent) throws -> String? {
    // The plain OpenAI client accepts this sentinel; completion still comes from `response.completed`.
    guard event.data != "[DONE]" else { return nil }
    let object = try eventObject(event)
    let index = object["output_index"] as? Int ?? items.count
    switch object["type"] as? String {
    case "response.output_text.delta":
      return (object["delta"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    case "response.output_item.added":
      if (object["item"] as? [String: Any])?["type"] as? String == "function_call" { openCalls.insert(index) }
    case "response.output_item.done":
      guard let item = object["item"] as? [String: Any] else { throw CloudProviderError.invalidResponse }
      items.append((index, item))
      openCalls.remove(index)
    case "response.completed":
      status = "completed"
    case "response.incomplete":
      status = "incomplete"
    case "response.failed", "error":
      let response = object["response"] as? [String: Any]
      throw CloudProviderError.providerMessage(
        (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String
          ?? (response?["error"] as? [String: Any])?["message"] as? String ?? "OpenAI could not complete the response.")
    default:
      break
    }
    return nil
  }

  func finish() throws -> CloudToolLoop.Turn {
    guard openCalls.isEmpty else { throw CloudProviderError.invalidResponse }
    guard let status else { throw CloudProviderError.streamEndedUnexpectedly }
    return try OpenAIResponsesClient.toolTurn(["status": status, "output": output])
  }
}

/// Anthropic Messages: content blocks from `content_block_start`, their deltas and `content_block_stop`.
struct AnthropicToolStreamAssembler: ToolStreamAssembler {
  private var blocks: [(index: Int, block: [String: Any])] = []
  private var partialJSON: [Int: String] = [:]
  private var open: Set<Int> = []
  private var stopped = false

  /// The assistant content, unchanged, as the whole-response path appended it to the messages
  /// (thinking blocks keep their signatures).
  var assistantContent: [[String: Any]] { blocks.map(\.block) }

  mutating func consume(_ event: ServerSentEvent) throws -> String? {
    let object = try eventObject(event)
    switch object["type"] as? String {
    case "content_block_start":
      guard let index = object["index"] as? Int, let block = object["content_block"] as? [String: Any],
            !blocks.contains(where: { $0.index == index }) else { throw CloudProviderError.invalidResponse }
      blocks.append((index, block))
      open.insert(index)
      if block["type"] as? String == "tool_use" { partialJSON[index] = "" }
    case "content_block_delta":
      guard let index = object["index"] as? Int, open.contains(index),
            let position = blocks.firstIndex(where: { $0.index == index }),
            let delta = object["delta"] as? [String: Any] else { throw CloudProviderError.invalidResponse }
      switch delta["type"] as? String {
      case "text_delta":
        let text = delta["text"] as? String ?? ""
        blocks[position].block["text"] = (blocks[position].block["text"] as? String ?? "") + text
        return text.isEmpty ? nil : text
      case "input_json_delta":
        guard partialJSON[index] != nil else { throw CloudProviderError.invalidResponse }
        partialJSON[index]? += delta["partial_json"] as? String ?? ""
      case "thinking_delta":
        blocks[position].block["thinking"] = (blocks[position].block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
      case "signature_delta":
        blocks[position].block["signature"] = delta["signature"] as? String ?? ""
      default:
        break
      }
    case "content_block_stop":
      guard let index = object["index"] as? Int, open.contains(index),
            let position = blocks.firstIndex(where: { $0.index == index }) else { throw CloudProviderError.invalidResponse }
      if let json = partialJSON[index] {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = text.isEmpty ? [String: Any]()
                : try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
          throw CloudProviderError.invalidResponse
        }
        blocks[position].block["input"] = input
      }
      open.remove(index)
    case "message_stop":
      stopped = true
    case "error":
      throw CloudProviderError.providerMessage(
        (object["error"] as? [String: Any])?["message"] as? String ?? "Anthropic could not complete the response.")
    default:
      break
    }
    return nil
  }

  func finish() throws -> CloudToolLoop.Turn {
    guard open.isEmpty else { throw CloudProviderError.invalidResponse }
    guard stopped else { throw CloudProviderError.streamEndedUnexpectedly }
    return try AnthropicMessagesClient.toolTurn(["content": assistantContent])
  }
}

/// Gemini `streamGenerateContent`: each event is a whole response chunk whose parts are merged
/// into the content a non-streamed response would have returned. Calls arrive whole.
struct GeminiToolStreamAssembler: ToolStreamAssembler {
  private var content: [String: Any]?
  private var parts: [[String: Any]] = []
  private var finishReason: String?

  /// The model content as the whole-response path appended it, with thought signatures.
  var modelContent: [String: Any]? {
    guard var content else { return nil }
    content["parts"] = parts
    return content
  }

  mutating func consume(_ event: ServerSentEvent) throws -> String? {
    let object = try eventObject(event)
    if let error = object["error"] as? [String: Any] {
      throw CloudProviderError.providerMessage(error["message"] as? String ?? "Gemini request failed.")
    }
    guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
      if object["promptFeedback"] != nil { throw CloudProviderError.providerMessage("Gemini could not analyze this request.") }
      return nil
    }
    var text: String?
    if let chunk = candidate["content"] as? [String: Any] {
      content = (content ?? [:]).merging(chunk) { $1 }
      for part in chunk["parts"] as? [[String: Any]] ?? [] {
        if part["thought"] as? Bool != true, let delta = part["text"] as? String, !delta.isEmpty { text = (text ?? "") + delta }
        append(part)
      }
    }
    if let reason = candidate["finishReason"] as? String { finishReason = reason }
    return text
  }

  /// Text streams as many small parts; a whole response has one, carrying any signature that
  /// streamed on a later (often empty) part.
  private mutating func append(_ part: [String: Any]) {
    if let last = parts.last, let earlier = last["text"] as? String, let later = part["text"] as? String,
       last["thoughtSignature"] == nil, last["functionCall"] == nil, part["functionCall"] == nil,
       (last["thought"] as? Bool ?? false) == (part["thought"] as? Bool ?? false) {
      var merged = last.merging(part) { $1 }
      merged["text"] = earlier + later
      parts[parts.count - 1] = merged
    } else {
      parts.append(part)
    }
  }

  func finish() throws -> CloudToolLoop.Turn {
    guard let finishReason else { throw CloudProviderError.streamEndedUnexpectedly }
    var candidate: [String: Any] = ["finishReason": finishReason]
    candidate["content"] = modelContent
    return try GeminiContentClient.toolTurn(["candidates": [candidate]]).0
  }
}
