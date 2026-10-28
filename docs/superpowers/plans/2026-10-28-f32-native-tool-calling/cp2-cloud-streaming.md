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

1. **Summary:** The OpenAI, Anthropic and Gemini tool loops now stream. Each
   step posts with `"stream": true` (Gemini: `:streamGenerateContent?alt=sse`)
   through `CloudToolLoop.streamPost`, feeds the events to its provider's
   assembler, and shows text deltas as they arrive. Calls come only from the
   assembler's `finish()`, after the stream ends, so a cut stream runs
   nothing. `AgentToolbox.requiredTool` (default nil) forces that tool on
   the first step. Nothing sets it yet, so today's toolboxes send the same
   bodies as before plus `stream`. Codex and Claude Code are unchanged.

2. **Files:**
   - `Enigma/Cloud/CloudToolStreaming.swift` (new): `ToolStreamAssembler`
     and the three assemblers.
   - `Enigma/Cloud/CloudToolCalling.swift`: `run` takes
     `step: (isFirst, onText)` and streams text through `StepText`; a
     whole-turn `run` overload for steps that return their text at once
     (used by an existing test); `streamPost` and `streamStep`; the three
     providers stream and send the forced choice; `post` deleted (nothing
     else used it).
   - `Enigma/Chat/AgentToolLoop.swift`: `requiredTool` (default nil) and
     `offeredRequiredTool` (the required tool only if the toolbox defines it).
   - `EnigmaTests/CloudToolStreamingTests.swift` (new): `F32Fixture`, the
     per-provider assembler tests, and `streamPost` tests (HTTP errors,
     cancellation).
   - `EnigmaTests/MessagesToolCallingTests.swift`: `QueuedTransport` also
     serves streams (see Decisions); new loop and provider tests in an
     extension of `CloudToolLoopTests`; the one Gemini endpoint assertion.
   - `Enigma.xcodeproj/project.pbxproj`: the two new files.
   - `docs/Messages.md`: removed the limitation saying API routes answer
     each model turn whole (review round 1); they now stream.
   - The plan's progress log, and this Hand-off.

3. **Decisions:**
   - **CP1's CI:** the run on `c92627b` passed (`build-and-test`, 9m1s).
   - **Existing tests and the streaming switch (owner, 2026-10-28).** Six
     existing tests served whole JSON responses, and
     `testGeminiReturnsFunctionResponsesAndStripsUnsupportedSchema` asserted
     the `:generateContent` endpoint, so "pass unedited" and "stream" could
     not both hold. The owner chose to adapt the shared helper:
     `QueuedTransport.stream(for:)` turns each queued whole response into
     that provider's event stream (Anthropic blocks with one delta each;
     OpenAI `output_text.delta`, `output_item.done` per item and
     `response.<status>`; Gemini one chunk). No test body changed except that
     endpoint assertion, now `:streamGenerateContent?alt=sse`.
   - **Text is shown exactly as before.** Today's loop trimmed each step's
     text and put a blank line between steps. `StepText` holds back leading
     and trailing whitespace, so the streamed deltas join to the same text.
   - **Assemblers reuse today's parsers.** `finish()` rebuilds the whole
     response (`output` + `status`; `content`; one candidate with the merged
     content and `finishReason`) and passes it to the existing `toolTurn`, so
     call IDs, `incomplete`, finish reasons and arguments behave as before.
   - **Failures:** a call that started but never finished (OpenAI added
     without done; an Anthropic block without stop) or arguments that aren't a
     JSON object → `invalidResponse`, before or regardless of a later
     completion event. A stream with no completion event (`response.completed`
     or `incomplete`, `message_stop`, a Gemini `finishReason`) →
     `streamEndedUnexpectedly`, as the plain cloud clients do. Provider error
     events → `providerMessage` with the provider's message.
   - **Gemini merging:** adjacent text parts with the same `thought` flag are
     joined, and a signature on a later (often empty) part moves onto the
     joined part; a part that already has a signature, and every
     `functionCall` part, stays separate. Thought text is never shown.
   - **Forced choice:** OpenAI `tool_choice {"type":"function","name"}`,
     Anthropic `{"type":"tool","name"}`, Gemini `toolConfig.functionCallingConfig
     {mode: "ANY", allowedFunctionNames}` — first step only, and only when the
     toolbox defines the tool. Anthropic with extended thinking (`/think`)
     sends no `tool_choice`, since only `auto` is allowed there; CP4's
     instruction covers it.
   - **Empty deltas** are returned as nil, so the chat never gets an empty
     token.
   - **OpenAI `[DONE]`** is ignored, as the plain OpenAI client accepts it
     (review round 1); completion still needs `response.completed`.
   - **Review round 1** (4 Should fix, no Blocker): added several-calls
     tests per provider, a test that a required tool the toolbox doesn't
     define is never forced, the `[DONE]` fix, and the `docs/Messages.md`
     line. The three mutations the reviewer found surviving (no
     `offeredRequiredTool` guard, Anthropic argument deltas sent to every
     open block, OpenAI items not ordered by `output_index`) now each fail a
     test. Round 2 found no Blocker or Should fix.

4. **Verification:**
   - Test-first: the new tests failed to compile (no assemblers, no
     `streamPost`, no two-argument `step`) before the code existed. The first
     run after implementing failed one test (an empty Gemini delta was
     reported), fixed by returning nil for empty deltas.
   - `scripts/verify-xcode.sh test -only-testing:EnigmaTests/CloudToolLoopTests
     -only-testing:EnigmaTests/OpenAIToolStreamAssemblerTests
     -only-testing:EnigmaTests/AnthropicToolStreamAssemblerTests
     -only-testing:EnigmaTests/GeminiToolStreamAssemblerTests
     -only-testing:EnigmaTests/CloudToolStreamPostTests
     -only-testing:EnigmaTests/MessagesRequestTests`: 72 executed, 0 failed.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, 0
     warnings. Full `test`: 1425 executed, 25 skipped, 0 failed.
   - After review round 1: the `[DONE]` test failed first (`invalidResponse`);
     the CP2 classes then ran 62 executed, 0 failed. Full `test`: 1430 executed, 25 skipped,
     1 failed, the known load-sensitive
     `testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`,
     which passed alone. Round 2's reviewer then ran the CP2 classes (77,
     0 failed), the full `test` (1430 executed, 25 skipped, 0 failed) and
     `analyze` (0 warnings), and found nothing to fix; `build` succeeded
     after the fixes.
   - No live runs.
   - CI: recorded by the CP3 worker.

5. **Limitations:**
   - The OpenAI and Gemini fixtures, and Anthropic's thinking stream, are
     from the docs (CP0). The assemblers match them and today's parsers, but
     live streams are unverified until the owner records them before CP5.
   - Forced choice is checked in the request bodies only, never against a
     live provider.

6. **For the next checkpoint:**
   - `CloudToolLoop.run`'s `step` is `(isFirst, onText)`; call `onText` per
     delta and the loop does the trimming and the blank line between steps.
     A step that returns text whole can use the zero-argument overload.
   - Use `toolbox.offeredRequiredTool`, not `requiredTool`, when building a
     request: it is nil when the toolbox doesn't define that tool.
   - `QueuedTransport(streams:)` serves recorded fixtures; `F32Fixture`
     (in `CloudToolStreamingTests.swift`) loads them.
