# CP3: Anthropic — the Messages API's web search tool

Read [agent-workflow.md](agent-workflow.md), the spec (§2 "Anthropic", §3,
§4), and the Hand-offs of [CP0](cp0-spike.md#hand-off) (Q4),
[CP1](cp1-shared-plumbing.md#hand-off) and [CP2](cp2-openai.md#hand-off).

## Goal

`AnthropicMessagesClient` searches with Anthropic's web search tool when a
request carries `webSearch`. It:

- picks the tool version by model;
- sends the blocked sites;
- reports searches, results and citations;
- continues paused turns;
- maps rejections to `.webSearchUnavailable(.anthropic)`.

After the owner's live check, `.anthropic` joins the provider set.

## Starting point

- **`AnthropicMessagesClient`** (`Enigma/Cloud/CloudProviderClients.swift`):
  - `makeRequest(for:)` builds `model`, `max_tokens`
    (`prepared.budget.outputTokens`), `system`
    (`ChatResponseStyle.instructions`), `messages` and `stream`, plus
    `thinking(modelID:)` for `/think`;
  - `handle` decodes `AnthropicStreamPayload`, with `type`, `delta.type`,
    `delta.text` and `error`. Only `text_delta`, `message_stop` and `error`
    matter today.
- **`CodexValue`** (`Enigma/Cloud/CodexAppServer.swift`) is the project's
  Codable JSON value. `ClaudeCodeStreamParser` already uses it for
  arbitrary JSON.
- **From CP0's Q4:**
  - the event order, including code-execution blocks under dynamic
    filtering;
  - whether search blocks count against `max_tokens`, and the margin to add;
  - the `blocked_domains` limit;
  - which model prefixes accept `web_search_20260318`;
  - the error bodies;
  - what a continuation must contain after a second pause.

  The fixtures are `anthropic-*.sse` and `anthropic-*.json`.
- **From CP2:** `EnvironmentCredentials`, `liveEvents` and the live-test
  file.

## Tasks

### Task 3.1: The tool and the request

**Files:** modify `Enigma/Cloud/CloudProviderClients.swift`. Tests go in
`CloudModeTests`.

**Interfaces.** This task produces:

```swift
extension AnthropicMessagesClient {
  /// From CP0 Q4: prefixes of models that accept web_search_20260318, for example
  /// "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-5", "claude-sonnet-5", "claude-fable-5".
  static let dynamicSearchModelPrefixes: [String]
  static let maximumBlockedDomains: Int            // CP0 Q4's limit
  static let maximumContinuations = 3
  static let searchOutputMargin: Int               // from CP0 Q4; 0 if search blocks don't count
  static func webSearchTool(modelID: String, blockedDomains: [String]) -> [String: Any]
}
```

**`webSearchTool`** returns:

- **For a matching prefix:**

  ```text
  ["type": "web_search_20260318", "name": "web_search",
   "max_uses": 5, "response_inclusion": "excluded"]
  ```

- **Otherwise:**

  ```text
  ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
  ```

- **In both cases,** `"blocked_domains"` holds the first
  `maximumBlockedDomains` blocked sites, only when there are any.

**With `webSearch` set,** `makeRequest` also:

- adds `tools: [webSearchTool(...)]`;
- sets `system` to `ChatResponseStyle.instructions + "\n\n" +
  NativeWebSearch.instructions(blockedDomains: search.blockedDomains,
  namesBlockedDomains: false)`;
- adds `searchOutputMargin` to `max_tokens`.

No `user_location`.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testAnthropicSearchToolDependsOnModel`.** For each entry of CP0's
    accepted list (`claude-sonnet-4-6` at least), the tool is
    `web_search_20260318` with `response_inclusion: "excluded"` and
    `max_uses: 5`. `claude-haiku-4-5` and `claude-3-7-sonnet-20250219` get
    `web_search_20250305`.
  - **`testAnthropicSearchSendsBlockedDomainsWithinLimit`:**
    - 600 domains give exactly `maximumBlockedDomains`, the first ones in
      the given order;
    - an empty list leaves the key out;
    - `allowed_domains` never appears.
  - **`testAnthropicRequestWithoutSearchIsUnchanged`:** no `tools`, `system`
    equals `ChatResponseStyle.instructions`, and `max_tokens` is unchanged.
  - **`testAnthropicSearchRequestUsesSystemInstructionAndBudget`:**
    - `system` ends with the instruction;
    - the blocked sites aren't named in it;
    - `max_tokens` is `prepared.budget.outputTokens + searchOutputMargin`;
    - no key contains `location`.
- [ ] **Run** `CloudModeTests`. Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 3.2: `AnthropicTurnAccumulator`

**Files:** create `Enigma/Cloud/AnthropicTurnAccumulator.swift`, registered
in the app target. Tests go in `CloudModeTests`.

**Interfaces.** This task produces:

```swift
/// Rebuilds the assistant's content blocks from the stream, so a paused turn can be sent back unchanged.
struct AnthropicTurnAccumulator: Sendable {
  /// Applies one event's decoded `data`.
  mutating func apply(_ event: CodexValue)
  /// Every block received in this turn, across continuations (per CP0 Q4), in order.
  var content: [CodexValue] { get }
  /// The latest message_delta's stop_reason.
  var stopReason: String? { get }
}
```

**The rules:**

| Event | Action |
| --- | --- |
| `message_start` | Starts a new message; earlier messages' blocks are kept |
| `content_block_start` | Stores `content_block` at `index`, verbatim |
| `content_block_delta`, `text_delta` | Appends to `text` |
| `content_block_delta`, `citations_delta` | Appends `citation` to `citations`, created if missing |
| `content_block_delta`, `input_json_delta` | Appends `partial_json` to a buffer for that block |
| `content_block_delta`, `thinking_delta` | Appends to `thinking` |
| `content_block_delta`, `signature_delta` | Sets `signature` |
| `content_block_stop` | Parses the input buffer into `input`, or `{}` if the buffer is empty |
| `message_delta` | Records `delta.stop_reason` |

Unknown block types (code execution, nested tool results) are kept as
started.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testAccumulatorRebuildsBlocksFromDeltas`.** A synthetic stream with
    six blocks: text with two `text_delta`s and a `citations_delta`; a
    `server_tool_use` whose input arrives in two `input_json_delta` parts;
    a `web_search_tool_result`; a `thinking` block with a `thinking_delta`
    and a `signature_delta`; a `redacted_thinking` block; and an
    unknown-type block. `content` equals the expected six blocks exactly.
  - **`testAccumulatorKeepsBlocksAcrossMessages`:** two `message_start`s
    give the blocks of both messages, in order.
- [ ] **Run.** Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 3.3: The stream

**Files:** `Enigma/Cloud/CloudProviderClients.swift`. Tests go in
`CloudModeTests`.

**Decoding.** Decode each event's `data` as `CodexValue` once. Feed it to
the accumulator and to the handling below. Keep today's behavior for
requests without search.

| Event | Action |
| --- | --- |
| `content_block_start`, `server_tool_use` (any name, since dynamic filtering searches from code execution) | The first time: `sources.noteSearch()`, yield `.activity(.phase(.searching))` |
| `content_block_start`, `web_search_tool_result` with a list | `noteSearch`; discover each `web_search_result`'s url and title |
| `content_block_start`, `web_search_tool_result` with an object | Log the `error_code` only, with the provider name. Not an error. |
| `content_block_delta`, `text_delta` | Token, and `appendAnswer` |
| `content_block_delta`, `citations_delta` with a `web_search_result_location` | `noteSearch`; `cite` its url and title |
| `message_stop` with stop reason `pause_turn` | Task 3.4 |
| `message_stop` otherwise | Yield the selection when there is one, then `.completed` |

**Steps:**

- [ ] **Write the failing tests:**
  - **`testAnthropicSearchStreamReportsActivityAndCitations`.** Feed
    `anthropic-web-search.sse`:
    - `.phase(.searching)` comes first among activities;
    - the discovered sources match the fixture's results, if the fixture
      has any after `response_inclusion`;
    - the tokens join to the answer;
    - the last two events are the literal expected `.sourcesSelected` and
      `.completed`.
  - **`testAnthropicSearchErrorResultIsNotAFailure`:** a stream whose
    result is `{"type": "web_search_tool_result_error", "error_code":
    "too_many_requests"}`, followed by text, finishes normally, with no
    discovered sources.
- [ ] **Run.** Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 3.4: Continuing a paused turn

**Files:** the same. Tests go in `CloudModeTests`.

**The rule.** When a message ends with `pause_turn`, and fewer than 3
continuations have run, send the same body again with one change: append
`["role": "assistant", "content": accumulator.content]` to `messages`. Keep
streaming tokens and activity into the same output. After 3 continuations,
yield the selection and `.completed` with the text so far.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testPauseTurnContinuesWithRebuiltAssistantMessage`.** The mock
    transport returns a paused stream, then a final one. Use CP0's
    recordings, or synthetic streams if no pause was recorded.
    - The second request's body equals the first's, plus one assistant
      message whose `content` equals the accumulated blocks.
    - The tokens from both streams arrive in order, and `.completed` comes
      once.
  - **`testPauseTurnStopsAfterThreeContinuations`:** every stream pauses,
    so there are exactly 4 requests, then `.completed`, and no error.
- [ ] **Run.** Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 3.5: Rejections

**Files:** the same. Tests go in `CloudModeTests`.

**Interfaces.** This task produces
`static func isWebSearchRejection(statusCode: Int, body: Data) -> Bool` on
`AnthropicMessagesClient`. It's true for a 400 `invalid_request_error`
whose message mentions web search, or the search tool's version, in CP0's
recorded wording. It covers:

- an organization that turned search off;
- a model that doesn't support the tool;
- a blocked-domains error.

**Steps:**

- [ ] **Write the failing test**
  `testAnthropicSearchRejectionIsUnavailable`:
  - each recorded error body with status 400, on a search request, throws
    `.webSearchUnavailable(.anthropic)`;
  - the same bodies without `webSearch` keep today's `.requestFailed`;
  - a 429 keeps `.rateLimited`.
- [ ] **Implement,** then run. Expect it to pass.

### Task 3.6: The live check, and turning Anthropic on

**Files:** `EnigmaTests/NativeWebSearchLiveTests.swift`,
`Enigma/Cloud/CloudDomain.swift`, and `NativeWebSearchTests`.

**Steps:**

- [ ] **Add `testAnthropicSearchesLive`,** shaped like CP2's OpenAI test:
  model `ENIGMA_ANTHROPIC_MODEL` or `claude-sonnet-4-6`, with
  `EnvironmentCredentials`.
- [ ] **The owner runs it.** The coordinator asks the owner to run this. It
  costs about 1 to 5 searches.

  ```sh
  read -rs ENIGMA_KEY && TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 TEST_RUNNER_ENIGMA_ANTHROPIC_KEY="$ENIGMA_KEY" scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeWebSearchLiveTests/testAnthropicSearchesLive; unset ENIGMA_KEY
  ```

- [ ] **Turn Anthropic on** after it passes: the set becomes
  `[.openAI, .anthropic]`, and `testNativeWebSearchProviders` matches. If
  the owner has no Anthropic key, leave it off and say so.
- [ ] **Run** the full `test` action. Expect it to pass.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- [ ] The live check passed, run by the owner, or Anthropic stays off with
  the reason in the Hand-off.
- [ ] `plutil -lint` passes.

## Reviewer checklist

- **Tool choice:** the prefixes match CP0's evidence. An unknown model gets
  the basic tool, and the code never sends `allowed_domains` with
  `blocked_domains`.
- **The accumulator:**
  - the blocks it sends back are byte-for-byte what was received, after
    reassembly, including `signature` and encrypted fields;
  - no block is dropped or reordered;
  - the continuation never adds a user message.
- **Continuation:** capped at 3; cancelling during a continuation stops it;
  only one `.completed`.
- **Errors:** search error objects are logged by code only, never with a
  query or URL.
- **Unchanged without search:** requests and streams match before and after,
  including `/think`.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
