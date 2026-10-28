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
`LocalToolAgent.runStreaming`, `nativeLocalReady(_:)` (CP3).

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
applied automatically when today's setting says so). Local routes: unload
the in-process engine, then `LocalToolAgent.runStreaming`; if
`nativeLocalReady` is false, fall back to today's `submit` and note it once
in the activity row. Cloud routes: the route's `ToolCallingChatProvider`
`stream(_:toolbox:)`. It keeps `submitMessages`' access check (when
`.messages` is in the plan), cancellation and `finishGeneration` handling,
and calls `ToolGrantStore.endSession` when a chat is deleted or evicted.

- [ ] **Write failing tests:**
  - `testFlaggedLocalTurnUsesStreamingAgent` and
    `testFlaggedCloudTurnUsesToolStream`.
  - `testUnreadyLocalRuntimeFallsBack`.
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
- The local in-process engine is unloaded before the server loads; no two
  copies of a model.
- Grants end with the chat; nothing about sessions is persisted.

## Hand-off

*Filled in by the CP4 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP3's CI result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
