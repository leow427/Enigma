# Sparkle Auto-Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installed copies of Enigma find, download and install new releases by themselves through Sparkle, and the owner publishes a release with one script.

**Architecture:** A Sparkle-free `AppUpdater` (an `ObservableObject`) is what the menu bar and Settings read and drive; it talks to an `AppUpdaterBackend` protocol. `SparkleUpdaterBackend` is the only file that imports Sparkle, and tests use a fake backend. `scripts/release.sh` bumps the version, archives, checks the signature, zips, signs the zip and updates `appcast.xml` with Sparkle's `generate_appcast`, then publishes in a feed-safe order.

**Departures from the spec:** the spec's `protocol AppUpdating: ObservableObject` moves one level down to `AppUpdaterBackend`, because SwiftUI cannot observe an existential; the views observe the concrete `AppUpdater`. The spec's `installPendingUpdate()` is `performPendingUpdate()`, since it also hands an available-but-not-downloaded update back to Sparkle. A downloaded update stays in the menu until it installs; only an available one is cleared when Sparkle's session ends.

**Tech Stack:** Swift 6, AppKit + SwiftUI, Sparkle 2 (SPM), XCTest, POSIX `sh`, `gh`.

**Spec:** `docs/superpowers/specs/2026-10-18-sparkle-updates-design.md` — read it first; this plan argues from it.

## Global Constraints

- Sparkle 2 via SPM, **exact** version pin (latest stable 2.x, ≥ 2.9; 2.10.0 when written), linked only into the Enigma app target.
- Only `Enigma/App/SparkleUpdaterBackend.swift` imports Sparkle.
- Feed URL: `https://raw.githubusercontent.com/leow427/Enigma/main/appcast.xml`, via build setting `ENIGMA_UPDATE_FEED_URL` set in `project.pbxproj` (never an `.xcconfig`, where `//` starts a comment).
- Info.plist: `SUEnableAutomaticChecks` YES, `SUAutomaticallyUpdate` YES, `SUScheduledCheckInterval` 86400, no `SUEnableSystemProfiling`.
- `CFBundleShortVersionString` = `$(MARKETING_VERSION)`, `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)` (a plain integer). `MARKETING_VERSION` starts at `0.9.1`.
- Download URL prefix: `https://github.com/leow427/Enigma/releases/download/v<version>/`; archive name `Enigma-<version>.zip`; tag `v<version>`.
- Hosted unit tests never start Sparkle; tests stay offline and deterministic.
- Debug builds refuse background update checks; manual checks still run.
- Menu copy: `Check for Updates…`, `Restart to Update to <version>`, `Update to <version> Available…`.
- UI follows `UI-Style.md` and existing `EnigmaRow` / `EnigmaSwitch` / `EnigmaSectionHeader` / `EnigmaHairline` controls.
- No home paths, emails or credentials in committed files. No attribution lines in commits.
- Commits: focused, imperative (e.g. `Add the Sparkle package and update keys`).

## Review Focus

1. **Update found but not downloaded** (automatic download off, or install needs authorization): the menu shows `Update to X Available…`, and choosing it hands back to Sparkle (`checkForUpdates()`), never runs an install block. → Task 2 and Task 4 tests.
2. **Restart to Update chosen twice** (double click, or menu reopened before relaunch): the install block runs exactly once. → Task 2 test.
3. **Sparkle ends the update session** (user dismisses or skips an available update): that item disappears from the menu, while a downloaded update stays offered until it installs. → Task 2 and Task 4 tests.
4. **Debug build's scheduled check**: refused; a user-started check in Debug is allowed. → Task 3 test.
5. **Bad release arguments** (malformed version, version not newer, existing tag, missing notes file): the script stops before building and publishes nothing. → Task 6 verification steps.

---

### Task 0: Branch setup (coordinator)

