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

  /// F35 CP0: each API tool loop counts its toolbox's prompt and tools when it trims history.
  func testAPIToolLoopsTrimHistoryWithTheirToolbox() async throws {
    let answers: [(CloudProviderID, String, [String: Any], String)] = [
      (.openAI, "gpt-4.1", ["status": "completed", "output": [["type": "message", "role": "assistant",
        "content": [["type": "output_text", "text": "Done."]]]]], "input"),
      (.anthropic, "claude-sonnet-4-6", ["content": [["type": "text", "text": "Done."]], "stop_reason": "end_turn"], "messages"),
      (.gemini, "gemini-3-flash", ["candidates": [["content": ["role": "model", "parts": [["text": "Done."]]], "finishReason": "STOP"]]], "contents"),
    ]
    for (provider, model, answer, key) in answers {
      let transport = QueuedTransport([answer])
      let request = ChatRequest(sessionID: UUID(), messages: longChat(),
        route: Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true))
      let client: any ToolCallingChatProvider = switch provider {
      case .openAI: OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
      case .anthropic: AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
      default: GeminiContentClient(credentialStore: ToolTestCredentials(), transport: transport)
      }
      _ = try await collect(client.stream(request, toolbox: SampleToolbox()))
      let sent = try XCTUnwrap(transport.bodies.first?[key] as? [[String: Any]], "\(provider)")
      let withTools = try CloudContext.prepare(request, toolbox: SampleToolbox())
      XCTAssertEqual(sent.count, withTools.messages.count, "\(provider)")
      XCTAssertLessThan(sent.count, try CloudContext.prepare(request).messages.count, "\(provider)")
    }
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
  private(set) var requiredTools: [String?] = []

  /// Streams each scripted step's text in two deltas, recording the required tool.
  nonisolated func streamTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel,
                               requiredTool: String?) -> AsyncThrowingStream<LocalToolStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          await self.recordRequiredTool(requiredTool)
          let message = try await self.completeTools(messages: messages, tools: tools, model: model)
          if let content = message.content, !content.isEmpty {
            let middle = content.index(content.startIndex, offsetBy: content.count / 2)
            continuation.yield(.text(String(content[..<middle])))
            continuation.yield(.text(String(content[middle...])))
          }
          continuation.yield(.message(message))
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func recordRequiredTool(_ name: String?) { requiredTools.append(name) }

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

  /// F35 CP1: a long chat drops older turns, so its tools stay offered for the whole turn.
  func testLocalMessagesRequestTrimsALongChat() async throws {
    let sessionStore = ChatSessionStore(applicationSupportDirectory: root)
    var saved = ChatSession(title: "Long")
    for turn in 0..<20 {
      saved.append(ChatMessage(role: .user, content: "Question \(turn) " + String(repeating: "q", count: 1_500)))
      saved.append(ChatMessage(role: .assistant, content: "Answer \(turn) " + String(repeating: "a", count: 1_500)))
    }
    try sessionStore.save([saved])
    let inference = ScriptedToolInference()
    let chat = LocalChatViewModel(engine: MessagesTestEngine(), messagesToolbox: { _ in RecordingToolbox() }, messagesAccess: {},
      localToolRuntime: { _ in true }, fileInference: inference, sessionStore: sessionStore)
    chat.selectSession(id: saved.id)
    await chat.refreshInstalledModel()
    chat.submitMessages("Who texted me last?", mode: .local, cloudProvider: .anthropic, cloudModelID: "")
    await waitForTheRequestToFinish(chat)
    let requests = await inference.requests
    let first = try XCTUnwrap(requests.first)
    XCTAssertLessThan(first.count, 42, "Older turns were dropped")
    XCTAssertEqual(first.last?.content?.contains("Who texted me last?"), true)
    XCTAssertNotNil(chat.contextNotice)
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

  func testRequiredToolIsNotForcedOnAnthropicModelsThatRejectForcedToolChoice() async throws {
    for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-mythos-5-1", "claude-opus-5-5-20261001",
                  "claude-sonnet-5-6", "claude-fable-5-2", "claude-mythos-5-3"] {
      let transport = QueuedTransport([["content": [["type": "text", "text": "42."]]]])
      let client = AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
      _ = try await collect(client.stream(request(.anthropic, model: model), toolbox: RequiringToolbox()))
      XCTAssertNil(transport.bodies[0]["tool_choice"], "\(model) returns a 400 for forced tool choice")
    }
  }

  func testAnthropicForcedToolChoiceIsAcceptedOnlyBeforeTheFiveFiveGeneration() {
    for model in ["claude-sonnet-4-6", "claude-opus-4-7", "claude-haiku-4-5", "claude-haiku-5-5", "claude-opus-5"] {
      XCTAssertTrue(AnthropicMessagesClient.acceptsForcedToolChoice(modelID: model), model)
    }
    for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-mythos-5-1", "claude-opus-5-10",
                  "claude-sonnet-5-5-20261001"] {
      XCTAssertFalse(AnthropicMessagesClient.acceptsForcedToolChoice(modelID: model), model)
    }
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

