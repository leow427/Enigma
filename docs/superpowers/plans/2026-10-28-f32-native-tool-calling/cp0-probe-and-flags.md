# CP0: Probe and flags

Read [agent-workflow.md](agent-workflow.md) and the spec in full (above all
"Open questions for CP0" and §3).

## Goal

Answer the spec's six open questions with evidence, record scrubbed stream
fixtures that CP2 and CP3 test against, and add the capability flags and the
internal switch. No behavior change.

## Starting point

- Worktree: create it (agent-workflow, Roles) on
  `feat/f32-native-tool-calling` from `main`.
- `LocalMultimodalProfile` (`Enigma/LocalInference/LocalMultimodalProfile.swift`)
  is a `String` enum with per-case switches; bundled families use
  `qwen35_2B`, `qwen35_4B`, `gemma4E4B`, `ministral8B`, `qwen35_9B`,
  `gemma4_12B`, `ministral14B`, `gemma4A4B`, `gemma4_31B`,
  `qwen36_35BA3B`, `qwen38_27B`.
- `LocalModelDescriptor.resolvedProfile: LocalMultimodalProfile?`
  (`LocalModelManifest.swift`); `LocalModel.catalogDescriptor`
  (`LocalModelEngine.swift`).
- `CloudModelCapabilities` (`Enigma/Cloud/CloudModelCapabilities.swift`)
  has `metadata(provider:modelID:)`; there is no tool flag.
- Non-tool streaming already exists: `OpenAIResponsesClient.stream(_:)`,
  `AnthropicMessagesClient.stream(_:)` (`CloudProviderClients.swift`),
  `GeminiContentClient.stream(_:)`; SSE via `ServerSentEventParser`.
- `llama-server` text args: `LocalFileRuntime.textArguments`
  (`Enigma/Files/LocalFileInference.swift`), already with `--jinja`.

## Interfaces

**Produces:**

```swift
// Enigma/Chat/NativeTools.swift
enum NativeTools {
  /// Off until F32 CP5. Flagged routes take today's path while false.
  static let isEnabled = false
  /// True when the route's model calls tools natively. Ignores isEnabled.
  static func isCapable(route: Route, localModel: LocalModel?) -> Bool
}
// LocalMultimodalProfile
var nativeTools: Bool { get }
// LocalModelDescriptor
var supportsNativeTools: Bool { get }   // resolvedProfile?.nativeTools ?? false
// CloudModelCapabilities
static func supportsNativeTools(provider: CloudProviderID, modelID: String) -> Bool
```

`isCapable`: local routes use `localModel?.catalogDescriptor?.supportsNativeTools ?? false`;
cloud routes use `supportsNativeTools(provider:modelID:)` with the route's
provider and model; a route without a provider is not capable.

## Tasks

### Task 0.1: Flags and switch

**Files:** create `Enigma/Chat/NativeTools.swift`; modify
`LocalMultimodalProfile.swift`, `LocalModelManifest.swift`,
`CloudModelCapabilities.swift`. Tests in new `EnigmaTests/NativeToolsTests.swift`.

- [ ] **Write failing tests:**
  - `testStartingLocalFlags`: for every `BundledLocalModels` family,
    `supportsNativeTools` matches the plan's "Starting local flags" row
    (on: 9B, 12B, 14B, 26B-A4B, 31B, 35B-A3B, 27B; off: 2B, 4B, E4B, 8B).
  - `testEveryQuantizationSharesItsFamilysFlag`.
  - `testUnknownProfileIsNotCapable`: a descriptor with no resolved profile
    answers false.
  - `testCloudModelsAreCapable`: every catalogue model of every
    `CloudProviderID` answers true, except those listed in
    `CloudModelCapabilities` as lacking function calling (Task 0.2).
  - `testRouteCapability`: `isCapable` for a local route with a flagged
    model, an unflagged model, no model; a cloud route; a route with no
    provider.
  - `testSwitchIsOff`: `XCTAssertFalse(NativeTools.isEnabled)` (CP5 updates
    this assertion when it turns the switch on).
- [ ] **Run them** and watch them fail; implement; run them and watch them
  pass. Profiles not in the bundled catalogue (`qwen3VL*`, `gemma4E2B`,
  `ministral3B`, `miniCPM*`, `smolVLM2`) are `false`.

### Task 0.2: Probe the open questions

Live runs need the owner's approval first (agent-workflow, Accounts and
keys). Write the probes as opt-in XCTests in
`EnigmaTests/NativeToolsProbeTests.swift` that skip unless
`ENIGMA_F32_PROBE` is set, and write raw recordings to the folder it names,
outside the repository.