- [x] Create `feat/sparkle-updates` from `docs/sparkle-updates-spec` (it carries the spec and this plan), in its own worktree.
- [x] `git fetch origin` and merge `origin/main` (done: it carries the rename to `Enigma/`, `Enigma.xcodeproj` and `EnigmaTests/`, which this plan's paths now use).

---

### Task 1: Sparkle package, versioning and Info.plist keys

**Files:**
- Modify: `Enigma.xcodeproj/project.pbxproj` (remote package reference, product dependency on the app target, `MARKETING_VERSION = 0.9.1`, `ENIGMA_UPDATE_FEED_URL` in both app configurations)
- Create: `Enigma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (commit it)
- Modify: `Enigma/Resources/Info.plist`
- Modify: `Enigma/Resources/ThirdPartyNotices.txt` (Sparkle's MIT license, same layout as the llama.cpp entry; copy the text from the checked-out package's `LICENSE`)
- Test: `EnigmaTests/AppBundleTests.swift`

**Interfaces:**
- Produces: the `Sparkle` module available to the app target; Info.plist keys above.

- [ ] **Step 1: Write the failing tests** in `AppBundleTests`:

```swift
func testUpdateFeedAndKeysAreConfigured() throws {
  let info = try XCTUnwrap(Bundle.main.infoDictionary)
  let feed = try XCTUnwrap(URL(string: try XCTUnwrap(info["SUFeedURL"] as? String)))
  XCTAssertEqual(feed.scheme, "https")
  XCTAssertEqual(feed.host(), "raw.githubusercontent.com")
  XCTAssertEqual(feed.path(), "/leow427/Enigma/main/appcast.xml")
  let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
  XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "An Ed25519 public key is 32 bytes.")
  XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
  XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
  XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
  XCTAssertNotEqual(info["SUEnableSystemProfiling"] as? Bool, true)
}

func testVersionsComeFromBuildSettings() throws {
  let info = try XCTUnwrap(Bundle.main.infoDictionary)
  let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
  XCTAssertFalse(build.isEmpty)
  XCTAssertTrue(build.allSatisfy(\.isASCII) && build.allSatisfy(\.isNumber), "Sparkle compares this integer: \(build)")
  let short = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
  XCTAssertNotNil(short.wholeMatch(of: /\d+\.\d+\.\d+/), short)
}

func testSparkleIsEmbeddedInTheApp() throws {
  let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
  XCTAssertTrue(FileManager.default.fileExists(atPath: frameworks.appending(path: "Sparkle.framework").path))
}
```

- [ ] **Step 2: Run and confirm they fail.**
Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/AppBundleTests`
Expected: the three new tests FAIL (missing keys, `1.0` short version, no framework).

- [ ] **Step 3: Add the package and settings.** In Xcode or by editing `project.pbxproj`: remote package `https://github.com/sparkle-project/Sparkle`, `kind = exactVersion`, product `Sparkle` → Enigma target only (Embed & Sign). Set app-target `MARKETING_VERSION = 0.9.1` (Debug and Release) and `ENIGMA_UPDATE_FEED_URL = "https://raw.githubusercontent.com/leow427/Enigma/main/appcast.xml"` (Debug and Release). Leave `CURRENT_PROJECT_VERSION = 1`.

- [ ] **Step 4: Owner checkpoint — EdDSA key.** Pause and have the owner run Sparkle's `generate_keys` once (now that the package is resolved, it is at `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`), back the key up with `generate_keys -x <file>` into their password manager, and paste the printed **public** key. Do not run `generate_keys` yourself and never handle the private key.

- [ ] **Step 5: Edit `Info.plist`**: `CFBundleShortVersionString` → `$(MARKETING_VERSION)`, `CFBundleVersion` → `$(CURRENT_PROJECT_VERSION)`; add `SUFeedURL` = `$(ENIGMA_UPDATE_FEED_URL)`, `SUPublicEDKey` = the owner's public key, `SUEnableAutomaticChecks` `<true/>`, `SUAutomaticallyUpdate` `<true/>`, `SUScheduledCheckInterval` `<integer>86400</integer>`. Add the Sparkle notice.

- [ ] **Step 6: Run and confirm they pass.** Same command. Expected: all `AppBundleTests` PASS, including the existing llama framework test.

- [ ] **Step 7: Check the signed Release build still verifies.** Run `scripts/verify-xcode.sh build`; Expected: `BUILD SUCCEEDED`. Then confirm CI's unsigned path: `xcodebuild build -project Enigma.xcodeproj -scheme Enigma -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet` succeeds.

- [ ] **Step 8: Commit** `project.pbxproj`, `Package.resolved`, `Info.plist`, `ThirdPartyNotices.txt`, `AppBundleTests.swift`: `Add the Sparkle package and update settings`.

