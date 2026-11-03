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
  init(budget: ContextBudget, count: @escaping @Sendable (_ requestSoFar: …) -> Int)
  /// Tokens left for the next tool result and the model's next step.
  var roomLeft: Int { get }
  /// min(cap, roomLeft / 2), or nil when that is below 256 (the plan's smallest result).
  func evidenceTokens(cap: Int) -> Int?
  /// The usage of the request as it stands, for the ring (CP5).
  var usage: ContextUsage { get }
}

enum ToolStepDecision: Equatable { case proceed, shrinkEarlierResults, answerWithoutTools }
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

_To be filled in by the CP1 worker._
