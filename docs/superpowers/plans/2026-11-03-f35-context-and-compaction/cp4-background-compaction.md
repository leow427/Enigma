# CP4: Background compaction

Read [agent-workflow.md](agent-workflow.md), the F35 entry, the plan, and the
Hand-offs of CP0–CP3.

## Goal

Compaction is ready before the next send. After a reply finishes, if the
chat's usage is at or above 90%, compaction starts in the background. A send
made while it runs waits for it with `Summarizing earlier messages…`; after
30 s, or if it fails, that request drops turns as today.

## Starting point

- CP3's `ChatCompactor`, `ChatSession.summary`, `LocalChatViewModel.contextUsage`,
  the single preparation function every send path uses, and `/compact`.
- `LocalChatViewModel` tracks the running request in `activeRequest`; a
  reply's end is where `contextNotice` and the activity are settled.
- The assistant activity row shows `AssistantActivity.Phase.label`
  (`Enigma/Chat/AssistantActivity.swift`, rendered by `AssistantActivityView`).
  Add a `.summarizing` phase whose label is the plan's exact status copy; CP3's
  `/compact` should already use it (check its Hand-off). B21 (`to-do.md`)
  reuses this status later.

## Interfaces

**Produces** (in `LocalChatViewModel`):

```swift
@Published private(set) var isCompacting: Bool     // the selected chat is compacting
// internal: one compaction task per chat, keyed by session ID, carrying the transcript
// prefix (message IDs) it summarized and the route it used.
```

## Decisions this plan fixes

- **Trigger:** after a reply completes normally (not on Stop or error), for
  that chat only, when `contextUsage.level == .full`. Never during the tour.
- **One at a time per chat.** A trigger while one runs is ignored.
- **Result applied only if still valid:** the same chat exists, and its
  messages still start with the prefix that was summarized (Review Focus 2).
  Otherwise it is discarded silently.
- **A send while it runs:** shows the status in the assistant activity row,
  waits up to 30 s (one injectable clock for tests), then prepares with the
  result, or, on failure or timeout, with today's drop. The background task
  is cancelled on timeout.
- **Stop** during the wait cancels the wait and the compaction (Review
  Focus 1).
- **Route changes** don't cancel a running compaction; the next send
  recounts with the new budget.
- **Temporary chats** compact the same way; the summary stays in memory.
- **Logs:** a line for start, finish, failure and timeout with durations
  and token counts only.

## Tasks

### Task 4.1: Trigger and apply

- [ ] **Failing tests:** `testCompactionStartsAfterReplyAtNinetyPercent`,
  `testNoCompactionBelowNinetyPercent` (89.9%), `testNoCompactionAfterStopOrError`,
  `testOneCompactionPerChat`, `testCompactionResultForAnotherChatIsDiscarded`,
  `testCompactionResultAfterEditIsDiscarded`, `testTemporaryChatCompactsInMemory`,
  `testUsageDropsAfterCompaction`.

### Task 4.2: Sends that wait

- [ ] **Failing tests:** `testSendWaitsForRunningCompactionWithStatus`,
  `testSendAfterTimeoutDropsTurns` (fake clock, 30 s),
  `testSendAfterFailedCompactionDropsTurns`,
  `testStopWhileWaitingForCompactionCancelsBoth` (draft kept, nothing
  half-saved), `testSendWithoutCompactionDoesNotWait`.

### Task 4.3: Docs

- [ ] `docs/Chat.md` → "Context budgets": when compaction runs, the wait and
  its status, the fallback.

## Exit checks

- The new tests, `ChatCompactionTests`, `EnigmaMainWindowTests`,
  `EnigmaConversationTests` pass; full `build`, `test`, `analyze`.
- With the owner's approval, one live run: a long local chat reaches 90%,
  compacts after the reply, and the next send doesn't wait.

## Hand-off

1. **Summary:** after a reply finishes normally, a chat whose usage is at 90% or
   more is summarized in the background on the route that answered
   (`compactInBackground`). A send made meanwhile waits in the one preparation
   every send path runs (`compactedRequest`), showing "Summarizing earlier
   messages…", for up to 30 s; on failure or timeout (the run is cancelled) it
   drops turns instead of summarizing again. Stop cancels the wait and the run.
