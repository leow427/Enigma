# CP0: Counting and cloud budgets

Read [agent-workflow.md](agent-workflow.md), the F35 entry in `to-do.md`, and
the plan.

## Goal

One way to measure how full a request is, used everywhere from here on, and
cloud budgets that use far more of each model's window: a realistic token
estimate, the 65,536 latency cap, and protocol reserves checked against what
the CLIs really add. No compaction and no UI yet.

## Starting point

- Worktree: create it (agent-workflow, Roles) on `feat/f35-context` from
  `main`.
- `Enigma/Chat/ChatContext.swift`:
  - `ContextBudget(contextWindow:outputTokens:overheadTokens:inputLimit:)`,
    `availableInputTokens = max(0, min(inputLimit, window − output − overhead))`.
  - `ModelContextPolicy.cloud(provider:modelID:)`: every branch has
    `inputLimit: 32_768`; reserves 8,192 (ChatGPT), 16,384 (Claude Code),
    512 (others); `localContextWindow = 4_096`.
  - `ChatContextPreparer.prepare` / `prepareAsync`: current message plus
    complete turns, newest first; `PreparedConversation(messages:inputTokenCount:omittedMessageCount:budget:)`
    and its `notice`.
  - `CloudContext.inputTokenCount` counts one UTF-8 byte as one token of
    `encodedMessages` (API routes) or `codexPrompt` (ChatGPT and Claude
    Code); `CloudContext.prepare` adds 4,096 for an image.
- Callers of `CloudContext.prepare`: `CloudProviderClients.swift` (OpenAI
  and Anthropic), `GeminiContentClient.swift`, `CodexSubscriptionClient.swift`
  (twice), `ClaudeCodeSubscriptionClient.swift`, `CloudToolCalling.swift`
  (three loops), `LocalChatViewModel` (several send paths that also set
  `contextNotice`), and `AutoRouter` (`.exceedsLocalContext`, through
  `ChatContextPreparer.prepare` with `CloudContext.inputTokenCount`).
- The system prompt and tool definitions are not counted on cloud routes
  today; the 512 / 8,192 / 16,384 reserves stand in for them.
- Tests pinned to today's values: `ClaudeCodeSubscriptionTests` (asserts
  `availableInputTokens == 32_768` twice), `CodexSubscriptionTests`
  (`contextWindow == 32_768` for an unlisted model; keeps passing),
  `ChatContextTests`, `CloudModelSelectionTests`, `WebSearchTests`,
  `NativeToolRequestTests`. Only the first is expected to change.
- `docs/Chat.md` → "Context budgets" documents today's table.

## Interfaces

**Produces** (in `Enigma/Chat/ChatContext.swift`):

```swift
struct ContextBudget {
  // existing fields, plus:
  /// Enigma's own system prompt and tool definitions for this request, counted as used.
  var promptTokens: Int = 0
  // availableInputTokens now also subtracts promptTokens.
}

enum ContextEstimate {
  /// ceil(bytes / 3) of `text`.
  static func tokens(_ text: String) -> Int
  /// The cloud request's messages as the client serializes them (roles, JSON escaping),
  /// using the same serialization `inputTokenCount` used before.
  static func cloudTokens(_ messages: [ChatMessage], provider: CloudProviderID) throws -> Int
}

struct ContextUsage: Equatable, Sendable {
  enum Level: Equatable, Sendable { case normal, high, full }   // green, yellow, red
  static let highFraction = 0.70
  static let fullFraction = 0.90
  let usedTokens: Int      // inputTokenCount + budget.promptTokens
  let limitTokens: Int     // budget.availableInputTokens + budget.promptTokens
  var fraction: Double     // usedTokens / limitTokens, clamped to 0...1; 1 when limit is 0
  var level: Level         // normal < 0.70 ≤ high < 0.90 ≤ full
  var percentLeft: Int     // floor((1 − fraction) × 100), never below 0
}

extension PreparedConversation {
  var usage: ContextUsage { get }
}
```