- [ ] **Q1 and Q2, cloud streams and forced choice.** The owner has no
  OpenAI, Anthropic or Gemini API key (only ChatGPT and Claude
  subscriptions), so these are answered from each provider's current
  official API reference, not live runs. For OpenAI Responses, Anthropic
  Messages and Gemini `streamGenerateContent?alt=sse`, write the streamed
  event sequence for four cases with one function tool
  (`get_weather(city)`): text only; one call; text then a call; a call
  forced by name (OpenAI `tool_choice: {"type":"function","name":…}`,
  Anthropic `tool_choice: {"type":"tool","name":…}`, Gemini
  `toolConfig.functionCallingConfig {mode: "ANY", allowedFunctionNames: […]}`),
  plus one Anthropic stream with extended thinking (`thinking_delta`,
  `signature_delta`). Copy shapes from the documented examples exactly;
  cite each source page in the Hand-off and mark these fixtures
  "from docs, not recorded". Never ask the owner for a key.
- [ ] **Q3, local streamed tool calls.** For each flagged family the owner
  has installed, start `llama-server` with `LocalFileRuntime.textArguments`
  and record a streamed `v1/chat/completions` request (`"stream": true`,
  one tool, the same four cases, `tool_choice: "required"` for the forced
  case). Note per family whether `delta.tool_calls` arrives and parses.
- [ ] **Q4, latency and memory.** On the owner's Mac, for each installed
  flagged model: median of 5 runs of time to first token for "What is the
  capital of Australia?" on the in-process engine (`LlamaCPPModelEngine`)
  and on a warm `llama-server` (second request onward); and the
  `llama-server` process's resident memory beyond the model file size.
