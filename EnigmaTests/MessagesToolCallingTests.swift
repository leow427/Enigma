import Combine
import XCTest
@testable import Enigma

/// A toolbox that records calls, so loops are tested without Messages data.
final class RecordingToolbox: AgentToolbox, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(String, CodexValue)] = []
  var calls: [(String, CodexValue)] { lock.withLock { recorded } }
  let instructions = "Use lookup for facts."
  let definitions = [AgentToolDefinition(name: "lookup", description: "Look something up.",
    properties: ["query": .object(["type": .string("string")])], required: ["query"])]

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    lock.withLock { recorded.append((name, arguments)) }
    return AgentToolResult(text: #"{"answer":"42"}"#, success: true)
  }

  func phase(for _: String) -> AssistantActivity.Phase { .readingMessages }
}

/// Waits inside its call until released, then ends the request as a denied permission would.
private final class GatedStoppingToolbox: AgentToolbox, @unchecked Sendable {
  let instructions = "Use lookup for facts."
  let definitions = RecordingToolbox().definitions
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    entered.continuation.yield()
    for await _ in release.stream { break }
    return AgentToolResult(text: MessagesError.automationDenied.localizedDescription, success: false, terminal: true,
      stop: .messages(.automationDenied))
  }
}

/// A toolbox whose every call ends the request, as Messages does when macOS withholds a permission.
final class StoppingToolbox: AgentToolbox, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let error: MessagesError
  var callCount: Int { lock.withLock { count } }
  let instructions = "Use lookup for facts."
  let definitions = RecordingToolbox().definitions

  init(_ error: MessagesError = .automationDenied) { self.error = error }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    lock.withLock { count += 1 }
    return AgentToolResult(text: error.localizedDescription, success: false, terminal: true, stop: .messages(error))
  }
}

private struct ToolTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { "test-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

/// Returns queued responses and records request bodies. A whole JSON response is served as one
/// non-streamed reply, or, to a streaming request, as that provider's server-sent events built from
/// it; a recorded stream (`init(streams:)`) is served as is.
private final class QueuedTransport: CloudNetworkTransport, @unchecked Sendable {
  enum Response {
    case json([String: Any])
    case stream(String)
  }

  private let lock = NSLock()
  private var responses: [Response]
  private(set) var bodies: [[String: Any]] = []
  private(set) var urls: [URL] = []

  init(_ responses: [[String: Any]]) { self.responses = responses.map(Response.json) }
  init(streams: [String]) { self.responses = streams.map(Response.stream) }

  private func next(_ request: URLRequest) throws -> Response {
    try lock.withLock {
      urls.append(request.url!)
      bodies.append(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:])
      return responses.removeFirst()
    }
  }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    guard case .json(let next) = try next(request) else { throw CloudProviderError.invalidResponse }
    return CloudDataResponse(data: try JSONSerialization.data(withJSONObject: next), statusCode: 200)
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { continuation in
      do {
        let text = switch try next(request) {
        case .stream(let text): text
        case .json(let response): try Self.events(for: request.url!, response: response)
        }
        continuation.yield(.response(statusCode: 200))
        continuation.yield(.data(Data(text.utf8)))
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
  }

  /// A whole response as the stream its provider would send for it.
  private static func events(for url: URL, response: [String: Any]) throws -> String {
    func event(_ name: String?, _ object: [String: Any]) throws -> String {
      let data = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      return (name.map { "event: \($0)\n" } ?? "") + "data: \(data)\n\n"
    }
    switch url.host() {
    case "api.anthropic.com":
      var text = try event("message_start", ["type": "message_start", "message": ["role": "assistant", "content": []]])
      for (index, block) in (response["content"] as? [[String: Any]] ?? []).enumerated() {
        var start = block
        var deltas: [[String: Any]] = []
        switch block["type"] as? String {
        case "text":
          start["text"] = ""
          deltas = [["type": "text_delta", "text": block["text"] ?? ""]]
        case "tool_use":
          start["input"] = [String: Any]()
          deltas = [["type": "input_json_delta", "partial_json": CloudToolLoop.jsonString(block["input"] ?? [:])]]
        case "thinking":
          start["thinking"] = ""
          start["signature"] = ""
          deltas = [["type": "thinking_delta", "thinking": block["thinking"] ?? ""],
                    ["type": "signature_delta", "signature": block["signature"] ?? ""]]
        default: break
        }
        text += try event("content_block_start", ["type": "content_block_start", "index": index, "content_block": start])
        for delta in deltas {
          text += try event("content_block_delta", ["type": "content_block_delta", "index": index, "delta": delta])
        }
        text += try event("content_block_stop", ["type": "content_block_stop", "index": index])
      }
      text += try event("message_delta", ["type": "message_delta", "delta": ["stop_reason": response["stop_reason"] ?? "end_turn"]])
      return text + (try event("message_stop", ["type": "message_stop"]))
    case "api.openai.com":
      var text = ""
      let output = response["output"] as? [[String: Any]] ?? []
      for (index, item) in output.enumerated() {
        for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
          text += try event("response.output_text.delta", ["type": "response.output_text.delta", "output_index": index,
            "delta": part["text"] ?? ""])
        }
        text += try event("response.output_item.done", ["type": "response.output_item.done", "output_index": index, "item": item])
      }
      let status = response["status"] as? String ?? "completed"
      return text + (try event("response.\(status)", ["type": "response.\(status)", "response": response]))
    default:
      return try event(nil, response)
    }
  }
}

