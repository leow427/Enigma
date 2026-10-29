import XCTest
@testable import Enigma

/// CP0's recorded and documented provider streams (`Fixtures/F32`).
enum F32Fixture {
  static func text(_ provider: String, _ name: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/F32/\(provider)/\(name).txt"), encoding: .utf8)
  }

  static func events(_ provider: String, _ name: String) throws -> [ServerSentEvent] {
    try events(in: text(provider, name))
  }

  static func events(in text: String) -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    return parser.append(Data(text.utf8)) + parser.finish()
  }
}

/// Feeds every event to the assembler and finishes it, collecting the text deltas.
private func assemble<Assembler: ToolStreamAssembler>(
  _ assembler: inout Assembler, _ events: [ServerSentEvent]
) throws -> (texts: [String], turn: CloudToolLoop.Turn) {
  var texts: [String] = []
  for event in events {
    if let text = try assembler.consume(event) { texts.append(text) }
  }
  return (texts, try assembler.finish())
}

private func object(_ json: String) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func assertEqualJSON(_ actual: Any?, _ expected: Any?, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertEqual(actual.map { $0 as AnyObject } as? NSObject, expected.map { $0 as AnyObject } as? NSObject,
    message, file: file, line: line)
}

private func assertInvalidResponse(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
  XCTAssertThrowsError(try body(), file: file, line: line) { error in
    XCTAssertEqual(error as? CloudProviderError, .invalidResponse, file: file, line: line)
  }
}

