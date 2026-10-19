# Updates

Installed copies of Enigma find, download and install new versions by
themselves through [Sparkle](https://sparkle-project.org) 2. The owner publishes
a release with one script, `scripts/release.sh`. The design is in
[superpowers/specs/2026-10-18-sparkle-updates-design.md](superpowers/specs/2026-10-18-sparkle-updates-design.md).

## What users see

- **A daily check.** Once a day Enigma fetches the update feed,
  `appcast.xml` on `main`, from
  `https://raw.githubusercontent.com/leow427/Enigma/main/appcast.xml`. It
  doesn't ask first whether to check. A failed background check is silent and is
  tried again the next day.
- **Quiet downloads.** With automatic download on, a new version downloads in
  the background and installs when Enigma quits.
- **Menu-bar items.** The Enigma menu has **Check for Updates…** at all times.
  Once an update has downloaded, **Restart to Update to X** appears above it
  and installs and relaunches straight away. If Sparkle found an update but
  could not download it by itself (automatic download is off, or installing
  needs an administrator), the same slot shows **Update to X Available…**,
  which opens Sparkle's update window. That item disappears once the user
  dismisses or skips the update; a downloaded update stays until it installs.
- **Gentle reminders.** Sparkle shows a scheduled update alert itself only
  near launch or after the user has been idle. At other times Enigma offers
  the update in the menu instead of interrupting.
- **Settings → General → Updates.** One switch turns the daily check on or off.
  Another turns automatic download and install on or off; it is unavailable
  while checks are off. The **Version** row shows the version and build, when
  Enigma last checked, and a **Check Now** button.

Updates keep the bundle identifier and the signing identity, so Screen
Recording, Accessibility, Full Disk Access, Automation and Keychain approvals
carry over. Chats, models and credentials are not touched.

Builds from Xcode (Debug) refuse background checks, so a development build
never replaces itself. **Check for Updates…** still works in Debug for
testing.

## Moving into Applications

Sparkle can only replace Enigma where it is installed. A quarantined download
opened from outside Applications runs from an App Translocation copy, a
random read-only path, and can never update. So at launch Enigma checks where
it runs and offers to move itself:

- **When it asks.** When Enigma is translocated, or runs from anywhere outside
  `/Applications` and `~/Applications` (subfolders count as inside). It never
  asks in Debug builds or in the hosted unit tests. Only Debug is excluded, so
  a Release build run from DerivedData (Profile or Archive in Xcode) does
  offer the move; choose **Not Now** or **Don't ask again** there.
- **Move offer.** **Move to Applications** copies Enigma to
  `/Applications/Enigma.app` (always named `Enigma.app`, even if the download
  was `Enigma 2.app`), moves the download to the Trash, and reopens the new
  copy once the old process has quit.
- **Home-folder fallback.** A standard account cannot write to
  `/Applications`, so Enigma moves to `~/Applications/Enigma.app` instead,
  creating the folder if needed. Sparkle updates there without an
  administrator password. There is no administrator path.
- **Reopen in place.** If Enigma is translocated but its original already
  sits in an Applications folder (for example, moved there with `mv`), the
  offer is **Reopen**: Enigma clears the download flag on the original and
  reopens it, without copying.
- **Replace confirmation.** If Applications already has an Enigma, a second
  alert names its version (and warns when it is newer). **Replace** quits that
  copy if it is running and moves it to the Trash; **Cancel** keeps everything
  as it was.
- **Quarantine removal.** A copy moved by anything other than Finder keeps
  `com.apple.quarantine` and would be translocated again. Enigma removes the
  attribute from the installed copy; the user has already approved this
  build, and the code signature is unchanged, so permissions carry over.
- **Not Now and Don't ask again.** **Not Now** keeps Enigma running where it
  is, and the offer returns at the next launch. Checking **Don't ask again**,
  with either button, stores `true` under the `UserDefaults` key
  `installLocation.dontAskToMove`, and Enigma never asks again.
- **Failures.** If any step fails, an alert gives the reason and suggests
  dragging Enigma into Applications in Finder; Enigma keeps running where it
  is. A staged copy is removed, and an existing copy is only touched once the
  new one is ready to take its place.

Three files implement it: `Enigma/App/InstallLocation.swift` (the decision,
version comparison and alert wording; no AppKit or file access),
`Enigma/App/ApplicationMover.swift` (copy, replace, quarantine removal,
trashing the original) and `Enigma/App/MoveToApplicationsPrompt.swift` (the
translocation check, the alerts and the relaunch). `ApplicationDelegate`
runs it before Sparkle starts, so nothing else starts in a process that is
about to quit. The design is in
[superpowers/specs/2026-10-19-move-to-applications-design.md](superpowers/specs/2026-10-19-move-to-applications-design.md).

## What is sent

The check is an HTTPS request for the feed. Sparkle's User-Agent names the app
and its version. System profiling (`SUEnableSystemProfiling`) is off, so
nothing about the Mac is sent. The update itself downloads from the GitHub
release.

## How it is built

- `Enigma/App/AppUpdater.swift` holds the state the menu bar and Settings read.
  It has no Sparkle types.
- `Enigma/App/SparkleUpdaterBackend.swift` is the only file that imports
  Sparkle. It owns an `SPUStandardUpdaterController` and reports to
  `AppUpdater.shared`. `ApplicationDelegate` starts it after launch, after the
  test-host early return, so hosted unit tests never start Sparkle.
- `Info.plist` sets `SUFeedURL` from the `ENIGMA_UPDATE_FEED_URL` build
  setting, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`
  and `SUScheduledCheckInterval` (86400 seconds). The version comes from
  `MARKETING_VERSION` and the build number from `CURRENT_PROJECT_VERSION`.
  Sparkle compares the build number, so it must be a plain integer that grows
  with every release.
- The feed URL is a project build setting rather than an `.xcconfig` value,
  because `//` starts a comment in `.xcconfig` files. A test build can point
  elsewhere with `xcodebuild … ENIGMA_UPDATE_FEED_URL=<url>`.

Tests: `AppBundleTests` (Info.plist keys, versions, the embedded framework),
`AppUpdaterTests` (state, the menu items, Debug checks) and
`EnigmaSettingsTests.testUpdateSwitchesAndCheckNowReachTheUpdater`. They use a
fake backend and stay offline. `InstallLocationTests` (the move decision,
version comparison and alert wording) and `ApplicationMoverTests` (install,
replace, quarantine removal and discarding the original, in a temporary
folder with a fake Trash) cover moving into Applications.

## One-time setup: the update signing key

Every update archive is signed with an EdDSA (Ed25519) key. Installed copies
trust only archives signed with the key whose public half is `SUPublicEDKey` in
`Info.plist`.

1. Resolve the packages (any build does this). Sparkle's tools are in the
   DerivedData folder under
   `SourcePackages/artifacts/sparkle/Sparkle/bin/`.
2. Run `generate_keys` once. It stores the private key in the login keychain
   and prints the public key, which goes into `SUPublicEDKey`.
3. Back up the private key: `generate_keys -x <file>`, store the file in a
   password manager, then delete it.
4. To release from another Mac, restore it with `generate_keys -f <file>`.

Losing the private key means installed copies can never update again: on the
free team there is no Developer ID signature for Sparkle to fall back on.

The first `release.sh` run on a Mac asks for keychain access to the key when
`generate_appcast` signs the archive. Choose **Always Allow** so later releases
do not stop at the prompt.

## Releasing

1. Write `docs/release-notes/<version>.md` in Markdown and commit it on `main`.
2. Optionally rehearse: `scripts/release.sh --dry-run <version>`.
3. Run `scripts/release.sh <version>` from a clean `main` that is level with
   `origin/main`.

The script works in `~/Library/Caches/Enigma-Release/` (its DerivedData and
the archive copy), outside the repository. It stops at the first failure:

1. **Preflight.** The version is `X.Y.Z` and newer than the current
   `MARKETING_VERSION`, the release notes exist, the tag `v<version>` doesn't
   exist locally or on `origin`, `gh` is signed in, and Sparkle's tools resolve.
   It also checks the branch is `main`, the tree is clean, and `HEAD` equals
   `origin/main` after a fetch.
2. **Bump.** `MARKETING_VERSION` becomes `<version>` and
   `CURRENT_PROJECT_VERSION` goes up by one, in both app configurations.
3. **Build and verify.** It runs `xcodebuild archive` (Release,
   `-allowProvisioningUpdates`) and checks the built version. `xcodebuild
   archive` leaves Sparkle's helpers ad-hoc signed, unlike an Organizer
   export, and a quarantined download may refuse to run them. So the script
   re-signs them with the app's own identity, read from the built app's
   certificate, and the hardened runtime. It follows
   [Sparkle's documented order](https://sparkle-project.org/documentation/sandboxing/#code-signing):
   `Installer.xpc`, `Downloader.xpc` (keeping its entitlements), `Autoupdate`,
   `Updater.app`, `Sparkle.framework`. Then it re-signs `Enigma.app`, keeping
   its entitlements. It then checks several things:
   - `codesign --verify --deep --strict` passes.
   - Every one of those items, plus `llama.framework` and the app, has the
     app's signing authority and the runtime flag.
   - The app's entitlements equal `Enigma.entitlements`, with no
     `get-task-allow`.

   It also
   compares the designated requirement with the previous GitHub release's app,
   taken from its zip, or for 0.9.x from its DMG mounted read-only. A changed
   requirement means every user would silently lose their permissions, so the
   script stops.
4. **Package.** `ditto -c -k --sequesterRsrc --keepParent` makes
   `Enigma-<version>.zip`.
5. **Appcast.** Sparkle's `generate_appcast` signs the zip with the keychain
   key and adds an item to `appcast.xml`. The options are
   `--embed-release-notes --maximum-deltas 0 --maximum-versions 0` and a
   download prefix of
   `https://github.com/leow427/Enigma/releases/download/v<version>/`. The
   script then checks the new item's `sparkle:version`,
   `sparkle:shortVersionString`, enclosure URL and `sparkle:edSignature`.
6. **Publish**, in an order that never leaves the live feed pointing at a
   missing file:
   1. commit `Release <version>` and tag `v<version>`;
   2. push the tag;
   3. `gh release create` with the zip and the release notes;
   4. push `main`. From this point on, the raw feed serves the new item.

Just before step 6, the script checks again that `origin/main` hasn't moved.
If anything fails before the release commit, it restores `project.pbxproj`
and `appcast.xml` in the checkout. If a later step fails, it prints how to
retry or undo:
- If the tag push fails, nothing is published. Push the tag again, or undo
  with `git tag -d` and `git reset --hard HEAD~1`.
- If `gh release create` fails after the tag was pushed, re-run it or delete
  the tag. `main` and the live feed are still unchanged.
- If pushing `main` fails after the release exists, the live feed is unchanged
  and safe. Run `git push origin main` again.

The previous release used for the signature check is the newest one that isn't
a draft. Pre-releases count, since v0.9.1 is one.

`--dry-run` runs steps 1–5 in a temporary detached worktree of `HEAD`. It
copies the zip, `appcast.xml` and `project.pbxproj` to
`~/Library/Caches/Enigma-Release/dry-run/<version>/`, prints the appcast diff,
and removes the worktree. In a dry run, the branch, clean-tree and
`origin/main` checks only warn, so it can be rehearsed from a feature branch.
Every other check still fails hard. It commits, tags, pushes and uploads
nothing. For the manual check below,
`ENIGMA_RELEASE_TEST_FEED_URL=<url> scripts/release.sh --dry-run <version>`
builds an app that checks a test feed instead. A real release refuses this
variable.

Releases are zips from 0.10.0 on; 0.9.x shipped as DMGs without an updater.
Friends install 0.10.0 by hand once: download the zip, drag `Enigma.app` into
Applications, and right-click → **Open** the first time.

## Resolved during implementation

| Question | Outcome |
| --- | --- |
| Do Markdown release notes embed? | Yes. With `--embed-release-notes`, `Enigma-<version>.md` becomes `<description sparkle:format="markdown">` with the Markdown in CDATA, so no conversion is needed. |
| Does `--maximum-deltas 0` make deltas? | No. The 0.10.0 dry run wrote one item and no delta files or `sparkle:deltas`. |
| Does `generate_appcast` keep older items whose archives are not in the folder? | Yes. A dry run of 0.10.1 against a feed already holding 0.10.0 (build 2) kept that item and added 0.10.1 (build 3): "Wrote 1 new update, updated 0 existing updates, and removed 0 old updates". `--maximum-versions 0` keeps every item. |
| Does the free-team Release archive carry `get-task-allow`? | No. The archived app's entitlements are just the three in `Enigma.entitlements`. It is signed "Apple Development" with the hardened runtime. `release.sh` now fails if that changes. |
| Are Sparkle's helpers signed in the archive? | No: `Installer.xpc`, `Downloader.xpc`, `Autoupdate` and `Updater.app` come out of `xcodebuild archive` ad-hoc signed. `release.sh` re-signs them, as described in step 3. |
| Does 0.10.0 keep v0.9.1's designated requirement? | Yes, compared against the app in the v0.9.1 DMG. |
| Exact Sparkle 2.10.0 Swift spellings | `updater(_:mayPerform:) throws`, `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, `updater(_:didFinishUpdateCycleFor:error:)`, `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`, `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`, `standardUserDriverDidReceiveUserAttention(forUpdate:)`, `standardUserDriverWillFinishUpdateSession()`. |
| Does a local `http://127.0.0.1` test feed work? | Yes; Sparkle fetched the feed and update over it (see the manual check below). |
| Does renewing the free certificate change the designated requirement? | Unknown until the first renewal; `release.sh` stops if it does. |

## Manual end-to-end check

Before friends get 0.10.0, the owner runs this once with a real signed
install, because it needs macOS permission prompts:

1. Build a signed 0.10.0 with `ENIGMA_UPDATE_FEED_URL` pointing at a local
   test feed served from the Mac, and install it to `/Applications`. Grant
   Screen Recording and Accessibility.
2. Produce a 0.10.1 with `scripts/release.sh --dry-run 0.10.1`, and put its
   zip and `appcast.xml` in the test feed folder.
3. Confirm all of these: the update downloads automatically, the **Restart to
   Update to 0.10.1** item appears, it installs and relaunches, Settings shows
   the new version, and Screen Recording and Accessibility are still granted.
4. Replace the zip with a tampered copy (one byte changed). Confirm that
   Sparkle rejects it and 0.10.0 keeps running.

Result (2026-10-18, run with a 0.10.0 zip quarantined like a Safari
download, served from `http://127.0.0.1:8000`):

- **First open:** right-click → Open offered only Done / Move to Trash;
  System Settings → Privacy & Security → **Open Anyway** was needed, as
  expected for a build that is not notarized.
- **Install location matters:** moved into `/Applications` from Terminal,
  the quarantined app ran from an App Translocation copy and fetched nothing.
  Dragged from Downloads into Applications in Finder, it ran in place and
  checked at launch. Friends should drag the app into Applications in Finder
  before opening it; since the move to Applications was added, Enigma
  offers to move itself there when they don't (see
  [Moving into Applications](#moving-into-applications)).
- **First launch:** Sparkle does not check on an app's first launch; it
  records the check time and waits a day.
- **Automatic update:** passed. The local `http` feed works. Enigma fetched
  the appcast and the 0.10.1 zip, showed **Restart to Update to 0.10.1**, and
  relaunched as 0.10.1 (3) with a valid signature. **Check for Updates…**
  then reported it was up to date. Screen Recording (and audio) access was
  still granted after the update; Accessibility was not checked separately.
- **Tampered update:** passed. Sparkle downloaded the zip with one byte
  changed, refused to install it with an error, and 0.10.0 (2) kept running.

### Manual check: moving into Applications

Not yet run. With a signed Release build zipped and quarantined like a
download:

1. Open it from Downloads. The move offer appears; accept. Enigma reopens from
   `/Applications/Enigma.app`, is not translocated (`ps` shows the real path),
   and the download is in the Trash.
2. With an older copy already in `/Applications`, the replace confirmation
   names both versions.
3. Move a quarantined copy into `/Applications` with `mv` and open it. The
   reopen offer appears, and after **Reopen** it runs in place.
4. **Not Now** returns at the next launch; **Don't ask again** stops it.

## Future: Developer ID and notarization

This is planned as one deliberate release. `release.sh` would sign with a
Developer ID Application identity, notarize with `xcrun notarytool submit
--wait`, staple, and re-zip. The designated-requirement check would accept the
identity change for that one release only, through an explicit flag such as
`--accept-new-identity`. Sparkle accepts it because the EdDSA key is unchanged.
macOS ties Screen Recording and Accessibility approval to the signature, so
every user re-grants them once, and that release's notes must say so.
Afterwards Gatekeeper no longer needs right-click → Open, and releasing from
GitHub Actions can be reconsidered.
