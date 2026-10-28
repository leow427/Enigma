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

1. **Summary:** `LlamaServerVisionEngine.streamTools` streams one tool step
   from the `llama-server` plain turns already use: the same load, reuse and
   idle unload, the same budget check as `completeTools`, the prompt cache on,
   text deltas as `.text`, and the finished message (with any call) as one
   `.message` only after a complete stream. `LocalToolAgent.runStreaming` is
   `run` with streamed steps: text is shown as it arrives, trimmed and joined
   between steps as CP2's cloud loops show it. Nothing calls either on a live
   route yet (CP4); `run`, `completeTools` and plain turns are unchanged.

2. **Files:**
   - `Enigma/Files/AgentFileTools.swift`: `LocalToolStreamEvent`;
     `LocalToolInference.streamTools`, with a default that answers one
     `completeTools` call whole (`.text`, then `.message`).
   - `Enigma/Files/LocalFileInference.swift`: `LocalFileRuntime.payload` takes
     `stream`, `cachePrompt` and `requiresTool` (defaults give today's body);
     `LocalToolStreamAssembler`.
   - `Enigma/LocalInference/LlamaServerVisionEngine.swift` also: `toolJSON`
     takes a `task` name for its HTTP error (File Mode's text unchanged).
   - `Enigma/LocalInference/LlamaServerVisionEngine.swift`: `streamTools`,
     `requiredToolInstruction`, `stopTools`, `streamingID`; `toolRequest`
     split out of `toolJSON` (same request).
   - `Enigma/Chat/AgentToolLoop.swift`: `LocalToolAgent.runStreaming`, in an
     extension; `run` untouched.
   - `EnigmaTests/LocalToolStreamingTests.swift` (new): the brief's five engine
     tests plus idle unload and both cancellation cases, against a Python stub
     server that replays `Fixtures/F32/llama` (Gemma and `qwen38/`).
   - `EnigmaTests/MessagesToolCallingTests.swift`: `ScriptedToolInference`
     streams (two deltas per step) and records the required tool;
     `StreamingStepsInference`; the `runStreaming` tests in an extension of
     `MessagesRequestTests`. Existing tests unedited.
   - `EnigmaTests/NativeToolsProbeTests.swift`: opt-in `testStreamToolsLatency`
     (the exit criterion's live check).
   - `Enigma.xcodeproj/project.pbxproj`: the new test file.
   - The plan's progress log, and this Hand-off.

3. **Decisions:**
   - **CP2's CI:** the run on `d458f20` passed (`build-and-test`, 5m41s).
   - **Why the prompt cache was off:** no reason is recorded. `cache_prompt:
     false` arrived in 577fad3 (2026-09-06, "Unify local chat and screenshots
     around multimodal models", no message body) with `--cache-ram 0`, and the
     docs only say the server "keeps no conversation state" (Chat.md:
     "Context shifting and prompt caching are off"). The likely reasons are
     reproducible output at temperature 0 (llama.cpp warns a reused prefix can
     change results slightly) and that statement. Neither is a privacy issue:
     the slot holds the last prompt's tokens in the server's memory whether or
     not the next request reuses them. So `streamTools` sends `cache_prompt:
     true`; plain turns, screens and File Mode keep `false`, and the server
     arguments (`--cache-ram 0`) are unchanged.
   - **A cached prefix:** the system prompt is `run`'s (style, toolbox
     instructions, the one-call rule) and tools are encoded with sorted keys,
     so step after step and turn after turn the prefix is byte-identical for an
     unchanged toolbox. `/think` changes the system prompt (as `run` does), so
     it starts its own prefix.
   - **Forced tool:** `tool_choice: "required"` (llama-server can't name the
     tool) plus `Call the <name> tool before you answer.` appended to the last
     user message of that request only, not the system prompt, so the cached
     prefix survives. A `requiredTool` the step doesn't offer is ignored.
     `runStreaming` passes `toolbox.offeredRequiredTool` on step 1 only.
   - **Stopping a step (reviewer checklist: "leaves the server warm"):**
     once the request is streaming, a stop closes the HTTP request and keeps
     the server, with the idle unload scheduled; the next turn reuses it and its
     cache. A stop while the server loads or the budget is checked unloads it,
     as plain turns do, because `load` would otherwise hand the next request a
     server that never became healthy. Any other failure (HTTP error, an error
     event, a cut stream) unloads, as a failed plain turn does. Plain turns
     still unload on every stop.
   - **How a streamed step ends (review round 2):** as on plain turns, an
     answer that reaches the output limit simply ends there (`length` with text
     only is a finished answer). A reply the limit cut mid-call, an empty reply,
     an unknown finish reason or a call without a name fails with
     `AgentToolError.invalidResponse` in chat wording, and no call runs. A
     stream without a `finish_reason` is `streamEndedUnexpectedly` (the plain
     clients' error), so a half-built call never runs. Malformed arguments
     reach the toolbox, which returns today's "Invalid tool arguments".
   - **When the server stays loaded:** whenever it finished its reply, usable
     or not, and when a step is stopped while streaming; the idle unload is
     scheduled either way. A request that broke off (a cut stream, an HTTP
     error, an error event) or a stop before streaming unloads it, as a failed
     plain turn does.
   - **Output limit:** `completeTools`'s (1,024 tokens, 2,048 with `/think`),
     not plain turns' 512, since the brief asks for the same keys.
   - **Text in a step that calls a tool** is shown as it streams (as CP2's
     loops do) but, as in `run`, kept out of the history.
   - **Activity:** `.generating` when a step's first text appears, the tool's
     phase while it runs, `.thinking` after it.
   - **Chat wording for chat errors (review round 1):** a streamed request over
     the context window throws `ChatContextError.oversizedPrompt` (plain turns'
     message) instead of File Mode's `contextExhausted`, and an HTTP error from
     `apply-template`/`tokenize` says "could not complete this request".
     `completeTools`'s messages are unchanged.
   - **No history trimming here (review round 1):** plain turns drop older
     messages to fit (`ChatContextPreparer`); `streamTools` only checks the
     budget. Trimming is the caller's job, since CP4's `submitNative` builds
     the history; see "For the next checkpoint".
   - **Review rounds:** round 1 found no Blocker and four Should fix: the
     context wording and trimming hand-off above, no test that Stop runs no
     call after a streamed step, no test that a kept server still unloads when
     idle, and the docs CP5 must change. All four are fixed; the two new tests
     each fail when the line they cover is removed. Round 2 found one Should
     fix: a reply that reached the limit, or came back empty, failed with File
     Mode's wording and unloaded a healthy server. Fixed as described above;
     on the owner's standing rule (one small Should fix), I tested it myself
     and skipped a third reviewer.

4. **Verification:**
   - Test-first: both tasks' tests failed to compile first (no `streamTools`,
     `LocalToolStreamEvent`, `runStreaming`). After implementing,
     `testRunStreamingMatchesRunsHistory` failed once on the test's own setup
     (`/think` is `ChatMessage.extendedThinking`, not text) and passed after.
   - `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalToolStreamingTests
     -only-testing:EnigmaTests/MessagesRequestTests`: 28 executed, 0 failed.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, 0
     warnings. Full `test`: 1446 executed, 25 skipped, 1 failed: the
     key-window UI test `testSelectionCardsCallTheSameActions` ("Timed out
     waiting for visible control…"), which passed alone.
   - After review round 1's fixes: the CP3 classes, 32 executed, 0 failed;
     the two new stop tests and the idle-unload test each failed with the line
     they cover removed (scratch copy). `analyze`: succeeded, 0 warnings. Full
     `test`: 1451 executed, 26 skipped (the new probe is one), 0 failed.
   - After review round 2's fix: the CP3 classes, 34 executed, 0 failed; the
     two new tests each failed in a scratch copy with the keep-server block
     removed and with `length` treated as an error. `build`: succeeded.
     `analyze`: succeeded, 0 warnings. Full `test`: 1453 executed, 26
     skipped, 1 failed: the known load-sensitive
     `testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`,
     which passed alone.
   - Live (owner-approved, 2026-10-28): `TEST_RUNNER_ENIGMA_F32_PROBE=<scratch>
     scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeToolsProbeTests/testStreamToolsLatency`.
     Same warm server, prompt cache on, thinking off; five questions per
     condition after one unmeasured request; median time to first answer text:

     | | Without tools | With 8 tools | Ratio | After a stop mid-answer |
     | --- | --- | --- | --- | --- |
     | Gemma 4 12B Q5_K_M | 0.235 s | 0.162 s | 0.69 | 0.199 s, same server |
     | Qwen3.8 27B IQ3_XXS | 0.357 s | 0.364 s | 1.02 | 0.273 s, same server |

     No question made either model call a tool. Both are under the 1.15 gate.
     Gemma's runs with tools being faster is noise between blocks (both
     cached), not a gain from tools. The stop check asked for a 400-word story,
     stopped at its first text, and asked again 200 ms later: the reply came as
     fast as a fresh one, so `llama-server` stops generating when the request
     closes.
   - CI: the run on `9c976d2` failed to compile three test lines (CI's Xcode
     26.6 region checker: "pattern … does not understand how to check"; local
     Xcode 27.1 accepts them). `Fix CI after F32 CP3` builds those held streams
     inside their `Task`, as `LocalVisionTests` does. Its run is recorded by
     the CP4 worker.

5. **Limitations:**
   - Fixtures cover Gemma 4 and Qwen3.8 only (CP0 Q3).
   - A screen capture or File Mode request on the same server between two
     flagged turns sends `cache_prompt: false`, so the next flagged turn reads
     its prefix again once.
   - Long chats: nothing trims a flagged local turn's history yet, so a chat
     longer than about 6,000 tokens (8,192 context, minus 1,024 for the reply
     and about 1,000 for the system prompt and tools) fails with the context
     error until CP4 trims it.
   - The engine learns of a stop on its next actor turn: a new request sent in
     that instant unloads the server instead of reusing it (correct, just
     slower).

6. **For the next checkpoint:**
   - Call `LocalToolAgent(inference: fileInference).runStreaming(…)`;
     `fileInference` is the same `LlamaServerVisionEngine` as plain turns'
     `visionEngine` by default. Don't `unload()` after a flagged turn as
     `submitMessages` does today, or the server and its cache go.
   - Use `ThinkCommand` through `ChatMessage.extendedThinking`, as today.
   - Keep the toolbox's `instructions` and `definitions` stable within a chat
     (no per-turn text in them), or every turn rereads the prefix.
   - **Trim the history before `runStreaming`,** as plain turns do with
     `ChatContextPreparer`: reserve the system prompt and tool definitions
     (render them through `apply-template`, or measure once per toolbox),
     1,024 output tokens (2,048 with `/think`) and 64 spare. Otherwise a long
     flagged chat fails where `main` trims it.
   - **For CP5's docs:** once flagged routes are live, `docs/Chat.md` ("Context
     shifting and prompt caching are off") and `docs/Local-Model-Selection.md`
     ("the server keeps no conversation state… cancelling… stop it") are wrong
     for flagged turns: they send `cache_prompt: true`, and a stop mid-stream
     keeps the server.
   - Interface map: no changes; `LocalToolStreamAssembler` and
     `requiredToolInstruction` are new names.
