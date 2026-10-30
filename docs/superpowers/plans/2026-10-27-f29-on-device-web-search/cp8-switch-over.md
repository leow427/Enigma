# CP8: Switch-over — on-device by default, Brave removed

> *Amended (owner approved 2026-10-30), D128:* CP7's gate failed, and the owner chose on-device
> search as the default for everyone, with Brave used **only when a Brave key is saved**. Brave's
> client and key storage stay; the Debug switch is replaced by the key rule (D129); the launch-time
> Keychain cleanup is dropped (D134); Settings shows on-device as the default with Brave as an
> optional extra (D133); the welcome's Brave field goes. Labels name the provider actually used
> (D131); blocked sites also filter Brave's results (D132); Brave gets only the city (D136). The
> exit criterion on `grep -i brave` no longer applies. Tasks below are amended where they differ.

Read [agent-workflow.md](agent-workflow.md), the spec (§7 "Brave key
cleanup", §8, "Failure handling"), and the Hand-offs of CP5 to
[CP7](cp7-evaluation.md#hand-off). **Start only if CP7's gate passed.** Its
report is in `docs/history/`.

## Goal

Every route uses on-device search, and Brave is gone: its client, key, Debug
switch, settings, welcome field and wording. On first launch the old key is
deleted from the Keychain. Settings gets the new Web search section, and
sources get "Never use this site". Capable models get `web_search`,
`find_places` and `get_weather` with no key, and F30's provider search gets
the blocked sites.

## Starting point

**Where Brave and the key still appear:**

| Place | What's there |
| --- | --- |
| `Enigma/Search/BraveSearchClient.swift` | The client, plus `BraveRedirectBlocker`. Its project entries are `B60000000000000000000101` (build file) and `B60000000000000000000001` (reference, in the `Search` group `B60000000000000000000301` and the Sources phase) |
| `Enigma/Search/WebSearchSettings.swift` | `WebSearchCredentialStore`, `KeychainSearchCredentialStore` (service `com.leow427.AISpotlight.web-search`, account `brave`), `hasAPIKey`, `saveAPIKey`, `removeAPIKey` and `canSaveAPIKey` |
| `Enigma/Search/WebSearchSettingsSection.swift` | The "Web search · Brave" section |
| `Enigma/App/SlashCommand.swift:30` | `available(hasSearchKey:)`, called from `AppShellView.swift:207` and `:812` |
| `Enigma/App/KeyboardShortcutsHelpView.swift:106` | Shows the search rows only when there's a key |
| `Enigma/App/WelcomeSetupView.swift`, lines ~24–28, 101 and 405–440 | The Brave field, its link, and the character's reaction to typing in it |
| `Enigma/App/SettingsView.swift:287` | `locationExplanation` |
| `Enigma/App/EnigmaMainWindowLogic.swift:518` | `searchNote` |
| `Enigma/Chat/AutoRouter.swift:32` | The Brave message |
| `Enigma/Chat/EnigmaConversationLogic.swift:170` | "brave search" in the reply footer |
| `Enigma/App/EnigmaControls.swift:1990` | The gallery placeholder |
| `OnDeviceSearch.swift` | `WebSearchProviderFactory` and its Debug key |

**Added since this brief was first written (F32, F30, CP5–CP6):**

| Place | What's there |
| --- | --- |
| `Enigma/Chat/AssistantToolbox.swift` | `NativeToolPlan.Inputs.hasSearchKey`, which gates the search part |
| `LocalChatViewModel.nativeToolPlan(for:…)` | Fills `hasSearchKey` from the settings |
| `LocalChatViewModel.submitNative` | Builds F30's `ProviderSearch` with empty `blockedDomains` |
| `Enigma/Cloud/NativeWebSearch.swift` | `ProviderSearchPart(blockedDomains:)`; F30's instruction sentence for blocked sites |
| `Enigma/Cloud/CloudToolCalling.swift` | `AnthropicMessagesClient.webSearchTool(modelID:blockedDomains:)` and its limit |
| `docs/Slash-Commands.md`, `docs/Web-Search.md` | F32's and F30's "without a key" notes (CP10 rewrites them) |
| `SlashCommand.swift` | `/maps` (CP6), offered under the same key rule as `/search` until now |

**Tests that mention Brave or the key:** `WebSearchTests` (about 20),
`EnigmaSettingsTests` (24), `EnigmaWelcomeTests` (12), `ScreenViewTests`,
`ScreenPipelineTests`, `ScreenNativeSmokeTests`, `EnigmaMainWindowTests`,
`ScreenCaptureTests`, `EnigmaCompactPanelTests`, `EnigmaConversationTests`,
`CodexSubscriptionTests`, `ClaudeCodeSubscriptionTests` and
`LocalModelSelectionTests`.

**References that stay:** `SelectionContextService`'s `com.brave.Browser`
bundle IDs, and their tests in `SelectionContextTests`. They're about the
Brave browser, not search.

## Tasks

### Task 8.1: On-device by default; remove the client and key code

**Files:**

- Delete `Enigma/Search/BraveSearchClient.swift`, and its project entries.
- Modify `WebSearch.swift` (errors), `WebSearchSettings.swift`,
  `OnDeviceSearch.swift` (remove `WebSearchProviderFactory`),
  `LocalChatViewModel.swift`, and the app's launch code. Find where other
  one-time launch work runs (search for `applicationDidFinishLaunching`).
- Tests: `WebSearchTests` and the classes listed above.

**Interfaces.** This task produces:

```swift
// LocalChatViewModel: init(... webSearch: any WebSearchProvider = OnDeviceSearchProvider.live(), ...); .shared uses it too.
// OnDeviceSearchProvider.live(): when TestHost.isActive, builds a provider whose HTTP client fails every
//   request at once, so no test can reach the network by accident.
enum WebSearchError: LocalizedError, Equatable {
  case rateLimited, unavailable, invalidResponse, noResults, contextTooSmall, emptyQuery   // missingAPIKey, invalidAPIKey and requestFailed removed
}
// WebSearchSettings: no key API. canSearchAutomatically == automaticallySearch.
enum BraveKeyCleanup {                       // in WebSearchSettings.swift
  static let doneKey = "webSearch.braveKeyRemoved"
  @MainActor static func runOnce(defaults: UserDefaults, remove: () throws -> Void)
}
```

**The evaluation after Brave.** `WebSearchEvaluationTests` drops its Brave
run and the `ENIGMA_BRAVE_KEY` variable, and runs on-device only. CP7's
script already handles on-device-only output: it reports the source and
speed metrics, and skips the judge.

**The error messages,** exactly. Each is followed by " Your draft has been
kept.", as today:

| Case | Message |
| --- | --- |
| `unavailable` | "Search sites couldn't be reached. Check your connection and try again." |
| `rateLimited` | "Search sites are limiting requests right now. Try again shortly." |
| `noResults` | "No usable sources were found. Try a more specific question." |

*Amended (owner approved 2026-10-30), D128, D130, D134:* the client, `WebSearchCredentialStore`,
`KeychainSearchCredentialStore` and the key API stay; `missingAPIKey`, `invalidAPIKey` and
`requestFailed` stay for Brave only, and `BraveKeyCleanup` isn't built. A saved key selects
Brave at each search (`LocalChatViewModel.braveSearch`, D129).

**The cleanup at launch** (*dropped, D134*):

- It's skipped when `TestHost.isActive`.
- It calls
  `KeychainCredentialStore(service: "com.leow427.AISpotlight.web-search").removeAPIKey(account: "brave")`
  through `runOnce`.
- `runOnce` sets `doneKey` after a successful removal, and also when there
  was no item. After a failure it tries again at the next launch.

**Steps:**

- [ ] **Write the failing tests:**
  - `testBraveKeyCleanupRunsOnce`: the fake `remove` is called once over
    two launches, and the flag is set;
  - `testBraveKeyCleanupRetriesAfterFailure`;
  - `testErrorMessages`: the exact strings above;
  - `testSearchWorksWithoutAnySetup`: a fresh `WebSearchSettings` on an
    empty suite has `canSearchAutomatically == true`, and `/search` reaches
    the provider.
- [ ] **Retarget the Brave tests.** Every test that checked Brave's wire
  format, key storage, or behavior without a key is either:
  - covered by an existing on-device test (CP2–CP6), or
  - rewritten to check the same user-facing behavior with no key.

  Put the mapping table (old test → replacement) in your Hand-off.
- [ ] **Run** `WebSearchTests`. Expect failures.
- [ ] **Implement:** delete the Brave code, change the default, add the
  cleanup and the launch call.
- [ ] **Run** `WebSearchTests`, `ScreenViewTests`, `ScreenPipelineTests` and
  `ScreenNativeSmokeTests`. Expect them to pass.

### Task 8.2: `/search` is always available

**Files:** `SlashCommand.swift`, `AppShellView.swift`,
`KeyboardShortcutsHelpView.swift`, and their tests.

**Interfaces.** This task produces `static func available() -> [SlashCommand]`,
which always includes `.search` and `.maps`. `NativeToolPlan.Inputs` loses
`hasSearchKey`: the search part (and with it `find_places` and
`get_weather`) is offered whenever automatic search is on or `/search` or
`/maps` is typed. Retarget `NativeToolPlanTests`' key rows to that rule.

**Steps:**

- [ ] **Retarget the tests** that passed `hasSearchKey: false` or `true`
  (`ScreenCaptureTests:525,531`, `EnigmaCompactPanelTests:48`,
  `EnigmaMainWindowTests:199,201,601`, `EnigmaWelcomeTests:293`). They now
  assert that `/search` and its examples are always offered.
- [ ] **Run** those classes. Expect compile failures.
- [ ] **Implement:** remove the parameter, and show the Help search rows
  unconditionally.
- [ ] **Run** those classes. Expect them to pass.

### Task 8.3: The Settings section

*Amended (owner approved 2026-10-30), D133, D136:* after the status row, an optional
"Use Brave Search instead" row with the key field, Save key and Remove key; the status row reads
"Brave in use" when a key is saved. The note names the kept lineup, and the cloud-search sentence
names ChatGPT and Claude Code.

**Files:** rewrite `Enigma/Search/WebSearchSettingsSection.swift`. Tests go
in `EnigmaSettingsTests`.

**Content,** exactly as spec §8 gives it, built from `EnigmaSectionHeader`,
`EnigmaRow`, `EnigmaSwitch`, `EnigmaStatusLine`, `EnigmaNote` and the `.text`
button style:

1. **Header:** "Web search".
2. **The automatic switch,** with the subtitle "On by default. Questions
   about news, recent events and changing facts search automatically, in
   every mode. Turn this off to search only when you type /search."
3. **A status row:** "Web search", subtitle "Runs on this Mac. No account or
   key needed.", status `.on` with the text "ready".
4. **"Blocked sites":** one row per domain, with **Remove**, which calls
   `unblock`. When the list is empty, show the note "Use Never use this site
   in a reply's sources to stop Enigma using a site."
5. **The note:** "Queries go to DuckDuckGo, Mojeek and Wikipedia, and to
   Startpage when DuckDuckGo is unavailable. Up to six result pages are read
   on this Mac without scripts or images. Weather comes from Open-Meteo and
   nearby places from Apple Maps."

**Steps:**

- [ ] **Write the failing tests:**
  - `testWebSearchSectionText`: the strings above;
  - `testBlockedSitesListAndRemove`: two domains show two rows, and Remove
    empties the list;
  - snapshots in Paper and Ink, empty and with two blocked sites.

  Retarget `EnigmaSettingsTests`' Brave assertions to the new section.
- [ ] **Run** `EnigmaSettingsTests`. Expect failures.
- [ ] **Implement** the section.
- [ ] **Run** `EnigmaSettingsTests`. Expect it to pass. Look at your
  snapshots against `docs/design/UI-Style.md`.

### Task 8.4: The welcome row

**Files:** `WelcomeSetupView.swift`. Tests go in `EnigmaWelcomeTests`.

**Content:**

- `EnigmaRow("Web search", subtitle: "Used by /search and automatic search, with sources listed.")`,
  holding `EnigmaStatusLine(.on, "ready · no setup needed")`.
- Remove the key field, "Get a Brave API key", `saveBraveKey`, and the
  character's reaction to that field. Keep any shared typing state that other
  fields use.

**Steps:**

- [ ] **Retarget** the welcome tests to the row above.
- [ ] **Run** `EnigmaWelcomeTests`. Expect failures.
- [ ] **Implement** the row.
- [ ] **Run** `EnigmaWelcomeTests`. Expect it to pass.

### Task 8.5: "Never use this site"

**Files:**

- `Enigma/Chat/AssistantActivityView.swift` (`ActivitySourceRow`);
- `Enigma/Chat/AssistantActivity.swift` (`WebSearchSource.allowsBlocking`);
- `WebSearchSettings.swift`;
- `AppShellView.swift`, which sets the environment for both the main window
  and the compact panel.
- Tests go in `EnigmaConversationTests` and `WebSearchTests`.

**Interfaces.** This task produces:

```swift
extension WebSearchSource { var allowsBlocking: Bool { get } }   // false for maps.apple.com and open-meteo.com
struct SourceBlocking {
  var domain: @MainActor (URL) -> String       // the registrable domain, the same rule as block(_:)
  var block: @MainActor (URL) -> Void
  var unblock: @MainActor (String) -> Void
}
extension EnvironmentValues { @Entry var sourceBlocking: SourceBlocking? = nil }
```

**Behavior,** from spec §8:

- A web source row has a context-menu item, "Never use <domain>", which is
  also an accessibility action with the same name.
- After it's chosen, the row's detail line reads `<site> · blocked`, and an
  **Undo** text button appears. That row state lasts until the panel closes.
- Rows whose `allowsBlocking` is false, and rows with no `sourceBlocking` in
  the environment, show no action.

**Steps:**

- [ ] **Write the failing tests:**
  - `testNeverUseLabel`: "Never use bbc.co.uk" for `https://news.bbc.co.uk/x`;
  - `testNoBlockActionForAppleMapsOrOpenMeteo`;
  - `testBlockThenUndoRestores`;
  - a snapshot of a blocked row, in Paper and Ink.
- [ ] **Run** those classes. Expect failures.
- [ ] **Implement** the action, the blocked state and the environment.
- [ ] **Run** them again. Expect them to pass.

### Task 8.5b: Blocked sites for cloud models' own search (F30)

**Files:** `LocalChatViewModel.swift` (`submitNative`), `WebSearchSettings.swift`,
`WebSearchSettingsSection.swift`. Tests in `NativeToolRequestTests`,
`EnigmaSettingsTests`.

- [ ] **Write the failing tests:**
  - `testProviderSearchCarriesBlockedSites`: with three blocked domains,
    `request.providerSearch.blockedDomains` lists them most recent first;
    `ProviderSearchPart`'s instruction names them (OpenAI, Codex, Claude
    Code) and Anthropic's tool sends them as `blocked_domains` within its
    limit (F30's existing tests for the cut stay green).
  - `testBlockedSitesNoteMentionsCloudSearch`: the Settings list shows spec
    §8's sentence about cloud models' own search.
- [ ] **Run, implement, run.**

### Task 8.6: Wording

*Amended (owner approved 2026-10-30), D131:* the footer says "brave search" when Brave answered
(a key was saved) and "web search" otherwise; gate 3's card names Brave or "search sites".

**Files:** the five places listed in spec §8's wording table, plus
`EnigmaConversationLogic.swift:170`, and their tests (`AutoRouterTests`,
`EnigmaConversationTests`, `EnigmaMainWindowTests`).

**Steps:**

- [ ] **Retarget the tests** to the spec's exact strings. The footer becomes
  "web search".
- [ ] **Run** those classes. Expect failures.
- [ ] **Change the strings.**
- [ ] **Run** them again. Expect them to pass.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass (the full
  `test` once, before the commit).
- [ ] The Settings note names the sites CP0b's lineup kept, and F30's
  sentence about cloud models' own search.
- [ ] `grep -rni brave Enigma EnigmaTests` lists only these:
  - `BraveKeyCleanup` and its tests;
  - the `com.brave.Browser` bundle IDs and their tests;
  - the cleanup's Keychain service string.
- [ ] **A manual check in a signed build**, by the owner with the worker:
  - the welcome shows "Web search · ready";
  - Settings shows the new section;
  - a search with each route works, on a small and a capable model, with no
    key: web, places and weather;
  - "Never use this site" and Undo work;
  - the old Brave key is gone from Keychain Access after launch.

## Reviewer checklist

- **No path still needs a key,** and no dead key UI or plumbing is left.
- **The cleanup** runs once, never in the test host, and retries after a
  failure.
- **Every retargeted test** still checks the same user-facing behavior.
  Check the Hand-off's mapping table.
- **"Never use this site"** never blocks Apple Maps or Open-Meteo, and the
  action is reachable with VoiceOver.
- **The UI** follows `docs/design/UI-Style.md` and reuses the shared
  controls.

## Hand-off

*Filled in by the CP8 worker, 2026-10-30. Decisions D128–D137 in
[overnight-decisions.md](overnight-decisions.md).*

1. **Summary:** built under the owner's D128, not the original removal. On-device search is
   the default for everyone: `/search`, `/maps`, automatic search and capable models'
   `web_search`, `find_places` and `get_weather` need no key (`hasSearchKey`,
   `available(hasSearchKey:)` and the Help gate are gone; `canSearchAutomatically ==
   automaticallySearch`). Brave runs only while a Brave key is saved: `LocalChatViewModel`
   holds `webSearch` (on-device) and an optional `braveSearch` (set in `.shared` only) and
   picks per search, so saving or removing a key takes effect on the next search (D129).
   `WebSearchProviderFactory` and its Debug key are gone; no Keychain cleanup (D134). Brave's
   results are filtered by the blocked sites (D132), Brave gets only the city (D136), and a key
   deleted outside Enigma falls back to on-device (D130). Settings' Web search section, the
   welcome row, "Never use this site" with Undo, blocked sites for F30's provider search, the
   brief's error messages and the wording are in. Labels name the provider used: footer
   "brave search" or "web search", gate 3 "Brave" or "search sites" (D131).
   Review round 1 (no Blocker): Brave answers web searches only, places and weather stay on
   Apple Maps and Open-Meteo (D138); `live(offline:)` is the seam for live tests, and the view
   model's places and weather defaults are offline in the test host (D139); F30's evaluation
   injects Brave with its key; Brave's own failures name Brave; a missing key refreshes the
   saved-key state; the search reports which provider ran (D141); the Settings note reads
   "up to six at a time" (D142).
2. **Files:**
   - Search: `WebSearch.swift` (messages), `WebSearchSettings.swift` (`canSearchAutomatically`,
     `domain(of:)`, `isBlocked(_:)`, `blockedDomainsMostRecentFirst`),
     `WebSearchSettingsSection.swift` (rewritten), `OnDeviceSearch.swift` (factory removed,
     `OfflineSearchHTTPClient`, test-host `live()`), `BraveSearchClient.swift` (city only).
   - Chat: `AssistantToolbox.swift` (no `hasSearchKey`), `AssistantActivity.swift`
     (`allowsBlocking`, `SourceBlocking`), `AssistantActivityView.swift` (`sourceBlocking`
     environment; the row's action, blocked state and Undo), `ChatDomain.swift`
     (`ReplyOrigin.braveSearch`), `EnigmaConversationLogic.swift` (footer), `AutoRouter.swift`,
     `ToolPermissions.swift` / `ToolPermissionCoordinator.swift` (gate 3's service).
   - App: `SlashCommand.swift` (`available()`), `AppShellView.swift` (environment, commands,
     Help), `KeyboardShortcutsHelpView.swift`, `WelcomeSetupView.swift` / `WelcomeSetup.swift`
     (row; key field and listening state removed), `SettingsView.swift`
     (`locationExplanation`), `EnigmaMainWindowLogic.swift` (`searchNote`),
     `EnigmaControls.swift` (gallery placeholder).
   - `LocalInference/LocalChatViewModel.swift`: two providers and the choice, Brave filter and
     fallback, footer record, blocked domains to `ProviderSearch` and `ProviderSearchPart`,
     gate 3's service, `WebSearchLimits.evidenceTokens`.
   - `Screen/ScreenPromptContext.swift`: comments only.
   - Tests: `WebSearchTests`, `NativeToolPlanTests`, `NativeToolRequestTests`,
     `EnigmaSettingsTests`, `EnigmaWelcomeTests`, `EnigmaConversationTests`,
     `EnigmaMainWindowTests`, `ScreenViewTests`, `ScreenCaptureTests`,
     `EnigmaCompactPanelTests`, `ComposerIntentTests`, `ToolPermissionTests`,
     `ScreenNativeSmokeTests`.
   - Docs: this brief, the spec (§7, §8) and the plan (interface map, progress) amended;
     decisions D129–D137.
3. **Decisions:** D128 (owner), D129 (the choice in the view model), D130 (errors;
   `missingAPIKey` stays for Brave, falls back to on-device), D131 (labels), D132 (Brave
   filter), D133 (Settings and welcome text), D134 (no cleanup), D135 (no worker review
   round), D136 (Brave city only; the cloud-search sentence), D137 (smaller choices); review
   round 1: D138 (Brave for web searches only), D139 (online seam, offline defaults),
   D140 (one round), D141 (nits), D142 (reading sentence, spec table), D143 (tests).
   `WebSearchEvaluationTests` keeps its opt-in Brave comparison, unchanged.

   **Test mapping (old → replacement):**

   | Old test | Replacement |
   | --- | --- |
   | `WebSearchTests.testAutomaticSearchSettingsPersistAndRequireAKey` | `testAutomaticSearchSettingsPersistAndNeedNoKey` (+ new `testSearchWorksWithoutAnySetup`) |
   | `WebSearchTests.testAutomaticSearchOffAndMissingKeyStillAllowForcedSearch` | `testAutomaticSearchOffStillAllowsForcedSearch` (no key now searches automatically) |
   | `WebSearchTests.testActualComposersRequireKeyForAutomaticSearchAndSearchSuggestions` | `testActualComposersNeedNoKeyForAutomaticSearchAndSearchSuggestions` |
   | `WebSearchTests.testDebugSwitchSelectsOnDeviceProvider`, `testBraveRemainsDefault` | `testBraveRunsOnlyWithASavedKey`, `testBraveMissingKeyFallsBackToOnDevice` |
   | `WebSearchTests.testBraveAppendsLocationFromRequest` | same name, city only (D136) |
   | `WebSearchTests.testBraveUsesUnknownAreaWithoutCity` | `testBraveSendsNoCoordinatesWithoutCity` |
   | Brave wire format, key storage, HTTP errors (`testBraveRequestAndGenericPOIMapResponse`, `testMissingCredential…`, `testEmptyMalformedAndOfflineResponses`, `testCredentialSaveAndRemoval`) | unchanged: Brave stays |
   | `NativeToolPlanTests.testPlanTable`, `testSearchBackend` | key loops kept; the plan no longer depends on the key |
   | `NativeToolPlanTests.testRemadeWithoutProviderSearch` (keyless remake has no search) | remake with nothing asking for search has none; keyless remake gets `.search(.enigma)` |
   | `NativeToolPlanTests.testPlacesAndWeatherOfferedWithSearch` (no key → nothing) | no key → search, places and weather |
   | `NativeToolPlanTests.testMapsRequiresFindPlaces` (`key: false`) | key parameter removed |
   | `NativeToolRequestTests.testProviderSearchNeedsNoKey` (no key → no `web_search`) | no key → Enigma's `web_search` |
   | `NativeToolRequestTests.testUnavailableFallbackWithoutKeyHasNoSearch` | `testUnavailableFallbackWithoutKeyUsesOnDeviceSearch` |
   | `ScreenCaptureTests` (`available(hasSearchKey:)`) | a list without `/search` stands in for the changed menu |
   | `ComposerIntentTests` (`/maps` only with a key) | `/maps` and `/search` always |
   | `EnigmaMainWindowTests.testCommandExamplesFollowTheAvailableCommands`, the `/` button test | `available()`; the no-search examples use an explicit list |
   | `EnigmaCompactPanelTests:48`, `EnigmaWelcomeTests` tour card | `available()` |
   | `EnigmaWelcomeTests.testReturnInTheKeyFieldSavesTheKeyAndStaysOnConnections`, `testFailedKeySaveShowsTheErrorAndTheCharactersErrorState` | `testConnectionsStepShowsWebSearchReadyWithNoKeyField` (key-save errors stay covered by `EnigmaSettingsTests.testFailedBraveKeySaveShowsTheError`) |
   | `EnigmaWelcomeTests.testCharacterThinksListensAndShowsErrorsOnTheRightSteps` (listening) | idle on connections; errors still outrank |
   | `EnigmaSettingsTests.testFailedBraveKeySaveShowsTheError` ("no key") | "not used", and on-device stays "ready" |
   | `EnigmaConversationTests` footer ("brave search" without provider search) | "web search"; "brave search" only with `braveSearch` |
   | `ScreenViewTests.testRepeatedScreenSubmissionsKeepFullPanelInsideWindow` (no search without a key) | every command offered; "search the web" visible |
   | `ScreenViewTests.testAutoLimitationInThePanelOpensTheDetailsWithTheProblem` | automatic search off, the pre-CP8 condition |
   | `ToolPermissionTests.testCardCopy` ("sent to Brave") | "sent to search sites"; "Brave" with the service |
   | `ScreenNativeSmokeTests` (opt-in) footer | "web search" |

   **New tests:** `WebSearchTests.testErrorMessages`, `testSearchWorksWithoutAnySetup`,
   `testBraveRunsOnlyWithASavedKey`, `testBlockedSitesFilterBravesResults`,
   `testBraveMissingKeyFallsBackToOnDevice`, `testNeverUseLabel`,
   `testNoBlockActionForAppleMapsOrOpenMeteo`, `testBlockThenUndoRestores`;
   `NativeToolRequestTests.testProviderSearchCarriesBlockedSites`;
   `EnigmaSettingsTests.testWebSearchSectionText`, `testBlockedSitesListAndRemove`,
   `testBlockedSitesNoteMentionsCloudSearch`, `testSaveWebSearchSectionScreenshots` (Paper
   and Ink, empty and two sites; skipped without `ENIGMA_SNAPSHOT_DIR`).
4. **Verification** (logs in `/private/tmp/claude-501/f29-cp8/`):
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded.
   - Non-UI classes (`WebSearchTests`, `NativeToolPlanTests`, `NativeToolRequestTests`,
     `NativeWebSearchTests`, `NativeToolsTests`, `ComposerIntentTests`, `ToolPermissionTests`,
     `PlacesAndWeatherToolTests`, `NativeToolsEvalTests`, `OnDeviceSearchTests`,
     `ScreenPipelineTests`, `ScreenNativeSmokeTests`, `CodexSubscriptionTests`,
     `ClaudeCodeSubscriptionTests`, `LocalModelSelectionTests`): 475 executed, 4 skipped; the
     12 failures (gate 3 copy and the new view-model tests' submit form) fixed, then
     `WebSearchTests` + `ToolPermissionTests` 109 executed, 0 failed.
   - Hosted UI classes (`EnigmaSettingsTests`, `EnigmaWelcomeTests`, `ScreenViewTests`,
     `EnigmaMainWindowTests`, `ScreenCaptureTests`, `EnigmaCompactPanelTests`,
     `EnigmaConversationTests`): 245 executed, 6 skipped, 7 failed (6 `ScreenViewTests`
     assertions on "no search without a key", retargeted; 1 `EnigmaMainWindowTests` send-now
     wait); then `ScreenViewTests` with that `EnigmaMainWindowTests` test: 36 executed,
     0 failed. `ScreenViewTests`' 15 s burst wait (8626f32) is unchanged.
   - Further classes (`AutoRouterTests`, `EnigmaControlsTests`, `ScreenNativeSmokeTests`,
     `ScreenPipelineTests`, `EnigmaConversationTests`, `SourceQualityTests`,
     `MessagesToolCallingTests`, `RequestLifecycleTests`, `SubscriptionModelRefreshTests`,
     `CloudModeTests`, `WebSearchEvaluationTests`, `NativeWebSearchEvaluationTests`,
     `PlacesAndWeatherTests`, `SearchFactsAndNewsTests`): 251 executed, 5 skipped, 0 failed.
   - Not run: the full suite (the orchestrator's), live runs (none needed).
   - **After review round 1** (D138–D143): `WebSearchTests`, `ToolPermissionTests`,
     `NativeToolRequestTests`, `NativeToolPlanTests`, `WebSearchLiveTests`,
     `NativeWebSearchEvaluationTests`, `NativeWebSearchLiveTests`, `ScreenNativeSmokeTests`,
     `SearchAssistTests`, `PlacesAndWeatherToolTests`, `OnDeviceSearchTests`: 306 executed,
     12 skipped (opt-in live), 0 failed. Mutants "Brave for every route" and "gate 3 always
     says search sites" each fail their new test. No UI class rerun (only the Settings note
     string changed).
5. **Limitations:**
   - No review round yet (D135). The manual check in a signed build (welcome "Web search ·
     ready", Settings section, keyless searches on small and capable models, "Never use this
     site" and Undo, Brave with a saved key) is the owner's.
   - "Never use this site" is a context-menu item and an accessibility action; the hosted
     tests check the model (`SourceBlocking`), not the context menu itself.
   - `docs/Web-Search.md` and `docs/Slash-Commands.md` still describe the key; CP10 rewrites
     them.
   - Snapshot images weren't generated or looked at (no `ENIGMA_SNAPSHOT_DIR`).
   - The row's Undo state lives in its `@State` (known, not fixed, per the review).
6. **For the next checkpoint:**
   - `LocalChatViewModel(webSearch:braveSearch:)`: tests inject only `webSearch` and never
     reach Brave; inject `braveSearch` to test the key rule.
   - `ReplyOrigin.braveSearch` is session-only, like `providerSearch`.
   - `SourceBlocking(settings:)` is set once in `AppShellView.body`; CP9's map card rows
     shouldn't offer blocking (Apple Maps, `allowsBlocking` false).
