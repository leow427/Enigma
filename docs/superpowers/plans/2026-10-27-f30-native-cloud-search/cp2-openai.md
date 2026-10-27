# CP2: OpenAI — the Responses API's `web_search`

Read [agent-workflow.md](agent-workflow.md), the spec (§2 "OpenAI", §3,
§4), and the Hand-offs of [CP0](cp0-spike.md#hand-off) (Q3) and
[CP1](cp1-shared-plumbing.md#hand-off).

## Goal

`OpenAIResponsesClient` searches with OpenAI's `web_search` tool when a
request carries `webSearch`. It reports searches, results and the chosen
sources, and maps a rejected tool to `.webSearchUnavailable(.openAI)`. After
the owner's live check passes, `.openAI` joins
`CloudProviderID.nativeWebSearchProviders`.

## Starting point

- **`OpenAIResponsesClient`** (`Enigma/Cloud/CloudProviderClients.swift`):
  - `makeRequest(for:)` builds `model`, `instructions`
    (`ChatResponseStyle.instructions`), `input`, `stream`, `store: false`
    and `max_output_tokens`, plus `reasoning` for `/think`;
  - `consume` reads server-sent events through `ServerSentEventParser`;
  - `handle` decodes each event as `OpenAIStreamPayload`, with `type`,
    `delta`, `error` and `response`. It throws `invalidResponse` when
    decoding fails;
  - HTTP errors go through `cloudHTTPError`.
- **CP1** provides:
  - `CloudWebSearch` and `ChatRequest.webSearch`;
  - `NativeWebSearch.instructions(blockedDomains:namesBlockedDomains:)`;
  - `NativeWebSearchSources`;
  - `.webSearchUnavailable`;
  - `CloudSearchFixture`.
- **CP0's fixtures:** `openai-web-search.sse`,
  `openai-invalid-tool-error.json`, and maybe `openai-model-error.json`.
  Q3's answer says whether inline links are already in the text.
- **Test doubles:** `MockCloudTransport` and `MockCredentialStore` in
  `CloudModeTests`.

## Tasks

### Task 2.1: The search request

**Files:** modify `Enigma/Cloud/CloudProviderClients.swift`. Tests go in
`CloudModeTests`.

**Interfaces.** This task produces:

```swift
extension OpenAIResponsesClient {
  /// ["tools": [["type": "web_search"]], "include": ["web_search_call.action.sources"],
  ///  "max_tool_calls": NativeWebSearch.maximumSearches]
  static func webSearchFields(_ search: CloudWebSearch) -> [String: Any]
}
```

With `webSearch` set, `makeRequest` merges these fields. `instructions`
becomes `ChatResponseStyle.instructions + "\n\n" +
NativeWebSearch.instructions(blockedDomains: search.blockedDomains,
namesBlockedDomains: true)`. Nothing else changes, and there's no location
field.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testOpenAIRequestWithoutSearchIsUnchanged`:** the body has no
    `tools`, `include` or `max_tool_calls`, and `instructions` equals
    `ChatResponseStyle.instructions`.
  - **`testOpenAISearchRequestAddsToolSourcesAndLimit`.** With
    `CloudWebSearch(blockedDomains: ["b.example"])`:
    - `tools == [["type": "web_search"]]`;
    - `include == ["web_search_call.action.sources"]`;
    - `max_tool_calls == 5`;
    - `instructions` starts with `ChatResponseStyle.instructions` and ends
      with the instruction naming `b.example`;
    - `store == false`;
    - no key contains `location`.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/CloudModeTests`.
  Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 2.2: The stream

**Files:** the same. Tests go in `CloudModeTests`.

**Events,** using the item shapes CP0 recorded. Decode the new fields as
optionals, so other events and unknown annotation types still decode.

| Event | Action |
| --- | --- |
| `response.output_item.added`, `item.type == "web_search_call"` | `sources.noteSearch()`; yield `.activity(.phase(.searching))` |
| `response.output_item.done`, `item.type == "web_search_call"` | Map `item.action.sources[].url` to sources with blank titles; yield `.activity(.sourcesDiscovered(new))` when `sources.discover` returns any |
| `response.output_text.delta` | As today, and also `sources.appendAnswer(delta)` |
| `response.output_item.done`, `item.type == "message"` | `sources.cite` each `url_citation` annotation of each `output_text` part |
| `response.completed`, or `[DONE]` if that comes first | Yield `.activity(.sourcesSelected(selection))` when `sources.selection()` isn't nil, then `.completed`, once |

**Steps:**

- [ ] **Write the failing tests:**
  - **`testOpenAISearchStreamReportsActivityAndCitedSources`.** Feed
    `openai-web-search.sse` through `MockCloudTransport`:
    - the first activity is `.phase(.searching)`;
    - at least one `.sourcesDiscovered` is non-empty;
    - the tokens join to the answer text in the fixture;
    - the last two events are `.activity(.sourcesSelected(expected))` and
      `.completed`. `expected` is computed with
      `NativeWebSearch.selectSources` from the fixture's annotations,
      answer links and sources, and the test writes it out literally.
  - **`testOpenAIStreamWithoutSearchHasNoSourceEvents`:** a plain text
    stream yields only tokens and `.completed`.
- [ ] **Run.** Expect failures.
- [ ] **Implement.** Keep one `NativeWebSearchSources` per `consume` call.
- [ ] **Run.** Expect the tests to pass.

### Task 2.3: Rejections and inline citations

**Files:** the same. Tests go in `CloudModeTests`.

**Interfaces.** This task produces
`static func isWebSearchRejection(statusCode: Int, body: Data) -> Bool` on
`OpenAIResponsesClient`. It's true for a 400 whose error `param` starts with
`tools`, or whose message mentions `web_search`, case-insensitively. Pin the
match to CP0's recorded bodies.

When a request with `webSearch` gets a rejection, `consume` throws
`.webSearchUnavailable(.openAI)` instead of `cloudHTTPError`'s result.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testOpenAISearchRejectionIsUnavailable`:**
    - `openai-invalid-tool-error.json` with status 400, on a search request,
      throws `.webSearchUnavailable(.openAI)`;
    - the same body without `webSearch` throws `.requestFailed`;
    - a 400 about something else, such as
      `{"error":{"message":"Invalid input","param":"input"}}`, throws
      `.requestFailed`.
  - **`testOpenAIModelWithoutSearchIsUnavailable`:** only if CP0 recorded
    `openai-model-error.json`. It throws `.webSearchUnavailable(.openAI)`.
  - **Inline citations, per CP0's Q3:**
    - **If the text already holds the links:**
      `testOpenAIAnswerKeepsInlineCitationLinks`. The fixture's joined
      tokens contain every cited URL as a Markdown link.
    - **If it doesn't:** `testOpenAIAppendsCitationLinksMissingFromText`.
      Before `.completed`, the client yields one token: `"\n\n"` followed by
      each cited source not already linked, as `[siteName](url)`, joined
      with `" · "`. Linked ones aren't repeated.
- [ ] **Run.** Expect failures.
- [ ] **Implement,** then run. Expect the tests to pass.

### Task 2.4: The live check, and turning OpenAI on

**Files:**

- Create `EnigmaTests/NativeWebSearchLiveTests.swift`, registered in the
  test target.
- Modify `Enigma/Cloud/CloudDomain.swift` (the provider set) and
  `NativeWebSearchTests` (`testNativeWebSearchProviders`).

**Interfaces.** This task produces:

```swift
final class NativeWebSearchLiveTests: XCTestCase {
  func testOpenAISearchesLive() async throws
}
/// Reads ENIGMA_OPENAI_KEY and ENIGMA_ANTHROPIC_KEY; stores nothing.
struct EnvironmentCredentials: CloudCredentialStore
/// Collects a stream's events with a 120 s limit.
func liveEvents(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent]
```

**The test:**

- **Skips** unless `ENIGMA_NATIVE_SEARCH_LIVE == "1"` and the key is set.
- **Sends**, with model `ENIGMA_OPENAI_MODEL` or `gpt-5.6-luna`, through
  `OpenAIResponsesClient(credentialStore: EnvironmentCredentials(), transport: URLSessionCloudTransport.shared)`:
  - one user message: "What is the latest stable Swift release? Link your
    source.";
  - `webSearch: CloudWebSearch()`.
- **Asserts:**
  - a `.phase(.searching)` arrives;
  - some tokens arrive;
  - a non-empty `.sourcesSelected` with only safe links;
  - `.completed` last.

**Steps:**

- [ ] **Write the test, and run it without the variables.** Expect a skip.
- [ ] **The owner runs it.** Ask the owner to run this from the
  worktree. It costs about 1 to 5 searches.

  ```sh
  read -rs ENIGMA_KEY && TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 TEST_RUNNER_ENIGMA_OPENAI_KEY="$ENIGMA_KEY" scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeWebSearchLiveTests/testOpenAISearchesLive; unset ENIGMA_KEY
  ```

  Expect it to pass. If it fails, fix the cause before going on.
- [ ] **Turn OpenAI on,** once the live check passes:
  - `nativeWebSearchProviders = [.openAI]`;
  - `testNativeWebSearchProviders` now expects `[.openAI]`.

  If the owner has no OpenAI key, leave it off and say so in the Hand-off.
- [ ] **Run** the full `test` action. Expect it to pass. The pinned
  on-device tests are unaffected.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- [ ] The live check passed, run by the owner, or OpenAI stays off with the
  reason in the Hand-off.
- [ ] `plutil -lint` passes.

## Reviewer checklist

- **Request:** no location or `filters` field; `store` stays false;
  `max_tool_calls` is 5.
- **Decoding:**
  - unknown item, action and annotation shapes don't throw
    `invalidResponse`;
  - an `output_item.done` without `action.sources` is fine.
- **Ordering:** `.sourcesSelected` comes once, before `.completed`, and only
  if a search happened.
- **Rejections:** only search-related 400s become unavailable. A 401, 429
  or 5xx keeps its existing error.
- **Keys:** no key in the test file or fixtures, and the live test skips
  cleanly in CI.

## Hand-off

*Filled in by the CP2 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
