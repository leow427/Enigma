# CP1: Tool-loop budget

Read [agent-workflow.md](agent-workflow.md), the F35 entry, the plan, and
CP0's Hand-off.

## Goal

No turn fails because tool results filled the context. Before every step of
every tool loop Enigma drives, recount the request; when the next step won't
fit, shrink this turn's earlier tool results, then withdraw the tools and ask
the model to answer. Each `web_search` result is sized to the room left.

This is the "filled up immediately" fix, so it comes before the rest.

## Starting point

- `Enigma/Chat/AgentToolLoop.swift`:
  - `LocalToolAgent.prepare(_:model:toolbox:)` trims history once before the
    first step: a byte counts as a token, plus 32 per message; system prompt
    and tools reserved at about four bytes a token, + 64; output reserve
    1,024, or 2,048 with `/think`.
  - `LocalToolAgent.run` and `runStreaming` append each assistant call and
    its `role: "tool"` result to `history` for up to `maximumSteps` (12)
    with no recount. The tool result is JSON `{"success":…,"result":…}`.
- `Enigma/Cloud/CloudToolCalling.swift`: `CloudToolLoop.run(toolbox:emit:step:deliver:)`
  drives the OpenAI (`input += …`), Anthropic (`messages.append`) and Gemini
  (`contents`) loops; each `stream` prepares once with
  `CloudContext.prepare(request)` and appends results in `deliver` unchecked.
  `CloudToolLoop.maximumSteps = 12`.
- Codex (`CodexToolMode.handle`) and Claude Code (`ClaudeCodeToolMode.respond`)
  answer tool calls from inside the CLIs' own loops; Enigma never sees their
  history. Leave them alone except for result sizing (Task 1.4).
- `Enigma/Search/WebSearchTool.swift`: `WebSearchTool(search:mayQuery:onSources:)`;
  `execute` returns the results as JSON with title, URL and snippets.
- `LocalChatViewModel.nativeToolbox(plan:…evidenceTokens:…)` builds the
  toolbox with a fixed `evidenceTokens`: 2,048 local, `WebSearchLimits.evidenceTokens`
  (8,192) cloud; Brave results arrive already fitted, the on-device provider's
  go through `WebSearchExcerpts.fitted(_:maximumTokens:)`.