---

### Task 2: `AppUpdater` state model (no Sparkle)

**Files:**
- Create: `Enigma/App/AppUpdater.swift`
- Create: `EnigmaTests/AppUpdaterTests.swift` (holds `FakeUpdaterBackend`)

**Interfaces:**
- Produces (exact):

```swift
struct PendingUpdate: Equatable {
  enum Stage: Equatable { case readyToInstall, available }
  let version: String          // display version, e.g. "0.10.1"
  let stage: Stage
  var menuTitle: String        // "Restart to Update to 0.10.1" / "Update to 0.10.1 Available…"
}

@MainActor protocol AppUpdaterBackend: AnyObject {
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var lastUpdateCheckDate: Date? { get }
  func start(reportingTo updater: AppUpdater)
  func checkForUpdates()
}

@MainActor final class AppUpdater: ObservableObject {
  init(backend: any AppUpdaterBackend)
  @Published private(set) var canCheckForUpdates: Bool        // false until the backend says otherwise
  @Published private(set) var pendingUpdate: PendingUpdate?
  @Published private(set) var lastUpdateCheckDate: Date?
  var automaticallyChecksForUpdates: Bool { get set }         // forwards to backend, sends objectWillChange
  var automaticallyDownloadsUpdates: Bool { get set }         // same
  func start()                                                // backend.start(reportingTo: self) once; refreshes lastUpdateCheckDate
  func checkForUpdates()
  func performPendingUpdate()                                 // readyToInstall → install block once; available → checkForUpdates()
  // Called by the backend:
  func backendCanCheckChanged(_ canCheck: Bool)
  func backendUpdateReady(version: String, install: @escaping @MainActor () -> Void)
  func backendUpdateAvailable(version: String)
  func backendSessionEnded()                                  // clears an .available update; a .readyToInstall one stays until installed
  func backendCheckFinished()                                 // refreshes lastUpdateCheckDate from the backend
  static func versionText(info: [String: Any]) -> String      // "0.10.0 (2)"; "Unknown version" when either key is missing
  static func lastCheckedText(_ date: Date?, now: Date, locale: Locale) -> String
}
```

`lastCheckedText`: `nil` → `"Not checked yet"`; otherwise `"Last checked "` + `RelativeDateTimeFormatter` (`.full` units, given locale) output.

`performPendingUpdate()` on a ready update runs the install block and then clears `pendingUpdate`, so a second call does nothing. `AppUpdater.shared` arrives in Task 3.

- [ ] **Step 1: Write the failing tests** in `AppUpdaterTests` (all `@MainActor`), with:

```swift
@MainActor final class FakeUpdaterBackend: AppUpdaterBackend {
  var automaticallyChecksForUpdates = true
  var automaticallyDownloadsUpdates = true
  var lastUpdateCheckDate: Date?
  private(set) var startCount = 0
  private(set) var checkCount = 0
  func start(reportingTo updater: AppUpdater) { startCount += 1 }
  func checkForUpdates() { checkCount += 1 }
}
```

Tests and their assertions:
- `testStartsOnceAndHasNothingPending`: `start()` twice → `startCount == 1`; `pendingUpdate == nil`; `canCheckForUpdates == false` until `backendCanCheckChanged(true)`, then `true`.
- `testReadyUpdateInstallsExactlyOnce`: `backendUpdateReady(version: "0.10.1") { installs += 1 }` → `pendingUpdate == PendingUpdate(version: "0.10.1", stage: .readyToInstall)`, `menuTitle == "Restart to Update to 0.10.1"`; `performPendingUpdate()` twice → `installs == 1`, `checkCount == 0`.
- `testAvailableUpdateHandsBackToSparkle`: `backendUpdateAvailable(version: "0.10.1")` → `menuTitle == "Update to 0.10.1 Available…"`; `performPendingUpdate()` → `checkCount == 1`.
- `testSessionEndClearsAnAvailableUpdate`: available, then `backendSessionEnded()` → `pendingUpdate == nil`; `performPendingUpdate()` afterwards → `checkCount == 0`.
- `testSessionEndKeepsAReadyUpdate`: ready, then `backendSessionEnded()` → still `.readyToInstall` for `"0.10.1"`.
- `testTogglesWriteThroughToTheBackend`: set `automaticallyChecksForUpdates = false`, `automaticallyDownloadsUpdates = false` → fake's values are `false`.
- `testLastCheckDateFollowsTheBackend`: fake `lastUpdateCheckDate = d`; `backendCheckFinished()` → `updater.lastUpdateCheckDate == d`.
- `testVersionText`: `["CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "2"]` → `"0.10.0 (2)"`; `[:]` → `"Unknown version"`.
- `testLastCheckedText`: `nil` → `"Not checked yet"`; `now - 300` with `Locale(identifier: "en_US")` → `"Last checked 5 minutes ago"`.

