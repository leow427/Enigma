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

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