2. **Files:**
   - `Enigma/LocalInference/LocalChatViewModel.swift`: `CompactionSteps` and
     `compactionSteps(route:localModel:sessionID:requestID:)` (factored out of
     `compactNow`, same behaviour), `compactions`, `isCompacting`,
     `compactionWait`, `compactInBackground(route:)`,
     `waitForCompaction(of:requestID:)`; `compactedRequest` waits first;
     `finishGeneration` triggers.
   - `EnigmaTests/ChatCompactionTests.swift`: `BackgroundCompactionTests`
     (13 tests), `Gate`, `GatedEngine`.
   - `docs/Chat.md`: "In the background" under Compaction.
3. **Decisions:**
   - The injectable clock is the view model's existing `sleep` (also used for
     idle unload); `compactionWait` is 30 s.
   - `isCompacting` is computed from a published per-chat dictionary rather than
     a stored `@Published` flag, so it follows chat switches by itself.
   - Validity: the chat must exist and its messages must still start with the
     ones summarized (`starts(with:)` on whole messages, so a changed message
     also discards). Switching chats keeps the result for its own chat; the
     selected chat's usage changes only when it is that chat.
   - The trigger needs `messageTextMayGo(to:)` like every send, and skips while
     a tour reply plays.
   - A waited send whose run failed or timed out skips summarizing by making
     its summarize step throw, which the compactor already treats as a failed
     summary (tier 3).
   - **Review round 1 fixes** (no Blocker, 5 Should fixes): the plain local and
     Screen local sends wait (`waitBeforeEngine`) before their first engine
     call, which would otherwise queue silently behind the run on the engine
     actor; `/compact` during a run counts the run's summary as success; the
     idle unload doesn't fire during a run and is re-armed after it; a reply
     that applies a waiting model pick (B21) starts no run; `compactInBackground`
     is internal so a test pins one run per chat. The first commit (fbe748e)
     said each fix had a test that fails without it; only the `/compact` and
     one-run fixes did. The owner asked for a second round for the send-wait fix.
   - **Review round 2 fixes** (no Blocker, 2 Should fixes): the local File Mode,
     `/messages` and native tool sends wait before their first engine call too;
     a local send in another chat cancels other chats' local runs and waits for
     them to let go of the engine (that chat compacts on its own next send), and
     a model switch cancels local runs. Tests added with an engine that runs one
     call at a time like the real actor: the same-chat send shows the status, a
     new chat's send isn't held, the idle unload waits for the run, and a reply
     that applies a model pick starts no run. Each was mutation-checked.
4. **Verification:** `BackgroundCompactionTests`, `ChatCompactionTests`,
   `ChatCompactionSendTests`, `LocalInferenceTests`: 74 tests, 0 failures after
   both review rounds; every review-fix test was mutation-checked. `EnigmaMainWindowTests`,
   `EnigmaConversationTests`, `NativeToolRequestTests`, `LocalInferenceTests`,
   `CloudModeTests`: 244 tests, 2 skipped, 0 failures.
5. **Limitations:**
   - The app can't edit a message, so `testCompactionResultAfterEditIsDiscarded`
     covers the prefix check with a left temporary chat (gone, so nothing applies).
   - A run for a chat that is left keeps running until it ends, then is discarded.
   - On the embedded engine, generation runs on its actor, so cancelling a run
     (timeout or Stop) takes effect between tokens, not during prefill; the
     30 s bound can stretch by one prefill, and a send in another chat or a model
     switch waits that long for a cancelled run. A model delete or benchmark
     still waits behind a running summary with no status. The File Mode,
     `/messages` and native tool waits have no test of their own.
   - The live run (a long local chat reaches 90%) needs the owner's approval and
     wasn't run.
6. **For the next checkpoint:** `isCompacting` is a computed `Bool` on the view
   model; `contextUsage` drops when a background run's summary is kept for the
   selected chat.