- [ ] **Step 2: Run and confirm they fail** — `scripts/verify-xcode.sh test -only-testing:EnigmaTests/AppUpdaterTests`; Expected: compile failure (`AppUpdater` not defined).

- [ ] **Step 3: Implement `AppUpdater.swift`** to the interface above.

- [ ] **Step 4: Run and confirm they pass.** Same command; Expected: PASS.

- [ ] **Step 5: Commit** `AppUpdater.swift`, `AppUpdaterTests.swift`: `Add the update state that the menu and Settings read`.

---

### Task 3: `SparkleUpdaterBackend` and startup

**Files:**
- Create: `Enigma/App/SparkleUpdaterBackend.swift` (the only `import Sparkle`)
- Modify: `Enigma/App/AppUpdater.swift` (add `static let shared = AppUpdater(backend: SparkleUpdaterBackend())`)
- Modify: `Enigma/App/ApplicationDelegate.swift` (`applicationDidFinishLaunching`, after the test-host return: `AppUpdater.shared.start()`)
- Test: `EnigmaTests/AppUpdaterTests.swift`

**Interfaces:**
- Consumes: `AppUpdaterBackend`, `AppUpdater.backend*` methods (Task 2).
- Produces: `@MainActor final class SparkleUpdaterBackend: NSObject, AppUpdaterBackend` and `static func permitsCheck(isBackground: Bool, isDebugBuild: Bool) -> Bool` (false only for a background check in a Debug build).

Behaviour (spec, "AppUpdater" section):
- Owns a lazily created `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)`; `start(reportingTo:)` keeps a weak reference to the `AppUpdater`, calls `startUpdater()`, and observes `updater.canCheckForUpdates` (KVO) → `backendCanCheckChanged`. Creating it is side-effect free, so Settings rendered in tests through `.shared` reads flags without starting Sparkle.
- `SPUUpdaterDelegate`:
  - `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` → `backendUpdateReady(version: item.displayVersionString, install: block)`, return `true`.
  - `updater(_:mayPerform:)` (Obj-C `updater:mayPerformUpdateCheck:error:`) → throw unless `permitsCheck(isBackground: check == .updatesInBackground, isDebugBuild: <#if DEBUG>)`.
  - `updater(_:didFinishUpdateCycleFor:error:)` → `backendCheckFinished()`.
- `SPUStandardUserDriverDelegate`: `supportsGentleScheduledUpdateReminders` → `true`; `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` → `immediateFocus`; `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` → when not handled by Sparkle and `state.stage == .notDownloaded` (or other non-downloaded stages), `backendUpdateAvailable(version:)`; `standardUserDriverDidReceiveUserAttention(forUpdate:)` and `standardUserDriverWillFinishUpdateSession()` → `backendSessionEnded()`.
- Conform with `@preconcurrency` (Sparkle calls delegates on the main thread). Confirm each Swift spelling by compiling against the pinned package; record any difference from the spec in the commit message.

