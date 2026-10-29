# CP5: Claude Code — WebSearch beside the MCP tools

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "Claude Code", §4,
§5), and the Hand-offs of [CP0](cp0-spike.md#hand-off) to
[CP4](cp4-chatgpt-codex.md#hand-off).

## Goal

A provider-search Claude Code request runs with `WebSearch` beside F32's MCP
tools, stops and falls back when a policy withholds it, reports its searches
and results, and takes its cited sources from the answer's links. When the
owner's live check passes, `.claudeCode` joins the provider set.

## Starting point

- **`ClaudeCodeSubscriptionClient`** (`ClaudeCodeSubscriptionClient.swift`)
  builds F32's tool-mode arguments: `--safe-mode`, `--tools ""`,
  `--strict-mcp-config`, `--mcp-config` with the SDK server,
  `--disable-slash-commands`, `--allowedTools` of the `mcp__…` names, and
  the system prompt from `ClaudeCodeToolMode.systemPrompt(toolbox)`.
- **`ClaudeCodeToolMode`** (`CloudToolCalling.swift`) answers MCP messages;
  its `stream` extension runs the process and maps control requests.
- **`ClaudeCodeStreamParser`** parses `stream-json`.
- **CP0's Q4:** the `init` tools list with `WebSearch` and MCP tools, the
  search events, any "Sources:" list, and plain-string results. **Q5:**
  ending the process after a held-back `tools/call`.

## Tasks

### Task 5.1: Arguments and the system prompt

- [ ] **Write the failing tests** in `ClaudeCodeSubscriptionTests`:
  - `testClaudeCodeSearchArguments`: with `providerSearch`, `--tools
    WebSearch` replaces `--tools ""`, and `--allowedTools` lists
    `WebSearch` plus the MCP names; `--safe-mode`, `--strict-mcp-config`,
    `--disable-slash-commands`, the empty workspace and the stripped
    environment are unchanged; `WebFetch` appears nowhere.
  - `testClaudeCodeArgumentsWithoutSearchUnchanged`.
  - `testClaudeCodeSearchSystemPrompt`: the tools line gains "and
    WebSearch"; the spec §4 instruction follows. If CP0 found answers add
    their own "Sources:" list, the instruction asks for linked pages only,
    as CP0 recommends.
  - `testClaudeCodeSearchSystemPromptWithLocation` (spec §2a): Claude Code
    has no location field, so with `providerSearch.location` the near-me
    clause names the area in the system prompt; without it, the "ask which
    city" clause. Nowhere else in the arguments.
- [ ] **Run, implement, run.**

### Task 5.2: Parser events and the `init` check

**Interfaces:** `ClaudeCodeStreamParser.Event` gains
`.toolsListed([String])`, `.searchStarted` and
`.searchResults([WebSearchSource])` (spec §3).

- [ ] **Write the failing tests:**
  - `testParserSearchEventsFromFixture` (`claude-code-web-search.jsonl`).
  - `testParserSkipsMalformedSearchResults`: plain strings, entries without
    `content`, unsafe URLs.
  - `testInitWithoutWebSearchIsUnavailable`
    (`claude-code-init-without-websearch.jsonl`): the process stops and
    `.webSearchUnavailable(.claudeCode)` is thrown before any text.
  - `testClaudeCodeSourcesFromAnswerLinks`.
  - `testClaudeCodeRestartDeliversNothing`: on `ProviderSearchRestart`, no
    MCP response is written and the process ends as CP0 Q5 found.
  - `testClaudeCodeFailureAfterSearchKeepsSources`: a turn that fails after
    a search emits `.sourcesSelected` before the error (spec §6 step 5;
    CP1 Hand-off).
- [ ] **Run, implement, run.**

### Task 5.3: The live check, and turning Claude Code on

- [ ] **Add** `testClaudeCodeSearchesLive` to `NativeWebSearchLiveTests`
  (CP4): the multi-search question
  through the Mac's Claude sign-in; a search, two sources, an answer.
- [ ] **Get the owner's approval,** run it, record it.
- [ ] **When it passes,** add `.claudeCode` to the set and update the test.

## Exit criteria

- The touched classes pass; `build` and `analyze` succeed; the full `test`
  once before the commit; CI passes.
- The live check passed, or `.claudeCode` stays off and the Hand-off says
  why.

## Reviewer checklist

- `WebFetch` can't be enabled by any path; mutation: add it, and a test
  fails.
- Every other argument F32 relies on is unchanged.
- The `init` check runs before any text reaches the reply.

## Hand-off

*Filled in by the CP5 worker.*

1. **Summary:** A provider-search Claude Code request now runs with
   `WebSearch` beside F32's MCP tools, and `.claudeCode` is in
   `nativeWebSearchProviders` after its live check passed. The changes:
   - `--tools WebSearch` replaces `--tools ""`, and `WebSearch` leads
     `--allowedTools`; every other argument is unchanged, and `WebFetch`
     appears nowhere;
   - the system prompt's tools line gains "and WebSearch"; the spec §4
     instruction, with its near-me clause, comes from the toolbox as CP1
     left it;
   - the parser reports `init`'s tools, each `WebSearch` call and its
     results;
   - an `init` without `WebSearch` stops the process and throws
     `.webSearchUnavailable(.claudeCode)` before any text reaches the reply;
   - the answer's links become the selected sources, sent before
     `.completed` and before any error once a search has run;
   - a held-back Messages result (`ProviderSearchRestart`) is never
     answered, and the process ends (F32's terminal path, unchanged).
2. **Files:**
   - `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift`:
     - `ClaudeCodeRuntime.toolArguments(model:effort:toolbox:providerSearch:)`,
       the new parameter defaulting to nil so F32's callers are unchanged;
     - `ClaudeCodeStreamParser.Event` gains `.toolsListed`, `.searchStarted`
       and `.searchResults`; the parser remembers `WebSearch` tool-use IDs,
       so only their results become sources;
     - `ClaudeCodeStreamParser.searchSources(in:)`;
     - the plain chat stream ignores the new events.
   - `Enigma/Cloud/CloudToolCalling.swift` (`ClaudeCodeToolMode` and the
     tool-mode stream): `webSearch`, `systemPrompt(_:providerSearch:)`, and
     in the stream the `init` check, held text, search events and source
     selection.
   - `Enigma/Cloud/CloudDomain.swift`: `nativeWebSearchProviders = [.chatGPT, .claudeCode]`.
   - `EnigmaTests/ClaudeCodeSubscriptionTests.swift`: the brief's 10 tests in
     a "Provider search (F30 CP5)" extension, `searchRequest()`, and
     `RestartingToolbox`.
   - `EnigmaTests/NativeWebSearchLiveTests.swift`:
     `testClaudeCodeSearchesLive` and `multiSearchQuestion`.
   - `EnigmaTests/NativeWebSearchTests.swift`: `testNativeWebSearchProviders`
     now expects `[.chatGPT, .claudeCode]`. It checks the same thing,
     pointed at the new set.
   - `EnigmaTests/NativeToolRequestTests.swift`:
     `testTheShippedProviderSetSearchesOnlyOnChatGPT` becomes
     `testTheShippedProviderSetSearchesOnChatGPTAndClaudeCode`. The Claude
     Code route now gets `providerSearch`, the search instruction and no
     `web_search` function; the OpenAI, Anthropic and Gemini routes still get
     Enigma's `web_search`. It keeps what the test checked, pointed at the
     new set.
3. **Decisions:**
   - **"Sources:" lists.** CP0 found 5 of 6 answers end with their own
     "Sources:" list, and decided the list stays in the reply and the
     answer's links are the citations. CP0 recommended no wording change, so
     the instruction stays spec §4's ("Link the pages you rely on."), with
     nothing added. The selection dedupes the list's repeats of inline links.
   - **Tools line.** On a search request it reads "Use only the Enigma tools
     and WebSearch. You cannot read local files or run commands." It drops
     "or browse", which would contradict web search, as CP4 did for Codex.
   - **The `init` check.** `init` comes first in the CLI's stream-json
     output, after the MCP handshake. Even so, text that arrives before it on
     a provider-search request is held, and released only once `init` lists
     `WebSearch` (or at the result, if no `init` with a tools list ever
     came). An `init` without a `tools` array isn't treated as a check, so
     F32's plain-chat parser test is unchanged.
   - **Search results.** Only `user` messages answering a recorded
     `WebSearch` tool-use ID count. Their `tool_use_result.results[]`
     objects' `content[]` `{title, url}` entries become sources; strings,
     entries without a `content` list, non-string URLs and unsafe links are
     skipped; a numeric or missing title becomes the site name. A failed
     search (a bare string) gives `.searchResults([])`: no
     `.sourcesDiscovered`, but it still counts as a search, so the answer's
     links become sources (as CP4 does for Codex's empty batches).
   - **No other unavailable mapping.** The spec names only the `init` check
     for Claude Code. A failed result after `init` stays
     `ClaudeCodeError.server`.
   - **Permission requests** (`can_use_tool`) are still denied. `WebSearch`
     is in `--allowedTools`, so the CLI doesn't ask: CP0's probes and the
     live check searched without one being answered.
4. **Verification:**
   - I wrote the tests before the code but ran them only after, so red
     wasn't observed. Instead, each key assertion was mutation-checked in a
     scratch copy (`rsync -a --exclude .git`), one mutation at a time, and
     each made its test fail:
     - no `init` check → `testInitWithoutWebSearchIsUnavailable`;
     - `WebFetch` added to the tools → `testClaudeCodeSearchArguments`;
     - text not held before `init` → `testInitWithoutWebSearchIsUnavailable`;
     - no `.sourcesSelected` before an error → `testClaudeCodeFailureAfterSearchKeepsSources`;
     - no `isSafeWebLink` check → `testParserSkipsMalformedSearchResults`;
     - the restart answered instead of thrown → `testClaudeCodeRestartDeliversNothing`;
     - any tool's result taken as search results → `testParserSkipsMalformedSearchResults`.
   - The affected classes (ClaudeCodeSubscriptionTests,
     ClaudeCodeToolModeTests, NativeWebSearchTests, NativeToolRequestTests,
     NativeToolPlanTests, NativeToolPartsTests, MessagesRequestTests,
     MessagesToolsTests, RequestLifecycleTests, CloudToolLoopTests,
     CodexSubscriptionTests, NativeWebSearchLiveTests, NativeToolsEvalTests,
     WebSearchTests, ToolPermissionTests): 408 executed, 4 skipped,
     0 failed.
   - **Live, run by the worker with the owner's approval (2026-10-29,
     sonnet):** `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 scripts/verify-xcode.sh test
     -only-testing:EnigmaTests/NativeWebSearchLiveTests/testClaudeCodeSearchesLive`
     passed in 34.5 s: Claude Code searched, 6 safe sources were selected,
     and the answer had 1,897 characters.
   - Review round 1 (Opus, xhigh): no Blocker, no product-code bug. Two
     Should-fix findings, both test gaps, both fixed:
     - the parser's `WebSearch` name filter was untested:
       `testParserSkipsMalformedSearchResults` now includes an Enigma
       tool's call with a search-shaped result;
     - two stream decisions were untested: a failed search still counting
       as a search (`testClaudeCodeFailedSearchStillSelectsAnswerLinks`),
       and held text released at the result when `init` has no tools list
       (`testClaudeCodeTextWithoutInitToolsIsReleasedAtTheResult`).
     Each new test was seen failing against the reviewer's surviving
     mutation (the name filter relaxed; an empty batch not counted; no
     release at the result), and passing without it:
     `ClaudeCodeSubscriptionTests` 37 executed, 0 failed.
   - Review round 2 (Opus, xhigh): no Blocker and no Should fix; 229
     tests in the affected classes passed in its scratch copy, and its
     mutations were caught or hit unreachable paths.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings in the changed files. `plutil -lint`: OK (project file
     unchanged).
   - Full suite (`scripts/verify-xcode.sh test`, once, before the commit):
     1622 executed, 30 skipped, 0 failed.
5. **Limitations:**
   - Nothing was checked in the running app (CP6's audit). The live test
     drives `submitNative` with the real Claude Code client, but not the UI.
   - The `init`-without-`WebSearch` case is derived from a recording, not
     seen live: no policy that withholds `WebSearch` was available to test.
   - Location on Claude Code goes only through the system prompt's near-me
     clause (spec §2a). Whether `WebSearch` uses it for nearby results is
     unverified; CP6's in-app check covers it.
6. **For the next checkpoint:**
   - `nativeWebSearchProviders` is now `[.chatGPT, .claudeCode]`. Tests
     that build a `LocalChatViewModel` without passing the set now get
     provider search on Claude Code routes too.
   - `NativeWebSearchLiveTests` has `testChatGPTSearchesLive` and
     `testClaudeCodeSearchesLive` (model from `ENIGMA_CLAUDE_CODE_MODEL`,
     default `sonnet`).
   - The Claude Code model sometimes picks its own `allowed_domains`, which
     can fail a search (CP0 Q4); the answer still comes, from the other
     searches. That matters for F29's blocked sites.
