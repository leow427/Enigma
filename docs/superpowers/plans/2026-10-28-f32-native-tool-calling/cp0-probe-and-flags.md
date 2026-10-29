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

1. **Summary:**
2. **Files:**
3. **Decisions:** include Q1–Q6 answers: event names per provider, forced
   choice support, local families that stream calls, latency and memory
   numbers, Codex/Claude Code start-up, cloud models without function calls.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
