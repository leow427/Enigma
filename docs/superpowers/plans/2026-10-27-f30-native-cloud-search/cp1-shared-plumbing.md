# CP1: Shared plumbing — the search backend, fallback, the restart, sources

Read [agent-workflow.md](agent-workflow.md), the spec (§1, §2, §2a, §4–§6,
"Failure handling", "Privacy"), and [CP0's Hand-off](cp0-spike.md#hand-off).

## Goal

Build everything the four providers share, without changing what users see:

- `NativeToolPlan` can choose provider search, and `submitNative` sets
  `ChatRequest.providerSearch` and uses `ProviderSearchPart` for it;
- an unavailable provider falls back once, and is remembered;
- message text on its way into a provider-search request is held back and
  the turn restarts without provider search;
- provider sources are selected, merged onto the reply and saved;
- a nearby question on a provider-search turn asks, per provider, before
  the approximate location goes to that provider's search (spec §2a, owner
  amendment of 2026-10-29).

`CloudProviderID.nativeWebSearchProviders` stays empty, so every route
still gets F32's behavior. CP1 also opens the branch's draft pull request,
so CI runs from now on, and turns Auto-fix on.

## Starting point

Find code by symbol (see the workflow).

- **`Enigma/Chat/ChatDomain.swift`:** `ChatRequest` has `sessionID`,
  `messages`, `route`, `image` and `allowsCloudImages`.
  `ChatSession.holdsMessageText` (F32 CP4) is saved with the chat and
  restored into the grant store at launch.
- **`Enigma/Chat/AssistantToolbox.swift`:** `NativeToolPart` is
  `.search`, `.messages` or `.selection`. `NativeToolPlan.make(_:)` adds
  `.search` when `hasSearchKey && (searchesAutomatically || typed.search)`,
  and sets `requiredTool = "web_search"` for a typed `/search`.
  `AssistantToolbox` merges parts' instructions and definitions.
- **`Enigma/Search/WebSearchTool.swift`:** the `.enigma` backend. Its
  instructions start with "Today is …" in the user's time zone.
- **`Enigma/LocalInference/LocalChatViewModel.swift`:**
  - `nativeToolPlan(for:hasFiles:hasScreenshot:)` fills the plan's inputs;
  - `submitNative(_:route:plan:onAccepted:)` begins the generation, sets
    `pendingUserMessage`, builds the toolbox (`nativeToolbox(plan:…)`, which
    builds `WebSearchTool`, the gated `MessagesTools` wrapped in
    `SavingMessagesGate`, and the selection tools), and streams
    `provider.stream(request, toolbox:)`. A cloud turn is accepted
    (`acceptNative`) once it's prepared, before the stream;
  - `SavingMessagesGate.didReturnMessageText()` runs when a Messages tool is
    about to return message text, and marks the chat.
- **`Enigma/Cloud/CloudDomain.swift`:** `CloudProviderID`, and
  `CloudProviderError` with its `errorDescription`.
- **`Enigma/Chat/AssistantActivity.swift`:** `AssistantActivityEvent` has
  `.phase`, `.sourcesDiscovered` and `.sourcesSelected`;
  `WebSearchSource.isSafeWebLink` and `.siteName`.
- **Test doubles to reuse:** `NativeToolRequestTests`' fake tool-calling
  providers and Messages fixtures; `RequestLifecycleTests`'
  `ControlledStream`.

## Tasks

### Task 1.1: Types, the error and the provider set

**Files:** modify `Enigma/Chat/ChatDomain.swift`,
`Enigma/Cloud/CloudDomain.swift`; create `Enigma/Cloud/NativeWebSearch.swift`
(app target). Tests go in the new `EnigmaTests/NativeWebSearchTests.swift`
(test target).

**Interfaces.** This task produces:

```swift
// ChatDomain.swift
struct ProviderSearch: Sendable, Equatable {
  /// F29's blocked sites, most recently blocked first. Empty until F29.
  var blockedDomains: [String] = []
}
struct ChatRequest: Sendable, Equatable {
  // existing fields unchanged
  var providerSearch: ProviderSearch? = nil     // nil: no provider search
}

// CloudDomain.swift
extension CloudProviderID {
  /// The providers whose own search is on. CP2–CP5 each add theirs; never `.gemini`.
  static let nativeWebSearchProviders: Set<CloudProviderID> = []
  var supportsNativeWebSearch: Bool { Self.nativeWebSearchProviders.contains(self) }
}
enum CloudProviderError { case webSearchUnavailable(CloudProviderID) }

// NativeWebSearch.swift
enum NativeWebSearch {
  static let maximumSearches = 5
  static let maximumSources = 8
  static func isAllowed(provider: CloudProviderID, modelID: String, holdsMessageText: Bool,
                        enabledProviders: Set<CloudProviderID>,
                        availability: NativeWebSearchAvailability) -> Bool
  static func selectSources(cited: [WebSearchSource], linked: [URL],
                            discovered: [WebSearchSource]) -> [WebSearchSource]
  /// Markdown links (not images) and bare http(s) URLs, first-seen order, no duplicates.
  static func links(in text: String) -> [URL]
}
struct NativeWebSearchAvailability: Equatable, Sendable {
  mutating func markUnavailable(_ provider: CloudProviderID, modelID: String)
  func isAvailable(_ provider: CloudProviderID, modelID: String) -> Bool
}
/// One request's search bookkeeping, shared by the four clients.
struct NativeWebSearchSources: Sendable {
  mutating func discovered(_ sources: [WebSearchSource])
  mutating func cited(_ source: WebSearchSource)
  mutating func answered(_ text: String)
  var searched: Bool { get }
  /// `selectSources` over what was collected; `linksAreCitations` for Codex and Claude Code.
  func selection(linksAreCitations: Bool) -> [WebSearchSource]
}
/// Raised by the gate to stop a provider-search request for a restart (spec §2).
struct ProviderSearchRestart: Error, Equatable {}
```

**Steps:**

- [ ] **Write the failing tests** in `NativeWebSearchTests`:
  - `testChatRequestHasNoProviderSearchByDefault`.
  - `testUnavailableErrorMessage`: the description is "Web search isn't
    available for this model."
  - `testNativeWebSearchProviders`: the set is `[]`, and
    `.gemini.supportsNativeWebSearch == false`. CP2–CP5 update the expected
    set.
  - `testIsAllowed`: a table over provider (each of the five), the provider
    in or out of `enabledProviders`, `holdsMessageText`, and availability.
    Gemini is never allowed; message text always forbids.
  - `testAvailabilityIsPerProviderAndModel`.
  - `testSelectSourcesPrefersCitedThenLinked`,
    `testSelectSourcesFallsBackToDiscoveredWhenNothingCited`,
    `testSelectSourcesDropsFragmentDuplicates`,
    `testSelectSourcesDropsUnsafeLinks` (`javascript:`, credentials,
    relative paths), `testSelectSourcesUsesSiteNameForMissingTitle`,
    `testSelectSourcesCapsAtEight`.
  - `testLinksInText`: Markdown links in order, images skipped, bare URLs,
    trailing punctuation trimmed, duplicates once.
  - `testCollectorSelection`: with and without `linksAreCitations`.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeWebSearchTests`.
  Expect a compile failure.
- [ ] **Implement,** then run again. Check every `switch` over
  `CloudProviderError` still compiles.

### Task 1.2: The plan's search backend and the instruction

**Files:** modify `Enigma/Chat/AssistantToolbox.swift`,
`Enigma/Cloud/NativeWebSearch.swift`. Tests in `NativeToolPlanTests` and
`NativeWebSearchTests`.

**Interfaces:**

```swift
enum SearchBackend: Hashable, Sendable { case enigma, provider }
enum NativeToolPart: Hashable, Sendable { case search(SearchBackend), messages, selection }
struct NativeToolPlan {
  struct Inputs { /* existing */ var providerSearch: Bool = false }
}
/// Spec §4's instruction as a toolbox part with no definitions.
struct ProviderSearchPart: AgentToolbox {
  init(today: Date = Date(), timeZone: TimeZone = .current, blockedDomains: [String] = [])
}
```

**Steps:**

- [ ] **Write the failing tests:**
  - `NativeToolPlanTests.testSearchBackend`: a table over `providerSearch`,
    `hasSearchKey`, automatic search and typed `/search`. Provider search
    needs no key; without either, no search part; a typed `/search` sets
    `requiredTool = "web_search"` for both backends. Every existing row of
    the test class stays green unchanged.
  - `NativeWebSearchTests.testProviderSearchInstruction`: the exact spec §4
    text for a fixed date and time zone, with "ask which city they mean";
    no definitions; `phase(for:)` is `.searching`.
  - `testProviderSearchInstructionNamesBlockedSites`: with 25 blocked
    domains, the final sentence names the first 20 (most recent first),
    "Don't use results from these sites: a.com, b.com." (spec, Decisions:
    F29 supplies them later; the sentence is built now so F29 only passes
    the list).
- [ ] **Run, implement, run.** Update every `switch` over `NativeToolPart`.
- [ ] **Amendment (spec §2a, §4):** the instruction's near-me clause comes
  from the request's location. `testProviderSearchInstructionWithLocation`:
  with a `ProviderSearchLocation` the clause is exactly "The user's
  approximate location is ‹City, Region, Country›; your web search tool uses
  it for places and weather near them", with missing parts left out (no
  stray commas); without one it's the "ask which city they mean" clause.

### Task 1.3: `submitNative` with provider search, and the fallback

**Files:** modify `Enigma/LocalInference/LocalChatViewModel.swift`. Tests in
`NativeToolRequestTests`; doubles in the new
`EnigmaTests/CloudSearchTestSupport.swift`.

**Interfaces:**

```swift
// LocalChatViewModel
init(/* existing */, nativeWebSearchProviders: Set<CloudProviderID> = CloudProviderID.nativeWebSearchProviders)

