# CP3: Local on llama-server

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "Local",
"Failure handling"), and the Hand-offs of CP0–CP2. CP0's Hand-off says which
families stream tool calls and whether `tool_choice: "required"` works.

## Goal

Flagged local models stream text and tool calls from the `llama-server`
every catalogue model already runs on (each is a vision model, so plain
turns go through `submitScreen`'s vision path today), with the prompt prefix
cached and no model reload between turns. No new runtime or install step.
Nothing calls this on a live route yet (CP4).

## Starting point

- `actor LlamaServerVisionEngine: LocalVisionServing, LocalToolInference`
  (`Enigma/LocalInference/LlamaServerVisionEngine.swift`):
  `load(_:requestID:)` picks a port, starts the process, polls `/health`;
  `unload()`; `scheduleIdleUnload(id:)` with `LocalModelIdlePolicy.unloadDelay`;
  `generate` and `completeTools` both unload any active server first.
- `completeTools` posts non-streaming JSON built by `LocalFileRuntime.payload`
  (`Enigma/Files/LocalFileInference.swift`): `tool_choice: "auto"`,
  `parallel_tool_calls: false`, `chat_template_kwargs.enable_thinking`,
  `reasoning_budget`, `"stream": false`, `temperature: 0`,
  `cache_prompt: false`; parsed by `LocalFileRuntime.response`; it first
  runs `apply-template`/`tokenize` to check the budget.
- Streaming text already exists for vision: `LocalMultimodalClient.stream`
  (`LocalMultimodalClient.swift`).
- `LocalToolAgent` (`Enigma/Chat/AgentToolLoop.swift`) runs one call per
  step through `completeTools` and calls `onText` once at the end.
- Runtime: `LocalFileToolsInstallation.isReady(for:)`,
  `LocalFileRuntimeSetup.install(session:activity:…)`,
  `LocalFileRuntime.executable(for:)`.
- View model seams: `fileInference`, `localToolRuntime` in
  `LocalChatViewModel.init`; `engine.unload()` before the server loads
  (see `submitMessages`).

## Interfaces

**Consumes:** `AgentToolbox.requiredTool` (CP2).

**Produces:**

```swift
// AgentFileTools.swift
enum LocalToolStreamEvent: Sendable {
  case text(String)
  case message(AgentInferenceMessage)   // the finished assistant message, with any tool calls
}
protocol LocalToolInference {          // add:
  func streamTools(messages: [AgentInferenceMessage], tools: [AgentToolDefinition],
                   model: LocalModel, requiredTool: String?) -> AsyncThrowingStream<LocalToolStreamEvent, Error>
}
// default implementation: one completeTools call, yielding .text(content) then .message

// AgentToolLoop.swift
extension LocalToolAgent {
  func runStreaming(messages: [ChatMessage], model: LocalModel, toolbox: any AgentToolbox,
                    onActivity: @Sendable (AssistantActivityEvent) async -> Void,
                    onText: @Sendable (String) async -> Void) async throws
}
```

## Tasks

### Task 3.1: Streamed tool calls in `LlamaServerVisionEngine`

**Files:** `LlamaServerVisionEngine.swift`, `LocalFileInference.swift`;
tests in new `EnigmaTests/LocalToolStreamingTests.swift` with a stub server
(a local `URLProtocol` or the existing test transport pattern) replaying
CP0's `Fixtures/F32/llama/*.txt`.

- [ ] **Write failing tests:**
  - `testLocalTextStreams`: `.text` events concatenate to the fixture text,
    then one `.message` with no calls.
  - `testLocalCallIsAssembled`: `.message` carries one call with the
    fixture's name and arguments.
  - `testLocalStreamCutMidCallRunsNothing`: the stream throws; no `.message`.
  - `testStreamPayload`: `"stream": true`, `cache_prompt: true`,
    `tool_choice` `"auto"`, or `"required"` when `requiredTool` is set (or
    an instruction if CP0 found `required` unsupported), and otherwise the
    same keys as `completeTools`.
  - `testNoReloadBetweenTurns`: a `streamTools` call after a plain
    `generate` (or another `streamTools`) for the same model reuses the
    loaded server, as plain turns do today; a different model restarts it.
- [ ] **Implement** `streamTools`: follow plain turns' load and reuse
  behavior (CP0's Hand-off describes it), keep the
  budget check, stream `v1/chat/completions`, yield `delta.content` as
  `.text`, ignore `delta.reasoning_content`, assemble
  `delta.tool_calls[i].function.{name,arguments}`, and yield `.message` at
  the end. Schedule the idle unload after each request, as today.

### Task 3.2: `LocalToolAgent.runStreaming`

**Files:** `AgentToolLoop.swift`; tests with `ScriptedToolInference`
(`MessagesToolCallingTests.swift`) extended for `streamTools`.

- [ ] **Write failing tests:** `testRunStreamingEmitsTextAsItArrives`;
  `testRunStreamingKeepsOneCallPerStep` (a message with two calls runs only
  the first, as `run` does); `testRunStreamingPassesRequiredToolOnFirstStepOnly`;
  `testRunStreamingStepLimit`; existing `run` tests pass unedited.
- [ ] **Implement** with `run`'s history, think handling and tool-result
  JSON; only the inference call and `onText` timing differ.

## Exit criteria

- `build`, `test`, `analyze` pass; File Mode, local Messages and vision
  tests pass unedited.
- The owner-approved check from CP0 Q4 is repeated through `streamTools`:
  median time to first token with and without the tool descriptions,
  recorded in the Hand-off.

## Reviewer checklist

- No model reload between turns on the same model.
- A cancelled stream stops the HTTP request and leaves the server warm and
  usable.
- `completeTools`/`generate` behavior unchanged.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP2's CI result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