- [ ] **Q5, Codex and Claude Code.** Time to first token for a plain
  question with and without a one-tool toolbox, through
  `CodexSubscriptionClient.stream(_:toolbox:)` and
  `ClaudeCodeSubscriptionClient.stream(_:toolbox:)` (owner-approved; uses
  the Mac's sign-ins).
- [ ] **Q6, cloud function calling.** For every catalogue cloud model, check
  the provider's model documentation for function calling; list any
  without it in `CloudModelCapabilities` (Task 0.1's exception list) with
  the source in the Hand-off.

### Task 0.3: Fixtures

- [ ] **Scrub** the local and subscription recordings (the API fixtures
  are written from docs and need no scrubbing): remove keys, request and response IDs,
  account or organization names, and anything else identifying; keep event
  names, ordering and payload shapes.
- [ ] **Save** them as `EnigmaTests/Fixtures/F32/<openai|anthropic|gemini|llama>/<case>.txt`
  with cases `text`, `call`, `text-then-call`, `forced`, and for Anthropic
  `thinking-call`. Add `cut-mid-call.txt` per provider by truncating
  `call.txt` inside the arguments.
- [ ] **Add** `testFixturesAreScrubbed` to `NativeToolsTests`: no fixture
  contains `sk-`, `Bearer`, `x-api-key`, `"id":"resp_`, `"id":"msg_` or
  `req_`.

### Task 0.4: Draft pull request

- [ ] After the owner approves in the chat, open the draft PR
  "F32: native tool calling for capable models" from the branch to `main`.

## Exit criteria

- The Hand-off lists which fixtures are from docs and which are recorded.

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass; probe tests
  skip without `ENIGMA_F32_PROBE`.
- The Hand-off answers Q1–Q6 with evidence. Anything that blocks the spec
  (a provider that can't stream calls, a starting-flagged family whose calls
  don't parse, the warm server slower than the gate) is raised with the
  owner before committing.

## Reviewer checklist

- Flags match the plan's table; nothing reads `NativeTools.isEnabled` yet.
- Fixtures are scrubbed and match their case names.
- Probe tests can't run without the variable and never write into the
  repository.

## Hand-off

*Filled in by the CP0 worker.*

1. **Summary:** Added the native-tools flags and the internal switch
   (`NativeTools`, off), answered Q1–Q6, and saved stream fixtures for CP2
   and CP3. No behavior change: nothing reads `NativeTools.isEnabled` or
   `isCapable` yet. The owner had no API keys, so the OpenAI and Gemini
   fixtures and Anthropic's thinking case are from docs, not recorded
   (sources under Q1); Anthropic's `text`, `call` and `text-then-call` were
   recorded through Claude Code, and its `forced` is a copy of `call`.

2. **Files:**
   - `Enigma/Chat/NativeTools.swift` (new): `isEnabled = false` and
     `isCapable(route:localModel:)`.
   - `Enigma/LocalInference/LocalMultimodalProfile.swift`: `nativeTools`,
     on for the seven starting families.
   - `Enigma/LocalInference/LocalModelManifest.swift`:
     `LocalModelDescriptor.supportsNativeTools`.
   - `Enigma/Cloud/CloudModelCapabilities.swift`:
     `modelsWithoutFunctionCalling` (empty, per Q6), `reviewedModelIDs(for:)`
     and `supportsNativeTools(provider:modelID:lacking:)` (`lacking`
     defaults to the static list; tests pass their own).
   - `EnigmaTests/NativeToolsTests.swift` (new): the brief's six tests plus
     `testFixturesAreScrubbed` (which also requires every case file) and
     `testProbeFolderMustBeOutsideTheRepository`.
   - `EnigmaTests/NativeToolsProbeTests.swift` (new): opt-in probes; they
     skip unless `ENIGMA_F32_PROBE` names a folder outside the repository.
   - `EnigmaTests/Fixtures/F32/` (new): fixtures and a README stating which
     are recorded and which synthesized.
   - `Enigma.xcodeproj/project.pbxproj`: the three Swift files.
   - The plan's progress log, and this Hand-off.

3. **Decisions:**
   - **Cloud flag scope (owner, 2026-10-28: by model family).** OpenAI,
     Codex and Claude Code need a reviewed entry
     (`CloudModelCapabilities.metadata` non-nil): OpenAI's allowlist, the
     models Codex lists, Claude Code's aliases. Anthropic goes by family:
     every `claude-*` model except the retired `claude-2*` and
     `claude-instant*`. Gemini: `gemini-2.5*` and `gemini-3*`, except image,
     speech, audio and live variants, plus the `gemini-flash-latest`,
     `gemini-flash-lite-latest` and `gemini-pro-latest` aliases. So the newer models each
     provider lists first (Claude Haiku 5.5, Gemini 3 Flash) are covered,
     and tool support no longer depends on the screenshot list. Gemma and
     other open models on the Gemini API, and OpenAI IDs nobody reviewed,
     keep today's path.
   - **`isCapable`** treats `mode == .local` as local; any other route needs
     a `providerID` that is a `CloudProviderID` (so `"llama.cpp"`/`"local"`
     on a non-local route, or `""`, answer false).
   - **Q1, event names** (fixtures in `Fixtures/F32/<provider>/`). Which
     fixtures are recorded and which are from docs is listed in
     `Fixtures/F32/README.md`. Sources for the ones from docs:
     - OpenAI: the function-calling guide's streaming section,
       https://developers.openai.com/api/docs/guides/function-calling, and
       the streaming events reference,
       https://developers.openai.com/api/reference/resources/responses/streaming-events
       (only partly readable from here; `sequence_number` and the text
       events follow it, not a verified example).
     - Anthropic thinking: https://platform.claude.com/docs/en/build-with-claude/streaming
       (the extended-thinking example).
     - Gemini: today's `GeminiContentClient` and `CloudToolCalling` parsing,
       and the thinking guide's signatures section,
       https://ai.google.dev/gemini-api/docs/thinking (signatures may sit
       on a `functionCall` part or on the final part of a response). The
       function-calling page now documents the Interactions API, so the
       `generateContent` chunk shape is from today's client, not a page.
     - OpenAI Responses (from the docs): `response.created`,
       `response.in_progress`, `response.output_item.added` (a
       `function_call` item with `id`, `call_id`, `name`, empty
       `arguments`), `response.function_call_arguments.delta`
       (`item_id`, `output_index`, `delta`),
       `response.function_call_arguments.done` (full `arguments`),
       `response.output_item.done`, `response.completed`; text uses
       `response.content_part.added`, `response.output_text.delta`/`.done`,
       `response.content_part.done`. Every event carries
       `sequence_number`.
     - Anthropic Messages (recorded through Claude Code; `ping` is from the
       docs, since Claude Code drops it): `message_start`, `content_block_start`
       (`text` or `tool_use` with `id`, `name`, `input: {}`; Claude Code's
       stream also has `caller`), `ping`, `content_block_delta` with `text_delta`
       or `input_json_delta` (`partial_json`; the first was empty in every recording),
       `content_block_stop`, `message_delta` (`stop_reason: "tool_use"` or
       `"end_turn"`, `usage`), `message_stop`. Text and a call share one
       message as blocks 0 and 1. Thinking (from the docs): a `thinking`
       block with `thinking_delta` (`thinking`), then one `signature_delta`
       (`signature`) just before its `content_block_stop`.
     - Gemini (from docs and today's client): each SSE `data:` chunk is a
       whole `GenerateContentResponse`; a call arrives whole as a part
       `{"functionCall": {"name", "args"}, "thoughtSignature"}`. The
       signature may also come on the response's final part (for example
       an empty text part in a last chunk); CP2 must keep it and send it
       back exactly. `finishReason` is `STOP` for calls too.
   - **Q2, forced choice:** OpenAI `{"type":"function","name":…}`, Anthropic
     `{"type":"tool","name":…}` (not allowed with extended thinking: only
     `auto`), Gemini `functionCallingConfig {mode: "ANY",
     allowedFunctionNames: […]}`, all from the docs, not verified live.
     `llama-server` b11734 `tool_choice: "required"`: Gemma 4 12B obeyed in
     all three runs; **Qwen3.8 27B did not** in two of three (it wrote text
     until `max_tokens` without calling; once it wrote text and then
     called). Treat local forced choice as best-effort and add the
     instruction too. Codex and Claude Code offer no tool choice, so
     `/search` and `/edit` use an instruction there.
   - **Q3, local streamed calls:** with today's server arguments (`--jinja`)
     and today's request keys (`LocalMultimodalClient.makeRequest`: the
     response-style system prompt, `cache_prompt: false`,
     `enable_thinking: false`, `reasoning_budget: 0`), Gemma 4 12B Q5_K_M
     and Qwen3.8 27B IQ3_XXS both stream `delta.tool_calls` (first delta has
     `id`, `type`, `function.name`; the rest only `function.arguments`
     fragments), finish with `finish_reason: "tool_calls"`, and assemble
     into valid JSON for `call` and `text-then-call`. With thinking on
     (`thinking-call`) they stream `delta.reasoning_content` first, then the
     call, which also parses. Qwen3.5, Qwen3.6 and Ministral 3 aren't
     installed and are unverified (owner: note as a limitation).
   - **Q4, latency and memory — the code differs from the brief.** Every
     catalogue model already chats through a warm `llama-server`
     (`LlamaServerVisionEngine`, unloaded after 60 s idle,
     `LocalModelIdlePolicy.unloadDelay`); the in-process engine refuses
     vision models. So flagging changes no runtime. The owner agreed to
     measure what does change: the same warm server, today's exact request
     against a flagged turn (the style prompt plus the tool instructions and
     the toolbox: Messages' five tools, `web_search`, `propose_edit`,
     `propose_translation`). Five different plain questions per condition,
     each condition in its own block after one unmeasured request. Median
     time to the first streamed delta (thinking is off, so that is the first
     answer text):

     | | Today (cache off) | Flagged, cache on | Flagged, cache off |
     | --- | --- | --- | --- |
     | Gemma 4 12B | 0.578 s | 0.224 s (−61%) | 1.716 s (+197%) |
     | Qwen3.8 27B | 1.148 s | 0.463 s (−60%) | 4.538 s (+295%) |

     These compare different cache settings, so they don't measure the gate.
     Main's plan (3083edc) defines it as tools against no tools on the same
     running server; the "cache on, no tools" row was not measured, and the
     owner chose to leave that to CP5 (2026-10-28). Flagged turns aren't
     expected to be faster than today: the −60% comes from the cache, not
     the tools.
     - **The prompt cache must be on for flagged turns** (owner,
       2026-10-28: a CP3 requirement, after CP3 finds out why it was turned
       off). Today's request sends `cache_prompt: false` (since 577fad3,
       September; no reason is recorded), so every turn re-reads the whole
       prompt; with the tool descriptions added and the cache off, the
       first word takes 3–4× as long. CP3 must send `cache_prompt: true` on
       flagged turns, keep the system prompt and tools byte-identical
       across turns, and check that nothing else sent to the same server
       (screens, File Mode) evicts the prefix between turns.
     - Earlier runs in this checkpoint used a thinking-on, cached baseline
       without the style prompt and found tools cost Gemma +20% and Qwen +1%.
       The owner accepted Gemma's +20% then; CP5's measurement replaces it.
     - Memory (`ps` resident set, mapped weights included; footprint
       excludes them): Gemma's server 9,774 MiB resident with an 8,023 MiB
       model and 167 MiB projector, so about 1.5 GiB beyond the files
       (2,010 MiB footprint). Qwen 3,665 MiB resident, less than its
       10,428 MiB model (its weights weren't all paged in), 2,293 MiB
       footprint. This is today's cost already.
     - Cold load (process start to `/health`): 2.6 s and 5.8 s.
   - **Q5, Codex and Claude Code:** time to first token, three runs each,
     plain question, no tools against a one-tool toolbox: Codex
     (gpt-5.6-luna) 2.65 s against 2.06 s; Claude Code (haiku) 1.75 s
     against 1.34 s. No slowdown. The plain run always went first, so the
     toolbox runs being faster may be warm-up, not tools.
   - **Q6, cloud function calling:** every catalogue model supports it, so
     the exception list is empty. Sources: OpenAI's model pages (GPT-5.4
     mini, GPT-5.6 Terra) and function-calling guide
     (developers.openai.com/api/docs/guides/function-calling); Anthropic's
     tool-use docs for every listed Claude model; Gemini 2.5 Flash, Pro and
     Flash-Lite list function calling. Codex and Claude Code run tools
     through their own agents.