// CloudSearchTestSupport.swift (tests)
/// A ToolCallingChatProvider that records each request and toolbox, and replays a script of
/// events, tool calls or errors per run.
final class ScriptedSearchProvider: ToolCallingChatProvider { /* … */ }
enum CloudSearchFixture { static func url(_ name: String) -> URL }   // Fixtures/CloudSearch/
```

**Steps:**

- [ ] **Write the failing tests:**
  - `testProviderSearchSetsRequestAndInstruction`: with the provider in the
    set, `request.providerSearch` is set, the toolbox has no `web_search`
    definition, and its instructions hold `ProviderSearchPart`'s.
  - `testWithoutProviderSearchKeepsWebSearchTool`: the provider not in the
    set and a key saved: today's `WebSearchTool`, `providerSearch == nil`.
  - `testProviderSearchNeedsNoKey`: no Brave key, provider in the set: the
    search part is offered.
  - `testChatHoldingMessageTextNeverGetsProviderSearch`: a chat restored
    with `holdsMessageText == true`: `.enigma` behind gate 3 with a key,
    no search part without one.
  - `testUnavailableBeforeReplyFallsBackOnce`: the script throws
    `.webSearchUnavailable` before any text or tool call: the same turn runs
    again with `providerSearch == nil`, no second `beginGeneration`, one
    reply; a second turn with the same model doesn't try provider search.
  - `testUnavailableAfterReplyStartsDoesNotFallBack`: text first, then the
    error: no second run, the error shown, text and sources kept.
  - `testProviderSourcesSavedOnReply`: `.sourcesSelected` from the script
    become the reply's `searchSources`, merged with any from an earlier
    step, capped at 8, and saved.
  - `testFailedStreamStillSavesSources`.
  - `testGeminiNeverGetsProviderSearch`.
- [ ] **Run, implement, run.** The fallback runs inside the same generation
  task, before any token or tool call reaches the reply. Availability lives
  on the view model, never saved.

### Task 1.4: The restart

**Files:** `LocalChatViewModel.swift` (`SavingMessagesGate`, `submitNative`),
`NativeWebSearch.swift`. Tests in `NativeToolRequestTests`.

Spec §2. When `didReturnMessageText()` runs for a request whose
`providerSearch` is set, the gate marks the chat, then throws
`ProviderSearchRestart`, so `MessagesTools` returns no result to the loop.
The loop ends the request; `submitNative` sees the restart, clears the
reply's text and sources, and runs the turn again with the plan made again.

- [ ] **Write the failing tests:**
  - `testMessageTextHoldsResultAndRestarts`: the script searches, writes
    text, then calls `get_messages` on an allowed chat. The provider never
    receives that call's result (the scripted provider records every
    delivered result); the reply on screen is cleared; a second run starts.
  - `testRestartRunsOnceWithoutProviderSearch`: the second run's request
    has `providerSearch == nil` and, with a key, `web_search` behind gate 3;
    its own Messages read doesn't restart.
  - `testRestartKeepsTheReadGrant`: the first run's card was answered For
    this conversation; the second run's `get_messages` shows no card.
  - `testDeclinedReadDoesNotRestart`: Don't allow on the card: no message
    text, no restart, the model carries on.
  - `testStopDuringRestartEndsTheTurn`: Stop after the first run ends and
    before the second sends: no second request.
  - `testRestartIsNotShownAsStop`: no "stopped" state or error appears.
- [ ] **Run, implement, run.** The check stays in the gate (Swift), never
  in a prompt.

### Task 1.5: The location card (spec §2a)

Added on 2026-10-29 by the owner's amendment, after CP1 started. Build it
after Task 1.4.

**Files:** modify `Enigma/Chat/ChatDomain.swift`,
`Enigma/Chat/ToolPermissions.swift`, `Enigma/Chat/ToolPermissionCard.swift`
(copy only), `Enigma/Search/LocationService.swift`,
`Enigma/LocalInference/LocalChatViewModel.swift`, and the Settings Always
list if it needs a label for the new kind.

**Interfaces:**

```swift
// ChatDomain.swift
struct ProviderSearchLocation: Sendable, Equatable {
  var city: String?
  var region: String?
  var countryCode: String?     // ISO 3166-1 alpha-2
  var timeZone: String?        // IANA identifier, from the Mac
  /// "City, Region, Country" with missing parts left out, for the card and the instruction.
  var displayName: String { get }
}
struct ProviderSearch { var location: ProviderSearchLocation? = nil }   // beside blockedDomains

