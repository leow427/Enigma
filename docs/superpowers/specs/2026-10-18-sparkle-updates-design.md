# Sparkle auto-updates — design

Status: approved design, not yet implemented. Date: 2026-10-18.

## Goal and users

Friends and family run Enigma from `/Applications/Enigma.app`. Today each new
version means downloading a DMG, replacing the app by hand and getting past
Gatekeeper again. This change lets an installed Enigma find, download and
install new versions by itself, without losing its macOS permissions.

The users are a handful of people the owner knows. The publisher is the owner,
releasing from their own Mac. The design keeps to the product's priorities: it
adds no work to the chat path, sends nothing about the user, and keeps no new
history.

## Decisions

1. **Signing stays on the free Personal Team for now.** Builds are signed
   "Apple Development" and are not notarized, so the first install still needs
   right-click → Open (or System Settings → Privacy & Security → Open Anyway).
   A later, one-time move to Developer ID and notarization is described under
   [Future: Developer ID](#future-developer-id-and-notarization) but not built.
2. **Updates are automatic and quiet.** Enigma checks once a day without
   Sparkle's "check automatically?" prompt, downloads updates by itself and
   installs them when it quits. Because a menu-bar app rarely quits, a
   **Restart to Update to X** menu item appears once an update is downloaded.
   Sparkle's gentle scheduled update reminders stop its alerts from taking
   focus from other apps. Settings → General has toggles for automatic checks
   and for automatic download and install.
3. **Approach A: release from a local script, appcast in the repository.**
   `scripts/release.sh <version>` builds, signs and publishes a release. The
   appcast is `appcast.xml` at the repository root on `main`, served from
   `https://raw.githubusercontent.com/leow427/Enigma/main/appcast.xml`. Update
   archives are GitHub release assets.
   - Rejected, B — release from GitHub Actions: CI would need the signing
     certificate and the EdDSA private key as secrets, and a free-team
     development certificate is awkward to use in CI. Revisit after the
     Developer ID move.
   - Rejected, C — appcast as a release asset behind
     `releases/latest/download/appcast.xml`: "latest" skips pre-releases (all
     current releases are pre-releases) and each release would replace the
     feed, losing its history.
4. **Out of scope:** delta updates, a beta channel, and system profiling.

## Architecture

### Sparkle dependency

- Sparkle 2 is added as a Swift package, pinned to an exact version (the
  latest stable 2.x when implemented; 2.10.0 at the time of writing, and at
  least 2.9 for Markdown release notes). It is linked only into the Enigma app
  target, not `EnigmaTests` or `Packages/LlamaBridge`.
- Sparkle's MIT license is added to `Enigma/Resources/ThirdPartyNotices.txt`
  in the same style as the llama.cpp entry.
- Enigma is not sandboxed, so none of Sparkle's sandbox XPC-service keys apply.
  Hardened Runtime stays on; Debug builds already use an Apple Development
  certificate, which Sparkle needs when library validation is on.

### `AppUpdater`

New file `Enigma/App/AppUpdater.swift`. It is the only file that imports
Sparkle.

- `protocol AppUpdating: ObservableObject` (main-actor) is what feature code
  depends on:
  - `func checkForUpdates()` and `var canCheckForUpdates: Bool`
  - `var automaticallyChecksForUpdates: Bool { get set }`
  - `var automaticallyDownloadsUpdates: Bool { get set }`
  - `var lastUpdateCheckDate: Date? { get }`
  - `var updateReadyToInstall: PendingUpdate?`, where `PendingUpdate` holds the
    display version
  - `func installPendingUpdate()`
- `@MainActor final class AppUpdater: NSObject, AppUpdating` owns one
  `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
  userDriverDelegate: self)`. Its `updater` (`SPUUpdater`) supplies
  `checkForUpdates()`, `canCheckForUpdates` (KVO-observable, republished),
  `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates` and
  `lastUpdateCheckDate`.
- Following the existing `.shared` pattern (`EnigmaAppearancePreference.shared`,
  `WelcomeSetup.shared`), `AppUpdater.shared` is created lazily and started from
  `ApplicationDelegate.applicationDidFinishLaunching` after the test-host early
  return, so hosted unit tests never start Sparkle.

**Restart nudge.** `AppUpdater` implements the `SPUUpdaterDelegate` method
`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, which Sparkle
calls when an automatically downloaded update is scheduled to install on quit.
It stores the block and the item's display version in `updateReadyToInstall`
and returns `true`. `installPendingUpdate()` calls the stored block, which
installs and relaunches without further UI. If the user quits normally instead,
Sparkle installs on termination as usual.

**Gentle reminders.** `AppUpdater` is the `SPUStandardUserDriverDelegate`:

- `supportsGentleScheduledUpdateReminders` returns `true`.
- `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`
  returns `immediateFocus`, so Sparkle shows a scheduled alert only when it
  would not take focus from another app.
- When Sparkle leaves the alert to us,
  `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` sets
  `updateReadyToInstall` (for `state.stage == .downloaded`) or an
  "Update to X available" pending state (for `.notDownloaded`, e.g. when
  automatic download is off or installing needs authorization).
- `standardUserDriverDidReceiveUserAttention(forUpdate:)` and
  `standardUserDriverWillFinishUpdateSession()` clear that state.

User-started checks are always shown by Sparkle's standard user driver.

**Debug builds.** Under `#if DEBUG`, `AppUpdater` implements
`updater(_:mayPerformUpdateCheck:error:)` and refuses
`.updatesInBackground` checks, so a run from Xcode never downloads an update
and replaces itself. A manual **Check for Updates…** still works for testing.

### Info.plist

`Enigma/Resources/Info.plist` gains:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `$(ENIGMA_UPDATE_FEED_URL)` — build setting, defaults to the raw `main` URL above |
| `SUPublicEDKey` | base64 public key printed by `generate_keys` |
| `SUEnableAutomaticChecks` | `YES` (checks start on without asking) |
| `SUAutomaticallyUpdate` | `YES` (default for automatic download and install) |
| `SUScheduledCheckInterval` | `86400` |

`SUEnableSystemProfiling` is left out (Sparkle's default is off).
`CFBundleShortVersionString` and `CFBundleVersion` change from the hardcoded
`1.0` / `1` to `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Sparkle
compares `sparkle:version`, which is `CFBundleVersion`, so the build number
must be a plain, increasing integer.

The integration change also sets `MARKETING_VERSION` to `0.9.1`, matching the
latest published tag, so the first `release.sh 0.10.0` passes its version
check (the project's current `1.0` would otherwise be "newer").

### User interface

- **Menu bar** (`MenuBarController`): `AppCommand` gains
  `restartToUpdate = "Restart to Update"` and
  `checkForUpdates = "Check for Updates…"`. The menu becomes Open, New Chat,
  Privacy Hide, separator, *Restart to Update to X* (only while an update is
  pending), Check for Updates…, Settings, separator, Quit.
  `MenuBarController` takes an `any AppUpdating` and refreshes the two items in
  `NSMenuDelegate.menuNeedsUpdate(_:)`: the restart item is hidden unless
  `updateReadyToInstall` is set and its title includes the version; Check for
  Updates… is enabled only when `canCheckForUpdates`. The "Update to X
  available" state reuses the restart item's slot with that title and calls
  `checkForUpdates()`.
- **Settings → General** (`GeneralSettingsPage` in `SettingsView.swift`): a new
  `EnigmaSectionHeader("Updates")` group, using the existing `EnigmaRow`,
  `EnigmaSwitch` and `EnigmaNote` controls per `UI-Style.md`:
  - "Check for updates automatically" — switch bound to
    `automaticallyChecksForUpdates`.
  - "Download and install updates automatically" — switch bound to
    `automaticallyDownloadsUpdates`, disabled while automatic checks are off.
  - "Version" — `CFBundleShortVersionString (CFBundleVersion)`, with a
    **Check Now** secondary button.
  - "Last checked" — `lastUpdateCheckDate`, relative, or "Never".

### Data flow

1. Launch: `ApplicationDelegate` starts `AppUpdater`; Sparkle schedules a
   check from `SUScheduledCheckInterval` and the last check time.
2. Daily check: Sparkle fetches `appcast.xml` over HTTPS and compares the
   newest item's `sparkle:version` with `CFBundleVersion`. Nothing about the
   Mac is sent (no profiling).
3. Download: with automatic download on, Sparkle downloads the zip from the
   GitHub release and verifies its EdDSA signature against `SUPublicEDKey`.
4. Ready: Sparkle calls `willInstallUpdateOnQuit`; the menu shows **Restart to
   Update to X**.
5. Install: on quit, or when the user picks the restart item, Sparkle replaces
   `/Applications/Enigma.app` in place and relaunches if asked. The bundle ID
   (`com.leow427.AISpotlight`) and signing identity are unchanged, so Screen
   Recording, Accessibility and Keychain approvals carry over.

The owner's own copy, built by `scripts/install-app.sh` from `main`, carries
the build number of the latest release, so it never sees that release as an
update. If it falls behind (hooks off, no reinstall), Sparkle updates it to
the published release like any other copy.

## Release pipeline: `scripts/release.sh <version>`

A POSIX `sh` script in the style of `scripts/install-app.sh` (`set -eu`, clear
messages). It stops at the first failure.

1. **Preflight.** On `main`; working tree clean; `HEAD` equals `origin/main`
   after a fetch; `<version>` is `X.Y.Z` and newer than the current
   `MARKETING_VERSION`; `docs/release-notes/<version>.md` exists; tag
   `v<version>` does not exist locally or on `origin`; `gh auth status`
   succeeds; Sparkle's tools are found.
2. **Bump.** Set `MARKETING_VERSION` to `<version>` and increment
   `CURRENT_PROJECT_VERSION` by one, in both Debug and Release configurations
   of `Enigma.xcodeproj/project.pbxproj`.
3. **Build and verify.** `xcodebuild archive` of the `Enigma` scheme, Release,
   with `-allowProvisioningUpdates` and the project's existing team and
   identity, as `install-app.sh` does. Then:
   - `codesign --verify --deep --strict` passes;
   - `codesign -dvv` shows the `runtime` flag;
   - `codesign -d --entitlements -` has no `com.apple.security.get-task-allow`
     (see `docs/Distribution.md`). If the free-team Apple Development export
     always includes it, record that as a known limitation instead of failing;
   - the designated requirement (`codesign -d -r-`) equals the one recorded
     from the previous release. A mismatch means the signing identity changed
     (for example after the yearly renewal of the free certificate) and every
     user would silently lose their permissions; the script stops. The
     previous requirement is read from the last release's zip, downloaded with
     `gh release download`, so no extra state is committed. For 0.10.0 the
     previous release (v0.9.1) has only a DMG; the script mounts it read-only
     and reads the app inside.
4. **Package.** `ditto -c -k --sequesterRsrc --keepParent Enigma.app
   Enigma-<version>.zip` (Sparkle's recommended command).
5. **Appcast.** Copy `docs/release-notes/<version>.md` beside the zip as
   `Enigma-<version>.md` and run Sparkle's `generate_appcast` on that folder
   with the committed `appcast.xml` in it:
   `--download-url-prefix https://github.com/leow427/Enigma/releases/download/v<version>/`,
   `--embed-release-notes`, `--maximum-deltas 0`, `--maximum-versions 0`, and
   `-o appcast.xml`. It signs the zip with the EdDSA key in the login keychain
   (default account `ed25519`). The script then checks that the new item has
   the expected `sparkle:version`, `sparkle:shortVersionString`, URL and an
   `sparkle:edSignature`.
6. **Publish**, in an order that never leaves a feed pointing at a missing
   file:
   1. commit "Release <version>" (version bump, `appcast.xml`, release notes)
      and tag `v<version>`;
   2. push only the tag;
   3. `gh release create v<version> Enigma-<version>.zip --notes-file
      docs/release-notes/<version>.md`;
   4. push `main`. The raw feed URL serves the new item only from here on.

`release.sh --dry-run <version>` runs steps 1–5 in a temporary copy (a
`git worktree` under the system temp folder) and prints the resulting appcast
diff. It commits, tags, pushes and uploads nothing.

**Where the tools live.** In an SPM checkout, Sparkle's binaries are in
`SourcePackages/artifacts/sparkle/Sparkle/bin/` under the DerivedData folder
the archive used. The script resolves the packages into its own DerivedData
path, as `install-app.sh` does, and uses `generate_appcast` from there.

### One-time setup

- Run `generate_keys` once. The private key stays in the login keychain; the
  printed public key goes into `SUPublicEDKey`.
- Back it up with `generate_keys -x <file>`, store the file in a password
  manager, then delete it. `generate_keys -f <file>` restores it on another
  Mac. On the free team there is no Developer ID fallback: losing this key
  means installed copies can never update again.

### First rollout

0.10.0 is the first release with Sparkle. Friends install it by hand one last
time: download `Enigma-0.10.0.zip` from the release page, unzip, drag
`Enigma.app` into Applications, and right-click → Open. Releases switch from
DMG to zip from then on. Older 0.9.x copies have no updater and are not in the
appcast.

## Failure handling

- **Background check fails** (offline, GitHub down, bad feed): silent; Sparkle
  logs it and tries again at the next interval. Nothing is shown.
- **User-started check fails:** Sparkle's standard error alert.
- **Bad signature:** a tampered or wrongly signed archive fails validation and
  is never installed. Sparkle accepts an app update if either the
  EdDSA check against the old key or the Apple code-signing check against the
  old app passes, and rejects an update that drops the key or the code
  signature. Validation is never turned off.
- **Install fails:** the old app stays in place and keeps working; the next
  cycle retries.
- **Install needs authorization** (a standard user without write access to
  `/Applications`): Sparkle downloads but cannot install silently; it falls
  back to its standard alert, which our gentle-reminder handling surfaces in
  the menu.
- No chat data, models or credentials are touched by an update.
- **Release script:** any failed step stops the script. Failures before step 6
  leave only local changes (`git restore`/delete the temp folder). If step 6.3
  fails after the tag was pushed, re-run `gh release create` or delete the tag;
  `main` and the live feed are still unchanged.

## Testing

Unit tests, offline and deterministic, in `EnigmaTests`:

- **Updater state:** a `FakeAppUpdater: AppUpdating` drives
  `MenuBarController`. The restart item is hidden without a pending update,
  shows "Restart to Update to 0.10.1" with one, and calls
  `installPendingUpdate()`; Check for Updates… follows `canCheckForUpdates` and
  calls `checkForUpdates()`.
- **Settings:** the General page's Updates switches read and write the fake's
  two flags; the download switch is disabled when checks are off.
- **Commands:** `AppCommandTests.testMenuCommandsHaveExpectedOrderAndTitles`
  is updated to the new list and order (not removed).
- **Bundle:** a test in `AppBundleTests` reads `Bundle.main.infoDictionary`:
  `SUFeedURL` is an `https` URL, `SUPublicEDKey` is non-empty base64,
  `SUEnableSystemProfiling` is absent or false, and `CFBundleVersion` is a
  plain integer.

Script: `scripts/release.sh --dry-run` on a clean `main` produces a signed zip
and an appcast item with the expected fields.

Manual end-to-end check, once before friends get 0.10.0 (the checklist lives
in `docs/Updates.md`):

1. Build a signed 0.10.0 with `ENIGMA_UPDATE_FEED_URL` set to a local test
   feed served from the Mac, and install it to `/Applications`. Grant Screen
   Recording and Accessibility.
2. Produce a 0.10.1 with `release.sh --dry-run`, put its zip and appcast in
   the test feed folder.
3. Confirm: automatic download, the **Restart to Update to 0.10.1** item,
   install and relaunch, the new version in Settings, and Screen Recording and
   Accessibility still granted.
4. Replace the zip with a tampered copy (one byte changed) and confirm Sparkle
   rejects it and 0.10.0 keeps running.

The test feed is set at build time through the `ENIGMA_UPDATE_FEED_URL` build
setting (passed to `xcodebuild`), not at run time. Sparkle does support both
alternatives: the `SPUUpdaterDelegate` method `feedURLString(for:)`, and a feed
URL stored in user defaults (Sparkle prefers it over Info.plist, but setting it
via `setFeedURL` is deprecated). Both would leave a redirect hook in every
shipped copy; the build setting keeps released builds fixed to the real feed.

## Documentation

- New `docs/Updates.md`: what users see (daily check, restart item, Settings
  toggles), what is and isn't sent, how to release with `release.sh`, the key
  backup and restore, and the manual end-to-end checklist.
- `docs/Distribution.md`: replace the "archive and distribute from Organizer"
  steps with a link to `docs/Updates.md`; keep the hardened-runtime and
  entitlement checks.
- `README.md`: an Install section for non-developers — download the latest
  zip from Releases, drag to Applications, right-click → Open the first time;
  later versions arrive automatically.
- `AGENTS.md`: list `scripts/release.sh` beside `install-app.sh`.

## Future: Developer ID and notarization

Documented now, built later, as one deliberate release:

- `release.sh` exports with a Developer ID Application identity, submits the
  zip with `xcrun notarytool submit --wait`, staples the app, and re-zips.
- The designated-requirement check accepts the identity change for that one
  release only (an explicit flag, e.g. `--accept-new-identity`), then records
  the new requirement.
- Sparkle keeps working because the EdDSA key is unchanged, and its rules
  allow changing the code-signing identity or the EdDSA key in one update, but
  not both.
- macOS ties Screen Recording and Accessibility approval to the code
  signature, so every user re-grants them once after that update. Its release
  notes must say so.
- After the move, Gatekeeper no longer needs right-click → Open, and releasing
  from GitHub Actions (approach B) can be reconsidered.

## Open items to confirm during implementation

| Item | Decided by |
| --- | --- |
| `--embed-release-notes` with a `.md` file writes `<description sparkle:format="markdown">`. The flag and `.md` input are documented; the exact output was not confirmed. If not, convert the Markdown to an HTML fragment (no DOCTYPE or body) in the script, which `generate_appcast` embeds by default. | First `--dry-run` output |
| `--maximum-deltas 0` creates no deltas (default is 5; the help text does not say what 0 does). Deltas need older archives in the folder, which the script never provides, so none should be made either way. | First `--dry-run` output |
| `generate_appcast` keeps existing appcast items whose archives are not in the folder (only the new zip is present). If it drops them, keep old items by merging, or accept a feed that lists only the latest release. | First `--dry-run` with a two-item feed |
| A local test feed over `http://127.0.0.1` is accepted by App Transport Security and Sparkle. If not, host the test feed and zip on a throwaway branch and pre-release, reached over HTTPS. | Manual end-to-end check |
| The free-team Release archive's entitlements, especially `get-task-allow`. | First `--dry-run` |
| Whether the free Personal Team certificate renewal changes the designated requirement (the DR check guards against it either way). | First renewal |
| Exact Swift spelling of each Sparkle delegate method in the pinned version (the docs show `standardUserDriverDidReceiveUserAttention(forUpdate:)`; others are mapped from the Objective-C headers). | Compiling against the pinned package |
| `ENIGMA_UPDATE_FEED_URL` is set in the project's build settings, not an `.xcconfig` file, where `//` would start a comment and cut the URL. | Implementation |

## Sources

- Sparkle documentation: <https://sparkle-project.org/documentation/>,
  customization (Info.plist keys), programmatic setup, publishing, and gentle
  reminders pages.
- Sparkle 2 headers and tools on the `2.x` branch of
  <https://github.com/sparkle-project/Sparkle>: `SPUUpdater.h`,
  `SPUUpdaterDelegate.h`, `SPUStandardUserDriverDelegate.h`,
  `SPUUserUpdateState.h`, `SPUUpdateCheck.h`, `SUUpdateValidator.m`, and
  `generate_appcast/main.swift`.