- `ProviderSearchPart` (a provider's own server-side search) returns results
  inside the provider; Enigma can't size them.
- The warm-up toolbox (`LocalChatViewModel`, the `warm` path) hard-codes
  `evidenceTokens: 2_048`; give it the same budget so the warmed tool prefix
  matches the real turn's.
- Tests: the tool loops are exercised in `EnigmaTests/MessagesToolCallingTests.swift`
  (`CloudToolLoopTests`, `MessagesRequestTests`, with `RecordingToolbox` and
  `StoppingToolbox`) and `LocalToolStreamingTests`; the provider stream
  assemblers in `CloudToolStreamingTests.swift` (classes
  `OpenAIToolStreamAssemblerTests`, `AnthropicToolStreamAssemblerTests`,
  `GeminiToolStreamAssemblerTests`, `CloudToolStreamPostTests`; there is no
  `CloudToolStreamingTests` class). `NativeToolRequestTests` asserts the
  search size equals `BraveSearchClient.evidenceTokens`; with plenty of room
  the first call still gets the 8,192 cap, so it should keep passing.

## Interfaces

**Produces** (`Enigma/Chat/ToolStepBudget.swift`):

```swift
/// Shared by one tool loop and the tools it runs, for one turn.
final class ToolStepBudget: Sendable {
  init()
  /// The loop records the request as it stands before each step.
  func measure(_ budget: ContextBudget, usedTokens: Int)
  /// A result returned to a CLI's own loop, or an earlier call of the same step.
  func add(_ tokens: Int)
  /// Tokens left for the next tool result and the model's next step; unlimited before a measurement.
  var roomLeft: Int { get }
  /// min(cap, roomLeft / 2), or nil when that is below 256 (the plan's smallest result).
  func evidenceTokens(cap: Int) -> Int?
  /// The usage of the request as it stands, for the ring (CP5); nil before a measurement.
  var usage: ContextUsage? { get }
  /// Before a step after tool results: proceed, or shrink earlier results, or answer without tools.
  func decide(usedTokens: Int, budget: ContextBudget, shrink: () -> Int) -> ToolStepDecision
}

enum ToolStepDecision: Equatable { case proceed, shrinkEarlierResults, answerWithoutTools }

// AgentToolbox
var stepBudget: ToolStepBudget? { get }   // default nil
```

The exact shape of `count` is the worker's choice: local loops count
`[AgentInferenceMessage]` with the same counter `prepare` uses, cloud loops
the provider's wire items with `ContextEstimate.tokens` of their JSON.
`ToolStepBudget` is passed to the toolbox through the existing
`nativeToolbox(…)` builder; `WebSearchTool` reads `evidenceTokens(cap:)`
per call instead of a fixed number.

## Tasks

### Task 1.1: The decision

**Files:** create `ToolStepBudget.swift` (+ `EnigmaTests/ToolStepBudgetTests.swift`).

- [ ] **Failing tests:** `testProceedsWhenNextStepFits`;
  `testShrinksWhenResultsOverflow`; `testAnswersWithoutToolsWhenShrinkingIsNotEnough`;
  `testThinkReserveCountsInStepBudget` (the 2,048 `/think` reserve decides
  the boundary); `testEvidenceTokensHalveRoomLeftAndRespectCap`;
  `testEvidenceTokensNilBelowSmallestResult`.

### Task 1.2: Shrinking earlier results

- [ ] **Failing tests:** `testShrinkKeepsTitleSiteAndURL` (each
  search source keeps title, site and URL; its excerpt text becomes
  `(excerpt removed to save space)`); `testShrinkLeavesNonSearchResultsAlone`
  (results of other tools are kept whole, so shrinking may not be enough);
  `testShrinkNeverTouchesTheCurrentStep`; `testShrinkIsIdempotent`.
- [ ] Implement one function used by every loop that rewrites the turn's
  earlier `web_search` result JSON in place.

### Task 1.3: Every loop Enigma drives

**Files:** `AgentToolLoop.swift` (`run`, `runStreaming`), `CloudToolCalling.swift`
(OpenAI, Anthropic, Gemini).

- [ ] **Failing tests** (local stub and recorded fixtures):
  - `testRepeatedSearchesShrinkThenAnswerLocal`: an 8,192-token local model
    calls `web_search` four times with 2,048-token results; the loop shrinks,
    then the last step is sent with no tools and the instruction from the
    plan's copy table; the turn ends with the model's answer, never an error.
  - The same for each API loop: `testRepeatedSearchesShrinkThenAnswerOpenAI`,
    `…Anthropic`, `…Gemini` (tools omitted from the request body; Anthropic
    keeps its thinking blocks valid).
  - `testWithdrawnToolsAreNotForcedRequired`: `requiredTool` is never sent on
    a step without tools.
  - `testStepLimitStillApplies`.
- [ ] Before each step: recount; decide; shrink or withdraw; then send.

### Task 1.4: Search results sized to the room left

**Files:** `WebSearchTool.swift`, `LocalChatViewModel.nativeToolbox`,
Codex and Claude Code tool handlers (sizing only).

- [ ] **Failing tests:** `testWebSearchUsesRoomLeft` (a second call gets a
  smaller result than the first); `testWebSearchWithNoRoomAnswersNoRoom`
  (the plan's "no room" text, success false, no search runs);
  `testCLIRoutesSizeResultsFromEstimate` (Codex and Claude Code: Enigma
  estimates the room from what it sent plus the results it has returned this
  turn, and sizes the next result from that).
- [ ] Keep today's 2,048 / 8,192 as caps, never as fixed sizes.

### Task 1.5: Docs

- [ ] `docs/Web-Search.md`: per-call evidence sizing. `docs/Chat.md` →
  "Native tool turns": the per-step budget, shrinking and the no-tools
  answer, and that provider search and the CLIs' own loops are outside it.

## Exit checks

- `ToolStepBudgetTests`, `LocalToolStreamingTests`, `CloudToolLoopTests`,
  `MessagesRequestTests`, the four classes in `CloudToolStreamingTests.swift`,
  `NativeToolRequestTests`, `WebSearchTests`, `CodexSubscriptionTests`,
  `ClaudeCodeSubscriptionTests` pass; full `build`, `test`, `analyze`.
- With the owner's approval, one live check on a local 8K model: a question
  that searches several times ends with an answer.

## Hand-off

1. **Summary:** every tool loop Enigma drives (local `run` and `runStreaming`,
   OpenAI, Anthropic, Gemini) now measures each step against the request's
   budget with a per-turn `ToolStepBudget`. After a tool result, when fewer
   than 512 tokens would be left, the turn's earlier `web_search` results
   shrink to title, site and URL; if that isn't enough, the step goes without
   tools and the system prompt asks the model to answer. Each `web_search`
   call is sized to half the room left (capped at 2,048 local, 8,192 cloud),
   and answers with the plan's "no room" text below 256 tokens. Codex and
   Claude Code size results from what Enigma sent plus the results returned.
2. **Files:**
   - `Enigma/Chat/ToolStepBudget.swift` (new): `ToolStepBudget`,
     `ToolStepDecision`, the copy strings, `shrunkSearchResult(_:)`.
   - `Enigma/Chat/AgentToolLoop.swift`: `AgentToolbox.stepBudget` (default
     nil); `LocalToolAgent.budget(_:model:toolbox:)` (split out of `prepare`),
     `usedTokens(_:)`, `prepareStep(...)`; both local loops measure, shrink
     and withdraw.
   - `Enigma/Chat/AssistantToolbox.swift`: a `stepBudget` property.
   - `Enigma/Cloud/CloudToolCalling.swift`: `CloudToolLoop.run` with
     `budget:count:shrink:` and `offersTools` (the old overloads forward);
     `systemPrompt(_:offersTools:)`, `estimatedTokens(_:)`, `SearchResults`;
     the three API loops; Codex's and Claude Code's tool handlers add each
     result to the budget.
   - `Enigma/Cloud/CodexSubscriptionClient.swift`,
     `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift`: `prompt(for:…)`
     measures the toolbox's budget.
   - `Enigma/Search/WebSearchTool.swift`: `name`, `noRoom`, an init with
     `evidenceCap:stepBudget:` whose search gets the per-call size; the old
     init stays (cap 8,192, no budget).
   - `Enigma/LocalInference/LocalChatViewModel.swift`: one `ToolStepBudget`
     per native turn through `nativeToolbox(…stepBudget:)`;
     `localEvidenceTokens` (2,048) shared with the warm-up toolbox.
   - `EnigmaTests/ToolStepBudgetTests.swift` (new),
     `EnigmaTests/MessagesToolCallingTests.swift` (new tests and stubs
     appended), `Enigma.xcodeproj/project.pbxproj` (two files).
   - `Enigma/Chat/ChatContext.swift`: `ChatContextPreparer.prepare(_:budget:reserving:countTokens:)`;
     `CloudContext.prepare` reserves room on tool turns.
   - `Enigma/Search/BraveSearchClient.swift`: `minimumTokens`.
   - `Enigma/Search/WebSearchContext.swift`: `WebSearchExcerpts.json(_:timeZone:maximumTokens:)`.
   - `EnigmaTests/NativeToolRequestTests.swift`: five new tests (one renamed in round 3) and a
     `BraveLikeProvider` double; `EnigmaTests/CloudSearchTestSupport.swift`:
     `ScriptedSearchProvider.Run` records the toolbox's `stepBudget`.
   - `docs/Chat.md` (Native tool turns), `docs/Web-Search.md` (per-call sizing),
     the plan's Interface map and this brief's Interfaces block.
3. **Decisions:**
   - **"The next step fits"** means at least 512 tokens left after the
     request: room for the smallest result (256) and the model's next step,
     the same line below which `web_search` answers "no room". `/think`'s
     2,048 output reserve is in the budget, so it moves the line.
   - **Step 0 is only measured,** never shrunk or withdrawn: history was
     trimmed to fit just before, and a required first search still runs.
   - **API loops keep the tools defined when withdrawing them,** with
     `tool_choice: "none"` (OpenAI), `{"type": "none"}` (Anthropic) and
     `functionCallingConfig.mode: "NONE"` (Gemini), instead of omitting
     `tools` as the brief says. Anthropic rejects `tool_use` / `tool_result`
     blocks in a request that defines no tools; keeping them defined is valid
     on all three, and thinking blocks go back unchanged. The local loop does
     omit them (`tools: []`). Their definitions stay counted, so a withdrawn
     API step may sit closer to the limit than a local one.
   - **The answer instruction is appended to the system prompt** of the
     withdrawn step (local system message, `instructions`, `system`,
     `systemInstruction`): one place that is valid on every provider.
   - **A tool call on a withdrawn step** ends the turn with today's step-limit
     error rather than running.
   - **`ToolStepBudget`'s shape:** `init()`, then `measure(_:usedTokens:)` by
     the loop (the view model creates it before the client knows the budget),
     `add(_:)` for CLI results, `decide(usedTokens:budget:shrink:)`. Before a
     measurement `roomLeft` is unlimited, so the cap applies. `usage` is
     optional (nil before a measurement).
   - **Local tool turns count with `ContextEstimate`** (owner, 2026-11-03,
     after review round 1), not the brief's byte a token: `prepare`, the
     overhead (system prompt and tools) and every step count
     `ceil(bytes / 3)`, + 8 a message, call names and arguments included.
     Search results are sized in real tokens, so a byte count made a
     2,048-token result count as about 10,000 and starved the second search.
     Plain local turns keep their exact tokenizer counts; the server checks
     a tool step's exact count before it answers, as before.
   - **Tool turns keep room for a result** (owner, same decision):
     `ChatContextPreparer.prepare(_:budget:reserving:countTokens:)` drops older
     turns first so 2,560 tokens (local: 2,048 + 512) or 8,704 (cloud:
     8,192 + 512) stay free, at most half the budget (review round 3: an
     unreviewed API model's default 8,192 window has about 3,100 tokens of
     input, so the full cloud reserve dropped all history on every tool turn).
     The result carries the real budget, so the loop
     measures against all of it; a current message too big for the reserve is
     sent alone with the whole budget (older turns would otherwise fill the
     room the results need). As each result gets half the
     room, the first search in a full chat gets at least 1,280 (local) or
     4,352 (cloud).
   - **Cloud counts** are `ContextEstimate.tokens` of each provider's wire items
     as JSON (`input`, `messages`, `contents`).
   - **A result's whole JSON fits its size** (review round 2): the size used to
     limit only the excerpt words, and each source's title, URL and other
     fields added 80–90 tokens on top. `WebSearchExcerpts.json(_:timeZone:maximumTokens:)`
     gives the excerpts the largest budget that fits beside the fields, found
     by binary search (review round 3: one cut by the overshoot filled only
     55–70% of the size), with 16 tokens kept for the loops' wrappers; it
     drops trailing sources when even the fields don't fit, and
     the call answers "no room" if not one source fits. Only the kept
     sources are reported.
   - **A step still over the budget after shrinking** shrinks the newest
     results too before going out without tools, rather than send a request
     measured as not fitting (`decide`'s `shrink` takes `includingNewest`).
   - **Calls in one step** (Anthropic and Gemini can make several) are sized
     one after another: each result is added to the budget before the next
     call runs.
   - **Brave** never returns fewer than 1,024 tokens
     (`BraveSearchClient.minimumTokens`); `WebSearchTool` fits whatever comes
     back, so the view model passes Brave's and the on-device results through.
   - **Typed `/messages` on a local route** trims its history with
     `LocalToolAgent.prepare` and shows the notice, as `submitNative` does
     (review round 3): with every step now measured, an untrimmed long chat
     lost its tools after the first call.
   - **Test helper:** an `extension QueuedTransport` exposes its stream builder
     to the new `SearchingTransport`; `QueuedTransport` itself is unchanged.
     No existing test was edited.
4. **Verification:**
   - New tests: `ToolStepBudgetTests` (19: the decisions, the reserves and
     their cap, the fallback, result sizing and fitting, the shrink, no room,
     CLI sizing); in `MessagesToolCallingTests`,
     `MessagesRequestTests.testRepeatedSearchesShrinkThenAnswerLocal`,
     `testShrinkNeverTouchesTheCurrentStep`, `testNoStepIsSentOverTheBudget`,
     `testThinkReserveCountsInLocalStepBudget`,
     `testWithdrawnToolsAreNotForcedRequiredLocal`,
     `testACallOnAWithdrawnStepEndsTheTurnUnrunLocal`,
     `testStepLimitStillAppliesWithRoomLeft`, `testWebSearchUsesRoomLeft`,
     `testLocalMessagesRequestTrimsALongChat`, and
     `CloudToolLoopTests.testRepeatedSearchesShrinkThenAnswer{OpenAI,Anthropic,Gemini}`,
     `testWithdrawnToolsAreNotForcedRequired`,
     `testACallOnAWithdrawnStepEndsTheTurnUnrun`,
     `testAPILoopsShareTheTurnsBudgetWithTheirTools`,
     `testParallelCallsAreSizedOneAfterAnother`, `testStepLimitStillApplies`;
     in `NativeToolRequestTests`, `testLocalTurnSizesEachSearchFromTheRoomLeft`,
     `testBraveResultsAreFittedToTheRoomLeft`, `testFirstSearchRunsWhenHistoryIsFull`,
     `testFallbackRunKeepsTheTurnsBudget`, `testLocationAnswerKeepsTheTurnsBudget`.
     Written before the code for the first pass; the review rounds' tests
     were checked by mutation (below) rather than watched failing.
   - Mutations, each caught: the view model's budget on both rebuilt
     toolboxes, Brave below its minimum (round 2), the `/think` reserve,
     the reserve itself; the reviewer's round 3 also broke the newest-result
     shrink, the current-step skip, the per-call `add` (API loop, Codex,
     Claude Code), the three providers' shrink positions and the
     current-message fallback, each caught. The four it found uncaught
     (the withdrawn-step guard, kept sources, the Brave branch, the wrapper
     allowance) are covered or removed.
   - Exit-check classes (`ToolStepBudgetTests`, `CloudToolLoopTests`,
     `MessagesRequestTests`, `ClaudeCodeToolModeTests`, `LocalToolStreamingTests`,
     `NativeToolRequestTests`, `NativeToolPartsTests`, `ChatContextTests`,
     `WebSearchTests`, `CodexSubscriptionTests`, `ClaudeCodeSubscriptionTests`
     and the four classes in `CloudToolStreamingTests.swift`): 475 executed,
     1 skipped, 0 failed.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings. Full `test`: 2,252 executed, 42 skipped, 8 failures in 4
     tests. `BugReportTests.testFailedSendOffersEmailAndASentReportCantBeSentTwice`
     and `ClaudeCodeSubscriptionTests.testClaudeCodeRestartDeliversNothing`
     pass run again; the two `AppCommandTests` window-layout tests fail as
     in CP0 (on `main` too, this Mac's screen layout). CI's result is
     reported after the push.
   - Review: three rounds (Opus, xhigh). Round 1: one Blocker, the byte-a-token
     counter starved the second search (owner: estimate + reserve), and five
     Should fixes (wiring untested, `/think` reserve unpinned, Brave below
     1,024, parallel calls in one step, stale Interface map). Round 2: three
     Should fixes (results over their size, the fallback refilling the
     reserve, reserves and rebuilt toolboxes untested). Round 3: four Should
     fixes (the reserve on small windows, typed `/messages` untrimmed,
     results under-filled, four behaviours untested). All fixed.
   - Not run: the live 8K local check (waits for the owner's approval).
5. **Limitations:**
   - The API "none" tool choices and the withdrawn-step requests are tested
     from fixtures only (no API keys); not checked against the live APIs.
   - Withdrawing tools on a local step changes the rendered prompt's tool
     section, so the server reads the whole prompt again for that last step.
   - The estimate isn't conservative for digit-heavy or CJK text (CP0's
     limitation), so a local tool step near the limit can still be refused by
     the server's exact count.
   - Codex and Claude Code: only result sizing. Their own loops still grow
     unchecked inside the CLI, and the estimate leaves out the model's
     arguments and text between calls.
6. **For the next checkpoint:**
   - `ToolStepBudget.usage` is optional (nil before the loop's first
     measurement); CP5's brief reads it as if it weren't. The
     view model's per-turn budget is created in `submitNative` as
     `stepBudget` and reaches the loops through `toolbox.stepBudget`.
   - `LocalToolAgent.budget(_:model:toolbox:)` is the local tool budget.
