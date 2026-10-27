# CP8: Switch-over — on-device by default, Brave removed

Read [agent-workflow.md](agent-workflow.md), the spec (§7 "Brave key
cleanup", §8, "Failure handling"), and the Hand-offs of CP5 to
[CP7](cp7-evaluation.md#hand-off). **Start only if CP7's gate passed.** Its
report is in `docs/history/`.

## Goal

Every route uses on-device search, and Brave is gone: its client, key, Debug
switch, settings, welcome field and wording. On first launch the old key is
deleted from the Keychain. Settings gets the new Web search section, and
sources get "Never use this site".

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

**The cleanup at launch:**

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
which always includes `.search`.

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

### Task 8.6: Wording

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

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- [ ] `grep -rni brave Enigma EnigmaTests` lists only these:
  - `BraveKeyCleanup` and its tests;
  - the `com.brave.Browser` bundle IDs and their tests;
  - the cleanup's Keychain service string.
- [ ] **A manual check in a signed build**, by the owner with the worker:
  - the welcome shows "Web search · ready";
  - Settings shows the new section;
  - a search with each route works;
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

*Filled in by the CP8 worker, including the old test → replacement mapping
table.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