// ToolPermissions.swift
enum ToolPermission { case shareLocation(provider: CloudProviderID, area: String) }
// ToolAlwaysGrant.Kind gains .shareLocation, and the grant gains an optional
// `provider: CloudProviderID?`: location grants are matched by provider, never by
// ToolDestination. Saved Always grants from F32 still decode.

// LocationService.swift
// ApproximateLocation gains `providerSearchLocation`: city, region and country code from the
// reverse geocode the service already makes, and TimeZone.current's identifier. Coordinates stay
// on the Mac.
```

**Behavior** is spec §2a. The card is asked in `submitNative` before the
request is sent (like F32's `.shareMessageText` card), only when the plan's
search is `.provider`, `LocationIntent.needsLocation` holds for the user's
own question, the Location setting is on, and this provider has no grant.
Look up the area first (on the Mac), so the card can name it; no area, no
card. Stop while the card shows ends the turn like Stop.

- [ ] **Write the failing tests** (`NativeToolRequestTests`, with fakes for
  the location provider and the permission answer):
  - `testNearbyQuestionAsksBeforeProviderSearch`: the card shows with the
    spec's exact title and body, before anything reaches the fake provider;
    "For this conversation" sends the location in `providerSearch.location`.
  - `testLocationDeclinedSendsNothing`: Don't allow → no location, the
    "ask which city" clause, and the card returns for the next nearby
    question.
  - `testLocationGrantIsPerProvider`: a grant for `.chatGPT` doesn't cover
    `.openAI`, and `.claudeCode` doesn't cover `.anthropic` (both
    directions); Always for one provider shows the card again for another.
  - `testNoLocationCardWithoutNearbyQuestion`, `…WhenLocationOff`,
    `…WhenLocationUnavailable`, `…OnEnigmaSearch` (`.enigma` backend keeps
    today's behavior), `…AfterRestart` (the restart's second run asks
    nothing).
  - `testAlwaysLocationGrantSurvivesAndIsListed`: saved with F32's Always
    grants (in a test suite's defaults), listed with the provider's name,
    removable; an F32 grant saved before this change still decodes.
  - `ApproximateLocation` maps a geocoded city, region and country to
    `ProviderSearchLocation` and never includes coordinates.
- [ ] **Run, implement, run.** Nothing about the location is logged.

### Task 1.6: The pull request

- [ ] **After the commit is pushed,** open the branch's draft pull request
  (`gh pr create --draft`, title "Native web search for cloud models
  (F30)", body from the plan's Goal and a checklist of checkpoints, no
  attribution lines) and turn Auto-fix on for it. Check CI passes.

## Exit criteria

- `NativeWebSearchTests`, `NativeToolPlanTests`, `NativeToolRequestTests`,
  `NativeToolPartsTests`, `ToolPermissionTests` and `RequestLifecycleTests`
  pass; F32's existing tests unchanged.
- `build` and `analyze` succeed; the full `test` runs once, before the
  commit.
- With the set empty, no request carries `providerSearch` (a test proves
  it), so users see no change.
- The draft pull request exists, Auto-fix is on, and CI passes.

## Reviewer checklist

- The restart is in the gate, delivers nothing to the provider, happens
  once, and keeps the grant. Mutation-test it: deliver the result anyway,
  or allow a second restart, and a test must fail.
- `isAllowed` and the plan can't offer provider search in a chat that holds
  message text, on Gemini, or for an unavailable pair.
- The fallback can't run after any text or tool call reached the reply.
- Location: no card and no location unless every §2a condition holds; a
  grant never crosses providers (mutation-test: key it by
  `ToolDestination` and a test must fail); no coordinates in
  `ProviderSearchLocation`; nothing logged.
- No location, query, URL or answer text in a log; nothing new on disk.
- No existing F32 test was weakened.

## Hand-off

*Filled in by the CP1 worker.*

1. **Summary:** The shared plumbing for provider search, with no provider
   turned on (`nativeWebSearchProviders == []`), so users see no change. It
   includes:
   - the plan's search backend (`.search(.enigma)` or `.search(.provider)`);
   - `ChatRequest.providerSearch`, set by `submitNative` together with
     `ProviderSearchPart`'s instruction;
   - the unavailable fallback, remembered per provider and model;
   - the restart, enforced in the Messages gate;
   - source selection, and merging provider sources onto the reply;
   - spec §2a's per-provider location card.

   It was built in the brief's order, with Task 1.5 (location) after 1.4 as
   the amendment asked.
2. **Files:**
   - `Enigma/Cloud/NativeWebSearch.swift` (new): `NativeWebSearch`
     (limits, `isAllowed`, `selectSources`, `links(in:)`),
     `NativeWebSearchAvailability`, `NativeWebSearchSources`,
     `ProviderSearchRestart`, `ProviderSearchPart`.
   - `Enigma/Chat/ChatDomain.swift`: `ProviderSearchLocation`,
     `ProviderSearch`, `ChatRequest.providerSearch`.
   - `Enigma/Cloud/CloudDomain.swift`: `nativeWebSearchProviders`,
     `supportsNativeWebSearch`, `shortName` (the card's provider name),
     `CloudProviderError.webSearchUnavailable`.
   - `Enigma/Chat/AssistantToolbox.swift`: `SearchBackend`,
     `NativeToolPart.search(SearchBackend)`, `Inputs.providerSearch`, the
     plan's stored `inputs`, `remade(providerSearch:)`, `searchBackend`, and
     `AssistantToolbox.onCall`.
   - `Enigma/Chat/AgentToolLoop.swift`: `AgentToolStop.restart`, whose error
     is `ProviderSearchRestart`.
   - `Enigma/Messages/MessagesAccessGate.swift`, `MessagesTools.swift`:
     `didReturnMessageText()` is now `async throws`. A
     `ProviderSearchRestart` becomes a terminal result with fixed text and
     `stop: .restart`.
   - `Enigma/LocalInference/LocalChatViewModel.swift`, `submitNative` and
     its helpers:
     - the init takes `nativeWebSearchProviders:`, and availability is kept
       in memory;
     - the plan is resolved per route, then the location step, then a run
       loop with the fallback and the restart;
     - provider `.sourcesSelected` events are merged and capped at 8;
     - `restartNativeReply`, `providerSearchLocation`, and
       `SavingMessagesGate.restartsProviderSearch`.
   - `Enigma/Search/WebSearchTool.swift`: `formattedDate`, shared with
     `ProviderSearchPart`.
   - `Enigma/Messages/MessagesTools.swift`: `ledger` is injectable.
     `submitNative` makes one `MessagesSendLedger` per turn, shared by every
     run (review round 1).
   - `Enigma/Chat/ChatDomain.swift` (`ReplyOrigin.providerSearch`, session
     only) and `Enigma/Chat/EnigmaConversationLogic.swift`
     (`ReplyMetaLine`): the footer says "web search" for provider search,
     per spec §5 (owner: CP1 builds it).
   - `Enigma/Chat/ToolPermissions.swift`: `ToolPermission.shareLocation`,
     `Kind.shareLocation`, and an optional `provider` on the grant and its
     key.
   - `ToolPermissionCoordinator.swift` (copy), `ToolPermissionCard.swift`
     (the globe icon for the location card), `MessagesSettingsSection.swift`
     (the Always row).
   - `Enigma/Search/LocationService.swift`: `ApproximateLocation` gains
     city, region, country code and `providerSearchLocation`, and
     `LocationService.region(cityWithContext:city:country:)`.
   - Tests:
     - `EnigmaTests/NativeWebSearchTests.swift` (new);
     - `EnigmaTests/CloudSearchTestSupport.swift` (new):
       `CloudSearchFixture` and `ScriptedSearchProvider`;
     - `NativeToolPlanTests` and `NativeToolRequestTests`: new tests.
   - `Enigma.xcodeproj/project.pbxproj`: the three new files.
3. **Decisions:**
   - **Making the plan again.** `NativeToolPlan` keeps the `Inputs` it was
     made from, so `submitNative` can resolve provider search for the route
     itself (`plan.remade(providerSearch:)`) and make the plan again for the
     fallback and the restart. Callers (`AppShellView`, the warm-up) are
     unchanged.
   - **The restart uses the terminal path, as CP0 decided.** The gate
     throws. `MessagesTools` turns that into a terminal result
     (`stop: .restart`, text "The request was restarted.", never the read's
     output), which F32's loops throw instead of delivering.
   - **"Reply started"** means the first `.token` or toolbox call, tracked
     with `AssistantToolbox.onCall`. It isn't acceptance, as CP0 found.
     Each of the fallback and the restart runs at most once per turn. An
     unavailable error marks the provider and model unavailable even after
     the reply started, when it's shown as an error and there's no
     fallback, so later turns skip it (review round 3).
   - **A typed `/search` on provider search** keeps
     `requiredTool = "web_search"`. Because `ProviderSearchPart` has no
     definitions, `offeredRequiredTool` is nil, so `submitNative` adds F32's
     "Call the web_search tool before you answer." in words itself. Whether
     to force the tool as well: CP2 may force OpenAI's search with the
     `allowed_tools` form, only if its live check confirms it (CP0 Q1).
     CP3 never forces Anthropic's: CP0 Q2 found `tool_choice` returns a 400
     on current models. A client detects a typed `/search` with
     `request.providerSearch != nil && toolbox.requiredTool == "web_search"`.
   - **Sources:**
     - `selectSources` filters unsafe links before deciding whether
       anything was cited, so a citation list of only unsafe links falls
       back to the discovered results.
     - `links(in:)` returns only http(s) URLs.
     - `NativeWebSearchSources.selection(linksAreCitations: true)` puts the
       answer's links first, as the citations, and then any explicit
       citations.
     - The 8-source cap applies to provider sources only. Enigma's Brave
       sources merge uncapped, as in F32.
   - **Owner decisions from review round 1 (2026-10-29):**
     - A typed `/messages` turn, which includes Messages-panel sends, never
       gets provider search (`NativeToolPlan.make`). Its first chat read
       would restart the request and throw it away. This adds a condition
       to spec §1, which the spec doesn't yet say. **Proposed spec change:**
       add "and `/messages` wasn't typed" to §1's `providerSearch`
       conditions.
     - CP1 builds spec §5's footer. It's recorded on the reply's
       session-only `ReplyOrigin`, so a provider-search reply reopened
       after a relaunch shows the footer without a model or place, and
       still says "brave search". That's the same gap F32 has for the model
       name.
   - **The location card:**
     - It's asked once per turn, before the run loop. The restart's and the
       fallback's second runs have no provider search, so the location
       isn't sent again.
     - The area's region comes from `cityWithContext` ("Cupertino, CA" gives
       "CA"), since MapKit 26 has no separate state field. The country code
       comes from `addressRepresentations.region`.
     - The country is shown by its English name.
     - The grant saves the provider, never the area.
4. **Verification** (the worktree; final numbers are in the progress log):
   - `scripts/verify-xcode.sh test` with one `-only-testing:EnigmaTests/<Class>`
     per class. These are class names; `MessagesTests` and
     `CloudToolStreamingTests` are file names and select nothing. The
     classes: NativeWebSearchTests, NativeToolPlanTests,
     NativeToolRequestTests, NativeToolPartsTests, ToolPermissionTests,
     RequestLifecycleTests, WebSearchTests, EnigmaConversationTests,
     MessagesToolsTests, MessagesRequestTests, MessagesCoordinatorTests,
     MessagesSenderTests, MessagesDatabaseTests, CloudToolLoopTests,
     ClaudeCodeToolModeTests, OpenAIToolStreamAssemblerTests,
     AnthropicToolStreamAssemblerTests, GeminiToolStreamAssemblerTests,
     CloudToolStreamPostTests and LocalToolStreamingTests. After review
     round 2: 411 executed, 0 failed, 1 skipped (the opt-in
     `testScreenshots`).
   - `build` succeeded, and `analyze` succeeded with no warnings in CP1's
     files.
   - Mutation checks, all reverted. Each made a test fail:
     - the gate not throwing fails the restart tests;
     - swallowing the throw for search hits or previews fails
       `testSearchHitsAndPreviewsRestartToo` and
       `testProviderSearchRestartHoldsEveryReadBack`;
     - keying the location grant by `ToolDestination` fails
       `testLocationGrantIsPerProvider`;
     - a fresh ledger per run fails `testRestartDoesNotSendTwice`.
   - After review round 3, the affected classes: 336 executed, 0 failed,
     1 skipped.
   - **Full suite** (`scripts/verify-xcode.sh test`, once, before the
     commit): 1591 executed, 28 skipped, 1 failed. The failure was
     `EnigmaMainWindowTests.testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`,
     a key-window timeout.
     - It failed twice more when rerun alone right after the suite, then
       passed 4 times in a row.
     - e0a0aca, exported from git, passed it 4 times too.
     - Its fixture runs with native tools off, and CP1 changes nothing on
       its path (composer, queue, `submit`), so this is a focus or timing
       flake, as the workflow's "Unreliable failures" note describes.
   - **Known flake, not caused by CP1:**
     `EnigmaConversationTests.testCharacterFallsIntoTheFirstReplyFollowsTheRequestAndMovesToTheNewestReply`
     can time out in whole-class runs, on e0a0aca too. It passes alone.
5. **Limitations:**
   - No provider is on, so none of this is reachable in the app yet.
   - The card's copy and icon weren't checked in the running app.
   - `LocationService`'s new geocode fields are covered only through the
     pure `region(...)` helper and `ApproximateLocation`. The live MapKit
     path needs a person to check it.
6. **For the next checkpoint:**
   - A provider-search request has `request.providerSearch != nil`. Its
     `location` is set only after the user's grant; send it as spec §2a's
     table says.
   - The toolbox's instructions already hold the provider-search
     instruction. Don't add another.
   - Throw `CloudProviderError.webSearchUnavailable(<provider>)` before the
     first text or tool call to get the fallback.
   - Emit `.activity(.sourcesSelected(collector.selection(...)))` before
     `.completed`, and also before rethrowing any error once text or a
     search result has arrived. Spec §6 step 5 and the Failure-handling
     table save the sources so far even when the stream fails.
     `submitNative` merges and caps them; before a restart or fallback
     error they're harmless, since the reply is cleared. **Proposed brief
     change (CP2–CP5):** add this to each brief's stream task, and test
     that a failure after a search keeps its sources.
   - A Messages read in a provider-search request ends the request with
     `ProviderSearchRestart`, the terminal result's stop error. The API
     loops already throw it, and `ClaudeCodeToolMode.respond` throws it.
   - `CodexToolMode.handle` still answers the call with `result.codex`
     (fixed text, no message text) and records only `.messages` stops. CP4
     must record `.restart` and interrupt the turn (CP0 Q0).
   - Test support: `ScriptedSearchProvider(runs:)` with
     `.token / .activity / .call / .fail / .hang`, its `runs` and
     `delivered`, and `beforeStop`. In `NativeToolRequestTests`,
     `makeChat(nativeWebSearchProviders:hasSearchKey:locationProvider:)`
     and `NativeLocation`.
