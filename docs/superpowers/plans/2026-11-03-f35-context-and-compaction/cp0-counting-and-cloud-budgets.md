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

_To be filled in by the CP0 worker._
