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

private struct ToolTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { "test-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

/// Returns queued JSON responses and records request bodies.
private final class QueuedTransport: CloudNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [[String: Any]]
  private(set) var bodies: [[String: Any]] = []
  private(set) var urls: [URL] = []

  init(_ responses: [[String: Any]]) { self.responses = responses }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    try lock.withLock {
      urls.append(request.url!)
      bodies.append(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:])
      let next = responses.removeFirst()
      return CloudDataResponse(data: try JSONSerialization.data(withJSONObject: next), statusCode: 200)
    }
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: CloudProviderError.invalidResponse) }
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
    XCTAssertTrue(transport.urls[0].absoluteString.hasSuffix("gemini-3-flash:generateContent"))
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
    let initialize = await ClaudeCodeToolMode.respond(to: .object(["jsonrpc": .string("2.0"), "id": .number(0),
      "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25")])]), toolbox: toolbox)
    XCTAssertEqual(initialize["result"]["protocolVersion"].string, "2025-11-25")
    let list = await ClaudeCodeToolMode.respond(to: .object(["id": .number(1), "method": .string("tools/list")]), toolbox: toolbox)
    XCTAssertEqual(list["result"]["tools"].array?.first?["inputSchema"]["required"], .array([.string("query")]))
    var called: [String] = []
    let call = await ClaudeCodeToolMode.respond(to: .object(["id": .number(2), "method": .string("tools/call"),
      "params": .object(["name": .string("lookup"), "arguments": .object(["query": .string("x")])])]), toolbox: toolbox) {
      called.append($0)
    }
    XCTAssertEqual(called, ["lookup"])
    XCTAssertEqual(call["result"]["isError"], .bool(false))
    XCTAssertEqual(call["result"]["content"].array?.first?["text"].string, #"{"answer":"42"}"#)
    let unknown = await ClaudeCodeToolMode.respond(to: .object(["id": .number(3), "method": .string("resources/list")]), toolbox: toolbox)
    XCTAssertEqual(unknown["error"]["code"].integer, -32601)
  }

  func testControlRequestsForOtherServersOrPermissionsAreRefused() async throws {
    let toolbox = RecordingToolbox()
    let other = await ClaudeCodeToolMode.controlResponse(id: "r1", request: .object([
      "subtype": .string("mcp_message"), "server_name": .string("other"), "message": .object([:])]), toolbox: toolbox)
    XCTAssertEqual(other["response"]["subtype"].string, "error")
    let permission = await ClaudeCodeToolMode.controlResponse(id: "r2", request: .object(["subtype": .string("can_use_tool")]), toolbox: toolbox)
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
