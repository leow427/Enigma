# CP4: ChatGPT (Codex) — live web search beside the dynamic tools

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "ChatGPT", §4,
§5), and the Hand-offs of [CP0](cp0-spike.md#hand-off) and
[CP1](cp1-shared-plumbing.md#hand-off). CP2 and CP3 are deferred (owner,
2026-10-29), so this checkpoint follows CP1 and creates the live-test file
CP2 would have made (Task 4.3).

## Goal

A provider-search Codex thread asks for live web search beside F32's
dynamic tools, falls back to `cached` or unavailable under a workspace
policy, reports `webSearch` items as activity and sources, and takes its
cited sources from the answer's links. When the owner's live check passes,
`.chatGPT` joins the provider set.

## Starting point

- **`CodexToolMode`** (`CloudToolCalling.swift`):
  `threadParameters(model:toolbox:)` builds `thread/start` with
  `dynamicTools` and `developerInstructions`; `handle(method:params:toolbox:stop:)`
  answers dynamic tool calls. `CodexSubscriptionClient`'s
  `ToolCallingChatProvider` extension runs the turn.
- **`CodexAppServer.arguments`** launches with `-c web_search="disabled"`.
- **CP0's Q3:** whether the thread setting overrides the launch argument
  with dynamic tools present, `configRequirements/read`'s shape, the
  `webSearch` item order and `results`, whether answers carry links, and
  what a disallowed mode returns. **Q5:** how `turn/interrupt` behaves
  after a held-back dynamic tool call.

## Tasks

### Task 4.1: The thread setting and the policy

**Interfaces:**

```swift
extension CodexToolMode {
  static func threadParameters(model: String, toolbox: any AgentToolbox,
                               providerSearch: ProviderSearch?, searchMode: String?) throws -> CodexValue
}
extension CodexSubscriptionClient {
  /// "live", or "cached" when only that is allowed; nil when neither is.
  static func webSearchMode(requirements: CodexValue?) -> String?
}
```

- [ ] **Write the failing tests** in `CodexSubscriptionTests`:
  - `testCodexSearchThreadParameters`: `config: {"web_search": <mode>}`
    beside `dynamicTools`; the developer instructions' tools line gains
    "and web search" and the spec §4 instruction follows.
  - `testCodexThreadWithoutSearchUnchanged`.
  - `testCodexSearchThreadLocation` (spec §2a): with `providerSearch.location`,
    `config` also holds `tools.web_search.location` (`{city, region,
    country, timezone}`, missing parts left out); without it, no location
    key. Confirm the key with one approved ChatGPT turn before relying on it
    (the 0.164.0 schema has `WebSearchToolConfig.location`).
  - `testCodexWebSearchModeFromRequirements`: live allowed, only cached,
    neither, and no requirements.
  - `testCodexNoAllowedModeIsUnavailable`: neither mode allowed throws
    `.webSearchUnavailable(.chatGPT)` before `turn/start`.
  - If CP0 found the thread setting doesn't override the launch argument:
    `testCodexLaunchSetting` for the option CP0 chose (spec §3).
- [ ] **Run, implement, run.**

### Task 4.2: Events, links and errors

- [ ] **Write the failing tests:**
  - `testCodexWebSearchEventsFromFixture` (`codex-web-search.jsonl`):
    `.phase(.searching)` on `item/started`; `openPage` URLs and `results`
    objects as discovered sources; `.sourcesSelected` from the answer's
    links before `.completed`.
  - `testCodexFailureAfterSearchKeepsSources`: a turn that fails after a
    search emits `.sourcesSelected` before the error, so the sources so far
    are saved (spec §6 step 5; CP1 Hand-off).
  - `testMalformedSearchResultsAreSkipped`: `results` entries without a
    string `url`, with `javascript:` URLs, or as plain strings are skipped.
  - `testCodexSearchAndDynamicToolTogether`
    (`codex-search-and-dynamic-tool.jsonl`): both run in one turn.
  - `testCodexThreadStartErrorIsUnavailable`, from CP0's error fixture or
    its recorded text.
  - `testCodexRestartDeliversNothing`: on `ProviderSearchRestart`, no
    dynamic tool response is sent and the turn is interrupted as CP0 Q5
    found.
- [ ] **Run, implement, run.**

### Task 4.3: The live check, and turning ChatGPT on

**Files:** create `EnigmaTests/NativeWebSearchLiveTests.swift` (test
target; register it as the workflow says); modify `CloudDomain.swift` and
`NativeWebSearchTests`.

```swift
final class NativeWebSearchLiveTests: XCTestCase {
  /// Skips unless ENIGMA_NATIVE_SEARCH_LIVE is set. Uses the Mac's ChatGPT sign-in.
  func testChatGPTSearchesLive() async throws
}
```

- [ ] **Write** `testChatGPTSearchesLive`: through `submitNative` on a real
  ChatGPT route, the Swift release question; at least one `.searching`
  phase, at least one selected source that passes `isSafeWebLink`, a
  non-empty answer.
- [ ] **Get the owner's approval** (one or two turns), run it, record it.
- [ ] **When it passes,** add `.chatGPT` to the set and update the test.

## Exit criteria

- The touched classes pass; `build` and `analyze` succeed; the full `test`
  once before the commit; CI passes.
- The live check passed, or `.chatGPT` stays off and the Hand-off says why.

## Reviewer checklist

- The turn keeps F32's read-only sandbox and declined approvals; a
  location in `config` only from `providerSearch.location` (spec §2a), never
  coordinates.
- A thread without provider search is unchanged, including the launch
  arguments unless CP0 required otherwise.
- Malformed results never become sources.

## Hand-off

*Filled in by the CP4 worker.*

1. **Summary:** A provider-search Codex turn now uses Codex's own web search
   beside F32's dynamic tools, and `.chatGPT` is in
   `nativeWebSearchProviders` after its live check passed. The changes:
   - before `thread/start`, the client reads `configRequirements/read`, and
     asks for `live` search, or `cached` when the workspace allows only that;
   - with neither allowed, it throws `.webSearchUnavailable(.chatGPT)`
     before the thread starts;
   - the thread's `config` holds `web_search` and, after the user's
     location grant, `tools.web_search.location`;
   - `webSearch` items become `.phase(.searching)` and discovered sources;
   - the answer's links become the selected sources, sent before
     `.completed` and before any error once a search has run;
   - errors that mention web search become unavailable: a `thread/start`
     error, or a failed turn before any text;
   - a held-back Messages result (`ProviderSearchRestart`) is never
     answered, and the turn is interrupted.
2. **Files:**
   - `Enigma/Cloud/CloudToolCalling.swift` (`CodexToolMode`):
     - `threadParameters(model:toolbox:providerSearch:searchMode:)`, with
       the new parameters defaulting to nil so F32's callers are unchanged;
     - `webSearchLocation(_:)`;
     - `Stop` records any error, including the restart, and gains
       `isRestart`;
     - `handle` records `.restart`.
   - `Enigma/Cloud/CodexSubscriptionClient.swift`:
     - `webSearchMode(requirements:)`, `webSearchSources(in:)` and
       `mentionsWebSearch(_:)`;
     - in the stream: the policy read, the unavailable mapping, the
       `webSearch` events, source selection, and a restart handler that
       never answers.
   - `Enigma/Cloud/CodexAppServer.swift` (`receiveServerRequest`): a call
     whose thread handler was removed (by Stop, or by a restart) is no
     longer answered.
   - `Enigma/Cloud/CloudDomain.swift`: `nativeWebSearchProviders = [.chatGPT]`.
   - `EnigmaTests/CodexSubscriptionTests.swift`:
     - 16 tests in a "Provider search (F30 CP4)" extension;
     - `SearchNoteToolbox`;
     - `SearchCodexTransport`, which replays fixtures and server requests
       and answers a call only while its handler is set. It is internal, so
       `NativeToolRequestTests` can use it;
     - `testAppServerDropsTheAnswerOfACallWhoseHandlerWasRemoved`, which
       checks the real `CodexAppServer` guard over a fake-process pipe
       (review round 1).
   - `EnigmaTests/NativeToolRequestTests.swift`:
     - `makeChat` gains `fileCodex:`;
     - `testTheShippedProviderSetSendsNoProviderSearch` becomes
       `testTheShippedProviderSetSearchesOnlyOnChatGPT`. A ChatGPT turn
       through `submitNative` now starts a thread with
       `config.web_search` set to "live", the search instruction, and no
       `web_search` function. The other four routes still get Enigma's
       `web_search`. This keeps what the test checked, pointed at the new
       set (review round 1).
   - `EnigmaTests/NativeWebSearchLiveTests.swift` (new, registered in the
     test target): `testChatGPTSearchesLive`.
   - `EnigmaTests/NativeWebSearchTests.swift`: `testNativeWebSearchProviders`
     now expects `[.chatGPT]`. It checks the same thing, pointed at the new
     set.
3. **Decisions:**
   - **The restart on Codex.** `handle` still returns the terminal result.
     The client's handler doesn't hand it back while a restart is recorded:
     it waits, for at most 60 s, until the stream's cleanup removes the
     handler, which cancels the call. `CodexAppServer` then skips the
     answer, because the handler is gone, and the cleanup sends
     `turn/interrupt`. This matches CP0 Q5's probe (unanswered call, then
     interrupt).
   - **Stop no longer answers.** The same `CodexAppServer` guard means a
     call still running when Stop removes the handler (Stop, a Messages
     stop's race, File Mode Stop) is no longer answered. Its turn is being
     interrupted, so the answer had no use.
   - **Developer instructions.** On a search thread the tools line reads
     "Use only the supplied tools and web search. You cannot run commands
     or read files." It drops "or browse", which would contradict web
     search. The spec §4 instruction comes earlier in the same string, from
     `ProviderSearchPart` in the toolbox's instructions, as CP1 left it.
   - **Policy.** No requirements, or `allowedWebSearchModes` null or
     absent, means `live`. A present list (even `[]`) is followed: `live`,
     else `cached`, else unavailable (CP0 Q3). `indexed` is never chosen.
     If `configRequirements/read` itself fails, the turn asks for `live`,
     and a refusal comes back as a `thread/start` error, which maps to
     unavailable.
   - **Unavailable after start.** A failed turn (`turn/completed` failed, or
     an `error` notification that won't retry) whose message mentions web
     search, before any text, is unavailable. After text it stays
     `CodexError.server`. `submitNative` already refuses to fall back once
     a tool call has run.
   - **Sources.**
     - Discovered sources come from `results[]` objects with a string `url`,
       plus `action.url` on `openPage` and `findInPage`. Each must pass
       `isSafeWebLink`, and a missing title becomes the site name.
     - An empty batch isn't emitted, but still counts as a search, so an
       answer's links become sources once Codex searched.
     - A reply that never searched sends no `.sourcesSelected`.
   - **Queries.** `action.query` and `action.queries` aren't read. Showing
     queries is out of scope (spec), and they're never logged.
4. **Verification:**
   - Red first: with signature stubs, the new tests failed (cached mode,
     sources kept after failure) or hung (no allowed mode).
   - Green, after review round 1, using class names:
     - CodexSubscriptionTests, NativeWebSearchLiveTests, CloudToolLoopTests
       (F32's Codex Messages-stop tests), ClaudeCodeToolModeTests,
       FileAgentTests, FileModeRuntimeTests, SubscriptionModelRefreshTests,
       NativeWebSearchTests, NativeToolRequestTests, MessagesRequestTests
       and RequestLifecycleTests: 302 executed, 6 skipped.
     - The only 2 failures in that run were the new guard test, from its own
       fake server's shell case order. After that fix,
       `CodexSubscriptionTests` passed: 58 executed, 1 skipped, 0 failed.
   - Mutation checks:
     - Removing the `CodexAppServer` guard, in a scratch copy, fails
       `testAppServerDropsTheAnswerOfACallWhoseHandlerWasRemoved` (the
       removed handler's call got answered).
     - Review round 1 also checked these, and the tests caught each one:
       the restart wait, `.restart` not being recorded, `isSafeWebLink`,
       the mode check, the mode without provider search, the
       streamed-text check, and `.sourcesSelected` on failure.
   - Review round 1 (Opus, xhigh): no Blocker. Four Should-fix findings, all
     about tests or this Hand-off, all fixed:
     - the real `CodexAppServer` guard was untested;
     - `testCodexNoAllowedModeIsUnavailable` hung on regression; it now
       completes the turn and fails;
     - the shipped-provider test's claim was wrong;
     - this record had a wrong class name and wrong counts.
     `testCodexMessagesStopStillAnswersAndInterrupts` is renamed
     `…StillInterruptsTheTurn`: since the guard, whether a Messages stop's
     answer is written is a race, and the test never checked it.
   - Review round 2 (Opus, xhigh): no Blocker. One small Should fix: this
     Hand-off now says that no turn with a location set has been seen to
     search, and flags it for CP6's in-app check. The worker fixed it
     without a third round (owner's rule).
   - `plutil -lint Enigma.xcodeproj/project.pbxproj`: OK.
   - **Live, run by the worker with the owner's approval (2026-10-29):**
     - The location-key probe: one Codex 0.164.0 turn, gpt-5.6-luna,
       `config.tools.web_search.location` set to Chicago, a public test
       city, with no area in the instructions. Codex accepted the key: its
       only "unrecognized setting" warning was F32's stale
       `tools.view_image`. The model asked for a city instead of
       searching, so whether the tool *uses* the location is unverified.
       In the app, the near-me clause also names the area.
     - `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 scripts/verify-xcode.sh test
       -only-testing:EnigmaTests/NativeWebSearchLiveTests`: passed in 6.4 s.
       Codex searched, 1 safe source was selected, and the answer had 208
       characters.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings in the changed files.
   - Full suite (`scripts/verify-xcode.sh test`, once, before the commit):
     1609 executed, 29 skipped, 0 failed.
5. **Limitations:**
   - No turn with `tools.web_search.location` set has been seen to search.
     Codex accepts the key, but whether search runs, and uses the location,
     on such a thread is unverified. The only passing live check had no
     location. A refused key would fail `thread/start` with a message about
     web search, which falls back cleanly.
   - The disallowed-mode and `thread/start` error texts are still
     unrecorded. Both mappings key off "web_search", "web search" or
     "websearch" in the message.
   - Nothing was checked in the running app (CP6's audit). The live test
     drives `submitNative` with the real Codex client, but not the UI.
6. **For the next checkpoint:**
   - `CodexToolMode.Stop` now takes any error. `isRestart` is how the Codex
     handler knows not to answer.
   - The `CodexAppServer` guard (no answer after the handler is removed)
     applies to every Codex tool and File Mode call.
   - `NativeWebSearchLiveTests.ask(_:route:providers:)` drives one flagged
     turn through `submitNative`, with automatic search on and no Brave key.
     CP5 adds `testClaudeCodeSearchesLive` with `[.claudeCode]`.
   - CP6's in-app check: on ChatGPT, after allowing location, a nearby
     question should show "Searching…" and sources (see Limitations).
   - `nativeWebSearchProviders` is now `[.chatGPT]`. Tests that build a
     `LocalChatViewModel` without passing the set now get provider search
     on ChatGPT routes.