/// Streams scripted steps: each step's deltas, then its message. With `holdAfterFirstDelta`,
/// the first step waits after its first delta until `release` is called.
private actor StreamingStepsInference: LocalToolInference {
  struct Step { var deltas: [String]; var message: AgentInferenceMessage? }
  private var steps: [Step]
  private(set) var requiredTools: [String?] = []
  private var held: CheckedContinuation<Void, Never>?
  private var released = false
  let holdAfterFirstDelta: Bool

  init(_ steps: [Step], holdAfterFirstDelta: Bool = false) {
    self.steps = steps
    self.holdAfterFirstDelta = holdAfterFirstDelta
  }

  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    XCTFail("The streaming loop must not use completeTools")
    throw CancellationError()
  }

  nonisolated func streamTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel,
                               requiredTool: String?) -> AsyncThrowingStream<LocalToolStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let (step, first) = await self.next(requiredTool)
        for (index, delta) in step.deltas.enumerated() {
          continuation.yield(.text(delta))
          if first && index == 0 && self.holdAfterFirstDelta { await self.waitForRelease() }
        }
        if let message = step.message { continuation.yield(.message(message)) }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func next(_ requiredTool: String?) -> (Step, Bool) {
    requiredTools.append(requiredTool)
    return (steps.removeFirst(), requiredTools.count == 1)
  }

  private func waitForRelease() async {
    if released { return }
    await withCheckedContinuation { held = $0 }
  }

  func release() {
    released = true
    held?.resume()
    held = nil
  }
}

/// The streaming local tool loop (F32 CP3).
extension MessagesRequestTests {
  private var streamingModel: LocalModel {
    LocalModel(id: "m", displayName: "M", fileURL: URL(fileURLWithPath: "/tmp/m.gguf"))
  }