- [ ] **Step 1: Write the failing test** `testDebugBuildsRefuseOnlyBackgroundChecks`: `permitsCheck(isBackground: true, isDebugBuild: true) == false`; `(false, true) == true`; `(true, false) == true`; `(false, false) == true`.
- [ ] **Step 2: Run it; Expected: FAIL** (type not defined).
- [ ] **Step 3: Implement** the backend, switch `AppUpdater.shared` to it, start it in `ApplicationDelegate`.
- [ ] **Step 4: Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/AppUpdaterTests -only-testing:EnigmaTests/AppBundleTests`; Expected: PASS.
- [ ] **Step 5: Run the full suite** `scripts/verify-xcode.sh test`; Expected: no new failures (the test host returns before `AppUpdater.shared.start()`).
- [ ] **Step 6: Commit** `SparkleUpdaterBackend.swift`, `AppUpdater.swift`, `ApplicationDelegate.swift`, `AppUpdaterTests.swift`: `Connect the update state to Sparkle`.

---

### Task 4: Menu-bar items

**Files:**
- Modify: `Enigma/App/AppCommand.swift`
- Modify: `Enigma/App/MenuBarController.swift`
- Modify: `Enigma/App/ApplicationDelegate.swift` (pass `.shared`)
- Test: `EnigmaTests/AppCommandTests.swift`, `EnigmaTests/AppUpdaterTests.swift`

**Interfaces:**
- Consumes: `AppUpdater` (Task 2).
- Produces: `AppCommand.restartToUpdate = "Restart to Update"`, `AppCommand.checkForUpdates = "Check for Updates…"`, declared between `privacyHide` and `settings`; `MenuBarController.init(panelController: SpotlightPanelController, updater: AppUpdater)`; `func makeMenu() -> NSMenu` (used by `install()`); `MenuBarController: NSMenuDelegate` with `menuNeedsUpdate(_:)`. The two update items carry `identifier` `NSUserInterfaceItemIdentifier("pendingUpdate")` and `("checkForUpdates")`; tests find them by these.

Menu order: Open, New Chat, Privacy Hide, separator, *pending update item*, Check for Updates…, Settings, separator, Quit. `makeMenu()` sets `autoenablesItems = false` and itself as delegate. `menuNeedsUpdate` hides the pending item unless `updater.pendingUpdate` is set, titles it `pendingUpdate.menuTitle`, and enables Check for Updates… only when `canCheckForUpdates`. The pending item calls `performPendingUpdate()`; Check for Updates… calls `checkForUpdates()`.

- [ ] **Step 1: Update** `testMenuCommandsHaveExpectedOrderAndTitles` to `["Open", "New Chat", "Privacy Hide", "Restart to Update", "Check for Updates…", "Settings", "Quit"]`.
- [ ] **Step 2: Write failing tests** in `AppUpdaterTests`, building `MenuBarController(panelController: SpotlightPanelController(contentView: NSView()), updater: AppUpdater(backend: fake))`, `let menu = controller.makeMenu()`, then `controller.menuNeedsUpdate(menu)`:
  - `testMenuHidesTheUpdateItemUntilOneIsPending`: the `pendingUpdate` item is hidden; Check for Updates… disabled; after `backendCanCheckChanged(true)` and `menuNeedsUpdate`, enabled; `menu.performActionForItem(at:)` on it → `fake.checkCount == 1`.
  - `testMenuOffersRestartForAReadyUpdate`: after `backendUpdateReady(version: "0.10.1")`, a visible item titled `"Restart to Update to 0.10.1"`; performing it runs the install block once.
  - `testMenuOffersAnAvailableUpdate`: after `backendUpdateAvailable(version: "0.10.1")`, visible item `"Update to 0.10.1 Available…"`; performing it → `checkCount == 1`.
  - `testMenuDropsAnAvailableUpdateWhenTheSessionEnds`: available → `backendSessionEnded()` → item hidden.
- [ ] **Step 3: Run; Expected: FAIL.** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/AppCommandTests -only-testing:EnigmaTests/AppUpdaterTests`
- [ ] **Step 4: Implement** the cases, `makeMenu()`, `menuNeedsUpdate(_:)`, and pass `AppUpdater.shared` from `ApplicationDelegate`.
- [ ] **Step 5: Run; Expected: PASS.**
- [ ] **Step 6: Commit** `Add update items to the menu bar`.

---

### Task 5: Settings → General → Updates

**Files:**
- Modify: `Enigma/App/SettingsView.swift` (`SettingsView.init` gains `updater: AppUpdater = .shared`, passed to `GeneralSettingsPage`; new `@ObservedObject var updater: AppUpdater` there)
- Modify: `EnigmaTests/EnigmaSettingsTests.swift` (`Fixture` owns `updater = AppUpdater(backend: FakeUpdaterBackend())` and passes it in `settings(_:)`)
- Test: `EnigmaTests/EnigmaSettingsTests.swift`

