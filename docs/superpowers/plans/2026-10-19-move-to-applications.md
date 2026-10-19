# Move to Applications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At launch, a translocated or misplaced Enigma offers to move itself into Applications and reopen, so Sparkle can update it.

**Architecture:** A pure decision and wording type (`InstallLocation`), a file mover with injected Trash and quit hooks (`ApplicationMover`), and a thin AppKit layer (`MoveToApplicationsPrompt`) that detects translocation, shows `NSAlert`s and relaunches. `ApplicationDelegate` calls it before Sparkle starts.

**Tech Stack:** Swift 6, AppKit, Foundation, Darwin `removexattr`, Security.framework SPI via `dlsym`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-move-to-applications-design.md` — read it first; the wording table there is normative. Where this plan refines a spec signature (`discardOriginal(_:destination:)`, `MoveError`), the plan wins.

## Global Constraints

- Branch `feat/move-to-applications` (based on `feat/sparkle-updates`). Do not push, do not touch `main`.
- No new dependencies. The project adds files explicitly to `Enigma.xcodeproj/project.pbxproj` (no synchronized folders): add each new app file to the `Enigma` target's App group and Sources phase, and each test file to `EnigmaTests`, following how `AppUpdater.swift` / `AppUpdaterTests.swift` appear there.
- `SWIFT_VERSION = 6.0`, no default actor isolation: `InstallLocation` and `ApplicationMover` are nonisolated value types; `MoveToApplicationsPrompt` is `@MainActor`.
- `UserDefaults` key: `installLocation.dontAskToMove`.
- Destination file name is always `Enigma.app`; destinations are `/Applications/Enigma.app` or `<home>/Applications/Enigma.app`.
- Staging name: `.Enigma-<UUID>.app` in the destination folder.
- Debug builds and the hosted test host never offer the move.
- Tests are offline and never touch `/Applications`, the real Trash, `UserDefaults.standard`, the SPI, alerts or relaunching. Use `FileManager.default.temporaryDirectory` subfolders removed in `tearDown`.
- Copy: exactly as in the spec's Wording table, with ASCII apostrophes (`'`).
- Commits: imperative, focused, no attribution lines. Check `git status` before each commit.
- Verification: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>` while developing; `scripts/verify-xcode.sh build`, `test`, `analyze` at the end.

## Review Focus

1. **A running bundle not named `Enigma.app`** (a second download, `Enigma 2.app`) must still install as `Enigma.app` — Task 1 tests the decision's destination; Task 2 tests `install` with a differently named source.
2. **A failed copy midway** (source missing or unreadable) must not leave a `.Enigma-*.app` staging item in Applications — Task 2 test `testCopyFailureLeavesNoStagingItem`.
3. **Symlinks inside the bundle** (`Versions/Current` in frameworks) must not break or be followed by quarantine removal — Task 2 test with a symlink to a directory in the fake bundle.
4. **Translocated paths under `/private/var` vs `/var`** must never count as an Applications folder, and `/Applications` must match through symlink resolution — Task 1 tests.
5. **The "Don't ask again" checkbox is honoured whichever button is pressed**, and only the offer alert can set it (the replace and failure alerts have no checkbox). Task 3 Step 2 reads the checkbox right after the offer returns, before any branch; the reviewer checks this in code and the manual check covers it.

---

### Task 1: `InstallLocation` — decision, version age, alert text

**Files:**
- Create: `Enigma/App/InstallLocation.swift`
- Create: `EnigmaTests/InstallLocationTests.swift`
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces (exact, from the spec): `InstallLocationContext` (fields `bundleURL`, `isTranslocated`, `originalURL`, `homeDirectory`, `systemApplicationsIsWritable`, `dontAskAgain`, `isDebugBuild`), `InstallLocationDecision` (`.stay`, `.reopenInPlace(original: URL)`, `.move(destination: URL, inHomeFolder: Bool)`), `enum InstallLocation` with `dontAskAgainKey`, `decide(_:)`, `isInApplicationsFolder(_:homeDirectory:)`, `age(ofExisting:comparedTo:) -> ExistingCopyAge`, `enum ExistingCopyAge { older, same, newer, unknown }`, `struct InstallLocationAlertText` (`title`, `message`, `confirmButton`, `cancelButton`; `moveOffer(inHomeFolder:)`, `reopenOffer`, `replace(existingVersion:runningVersion:age:)`, `failure(reason:)`).
- Also produce `static let systemApplicationsFolder = URL(fileURLWithPath: "/Applications")` and `static func destination(inHomeFolder: Bool, homeDirectory: URL) -> URL` on `InstallLocation`.

- [ ] **Step 1: Write the failing tests** in `InstallLocationTests` (XCTest, `@testable import Enigma`). Use a helper `context(bundle: String, translocated: Bool = false, original: String? = nil, writable: Bool = true, dontAsk: Bool = false, debug: Bool = false, home: String = "/Users/friend")`.
  - `testDebugBuildStays`: Downloads bundle, `debug: true` → `.stay`.
  - `testDontAskAgainStays`: Downloads bundle, translocated, `dontAsk: true` → `.stay`.
  - `testInSystemApplicationsStays`: `/Applications/Enigma.app` → `.stay`.
  - `testInApplicationsSubfolderStays`: `/Applications/Utilities/Enigma.app` → `.stay`.
  - `testInHomeApplicationsStays`: `/Users/friend/Applications/Enigma.app` → `.stay`.
  - `testDownloadsMovesToSystemApplications`: `/Users/friend/Downloads/Enigma.app`, writable → `.move(destination: /Applications/Enigma.app, inHomeFolder: false)`.
  - `testDownloadsWithoutWriteAccessMovesToHomeApplications` → `.move(destination: /Users/friend/Applications/Enigma.app, inHomeFolder: true)`.
  - `testRenamedBundleMovesAsEnigmaApp`: `/Users/friend/Downloads/Enigma 2.app` → destination `/Applications/Enigma.app`.
  - `testTranslocatedWithOriginalInApplicationsReopensInPlace`: bundle `/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/Enigma.app`, translocated, original `/Applications/Enigma.app` → `.reopenInPlace(original: /Applications/Enigma.app)`.
  - `testTranslocatedWithOriginalInDownloadsMoves` → `.move(/Applications/Enigma.app, false)`.
  - `testTranslocatedWithUnknownOriginalMoves` → `.move(/Applications/Enigma.app, false)`.
  - `testTranslocatedBundleIsNeverInApplications`: even if not flagged translocated, the `/private/var/.../AppTranslocation/...` path and the `/var/...` form → `isInApplicationsFolder` false.
  - `testApplicationsPrefixMustBeAWholeComponent`: `/ApplicationsFoo/Enigma.app` false; `/Applications` itself false; `/applications/Enigma.app` true.
  - `testSymlinkedHomeFolderResolves`: in a temp dir create `real/Applications/Enigma.app` (directories) and a symlink `link → real`; `isInApplicationsFolder(link/Applications/Enigma.app, homeDirectory: real)` true and `isInApplicationsFolder(real/Applications/Enigma.app, homeDirectory: link)` true.
  - `testExistingCopyAge`: (`"0.10.0"` vs running `"0.10.1"`) `.older`; (`"0.10.1"`,`"0.10.1"`) `.same`; (`"0.10.2"`,`"0.10.1"`) `.newer`; (`"0.10"`,`"0.10.0"`) `.same`; (`"0.9.12"`,`"0.10.0"`) `.older`; (`nil`, `"0.10.1"`) `.unknown`; (`"beta"`, `"0.10.1"`) `.unknown`.
  - `testAlertTexts`: assert every row of the spec's Wording table exactly, e.g.
    ```swift
    XCTAssertEqual(InstallLocationAlertText.moveOffer(inHomeFolder: false), .init(
      title: "Move Enigma to Applications?",
      message: "Enigma can only update itself from the Applications folder. It will move there and reopen.",
      confirmButton: "Move to Applications", cancelButton: "Not Now"))
    XCTAssertEqual(InstallLocationAlertText.replace(existingVersion: "0.10.2", runningVersion: "0.10.1", age: .newer).message,
      "Applications already has a newer Enigma (0.10.2). Replacing it installs 0.10.1. The old copy goes to the Trash.")
    XCTAssertEqual(InstallLocationAlertText.failure(reason: "The disk is full.").message,
      "The disk is full. Drag Enigma into Applications in Finder instead.")
    ```
    The failure alert's `confirmButton` is `"OK"` and `cancelButton` is `""` (no second button). Replace with `.older` and `.same` use the "older or same" row; `.unknown` (or a nil existing version) uses the "unknown" row.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/InstallLocationTests`