  func testRunStreamingEmitsTextAsItArrives() async throws {
    let inference = StreamingStepsInference([.init(deltas: ["Hello", " world"],
      message: AgentInferenceMessage(role: "assistant", content: "Hello world"))], holdAfterFirstDelta: true)
    let shown = LockedText()
    let toolbox = RecordingToolbox()
    // The second delta is released only once the first reached the chat, so a loop that
    // waited for the step to end would never finish.
    let run = Task { [streamingModel] in
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Hi")],
        model: streamingModel, toolbox: toolbox, onActivity: { _ in }) { text in
        shown.append(text)
        await inference.release()
      }
    }
    let timeout = Task { try await Task.sleep(for: .seconds(5)); run.cancel() }
    defer { timeout.cancel() }
    try await run.value
    XCTAssertEqual(shown.value, "Hello world")
    XCTAssertTrue(toolbox.calls.isEmpty)
  }

  func testRunStreamingKeepsOneCallPerStep() async throws {
    let inference = ScriptedToolInference()
    let runner = RecordingRunner()
    let tools = MessagesTools(database: MessagesDatabase(url: try MessagesFixture(directory: root).url), contacts: FixtureContacts(), sender: MessagesSender(run: runner.run),
      confirmSend: { _ in XCTFail("The discarded batch call must not reach approval"); return false })
    let collected = LockedText()
    try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Who texted last?")],
      model: streamingModel, toolbox: tools, onActivity: { _ in }) { collected.append($0) }
    XCTAssertTrue(collected.value.hasSuffix("Your latest chat is Weekend Trip."))
    let requests = await inference.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0][0].content?.contains("untrusted data") == true)
    XCTAssertEqual(requests[1].count, 4, "system, user, one assistant call, one tool result")
    XCTAssertEqual(requests[1][2].toolCalls?.map(\.function.name), ["list_conversations"])
    XCTAssertEqual(requests[1][2].toolCalls?.map(\.id), ["tool00000"])
    XCTAssertNil(requests[1][2].content, "History keeps the call, as run does")
    XCTAssertEqual(requests[1][3].role, "tool")
    XCTAssertEqual(requests[1][3].toolCallID, "tool00000")
    XCTAssertTrue(requests[1][3].content?.contains("Weekend Trip") == true)
    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testRunStreamingMatchesRunsHistory() async throws {
    // The same script through both loops sends the same requests: only the inference
    // call and the timing of onText differ.
    var histories: [[[AgentInferenceMessage]]] = []
    let database = MessagesDatabase(url: try MessagesFixture(directory: root).url)
    for streaming in [false, true] {
      let inference = ScriptedToolInference()
      let tools = MessagesTools(database: database, contacts: FixtureContacts(), sender: MessagesSender(run: RecordingRunner().run),
        confirmSend: { _ in false })
      var thinking = ChatMessage(role: .user, content: "Who texted last?")
      thinking.extendedThinking = true
      let messages = [thinking]
      let agent = LocalToolAgent(inference: inference)
      if streaming {
        try await agent.runStreaming(messages: messages, model: streamingModel, toolbox: tools, onActivity: { _ in }) { _ in }
      } else {
        try await agent.run(messages: messages, model: streamingModel, toolbox: tools) { _ in }
      }
      histories.append(await inference.requests)
    }
    XCTAssertEqual(histories[0], histories[1])
    XCTAssertEqual(histories[1].first?.first?.extendedThinking, true)
  }

  func testRunStreamingPassesRequiredToolOnFirstStepOnly() async throws {
    let call = AgentInferenceMessage(role: "assistant", content: nil, toolCalls: [
      AgentToolCall(id: "a", function: .init(name: "lookup", arguments: #"{"query":"x"}"#))])
    let answer = AgentInferenceMessage(role: "assistant", content: "42")
    for (toolbox, expected) in [(RequiringToolbox() as any AgentToolbox, "lookup"), (UnofferedRequirementToolbox(), nil)] {
      let inference = StreamingStepsInference([.init(deltas: [], message: call), .init(deltas: ["42"], message: answer)])
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Look it up")],
        model: streamingModel, toolbox: toolbox, onActivity: { _ in }) { _ in }
      let required = await inference.requiredTools
      XCTAssertEqual(required, [expected, nil])
    }
  }

  func testRunStreamingStepLimit() async throws {
    let inference = RepeatingToolInference()
    let toolbox = RecordingToolbox()
    do {
      try await LocalToolAgent(inference: inference, maximumSteps: 3).runStreaming(
        messages: [ChatMessage(role: .user, content: "Loop")], model: streamingModel, toolbox: toolbox,
        onActivity: { _ in }) { _ in }
      XCTFail("Expected the step limit")
    } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit) }
    let requests = await inference.requests
    XCTAssertEqual(requests, 3)
    XCTAssertEqual(toolbox.calls.count, 3)
  }

  func testRunStreamingEndsOnATerminalResult() async throws {
    let inference = RepeatingToolInference()
    let toolbox = StoppingToolbox(.automationDenied)
    do {
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Send it")],
        model: streamingModel, toolbox: toolbox, onActivity: { _ in }) { _ in }
      XCTFail("Expected the permission error")
    } catch { XCTAssertEqual(error as? MessagesError, .automationDenied) }
    XCTAssertEqual(toolbox.callCount, 1)
  }

  func testRunStreamingFailsWhenAStepEndsWithoutAMessage() async throws {
    let inference = StreamingStepsInference([.init(deltas: ["Partial"], message: nil)])
    do {
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Hi")],
        model: streamingModel, toolbox: RecordingToolbox(), onActivity: { _ in }) { _ in }
      XCTFail("A step with no finished message must fail")
    } catch { XCTAssertTrue(error is AgentToolError, "\(error)") }
  }

  func testRunStreamingJoinsStepsAsTheCloudLoopDoes() async throws {
    let call = AgentInferenceMessage(role: "assistant", content: "Checking.\n\n", toolCalls: [
      AgentToolCall(id: "a", function: .init(name: "lookup", arguments: #"{"query":"x"}"#))])
    let answer = AgentInferenceMessage(role: "assistant", content: "\n\nIt is 42.")
    let inference = StreamingStepsInference([.init(deltas: ["Checking.", "\n\n"], message: call),
                                              .init(deltas: ["\n\n", "It is ", "42."], message: answer)])
    let shown = LockedText()
    let phases = LockedPhases()
    try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Look it up")],
      model: streamingModel, toolbox: RecordingToolbox(), onActivity: { phases.append($0) }) { shown.append($0) }
    XCTAssertEqual(shown.value, "Checking.\n\nIt is 42.")
    XCTAssertEqual(phases.value, [.generating, .readingMessages, .thinking, .generating])
  }
}

/// Opens once; waiters before and after it carry on.
private actor Gate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    open = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

extension MessagesRequestTests {
  func testStopDuringAStreamedStepRunsNoCall() async throws {
    let call = AgentInferenceMessage(role: "assistant", content: "Checking", toolCalls: [
      AgentToolCall(id: "a", function: .init(name: "lookup", arguments: #"{"query":"x"}"#))])
    let inference = StreamingStepsInference([.init(deltas: ["Check", "ing"], message: call)], holdAfterFirstDelta: true)
    let toolbox = RecordingToolbox()
    let shown = LockedText()
    let run = Task { [streamingModel] in
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Look it up")],
        model: streamingModel, toolbox: toolbox, onActivity: { _ in }) { shown.append($0) }
    }
    while shown.value.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    run.cancel()
    await inference.release()
    do { try await run.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError, "Stop is quiet, not a broken step: \(error)") }
    XCTAssertTrue(toolbox.calls.isEmpty)
    let steps = await inference.requiredTools.count
    XCTAssertEqual(steps, 1, "No further step after Stop")
  }

  func testStopAfterAStepFinishedRunsNoCall() async throws {
    // The step's message is already buffered when Stop arrives; its call must not run.
    let call = AgentInferenceMessage(role: "assistant", content: "Checking", toolCalls: [
      AgentToolCall(id: "a", function: .init(name: "lookup", arguments: #"{"query":"x"}"#))])
    let inference = StreamingStepsInference([.init(deltas: ["Checking"], message: call)])
    let toolbox = RecordingToolbox()
    let gate = Gate()
    let shown = LockedText()
    let run = Task { [streamingModel] in
      try await LocalToolAgent(inference: inference).runStreaming(messages: [ChatMessage(role: .user, content: "Look it up")],
        model: streamingModel, toolbox: toolbox, onActivity: { _ in }) { text in
        shown.append(text)
        await gate.wait()
      }
    }
    while shown.value.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    run.cancel()
    await gate.release()
    do { try await run.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertTrue(toolbox.calls.isEmpty)
  }
}

private final class LockedPhases: @unchecked Sendable {
  private let lock = NSLock()
  private var phases: [AssistantActivity.Phase] = []
  var value: [AssistantActivity.Phase] { lock.withLock { phases } }
  func append(_ event: AssistantActivityEvent) {
    guard case .phase(let phase) = event else { return }
    lock.withLock { phases.append(phase) }
  }
}

// MARK: - F35 CP1: the per-step budget

/// Search results of about `bytes` of excerpt text in all, over two sources.
private func bulkySearchTool(bytes: Int = 2_000, sizes: LockedSizes? = nil, stepBudget: ToolStepBudget? = nil) -> WebSearchTool {
  let results = (1...2).map { index in
    WebSearchResult(source: WebSearchSource(title: "Result \(index)", url: URL(string: "https://example.com/\(index)")!),
                    snippets: [String(repeating: "word ", count: bytes / 10)])
  }
  return WebSearchTool(search: { _, _, maximumTokens in sizes?.append(maximumTokens); return results },
                       evidenceCap: 2_048, stepBudget: stepBudget, mayQuery: { _ in true }, onSources: { _ in })
}

final class LockedSizes: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []
  var values: [Int] { lock.withLock { sizes } }
  func append(_ size: Int) { lock.withLock { sizes.append(size) } }
}

/// Calls `web_search` whenever it is offered, and answers once tools are withdrawn.
private actor SearchingInference: LocalToolInference {
  /// Searches at most this many times.
  private let limit: Int
  /// Calls `web_search` even on a step sent without tools.
  private let ignoresWithdrawal: Bool
  private(set) var requests: [[AgentInferenceMessage]] = []
  private(set) var tools: [[String]] = []
  private(set) var requiredTools: [String?] = []

  init(limit: Int = .max, ignoresWithdrawal: Bool = false) {
    self.limit = limit
    self.ignoresWithdrawal = ignoresWithdrawal
  }

  func completeTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel) async throws -> AgentInferenceMessage {
    requests.append(messages)
    self.tools.append(tools.map(\.name))
    guard !tools.isEmpty || ignoresWithdrawal, requests.count <= limit else { return AgentInferenceMessage(role: "assistant", content: "Here is what I found.") }
    return AgentInferenceMessage(role: "assistant", content: nil, toolCalls: [
      AgentToolCall(id: "c", function: .init(name: "web_search", arguments: #"{"query":"news \#(requests.count)"}"#))])
  }

  nonisolated func streamTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition], model: LocalModel,
                               requiredTool: String?) -> AsyncThrowingStream<LocalToolStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        await self.recordRequired(requiredTool)
        do {
          let message = try await self.completeTools(messages: messages, tools: tools, model: model)
          if let content = message.content { continuation.yield(.text(content)) }
          continuation.yield(.message(message))
        } catch { continuation.finish(throwing: error); return }
        continuation.finish()
      }
    }
  }

  private func recordRequired(_ tool: String?) { requiredTools.append(tool) }
}

extension MessagesRequestTests {
  /// About 1,300 tokens, so a full-size first result leaves less than twice the cap.
  private static let sizingQuestion = [ChatMessage(role: .user, content: "What's new? " + String(repeating: "context ", count: 490))]

  /// Sized so the fourth search's result leaves no room for another.
  private static let contextWords = 1_620

  /// An 8,192-token local model, as catalogue packages run today.
  private var smallModel: LocalModel {
    LocalModel(id: "m", displayName: "M", fileURL: URL(fileURLWithPath: "/tmp/m.gguf"),
               visionConfiguration: LocalVisionConfiguration(projectorURL: URL(fileURLWithPath: "/tmp/p.gguf"),
                                                             serverExecutableURL: URL(fileURLWithPath: "/tmp/llama-server")))
  }

  private func searchTurn(streaming: Bool, thinks: Bool = false) async throws -> (SearchingInference, String) {
    let inference = SearchingInference()
    // About 1,000 tokens a result.
    let toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 3_000)], requiredTool: "web_search", extraInstructions: [])
    var question = ChatMessage(role: .user, content: "What's new? " + String(repeating: "context ", count: Self.contextWords))
    question.extendedThinking = thinks
    let shown = LockedText()
    let agent = LocalToolAgent(inference: inference)
    if streaming {
      try await agent.runStreaming(messages: [question], model: smallModel, toolbox: toolbox, onActivity: { _ in }) { shown.append($0) }
    } else {
      try await agent.run(messages: [question], model: smallModel, toolbox: toolbox) { shown.append($0) }
    }
    return (inference, shown.value)
  }

  func testRepeatedSearchesShrinkThenAnswerLocal() async throws {
    for streaming in [false, true] {
      let (inference, answer) = try await searchTurn(streaming: streaming)
      XCTAssertEqual(answer, "Here is what I found.", "The turn ends with the model's answer, never an error")
      let tools = await inference.tools
      XCTAssertEqual(tools.dropLast(), Array(repeating: ["web_search"], count: 4), "Four searches")
      XCTAssertEqual(tools.last, [], "The last step is sent with no tools")
      let requests = await inference.requests
      let last = try XCTUnwrap(requests.last)
      XCTAssertTrue(last[0].content?.hasSuffix("\n" + ToolStepBudget.answerInstruction) == true)
      XCTAssertFalse(requests.dropLast().contains { $0[0].content?.contains(ToolStepBudget.answerInstruction) == true })
      let results = last.filter { $0.role == "tool" }.compactMap(\.content)
      XCTAssertEqual(results.count, 4)
      XCTAssertTrue(results.dropLast().allSatisfy { $0.contains(ToolStepBudget.removedExcerpt) && !$0.contains("word word") },
                    "Earlier results shrank")
      XCTAssertTrue(results.dropLast().allSatisfy { $0.contains("https://example.com/1") && $0.contains("Result 2") })
      XCTAssertLessThanOrEqual(LocalToolAgent.usedTokens(last), LocalToolAgent.budget([], model: smallModel,
        toolbox: AssistantToolbox(parts: [bulkySearchTool()], requiredTool: nil, extraInstructions: [])).availableInputTokens)
    }
  }

  func testShrinkNeverTouchesTheCurrentStep() async throws {
    let (inference, _) = try await searchTurn(streaming: true)
    let requests = await inference.requests
    // The first step that shrank: its newest result is still whole, and the model reads it.
    let shrinking = try XCTUnwrap(requests.first { $0.contains { $0.content?.contains(ToolStepBudget.removedExcerpt) == true } })
    let results = shrinking.filter { $0.role == "tool" }.compactMap(\.content)
    XCTAssertTrue(results.last?.contains("word word") == true)
    XCTAssertFalse(results.last?.contains(ToolStepBudget.removedExcerpt) == true)
  }

  func testNoStepIsSentOverTheBudget() async throws {
    let inference = SearchingInference()
    // One result bigger than the whole window, from a search that ignores its size.
    let toolbox = AssistantToolbox(parts: [OversizedSearch()], requiredTool: nil, extraInstructions: [])
    let shown = LockedText()
    let question = [ChatMessage(role: .user, content: "What's new?")]
    try await LocalToolAgent(inference: inference).runStreaming(messages: question, model: smallModel, toolbox: toolbox,
      onActivity: { _ in }) { shown.append($0) }
    XCTAssertEqual(shown.value, "Here is what I found.")
    let tools = await inference.tools
    XCTAssertEqual(tools, [["web_search"], []])
    let requests = await inference.requests
    let last = try XCTUnwrap(requests.last)
    XCTAssertTrue(last.last?.content?.contains(ToolStepBudget.removedExcerpt) == true, "The newest result shrank too")
    XCTAssertTrue(last.last?.content?.contains("https://example.com/1") == true)
    XCTAssertLessThanOrEqual(LocalToolAgent.usedTokens(last),
                             LocalToolAgent.budget(question, model: smallModel, toolbox: toolbox).availableInputTokens)
  }

  func testThinkReserveCountsInLocalStepBudget() async throws {
    let (plain, _) = try await searchTurn(streaming: true)
    let (thinking, answer) = try await searchTurn(streaming: true, thinks: true)
    XCTAssertEqual(answer, "Here is what I found.")
    let plainSteps = await plain.tools.count
    let thinkingSteps = await thinking.tools.count
    XCTAssertLessThan(thinkingSteps, plainSteps, "/think's 2,048-token reserve leaves room for fewer steps")
  }

  func testWithdrawnToolsAreNotForcedRequiredLocal() async throws {
    let (inference, _) = try await searchTurn(streaming: true)
    let required = await inference.requiredTools
    XCTAssertEqual(required.first, "web_search")
    XCTAssertEqual(required.last, nil as String?, "A step without tools asks for none")
  }

  func testACallOnAWithdrawnStepEndsTheTurnUnrunLocal() async throws {
    for streaming in [false, true] {
      let inference = SearchingInference(ignoresWithdrawal: true)
      let sizes = LockedSizes()
      let toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 3_000, sizes: sizes)], requiredTool: nil, extraInstructions: [])
      let question = [ChatMessage(role: .user, content: "What's new? " + String(repeating: "context ", count: Self.contextWords))]
      let agent = LocalToolAgent(inference: inference)
      do {
        if streaming {
          try await agent.runStreaming(messages: question, model: smallModel, toolbox: toolbox, onActivity: { _ in }) { _ in }
        } else {
          try await agent.run(messages: question, model: smallModel, toolbox: toolbox) { _ in }
        }
        XCTFail("Expected the step limit")
      } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit) }
      let tools = await inference.tools
      XCTAssertEqual(tools.last, [], "The call came on a step sent without tools")
      XCTAssertEqual(sizes.values.count, tools.count - 1, "It never ran")
    }
  }

  func testStepLimitStillAppliesWithRoomLeft() async throws {
    let inference = SearchingInference()
    let toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 20)], requiredTool: nil, extraInstructions: [])
    do {
      try await LocalToolAgent(inference: inference, maximumSteps: 3).runStreaming(messages: [ChatMessage(role: .user, content: "Hi")],
        model: smallModel, toolbox: toolbox, onActivity: { _ in }) { _ in }
      XCTFail("Expected the step limit")
    } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit) }
    let tools = await inference.tools
    XCTAssertEqual(tools, Array(repeating: ["web_search"], count: 3))
  }

  func testWebSearchUsesRoomLeft() async throws {
    let sizes = LockedSizes()
    let steps = ToolStepBudget()
    var toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 9_000, sizes: sizes, stepBudget: steps)], requiredTool: nil, extraInstructions: [])
    toolbox.stepBudget = steps
    _ = try await searchTurn(inference: SearchingInference(limit: 2), toolbox: toolbox)
    // The same through the whole-step loop.
    try await LocalToolAgent(inference: SearchingInference(limit: 2)).run(
      messages: Self.sizingQuestion, model: smallModel, toolbox: toolbox) { _ in }
    XCTAssertEqual(sizes.values.count, 4)
    for pair in [Array(sizes.values.prefix(2)), Array(sizes.values.suffix(2))] {
      XCTAssertEqual(pair.first, 2_048, "With plenty of room, the cap")
      XCTAssertLessThan(pair[1], pair[0], "A second call gets a smaller result than the first")
      XCTAssertTrue(pair.allSatisfy { $0 >= ToolStepBudget.smallestResult })
    }
  }

  private func searchTurn(inference: SearchingInference, toolbox: AssistantToolbox) async throws -> String {
    let shown = LockedText()
    try await LocalToolAgent(inference: inference).runStreaming(
      messages: Self.sizingQuestion, model: smallModel, toolbox: toolbox, onActivity: { _ in }) { shown.append($0) }
    return shown.value
  }
}