**Interfaces:**
- Consumes: `AppUpdater`, `FakeUpdaterBackend` (Task 2).

A new group at the end of `GeneralSettingsPage`, after Messages:

```
EnigmaSectionHeader("Updates")
EnigmaRow("Check for updates automatically",
          subtitle: "Once a day, from Enigma’s GitHub page. Only Enigma’s version is sent.")  → EnigmaSwitch, same title
EnigmaRow("Download and install updates automatically",
          subtitle: "Updates install when Enigma quits, or when you choose Restart to Update in the menu bar.")
          → EnigmaSwitch, same title, .disabled(!updater.automaticallyChecksForUpdates)
EnigmaRow("Version", subtitle: "<versionText> · <lastCheckedText>")
          → Button("Check Now") .enigmaButtonStyle(.secondary) .disabled(!updater.canCheckForUpdates)
            .accessibilityLabel("Check for Updates Now")
EnigmaHairline()
```

Copy is fixed as written; store the two subtitles as `static let` on `GeneralSettingsPage` like `newChatsNote`.

- [ ] **Step 1: Write the failing test** `testUpdateSwitchesAndCheckNowReachTheUpdater` (pattern of `testAppearanceStartModeAndSwitchesChangeTheirSettings`): press `"Check for updates automatically switch"` → fake `automaticallyChecksForUpdates == false`; the download switch is then disabled (pressing it leaves fake `automaticallyDownloadsUpdates == true`); press the checks switch again, call `fixture.updater.backendCanCheckChanged(true)`, press `"Check for Updates Now"` → `checkCount == 1`. (If button markers are named differently, follow how `"Save OpenAI API key"` is reached.)
- [ ] **Step 2: Run; Expected: FAIL.** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaSettingsTests`
- [ ] **Step 3: Implement** the section.
- [ ] **Step 4: Run; Expected: PASS**, including `testEveryDestinationRendersAtWindowSizeInPaperAndInk`. Other suites that build `SettingsView` without an `updater` (e.g. `LocalModelSelectionTests`, `ScreenViewTests`) now read `AppUpdater.shared` unstarted; run the full suite to confirm they still pass and `testNoPageSpillsIntoItsMargins` (the new rows must not spill into the margins).
- [ ] **Step 5: Look at it.** Run `testSaveSettingsScreenshots` (or render General in Paper and Ink) and check the Updates group against `UI-Style.md`.
- [ ] **Step 6: Commit** `Add update settings to General`.

---

### Task 6: Release script, release notes and docs

**Files:**
- Create: `scripts/release.sh` (executable)
- Create: `appcast.xml` at the repository root (empty Sparkle RSS feed: `<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Enigma</title></channel></rss>`)
- Create: `docs/release-notes/0.10.0.md`
- Create: `docs/Updates.md`
- Modify: `docs/Distribution.md`, `README.md`, `AGENTS.md`

**Interfaces:**
- Usage: `scripts/release.sh [--dry-run] <version>`. Work folder `$HOME/Library/Caches/Enigma-Release/` (DerivedData and staging), outside the repository.

Implement the spec's six steps exactly ("Release pipeline" section), in the style of `scripts/install-app.sh` (`#!/bin/sh`, `set -eu`, a usage line, clear one-line messages, exit non-zero on the first failure). Decisions the spec leaves to the plan:
- `--dry-run` runs steps 1–5 in a detached `git worktree` under `mktemp -d`, copies the resulting zip, `appcast.xml` and `project.pbxproj` to `$HOME/Library/Caches/Enigma-Release/dry-run/<version>/`, prints the appcast diff and that folder, and removes the worktree. In dry-run the "on `main`", "clean" and "level with `origin/main`" checks print warnings instead of failing, so the script can be exercised from this feature branch; every other preflight check still fails hard.
- Version compare: three numeric fields, compared field by field (no `sort -V`).
- Bump with `sed` on the two app-target `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` lines; fail if the number of lines changed is not two each.
- Previous release: `gh release list --limit 1 --json tagName`; download `Enigma-*.zip`, or else the `*.dmg` (attach with `hdiutil attach -readonly -nobrowse -mountpoint <tmp>`, detach on exit). Compare `codesign -d -r- ` output's `designated =>` line. On mismatch print both requirements and stop. Flag `--accept-new-identity` is **not** built now (spec: future).
- After `generate_appcast`, check the new `<item>` has `sparkle:version` = new build number, `sparkle:shortVersionString` = `<version>`, the expected enclosure URL, and an `sparkle:edSignature`; otherwise stop.
- Resolve the spec's open items with the first dry run and write the outcome into `docs/Updates.md`: Markdown release notes embed as `sparkle:format="markdown"` (else convert to an HTML fragment in the script); `--maximum-deltas 0` makes no deltas; existing feed items survive (test with a two-item feed); whether the free-team archive carries `get-task-allow` (record, don't fail).