Expected: build fails, `InstallLocation` not found.

- [ ] **Step 3: Implement `Enigma/App/InstallLocation.swift`** with the interfaces above and the spec's `decide` rules in order. `isInApplicationsFolder`: `resolvingSymlinksInPath().standardizedFileURL.pathComponents` for the candidate and for each of `/Applications` and `<home>/Applications`; true when the folder's components are a strict prefix, compared with `caseInsensitiveCompare`. Resolve symlinks of the home path too. `age`: split on `.`, every part must parse as `Int` else `.unknown`; pad the shorter with zeros; compare lexicographically. Add both files to the project.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/InstallLocationTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git commit -m "Decide when Enigma should move into Applications"`.

---

### Task 2: `ApplicationMover` — copy, replace, quarantine, discard

**Files:**
- Create: `Enigma/App/ApplicationMover.swift`
- Create: `EnigmaTests/ApplicationMoverTests.swift`
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  ```swift
  struct ApplicationMover {
    enum MoveError: Error, Equatable, LocalizedError {
      case destinationExists           // replacingExisting was false
      case couldNotCreateFolder(String)
      case couldNotCopy(String)
      case couldNotReplace(String)     // quit/trash of the existing copy failed
      case couldNotRename(String)
      case couldNotClearQuarantine(String)
      var errorDescription: String? { get }  // one plain sentence, ending with "."
    }
    var fileManager: FileManager = .default
    var trash: (URL) throws -> Void
    var quitRunningCopy: (URL) -> Void
    init(fileManager: FileManager = .default,
         trash: @escaping (URL) throws -> Void = ApplicationMover.moveToTrash,
         quitRunningCopy: @escaping (URL) -> Void = ApplicationMover.quitRunningApplications)
    static func moveToTrash(_ url: URL) throws
    static func quitRunningApplications(at url: URL)
    func existingVersion(at url: URL) -> String?
    func install(from source: URL, to destination: URL, replacingExisting: Bool) throws
    func removeQuarantine(from bundle: URL) throws
    func discardOriginal(_ original: URL?, destination: URL)
  }
  ```
  The `String` payload is the underlying error's `localizedDescription`. `errorDescription` wording: `"Enigma couldn't create the Applications folder."`, `"Enigma couldn't copy itself into Applications."`, `"Enigma couldn't move the old copy to the Trash."`, `"Enigma couldn't finish moving into Applications."`, `"Enigma couldn't clear the download flag on the new copy."`, and for `.destinationExists` `"Applications already has a copy of Enigma."`.

- [ ] **Step 1: Write the failing tests** in `ApplicationMoverTests`. Helper `makeBundle(at: URL, version: String)` writes `Contents/Info.plist` (`CFBundleShortVersionString`), `Contents/MacOS/Enigma` (a few bytes), and `Contents/Frameworks/Fake.framework/Versions/A/Fake` with `Versions/Current → A` and `Fake → Versions/Current/Fake` symlinks. Helper `setQuarantine(_ url: URL)` uses `setxattr` with `XATTR_NOFOLLOW` and value `"0081;00000000;Safari;"`. A recording fake: `var trashed: [URL]`, `var quit: [URL]`; its `trash` moves the item into a temp `Trash/` folder so the destination is freed.
  - `testInstallCreatesMissingParentFolder`: destination `tmp/home/Applications/Enigma.app` where `Applications` is absent → exists afterwards with the source's version.
  - `testInstallWithoutExistingCopyLeavesOnlyEnigmaApp`: folder contents after install are exactly `["Enigma.app"]`.
  - `testRenamedSourceInstallsAsEnigmaApp`: source `Downloads/Enigma 2.app` → `Applications/Enigma.app` exists.
  - `testInstallReplacesExistingCopyAfterQuittingAndTrashing`: existing `0.10.0`, source `0.10.1`, `replacingExisting: true` → `quit == [destination]`, `trashed == [destination]`, `existingVersion(at: destination) == "0.10.1"`, quit recorded before trash.
  - `testInstallRefusesExistingCopyWhenNotReplacing`: throws `.destinationExists`; existing version still `0.10.0`; no staging item.
  - `testTrashFailureKeepsExistingCopy`: `trash` throws → error is `.couldNotReplace`; existing version still `0.10.0`; no item whose name starts with `.Enigma-`.
  - `testCopyFailureLeavesNoStagingItem`: source path does not exist → `.couldNotCopy`; destination folder has no `.Enigma-` item.
  - `testInstallClearsQuarantine`: quarantine set on the source bundle, its `Contents/MacOS/Enigma` and the framework binary → after install, `getxattr(..., XATTR_NOFOLLOW)` on the destination bundle, `Contents/MacOS/Enigma` and `Contents/Frameworks/Fake.framework/Versions/A/Fake` returns `-1` with `errno == ENOATTR`; `Versions/Current` is still a symlink.
  - `testRemoveQuarantineToleratesItemsWithoutTheAttribute`: no attribute anywhere → does not throw.
  - `testExistingVersion`: reads `0.10.0`; nil for a missing path; nil for a bundle without `Info.plist`.
  - `testDiscardOriginalTrashesIt`, `testDiscardOriginalSkipsNilAndDestination` (nothing trashed), `testDiscardOriginalSwallowsTrashErrors` (throwing `trash` → no throw, original still present).

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/ApplicationMoverTests`
Expected: build fails, `ApplicationMover` not found.