extension CloudToolLoopTests {
  nonisolated(unsafe) private static let searchCall: [CloudProviderID: [String: Any]] = [
    .openAI: ["status": "completed", "output": [["type": "function_call", "call_id": "call", "name": "web_search",
      "arguments": #"{"query":"news"}"#]]],
    .anthropic: ["content": [["type": "thinking", "thinking": "Searching.", "signature": "sig"],
      ["type": "tool_use", "id": "toolu", "name": "web_search", "input": ["query": "news"]]], "stop_reason": "tool_use"],
    .gemini: ["candidates": [["content": ["role": "model", "parts": [["functionCall": ["name": "web_search", "args": ["query": "news"]],
      "thoughtSignature": "sig"]]], "finishReason": "STOP"]]],
  ]
  nonisolated(unsafe) private static let searchAnswer: [CloudProviderID: [String: Any]] = [
    .openAI: ["status": "completed", "output": [["type": "message", "role": "assistant",
      "content": [["type": "output_text", "text": "Here is what I found."]]]]],
    .anthropic: ["content": [["type": "text", "text": "Here is what I found."]], "stop_reason": "end_turn"],
    .gemini: ["candidates": [["content": ["role": "model", "parts": [["text": "Here is what I found."]]], "finishReason": "STOP"]]],
  ]
  private func searchBodies(_ provider: CloudProviderID, thinks: Bool = false,
                            toolbox: AssistantToolbox? = nil, limit: Int = .max,
                            ignoresWithdrawal: Bool = false) async throws -> ([[String: Any]], [ChatEvent]) {
    let transport = SearchingTransport(call: Self.searchCall[provider]!, answer: Self.searchAnswer[provider]!, limit: limit,
                                       ignoresWithdrawal: ignoresWithdrawal)
    let client: any ToolCallingChatProvider = switch provider {
    case .openAI: OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    case .anthropic: AnthropicMessagesClient(credentialStore: ToolTestCredentials(), transport: transport)
    default: GeminiContentClient(credentialStore: ToolTestCredentials(), transport: transport)
    }
    // Padded so the room left is what an 8,192-token window left: every cloud model now has at
    // least 256K, so the 65,536 input cap applies (61,952 estimated tokens of padding).
    var question = ChatMessage(role: .user, content: "What's new?" + String(repeating: "x", count: 185_856))
    question.extendedThinking = thinks
    let request = ChatRequest(sessionID: UUID(), messages: [question],
      route: Route(mode: .cloud, providerID: provider.rawValue, modelID: "manual-model", usesNetwork: true))
    let toolbox = toolbox ?? AssistantToolbox(parts: [bulkySearchTool(bytes: 2_000)], requiredTool: "web_search", extraInstructions: [])
    let events = try await collect(client.stream(request, toolbox: toolbox))
    return (transport.bodies, events)
  }

  private func assertShrinksThenAnswers(_ provider: CloudProviderID, items key: String,
                                        withdrawn: ([String: Any]) -> Bool, system: ([String: Any]) -> String?,
                                        results: ([String: Any]) -> [String]) async throws {
    let (bodies, events) = try await searchBodies(provider)
    XCTAssertEqual(events.compactMap { if case .token(let text) = $0 { text } else { nil } }.last, "Here is what I found.")
    XCTAssertEqual(events.last, .completed)
    let searches = bodies.count - 1
    XCTAssertGreaterThanOrEqual(searches, 3, "\(provider)")
    XCTAssertLessThan(bodies.count, CloudToolLoop.maximumSteps, "\(provider)")
    XCTAssertEqual(bodies.map(withdrawn), Array(repeating: false, count: searches) + [true], "\(provider)")
    XCTAssertTrue(system(bodies.last!)?.hasSuffix("\n" + ToolStepBudget.answerInstruction) == true)
    XCTAssertFalse(bodies.dropLast().contains { system($0)?.contains(ToolStepBudget.answerInstruction) == true })
    let last = results(bodies.last!)
    XCTAssertEqual(last.count, searches)
    XCTAssertTrue(last.dropLast().allSatisfy { $0.contains(ToolStepBudget.removedExcerpt) && !$0.contains("word word") }, "\(provider)")
    XCTAssertTrue(last.last?.contains("word word") == true, "The newest result stays whole")
    let budget = ModelContextPolicy.cloud(provider: provider, modelID: "manual-model")
    XCTAssertLessThan(CloudToolLoop.estimatedTokens(bodies.last![key] as! [[String: Any]]), budget.contextWindow)
  }

  func testRepeatedSearchesShrinkThenAnswerOpenAI() async throws {
    try await assertShrinksThenAnswers(.openAI, items: "input", withdrawn: { $0["tool_choice"] as? String == "none" },
      system: { $0["instructions"] as? String },
      results: { ($0["input"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call_output" }
        .compactMap { $0["output"] as? String } })
    let (bodies, _) = try await searchBodies(.openAI)
    XCTAssertNotNil(bodies.last?["tools"], "Tools stay defined, so the calls in the input stay valid")
  }

  func testRepeatedSearchesShrinkThenAnswerAnthropic() async throws {
    let results: ([String: Any]) -> [String] = { body in
      (body["messages"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        .filter { $0["type"] as? String == "tool_result" }.compactMap { $0["content"] as? String }
    }
    try await assertShrinksThenAnswers(.anthropic, items: "messages",
      withdrawn: { ($0["tool_choice"] as? [String: Any])?["type"] as? String == "none" },
      system: { $0["system"] as? String }, results: results)
    // With /think, the assistant's thinking blocks go back unchanged on the withdrawn step.
    let (bodies, events) = try await searchBodies(.anthropic, thinks: true)
    XCTAssertEqual(events.last, .completed)
    let last = try XCTUnwrap(bodies.last)
    XCTAssertEqual((last["tool_choice"] as? [String: Any])?["type"] as? String, "none")
    XCTAssertNotNil(last["thinking"])
    let assistant = (last["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "assistant" }
    XCTAssertEqual(assistant.count, bodies.count - 1)
    for message in assistant {
      let blocks = message["content"] as? [[String: Any]] ?? []
      XCTAssertEqual(blocks.first?["type"] as? String, "thinking")
      XCTAssertEqual(blocks.first?["signature"] as? String, "sig")
    }
  }

  func testRepeatedSearchesShrinkThenAnswerGemini() async throws {
    try await assertShrinksThenAnswers(.gemini, items: "contents",
      withdrawn: { (($0["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"] as? String == "NONE" },
      system: { ((($0["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first)?["text"] as? String },
      results: { body in
        (body["contents"] as? [[String: Any]] ?? []).flatMap { $0["parts"] as? [[String: Any]] ?? [] }
          .compactMap { ($0["functionResponse"] as? [String: Any])?["response"] }.map(CloudToolLoop.jsonString)
      })
  }

  func testWithdrawnToolsAreNotForcedRequired() async throws {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let (bodies, _) = try await searchBodies(provider)
      let last = try XCTUnwrap(bodies.last)
      XCTAssertNotNil(bodies.first?[provider == .gemini ? "toolConfig" : "tool_choice"], "\(provider) forces the first step")
      switch provider {
      case .openAI: XCTAssertEqual(last["tool_choice"] as? String, "none")
      case .anthropic: XCTAssertEqual(last["tool_choice"] as? [String: String], ["type": "none"])
      default: XCTAssertEqual(CloudToolLoop.jsonString(last["toolConfig"] ?? [:]), #"{"functionCallingConfig":{"mode":"NONE"}}"#)
      }
    }
  }

  func testACallOnAWithdrawnStepEndsTheTurnUnrun() async throws {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let sizes = LockedSizes()
      let toolbox = { AssistantToolbox(parts: [bulkySearchTool(bytes: 2_000, sizes: sizes)], requiredTool: "web_search",
                                       extraInstructions: []) }
      let (bodies, _) = try await searchBodies(provider, toolbox: toolbox())
      let searches = bodies.count - 1
      XCTAssertEqual(sizes.values.count, searches)
      do {
        _ = try await searchBodies(provider, toolbox: toolbox(), ignoresWithdrawal: true)
        XCTFail("Expected the step limit")
      } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit, "\(provider)") }
      XCTAssertEqual(sizes.values.count, 2 * searches, "\(provider): the withdrawn step's call never ran")
    }
  }

  func testAPILoopsShareTheTurnsBudgetWithTheirTools() async throws {
    for provider in [CloudProviderID.openAI, .anthropic, .gemini] {
      let sizes = LockedSizes()
      let steps = ToolStepBudget()
      var toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 2_000, sizes: sizes, stepBudget: steps)],
                                     requiredTool: nil, extraInstructions: [])
      toolbox.stepBudget = steps
      _ = try await searchBodies(provider, toolbox: toolbox, limit: 2)
      XCTAssertEqual(sizes.values.count, 2, "\(provider)")
      XCTAssertLessThan(sizes.values[1], sizes.values[0], "\(provider): the loop measured the tools' budget")
    }
  }

  func testParallelCallsAreSizedOneAfterAnother() async throws {
    let sizes = LockedSizes()
    let steps = ToolStepBudget()
    var toolbox = AssistantToolbox(parts: [bulkySearchTool(bytes: 9_000, sizes: sizes, stepBudget: steps)],
                                   requiredTool: nil, extraInstructions: [])
    toolbox.stepBudget = steps
    let budget = ContextBudget(contextWindow: 8_192, outputTokens: 1_024, overheadTokens: 1_024)
    var step = 0
    try await CloudToolLoop.run(toolbox: toolbox, budget: budget, count: { 100 }, shrink: { _ in }, emit: { _ in },
      step: { _, _, _ in
        step += 1
        return step == 1 ? .init(text: "", calls: [.init(id: "1", name: "web_search", arguments: #"{"query":"a"}"#),
                                                   .init(id: "2", name: "web_search", arguments: #"{"query":"b"}"#)])
          : .init(text: "Done.", calls: [])
      }, deliver: { _ in })
    XCTAssertEqual(sizes.values.count, 2)
    XCTAssertEqual(sizes.values.first, 2_048)
    XCTAssertLessThan(sizes.values[1], sizes.values[0], "The second call of a step gets what the first left")
  }

  func testStepLimitStillApplies() async throws {
    let looping = Self.searchCall[.openAI]!
    let transport = QueuedTransport(Array(repeating: looping, count: CloudToolLoop.maximumSteps))
    let client = OpenAIResponsesClient(credentialStore: ToolTestCredentials(), transport: transport)
    let request = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "Hi")],
      route: Route(mode: .cloud, providerID: CloudProviderID.openAI.rawValue, modelID: "gpt-4.1", usesNetwork: true))
    do {
      _ = try await collect(client.stream(request, toolbox: AssistantToolbox(parts: [bulkySearchTool(bytes: 20)],
                                                                             requiredTool: nil, extraInstructions: [])))
      XCTFail("Expected the step limit")
    } catch { XCTAssertEqual(error as? AgentToolError, .stepLimit) }
    XCTAssertEqual(transport.bodies.count, CloudToolLoop.maximumSteps)
    XCTAssertTrue(transport.bodies.allSatisfy { $0["tool_choice"] as? String != "none" })
  }
}

/// Calls `web_search` while tools are offered and answers once they are withdrawn, in each
/// provider's stream format.
private final class SearchingTransport: CloudNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let call: [String: Any]
  private let answer: [String: Any]
  /// Searches at most this many times.
  private let limit: Int
  /// Calls `web_search` even on a step whose tools were withdrawn.
  private let ignoresWithdrawal: Bool
  private var recorded: [[String: Any]] = []
  var bodies: [[String: Any]] { lock.withLock { recorded } }

  init(call: [String: Any], answer: [String: Any], limit: Int = .max, ignoresWithdrawal: Bool = false) {
    self.call = call
    self.answer = answer
    self.limit = limit
    self.ignoresWithdrawal = ignoresWithdrawal
  }

  func data(for request: URLRequest) async throws -> CloudDataResponse { throw CloudProviderError.invalidResponse }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { continuation in
      do {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let count = lock.withLock { recorded.append(body); return recorded.count }
        let withdrawn = body["tool_choice"] as? String == "none" || (body["tool_choice"] as? [String: Any])?["type"] as? String == "none"
          || CloudToolLoop.jsonString(body["toolConfig"] ?? [:]).contains("NONE")
        continuation.yield(.response(statusCode: 200))
        let answers = (withdrawn && !ignoresWithdrawal) || count > limit
        continuation.yield(.data(Data(try QueuedTransport.stream(for: request.url!, response: answers ? answer : call).utf8)))
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
  }
}

extension QueuedTransport {
  /// A whole response as its provider's stream.
  static func stream(for url: URL, response: [String: Any]) throws -> String { try events(for: url, response: response) }
}

/// A `web_search` that returns about 10,000 tokens whatever it is asked for.
private struct OversizedSearch: AgentToolbox {
  let instructions = ""
  var definitions: [AgentToolDefinition] { bulkySearchTool().definitions }
  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    let text = String(repeating: "word ", count: 6_000)
    return AgentToolResult(text: #"{"results":[{"id":1,"kind":"page","site":"Example","text":"\#(text)","title":"Result 1","url":"https://example.com/1"}]}"#,
                           success: true)
  }
}
