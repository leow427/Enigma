# CP3: Local on llama-server

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "Local",
"Failure handling"), and the Hand-offs of CP0–CP2. CP0's Hand-off says which
families stream tool calls and whether `tool_choice: "required"` works.

## Goal

Flagged local models can run a whole turn on a warm `llama-server`, with
text and tool calls streamed, the prompt prefix cached, and the runtime
installed automatically; when the runtime is missing or fails, the caller
can fall back. Nothing calls this on a live route yet (CP4).

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
// LocalChatViewModel
func nativeLocalReady(_ model: LocalModel?) -> Bool   // flag && runtime ready
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
  - `testWarmServerIsReused`: two `streamTools` calls for the same model
    start one process; a different model restarts it; `completeTools` and
    `generate` keep unloading as today.
- [ ] **Implement** `streamTools`: ensure the server is loaded for this
  model (reuse when the active model and its arguments match), keep the
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

### Task 3.3: Runtime readiness, install and fallback

**Files:** `LocalChatViewModel.swift`, `LocalFileRuntimeSetup.swift` (or
the installer's owner); tests in `LocalInferenceTests`.

- [ ] **Write failing tests:**
  - `testNativeLocalReadyNeedsFlagAndRuntime`: flagged + runtime → true;
    unflagged → false; flagged without runtime → false.
  - `testFlaggedModelInstallsRuntime`: finishing a flagged model's download
    starts the runtime install (stub installer); an unflagged model's
    doesn't; an installed flagged model with no runtime starts the install
    once at launch (`TestHost`-safe seam).
  - `testRuntimeInstallFailureIsShownInSettings`: the install error is
    published where `LocalFileToolsViews` shows it.
- [ ] **Implement** with the existing installer (same source and checksum
  as the Settings **Install** button). No new download source.

## Exit criteria

- `build`, `test`, `analyze` pass; File Mode, local Messages and vision
  tests pass unedited.
- The owner-approved check from CP0 Q4 is repeated through `streamTools`:
  median time to first token on a warm server, recorded in the Hand-off.

## Reviewer checklist

- Only one runtime holds a model: the in-process engine is unloaded before
  the server loads (the caller's job in CP4; check the helper makes it easy).
- A cancelled stream stops the HTTP request and leaves the server warm and
  usable.
- `completeTools`/`generate` behavior unchanged.
- The install path reuses the existing source and checksum.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP2's CI result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