`docs/Updates.md` covers: what users see (daily check, menu items, Settings toggles), what is sent (version in the User-Agent; no profiling), one-time key setup and backup/restore (`generate_keys`, `-x`, `-f`), how to release, the manual end-to-end checklist from the spec's Testing section, and the resolved open items. `docs/Distribution.md` replaces the Organizer steps with a link to it and keeps the hardened-runtime/entitlement checks. `README.md` gains an Install section (download the zip from Releases, drag to Applications, right-click → Open the first time; later versions arrive automatically). `AGENTS.md` lists `scripts/release.sh` beside `install-app.sh`. `docs/release-notes/0.10.0.md` tells friends updates now arrive by themselves and where the two toggles are.

- [ ] **Step 1: Seed the feed and notes.** Create `appcast.xml` and `docs/release-notes/0.10.0.md`.
- [ ] **Step 2: Write the script.**
- [ ] **Step 3: Bad-argument checks fail before building.** Each exits non-zero with a one-line reason, starts no build, and leaves `git status` unchanged:
  - `scripts/release.sh --dry-run 0.10` → malformed version
  - `scripts/release.sh --dry-run 0.9.1` → not newer than 0.9.1
  - `scripts/release.sh --dry-run 0.9.2` (no `docs/release-notes/0.9.2.md`) → notes missing
  - `git tag v0.10.0 && scripts/release.sh --dry-run 0.10.0; git tag -d v0.10.0` → tag exists
- [ ] **Step 4: Full dry run** `scripts/release.sh --dry-run 0.10.0`; Expected: signed zip produced, signature checks pass (DR equals v0.9.1's), appcast diff shows one new item with build `2`, `0.10.0`, the `v0.10.0` URL and an `edSignature`; nothing committed, tagged or pushed; the temp worktree is gone (`git worktree list`).
- [ ] **Step 5: Two-item feed check.** On a scratch branch, copy the 0.10.0 dry run's `appcast.xml` and `project.pbxproj` from its dry-run folder over the repository's and commit them (as if 0.10.0 had shipped); add a throwaway `docs/release-notes/0.10.1.md`, commit, and run `scripts/release.sh --dry-run 0.10.1`. Expected: the new appcast holds both the 0.10.0 (build 2) and 0.10.1 (build 3) items. Delete the scratch branch, and record the result in `docs/Updates.md`.
- [ ] **Step 6: Write the docs**; check them and the release notes for home paths or emails (`grep -nE "/Users/|@[a-z0-9-]+\.(com|org)"`).
- [ ] **Step 7: Commit** `Add the release script, appcast and update docs`.

---

### Task 7: Whole-branch verification

- [ ] `scripts/verify-xcode.sh build`, `scripts/verify-xcode.sh test`, `scripts/verify-xcode.sh analyze` — Expected: all succeed.
- [ ] `git grep -n "import Sparkle"` → only `SparkleUpdaterBackend.swift`.
- [ ] `git diff origin/main --stat` contains only files named in this plan.
- [ ] **Owner checkpoint — manual end-to-end check** (spec, Testing): signed 0.10.0 with `ENIGMA_UPDATE_FEED_URL` pointed at a test feed, fake 0.10.1, confirm download → Restart to Update → relaunch → permissions kept; tampered zip rejected. This needs a real signed install and macOS permission prompts, so the owner runs it; record the result in `docs/Updates.md`.
- [ ] Hand back for merge to `main` and CI. Publishing 0.10.0 with `scripts/release.sh 0.10.0` is a separate owner decision after merge.
