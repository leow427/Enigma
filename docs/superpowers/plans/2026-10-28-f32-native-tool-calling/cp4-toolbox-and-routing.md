# CP4: Toolbox and routing

Read [agent-workflow.md](agent-workflow.md), the spec (§1, §2, "Privacy"),
the plan's "Where this plan refines the spec", and the Hand-offs of CP0–CP3.

## Goal

Build the three tool parts and the composite toolbox, decide per turn which
parts a flagged route gets, and send flagged requests through
`submitNative` on the route's streaming tool loop, with chips off and Auto's
web-search block lifted on flagged routes. Everything runs only when
`NativeTools.isEnabled` is true, so with the switch off the app is unchanged;
tests turn the new path on through an injected flag.

## Starting point

- Send routing: `AppShellView.submitDraft` → `ComposerSubmission.plan`
  (`.files / .messages / .captureScreen / .screenAttachment / .chat …`) →
  `submitChat` switches on mode: `localChat.submit`, `submitCloud`,
  `submitAuto`; `submitMessages` handles the cloud disclosure then
  `localChat.submitMessages`. Queue path: `sendQueuedMessage`.
- `LocalChatViewModel`: `submit(_:searchEnabled:allowsAutomaticSearch:onAccepted:)`,
  `submitCloud`, `submitCloudWithSearch`, `submitAuto` (`AutoRouter.decide`),
  `submitMessages` (the model for a tool-loop request: access check,
  provider choice, `engine.unload()`, `LocalToolAgent`/`provider.stream(_:toolbox:)`,
  cleanup), `search(_:writtenQuery:maximumTokens:requestID:)`,
  `finishGeneration` (selection revision parsing into `selectionRevisions`).
- `ComposerIntent.resolve(_ context:now:)` with `Context` fields `draft,
  hasSelection, hasFileSelection, hasScreenshot, previousTurnUsedMessages,
  infersCommands, searchesAutomatically, dismissed`; callers in
  `AppShellView` (`composerIntent(recognizesCommands:)`, queue).
- `AutoRouter.Request` (`selectedMode, webSearchEnabled, prompt,
  webSearchPrompt, …`); `requiresWebSearch` blocks with
  `limitation: .unavailableCapability(.webSearch)` when no cloud supports
  search.
- Sources: `.sourcesSelected(_:)` activity and `ChatMessage.searchSources`.
- Selection: `SelectionRevision(id:contextID:text:automatic:)`,
  `applySelectionRevision`, `SelectionEditingSettings`.
- Session end: `ChatSessionStore` deletion and eviction
  (`maximumRetainedSessions`).

## Interfaces

**Consumes:** `NativeTools` (CP0); `ToolGrantStore`, `ToolPermissionCoordinator`,
`CoordinatorMessagesGate`, `MessagesTools.init(…, gate:)` (CP1);
`AgentToolbox.requiredTool`, streaming `ToolCallingChatProvider`s (CP2);
`LocalToolAgent.runStreaming` (CP3).

**Produces:**

