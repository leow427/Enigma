# CP2: Cloud streaming

Read [agent-workflow.md](agent-workflow.md), the spec (§3, "Failure
handling", "Testing"), and the Hand-offs of [CP0](cp0-probe-and-flags.md#hand-off)
and [CP1](cp1-permissions.md#hand-off). CP0's Hand-off has the event names
and forced-choice answers this checkpoint relies on.

## Goal

The OpenAI, Anthropic and Gemini tool loops stream: text reaches the chat as
it arrives, tool calls are assembled from the stream, and a toolbox can
require one tool on the first step. Behavior is otherwise identical to
today's loops (same tools, one call at a time, 12 steps, same replay rules,
same errors).

## Starting point

- `CloudToolLoop` (`Enigma/Cloud/CloudToolCalling.swift`):
  `run(toolbox:emit:step:deliver:)` emits a step's text only after the step
  returns; `post(…)` is a non-streaming `transport.data(for:)`.
- Per provider, `toolTurn(_:)` parses a whole response:
  - OpenAI: `output[]` `message`/`function_call` (`call_id`, `name`,
    `arguments`); `replayable` drops `id`/`status` and reasoning items;
    body has `parallel_tool_calls: false`, `store: false`, `reasoning` when
    `ThinkCommand.enabled(in:)`.
  - Anthropic: `content[]` `text`/`tool_use`; the assistant content is
    appended to `messages` unchanged; think mode via `Self.thinking(modelID:)`.
  - Gemini: parts, skipping `thought`; synthesized `gemini-call-N` IDs;
    `geminiSchema` strips `additionalProperties`; endpoint hardcoded to
    `:generateContent`.
- Streaming helpers: `ServerSentEventParser.append(_:)`/`finish()`;
  `CloudNetworkTransport.stream(for:) -> AsyncThrowingStream<CloudNetworkEvent, Error>`
  (`.response(statusCode:)`, `.data(Data)`).
- Tests: `CloudToolLoopTests` and friends in
  `EnigmaTests/MessagesToolCallingTests.swift` (`QueuedTransport`,
  `RecordingToolbox`, `StoppingToolbox`).

## Interfaces

**Produces:**

```swift
// AgentToolLoop.swift — AgentToolbox
var requiredTool: String? { get }      // default nil in the protocol extension
// CloudToolCalling.swift
static func run(toolbox: any AgentToolbox, emit: (ChatEvent) -> Void,
                step: (_ isFirst: Bool, _ onText: (String) -> Void) async throws -> Turn,
                deliver: ([(Call, AgentToolResult)]) throws -> Void) async throws
static func streamPost(_ url: URL, headers: [String: String], body: [String: Any],
                       provider: CloudProviderID, transport: any CloudNetworkTransport)
  -> AsyncThrowingStream<ServerSentEvent, Error>   // non-2xx → today's cloudHTTPError
// Enigma/Cloud/CloudToolStreaming.swift
protocol ToolStreamAssembler {
  /// Returns any text delta in this event.
  mutating func consume(_ event: ServerSentEvent) throws -> String?
  /// The finished turn; throws CloudProviderError.invalidResponse if a call is incomplete.
  func finish() throws -> CloudToolLoop.Turn
}
struct OpenAIToolStreamAssembler: ToolStreamAssembler { var replayItems: [[String: Any]] { get } }
struct AnthropicToolStreamAssembler: ToolStreamAssembler { var assistantContent: [[String: Any]] { get } }
struct GeminiToolStreamAssembler: ToolStreamAssembler { var modelContent: [String: Any]? { get } }
```

`replayItems`, `assistantContent` and `modelContent` must equal what
today's whole-response parsing appends to the history for the same turn
(including Anthropic `thinking` blocks with their signatures and Gemini
thought signatures).

## Tasks

### Task 2.1: `requiredTool` and the loop

**Files:** `AgentToolLoop.swift`, `CloudToolCalling.swift`; tests in
`MessagesToolCallingTests.swift` (`CloudToolLoopTests`).

- [ ] **Write failing tests:** `testTextIsEmittedBeforeTheStepEnds` (a step
  that calls `onText` twice before returning emits two `.token` events in
  order, then the call runs); `testFirstStepIsFlagged` (`isFirst` true only
  on step 0); existing loop tests keep passing.
- [ ] **Implement:** `run` passes `onText` through to `emit(.token(…))`,
  keeping today's `"\n\n"` separator between steps' text.

### Task 2.2: Assemblers

**Files:** create `Enigma/Cloud/CloudToolStreaming.swift`; tests in new
`EnigmaTests/CloudToolStreamingTests.swift` reading CP0's fixtures.

- [ ] **Write failing tests,** per provider, from the fixtures:
  - `testTextOnly`: text deltas concatenate to the fixture's text; no calls.
  - `testOneCall`: one `Call` with the fixture's name and arguments JSON.
  - `testTextThenCall`: text emitted, then the call.
  - `testForcedCall`: a call with the forced name.
  - `testStreamCutMidCallRunsNothing`: `finish()` throws; no `Call`.
  - `testReplayMatchesWholeResponse`: the replay content equals what the
    existing `toolTurn` path produces for the same turn (build the
    equivalent whole response in the test).
  - Anthropic only: `testThinkingBlocksAreReplayedWithSignature`.
- [ ] **Implement** each assembler from CP0's event names. OpenAI: text from
  `response.output_text.delta`; items from `response.output_item.done`;
  `response.completed`/`incomplete` as today. Anthropic: blocks from
  `content_block_start`/`delta` (`text_delta`, `input_json_delta`,
  `thinking_delta`, `signature_delta`)/`stop`. Gemini: each SSE chunk's
  `candidates[0].content.parts`, merged.

### Task 2.3: Wire the three providers

**Files:** `CloudToolCalling.swift` (and `GeminiContentClient.swift` if the
endpoint moves to a property).

- [ ] **Write failing tests** with `QueuedTransport` serving fixtures:
  `testOpenAIToolLoopStreams`, `testAnthropicToolLoopStreams`,
  `testGeminiToolLoopStreams` (text arrives as tokens; a call runs; the
  second request's history contains the replay content);
  `testRequiredToolIsSentOnFirstStepOnly` per provider (the forced-choice
  body from CP0 on step 0, absent after).
- [ ] **Implement:** each provider's `step` sends `"stream": true` (Gemini:
  `:streamGenerateContent?alt=sse`) through `streamPost`, feeds events to its
  assembler, calls `onText` for each text delta, and returns `finish()`.
  Keep every other body key as today. Delete `post` only if nothing else
  uses it.

## Exit criteria

- `build`, `test`, `analyze` pass; existing `CloudToolLoopTests`,
  `MessagesRequestTests` and provider tests pass unedited.
- Codex and Claude Code untouched except reading `requiredTool` if CP0
  found a way to force a tool there (otherwise unchanged).

## Reviewer checklist

- A half-built call never executes; cancellation stops the byte stream.
- Replay content is byte-for-byte what the old path appended (thinking
  signatures included).
- Errors (HTTP status, `incomplete`, malformed JSON) map to today's errors.
- Fixtures drive every branch; mutation-test the cut-mid-call path.

## Hand-off

*Filled in by the CP2 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP1's CI result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