final class CloudToolLoopTests: XCTestCase {
  private func request(_ provider: CloudProviderID, model: String) -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "What is the answer?")],
      route: Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true))
  }

  private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  func testAnthropicReturnsToolResultsForEachToolUse() async throws {
    let transport = QueuedTransport([
      ["content": [["type": "text", "text": "Checking."],
        ["type": "tool_use", "id": "toolu_1", "name": "lookup", "input": ["query": "answer"]]], "stop_reason": "tool_use"],
      ["content": [["type": "text", "text": "It is 42."]], "stop_reason": "end_turn"],
    ])
    let toolbox = RecordingToolbox()
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: toolbox))
    XCTAssertEqual(events.compactMap { if case .token(let text) = $0 { text } else { nil } }, ["Checking.", "\n\nIt is 42."])
    XCTAssertEqual(events.last, .completed)
    XCTAssertTrue(events.contains(.activity(.phase(.readingMessages))))
    XCTAssertEqual(toolbox.calls.map(\.0), ["lookup"])
    XCTAssertEqual(toolbox.calls.first?.1["query"].string, "answer")
    XCTAssertEqual((transport.bodies[0]["tools"] as? [[String: Any]])?.first?["name"] as? String, "lookup")
    XCTAssertTrue((transport.bodies[0]["system"] as? String)?.contains("Use lookup for facts.") == true)
    let messages = try XCTUnwrap(transport.bodies[1]["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 3)
    let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
    XCTAssertEqual(result["type"] as? String, "tool_result")
    XCTAssertEqual(result["tool_use_id"] as? String, "toolu_1")
    XCTAssertEqual(result["content"] as? String, #"{"answer":"42"}"#)
  }

  func testOpenAIReplaysOutputItemsAndFunctionOutputs() async throws {
    let transport = QueuedTransport([
      ["status": "completed", "output": [
        ["type": "reasoning", "id": "rs_1", "summary": []],
        ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "lookup", "arguments": #"{"query":"answer"}"#, "status": "completed"]]],
      ["status": "completed", "output": [["type": "message", "id": "msg_1", "role": "assistant",
        "content": [["type": "output_text", "text": "42."]]]]],
    ])
    let toolbox = RecordingToolbox()
    let client = OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.openAI, model: "gpt-5.5"), toolbox: toolbox))
    XCTAssertEqual(events.compactMap { if case .token(let text) = $0 { text } else { nil } }, ["42."])
    XCTAssertEqual(toolbox.calls.count, 1)
    XCTAssertEqual((transport.bodies[0]["tools"] as? [[String: Any]])?.first?["type"] as? String, "function")
    XCTAssertEqual(transport.bodies[0]["store"] as? Bool, false)
    let input = try XCTUnwrap(transport.bodies[1]["input"] as? [[String: Any]])
    XCTAssertEqual(input.count, 3, "The question, the call, and its output; reasoning is not replayed")
    XCTAssertEqual(input[0]["role"] as? String, "user")
    XCTAssertEqual(input.dropFirst().compactMap { $0["type"] as? String }, ["function_call", "function_call_output"])
    XCTAssertNil(input[1]["id"], "Unstored item IDs cannot be referenced")
    XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
  }

  func testGeminiReturnsFunctionResponsesAndStripsUnsupportedSchema() async throws {
    let transport = QueuedTransport([
      ["candidates": [["content": ["role": "model", "parts": [
        ["functionCall": ["name": "lookup", "args": ["query": "answer"]], "thoughtSignature": "sig"]]], "finishReason": "STOP"]]],
      ["candidates": [["content": ["role": "model", "parts": [["text": "42"]]], "finishReason": "STOP"]]],
    ])
    let toolbox = RecordingToolbox()
    let client = GeminiContentClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.gemini, model: "gemini-3-flash"), toolbox: toolbox))
    XCTAssertEqual(events.compactMap { if case .token(let text) = $0 { text } else { nil } }, ["42"])
    XCTAssertTrue(transport.urls[0].absoluteString.hasSuffix("gemini-3-flash:streamGenerateContent?alt=sse"))
    let declaration = try XCTUnwrap(((transport.bodies[0]["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])?.first)
    XCTAssertNil((declaration["parameters"] as? [String: Any])?["additionalProperties"])
    let contents = try XCTUnwrap(transport.bodies[1]["contents"] as? [[String: Any]])
    XCTAssertEqual(((contents[1]["parts"] as? [[String: Any]])?.first)?["thoughtSignature"] as? String, "sig")
    let response = try XCTUnwrap(((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"]) as? [String: Any])
    XCTAssertEqual(response["name"] as? String, "lookup")
    XCTAssertEqual((response["response"] as? [String: Any]).flatMap { ($0["result"] as? [String: Any])?["answer"] as? String }, "42")
  }

  func testLoopStopsAtTheStepLimit() async throws {
    let looping: [String: Any] = ["content": [["type": "tool_use", "id": "t", "name": "lookup", "input": ["query": "x"]]]]
    let transport = QueuedTransport(Array(repeating: looping, count: CloudToolLoop.maximumSteps))
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    do {
      _ = try await collect(client.stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: RecordingToolbox()))
      XCTFail("Expected the step limit")
    } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit) }
  }

  func testTerminalResultEndsTheLoopWithItsError() async throws {
    let toolbox = StoppingToolbox()
    var steps = 0
    var deliveries = 0
    do {
      try await CloudToolLoop.run(toolbox: toolbox, emit: { _ in }, step: {
        steps += 1
        return .init(text: "", calls: [.init(id: "1", name: "lookup", arguments: #"{"query":"a"}"#),
                                       .init(id: "2", name: "lookup", arguments: #"{"query":"b"}"#)])
      }, deliver: { _ in deliveries += 1 })
      XCTFail("Expected the request to stop")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    XCTAssertEqual(steps, 1, "No model turn after the stop")
    XCTAssertEqual(deliveries, 0, "The result never goes back to the model")
    XCTAssertEqual(toolbox.callCount, 1, "The rest of the turn's calls never run")
  }

  func testTerminalResultStopsTheProviderStreamWithTheMessagesError() async throws {
    let calling: [String: Any] = ["content": [["type": "tool_use", "id": "t", "name": "lookup", "input": ["query": "x"]]]]
    // A regression answers with text and fails the assertions below rather than draining the queue.
    let answering: [String: Any] = ["content": [["type": "text", "text": "I couldn't do that."]]]
    let transport = QueuedTransport([calling, answering])
    let toolbox = StoppingToolbox(.fullDiskAccessRequired)
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    do {
      _ = try await collect(client.stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: toolbox))
      XCTFail("Expected the request to stop")
    } catch { XCTAssertEqual(error as? MessagesError, .fullDiskAccessRequired) }
    XCTAssertEqual(transport.bodies.count, 1, "No model turn after the stop")
    XCTAssertEqual(toolbox.callCount, 1)
  }

  func testCodexTerminalResultInterruptsTheTurnWithTheMessagesError() async throws {
    let transport = ToolCallingCodexTransport()
    let toolbox = StoppingToolbox()
    let client = CodexSubscriptionClient(transport: transport)
    do {
      _ = try await collect(client.stream(request(.chatGPT, model: "gpt-5.6-luna"), toolbox: toolbox))
      XCTFail("Expected the request to stop")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await !transport.methods.contains("turn/interrupt"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let methods = await transport.methods
    XCTAssertTrue(methods.contains("turn/interrupt"), "The Codex turn must be interrupted")
    XCTAssertEqual(toolbox.callCount, 1, "A retried call must not run the tool again")
  }

  func testCodexToolModeRunsNoCallAfterATerminalResult() async {
    let toolbox = StoppingToolbox()
    let stop = CodexToolMode.Stop()
    let call = CodexValue.object(["tool": .string("lookup"), "turnId": .string("turn"), "callId": .string("call"),
      "arguments": .object(["query": .string("q")])])
    let first = await CodexToolMode.handle(method: "item/tool/call", params: call, toolbox: toolbox, stop: stop)
    XCTAssertEqual(first["success"].bool, false)
    XCTAssertEqual(stop.error as? MessagesError, .automationDenied)
    let retried = await CodexToolMode.handle(method: "item/tool/call", params: call, toolbox: toolbox, stop: stop)
    XCTAssertEqual(retried["success"].bool, false)
    XCTAssertEqual(toolbox.callCount, 1, "The retried call is refused without running the tool")
  }

  func testCodexToolResultsGoBackToTheModelUntilTheTurnCompletes() async throws {
    let transport = ToolCallingCodexTransport()
    let toolbox = RecordingToolbox()
    let events = try await collect(CodexSubscriptionClient(transport: transport)
      .stream(request(.chatGPT, model: "gpt-5.6-luna"), toolbox: toolbox))
    XCTAssertEqual(events.last, .completed)
    XCTAssertEqual(toolbox.calls.count, 2, "Each call runs and goes back to the model")
    let methods = await transport.methods
    XCTAssertFalse(methods.contains("turn/interrupt"))
  }

  func testCodexDoesNotRecordACancelledCall() async {
    let stop = CodexToolMode.Stop()
    let call = CodexValue.object(["tool": .string("lookup"), "turnId": .string("turn"), "callId": .string("call"),
      "arguments": .object(["query": .string("q")])])
    _ = await CodexToolMode.handle(method: "item/tool/call", params: call, toolbox: CancelledResultToolbox(), stop: stop)
    XCTAssertFalse(stop.isStopped, "Only a permission stop ends the Codex turn")
    XCTAssertNil(stop.error)
  }

  func testCodexToolModeIsolatesTheThread() throws {
    let toolbox = RecordingToolbox()
    let thread = try CodexToolMode.threadParameters(model: "gpt-5.6-luna", toolbox: toolbox)
    XCTAssertEqual(thread["environments"], .array([]))
    XCTAssertEqual(thread["sandbox"].string, "read-only")
    XCTAssertEqual(thread["dynamicTools"].array?.first?["name"].string, "lookup")
    XCTAssertEqual(thread["config"]["features.shell_tool"], .bool(false))
    let turn = try CodexSubscriptionClient.turnParameters(threadID: "t", request: request(.chatGPT, model: "m"), isolatedTools: true)
    XCTAssertEqual(turn["sandboxPolicy"]["type"].string, "readOnly")
    XCTAssertEqual(turn["environments"], .array([]))
  }

  func testCodexToolModeDeclinesNativeApprovalsAndRunsOnlyHostTools() async {
    let toolbox = RecordingToolbox()
    let declined = await CodexToolMode.handle(method: "item/commandExecution/requestApproval", params: .object([:]), toolbox: toolbox)
    XCTAssertEqual(declined["decision"].string, "decline")
    let result = await CodexToolMode.handle(method: "item/tool/call", params: .object([
      "tool": .string("lookup"), "turnId": .string("turn"), "callId": .string("call"),
      "arguments": .object(["query": .string("q")])]), toolbox: toolbox)
    XCTAssertEqual(result["success"].bool, true)
    XCTAssertEqual(toolbox.calls.count, 1)
  }
}

/// Calls the host tool twice per turn, as a model that retries would, until the turn is interrupted.
private actor ToolCallingCodexTransport: CodexRPCTransport {
  private var handler: CodexServerRequestHandler?
  private var observers: [UUID: AsyncThrowingStream<CodexNotification, Error>.Continuation] = [:]
  private var interrupted = false
  private(set) var methods: [String] = []

  func request(_ method: String, params: CodexValue) async throws -> CodexValue {
    methods.append(method)
    switch method {
    case "account/read": return .object(["account": .object(["type": .string("chatgpt"), "planType": .string("plus")])])
    case "thread/start": return .object(["thread": .object(["id": .string("thread-one")])])
    case "turn/start":
      Task { await runTurn() }
      return .object(["turn": .object(["id": .string("turn-one")])])
    case "turn/interrupt":
      interrupted = true
      emit(completion("interrupted"))
      return .object([:])
    default: return .object([:])
    }
  }

  func prepareFileMode() async throws {}
  func setFileHandler(threadID: String, handler: CodexServerRequestHandler?) async throws { self.handler = handler }

  func notifications() -> CodexNotificationSubscription {
    let id = UUID()
    let stream = AsyncThrowingStream<CodexNotification, Error> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    }
    return CodexNotificationSubscription(stream: stream, cancel: { [weak self] in await self?.removeObserver(id) })
  }

  private func runTurn() async {
    let call = CodexValue.object(["threadId": .string("thread-one"), "turnId": .string("turn-one"),
      "callId": .string("call"), "tool": .string("lookup"), "arguments": .object(["query": .string("x")])])
    for _ in 0..<2 {
      guard !interrupted, let handler else { return }
      _ = await handler("item/tool/call", call)
    }
    if !interrupted { emit(completion("completed")) }
  }

  private func completion(_ status: String) -> CodexNotification {
    CodexNotification(method: "turn/completed", params: .object([
      "threadId": .string("thread-one"), "turn": .object(["id": .string("turn-one"), "status": .string(status)])]))
  }

  private func emit(_ notification: CodexNotification) {
    for continuation in observers.values { continuation.yield(notification) }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
}

final class ClaudeCodeToolModeTests: XCTestCase {
  func testArgumentsAllowOnlyEnigmaToolsWithBuiltInsDisabled() {
    let arguments = ClaudeCodeRuntime.toolArguments(model: "sonnet", effort: .automatic, toolbox: RecordingToolbox())
    XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
    XCTAssertEqual(arguments[arguments.firstIndex(of: "--allowedTools")! + 1], "mcp__enigma__lookup")
    XCTAssertTrue(arguments.contains("--strict-mcp-config"))
    XCTAssertTrue(arguments[arguments.firstIndex(of: "--mcp-config")! + 1].contains(#""type":"sdk""#))
    XCTAssertTrue(arguments[arguments.firstIndex(of: "--system-prompt")! + 1].contains("Use lookup for facts."))
  }

  func testServesMCPInitializeListAndCall() async throws {
    let toolbox = RecordingToolbox()
    let initialize = try await ClaudeCodeToolMode.respond(to: .object(["jsonrpc": .string("2.0"), "id": .number(0),
      "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25")])]), toolbox: toolbox)
    XCTAssertEqual(initialize["result"]["protocolVersion"].string, "2025-11-25")
    let list = try await ClaudeCodeToolMode.respond(to: .object(["id": .number(1), "method": .string("tools/list")]), toolbox: toolbox)
    XCTAssertEqual(list["result"]["tools"].array?.first?["inputSchema"]["required"], .array([.string("query")]))
    var called: [String] = []
    let call = try await ClaudeCodeToolMode.respond(to: .object(["id": .number(2), "method": .string("tools/call"),
      "params": .object(["name": .string("lookup"), "arguments": .object(["query": .string("x")])])]), toolbox: toolbox) {
      called.append($0)
    }
    XCTAssertEqual(called, ["lookup"])
    XCTAssertEqual(call["result"]["isError"], .bool(false))
    XCTAssertEqual(call["result"]["content"].array?.first?["text"].string, #"{"answer":"42"}"#)
    let unknown = try await ClaudeCodeToolMode.respond(to: .object(["id": .number(3), "method": .string("resources/list")]), toolbox: toolbox)
    XCTAssertEqual(unknown["error"]["code"].integer, -32601)
  }

  func testControlRequestsForOtherServersOrPermissionsAreRefused() async throws {
    let toolbox = RecordingToolbox()
    let other = try await ClaudeCodeToolMode.controlResponse(id: "r1", request: .object([
      "subtype": .string("mcp_message"), "server_name": .string("other"), "message": .object([:])]), toolbox: toolbox)
    XCTAssertEqual(other["response"]["subtype"].string, "error")
    let permission = try await ClaudeCodeToolMode.controlResponse(id: "r2", request: .object(["subtype": .string("can_use_tool")]), toolbox: toolbox)
    XCTAssertEqual(permission["response"]["response"]["behavior"].string, "deny")
    var parser = ClaudeCodeStreamParser()
    let events = try parser.consume(Data(#"{"type":"control_request","request_id":"req","request":{"subtype":"mcp_message"}}"#.utf8 + [0x0a]))
    XCTAssertEqual(events, [.controlRequest(id: "req", request: .object(["subtype": .string("mcp_message")]))])
  }
}

private actor ScriptedToolInference: LocalToolInference {
  private(set) var requests: [[AgentInferenceMessage]] = []
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    requests.append(messages)
    if requests.count == 1 {
      return AgentInferenceMessage(role: "assistant", content: "ignored", toolCalls: [
        AgentToolCall(id: "a", function: .init(name: "list_conversations", arguments: #"{"limit":2}"#)),
        AgentToolCall(id: "b", function: .init(name: "send_message", arguments: #"{"recipient":"x","text":"y"}"#)),
      ])
    }
    return AgentInferenceMessage(role: "assistant", content: "Your latest chat is Weekend Trip.")
  }
}

/// A model that keeps calling a tool, so a request ends only when the loop stops it.
private actor RepeatingToolInference: LocalToolInference {
  let name: String
  let arguments: String
  private(set) var requests = 0
  init(name: String = "lookup", arguments: String = #"{"query":"x"}"#) { self.name = name; self.arguments = arguments }
  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    requests += 1
    return AgentInferenceMessage(role: "assistant", content: nil, toolCalls: [
      AgentToolCall(id: "call", function: .init(name: name, arguments: arguments))])
  }
}

/// Waits inside `unload()` until released, which the local route awaits after its loop ends.
private actor GatedUnloadInference: LocalToolInference {
  nonisolated let unloading = AsyncStream<Void>.makeStream()
  nonisolated let release = AsyncStream<Void>.makeStream()

  func unload() async {
    unloading.continuation.yield()
    for await _ in release.stream { break }
  }

  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    AgentInferenceMessage(role: "assistant", content: nil, toolCalls: [
      AgentToolCall(id: "call", function: .init(name: "lookup", arguments: #"{"query":"x"}"#))])
  }
}

/// Returns the result a stopped Messages call gives.
private final class CancelledResultToolbox: AgentToolbox, @unchecked Sendable {
  let instructions = "Use lookup for facts."
  let definitions = RecordingToolbox().definitions

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    AgentToolResult(text: "The request was stopped.", success: false, terminal: true, stop: .cancelled)
  }
}

private actor MessagesTestEngine: LocalModelEngine {
  let model = LocalModel(id: "test", displayName: "Test local model", fileURL: URL(fileURLWithPath: "/tmp/model.gguf"))
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel { self.model }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.yield("Normal chat"); $0.finish() }
  }
  func unload() async {}
}

@MainActor
final class MessagesRequestTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("MessagesRequestTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testLocalAgentRunsOneCallPerStepWithMessagesTools() async throws {
    let database = MessagesDatabase(url: try MessagesFixture(directory: root).url)
    let inference = ScriptedToolInference()
    let runner = RecordingRunner()
    let tools = MessagesTools(database: database, contacts: FixtureContacts(), sender: MessagesSender(run: runner.run),
      confirmSend: { _ in XCTFail("The discarded batch call must not reach approval"); return false })
    let collected = LockedText()
    try await LocalToolAgent(inference: inference).run(messages: [ChatMessage(role: .user, content: "Who texted last?")],
      model: LocalModel(id: "m", displayName: "M", fileURL: root.appendingPathComponent("m.gguf")), toolbox: tools) {
      collected.append($0)
    }
    XCTAssertEqual(collected.value, "Your latest chat is Weekend Trip.")
    let requests = await inference.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0][0].content?.contains("untrusted data") == true)
    XCTAssertEqual(requests[1].count, 4, "system, user, one assistant call, one tool result")
    XCTAssertEqual(requests[1][2].toolCalls?.map(\.function.name), ["list_conversations"])
    XCTAssertTrue(requests[1][3].content?.contains("Weekend Trip") == true)
    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testPreflightReportsFullDiskAccessWithoutStartingARequest() async throws {
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesAccess: { throw MessagesError.fullDiskAccessRequired },
      localToolRuntime: { _ in true }, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Who texted me?", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    XCTAssertEqual(chat.appleMessages.issue?.pane, .fullDiskAccess)
    XCTAssertNil(chat.activeRequest)
    XCTAssertTrue(chat.messages.isEmpty)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testAutoKeepsMessagesLocalAndExplainsMissingRuntime() async throws {
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesAccess: {}, localToolRuntime: { _ in false },
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Who texted me?", mode: .auto, cloudProvider: .anthropic, cloudModelID: "claude-sonnet-4-6")
    XCTAssertTrue(chat.appleMessages.issue?.message.contains("llama-server") == true)
    XCTAssertNil(chat.activeRequest, "Auto never falls back to the cloud for Messages")
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testLocalRequestAnswersWithMessagesTools() async throws {
    let inference = ScriptedToolInference()
    let toolbox = RecordingToolbox()
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in toolbox }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileInference: inference, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    let finished = expectation(description: "Messages request finished")
    let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
    chat.submitMessages("Who texted me last?", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    XCTAssertEqual(chat.activeRequest?.route.mode, .local)
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
    XCTAssertEqual(chat.messages.map(\.content), ["Who texted me last?", "Your latest chat is Weekend Trip."])
    XCTAssertEqual(toolbox.calls.map(\.0), ["list_conversations"])
    XCTAssertNil(chat.appleMessages.pendingSend)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testAutomationDenialEndsTheLocalLoopWithoutRetrying() async throws {
    let database = MessagesDatabase(url: try MessagesFixture(directory: root).url)
    let inference = RepeatingToolInference(name: "send_message",
      arguments: #"{"recipient":"\#(MessagesFixture.aliceChat)","text":"hi"}"#)
    let runner = RecordingRunner()
    runner.result = ProcessOutput(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Messages. (-1743)")
    var tools = MessagesTools(database: database, contacts: FixtureContacts(), sender: MessagesSender(run: runner.run),
      confirmSend: { _ in true })
    tools.sendConfirmationTimeout = .zero
    do {
      try await LocalToolAgent(inference: inference).run(messages: [ChatMessage(role: .user, content: "Text Alice hi")],
        model: LocalModel(id: "m", displayName: "M", fileURL: root.appendingPathComponent("m.gguf")), toolbox: tools) { _ in }
      XCTFail("Expected the request to stop")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    let requests = await inference.requests
    XCTAssertEqual(requests, 1, "No model step after the denial")
    XCTAssertEqual(runner.invocations.count, 1, "osascript must not run again")
  }

  func testAutomationDenialDuringARequestShowsTheSettingsCard() async throws {
    let toolbox = StoppingToolbox(.automationDenied)
    let inference = RepeatingToolInference()
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in toolbox }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileInference: inference, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    XCTAssertEqual(chat.appleMessages.issue?.pane, .automation)
    XCTAssertTrue(chat.appleMessages.issue?.message.contains("Automation") == true)
    XCTAssertEqual(toolbox.callCount, 1)
    let requests = await inference.requests
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(chat.state, .idle, "The card explains the problem; the status line doesn't repeat it")
    XCTAssertEqual(chat.messages.last?.role, .assistant)
    XCTAssertEqual(chat.messages.last?.activity?.phase, .failed, "The reply reads Request failed rather than staying empty")
    await chat.sessionWriter.waitForPendingWrites()
  }

  private func waitForTheRequestToFinish(_ chat: LocalChatViewModel) async {
    let finished = expectation(description: "Messages request finished")
    let token = chat.$state.dropFirst().filter { _ in chat.activeRequest == nil }.prefix(1).sink { _ in finished.fulfill() }
    await fulfillment(of: [finished], timeout: 3)
    token.cancel()
  }

  func testAutomationDenialOnTheAnthropicRouteShowsTheSettingsCard() async throws {
    let calling: [String: Any] = ["content": [["type": "tool_use", "id": "t", "name": "lookup", "input": ["query": "x"]]]]
    let answering: [String: Any] = ["content": [["type": "text", "text": "I couldn't send that."]]]
    let transport = QueuedTransport([calling, answering])
    let toolbox = StoppingToolbox(.automationDenied)
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in toolbox }, messagesAccess: {},
      localToolRuntime: { _ in true },
      cloudProviders: CloudProviderRegistry(credentialStore: ToolTestCredentials(), transport: transport),
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Text Alice hi", mode: .cloud, cloudProvider: .anthropic, cloudModelID: "claude-sonnet-4-6")
    await waitForTheRequestToFinish(chat)
    XCTAssertEqual(chat.appleMessages.issue?.pane, .automation)
    XCTAssertEqual(transport.bodies.count, 1, "No model turn after the denial")
    XCTAssertEqual(toolbox.callCount, 1)
    XCTAssertEqual(chat.state, .idle)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testFullDiskAccessLostOnTheCodexRouteShowsTheSettingsCard() async throws {
    let toolbox = StoppingToolbox(.fullDiskAccessRequired)
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in toolbox }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileCodex: CodexSubscriptionClient(transport: ToolCallingCodexTransport()),
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Who texted me?", mode: .cloud, cloudProvider: .chatGPT, cloudModelID: "gpt-5.6-luna")
    await waitForTheRequestToFinish(chat)
    XCTAssertEqual(chat.appleMessages.issue?.pane, .fullDiskAccess)
    XCTAssertEqual(toolbox.callCount, 1)
    XCTAssertEqual(chat.state, .idle)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testStopDuringADeniedSendShowsNoCard() async throws {
    let toolbox = GatedStoppingToolbox()
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in toolbox }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileInference: RepeatingToolInference(),
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    var entered = toolbox.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    let task = chat.stopStreaming()
    toolbox.release.continuation.yield()
    await task?.value
    XCTAssertNil(chat.appleMessages.issue, "Stop must not show the settings card")
    XCTAssertEqual(chat.state, .idle)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testNewChatWhileUnloadingAfterADenialShowsNoCard() async throws {
    let inference = GatedUnloadInference()
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in StoppingToolbox() }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileInference: inference, sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    // The loop has already thrown the denial; the request is unloading the model.
    var unloading = inference.unloading.stream.makeAsyncIterator()
    _ = await unloading.next()
    let task = chat.stopStreaming()
    chat.newChat()
    inference.release.continuation.yield()
    await task?.value
    XCTAssertNil(chat.appleMessages.issue, "A new chat opened while the model unloads must not get the old card")
    XCTAssertEqual(chat.state, .idle)
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testNewChatOrAnotherChatClearsTheSettingsCard() async throws {
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let other = ChatSession(messages: [ChatMessage(role: .user, content: "Another chat")])
    try store.save([other])
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in StoppingToolbox() },
      messagesAccess: {}, localToolRuntime: { _ in true }, fileInference: RepeatingToolInference(),
      sessionStore: store)
    await chat.refreshInstalledModel()
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    let deniedChat = try XCTUnwrap(chat.selectedSessionID)
    XCTAssertEqual(chat.appleMessages.issue?.pane, .automation)
    chat.newChat()
    XCTAssertNil(chat.appleMessages.issue, "A new chat starts without the card")
    XCTAssertNil(chat.selectedSessionID)
    let freshChat = other.id

    chat.selectSession(id: deniedChat)
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    XCTAssertNotNil(chat.appleMessages.issue)
    chat.selectSession(id: freshChat)
    XCTAssertNil(chat.appleMessages.issue, "Switching chats clears the card")

    chat.selectSession(id: deniedChat)
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    XCTAssertNotNil(chat.appleMessages.issue)
    chat.cycleRecentChat()
    XCTAssertNotEqual(chat.selectedSessionID, deniedChat)
    XCTAssertNil(chat.appleMessages.issue, "Cycling to another chat clears the card")

    chat.selectSession(id: deniedChat)
    chat.submitMessages("Text Alice hi", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    XCTAssertNotNil(chat.appleMessages.issue)
    chat.startTemporaryChat(context: nil)
    XCTAssertNil(chat.appleMessages.issue, "A selection chat starts without the previous chat's card")
    await chat.sessionWriter.waitForPendingWrites()
  }

  func testFollowUpFlagStaysWithTheChatThatUsedMessages() async throws {
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in RecordingToolbox() },
      messagesAccess: {}, localToolRuntime: { _ in true }, fileInference: ScriptedToolInference(),
      sessionStore: .init(applicationSupportDirectory: root))
    await chat.refreshInstalledModel()
    func finish() async {
      let finished = expectation(description: "Request finished")
      let token = chat.$state.filter { $0 == .idle && chat.activeRequest == nil }.prefix(1).sink { _ in finished.fulfill() }
      await fulfillment(of: [finished], timeout: 3)
      token.cancel()
    }
    XCTAssertFalse(chat.previousTurnUsedMessages)
    chat.submitMessages("Who texted me last?", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    XCTAssertTrue(chat.previousTurnUsedMessages, "Set when the Messages request is accepted")
    await finish()
    let messagesChat = try XCTUnwrap(chat.selectedSessionID)

    chat.newChat()
    XCTAssertFalse(chat.previousTurnUsedMessages, "A new chat starts without it")
    chat.selectSession(id: messagesChat)
    XCTAssertFalse(chat.previousTurnUsedMessages, "Switching chats clears it")

    chat.submitMessages("Who texted me last?", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await finish()
    XCTAssertTrue(chat.previousTurnUsedMessages)
    chat.submit("Explain binary trees")
    await finish()
    XCTAssertFalse(chat.previousTurnUsedMessages, "An ordinary request clears it")
    await chat.sessionWriter.waitForPendingWrites()
  }
}

final class LockedText: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  var value: String { lock.withLock { text } }
  func append(_ fragment: String) { lock.withLock { text += fragment } }
}

/// Requires one tool on the first step, as `/search` will.
private struct RequiringToolbox: AgentToolbox {
  let base = RecordingToolbox()
  var instructions: String { base.instructions }
  var definitions: [AgentToolDefinition] { base.definitions }
  var requiredTool: String? { "lookup" }
  func execute(name: String, arguments: CodexValue) async -> AgentToolResult { await base.execute(name: name, arguments: arguments) }
}

/// Requires a tool it doesn't offer, as `/search` would without a search key.
private struct UnofferedRequirementToolbox: AgentToolbox {
  let base = RecordingToolbox()
  var instructions: String { base.instructions }
  var definitions: [AgentToolDefinition] { base.definitions }
  var requiredTool: String? { "web_search" }
  func execute(name: String, arguments: CodexValue) async -> AgentToolResult { await base.execute(name: name, arguments: arguments) }
}

/// The streaming tool loops (F32 CP2).
extension CloudToolLoopTests {
  private func tokens(_ events: [ChatEvent]) -> [String] {
    events.compactMap { if case .token(let text) = $0 { text } else { nil } }
  }

  func testTextIsEmittedBeforeTheStepEnds() async throws {
    let toolbox = RecordingToolbox()
    var events: [ChatEvent] = []
    var seenBeforeReturn: [ChatEvent] = []
    var step = 0
    try await CloudToolLoop.run(toolbox: toolbox, emit: { events.append($0) }, step: { _, onText in
      step += 1
      guard step == 1 else { return .init(text: "", calls: []) }
      onText("Checking")
      onText(" now.")
      seenBeforeReturn = events
      XCTAssertTrue(toolbox.calls.isEmpty, "The call runs only after the step ends")
      return .init(text: "Checking now.", calls: [.init(id: "1", name: "lookup", arguments: #"{"query":"a"}"#)])
    }, deliver: { _ in })
    XCTAssertEqual(seenBeforeReturn, [.token("Checking"), .token(" now.")])
    XCTAssertEqual(toolbox.calls.count, 1)
    XCTAssertEqual(tokens(events), ["Checking", " now."], "Streamed text isn't emitted again when the step returns")
    XCTAssertEqual(events.last, .completed)
  }

  func testStreamedTextKeepsTodaysTrimmingAndBlankLineBetweenSteps() async throws {
    var events: [ChatEvent] = []
    var step = 0
    try await CloudToolLoop.run(toolbox: RecordingToolbox(), emit: { events.append($0) }, step: { _, onText in
      step += 1
      if step == 1 {
        for delta in ["\n ", "Checking", " ", "\n"] { onText(delta) }
        return .init(text: "", calls: [.init(id: "1", name: "lookup", arguments: "{}")])
      }
      if step == 2 {
        onText("  ")
        return .init(text: "", calls: [.init(id: "2", name: "lookup", arguments: "{}")])
      }
      for delta in [" ", "It is", " ", "42.", " \n"] { onText(delta) }
      return .init(text: "", calls: [])
    }, deliver: { _ in })
    XCTAssertEqual(tokens(events).joined(), "Checking\n\nIt is 42.", "As today's loop printed the trimmed steps")
    XCTAssertEqual(tokens(events), ["Checking", "\n\nIt is", " 42."])
  }

  func testFirstStepIsFlagged() async throws {
    var flags: [Bool] = []
    try await CloudToolLoop.run(toolbox: RecordingToolbox(), emit: { _ in }, step: { isFirst, _ in
      flags.append(isFirst)
      return .init(text: "", calls: flags.count < 3 ? [.init(id: "\(flags.count)", name: "lookup", arguments: "{}")] : [])
    }, deliver: { _ in })
    XCTAssertEqual(flags, [true, false, false])
  }

  func testOpenAIToolLoopStreams() async throws {
    let transport = QueuedTransport(streams: [try F32Fixture.text("openai", "text-then-call"), try F32Fixture.text("openai", "text")])
    let toolbox = RecordingToolbox()
    let client = OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.openAI, model: "gpt-5.5"), toolbox: toolbox))
    XCTAssertEqual(tokens(events), ["Let me", " check the", " weather in Paris.", "\n\nHello", " there", ", nice", " to meet", " you!"])
    XCTAssertEqual(events.last, .completed)
    XCTAssertEqual(toolbox.calls.map(\.0), ["get_weather"])
    XCTAssertEqual(toolbox.calls.first?.1["city"].string, "Paris")
    XCTAssertEqual(transport.bodies.map { $0["stream"] as? Bool }, [true, true])
    XCTAssertEqual(transport.bodies[0]["parallel_tool_calls"] as? Bool, false)
    let input = try XCTUnwrap(transport.bodies[1]["input"] as? [[String: Any]])
    XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["message", "function_call", "function_call_output"])
    XCTAssertNil(input[2]["id"], "Unstored item IDs cannot be referenced")
    XCTAssertNil(input[2]["status"])
    XCTAssertEqual(input[2]["call_id"] as? String, "call-0")
    XCTAssertEqual(input[2]["arguments"] as? String, #"{"city":"Paris"}"#)
    XCTAssertEqual(input[3]["call_id"] as? String, "call-0")
  }

  func testAnthropicToolLoopStreams() async throws {
    let transport = QueuedTransport(streams: [try F32Fixture.text("anthropic", "thinking-call"), try F32Fixture.text("anthropic", "text")])
    let toolbox = RecordingToolbox()
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: toolbox))
    XCTAssertEqual(tokens(events), ["Hello there", ", fri", "end", ",", " n", "ice day!"])
    XCTAssertEqual(toolbox.calls.map(\.0), ["get_weather"])
    XCTAssertEqual(transport.bodies.map { $0["stream"] as? Bool }, [true, true])
    let messages = try XCTUnwrap(transport.bodies[1]["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 3)
    let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
    XCTAssertEqual(assistant.first?["signature"] as? String, "EqQBCgIYAhIMSynthesizedSignatureForTests0000==",
      "Thinking goes back with its signature")
    XCTAssertEqual((assistant.last?["input"] as? [String: Any])?["city"] as? String, "Paris")
    let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
    XCTAssertEqual(result["tool_use_id"] as? String, "toolu-0")
  }

  func testGeminiToolLoopStreams() async throws {
    let transport = QueuedTransport(streams: [try F32Fixture.text("gemini", "text-then-call"), try F32Fixture.text("gemini", "text")])
    let toolbox = RecordingToolbox()
    let client = GeminiContentClient(credentialStore: ToolTestCredentials(), transport: transport)
    let events = try await collect(client.stream(request(.gemini, model: "gemini-2.5-flash"), toolbox: toolbox))
    XCTAssertEqual(tokens(events), ["Let me check the weather in Paris.", "\n\nHello there,", " nice to meet you!"])
    XCTAssertEqual(toolbox.calls.map(\.0), ["get_weather"])
    XCTAssertEqual(transport.urls.map { $0.absoluteString.hasSuffix("gemini-2.5-flash:streamGenerateContent?alt=sse") }, [true, true])
    let contents = try XCTUnwrap(transport.bodies[1]["contents"] as? [[String: Any]])
    XCTAssertEqual(contents.count, 3)
    let parts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.first?["text"] as? String, "Let me check the weather in Paris.")
    XCTAssertEqual(parts.last?["thoughtSignature"] as? String, "CiQBSynthesizedThoughtSignatureForTests0000")
    let response = try XCTUnwrap((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])
    XCTAssertEqual(response["name"] as? String, "get_weather")
    XCTAssertNil(response["id"], "Synthesized call IDs aren't sent back")
  }

  func testStreamCutMidCallRunsNothingOnEveryProvider() async throws {
    let routes: [(CloudProviderID, String, String, (QueuedTransport) -> any ToolCallingChatProvider)] = [
      (.openAI, "gpt-5.5", "openai", { OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: $0) }),
      (.anthropic, "claude-sonnet-4-6", "anthropic", { AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: $0) }),
      (.gemini, "gemini-2.5-flash", "gemini", { GeminiContentClient(credentialStore: ToolTestCredentials(), transport: $0) }),
    ]
    for (provider, model, folder, client) in routes {
      let transport = QueuedTransport(streams: [try F32Fixture.text(folder, "cut-mid-call")])
      let toolbox = RecordingToolbox()
      do {
        _ = try await collect(client(transport).stream(request(provider, model: model), toolbox: toolbox))
        XCTFail("\(folder): expected the request to fail")
      } catch { XCTAssertEqual(error as? CloudProviderError, .invalidResponse, folder) }
      XCTAssertTrue(toolbox.calls.isEmpty, "\(folder): a half-built call never runs")
    }
  }

  func testRequiredToolIsSentOnFirstStepOnlyOnOpenAI() async throws {
    let transport = QueuedTransport([
      ["status": "completed", "output": [["type": "function_call", "call_id": "c", "name": "lookup", "arguments": "{}"]]],
      ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "42."]]]]],
    ])
    let client = OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    _ = try await collect(client.stream(request(.openAI, model: "gpt-5.5"), toolbox: RequiringToolbox()))
    XCTAssertEqual(transport.bodies[0]["tool_choice"] as? [String: String], ["type": "function", "name": "lookup"])
    XCTAssertNil(transport.bodies[1]["tool_choice"])
  }

  func testRequiredToolIsSentOnFirstStepOnlyOnAnthropic() async throws {
    let transport = QueuedTransport([
      ["content": [["type": "tool_use", "id": "t", "name": "lookup", "input": ["query": "x"]]], "stop_reason": "tool_use"],
      ["content": [["type": "text", "text": "42."]]],
    ])
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    _ = try await collect(client.stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: RequiringToolbox()))
    XCTAssertEqual(transport.bodies[0]["tool_choice"] as? [String: String], ["type": "tool", "name": "lookup"])
    XCTAssertNil(transport.bodies[1]["tool_choice"])
  }

  func testRequiredToolIsNotForcedWithAnthropicExtendedThinking() async throws {
    let transport = QueuedTransport([["content": [["type": "text", "text": "42."]]]])
    let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let thinking = ChatRequest(sessionID: UUID(), messages: [ThinkCommand.message("/think What is the answer?")],
      route: Route(mode: .cloud, providerID: CloudProviderID.anthropic.rawValue, modelID: "claude-sonnet-4-6", usesNetwork: true))
    _ = try await collect(client.stream(thinking, toolbox: RequiringToolbox()))
    XCTAssertNotNil(transport.bodies[0]["thinking"])
    XCTAssertNil(transport.bodies[0]["tool_choice"], "Anthropic allows only auto tool choice with extended thinking")
  }

  func testRequiredToolIsSentOnFirstStepOnlyOnGemini() async throws {
    let transport = QueuedTransport([
      ["candidates": [["content": ["role": "model", "parts": [["functionCall": ["name": "lookup", "args": [:]]]]], "finishReason": "STOP"]]],
      ["candidates": [["content": ["role": "model", "parts": [["text": "42"]]], "finishReason": "STOP"]]],
    ])
    let client = GeminiContentClient(credentialStore: ToolTestCredentials(), transport: transport)
    _ = try await collect(client.stream(request(.gemini, model: "gemini-3-flash"), toolbox: RequiringToolbox()))
    let config = try XCTUnwrap((transport.bodies[0]["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])
    XCTAssertEqual(config["mode"] as? String, "ANY")
    XCTAssertEqual(config["allowedFunctionNames"] as? [String], ["lookup"])
    XCTAssertNil(transport.bodies[1]["toolConfig"])
  }

  func testARequiredToolTheToolboxDoesNotOfferIsNeverForced() async throws {
    XCTAssertNil(UnofferedRequirementToolbox().offeredRequiredTool)
    let openAI = QueuedTransport([["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "42."]]]]]])
    _ = try await collect(OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: openAI)
      .stream(request(.openAI, model: "gpt-5.5"), toolbox: UnofferedRequirementToolbox()))
    XCTAssertNil(openAI.bodies[0]["tool_choice"])
    let anthropic = QueuedTransport([["content": [["type": "text", "text": "42."]]]])
    _ = try await collect(AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: anthropic)
      .stream(request(.anthropic, model: "claude-sonnet-4-6"), toolbox: UnofferedRequirementToolbox()))
    XCTAssertNil(anthropic.bodies[0]["tool_choice"])
    let gemini = QueuedTransport([["candidates": [["content": ["role": "model", "parts": [["text": "42"]]], "finishReason": "STOP"]]]])
    _ = try await collect(GeminiContentClient(credentialStore: ToolTestCredentials(), transport: gemini)
      .stream(request(.gemini, model: "gemini-3-flash"), toolbox: UnofferedRequirementToolbox()))
    XCTAssertNil(gemini.bodies[0]["toolConfig"])
  }

  func testNoToolIsForcedByDefault() async throws {
    let transport = QueuedTransport([["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "42."]]]]]])
    let client = OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    _ = try await collect(client.stream(request(.openAI, model: "gpt-5.5"), toolbox: RecordingToolbox()))
    XCTAssertNil(transport.bodies[0]["tool_choice"])
  }
}