```swift
// Enigma/Search/WebSearchTool.swift
struct WebSearchTool: AgentToolbox {        // tool: web_search(query: string)
  init(search: @escaping @Sendable (String) async throws -> [WebSearchResult],
       mayQuery: @escaping @Sendable (String) async -> Bool,       // gate 3
       onSources: @escaping @Sendable ([WebSearchSource]) async -> Void)
}
// Enigma/Chat/SelectionTools.swift
struct SelectionProposal: Sendable, Equatable { let text: String; let language: String? }
struct SelectionTools: AgentToolbox {       // propose_edit(text), propose_translation(text, language)
  init(allowsEdit: Bool, onProposal: @escaping @Sendable (SelectionProposal) async -> Void)
}
// Enigma/Chat/AssistantToolbox.swift
enum NativeToolPart: Hashable, Sendable { case search, messages, selection }
struct NativeToolPlan: Equatable, Sendable {
  struct Inputs: Equatable, Sendable {
    var typed: ComposerCommands; var hasSelection: Bool; var hasFiles: Bool
    var hasScreenshot: Bool; var searchesAutomatically: Bool; var hasSearchKey: Bool
    var hasFullDiskAccess: Bool
  }
  var parts: Set<NativeToolPart>; var requiredTool: String?; var messagesRequested: Bool
  static func make(_ inputs: Inputs) -> NativeToolPlan
}
struct AssistantToolbox: AgentToolbox {
  init(parts: [any AgentToolbox], requiredTool: String?, extraInstructions: [String])
}
// ComposerIntent.Context
var nativeTools: Bool        // true → no recognizers, no inferred chips
// AutoRouter.Request
var modelChoosesSearch: Bool // true → requiresWebSearch never blocks or reroutes
// LocalChatViewModel
func submitNative(_ prompt: String, route: Route, plan: NativeToolPlan,
                  onAccepted: @escaping () -> Void)
```

**`NativeToolPlan.make` rules** (spec §1–§2):