- [ ] **Step 3: Implement `Enigma/App/ApplicationMover.swift`** following the spec's `install` steps 1–5. Copy with `fileManager.copyItem(at:to:)` (it preserves symlinks and extended attributes). On any throw after the staging copy exists, remove the staging item before rethrowing. Rename with `fileManager.moveItem`. `removeQuarantine`: process the bundle URL itself, then every item from `fileManager.enumerator(at:includingPropertiesForKeys:options:[])` (symlinks are not descended), calling `removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)`; ignore `ENOATTR`, throw `couldNotClearQuarantine` otherwise. `moveToTrash` uses `FileManager.default.trashItem(at:resultingItemURL:)`. `quitRunningApplications(at:)`: `NSRunningApplication.runningApplications(withBundleIdentifier:)` filtered by `bundleURL` standardized equal to `url`, excluding the current process; `terminate()` each, then poll `isTerminated` every 0.1 s for up to 5 s, then `forceTerminate()`. `discardOriginal` logs failures with `NSLog("Unable to move the original Enigma to the Trash: %@", …)`. Add both files to the project.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/ApplicationMoverTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git commit -m "Add the mover that installs Enigma into Applications"`.

---

### Task 3: The launch prompt, relaunch, and docs

**Files:**
- Create: `Enigma/App/MoveToApplicationsPrompt.swift`
- Modify: `Enigma/App/ApplicationDelegate.swift` (in `applicationDidFinishLaunching`, after `NSApp.setActivationPolicy(.accessory)`, before `AppUpdater.shared.start()`)
- Modify: `Enigma.xcodeproj/project.pbxproj`, `docs/Updates.md`, `README.md`