4. **Verification:**
   - `scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeToolsTests
     -only-testing:EnigmaTests/NativeToolsProbeTests`: 13 executed, 5 skipped
     (the probes), 0 failed. The flag tests failed first, before the code
     existed.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     new warnings.
   - Full `test` (after review round 2's fixes): 1346 executed, 25 skipped,
     0 failed. (After round 1, one run failed only the known load-sensitive
     `testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`,
     which passed alone.) After review round 3's fixes: build and analyze
     succeeded (0 warnings); the full run failed four `ScreenViewTests`
     after the test host crashed in
     `testCombinedCommandsSearchBeforeAutomaticScreenSubmission` and
     restarted. The same crash happens on unchanged `main` (3f78cd0,
     `-only-testing:EnigmaTests/ScreenViewTests`), and no app code calls
     CP0's additions, so it is environmental or already on `main`.
   - Live runs (owner-approved): `TEST_RUNNER_ENIGMA_F32_PROBE=<scratch>
     scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeToolsProbeTests/testRecordLlamaServerStreamsAndLatency
     -only-testing:EnigmaTests/NativeToolsProbeTests/testSubscriptionStartUpWithTools`
     (both passed; the local probe ran three times: the first two used the
     wrong request keys, see Q4); Anthropic recordings with `claude -p --output-format
     stream-json --verbose --include-partial-messages --model haiku --tools
     Read --allowedTools Read` in an empty scratch folder, prompt on stdin
     (5 calls on the owner's subscription, plus one Sonnet call that showed
     no thinking blocks).
   - CI: recorded by the CP1 worker.

5. **Limitations:**
   - The OpenAI and Gemini fixtures and Anthropic's `thinking-call` are
     synthesized, not recorded; the owner has no API keys. CP2's parsers can
     be right against them and still meet a different live stream. Record
     them with `testRecordOpenAIStreams`/`…Anthropic…`/`…Gemini…` when a key
     is available, before CP5 switches the feature on.
   - Anthropic's recorded tool is Claude Code's `Read`, not `get_weather`;
     its input was rewritten to a placeholder path in the same number of
     deltas.
   - Q3 covers Gemma 4 and Qwen3.8 only.
   - The latency gate (tools against no tools, same server and cache
     settings) was not measured on today's request keys; CP5 measures it
     (owner). Flagged local turns need the prompt cache on (Q4).
   - Gemma 4 12B and Qwen3.8 27B only; one recorded run of each case
     (`forced` was run three times across the probe runs).
   - Task 0.4: the draft pull request is opened when the branch is first
     pushed, after the owner approves it in the chat.

6. **For the next checkpoint:**
   - Main's 3083edc already rewrote CP3 for the existing server
     (`LlamaServerVisionEngine`); this branch includes it.
   - Fixture paths: `Fixtures/F32/<openai|anthropic|gemini|llama>/<case>.txt`,
     plus `llama/qwen38/<case>.txt`. Gemini fixtures use CRLF separators.
   - Gemini calls carry `thoughtSignature`, which must go back exactly in
     the next request (the docs say signatures must be resent as received); it may arrive
     on a later chunk's final part. Live OpenAI deltas may carry fields the
     synthesized fixtures lack (`obfuscation`, `logprobs`); parsers should
     ignore unknown fields, and the live re-recording should check.
   - Local `required` is unreliable for Qwen; pair it with an instruction.
   - Flagged local turns need `cache_prompt: true` and a byte-identical
     prefix (Q4); find out why today's request disables the cache before
     changing it.
   - Local fixtures are thinking-off streams (today's default) plus one
     `thinking-call`. The Anthropic recordings came through Claude Code,
     which may send beta headers; fields like `caller` and `stop_details`
     may not appear on the public API.