`CloudContext.inputTokenCount(_:provider:)` keeps its signature and now
returns `ContextEstimate.cloudTokens`. `ModelContextPolicy.cloud` gains a
`promptTokens:` parameter (default 0) that callers fill with the estimated
system prompt and tool definitions they send.

## Tasks

### Task 0.1: The estimate and the usage

**Files:** `Enigma/Chat/ChatContext.swift`; tests in `ChatContextTests`.

- [ ] **Write failing tests:**
  - `testEstimateIsCeilingOfBytesOverThree`: "", "a", "abc", "abcd", a
    multi-byte string (counts UTF-8 bytes).
  - `testCloudEstimateCountsRoleWrappersAndEscaping`: a message with quotes
    and newlines counts more than its plain text.
  - `testEstimateStaysAboveRealTokenizerForSamples`: a small set of fixed
    English, code and JSON samples whose real token counts (from a published
    tokenizer, recorded in the test with the source named) are all ≤ the
    estimate. Keeps the estimate conservative.
  - `testUsageFractionLevelsAndPercentLeft`: 0, 0.699…, 0.70, 0.899…, 0.90,
    1.0 and over 1 (clamped); `percentLeft` rounds down (28.6% left → 28).
  - `testPromptTokensCountAsUsedAndReduceRoom`.
  - `testZeroLimitIsFull`.
- [ ] Run them, watch them fail, implement, watch them pass.

### Task 0.2: Raised cloud caps

**Files:** `ChatContext.swift`, the cloud clients that call
`CloudContext.prepare`, `AutoRouter.swift`; tests in `ChatContextTests`,
`CloudModelSelectionTests`, `ClaudeCodeSubscriptionTests`.

- [ ] **Write failing tests:**
  - `testCloudInputCapIsLatencyCap`: a listed model with a 1M window gets
    `availableInputTokens == 65_536 − promptTokens`.
  - `testCloudCapNeverExceedsWindowMinusReserves`: an unlisted model (8,192
    window) keeps `window − output − overhead − promptTokens`.
  - `testCloudPrepareCountsSystemPromptAndTools`: preparing a request whose
    client sends a system prompt and tools reports them in `usage.usedTokens`.
  - `testLongChatKeepsMoreTurnsThanBefore`: a chat of 40 turns of ~2 KB each
    that the old count cut to ~15 turns now keeps all of them.
  - Update `ClaudeCodeSubscriptionTests`' two `32_768` assertions to the new
    cap (named edit; list it in the Hand-off).
- [ ] Implement: `inputLimit: 65_536` on every cloud branch;
  `CloudContext.prepare` and each client pass the system prompt and tool
  definitions they send as `promptTokens`, so the reserves only cover what
  Enigma can't see.

### Task 0.3: Recheck the CLI reserves

The ChatGPT (8,192) and Claude Code (16,384) reserves stand for text the
CLIs add that Enigma never sees.