**Interfaces:**
- Consumes: Task 1's `InstallLocation`, `InstallLocationContext`, `InstallLocationDecision`, `InstallLocationAlertText`, `age(ofExisting:comparedTo:)`; Task 2's `ApplicationMover` (`existingVersion`, `install`, `removeQuarantine`, `discardOriginal`, `MoveError.errorDescription`).
- Produces: `@MainActor enum MoveToApplicationsPrompt { static func runIfNeeded() -> Bool }`.

- [ ] **Step 1: Implement translocation detection** as `private static func translocationStatus(of url: URL) -> (isTranslocated: Bool, original: URL?)`. `dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)`, `dlsym` both symbols, `unsafeBitCast` to `@convention(c)` function types matching the C signatures in the spec (`CFURL`, `UnsafeMutablePointer<Bool>`, `UnsafeMutablePointer<Unmanaged<CFError>?>?`; the create function returns `Unmanaged<CFURL>?`, taken with `takeRetainedValue()`). Fallback when a symbol is missing or the call returns false: translocated iff `url.pathComponents.contains("AppTranslocation")`, original nil.

- [ ] **Step 2: Implement `runIfNeeded()`** per the spec's seven steps. Build alerts from `InstallLocationAlertText` (one private helper `makeAlert(_ text:, style:)`; skip the second button when `cancelButton` is empty). Read `alert.suppressionButton?.state == .on` immediately after the offer's `runModal()` and store `true` under `InstallLocation.dontAskAgainKey` before branching on the button. Running version: `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""`. For the failure alert pass `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`. `isDebugBuild` uses `#if DEBUG`.

- [ ] **Step 3: Implement the relaunch** as `private static func relaunch(_ app: URL)`: a `Process` with `executableURL = /bin/sh` and the spec's arguments `["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", "sh", "\(getpid())", app.path]`; `try process.run()`. If `run()` throws, show the failure alert with the `localizedDescription` and return false instead of quitting. On success, `NSApp.terminate(nil)` and return true.

- [ ] **Step 4: Hook it into `ApplicationDelegate`**: `if MoveToApplicationsPrompt.runIfNeeded() { return }` at the position given above. Add the file to the project.

- [ ] **Step 5: Build and run the full checks**

Run: `scripts/verify-xcode.sh build`, then `scripts/verify-xcode.sh test`, then `scripts/verify-xcode.sh analyze`.
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, `** ANALYZE SUCCEEDED **` with no new analyzer warnings in the three new files.

- [ ] **Step 6: Update docs**
  - `docs/Updates.md`: add a `## Moving into Applications` section after "What users see" covering: when the offer appears (translocated, or outside `/Applications` and `~/Applications`; never in Debug), the reopen-in-place case, the `~/Applications` fallback, the replace confirmation (old copy to the Trash), quarantine removal and why, **Not Now** vs **Don't ask again** (key `installLocation.dontAskToMove`), and the three files. In "How it is built" tests list, add `InstallLocationTests` and `ApplicationMoverTests`. In the manual check's "Install location matters" bullet, add that Enigma now offers to move itself, and add the spec's four-step manual check for the move as a new subsection marked not yet run.
  - `README.md` Install step 2: keep "Unzip it and drag `Enigma.app` into Applications." and add a sentence: "If you open it from somewhere else, Enigma offers to move itself there, because it can only update itself from Applications."
  - Check neither file gains home paths or other private info.

- [ ] **Step 7: Commit** — `git commit -m "Offer to move Enigma into Applications at launch"`.
