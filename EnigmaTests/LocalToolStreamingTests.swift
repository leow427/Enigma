import Darwin
import XCTest
@testable import Enigma

/// F32 CP3: streamed tool calls on the `llama-server` every catalogue model already runs
/// on. A stub server replays CP0's recorded `Fixtures/F32/llama` streams.
final class LocalToolStreamingTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalToolStreamingTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private let weather = AgentToolDefinition(name: "get_weather", description: "Get the current weather for a city.",
    properties: ["city": .object(["type": .string("string")])], required: ["city"])

  private func messages(_ prompt: String = "What's the weather in Paris?") -> [AgentInferenceMessage] {
    [AgentInferenceMessage(role: "system", content: "You can look up the weather."),
     AgentInferenceMessage(role: "user", content: prompt)]
  }

  func testLocalTextStreams() async throws {
    for family in ["", "qwen38/"] {
      let model = try stubModel(serving: family + "text")
      let runtime = LlamaServerVisionEngine()
      let events = try await Self.collect(runtime.streamTools(messages: messages("Say hello."), tools: [weather],
                                                         model: model, requiredTool: nil))
      let expected = try Self.fixtureText(family + "text")
      XCTAssertFalse(expected.isEmpty)
      XCTAssertGreaterThan(events.texts.count, 1, "Text arrives as several deltas, not at the end")
      XCTAssertEqual(events.texts.joined(), expected)
      XCTAssertEqual(events.messages.count, 1)
      guard case .message(let message) = events.last else { return XCTFail("The finished message comes last") }
      XCTAssertEqual(message.role, "assistant")
      XCTAssertEqual(message.content, expected)
      XCTAssertTrue(message.toolCalls?.isEmpty ?? true)
      await runtime.unload()
    }
  }

  func testLocalCallIsAssembled() async throws {
    for family in ["", "qwen38/"] {
      for name in ["call", "text-then-call", "thinking-call"] {
        if family == "qwen38/" && name == "thinking-call" { continue }
        let model = try stubModel(serving: family + name)
        let runtime = LlamaServerVisionEngine()
        let events = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
        let expectedText = try Self.fixtureText(family + name)
        XCTAssertEqual(events.texts.joined(), expectedText, "\(family)\(name): reasoning is never shown")
        XCTAssertEqual(events.messages.count, 1)
        guard case .message(let message) = events.last else { XCTFail("\(family)\(name): no message"); continue }
        XCTAssertEqual(message.toolCalls?.count, 1, "\(family)\(name)")
        XCTAssertEqual(message.toolCalls?.first?.function.name, "get_weather")
        XCTAssertEqual(message.toolCalls?.first?.function.arguments, #"{"city":"Paris"}"#)
        XCTAssertEqual(message.content ?? "", expectedText)
        await runtime.unload()
      }
    }
  }

  func testLocalStreamCutMidCallRunsNothing() async throws {
    for family in ["", "qwen38/"] {
      let model = try stubModel(serving: family + "cut-mid-call")
      let runtime = LlamaServerVisionEngine()
      var events: [LocalToolStreamEvent] = []
      do {
        for try await event in runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil) {
          events.append(event)
        }
        XCTFail("A stream cut mid-call must fail")
      } catch {
        XCTAssertEqual(error as? CloudProviderError, .streamEndedUnexpectedly)
      }
      XCTAssertTrue(events.messages.isEmpty, "A half-built call never reaches the loop")
      // A failed request stops the server, as a failed plain turn does.
      try await waitFor { await runtime.runtimeProcessIdentifier() == nil }
    }
  }

  func testStreamPayload() async throws {
    let model = try stubModel(serving: "call")
    let runtime = LlamaServerVisionEngine()
    _ = try await runtime.completeTools(messages: messages(), tools: [weather], model: model)
    _ = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
    _ = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: "get_weather"))
    await runtime.unload()

    let completions = try requestLog().filter { $0["path"].string == "/v1/chat/completions" }.map { $0["body"] }
    XCTAssertEqual(completions.count, 3)
    let (whole, streamed, forced) = (completions[0], completions[1], completions[2])
    XCTAssertEqual(whole["stream"], .bool(false))
    XCTAssertEqual(whole["cache_prompt"], .bool(false))
    XCTAssertEqual(streamed["stream"], .bool(true))
    XCTAssertEqual(streamed["cache_prompt"], .bool(true))
    XCTAssertEqual(streamed["tool_choice"], .string("auto"))
    XCTAssertEqual(forced["tool_choice"], .string("required"))
    func without(_ value: CodexValue, _ keys: [String]) -> [String: CodexValue] {
      guard case .object(var object) = value else { return [:] }
      for key in keys { object[key] = nil }
      return object
    }
    XCTAssertEqual(without(streamed, ["stream", "cache_prompt"]), without(whole, ["stream", "cache_prompt"]),
                   "Apart from streaming and the cache, a streamed step sends what completeTools sends")

    // A forced tool also gets an instruction (Qwen ignores `required`), on the last user
    // message of that request only, so the system prompt and tools stay a cacheable prefix.
    XCTAssertEqual(forced["tools"], streamed["tools"])
    let forcedMessages = try XCTUnwrap(forced["messages"].array)
    let streamedMessages = try XCTUnwrap(streamed["messages"].array)
    XCTAssertEqual(forcedMessages.first, streamedMessages.first)
    XCTAssertEqual(forcedMessages.last?["content"].string,
                   (streamedMessages.last?["content"].string ?? "") + "\n\n" + LlamaServerVisionEngine.requiredToolInstruction("get_weather"))
    XCTAssertEqual(without(forced, ["tool_choice", "messages"]), without(streamed, ["tool_choice", "messages"]))

    // The budget check renders and tokenizes the exact streamed request first.
    let templates = try requestLog().filter { $0["path"].string == "/apply-template" }.map { $0["body"] }
    XCTAssertEqual(templates.count, 3)
    XCTAssertEqual(templates[1], streamed)
  }

  func testNoReloadBetweenTurns() async throws {
    let model = try stubModel(serving: "call")
    let runtime = LlamaServerVisionEngine()
    _ = try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "Hello")],
      image: nil, model: model), maximumBytes: 100)
    let plain = await runtime.runtimeProcessIdentifier()
    XCTAssertNotNil(plain)
    for _ in 0..<2 {
      _ = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
      let pid = await runtime.runtimeProcessIdentifier()
      XCTAssertEqual(pid, plain, "A tool turn reuses the server a plain turn loaded")
    }
    _ = try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "Hello")],
      image: nil, model: model), maximumBytes: 100)
    let afterPlain = await runtime.runtimeProcessIdentifier()
    XCTAssertEqual(afterPlain, plain, "A plain turn reuses the server a tool turn used")

    let other = LocalModel(id: "other", displayName: "Other", fileURL: model.fileURL, visionConfiguration: model.visionConfiguration)
    _ = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: other, requiredTool: nil))
    let switched = await runtime.runtimeProcessIdentifier()
    XCTAssertNotNil(switched)
    XCTAssertNotEqual(switched, plain, "A different model restarts the server")
    await runtime.unload()
    if let plain { try await waitFor { Darwin.kill(plain, 0) != 0 } }
  }

  func testToolStreamSchedulesIdleUnload() async throws {
    let model = try stubModel(serving: "text")
    let deadline = ControlledLocalIdleSleep()
    let runtime = LlamaServerVisionEngine(idleSleep: { try await deadline.sleep($0) })
    addTeardownBlock { await runtime.unload(); await deadline.close() }
    _ = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
    await fulfillment(of: [deadline.armed[0]], timeout: 2)
    let delays = await deadline.delays
    XCTAssertEqual(delays, [LocalModelIdlePolicy.unloadDelay])
    let identifier = await runtime.runtimeProcessIdentifier()
    let pid = try XCTUnwrap(identifier)
    await deadline.expire(0)
    try await waitFor { await runtime.runtimeProcessIdentifier() == nil }
    try await waitFor { Darwin.kill(pid, 0) != 0 }
  }

  func testCancelledToolStreamStopsTheRequestAndKeepsTheServerWarm() async throws {
    let model = try stubModel(serving: "text")
    let runtime = LlamaServerVisionEngine()
    addTeardownBlock { await runtime.unload() }
    try Data("hold".utf8).write(to: directory.appending(path: "mode"))
    let held = Task {
      try await collectToolEvents(runtime.streamTools(messages: heldMessages, tools: [heldTool], model: model, requiredTool: nil))
    }
    try await waitFor { FileManager.default.fileExists(atPath: self.directory.appending(path: "request-started").path) }
    let identifier = await runtime.runtimeProcessIdentifier()
    let pid = try XCTUnwrap(identifier)
    held.cancel()
    do { _ = try await held.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    // The HTTP request is closed, so the server stops generating...
    try await waitFor { FileManager.default.fileExists(atPath: self.directory.appending(path: "disconnected").path) }
    // ...and stays loaded for the next turn.
    let warm = await runtime.runtimeProcessIdentifier()
    XCTAssertEqual(warm, pid)
    try FileManager.default.removeItem(at: directory.appending(path: "mode"))
    let events = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
    XCTAssertEqual(events.texts.joined(), try Self.fixtureText("text"))
    let reused = await runtime.runtimeProcessIdentifier()
    XCTAssertEqual(reused, pid)
  }

  func testCancellingBeforeTheStreamStartsStopsTheServer() async throws {
    let model = try stubModel(serving: "text")
    let runtime = LlamaServerVisionEngine()
    try Data("hold-tokenizer".utf8).write(to: directory.appending(path: "mode"))
    let held = Task {
      try await collectToolEvents(runtime.streamTools(messages: heldMessages, tools: [heldTool], model: model, requiredTool: nil))
    }
    try await waitFor { FileManager.default.fileExists(atPath: self.directory.appending(path: "tokenizer-started").path) }
    held.cancel()
    do { _ = try await held.value; XCTFail("Expected cancellation") } catch { }
    // Cancelling while the request is being prepared stops the server, as plain turns do.
    try await waitFor { await runtime.runtimeProcessIdentifier() == nil }
  }

  func testStoppedToolStreamSchedulesIdleUnload() async throws {
    let model = try stubModel(serving: "text")
    let deadline = ControlledLocalIdleSleep()
    let runtime = LlamaServerVisionEngine(idleSleep: { try await deadline.sleep($0) })
    addTeardownBlock { await runtime.unload(); await deadline.close() }
    try Data("hold".utf8).write(to: directory.appending(path: "mode"))
    let held = Task {
      try await collectToolEvents(runtime.streamTools(messages: heldMessages, tools: [heldTool], model: model, requiredTool: nil))
    }
    try await waitFor { FileManager.default.fileExists(atPath: self.directory.appending(path: "request-started").path) }
    let identifier = await runtime.runtimeProcessIdentifier()
    let pid = try XCTUnwrap(identifier)
    held.cancel()
    _ = try? await held.value
    // The kept server still goes after the usual idle delay.
    await fulfillment(of: [deadline.armed[0]], timeout: 2)
    let delays = await deadline.delays
    XCTAssertEqual(delays, [LocalModelIdlePolicy.unloadDelay])
    await deadline.expire(0)
    try await waitFor { await runtime.runtimeProcessIdentifier() == nil }
    try await waitFor { Darwin.kill(pid, 0) != 0 }
  }

  func testOverlongToolStreamFailsWithTheChatContextError() async throws {
    let model = try stubModel(serving: "text")
    let runtime = LlamaServerVisionEngine()
    addTeardownBlock { await runtime.unload() }
    do {
      _ = try await Self.collect(runtime.streamTools(messages: messages(String(repeating: "word ", count: 10_000)),
                                                     tools: [weather], model: model, requiredTool: nil))
      XCTFail("A request over the context window must fail")
    } catch {
      let window = LocalFileRuntime.contextWindow(for: model)
      XCTAssertEqual(error as? ChatContextError, .oversizedPrompt(inputLimit: window - 1_024 - 64),
                     "A chat turn gets the chat's context error, not File Mode's")
    }
    XCTAssertFalse(try requestLog().contains { $0["path"].string == "/v1/chat/completions" }, "Nothing is generated")
  }

  func testLengthAfterTextEndsTheAnswerAndKeepsTheServer() async throws {
    // A plain turn ends at its limit without an error; so does a streamed tool step.
    let model = try stubModel(serving: "text", finishReason: ("stop", "length"))
    let runtime = LlamaServerVisionEngine()
    addTeardownBlock { await runtime.unload() }
    let events = try await Self.collect(runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil))
    let expected = try Self.fixtureText("text")
    XCTAssertEqual(events.texts.joined(), expected)
    guard case .message(let message) = events.last else { return XCTFail("The truncated answer still finishes") }
    XCTAssertEqual(message.content, expected)
    XCTAssertTrue(message.toolCalls?.isEmpty ?? true)
    let pid = await runtime.runtimeProcessIdentifier()
    XCTAssertNotNil(pid, "A server that answered stays loaded")
  }

  func testUnusableAnswersFailInChatWordingAndKeepTheServer() async throws {
    let cases: [(fixture: String, finishReason: (String, String)?, raw: String?)] = [
      ("call", ("tool_calls", "length"), nil),  // the limit cut a call
      ("text", nil, """
        data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}

        data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}

        data: [DONE]

        """),  // an empty answer
    ]
    for item in cases {
      let model = try stubModel(serving: item.fixture, finishReason: item.finishReason, raw: item.raw)
      let runtime = LlamaServerVisionEngine()
      _ = try await ScreenSearchContext.collect(runtime.stream(messages: [ChatMessage(role: .user, content: "Hello")],
        image: nil, model: model), maximumBytes: 100)
      let before = await runtime.runtimeProcessIdentifier()
      var events: [LocalToolStreamEvent] = []
      do {
        for try await event in runtime.streamTools(messages: messages(), tools: [weather], model: model, requiredTool: nil) {
          events.append(event)
        }
        XCTFail("\(item.fixture): an unusable answer must fail")
      } catch {
        guard case .invalidResponse = error as? AgentToolError else { XCTFail("\(item.fixture): \(error)"); continue }
        XCTAssertFalse(error.localizedDescription.contains("Review"), "Chat wording, not File Mode's")
      }
      XCTAssertTrue(events.messages.isEmpty, "\(item.fixture): no call runs")
      let after = await runtime.runtimeProcessIdentifier()
      XCTAssertNotNil(after)
      XCTAssertEqual(after, before, "\(item.fixture): the server answered, so it stays loaded")
      await runtime.unload()
    }
  }

  // MARK: Helpers

  private static func collect(_ stream: AsyncThrowingStream<LocalToolStreamEvent, Error>) async throws -> [LocalToolStreamEvent] {
    try await collectToolEvents(stream)
  }

  private func waitFor(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { return XCTFail("Condition did not hold in time") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func requestLog() throws -> [CodexValue] {
    try String(contentsOf: directory.appending(path: "requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONDecoder().decode(CodexValue.self, from: Data($0.utf8)) }
  }

  private static func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/F32/llama/\(name).txt")
  }

  /// The answer text of a recorded stream: every `delta.content`, joined.
  private static func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL(name), encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("data: {"),
            let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
            let choice = (object["choices"] as? [[String: Any]])?.first,
            let delta = choice["delta"] as? [String: Any] else { return nil }
      return delta["content"] as? String
    }.joined()
  }

  /// A model whose `llama-server` is a stub that replays a recorded tool stream, answers
  /// plain streams and whole tool completions, and logs every request.
  /// `finishReason` swaps the recorded stream's finish reason; `raw` replaces the stream.
  private func stubModel(serving fixture: String, finishReason: (String, String)? = nil, raw: String? = nil) throws -> LocalModel {
    var stream = try String(contentsOf: Self.fixtureURL(fixture), encoding: .utf8)
    if let (old, new) = finishReason {
      XCTAssertTrue(stream.contains(#""finish_reason":"\#(old)""#))
      stream = stream.replacingOccurrences(of: #""finish_reason":"\#(old)""#, with: #""finish_reason":"\#(new)""#)
    }
    try Data((raw ?? stream).utf8).write(to: directory.appending(path: "stream.txt"))
    let header = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]) + Data(repeating: 0, count: 24)
    let file = directory.appending(path: "model.gguf"), projector = directory.appending(path: "mmproj.gguf")
    if !FileManager.default.fileExists(atPath: file.path) {
      try header.write(to: file)
      try header.write(to: projector)
    }
    let server = directory.appending(path: "stub-server")
    let script = #"""
    #!/usr/bin/python3
    import http.server, json, sys, pathlib, threading, time
    port = int(sys.argv[sys.argv.index('--port') + 1])
    alias = sys.argv[sys.argv.index('--alias') + 1]
    root = pathlib.Path(__file__).parent
    def mode():
        path = root / 'mode'
        return path.read_text() if path.exists() else ''
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            self.send_response(200); self.end_headers()
            self.wfile.write(json.dumps({'data': [{'id': alias}]} if self.path == '/v1/models' else {'status': 'ok'}).encode())
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            with (root / 'requests.jsonl').open('a') as log:
                log.write(json.dumps({'path': self.path, 'body': body}) + '\n')
            if self.path in ['/apply-template', '/tokenize']:
                if self.path == '/tokenize' and mode() == 'hold-tokenizer':
                    (root / 'tokenizer-started').write_text('ready')
                    threading.Event().wait()
                result = {'prompt': json.dumps(body['messages'])} if self.path == '/apply-template' else {'tokens': list(range((len(body['content']) + 3) // 4))}
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                self.wfile.write(json.dumps(result).encode()); return
            if not body.get('stream'):
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                self.wfile.write(json.dumps({'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': 'whole'}}]}).encode())
                return
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            if 'tools' not in body:
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"fixture answer"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
                return
            if mode() == 'hold':
                (root / 'request-started').write_text('ready')
                try:
                    while True:
                        self.wfile.write(b': waiting\n\n'); self.wfile.flush(); time.sleep(0.02)
                except Exception:
                    (root / 'disconnected').write_text('closed')
                return
            for line in (root / 'stream.txt').read_bytes().splitlines(keepends=True):
                self.wfile.write(line); self.wfile.flush()
    http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
    """#
    try Data(script.utf8).write(to: server)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    return LocalModel(id: "stub", displayName: "Stub", fileURL: file,
      visionConfiguration: LocalVisionConfiguration(projectorURL: projector, serverExecutableURL: server))
  }
}

// File-level, so tasks can use them without capturing the test class (CI's Xcode 26.6
// region checker rejects a `Self` reference inside those closures).
private let heldTool = AgentToolDefinition(name: "get_weather", description: "Get the current weather for a city.",
  properties: ["city": .object(["type": .string("string")])], required: ["city"])
private let heldMessages = [AgentInferenceMessage(role: "user", content: "What's the weather in Paris?")]

private func collectToolEvents(_ stream: AsyncThrowingStream<LocalToolStreamEvent, Error>) async throws -> [LocalToolStreamEvent] {
  var events: [LocalToolStreamEvent] = []
  for try await event in stream { events.append(event) }
  try Task.checkCancellation()
  return events
}

private extension Array where Element == LocalToolStreamEvent {
  var texts: [String] { compactMap { if case .text(let text) = $0 { text } else { nil } } }
  var messages: [AgentInferenceMessage] { compactMap { if case .message(let message) = $0 { message } else { nil } } }
}
