# CP2: OpenAI — the search tool in the Responses tool loop

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "OpenAI", §4, §5),
and the Hand-offs of [CP0](cp0-spike.md#hand-off) and
[CP1](cp1-shared-plumbing.md#hand-off).

## Goal

On a request with `providerSearch` set, OpenAI's tool loop offers its
`web_search` tool beside F32's function tools, streams its searches and
citations into the activity and sources, replays search items between
steps, and maps a rejection to `.webSearchUnavailable(.openAI)`. When the
owner's live check passes, `.openAI` joins
`CloudProviderID.nativeWebSearchProviders`.

## Starting point

- **`OpenAIResponsesClient`'s `ToolCallingChatProvider` extension**
  (`Enigma/Cloud/CloudToolCalling.swift`) builds each step's body: `model`,
  `instructions` (`CloudToolLoop.systemPrompt(toolbox)`), `input`, `tools`
  (functions), `parallel_tool_calls: false`, `store: false`,
  `max_output_tokens`, `stream: true`, `reasoning` for `/think`, and
  `tool_choice` for a required function on step 1. Each step appends
  `assembler.replayItems` and the function outputs to `input`.
- **`OpenAIToolStreamAssembler`** (`CloudToolStreaming.swift`) assembles text
  deltas and function calls.
- **CP1:** `ChatRequest.providerSearch`, `NativeWebSearchSources`,
  `.webSearchUnavailable`, `CloudSearchFixture`, and the restart.
- **CP0's fixtures and Q1:** the event order, item shapes, whether links are
  in the text, `max_tool_calls`, forced choice, and what replay needs.
- **Test doubles:** F32's `CloudToolStreamingTests` transport for streamed
  bodies, and `QueuedTransport`.

## Tasks

### Task 2.1: The request

**Interfaces:**

```swift
extension OpenAIResponsesClient {
  /// The fields a provider-search step adds (spec §3, CP0 Q1).
  static func webSearchFields(required: Bool) -> [String: Any]
}
```

- [ ] **Write the failing tests** in `CloudToolStreamingTests`:
  - `testOpenAIProviderSearchBody`: the step body's `tools` hold F32's
    functions plus `{"type": "web_search"}` (no `user_location`, no
    `filters`); `include` is `["web_search_call.action.sources"]`;
    `max_tool_calls` is 5 only if CP0 confirmed it counts built-in calls
    alone; `store` is false.
  - `testOpenAIForcedProviderSearch`: a typed `/search` sends CP0's forced
    form on step 1, or F32's instruction if CP0 found it unsupported.
  - `testOpenAIWithoutProviderSearchUnchanged`: F32's body, byte for byte.
- [ ] **Run, implement, run.**

### Task 2.2: The stream and replay

- [ ] **Write the failing tests:**
  - `testOpenAISearchEventsFromFixture`: `openai-search-and-function.sse`
    gives `.phase(.searching)`, `.sourcesDiscovered` from
    `action.sources[].url` (site names as titles), the text, and a function
    call.
  - `testOpenAICitationsBecomeSelectedSources`: `url_citation` annotations
    are cited sources; `.sourcesSelected` comes before `.completed`.
  - `testOpenAIReplaysSearchItems`: the next step's `input` holds the items
    in the shape CP0's `openai-replay-request.json` shows.
  - `testOpenAIRestartDeliversNothing`: when the gate raises
    `ProviderSearchRestart` during a `get_messages` call, no
    `function_call_output` is posted.
- [ ] **Run, implement, run.**

### Task 2.3: Rejections and inline citations

**Interfaces:** `static func isWebSearchRejection(statusCode: Int, body: Data) -> Bool`
on `OpenAIResponsesClient`: true for a 400 whose error `param` starts with
`tools` or whose message mentions `web_search`, case-insensitively, pinned
to CP0's bodies. A provider-search request with a rejection throws
`.webSearchUnavailable(.openAI)`.

- [ ] **Write the failing tests:**
  - `testOpenAISearchRejectionIsUnavailable`: the invalid-tool body on a
    provider-search request is unavailable; the same body without
    `providerSearch` keeps today's error; a 400 about `input` keeps today's
    error.
  - `testOpenAIModelWithoutSearchIsUnavailable`, if CP0 recorded it.
  - Per CP0's Q1: `testOpenAIAnswerKeepsInlineCitationLinks` if the text
    holds the links, or `testOpenAIAppendsCitationLinksMissingFromText`
    (one final token, `"\n\n"` plus `[site](url)` per missing cited link, in
    order) if it doesn't.
- [ ] **Run, implement, run.**

### Task 2.4: The live check, and turning OpenAI on

**Files:** create `EnigmaTests/NativeWebSearchLiveTests.swift` (test
target); modify `CloudDomain.swift` and `NativeWebSearchTests`.

```swift
final class NativeWebSearchLiveTests: XCTestCase {
  /// Skips unless ENIGMA_NATIVE_SEARCH_LIVE and ENIGMA_OPENAI_KEY are set (F32's EnvironmentCredentials).
  func testOpenAISearchesLive() async throws
}
```

- [ ] **Write the test:** through `submitNative` on a real OpenAI route, the
  Swift release question: at least one `.searching` phase, at least one
  selected source that passes `isSafeWebLink`, a non-empty answer.
- [ ] **Get the owner's approval** (about 2 searches), hand them the
  command, and record its output in the Hand-off.
- [ ] **When it passes,** add `.openAI` to `nativeWebSearchProviders` and
  update `testNativeWebSearchProviders`.

## Exit criteria

- `CloudToolStreamingTests`, `NativeWebSearchTests`, `NativeToolRequestTests`
  pass; `build` and `analyze` succeed; the full `test` once before the
  commit.
- The live check passed on the owner's Mac, or `.openAI` stays off and the
  Hand-off says why.
- CI passes on the pushed commit.

## Reviewer checklist

- No location field in any OpenAI body; `store: false` kept.
- Replay matches CP0's recorded body; nothing is replayed that `store:
  false` rejects.
- The restart posts no function output; mutation-test it.
- F32's body without provider search is unchanged.

## Hand-off

*Filled in by the CP2 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
