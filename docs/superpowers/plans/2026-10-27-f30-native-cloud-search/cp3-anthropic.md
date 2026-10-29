# CP3: Anthropic — the search tool in the Messages tool loop

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "Anthropic", §4,
§5), and the Hand-offs of [CP0](cp0-spike.md#hand-off) to
[CP2](cp2-openai.md#hand-off).

## Goal

On a request with `providerSearch` set, Anthropic's tool loop offers the
right `web_search` tool for the model beside F32's client tools, streams
searches and citations, replays server blocks unchanged between steps,
continues paused turns, and maps a rejection to
`.webSearchUnavailable(.anthropic)`. When the owner's live check passes,
`.anthropic` joins the provider set.

## Starting point

- **`AnthropicMessagesClient`'s `ToolCallingChatProvider` extension**
  (`CloudToolCalling.swift`) builds each step: `system`, `messages`, client
  `tools`, `tool_choice` except under `/think`, `max_tokens`
  (`prepared.budget.outputTokens`), `stream: true`; `thinking(modelID:)`
  for `/think`.
- **`AnthropicToolStreamAssembler`** (`CloudToolStreaming.swift`) assembles
  `text_delta`, `input_json_delta` into `tool_use`, and thinking blocks with
  their signatures, and replays the assistant message.
- **CP0's Q2:** the event order with code-execution blocks, what a step
  replay needs, `pause_turn`, forced choice, the `max_tokens` finding, the
  blocked-domains limit, the accepted prefixes and the error bodies.

## Tasks

### Task 3.1: The tool by model

**Interfaces:**

```swift
extension AnthropicMessagesClient {
  static let dynamicSearchModelPrefixes: [String]      // CP0's accepted list
  static let maximumBlockedDomains: Int                 // CP0's limit
  static let maximumContinuations = 3
  static func webSearchTool(modelID: String, blockedDomains: [String]) -> [String: Any]
}
```

- [ ] **Write the failing tests** in `CloudToolStreamingTests`:
  - `testAnthropicSearchToolByModel`: each listed prefix and a point
    release (`claude-opus-5-5` under `claude-opus-5`) get
    `web_search_20260318` with `max_uses` 5 and
    `response_inclusion: "excluded"`; `claude-haiku-4-5` gets
    `web_search_20250305` with `max_uses` 5.
  - `testAnthropicBlockedDomainsLeftOutWhenEmpty`, and
    `testAnthropicSearchSendsBlockedDomainsWithinLimit` (F29 fills the list
    later; the cut is built now).
  - `testAnthropicProviderSearchBody`: the server tool joins the client
    tools; a typed `/search` forces it as CP0 found, never under `/think`.
  - `testAnthropicWithoutProviderSearchUnchanged`.
- [ ] **Run, implement, run.**

### Task 3.2: The stream, citations and server-block replay

- [ ] **Write the failing tests:**
  - `testAnthropicSearchEventsFromFixture`
    (`anthropic-search-and-tool.sse`): `.phase(.searching)` on
    `server_tool_use`; `web_search_result` entries as discovered sources;
    a result error object logged by code and the reply carrying on;
    `citations_delta` locations as cited sources; `.sourcesSelected` before
    `.completed`.
  - `testAnthropicReplaysServerBlocksUnchanged`: the next step's assistant
    message equals CP0's `anthropic-step-replay-request.json`, every block
    and encrypted field included.
  - `testAnthropicRestartDeliversNothing`.
- [ ] **Run, implement, run.**

### Task 3.3: `pause_turn`

- [ ] **Write the failing tests:**
  - `testAnthropicPauseTurnContinues`: from CP0's pause fixtures (or a
    synthetic pair if no pause was recorded, marked so in the README), the
    continuation body holds the rebuilt message and streaming goes on into
    the same reply.
  - `testAnthropicPauseTurnStopsAfterThree`: a fourth pause ends the reply
    with the text so far, as `.completed`.
  - `testPauseDoesNotCountAsAStep`: three pauses and eleven tool steps
    still finish under F32's 12-step limit.
- [ ] **Run, implement, run.**

### Task 3.4: Rejections and the output margin

- [ ] **Write the failing tests:**
  - `testAnthropicSearchRejectionIsUnavailable`: CP0's bodies (tool version,
    search off) on a provider-search request are unavailable; other 400s
    keep today's error.
  - `testAnthropicSearchOutputMargin`: only if CP0 found search blocks count
    against `max_tokens`: provider-search requests add the margin CP0's
    measurement supports.
- [ ] **Run, implement, run.**

### Task 3.5: The live check, and turning Anthropic on

- [ ] **Add** `testAnthropicSearchesLive` to `NativeWebSearchLiveTests`
  (skips without `ENIGMA_ANTHROPIC_KEY`): the multi-search question, at
  least one search, at least two sources, no fourth continuation.
- [ ] **Get the owner's approval** (about 5 searches), hand them the
  command, record the output.
- [ ] **When it passes,** add `.anthropic` to the set and update the test.

## Exit criteria

- The touched classes pass; `build` and `analyze` succeed; the full `test`
  once before the commit; CI passes.
- The live check passed, or `.anthropic` stays off and the Hand-off says
  why.

## Reviewer checklist

- Replay is byte-faithful for server and code-execution blocks; mutation:
  drop an encrypted field, and a test fails.
- The continuation cap and the step limit hold together.
- No `user_location`; blocked domains omitted when empty.
- The restart delivers nothing.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
