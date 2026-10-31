# F14 Welcome, Tour and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the owner-approved F14 spike (welcome setup, hands-on tour, new Settings, custom shortcuts) on `main` properly: its own files, final names, the gaps closed, tests green, docs rewritten.

**Architecture:** Port the spike's diff onto `feat/f14-welcome-settings` in one commit, then restructure it into focused files, close the seven gaps the spec lists, and rewrite the tests the spike broke. The spike branch `spike/f14-welcome` (927c2d3) is the reference for any look or behaviour this plan doesn't spell out.

**Tech Stack:** Swift 6, SwiftUI + AppKit, macOS 26, XCTest with `EnigmaSnapshot`; `scripts/verify-xcode.sh` for build and tests.

**Spec:** `docs/superpowers/specs/2026-10-31-f14-welcome-and-settings-design.md`

## Global Constraints

- Worktree `/private/tmp/claude-501/enigma-f14`, branch `feat/f14-welcome-settings`, based on `origin/main` 234d6cd.
- Build: `scripts/verify-xcode.sh build`. Tests: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>[/<test>]`. Full suite once, in Task 11 only.
- New Swift files must be added to `Enigma.xcodeproj/project.pbxproj` by hand (no synchronized groups): a `PBXFileReference`, a `PBXBuildFile`, the group's `children`, and the Enigma target's `PBXSourcesBuildPhase`, each with a fresh unique 24-hex ID, mirroring an existing file such as `WhatsNew.swift`.
- UserDefaults keys: `guidedTour.stop.v1`, `guidedTour.invite.v1`, `enigma.shortcuts.overrides.v1`, `enigma.shortcuts.selectionSameAsSummon.v1`. `welcomeSetup.step.v1` and `welcomeSetup.completed.v1` keep their meaning.
- The test host shares the app's defaults: anything that saves (tour progress, shortcuts, invite) must not write to `.standard` when `TestHost.isActive`.
- Settings uses SF Pro only (`EnigmaTypography.ui`); the chat keeps its mono.
- No "spike" in any identifier, key or comment when Task 2 is done.
- Commits are authored by the owner's git identity, with no attribution lines. Check `git status` before each commit; nothing from `.claude/`, CLAUDE files or scratch.
- Version shipping F14: 0.13.0.

## Review Focus

1. **Leaving the tour mid-stop** (Esc, Skip, closing the window, ⌘N outside the new-chat stop, quitting) → the window returns to its normal size and the Shmoogle Docs window closes; nothing stays faded or offscreen. Test: Task 9.
2. **Selection stop with Enigma's window hidden or on another Space** → the panel still opens under the pretend document and the window comes back after. Test: Task 9 (`testLeavingTheSelectionStopBringsTheWindowBack`).
3. **A global shortcut that macOS or another app already owns** (Carbon registration fails) → its row says it couldn't be set and the old one keeps working. Test: Task 6.
4. **An existing user who updates mid-setup** (`welcomeSetup.step.v1` saved, not completed) → setup resumes; no invite until setup is done. Test: Task 3.
5. **Settings search for a word only in an ⓘ detail or an Advanced row** (for example "brave", "api key") → it still finds the page. Test: Task 9.

---

### Task 1: Port the spike in one commit

**Files:** every file in `git diff origin/main...spike/f14-welcome --stat` (25 files).

- [ ] **Step 1: Apply the spike's changes**

```bash
cd /private/tmp/claude-501/enigma-f14
git diff origin/main...origin/spike/f14-welcome -- Enigma EnigmaTests | git apply --index
```
Expected: no output; `git status` lists the 25 files as staged.

- [ ] **Step 2: Build**

Run: `scripts/verify-xcode.sh build` → `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Record the known failures**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaSettingsTests -only-testing:EnigmaTests/EnigmaMainWindowTests`.
Expected: exactly these fail, all rewritten in Task 4: `testAPIKeySavesToTheKeychainAndRemoves`, `testBlockedSitesListAndRemove`, `testDiscoverIsGoneAndItsOldNameOpensLocalModels`, `testFailedBraveKeySaveShowsTheError`, `testFailedConnectionTestShowsTheSameMessage`, `testFailedKeySaveShowsTheSameErrorAndKeepsTheKey`, `testUpdateSwitchesAndCheckNowReachTheUpdater`, `testWebSearchSectionText`, `testTourCardDrawsAboveTheCharacterAndTakesTheClickOnNext`, `testTourTargetsAreOnTheNewControls`.

- [ ] **Step 4: Commit**

```bash
git commit -m "Bring over the F14 spike: welcome, hands-on tour, new Settings and shortcuts"
```

### Task 2: Structure, names and dead code

**Files:**
- Create: `Enigma/App/GuidedTour.swift`, `Enigma/App/TourDocumentWindow.swift`, `Enigma/App/WelcomeTypewriter.swift`, `Enigma/App/SettingsPages.swift`, `Enigma/App/SettingsCards.swift`, `Enigma/App/ShortcutStore.swift`, `Enigma/App/ShortcutEditor.swift`
- Modify: `Enigma/App/WelcomeSetup.swift`, `WelcomeSetupView.swift`, `SettingsView.swift`, `EnigmaControls.swift`, `PanelShortcut.swift`, `KeyboardShortcutsHelpView.swift`, `AppShellView.swift`, `SpotlightPanelController.swift`, `Enigma.xcodeproj/project.pbxproj`
- Test: `EnigmaTests/AppCommandTests.swift`, `EnigmaTests/EnigmaWelcomeTests.swift`, `EnigmaTests/EnigmaSettingsTests.swift`

**Interfaces:**
- Produces: `GuidedTour.progressKey == "guidedTour.stop.v1"`; `ShortcutStore.overridesKey == "enigma.shortcuts.overrides.v1"`; `ShortcutStore.sameAsSummonKey == "enigma.shortcuts.selectionSameAsSummon.v1"`; `EnvironmentValues.enigmaSettingsStyle: Bool` (replaces `enigmaStrongDividers`). Every other type keeps its spike name and API.

- [ ] **Step 1: Write the failing test** in `AppCommandTests`

```swift
func testSavedKeysHaveTheirFinalNames() {
  XCTAssertEqual(GuidedTour.progressKey, "guidedTour.stop.v1")
  XCTAssertEqual(ShortcutStore.overridesKey, "enigma.shortcuts.overrides.v1")
  XCTAssertEqual(ShortcutStore.sameAsSummonKey, "enigma.shortcuts.selectionSameAsSummon.v1")
}
```

- [ ] **Step 2: Run it** → FAIL (keys end in `.spike`).

- [ ] **Step 3: Move code into the new files**, unchanged except for comments, per the spec's Structure table:
  - `GuidedTour.swift`: `GuidedTour`, `TourStep`, `TourDemo`, `TourScript`, `GuidedTourPlacement`, the rail card view and the `GuidedTour.Stop` extensions.
  - `TourDocumentWindow.swift`: `TourDocumentWindow`, `TourScene`, `ShmoogleDocsHeader`, `ShmoogleDocsLogo`, `ShmooglePage`, `ShmoogleFold`.
  - `WelcomeTypewriter.swift`: `WelcomeTypewriter`, `View.welcomePerch(_:character:)`.
  - `SettingsPages.swift`: `GeneralSettingsPage`, `SearchSettingsPage`, `SelectionSettingsPage`, `FilesSettingsPage`, `PermissionsSettingsPage`, `AboutSettingsPage`, `SettingsLink`, `SettingsAdvanced`, `ReplayWelcomeButton`.
  - `SettingsCards.swift`: `SettingsCardMark`, `SettingsCardMarks`, `View.settingsCardMark(_:at:if:)`, `View.settingsCards(inset:)`, `SettingsCardsBackground`.
  - `ShortcutStore.swift`: `KeyBinding`, `ShortcutAction`, `ShortcutStore`, `Notification.Name.commandShortcutPressed`.
  - `ShortcutEditor.swift`: `ShortcutEditor`, `ShortcutRecorder`.
  Add all seven to the pbxproj (Global Constraints).

- [ ] **Step 4: Rename** the three keys and `enigmaStrongDividers` → `enigmaSettingsStyle` (all uses). Rewrite every "F14 spike:" comment as a plain doc comment; drop "Not for main" and "throwaway" lines.

- [ ] **Step 5: Delete the six-stop tour**: `WelcomeTourStep` and its extensions, `welcomeTourTarget`, `WelcomeSetup.tour`, `WelcomeSetup.nextTourStep()`, the overlay that drew it in `AppShellView`, and tests that only covered it. Delete `ConnectionSettingsSheet`, `WelcomeSetupView.showConnections` and the `settings-connection-sheet` snapshot.

- [ ] **Step 6: Verify**

Run: `grep -rni "spike\|WelcomeTourStep\|ConnectionSettingsSheet\|enigmaStrongDividers" Enigma EnigmaTests` → no output.
Run: `scripts/verify-xcode.sh build` → succeeds; `testSavedKeysHaveTheirFinalNames` passes; the Task 1 failure list is unchanged (no new failures).

- [ ] **Step 7: Commit** — `git commit -m "F14: give the tour, Settings pages, cards and shortcuts their own files and final names"`

### Task 3: One-time tour invite for existing users

**Files:**
- Modify: `Enigma/App/GuidedTour.swift`, `Enigma/App/AppShellView.swift` (empty-chat area beside `EnigmaMainPageHeader`, ~line 579), `Enigma/App/WelcomeSetup.swift`
- Test: `EnigmaTests/EnigmaWelcomeTests.swift`

**Interfaces:**
- Produces: `GuidedTour.inviteKey == "guidedTour.invite.v1"`; `static func showsInvite(defaults: UserDefaults, setupCompleted: Bool, isFreshSetup: Bool) -> Bool`; `func dismissInvite(takeTour: Bool)` (sets the key; `takeTour` calls `begin()`).
- `WelcomeSetup.start(hasInstalledModels:)` sets `WelcomeSetup.wasCompletedBeforeLaunch: Bool` (true only when `welcomeSetup.completed.v1` was already true when `start` ran).

- [ ] **Step 1: Write the failing tests**

```swift
func testInviteShowsOnceToExistingUsersOnly() {
  let defaults = UserDefaults(suiteName: #function)!; defaults.removePersistentDomain(forName: #function)
  XCTAssertTrue(GuidedTour.showsInvite(defaults: defaults, setupCompleted: true, isFreshSetup: false))
  XCTAssertFalse(GuidedTour.showsInvite(defaults: defaults, setupCompleted: true, isFreshSetup: true))
  XCTAssertFalse(GuidedTour.showsInvite(defaults: defaults, setupCompleted: false, isFreshSetup: false))
  defaults.set(true, forKey: GuidedTour.inviteKey)
  XCTAssertFalse(GuidedTour.showsInvite(defaults: defaults, setupCompleted: true, isFreshSetup: false))
}

func testSetupInterruptedBeforeTheUpdateResumesWithoutAnInvite() {
  let defaults = UserDefaults(suiteName: #function)!; defaults.removePersistentDomain(forName: #function)
  defaults.set(WelcomeSetup.Step.models.rawValue, forKey: WelcomeSetup.progressKey)
  let setup = WelcomeSetup(defaults: defaults)
  setup.start(hasInstalledModels: true)
  XCTAssertTrue(setup.isPresented)
  XCTAssertEqual(setup.step, .models)
  XCTAssertFalse(setup.wasCompletedBeforeLaunch)
}
```

- [ ] **Step 2: Run** `-only-testing:EnigmaTests/EnigmaWelcomeTests` → FAIL (undefined).

- [ ] **Step 3: Implement** the interfaces. The invite is one line in the empty chat under the greeting: "See what Enigma can do" with a primary **Take the tour** and a text **Not now** (`enigmaButtonStyle`), shown when `showsInvite(defaults: .standard, setupCompleted: true, isFreshSetup: !setup.wasCompletedBeforeLaunch)` and no tour is running. In the test host `showsInvite` is never consulted for `.standard` (use `TestHost.isActive` to hide it).

- [ ] **Step 4: Run** → PASS.

- [ ] **Step 5: Commit** — `git commit -m "F14: invite existing users to the tour once"`

### Task 4: Rewrite the tests the spike broke

**Files:** Test: `EnigmaTests/EnigmaSettingsTests.swift`, `EnigmaTests/EnigmaMainWindowTests.swift`

**Interfaces:**
- Consumes: page locations from the spec's Settings list: API keys and provider on Cloud → Advanced; Brave key and blocked sites on Search and maps → Advanced; updates on About; web search text on Search and maps; old raw values via `SettingsDestination.requested(_:)`.

- [ ] **Step 1: Rewrite the eight Settings tests** to open the right page (and `SettingsAdvanced`, found by its test marker "Advanced", where needed) before looking for their controls. Assertions on behaviour (keychain save/remove, error text, updater calls) stay as they are.

- [ ] **Step 2: Rename and rewrite** `testDiscoverIsGoneAndItsOldNameOpensLocalModels` → `testOldDestinationNamesStillOpenTheirPages`:

```swift
XCTAssertEqual(SettingsView.SettingsDestination.requested("general"), .general)
XCTAssertEqual(SettingsView.SettingsDestination.requested("local"), .local)
XCTAssertEqual(SettingsView.SettingsDestination.requested("cloud"), .cloud)
XCTAssertEqual(SettingsView.SettingsDestination.requested("selection"), .selection)
XCTAssertEqual(SettingsView.SettingsDestination.requested("discover"), .local)
XCTAssertEqual(SettingsView.SettingsDestination.allCases.map(\.rawValue),
  ["general", "shortcuts", "local", "cloud", "search", "selection", "screen", "files", "messages", "permissions", "approvals", "about"])
```

- [ ] **Step 3: Replace the two tour tests** with `testTourCardSitsInTheRailAndTakesReturnAndItsButton` (the card's frame is right of `GuidedTour.pageWidth`; Return and a click on its button each advance `stepIndex` by one) and `testTourStopsWithATargetSitLevelWithIt` (for each `Stop` whose target is non-nil, the card's vertical centre is within 40 pt of the target's, clamped to the window).

- [ ] **Step 4: Run** `-only-testing:EnigmaTests/EnigmaSettingsTests -only-testing:EnigmaTests/EnigmaMainWindowTests` → 0 failures.

- [ ] **Step 5: Commit** — `git commit -m "F14: tests find controls on their new pages and the tour in its rail"`

### Task 5: No monospace in Settings, shorter cloud sign-in

**Files:**
- Modify: `Enigma/App/EnigmaTheme.swift` (`EnigmaTypography`), `Enigma/App/EnigmaControls.swift` (`EnigmaStatusLine`, `EnigmaRow` badge), `Enigma/LocalInference/LocalModelManagerSection.swift` (its `mono` helper and Mac stats), `Enigma/Cloud/CloudSettingsPage.swift`, `ChatGPTConnectionControls`/`ClaudeCodeConnectionControls` call sites on that page
- Test: `EnigmaTests/EnigmaSettingsTests.swift`

**Interfaces:**
- Produces: `EnigmaTypography.detail(_ size: CGFloat = 11.5, settings: Bool) -> Font` — `ui(size)` when `settings`, else `mono(size)`. Every mono use reachable from a Settings page calls it with `@Environment(\.enigmaSettingsStyle)`.

- [ ] **Step 1: Failing tests**

```swift
func testSettingsDetailsUseTheUIFont() {
  XCTAssertEqual(EnigmaTypography.detail(11.5, settings: true), EnigmaTypography.ui(11.5))
  XCTAssertEqual(EnigmaTypography.detail(11.5, settings: false), EnigmaTypography.mono(11.5))
}
```
and `testCloudSignInIsOneRowPerPlan`: on `.cloud` with both plans signed out, exactly two `EnigmaRow`s titled "ChatGPT" and "Claude" exist before "Advanced", each with one button, and no other body text appears between them.

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement** `detail(_:settings:)` and switch the call sites. Cloud page: each plan is `EnigmaRow(plan, subtitle: <status>, info: <today's longer sign-in explanation>) { <one Sign in / Sign out button> }`; the longer copy moves into `info`.

- [ ] **Step 4: Run** `-only-testing:EnigmaTests/EnigmaSettingsTests` → PASS. Look at `settings-local-*` and `settings-cloud-*` snapshots: no monospace.

- [ ] **Step 5: Commit** — `git commit -m "F14: Settings in SF Pro only; one row per cloud plan"`

### Task 6: Shortcuts: Help shows yours, macOS clashes warn, failures show

**Files:**
- Modify: `Enigma/App/ShortcutStore.swift`, `Enigma/App/ShortcutEditor.swift`, `Enigma/App/KeyboardShortcutsHelpView.swift` (`KeyboardShortcutsList`), `Enigma/App/GlobalHotKeyMonitor.swift` (`ShortcutHotKeys`)
- Test: `EnigmaTests/AppCommandTests.swift`

**Interfaces:**
- Produces: `struct ShortcutConflict { let message: String; let blocks: Bool }`; `ShortcutStore.conflict(_ binding: KeyBinding, for action: ShortcutAction) -> ShortcutConflict?` — `blocks == true` for another Enigma action's shortcut, `false` for an entry in `reserved` (macOS). `ShortcutStore.failedActions: Set<String>` (action ids whose global registration failed), published.
- `reserved` gets a comment: `// shortcut: common macOS shortcuts only, not every app's; extend when users report a clash.`

- [ ] **Step 1: Failing tests**

```swift
func testAMacOSShortcutWarnsButIsAllowed() throws {
  let defaults = UserDefaults(suiteName: #function)!; defaults.removePersistentDomain(forName: #function)
  let store = ShortcutStore(defaults: defaults)
  let space = KeyBinding.keys(" ", [.command], keyCode: 49)
  let conflict = try XCTUnwrap(store.conflict(space, for: .panel(.newChat)))
  XCTAssertFalse(conflict.blocks)
}
```
and two hosted-view tests:
- `testHelpListsAChangedShortcut`: with `.panel(.newChat)` set to ⌘J in `ShortcutStore.shared` (reset in `tearDown`), the rendered `KeyboardShortcutsList` contains "⌘J" on the New chat row.
- `testAShortcutThatFailsToRegisterSaysSo`: after `ShortcutHotKeys` reports a registration failure for `.summon`, `failedActions` contains `ShortcutAction.summon.id` and the editor's summon row shows "Couldn’t set this shortcut".
Update `testAShortcutThatIsTakenIsRefused` to assert `conflict.blocks == true`.

- [ ] **Step 2: Run** `-only-testing:EnigmaTests/AppCommandTests` → FAIL.

- [ ] **Step 3: Implement.** The recorder saves a non-blocking binding and shows its message under the row; a blocking one is refused as today. `KeyboardShortcutsList` reads `ShortcutStore.shared.binding(_:)` for each row. `ShortcutHotKeys` inserts into `failedActions` when `registrationFailed` fires and keeps the previous binding registered.

- [ ] **Step 4: Run** → PASS.

- [ ] **Step 5: Commit** — `git commit -m "F14: Help shows your shortcuts; macOS clashes warn; failed shortcuts say so"`

### Task 7: "Advanced settings…" opens Cloud with Advanced open

**Files:**
- Modify: `Enigma/App/SettingsView.swift`, `Enigma/App/SettingsPages.swift` (`SettingsAdvanced`), `Enigma/App/AI_SpotlightApp.swift:119` (`showSettings`), `Enigma/App/EnigmaMainWindowLogic.swift:343`, the `openSettings` action in `AppShellView`
- Test: `EnigmaTests/EnigmaSettingsTests.swift`

**Interfaces:**
- Produces: `struct SettingsView.SettingsRequest { let destination: SettingsDestination; let opensAdvanced: Bool }`; `SettingsDestination.requested(_:)` also accepts a `SettingsRequest`; `static func opensAdvanced(_ object: Any?) -> Bool`; `showSettings(destination:opensAdvanced: Bool = false)`; `EnvironmentValues.settingsOpensAdvanced: Bool` read by `SettingsAdvanced` for its initial `isOpen`.

- [ ] **Step 1: Failing test** `testAdvancedSettingsOpensCloudWithAdvancedOpen`: post `.settingsDestinationRequested` with `SettingsRequest(destination: .cloud, opensAdvanced: true)` to a hosted `SettingsView`; the "API keys" header marker is present without clicking "Advanced". Posting `.cloud` alone leaves it absent.

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement.** The model menu's Cloud-mode item calls `showSettings(destination: .cloud, opensAdvanced: true)`; "Manage models in Settings…" keeps opening `.local`.

- [ ] **Step 4: Run** → PASS.

- [ ] **Step 5: Commit** — `git commit -m "F14: Advanced settings… opens Cloud with Advanced open"`

### Task 8: Cards: hover inside the card, custom rows join cards

**Files:**
- Modify: `Enigma/App/SettingsCards.swift`, `Enigma/App/EnigmaControls.swift` (`EnigmaRowButtonBody`), `Enigma/Cloud/CloudSettingsPage.swift` (`APIKeyRow`), any other Settings row that isn't an `EnigmaRow` and sits between a heading and a closing `EnigmaHairline`
- Test: `EnigmaTests/EnigmaSettingsTests.swift`

**Interfaces:**
- Consumes: `View.settingsCardMark(_:at:if:)` from Task 2.
- Produces: in Settings style, a clickable row's hover fill is a rounded rectangle (radius 6) reaching 8 pt beyond the row on each side, so it stays inside the card (which reaches 14 pt); non-`EnigmaRow` rows call `.settingsCardMark(.row, at: .top, if: settingsStyle)` and draw no top hairline in Settings style.

- [ ] **Step 1: Failing test** `testAPIKeyRowsSitOnACard`: render `.cloud` with `opensAdvanced` in Paper; a pixel 4 pt inside the left card edge, level with the first API key row, matches `EnigmaPalette.paper.surface`.

- [ ] **Step 2: Run** → FAIL (background colour).

- [ ] **Step 3: Implement** the marks on custom rows and the hover shape from the Interfaces block.

- [ ] **Step 4: Run** `-only-testing:EnigmaTests/EnigmaSettingsTests` → PASS; check `settings-*` snapshots for every page in both themes: no row outside a card that should be in one, no doubled lines.

- [ ] **Step 5: Commit** — `git commit -m "F14: custom rows join Settings cards; hover stays inside them"`

### Task 9: Behaviour the spec requires (tour exits, resume, search)

**Files:**
- Modify only if a test fails: `Enigma/App/GuidedTour.swift`, `Enigma/App/TourDocumentWindow.swift`, `Enigma/App/SpotlightPanelController.swift`, `Enigma/App/SettingsView.swift`
- Test: `EnigmaTests/EnigmaMainWindowTests.swift`, `EnigmaTests/EnigmaSettingsTests.swift`

- [ ] **Step 1: Write the tests**
  - `testLeavingTheTourFromAnyStopRestoresTheWindow`: for each `GuidedTour.Stop`, `go(stop)`, then `end()`; the panel's frame width equals its pre-tour width (±1), `alphaValue == 1`, it is visible, `GuidedTour.shared.pageWidth == nil`, and no `TourDocumentWindow` is on screen.
  - `testLeavingTheSelectionStopBringsTheWindowBack`: at `.selection` after the step-aside fade, Esc ends the tour; the panel is visible with `alphaValue == 1`.
  - `testARestartMidTourResumesAtTheSavedStop`: with a `GuidedTour(defaults:)` on a fresh suite and persistence on, `go(.messages)`; a new `GuidedTour` on the same suite `resumeIfInterrupted()` → `stop == .messages`, `resumed == true`. With `TestHost`'s default instance nothing is written to `.standard` (`UserDefaults.standard.object(forKey: GuidedTour.progressKey) == nil`).
  - `testSettingsSearchFindsWordsFromDetailsAndAdvanced`: `SettingsDestination.allCases.filter { $0.matches("brave") } == [.search]`; `matches("api key")` contains `.cloud`; `matches("zzz")` is empty; in a hosted `SettingsView`, typing "messages" and Return selects `.messages`; typing "zzz" shows "No matches".
  - `testNoTourChatReachesRecents`: after the ask stop's first demo plays, `ChatSessionStore` holds no new session.
- [ ] **Step 2: Run** → note failures.
- [ ] **Step 3: Fix each failure at its cause.** `GuidedTour.init` needs `persists` injectable for the resume test: `init(defaults: UserDefaults = .standard, persists: Bool = !TestHost.isActive)`.
- [ ] **Step 4: Run** `-only-testing:EnigmaTests/EnigmaMainWindowTests -only-testing:EnigmaTests/EnigmaSettingsTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "F14: tour exits, resume and Settings search are pinned by tests"`

### Task 10: Docs, screenshots, release notes

**Files:**
- Modify: `docs/Welcome-and-Settings.md` (rewrite), `docs/Selection-Context.md`, `docs/Messages.md`, `docs/Web-Search.md`, `docs/design/UI-Style.md`, `to-do.md` (F14 → ✅ Done, plus where F13/F15/F16/F19/F20 now live)
- Create: `docs/release-notes/0.13.0.md`; screenshots under the folder `Welcome-and-Settings.md` already uses, Paper and Ink, from `EnigmaSnapshot` (setup slides, three tour stops including selection, General, Shortcuts, Permissions, Cloud)

- [ ] **Step 1:** Generate screenshots with `TEST_RUNNER_ENIGMA_SNAPSHOT_DIR=<docs screenshot folder>` and the snapshot tests; keep only the ones the doc uses.
- [ ] **Step 2:** Write the docs. `UI-Style.md`: replace "No boxes around lists" for Settings with: rows grouped on `surface` cards (radius 10, `border` edge, faint inset dividers) under 13.5 pt semibold headings; ⓘ for details; "› Advanced" per page; the tour rail. Every "Settings → X" path matches the new page names.
- [ ] **Step 3: Verify** `grep -rn "Settings → \(Local models\|Cloud and search\)" docs` → no output; no home paths or emails in any changed doc (`grep -rn "/Users/\|@gmail" docs` → no output).
- [ ] **Step 4: Commit** — `git commit -m "F14: docs, screenshots and 0.13.0 notes for the new welcome, tour and Settings"`

### Task 11: Full suite, review, PR

- [ ] **Step 1:** `scripts/verify-xcode.sh test` (full suite) → 0 failures. Run it in the background; it takes several minutes.
- [ ] **Step 2:** One fresh reviewer (Opus, xhigh) on `git diff origin/main...HEAD`, up to three rounds; fix findings, re-run the affected test classes.
- [ ] **Step 3:** `git push -u origin feat/f14-welcome-settings`; open a PR to `main` titled "F14: new welcome setup, hands-on tour and Settings"; turn on Auto-fix.
- [ ] **Step 4:** Owner runs the build live (setup, full tour, Settings, a custom shortcut) before merge.