private let weatherCall = CloudToolLoop.Call(id: "call-0", name: "get_weather", arguments: #"{"city":"Paris"}"#)

// MARK: - OpenAI

final class OpenAIToolStreamAssemblerTests: XCTestCase {
  func testTextOnly() throws {
    var assembler = OpenAIToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("openai", "text"))
    XCTAssertEqual(texts, ["Hello", " there", ", nice", " to meet", " you!"])
    XCTAssertEqual(turn, .init(text: "Hello there, nice to meet you!", calls: []))
  }

  func testOneCall() throws {
    var assembler = OpenAIToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("openai", "call"))
    XCTAssertEqual(texts, [])
    XCTAssertEqual(turn.calls, [weatherCall])
  }

  func testTextThenCall() throws {
    var assembler = OpenAIToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("openai", "text-then-call"))
    XCTAssertEqual(texts, ["Let me", " check the", " weather in Paris."])
    XCTAssertEqual(turn, .init(text: "Let me check the weather in Paris.", calls: [weatherCall]))
  }

  func testForcedCall() throws {
    var assembler = OpenAIToolStreamAssembler()
    XCTAssertEqual(try assemble(&assembler, F32Fixture.events("openai", "forced")).turn.calls.map(\.name), ["get_weather"])
  }

  func testStreamCutMidCallRunsNothing() throws {
    var assembler = OpenAIToolStreamAssembler()
    for event in try F32Fixture.events("openai", "cut-mid-call") { _ = try assembler.consume(event) }
    assertInvalidResponse { _ = try assembler.finish() }
  }

  func testACallThatIsNeverFinishedRunsNothingEvenIfTheResponseCompletes() throws {
    let events = try F32Fixture.events("openai", "cut-mid-call") + F32Fixture.events(in: """
      data: {"type":"response.completed","response":{"status":"completed","output":[]}}

      """)
    var assembler = OpenAIToolStreamAssembler()
    for event in events { _ = try assembler.consume(event) }
    assertInvalidResponse { _ = try assembler.finish() }
  }

  func testReplayMatchesWholeResponse() throws {
    let events = try F32Fixture.events("openai", "text-then-call")
    var assembler = OpenAIToolStreamAssembler()
    let turn = try assemble(&assembler, events).turn
    // The completed event carries the whole response the non-streaming path parsed.
    let whole = try XCTUnwrap(object(try XCTUnwrap(events.last).data)["response"] as? [String: Any])
    XCTAssertEqual(turn, try OpenAIResponsesClient.toolTurn(whole))
    let replayed = (whole["output"] as? [[String: Any]] ?? []).compactMap(OpenAIResponsesClient.replayable)
    XCTAssertEqual(replayed.count, 2)
    assertEqualJSON(assembler.replayItems, replayed)
  }

  func testSeveralCallsKeepTheirOrderAndArguments() throws {
    var assembler = OpenAIToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events(in: """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc-0","call_id":"call-0","name":"get_weather","arguments":""}}

      data: {"type":"response.function_call_arguments.delta","item_id":"fc-0","output_index":0,"delta":"{\\"city\\":\\"Paris\\"}"}

      data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc-1","call_id":"call-1","name":"get_time","arguments":""}}

      data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc-1","status":"completed","call_id":"call-1","name":"get_time","arguments":"{\\"zone\\":\\"CET\\"}"}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc-0","status":"completed","call_id":"call-0","name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}

      data: {"type":"response.completed","response":{"status":"completed"}}

      """))
    XCTAssertEqual(texts, [])
    XCTAssertEqual(turn.calls, [weatherCall, .init(id: "call-1", name: "get_time", arguments: #"{"zone":"CET"}"#)],
      "Calls run in output order, whichever finished first")
    XCTAssertEqual(assembler.replayItems.compactMap { $0["call_id"] as? String }, ["call-0", "call-1"])
  }

  func testDoneSentinelIsIgnored() throws {
    var assembler = OpenAIToolStreamAssembler()
    let events = try F32Fixture.events("openai", "text") + F32Fixture.events(in: "data: [DONE]\n\n")
    XCTAssertEqual(try assemble(&assembler, events).turn.text, "Hello there, nice to meet you!")
  }

  func testReasoningItemsAreNotReplayed() throws {
    var assembler = OpenAIToolStreamAssembler()
    _ = try assemble(&assembler, F32Fixture.events(in: """
      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs-0","summary":[]}}

      data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc-0","status":"completed","call_id":"call-0","name":"get_weather","arguments":"{}"}}

      data: {"type":"response.completed","response":{"status":"completed"}}

      """))
    assertEqualJSON(assembler.replayItems, [["type": "function_call", "call_id": "call-0", "name": "get_weather", "arguments": "{}"]])
  }

  func testIncompleteWithNothingFailsAsToday() throws {
    var assembler = OpenAIToolStreamAssembler()
    XCTAssertThrowsError(try assemble(&assembler, F32Fixture.events(in: """
      data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

      """))) { XCTAssertEqual($0 as? CloudProviderError, .providerMessage("OpenAI stopped before answering.")) }
  }

  func testFailedResponseReportsTheProviderMessage() throws {
    var assembler = OpenAIToolStreamAssembler()
    XCTAssertThrowsError(try assembler.consume(ServerSentEvent(event: nil,
      data: #"{"type":"response.failed","response":{"status":"failed","error":{"message":"Server overloaded."}}}"#))) {
      XCTAssertEqual($0 as? CloudProviderError, .providerMessage("Server overloaded."))
    }
  }

  func testMalformedEventIsAnInvalidResponse() {
    var assembler = OpenAIToolStreamAssembler()
    assertInvalidResponse { _ = try assembler.consume(ServerSentEvent(event: nil, data: #"{"type":"response.output_item.done""#)) }
  }

  func testStreamWithoutACompletionEventIsADroppedReply() throws {
    var assembler = OpenAIToolStreamAssembler()
    for event in try F32Fixture.events("openai", "text").dropLast() { _ = try assembler.consume(event) }
    XCTAssertThrowsError(try assembler.finish()) { XCTAssertEqual($0 as? CloudProviderError, .streamEndedUnexpectedly) }
  }
}

// MARK: - Anthropic

final class AnthropicToolStreamAssemblerTests: XCTestCase {
  private let readCall = CloudToolLoop.Call(id: "toolu-0", name: "Read", arguments: #"{"file_path":"\/tmp\/probe\/city.txt"}"#)

  func testTextOnly() throws {
    var assembler = AnthropicToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("anthropic", "text"))
    XCTAssertEqual(texts, ["Hello there", ", fri", "end", ",", " n", "ice day!"])
    XCTAssertEqual(turn, .init(text: "Hello there, friend, nice day!", calls: []))
  }

  func testOneCall() throws {
    var assembler = AnthropicToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("anthropic", "call"))
    XCTAssertEqual(texts, [])
    XCTAssertEqual(turn.calls, [readCall])
  }

  func testTextThenCall() throws {
    var assembler = AnthropicToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("anthropic", "text-then-call"))
    XCTAssertEqual(texts, ["I'll check the", " file now", "."])
    XCTAssertEqual(turn, .init(text: "I'll check the file now.", calls: [readCall]))
  }

  func testForcedCall() throws {
    var assembler = AnthropicToolStreamAssembler()
    XCTAssertEqual(try assemble(&assembler, F32Fixture.events("anthropic", "forced")).turn.calls.map(\.name), ["Read"])
  }

  func testStreamCutMidCallRunsNothing() throws {
    var assembler = AnthropicToolStreamAssembler()
    for event in try F32Fixture.events("anthropic", "cut-mid-call") { _ = try assembler.consume(event) }
    assertInvalidResponse { _ = try assembler.finish() }
  }

  func testACallThatIsNeverStoppedRunsNothingEvenIfTheMessageStops() throws {
    var assembler = AnthropicToolStreamAssembler()
    let events = try F32Fixture.events("anthropic", "cut-mid-call")
      + F32Fixture.events(in: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
    for event in events { _ = try assembler.consume(event) }
    assertInvalidResponse { _ = try assembler.finish() }
  }

  func testArgumentsThatNeverFormJSONRunNothing() throws {
    var assembler = AnthropicToolStreamAssembler()
    let events = F32Fixture.events(in: """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-0","name":"Read","input":{}}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"file"}}

      data: {"type":"content_block_stop","index":0}

      """)
    _ = try assembler.consume(events[0])
    _ = try assembler.consume(events[1])
    assertInvalidResponse { _ = try assembler.consume(events[2]) }
  }

  func testReplayMatchesWholeResponse() throws {
    var assembler = AnthropicToolStreamAssembler()
    let turn = try assemble(&assembler, F32Fixture.events("anthropic", "text-then-call")).turn
    let whole: [[String: Any]] = [
      ["type": "text", "text": "I'll check the file now."],
      ["type": "tool_use", "id": "toolu-0", "name": "Read", "input": ["file_path": "/tmp/probe/city.txt"],
       "caller": ["type": "direct"]],
    ]
    XCTAssertEqual(turn, try AnthropicMessagesClient.toolTurn(["content": whole]))
    assertEqualJSON(assembler.assistantContent, whole)
  }

  func testThinkingBlocksAreReplayedWithSignature() throws {
    var assembler = AnthropicToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("anthropic", "thinking-call"))
    XCTAssertEqual(texts, [], "Thinking is never shown as reply text")
    XCTAssertEqual(turn.calls, [.init(id: "toolu-0", name: "get_weather", arguments: #"{"city":"Paris"}"#)])
    assertEqualJSON(assembler.assistantContent, [
      ["type": "thinking", "thinking": "The user wants the weather in Paris. I should call get_weather with city Paris.",
       "signature": "EqQBCgIYAhIMSynthesizedSignatureForTests0000=="],
      ["type": "tool_use", "id": "toolu-0", "name": "get_weather", "input": ["city": "Paris"]],
    ])
  }

  func testSeveralCallsWithTextBetweenKeepTheirOwnArguments() throws {
    var assembler = AnthropicToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events(in: """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-0","name":"get_weather","input":{}}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}

      data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu-1","name":"get_time","input":{}}}

      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"zone\\":"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"Paris\\"}"}}

      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"CET\\"}"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"content_block_stop","index":1}

      data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Both asked."}}

      data: {"type":"content_block_stop","index":2}

      data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu-2","name":"get_weather","input":{}}}

      data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Rome\\"}"}}

      data: {"type":"content_block_stop","index":3}

      data: {"type":"message_stop"}

      """))
    XCTAssertEqual(texts, ["Both asked."])
    XCTAssertEqual(turn.calls, [
      .init(id: "toolu-0", name: "get_weather", arguments: #"{"city":"Paris"}"#),
      .init(id: "toolu-1", name: "get_time", arguments: #"{"zone":"CET"}"#),
      .init(id: "toolu-2", name: "get_weather", arguments: #"{"city":"Rome"}"#),
    ])
    assertEqualJSON(assembler.assistantContent, [
      ["type": "tool_use", "id": "toolu-0", "name": "get_weather", "input": ["city": "Paris"]],
      ["type": "tool_use", "id": "toolu-1", "name": "get_time", "input": ["zone": "CET"]],
      ["type": "text", "text": "Both asked."],
      ["type": "tool_use", "id": "toolu-2", "name": "get_weather", "input": ["city": "Rome"]],
    ])
  }

  func testErrorEventReportsTheProviderMessage() {
    var assembler = AnthropicToolStreamAssembler()
    XCTAssertThrowsError(try assembler.consume(ServerSentEvent(event: "error",
      data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))) {
      XCTAssertEqual($0 as? CloudProviderError, .providerMessage("Overloaded"))
    }
  }

  func testStreamWithoutMessageStopIsADroppedReply() throws {
    var assembler = AnthropicToolStreamAssembler()
    for event in try F32Fixture.events("anthropic", "text").dropLast() { _ = try assembler.consume(event) }
    XCTAssertThrowsError(try assembler.finish()) { XCTAssertEqual($0 as? CloudProviderError, .streamEndedUnexpectedly) }
  }
}

// MARK: - Gemini

final class GeminiToolStreamAssemblerTests: XCTestCase {
  private let signature = "CiQBSynthesizedThoughtSignatureForTests0000"

  func testTextOnly() throws {
    var assembler = GeminiToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("gemini", "text"))
    XCTAssertEqual(texts, ["Hello there,", " nice to meet you!"])
    XCTAssertEqual(turn, .init(text: "Hello there, nice to meet you!", calls: []))
    assertEqualJSON(assembler.modelContent, ["role": "model", "parts": [["text": "Hello there, nice to meet you!"]]])
  }

  func testOneCall() throws {
    var assembler = GeminiToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("gemini", "call"))
    XCTAssertEqual(texts, [])
    XCTAssertEqual(turn.calls, [.init(id: "gemini-call-0", name: "get_weather", arguments: #"{"city":"Paris"}"#)])
  }

  func testTextThenCall() throws {
    var assembler = GeminiToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events("gemini", "text-then-call"))
    XCTAssertEqual(texts, ["Let me check the weather in Paris."])
    XCTAssertEqual(turn, .init(text: "Let me check the weather in Paris.",
      calls: [.init(id: "gemini-call-1", name: "get_weather", arguments: #"{"city":"Paris"}"#)]))
  }

  func testForcedCall() throws {
    var assembler = GeminiToolStreamAssembler()
    XCTAssertEqual(try assemble(&assembler, F32Fixture.events("gemini", "forced")).turn.calls.map(\.name), ["get_weather"])
  }

  func testStreamCutMidCallRunsNothing() throws {
    var assembler = GeminiToolStreamAssembler()
    assertInvalidResponse { _ = try assemble(&assembler, F32Fixture.events("gemini", "cut-mid-call")) }
  }

  func testStreamWithoutAFinishReasonIsADroppedReply() throws {
    var assembler = GeminiToolStreamAssembler()
    for event in try F32Fixture.events("gemini", "text").dropLast() { _ = try assembler.consume(event) }
    XCTAssertThrowsError(try assembler.finish()) { XCTAssertEqual($0 as? CloudProviderError, .streamEndedUnexpectedly) }
  }

  func testReplayMatchesWholeResponse() throws {
    var assembler = GeminiToolStreamAssembler()
    let turn = try assemble(&assembler, F32Fixture.events("gemini", "text-then-call")).turn
    let content: [String: Any] = ["role": "model", "parts": [
      ["text": "Let me check the weather in Paris."],
      ["functionCall": ["name": "get_weather", "args": ["city": "Paris"]], "thoughtSignature": signature],
    ]]
    let (wholeTurn, wholeContent) = try GeminiContentClient.toolTurn(["candidates": [["content": content, "finishReason": "STOP"]]])
    XCTAssertEqual(turn, wholeTurn)
    assertEqualJSON(assembler.modelContent, wholeContent)
  }

  func testThoughtSignatureOnAFinalEmptyPartIsKept() throws {
    var assembler = GeminiToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events(in: """
      data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Thinking","thought":true}]}}]}

      data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}

      data: {"candidates":[{"content":{"role":"model","parts":[{"text":" there"}]}}]}

      data: {"candidates":[{"content":{"role":"model","parts":[{"text":"","thoughtSignature":"sig"}]},"finishReason":"STOP"}]}

      """))
    XCTAssertEqual(texts, ["Hello", " there"], "Thought parts are never shown")
    XCTAssertEqual(turn, .init(text: "Hello there", calls: []))
    assertEqualJSON(assembler.modelContent, ["role": "model", "parts": [
      ["text": "Thinking", "thought": true], ["text": "Hello there", "thoughtSignature": "sig"]]])
  }

  func testSeveralCallsStaySeparate() throws {
    var assembler = GeminiToolStreamAssembler()
    let (texts, turn) = try assemble(&assembler, F32Fixture.events(in: """
      data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Checking both."}]}}]}

      data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"city":"Paris"}},"thoughtSignature":"sig"}]}}]}

      data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_time","args":{"zone":"CET"}}}]},"finishReason":"STOP"}]}

      """))
    XCTAssertEqual(texts, ["Checking both."])
    XCTAssertEqual(turn.calls, [
      .init(id: "gemini-call-1", name: "get_weather", arguments: #"{"city":"Paris"}"#),
      .init(id: "gemini-call-2", name: "get_time", arguments: #"{"zone":"CET"}"#),
    ])
    assertEqualJSON(assembler.modelContent, ["role": "model", "parts": [
      ["text": "Checking both."],
      ["functionCall": ["name": "get_weather", "args": ["city": "Paris"]], "thoughtSignature": "sig"],
      ["functionCall": ["name": "get_time", "args": ["zone": "CET"]]],
    ]])
  }

  func testOtherFinishReasonsFailAsToday() throws {
    var assembler = GeminiToolStreamAssembler()
    XCTAssertThrowsError(try assemble(&assembler, F32Fixture.events(in: """
      data: {"candidates":[{"content":{"role":"model","parts":[{"text":""}]},"finishReason":"SAFETY"}]}

      """))) { XCTAssertEqual($0 as? CloudProviderError, .providerMessage("Gemini stopped the response: SAFETY.")) }
  }

  func testBlockedPromptFailsAsToday() {
    var assembler = GeminiToolStreamAssembler()
    XCTAssertThrowsError(try assembler.consume(ServerSentEvent(event: nil, data: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#))) {
      XCTAssertEqual($0 as? CloudProviderError, .providerMessage("Gemini could not analyze this request."))
    }
  }
}

// MARK: - Transport

/// Answers every request with a status and body, or with a stream that never ends.
private final class StreamingTransport: CloudNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var terminated = false
  let statusCode: Int
  let body: String
  let hangs: Bool
  var wasTerminated: Bool { lock.withLock { terminated } }

  init(statusCode: Int = 200, body: String = "", hangs: Bool = false) {
    self.statusCode = statusCode
    self.body = body
    self.hangs = hangs
  }

  func data(for request: URLRequest) async throws -> CloudDataResponse { throw CloudProviderError.invalidResponse }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { @Sendable _ in self.lock.withLock { self.terminated = true } }
      continuation.yield(.response(statusCode: statusCode))
      continuation.yield(.data(Data(body.utf8)))
      if !hangs { continuation.finish() }
    }
  }
}

final class CloudToolStreamPostTests: XCTestCase {
  private let url = URL(string: "https://api.anthropic.com/v1/messages")!

  func testEventsArriveInOrder() async throws {
    let transport = StreamingTransport(body: try F32Fixture.text("anthropic", "text"))
    var names: [String?] = []
    for try await event in CloudToolLoop.streamPost(url, headers: [:], body: [:], provider: .anthropic, transport: transport) {
      names.append(event.event)
    }
    XCTAssertEqual(names.first, "message_start")
    XCTAssertEqual(names.last, "message_stop")
  }

  func testHTTPErrorsMapAsToday() async throws {
    let cases: [(Int, CloudProviderError)] = [
      (401, .authenticationFailed(.anthropic)), (429, .rateLimited(.anthropic)),
      (500, .requestFailed(statusCode: 500, message: "Overloaded")),
    ]
    for (status, expected) in cases {
      let transport = StreamingTransport(statusCode: status, body: #"{"error":{"message":"Overloaded"}}"#)
      do {
        for try await _ in CloudToolLoop.streamPost(url, headers: [:], body: [:], provider: .anthropic, transport: transport) {}
        XCTFail("Expected HTTP \(status) to fail")
      } catch { XCTAssertEqual(error as? CloudProviderError, expected) }
    }
  }

  func testCancellationStopsTheByteStream() async throws {
    let transport = StreamingTransport(body: try F32Fixture.text("anthropic", "cut-mid-call"), hangs: true)
    let started = expectation(description: "first event")
    let events = CloudToolLoop.streamPost(url, headers: [:], body: [:], provider: .anthropic, transport: transport)
    let task = Task {
      var fulfilled = false
      for try await _ in events {
        if !fulfilled { started.fulfill(); fulfilled = true }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    _ = await task.result
    for _ in 0..<100 where !transport.wasTerminated { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(transport.wasTerminated)
  }
}