- `hasFiles` or `hasScreenshot` → not used (those keep today's paths); the
  function returns an empty plan and callers don't call `submitNative`.
- `.search` when `hasSearchKey` and (`searchesAutomatically` or typed
  `/search`); `requiredTool = "web_search"` when `/search` is typed.
- `.messages` when `hasFullDiskAccess`; `messagesRequested` when `/messages`
  is typed.
- `.selection` when `hasSelection`; `requiredTool = "propose_edit"` for
  typed `/edit`, `"propose_translation"` for `/translate` (which also sets
  `allowsEdit` false). `/translate` wins over `/search` for `requiredTool`.

**`AssistantToolbox`** merges definitions (names are unique), dispatches by
name, joins `phase(for:)`, and builds `instructions` from the parts plus the
plan's untrusted-data instruction and, when `messagesRequested`, the typed
`/messages` instruction (exact copy in the plan).

## Tasks

### Task 4.1: The tool parts

**Files:** create `WebSearchTool.swift`, `SelectionTools.swift`; tests in new
`EnigmaTests/NativeToolPartsTests.swift`.

- [ ] **Write failing tests:**
  - `testWebSearchReturnsResultsAndSources`: results JSON has title, url and
    snippets; `onSources` gets the sources.
  - `testWebSearchAsksBeforeQueryingAfterMessageText`: when `mayQuery`
    returns false, `search` is never called and the result is
    `The user declined.`
  - `testWebSearchErrorReturnsToModel`: a thrown search error becomes a
    `success: false` result, not a thrown error.
  - `testProposeEditDeliversProposal`, `testTranslationOnlyHidesProposeEdit`.
- [ ] **Implement.** `web_search`'s description says when to search (fresh
  or changing facts, things the model doesn't know) and when not to (things
  it knows, the user's own data).

### Task 4.2: Plan and composite

**Files:** create `AssistantToolbox.swift`; tests in new
`EnigmaTests/NativeToolPlanTests.swift`.

- [ ] **Write failing tests:**
  - `testPlanTable`: a table over every combination of typed command
    (none, `/search`, `/messages`, `/edit`, `/translate`, `/think`) ×
    selection × automatic search × search key × Full Disk Access, asserting
    `parts`, `requiredTool` and `messagesRequested` from the rules above.
  - `testFilesOrScreenshotGiveEmptyPlan`.
  - `testCompositeDispatchesByName`, `testCompositeInstructions` (contains
    the untrusted-data line always and the `/messages` line only when
    requested), `testCompositeRequiredTool`.

### Task 4.3: `submitNative`

**Files:** `LocalChatViewModel.swift`; tests in `RequestLifecycleTests` /
`MessagesRequestTests` style with stub providers and `ScriptedToolInference`.

`submitNative` builds the parts for the plan (Messages with a
`CoordinatorMessagesGate` for `ToolDestination(route:)` and the session;
`WebSearchTool` whose `search` calls the view model's `search` helper with
the model's query as a written query, whose `mayQuery` is gate 3 through
the coordinator, and whose `onSources` records sources on the reply;
`SelectionTools` whose proposal becomes the message's `SelectionRevision`,
applied automatically when today's setting says so). Local routes:
`LocalToolAgent.runStreaming` on the same `llama-server` instance plain
turns use (`visionEngine`, which is also `fileInference` by default). Cloud
routes: the route's `ToolCallingChatProvider`
`stream(_:toolbox:)`. It keeps `submitMessages`' access check (when
`.messages` is in the plan), cancellation and `finishGeneration` handling,
and calls `ToolGrantStore.endSession` when a chat is deleted or evicted.

- [ ] **Write failing tests:**
  - `testFlaggedLocalTurnUsesStreamingAgent` and
    `testFlaggedCloudTurnUsesToolStream`.
  - `testWebSearchAfterEarlierMessagesTurnAsks`: a read in turn 1, then a
    search in turn 2 shows gate 3; without the read it doesn't.
  - `testNewChatStartsWithoutMessageText`.
  - `testDeletingChatEndsItsGrants`.
  - `testSourcesAttachToReply`, `testSelectionProposalBecomesRevision`.
  - `testStopDuringPermissionCardEndsRequest`.

### Task 4.4: Routing, chips and Auto

**Files:** `AppShellView.swift`, `ComposerIntent.swift`, `AutoRouter.swift`,
`LocalChatViewModel.swift` (`submitAuto`), `ComposerSubmission.swift` if
needed; tests in `ComposerIntentResolveTests`, `AutoRouterTests`,
`ComposerSubmissionTests`.

- [ ] **Write failing tests:**
  - `testNativeContextInfersNothing`: with `nativeTools: true`, no inferred
    chips for drafts that infer today; typed commands still parse.
  - `testAutoDoesNotBlockSearchWhenModelChooses`: `modelChoosesSearch: true`
    never yields `.requiresWebSearch` or a nil route for a web-lookup
    prompt.
  - `testFlaggedRoutesGoToSubmitNative` (switch injected on): Local with a
    flagged model, Cloud, Auto choosing either; `/messages` in Auto still
    routes to the local model; files and screen captures keep today's
    paths.
  - `testSwitchOffKeepsTodaysRouting`: with the switch off, every route
    takes today's function.
  - `testCloudMessagesNoticeSkippedOnFlaggedRoutes`.
- [ ] **Implement:** a single injected `nativeToolsEnabled` (default
  `NativeTools.isEnabled`) on the shell and view model. Chips: Local uses
  the local model's flag, Cloud the cloud flag, Auto the local model's flag
  (plan refinement). When chips were shown and the request goes to a
  flagged route, the shown commands count as typed.

## Exit criteria

- `build`, `test`, `analyze` pass; every pre-existing test passes unedited.
- With the switch injected on, a manual run in the app (owner-approved,
  Xcode-signed build) shows: a search, a gated chat read with each answer,
  gate 3 after a read, a selection edit card, and streaming text. Recorded
  in the Hand-off.

## Reviewer checklist

- The spec's Privacy items 1–8, each traced to code and a test.
- Small models: unflagged routes call exactly today's functions.
- Local tool turns reuse the loaded server; no model reload between turns.
- Grants end with the chat; nothing about sessions is persisted.

## Hand-off

*Filled in by the CP4 worker.*

1. **Summary:** Flagged routes now have their own path, behind the switch.
   `WebSearchTool`, `SelectionTools` and the gated `MessagesTools` merge into
   an `AssistantToolbox` that `NativeToolPlan` composes per turn, and
   `LocalChatViewModel.submitNative` runs it on `LocalToolAgent.runStreaming`
   (local, same server, no unload) or the provider's streaming tool loop
   (cloud). The composer recognizes nothing on a flagged route, Auto no longer
   blocks a lookup when the local model is flagged, and the shell, the queue
   and `submitAuto` send flagged routes to `submitNative`. With
   `nativeToolsEnabled` false (the default, `NativeTools.isEnabled`), every
   route takes today's function.

2. **Files:**
   - `Enigma/Search/WebSearchTool.swift` (new): `web_search`; gate 3 via
     `mayQuery`; searches exactly the card's one-line text.
   - `Enigma/Chat/SelectionTools.swift` (new): `SelectionProposal`,
     `propose_edit` and `propose_translation`.
   - `Enigma/Chat/AssistantToolbox.swift` (new): `NativeToolPart`,
     `NativeToolPlan` (`make`, `empty`, `selectionAllowsEdit`,
     `extraInstructions`) and `AssistantToolbox`.
   - `Enigma/LocalInference/LocalChatViewModel.swift`: `nativeToolsEnabled`,
     `nativeToolPlan(for:)`, `submitNative` and its helpers (toolbox, sources,
     proposals, message-text mark); `submitAuto`'s flagged branch;
     `search(…refinesQuery:)`; `endSession` on eviction, temporary-chat
     discard and empty-chat removal; a typed `/messages` marks message text.
   - `Enigma/Chat/AgentToolLoop.swift`: `LocalToolAgent.prepare` trims a
     flagged local turn's history.
   - `Enigma/Chat/ChatDomain.swift`: `ChatSession.holdsMessageText` (saved).
   - `Enigma/Chat/AutoRouter.swift`: `Request.modelChoosesSearch`.
   - `Enigma/Chat/NativeTools.swift`: `isCapable(mode:…)` for chips;
     `isEnabledForThisRun` (Debug-only environment override).
   - `Enigma/App/ComposerIntent.swift`: `Context.nativeTools`.
   - `Enigma/App/ComposerSubmission.swift`: `nativeRoute(for:…)`,
     `asksMessagesCloudNotice`.
   - `Enigma/App/AppShellView.swift`: chips, chat, Messages and queue
     routing.
   - `Enigma/Chat/ToolPermissions.swift`, `ToolPermissionCoordinator.swift`,
     `ToolPermissionCard.swift`, `Enigma/Messages/MessagesSettingsSection.swift`
     (review round 1): the `shareMessageText` permission, its two-button
     card, and where each chat's message text was allowed to go.
   - `Enigma/Messages/MessagesAccessGate.swift`: a read records its
     destination.
   - `Enigma/Messages/MessagesDatabase.swift`: in the test host,
     `defaultURL` is a missing file in the temporary folder (see Decisions).
   - `Enigma/Chat/ConversationContext.swift`: `draftNote` (the existing
     latest-revision line, shared, unchanged).
   - `EnigmaTests/EnigmaMainWindowTests.swift`: the window `Fixture` takes
     `nativeToolsEnabled`, `toolInference` and `searchKey` (defaults keep
     every existing test as it was), and a new shell routing test.
   - Tests: new `NativeToolPartsTests`, `NativeToolPlanTests`,
     `NativeToolRequestTests`; extensions of `ComposerSubmissionTests`
     (`AppShellStateTests.swift`), `ComposerIntentResolveTests` and
     `AutoRouterTests`. No existing test changed.
   - `Enigma.xcodeproj/project.pbxproj`: the six new files.
   - The plan's progress log, and this Hand-off.

3. **Decisions:**
   - **CP3's CI:** the run on `b1b1f55` (Fix CI after F32 CP3 (round 2))
     passed (`build-and-test`, 8m25s).
   - **Translations (owner, 2026-10-28):** never a card. `propose_translation`
     adds the translation to the reply's text, after what the model wrote.
     `propose_edit` becomes today's revision block in the reply, so the
     card, the saved chat and later `/edit` requests read it as they read a
     typed `/edit`'s; replacing still takes a click or the automatic-replace
     setting. Flagged turns don't get the revision-block instructions.
   - **The message-text mark is saved (owner, 2026-10-28):**
     `ChatSession.holdsMessageText` (nil until set, so older chats decode and
     save unchanged) is restored into the grant store at launch, so gate 3
     still asks in a chat reopened after a relaunch (CP1's open item). Only
     the flag is saved; grants stay in memory.
   - **A typed `/messages` turn marks the chat** on every route (Review Focus
     5), since today's tools read freely. That's the one change on an
     unflagged path; nothing reads the mark there.
   - **Gate 3 sends what the card showed:** `WebSearchTool` turns the
     model's query into the card's one-line form before asking and
     searching (CP1's note). As today, a "near me" query then gets the coarse
     city added on the Mac before it goes to Brave; the spec keeps that.
   - **`/edit` with `/search`:** search is required first, so the model can
     look something up before proposing; `/translate` wins over `/search`,
     as the brief says. `requiredTool` is set only for parts that are
     offered.
   - **Forced choice in words for cloud:** Codex, Claude Code and Anthropic
     under `/think` can't force a tool (CP0, CP2), so a cloud request with a
     required tool also ends its last user message with `Call the <name>
     tool before you answer.` (request only, never saved). The local server
     already adds it.
   - **Messages on flagged routes are always gated:** the toolbox factory's
     result is used only if it is `MessagesTools`, which then gets a
     `CoordinatorMessagesGate`; anything else isn't offered.
   - **Search on flagged routes** skips today's query refinement (the model
     wrote the query) and asks Brave for 2,048 tokens on local routes
     (8,192 on cloud), so results fit an 8K local context. Sources from every
     search in a reply are merged onto it.
   - **Trimming (CP3's note):** `LocalToolAgent.prepare` drops older turns
     as plain turns do: history at a byte a token, the system prompt and
     tools at about four bytes a token, 1,024 output tokens (2,048 with
     `/think`). The server's exact check still guards the request. Cloud
     routes use `CloudContext.prepare`.
   - **Auto:** `modelChoosesSearch` is the local model's flag (Auto starts
     local); Auto then sends a flagged route, local or cloud, to
     `submitNative`, with a shown search chip counting as typed `/search`.
     If a flagged local model's Auto request goes to an unflagged cloud
     model, that model gets typed commands only (no chips were shown).
   - **Grants end with the chat** on eviction, temporary-chat discard (new
     chat, a new selection) and empty-chat removal. There is no delete-chat
     action in the app.
   - **Manual run:** a Debug build reads `ENIGMA_NATIVE_TOOLS=1`
     (`NativeTools.isEnabledForThisRun`) so the owner can try flagged routes
     from Xcode before CP5; Release builds ignore it.
   - **Edit wording (owner-approved live probe, 2026-10-28):** in the
     owner's manual run Gemma 4 12B was offered `propose_edit` but wrote the
     revision as plain text. A local probe (6 prompts × 2 wordings, Gemma 4
     12B Q5_K_M, neutral sample text) scored today's wording 2/6 (no edit
     request called the tool) and a firmer one 6/6 (every edit called it,
     both questions didn't). `SelectionTools` now uses the firmer wording.
   - **Review round 1** (1 Blocker, 6 Should fix), all fixed:
     1. *Blocker:* a `propose_edit` the user didn't ask for was pasted by
        the automatic-replace setting. Now only a typed (or chip-shown)
        `/edit` pastes on its own (`NativeToolPlan.editRequested`); any other
        proposal waits for a click.
     2. *Message text crossing destinations (owner, 2026-10-28: keep Auto
        local; Cloud asks):* the store records where each chat's message
        text was allowed. In Auto such a chat stays local (as Auto
        `/messages` does). A flagged cloud turn asks first with a
        two-button card, `Send text from your messages to <Company>?` /
        `This chat includes text from your messages.` / `Don't allow`,
        `Allow` (for this chat; no Always). Don't allow fails the request
        before it starts, with the draft kept. An unflagged cloud model
        can't show the card, so with the switch on it refuses such a chat.
     3. *Draft cleared before a failure:* the question now lands, and the
        draft clears, only once the request is under way: a cloud turn after
        it's prepared, as `submitCloud`; a local turn at the model's first
        text or tool call, as plain local turns. Until then it shows as
        pending.
     4. *Manual changes to the revision card:* flagged turns send the latest
        draft line (with the user's changes) without the revision-block
        instructions.
     5. *Mark saved late:* the mark is saved the moment a tool returns
        message text (`SavingMessagesGate`), before any reply can quote it.
        Chats saved before this change that used `/messages` stay unmarked
        (owner, 2026-10-28: accepted limitation).
     6. *Shell wiring untested:* a window test sends through the real shell
        with a flagged model; removing the chip wiring or the native branch
        of `submitChat` each fails it (checked in a scratch copy).
     7. This Hand-off.
   - **Review round 2** (1 Blocker, 3 Should fix), all fixed:
     1. *Blocker:* a chat's allowed companies only grew, so text read with
        "It stays on this Mac" could go to a company that had seen earlier
        text in the chat. Now each read narrows the set to the companies
        all of the chat's text was allowed for (this Mac is always allowed),
        and only the share card's Allow adds one back.
     2. *Other cloud paths:* a screenshot turn to the cloud, Codex File Mode
        and an unflagged cloud `/messages` now refuse such a chat with the
        same message, keeping the draft (and attachments); in Auto a
        screenshot turn's route stays local, as `submitAuto`'s does. One check,
        `messageTextMayGo(to:)`, serves every path and treats a cloud
        company Enigma can't name as not allowed.
     3. *Draft `/messages` untested:* a window test types `/messages` in the
        field and clicks Send; breaking the native branch fails it.
     4. The manual run, below.
   - **Review round 3** (no Blocker, 1 Should fix), fixed without another
     round: a typed `/messages` on an unflagged route marks the chat with its
     route's company, and no test checked which. Two tests now do (a local
     read then a Cloud turn shows the share card; a cloud OpenAI read is
     allowed for OpenAI only); marking with the wrong company fails both.
     Its nits are also done: the access test returns before opening the
     real file, the share-card check fails closed if the view model is gone,
     and a test pins that with the switch off a `/messages` chat still goes
     to the cloud as today.
   - **Test runs revoked the owner's Full Disk Access (found in the manual
     run):** the unsigned test host shares Enigma's bundle ID, and several
     tests (the Settings Messages section, view models built without an
     access check) opened the real `chat.db`. macOS then failed to match the
     grant's code requirement, recorded a denial for the test build, and the
     installed and Debug copies lost access too (`tccd` logs: "Failed to match
     existing code requirement … recording denied"). In the test host
     `MessagesDatabase.defaultURL` is now a missing file, so tests never touch
     the real database; a full run afterwards made no Full Disk Access checks.
   - **Route log:** `NativeTools.logger` records each flagged turn's route,
     the tool names offered and each tool name called (category
     `NativeTools`), never text, queries, arguments or results. It is what
     found the manual run's problems; it stays for CP5's eval.
   - **Test-first:** Task 4.1's tests were written before the code but first
     run after it; Tasks 4.2–4.4 failed first (compile errors), then passed.

4. **Verification:**
   - Before review: the CP4 classes, 20/14/6/8 tests, 0 failed (each new
     class failed to compile first). `build` succeeded; `analyze` 0
     warnings; full `test` 1494 executed, 26 skipped, 1 failed (the known
     load-sensitive `testSendNowDuringAPendingSend…`, which passed alone).
   - Review round 1's reviewer: full `test` 1494/26/1 (same flaky test),
     21 mutations, all caught except the shell wiring (now covered).
   - After round 1's fixes: each fix's new test failed before its fix or
     was checked by mutation (the window test against both shell
     mutations). The CP4 classes, `ToolPermissionTests`, `MessagesToolsTests`
     and `ComposerSubmissionTests`: 0 failed. `build` succeeded; `analyze` 0
     warnings; full `test` 1503 executed, 26 skipped, 1 failed (the same
     flaky test, which passed alone).
   - Round 2's fixes: each new test failed first; the window test failed
     with its branch broken. Full `test` 1511 executed, 26 skipped, 0
     failed; `build` succeeded; `analyze` 0 warnings. Round 3's reviewer:
     full `test` 1511/26/0, 14 mutations, all caught except the Auto
     screenshot route (the screen check still refuses the cloud), an
     unreachable unknown-company branch, and the two round 3 fixed. After
     round 3's fixes: the new tests fail when a local `/messages` is marked
     with the wrong company; full `test` 1513 executed, 26 skipped, 1 failed
     (the known load-sensitive `testSendNowDuringAPendingSend…`, which passed
     alone); `build` succeeded; `analyze` 0 warnings.
   - Manual run (owner, Debug build signed with Apple Development,
     `ENIGMA_NATIVE_TOOLS=1`, Gemma 4 12B):
     - Messages: the first run had no Full Disk Access for the test copy, so
       the Messages tools weren't offered (correct). Granting it made macOS
       relaunch a stale Release build of `main` by bundle ID, whose `/messages`
       read with no card; relaunching the CP4 copy fixed that. Then
       `search_contacts` and `get_messages` were offered and called.
     - Selection: `propose_edit` was offered but not called; see the edit
       wording probe.
     - After round 1's fixes (owner): the selection's edit request showed
       the revision card. A Messages question got "I do not have access":
       the route log shows that turn offered only `web_search`, because a test
       run had revoked Full Disk Access (see Decisions); without it the spec
       offers no Messages tools.
     - After round 2's fixes (owner: "the tests seemed to actually be
       okay"; the route log of that copy): with Full Disk Access re-granted,
       local Gemma read chats (`search_contacts`, `get_messages`) and proposed
       an edit (`propose_edit`); cloud Claude Code read chats
       (`search_contacts`, `list_conversations`, `get_messages`) and proposed
       an edit. No grant was revoked during the run. No turn called
       `web_search` in that part of the run.
     - Then a weather search (owner: "the search for weather in paris did
       work"): local Gemma called `web_search`. The owner approved the run.
       Gate 3's card after a read wasn't separately reported; tests cover it
       (`testWebSearchAfterEarlierMessagesTurnAsks`,
       `testDeclinedSearchAfterMessagesNeverQueries`).

5. **Limitations:**
   - Chats saved before this change that used `/messages` aren't marked, so
     after CP5 their web searches don't ask (owner-accepted).
   - The message-text destinations are kept in memory; a chat reopened after
     a relaunch counts its text as allowed on this Mac only, so a cloud turn
     asks again (stricter, not looser).
   - The local trimming estimate is coarse (bytes as tokens for history);
     the server's exact check still guards each request.
   - The edit wording was tuned on Gemma 4 12B only; CP5's eval covers the
     other models.

6. **For the next checkpoint:**
   - `NativeTools.isEnabledForThisRun` is what `LocalChatViewModel.shared`
     uses; CP5 flips `isEnabled`. The Debug override can then go.
   - `ENIGMA_NATIVE_TOOLS=1` in a Debug run turns flagged routes on for
     manual checks. macOS relaunches "Enigma" by bundle ID after a privacy
     grant, which may start another copy; check which one runs.
   - The `NativeTools` log category shows each flagged turn's tools and
     calls; the eval can read it.
   - Docs (CP5): Selection Context (edits are proposed by a tool; only a
     typed `/edit` pastes automatically; translations are shown in the
     reply), Messages (the new cards, Auto keeping such chats local), Chat
     (the pending question until a flagged request is under way), and CP3's
     notes on the prompt cache.