- [ ] **From the docs first:** read what each CLI adds (Codex app-server's
  base instructions and tool schemas; Claude Code's system prompt with
  Enigma's replacement prompt and its MCP tool list) and estimate it.
- [ ] **Then, with the owner's approval (about 4 calls),** measure: send a
  one-word message on each route with Enigma's real settings and read the
  input-token count each CLI reports (Codex's token-usage notification,
  Claude Code's `usage.input_tokens` in its result). Reserve = reported
  input − Enigma's own estimate of what it sent, rounded up to the next
  1,024, plus 25%. Do it with and without a toolbox.
- [ ] Set the reserves to the measured values (or keep today's if the owner
  declines the runs), add `testCLIReservesMatchMeasurement` pinning them, and
  record the numbers and method in the Hand-off.

### Task 0.4: Docs

- [ ] `docs/Chat.md` → "Context budgets": the estimate, the 65,536 cap and
  why (latency), the new reserves, and that system prompt and tools now
  count. Keep the rest for later checkpoints.
- [ ] `docs/Cloud-Model-Selection.md` if it quotes the old cap.

## Exit checks

- `ChatContextTests`, `CloudModelSelectionTests`, `ClaudeCodeSubscriptionTests`,
  `CodexSubscriptionTests`, `WebSearchTests`, `NativeToolRequestTests`,
  `AutoRouterTests` (if present) pass.
- Full `build`, `test`, `analyze`.
- Draft PR open with Auto-fix on (owner approved).

## Hand-off

1. **Summary:** cloud requests are now counted with `ContextEstimate`
   (`ceil(bytes / 3)` of the serialized messages) instead of one token a byte.
   `ContextBudget.promptTokens` counts Enigma's own system prompt and tool
   definitions as used; `CloudContext.prepare(_:toolbox:)` fills it for every
   cloud route. `ContextUsage` and `PreparedConversation.usage` give the share
   of the budget a request fills. Every cloud route's input cap is 65,536. The
   CLI reserves were measured live and lowered: ChatGPT 3,840 (was 8,192),
   Claude Code 1,280 (was 16,384).
2. **Files:**
   - `Enigma/Chat/ChatContext.swift`: `promptTokens`, `ContextEstimate`,
     `ContextUsage`, `PreparedConversation.usage`, `cloudInputLimit`,
     `codexReserve`, `claudeCodeReserve`, `CloudContext.promptTokens`
     (by route and toolbox, and `fileMode:` for Codex File Mode),
     `CloudContext.prepare(_:toolbox:fileMode:)`.
   - `Enigma/Chat/AutoRouter.swift`: the `.exceedsLocalContext` cloud check
     counts the plain system prompt.
   - `Enigma/Cloud/CloudToolCalling.swift`: the three API tool loops and
     Claude Code's tool mode pass their toolbox.
   - `Enigma/Cloud/CodexSubscriptionClient.swift`: `prompt` and `input` take
     an optional `toolbox` and File Mode selection; `turnParameters` takes a
     `toolbox` and passes its `workspace` as the File Mode selection.
   - `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift`: `prompt(for:toolbox:)`.
   - `Enigma/LocalInference/LocalChatViewModel.swift`: the native-tool cloud
     preparation passes its toolbox, so its notice matches the client's.
   - `EnigmaTests/ChatContextTests.swift`: new tests (below), two edited, and
     the shared test helpers `SampleToolbox` and `longChat()`.
   - `EnigmaTests/MessagesToolCallingTests.swift`, `EnigmaTests/AutoRouterTests.swift`:
     one new test each.
   - `EnigmaTests/ClaudeCodeSubscriptionTests.swift`,
     `EnigmaTests/CloudModelSelectionTests.swift`, `EnigmaTests/CloudModeTests.swift`,
     `EnigmaTests/LocalInferenceTests.swift`: edited (below).
   - `EnigmaTests/NativeToolRequestTests.swift`: one new test; the test
     double `NativeToolProvider` records whether the real clients'
     preparation keeps every message it was sent.
   - `docs/Chat.md`, `docs/Cloud-Model-Selection.md`, `docs/ChatGPT-Setup.md`,
     `docs/Claude-Code-Setup.md`: the new estimate, cap and reserves.
3. **Decisions:**
   - **Prompt tokens are worked out centrally,** not passed by each client:
     `CloudContext.promptTokens(provider:toolbox:)` picks the system text the
     route's client sends (and the tool definitions' JSON), and `prepare`
     takes the `toolbox`. The view model prepares the same request before the
     client does; computing the prompt in one place keeps both preparations,
     and so the notice and later the ring, in agreement. `ModelContextPolicy.cloud`
     still has the brief's `promptTokens:` parameter (default 0).
   - **Codex and Claude Code share Claude Code's prompt texts** for the count:
     each contains every line of Codex's equivalent, so it bounds both.
   - **Codex File Mode** counts what its thread really sends: the File Mode
     instructions, the attached selection's context and the ten file tools
     (`CloudContext.promptTokens(fileMode:)`, read from
     `CodexFileMode.threadParameters`). Added after review round 2.
   - **Edited existing tests** (the estimate change breaks any test pinned to
     one token a byte): `ClaudeCodeSubscriptionTests.testClaudeCodeBudgetLeavesRoomForReplies`
     (32,768 → 65,536 and 65,536 − 8,192 − 1,280, the named edit);
     `ChatContextTests.testEveryCloudRouteBoundsEscapedUnicodeAndManualModels`
     (an oversized message is now `3 × limit + 1` bytes);
     `ChatContextTests.testCloudSerializedInputJustUnderAtAndOverBudget` and
     `CloudModelSelectionTests.testReviewedModelsUseSharedContextLimitsAtRequestBoundaries`
     (boundaries in bytes ÷ 3, after the system prompt). Each still checks
     just under, at and just over the limit.
     `CloudModeTests.testCloudTrimmingPreservesStoredTranscriptForEveryProvider`
     (old turn `"old" × 20_000` → `× 70_000`) and
     `LocalInferenceTests.testContextRejectionPreservesDraftAndDoesNotPersistOrGenerate`
     (draft of 40,000 → 200,000 characters): their "too big" fixtures now fit
     the larger budgets, so they are made larger than every route's cap. Each
     tests the same thing as before.
   - **The estimate stays `ceil(bytes / 3)`:** owner's decision, 2026-11-03,
     after review round 1 raised the digit-heavy undercount (the plan's stop
     rule).
   - **Reserve method:** reported input − Enigma's estimate of what it sent,
     larger of the with/without-toolbox runs, rounded up to the next 1,024,
     plus 25%.
4. **Verification:**
   - New tests: `testEstimateIsCeilingOfBytesOverThree`,
     `testCloudEstimateCountsRoleWrappersAndEscaping`,
     `testEstimateStaysAboveRealTokenizerForSamples`,
     `testUsageFractionLevelsAndPercentLeft`,
     `testPromptTokensCountAsUsedAndReduceRoom`, `testZeroLimitIsFull`,
     `testCloudInputCapIsLatencyCap`, `testCloudCapNeverExceedsWindowMinusReserves`,
     `testCloudPrepareCountsSystemPromptAndTools`,
     `testLongChatKeepsMoreTurnsThanBefore`, `testCLIReservesMatchMeasurement`,
     `testPromptTokensCoverWhatEachClientSends`, `testCodexTurnIsBoundedWithItsToolbox`,
     `testCodexFileModeCountsItsInstructionsAndTools` (`ChatContextTests`),
     `NativeToolRequestTests.testNearLimitCloudTurnIsPreparedAsTheClientPreparesIt`,
     `CloudToolLoopTests.testAPIToolLoopsTrimHistoryWithTheirToolbox`,
     `ClaudeCodeSubscriptionTests.testToolModeSendsHistoryTrimmedWithItsToolbox`
     (a fake `claude` that records its standard input) and
     `AutoRouterTests.testCloudContextCheckCountsTheSystemPrompt`.
     Mutations checked after review round 1: dropping `toolbox:` from the view
     model's cloud preparation, from Codex's `turnParameters` input, and
     counting the API prompt for Codex/Claude Code each fail a test. After
     round 2: dropping `toolbox:` from the OpenAI tool loop and from Claude
     Code's tool mode, dropping the File Mode selection from Codex's turn, and
     a zero prompt in AutoRouter's check each fail a test.
     The code was written before these tests, not strictly test-first; the
     reviewer's mutation checks stand in for watching them fail.
   - Tokenizer samples: counted with OpenAI's `tiktoken` 0.12 (`o200k_base`
     and `cl100k_base`) in a scratch environment.
   - Live runs (owner approved, 4 calls, 2026-11-03), a one-word message with
     Enigma's arguments and prompts, driven from a scratch script:
     | Route | Reported input | Enigma's estimate | Difference |
     | --- | ---: | ---: | ---: |
     | Codex 0.164.0, gpt-5.6-luna, no tools | 3,341 | 486 | 2,855 |
     | Codex, a one-tool toolbox | 3,196 | 494 | 2,702 |
     | Claude Code 2.1.312, sonnet, no tools | 1,325 | 489 | 836 |
     | Claude Code, a one-tool MCP server | 1,328 | 561 | 767 |
   - Exit-check classes (`ChatContextTests`, `CloudModelSelectionTests`,
     `ClaudeCodeSubscriptionTests`, `CodexSubscriptionTests`, `WebSearchTests`,
     `NativeToolRequestTests`, `AutoRouterTests`) plus `CloudModeTests` and
     `LocalInferenceTests`: all pass.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings.
   - Full `test`: 2,211 executed, 42 skipped, 6 failed. The 6 failures are
     in two `AppCommandTests` window-layout tests
     (`testPermissionsStopShrinksTheWindowToItsCardAtTheRightEdge`,
     `testARestartAtThePermissionsStopOpensAsTheCard`). They fail the same
     way run alone and on a clean copy of the base commit `5979c2a`, so they
     predate CP0 (probably this Mac's screen layout). CI's result is reported
     after the push.
   - Review: three rounds (Opus, xhigh). Round 1: two existing tests broke
     (fixtures resized) and the wiring between view model and clients was
     untested (tests added). Round 2: client-side wiring still partly
     untested, and Codex File Mode didn't count its prompt (both fixed).
     Round 3: no findings.
5. **Limitations:**
   - **The estimate isn't conservative for every text.** Digit-heavy text
     runs over it (a 102-byte order line: 44 real tokens, 34 estimated), and so
     do CJK and emoji on `cl100k_base` (not on `o200k_base`). The owner chose
     to keep it (see Decisions). On large windows the 65,536 cap leaves ample room; on small
     unlisted windows (8,192) a provider could reject a long digit-heavy
     message.
   - **Claude Code's tool run** reported almost the same input as the plain
     run, so the MCP tool definition may have been deferred by the CLI; its
     JSON is counted by Enigma anyway. The tool run used a stdio MCP server,
     not Enigma's in-process `sdk` server.
   - **Provider search** (Codex's and Claude Code's own web search tools) was
     not measured; its tool definition is inside the reserve's 25% margin only
     if it is small.
   - **Codex File Mode wasn't measured live.** Its own text is counted; the
     reserve assumes the CLI adds about the same in File Mode as in chat.
   - **Codex's first preparation** (before `thread/start`) has no test of its
     own; the `turnParameters` preparation, which decides what is sent, is
     tested. Dropping `toolbox:` there only makes an oversized turn fail after
     `thread/start` instead of before it.
   - **Auto's cloud check** counts the plain chat prompt, not a toolbox's; a
     borderline paste on a tool turn is then refused by the final preparation
     with the same message, and the draft is kept.
   - **Small unlisted API models have little room with the full toolbox.**
     Web search, places, weather, Messages and selection tools count about
     2,844 of an unlisted model's 3,584 tokens, so a few-KB selection that
     fit before can now be refused. This follows from counting the prompt as
     used.
6. **For the next checkpoint:**
   - `CloudContext.prepare(_ request:, toolbox:)`; `CloudContext.promptTokens(provider:toolbox:)`.
   - `ModelContextPolicy.cloudInputLimit`, `.codexReserve`, `.claudeCodeReserve`.
   - `ContextUsage(usedTokens:limitTokens:)`; `percentLeft` uses integer
     arithmetic; a zero limit is `full` with 0% left.
   - `ContextBudget.availableInputTokens` already subtracts `promptTokens`;
     `usage.limitTokens` adds it back.
   - **Preparation cost:** `ChatContextPreparer.prepare` re-serializes the
     candidate for every turn it adds, so its cost is quadratic in turns, and
     the larger cap lets far more turns in (review round 3, debug build:
     150 turns of 600 B took 33 ms, was 1 ms; 300 turns of 300 B took 91 ms,
     was 2 ms). It runs on the main actor at send. Prepare at most once per
     send or reply in CP3–CP5, or make the count incremental.
