# CP1: Shared plumbing — types, decision, sources, the view model's path

Read [agent-workflow.md](agent-workflow.md), the spec (§1, §3, §4,
"Failure handling"), and [CP0's Hand-off](cp0-spike.md#hand-off).

## Goal

Build everything the four providers share, without changing what users see:

- `ChatRequest` can ask for provider search;
- `NativeWebSearch` decides when to use it, writes the instruction, and
  chooses the sources;
- `LocalChatViewModel` has a provider-search path with acceptance at the
  first event, a one-time fallback to on-device search, and source saving.

`CloudProviderID.nativeWebSearchProviders` stays empty, so every request
still searches on the Mac.

## Starting point

Line numbers are from before F29 merged. Find code by symbol.

- **`Enigma/Chat/ChatDomain.swift`:**
  - `ChatRequest` has `sessionID`, `messages`, `route`, `image` and
    `allowsCloudImages`;
  - `ChatEvent` is `.activity`, `.token` or `.completed`.
- **`Enigma/Cloud/CloudDomain.swift`:**
  - `CloudProviderID` (line 36);
  - `CloudProviderError` (line 110) and its `errorDescription`.
- **`Enigma/Chat/AssistantActivity.swift`:**
  - `AssistantActivityEvent` has `.phase`, `.sourcesDiscovered` and
    `.sourcesSelected`;
  - `WebSearchSource.isSafeWebLink` and `.siteName`.
- **`Enigma/LocalInference/LocalChatViewModel.swift`:**
  - **`submitCloud`** (about line 1062) prepares with `CloudContext.prepare`,
    then calls `submitCloudWithSearch(userMessage, route:onAccepted:)` when
    `searchEnabled`;
  - **`submitCloudWithSearch`** (about 1139) begins the generation, sets
    `state = .searching` and `pendingUserMessage`, and then, in its task:
    1. searches;
    2. grounds with `WebSearchContext.prepare`;
    3. appends the user message and an assistant message with
       `searchSources`;
    4. calls `onAccepted`;
    5. streams.
  - **`beginGeneration`** creates `activity`. `append(_:to:)` attaches the
    activity to an assistant message (`activityMessageID`), and
    `finishGeneration` clears it;
  - **`receiveActivity(_:requestID:)`** applies an event and copies the
    activity into the reply.
- **`ScreenSearchContext.question(_:)`** (`Enigma/Screen/ScreenPromptContext.swift`)
  removes slash commands. F29's `SearchRouting.decide(question:)` takes its
  output.
- **F29's `WebSearchSettings.blockedSites`** is stored oldest first.
- **Test doubles to reuse:**
  - `WebSearchTests`: `SearchSpy`, `SearchLocalEngine`,
    `SearchCloudProvider`, `ActivityCloudProvider`, `SearchLocation`, and
    the `makeModel` and `finish` helpers;
  - `RequestLifecycleTests`: `ControlledStream` and
    `LifecycleCloudProvider`.

## Tasks

### Task 1.1: The request field, the error and the provider set

**Files:** modify `Enigma/Chat/ChatDomain.swift` and
`Enigma/Cloud/CloudDomain.swift`. Tests go in the new
`EnigmaTests/NativeWebSearchTests.swift`, registered in the test target.

**Interfaces.** This task produces:

```swift
// ChatDomain.swift
struct CloudWebSearch: Sendable, Equatable {
  /// F29's blocked sites, most recently blocked first.
  var blockedDomains: [String] = []
}
struct ChatRequest: Sendable, Equatable {
  // existing fields unchanged
  var webSearch: CloudWebSearch? = nil         // nil: no provider search
}

// CloudDomain.swift
extension CloudProviderID {
  /// The providers whose own search is turned on. CP2–CP5 each add theirs; never `.gemini`.
  static let nativeWebSearchProviders: Set<CloudProviderID> = []
  var supportsNativeWebSearch: Bool { Self.nativeWebSearchProviders.contains(self) }
}
enum CloudProviderError {
  case webSearchUnavailable(CloudProviderID)   // "Web search isn't available for this model."
}
```

**Steps:**

- [ ] **Write the failing tests** in `NativeWebSearchTests`:
  - `testChatRequestHasNoWebSearchByDefault`: a `ChatRequest` built without
    the field has `webSearch == nil`.
  - `testUnavailableErrorMessage`:
    `CloudProviderError.webSearchUnavailable(.openAI).errorDescription == "Web search isn't available for this model."`.
  - `testNativeWebSearchProviders`:
    `CloudProviderID.nativeWebSearchProviders == []`, and
    `CloudProviderID.gemini.supportsNativeWebSearch == false`. CP2–CP5
    update the expected set as they turn providers on.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeWebSearchTests`.
  Expect a compile failure.
- [ ] **Implement.** `errorDescription` gets the new case. Check that every
  `switch` over `CloudProviderError` in the app still compiles.
- [ ] **Run** the tests. Expect them to pass.

### Task 1.2: `NativeWebSearch` and the source collector

**Files:** create `Enigma/Cloud/NativeWebSearch.swift`, registered in the app
target. Tests go in `NativeWebSearchTests`.

**Interfaces.** This task produces:

```swift
enum NativeWebSearch {
  static let maximumSearches = 5
  static let maximumNamedBlockedSites = 20
  /// Spec §3's text, plus "Don't use results from these sites: …" when `namesBlockedDomains`.
  static func instructions(blockedDomains: [String], namesBlockedDomains: Bool) -> String
  enum Decision: Equatable, Sendable { case native, onDevice }
  static func decide(provider: CloudProviderID, modelID: String, question: String,
                     hasSourceMaterial: Bool, enabledProviders: Set<CloudProviderID>,
                     availability: NativeWebSearchAvailability) -> Decision
  static func selectSources(cited: [WebSearchSource], linked: [URL],
                            discovered: [WebSearchSource]) -> [WebSearchSource]
  /// Markdown links (not images) and bare http(s) URLs, in first-seen order, without duplicates.
  static func links(in text: String) -> [URL]
}

struct NativeWebSearchAvailability: Equatable, Sendable {
  mutating func markUnavailable(_ provider: CloudProviderID, modelID: String)
  func isAvailable(_ provider: CloudProviderID, modelID: String) -> Bool
}

/// One request's search bookkeeping, shared by the four provider clients.
struct NativeWebSearchSources: Sendable {
  private(set) var searched: Bool
  mutating func noteSearch()
  /// Records sources; returns the safe ones not seen before, blank titles replaced by
  /// `siteName`, for `.sourcesDiscovered`.
  mutating func discover(_ sources: [WebSearchSource]) -> [WebSearchSource]
  mutating func cite(_ source: WebSearchSource)
  mutating func appendAnswer(_ fragment: String)
  /// What `.sourcesSelected` carries: `selectSources(cited:linked: links(in: answer), discovered:)`,
  /// or nil when the model never searched.
  func selection() -> [WebSearchSource]?
}
```

**The rules:**

- **The instruction text** is spec §3's quoted paragraph, exactly. The
  blocked-sites sentence is added after one space: "Don't use results from
  these sites: " plus at most 20 domains in the given order, joined by ", ",
  and a final period. It's left out when the list is empty or
  `namesBlockedDomains` is false.
- **`decide`** returns `.onDevice` when any of these holds; otherwise
  `.native`:
  - the provider is `.gemini`;
  - the provider isn't in `enabledProviders`;
  - the provider and model are marked unavailable;
  - `hasSourceMaterial` is true;
  - `SearchRouting.decide(question:).route` isn't `.web`.
- **`selectSources`** follows spec §4:
  1. Cited sources first, then linked URLs, then the discovered sources,
     but only when the first two gave nothing.
  2. Sources are the same when their URLs match without the fragment; the
     first one wins.
  3. Only `isSafeWebLink` URLs are kept.
  4. A linked URL takes the title of a matching cited or discovered source.
     A source with no title, or a blank one, uses `siteName`.
  5. At most `WebSearchLimits.maximumSources`.

**Steps:**

- [ ] **Write the failing tests:**
  - **`testInstructionTextMatchesSpec`:**
    `instructions(blockedDomains: [], namesBlockedDomains: true)` equals the
    spec's paragraph, character for character.
  - **`testInstructionNamesAtMostTwentyBlockedSites`:**
    - 25 domains, `d01.example` … `d25.example`;
    - the result ends with
      `" Don't use results from these sites: d01.example, d02.example, …, d20.example."`
      (write out all 20);
    - it doesn't contain `d21.example`.
  - **`testInstructionOmitsBlockedSitesWhenNotNamed`:** with
    `namesBlockedDomains: false`, the result is the base text.
  - **`testDecideUsesProviderSearchOnlyForEnabledProviders`:** with enabled
    `[.openAI]` and "latest swift release notes", `.openAI` gives `.native`
    and `.anthropic` gives `.onDevice`.
  - **`testDecideKeepsPlacesAndWeatherOnDevice`:** with every provider
    enabled:
    - "cafe near me", "will it rain tomorrow" and "ramen in Soho" give
      `.onDevice`;
    - "latest swift release notes" gives `.native`.
  - **`testDecideKeepsSourceMaterialOnDevice`:** `hasSourceMaterial: true`
    gives `.onDevice`.
  - **`testDecideSkipsUnavailableModelOnly`:** after
    `markUnavailable(.openAI, modelID: "a")`, model "a" gives `.onDevice`
    and model "b" gives `.native`.
  - **`testGeminiNeverSearchesNatively`:** with `.gemini` in
    `enabledProviders`, the result is still `.onDevice`.
  - **`testSelectSourcesPutsCitedFirstThenLinks`:**
    - cited `[A]`, linked `[B.url, A.url]`, discovered `[C, B]`;
    - the result is `[A, B]`, and B keeps its discovered title.
  - **`testSelectSourcesFallsBackToDiscoveredWhenNothingCited`:** with no
    cited sources and no links, discovered `[C, D]` gives `[C, D]`.
  - **`testSelectSourcesDropsFragmentDuplicates`:** cited
    `https://e.example/a#x` and `https://e.example/a#y` give one source.
  - **`testSelectSourcesDropsUnsafeLinks`:** these are all dropped:
    - `javascript:alert(1)`;
    - `https://user:pass@e.example/`;
    - `ftp://e.example/f`;
    - a relative `/path`.
  - **`testSelectSourcesCapsAtEight`:** 12 cited sources give the first 8.
  - **`testSelectSourcesNamesLinksWithoutTitles`:** a link to
    `https://www.swift.org/blog/` that no source knows is titled
    `swift.org`.
  - **`testLinksFindsMarkdownAndBareURLsInOrder`.** The text:

    ```text
    See [Swift](https://en.wikipedia.org/wiki/Swift_(programming_language)), ![img](https://e.example/i.png) and https://swift.org/blog/. Also [again](https://swift.org/blog/).
    ```

    gives exactly
    `[https://en.wikipedia.org/wiki/Swift_(programming_language), https://swift.org/blog/]`.
    That means balanced parentheses are kept, the trailing period is
    dropped, the image is skipped, and the duplicate is removed.
  - **`testSourceCollectorReportsOnlyNewSafeSources`:**
    - `discover([A, unsafe])` returns `[A]`;
    - `discover([A, B])` then returns `[B]`.
  - **`testSourceCollectorSelectsNothingWithoutASearch`:** `selection()` is
    nil until `noteSearch()` runs. After it runs, `selection()` follows
    `selectSources`, using the links in the appended answer.
- [ ] **Run** `NativeWebSearchTests`. Expect failures.
- [ ] **Implement.** For bare URLs, `NSDataDetector` with `.link` is fine.
  Keep only `http` and `https`, and skip ranges already inside a Markdown
  link.
- [ ] **Run** `NativeWebSearchTests`. Expect them to pass.

### Task 1.3: Test support

**Files:** create `EnigmaTests/CloudSearchTestSupport.swift`, registered in
the test target.

**Interfaces.** This task produces:

```swift
enum CloudSearchFixture {
  /// `EnigmaTests/Fixtures/CloudSearch/<name>`, found through #filePath.
  static func url(_ name: String) -> URL
  static func data(_ name: String) throws -> Data
  static func lines(_ name: String) throws -> [String]          // JSONL, blank lines dropped
}

/// A ChatProvider whose n-th call (0-based) returns `respond(request, n)`.
final class ScriptedCloudProvider: ChatProvider, @unchecked Sendable {
  init(_ respond: @escaping @Sendable (ChatRequest, Int) -> AsyncThrowingStream<ChatEvent, Error>)
  var requests: [ChatRequest] { get }
  static func events(_ events: [ChatEvent], thenThrow error: Error? = nil)
    -> AsyncThrowingStream<ChatEvent, Error>
  /// Never yields; finishes with CancellationError when the consumer cancels.
  static func hanging() -> AsyncThrowingStream<ChatEvent, Error>
}
```

**Steps:**

- [ ] **Write** `testScriptedProviderCountsCalls` in `NativeWebSearchTests`:
  the second call receives `n == 1`, and `requests.count == 2`.
- [ ] **Implement and run.** Expect it to pass.

### Task 1.4: Keep the on-device cloud tests on on-device search

**Files:** modify `Enigma/LocalInference/LocalChatViewModel.swift` (the
initializer only), and the test files listed below.

**Interfaces.** This task produces
`LocalChatViewModel.init(..., nativeWebSearchProviders: Set<CloudProviderID> = CloudProviderID.nativeWebSearchProviders, ...)`,
placed after `webSearch:`. It's stored in a private `let`.

**Steps:**

- [ ] **Add the parameter.**
- [ ] **Find every test that runs a cloud search** with OpenAI, Anthropic,
  ChatGPT or Claude Code. Search `EnigmaTests` for `searchEnabled: true`,
  `submitCloud(`, `submitAuto(` and `/search`, and follow each test's model
  factory, for example `makeModel` in `WebSearchTests`. Pass
  `nativeWebSearchProviders: []` there, with the comment:
  `// Covers on-device search on cloud routes; provider search has its own tests.`
- [ ] **Run** the full `test` action. Expect every test to pass unchanged:
  the set is still empty, so this changes nothing yet.

### Task 1.5: The provider-search path in `LocalChatViewModel`

**Files:** modify `Enigma/LocalInference/LocalChatViewModel.swift`. Tests go
in `WebSearchTests` and `RequestLifecycleTests`.

**Interfaces.**

- **Consumes:** Tasks 1.1–1.4, `SearchRouting.decide(question:)`, and
  `WebSearchSettings.blockedSites`.
- **Produces:**
  - a private `submitCloudWithNativeSearch(_ userMessage:prepared:route:provider:onAccepted:)`;
  - a private `nativeSearchAvailability: NativeWebSearchAvailability`;
  - the on-device body of `submitCloudWithSearch`, extracted into a private
    `async throws` method that runs inside an existing generation, so the
    fallback can reuse it without a second `beginGeneration`.

**Behavior,** from spec §1:

1. **Choose the path.** In `submitCloud`, when `searchEnabled`, call
   `NativeWebSearch.decide` with:
   - the provider and model;
   - `question: ScreenSearchContext.question(trimmedPrompt)`;
   - `hasSourceMaterial`, which is true when `userMessage.contexts` isn't
     empty or `userMessage.selectionDraft` isn't nil;
   - the stored provider set and the availability.

   `.onDevice` runs `submitCloudWithSearch` as today. `.native` runs the new
   path.
2. **Start.** The new path begins the generation, sets `state = .preparing`
   and `pendingUserMessage = userMessage`, and reports `.phase(.thinking)`.
   It streams:

   ```swift
   ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: prepared.messages,
               route: route, webSearch: CloudWebSearch(blockedDomains: blocked))
   ```

   `blocked` is `searchSettings?.blockedSites.reversed()`, or `[]`.
3. **Accept** at the first event of any kind:
   - `ensureSelectedSession()`;
   - append the user message, then an empty assistant message;
   - set `contextNotice = prepared.notice` and
     `messagesFollowUpSessionID = nil`;
   - call `onAccepted()`.

   Then handle the event:
   - `.activity` goes to `receiveActivity`;
   - `.token` appends text;
   - `.completed` does nothing.
4. **Fall back** when `CloudProviderError.webSearchUnavailable` arrives
   before acceptance:
   - mark the provider and model unavailable;
   - run the extracted on-device body for the same `userMessage`, `route`
     and active request, so `onAccepted` runs once, at its own acceptance
     point;
   - this happens at most once per request.
5. **Save sources.** When the stream ends after acceptance, by success or
   error, set the reply's `searchSources` to its `activity.sources` if
   there are any. Do it before `finishGeneration`, which clears the
   activity.
6. **Stop and errors.** Stop and every other error behave as on the search
   path. Before acceptance, nothing was appended, so the draft stays.

**Steps:**

- [ ] **Write the failing tests** in `WebSearchTests`. Each builds the model
  with `nativeWebSearchProviders` set as stated and a `ScriptedCloudProvider`
  for every cloud slot.
  - **`testProviderSearchSkipsOnDeviceSearchAndSavesSelectedSources`.**
    - Setup: `[.openAI]`. The script is `.activity(.phase(.searching))`,
      `.activity(.sourcesDiscovered([A, B]))`, `.token("Answer")`,
      `.activity(.sourcesSelected([A]))`, `.completed`.
    - Expect:
      - `search.requests` is empty;
      - `requests[0].webSearch == CloudWebSearch()`;
      - `messages.map(\.content) == [prompt, "Answer"]`;
      - `messages.last?.searchSources == [A]`;
      - the store saves `[A]`.
  - **`testProviderSearchSendsBlockedSitesMostRecentFirst`:** after F29's
    `WebSearchSettings.block(_:)` with `https://a.example/x`, then
    `https://b.example/y`, the request's
    `webSearch?.blockedDomains == ["b.example", "a.example"]`. Use a
    settings object on its own `UserDefaults(suiteName:)`.
  - **`testProviderSearchFallsBackOnceAndRemembersTheModel`.**
    - Setup: call 0 throws `.webSearchUnavailable(.openAI)`. Later calls
      answer "Answer".
    - Expect:
      - the on-device search runs once;
      - the second provider call has `webSearch == nil`, and its last
        message contains the evidence;
      - `onAccepted` ran once.
    - Then:
      - a second `submitCloud` with the same model goes straight to
        on-device search, with no `webSearch` request;
      - one with another model ID asks for provider search again.
  - **`testUnavailableAfterFirstEventDoesNotFallBack`.**
    - Setup: the script is `.activity(.phase(.searching))`, `.token("Part")`,
      then throws `.webSearchUnavailable(.openAI)`.
    - Expect:
      - no on-device search, and one provider call;
      - the state is failed;
      - the reply keeps "Part".
  - **`testPlacesWeatherSelectionAndGeminiStayOnDevice`.** With every
    provider enabled:
    - "cafe near me" (with `SearchLocation`) and "will it rain tomorrow" on
      `.openAI`;
    - a turn carrying an attached selection context on `.anthropic`;
    - "latest swift release notes" on `.gemini`.

    Each runs the on-device search once, and every provider request has
    `webSearch == nil`.
  - **`testAutoCloudRouteUsesProviderSearch`:** with `[.chatGPT]`,
    `submitAuto` with search on, using the prompt and cloud configuration
    of the existing `auto-cloud` case in
    `testSearchGroundsLocalAndEveryCloudProviderAndPersistsOnlySources`,
    so Auto picks ChatGPT. It sends a request with `webSearch` set, and runs
    no on-device search.
- [ ] **Write the failing tests** in `RequestLifecycleTests`:
  - **`testNativeSearchAcceptsAtFirstEvent`.** With a stream held by
    `ControlledStream`:
    - before the first event, `messages` is empty and `onAccepted` hasn't
      run;
    - after `.activity(.phase(.searching))`, both messages exist and
      `onAccepted` ran once.
  - **`testStopBeforeFirstNativeEventAppendsNothing`.** With
    `ScriptedCloudProvider.hanging()`, `stopStreaming()` leaves:
    - `messages` empty;
    - `onAccepted` not run;
    - `state == .idle`;
    - the provider's stream cancelled, so the hanging stream's termination
      handler ran.
  - **`testNativeFailureAfterTextKeepsTextAndSources`.**
    - Setup: discovered `[A]`, `.token("Part")`, then a
      `CloudProviderError.providerMessage("x")`.
    - Expect: the reply keeps "Part", `searchSources == [A]`, and the state
      is failed.
- [ ] **Run** both classes. Expect failures.
- [ ] **Implement** the behavior above.
- [ ] **Run** `NativeWebSearchTests`, `WebSearchTests` and
  `RequestLifecycleTests`, then the full `test` action. Expect everything to
  pass.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- [ ] `CloudProviderID.nativeWebSearchProviders` is `[]`, and no existing
  test changed except to pass `nativeWebSearchProviders: []`.
- [ ] `plutil -lint Enigma.xcodeproj/project.pbxproj` passes.

## Reviewer checklist

- **The decision:**
  - places, weather, source material, Gemini and unavailable pairs all stay
    on-device;
  - the question passed is the typed text with slash commands removed,
    never a written query.
- **The fallback:**
  - it runs only before acceptance, at most once per request, and never
    after an event;
  - the availability mark is per provider and model, and in memory only.
- **Acceptance:** nothing is appended before the first event, and
  `onAccepted` runs exactly once on every path.
- **Sources:** saved only after acceptance and only when present, never
  with an unsafe URL. `searchSources` encodes as before.
- **No behavior change:** with the empty set, nothing reaches the new path.
  Mutation-test the pin in a scratch copy:
  1. Add `.openAI` to the set. The pinned on-device tests still pass, and
     only `testNativeWebSearchProviders` fails.
  2. Then remove `nativeWebSearchProviders: []` from one pinned factory.
     Its OpenAI search test now fails.

## Hand-off

*Filled in by the CP1 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
