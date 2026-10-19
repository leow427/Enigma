# Move to Applications — design

Status: approved design, not yet implemented. Date: 2026-10-19.

## Goal and users

Friends install Enigma from a zip on GitHub Releases. Enigma updates itself
through Sparkle ([Updates.md](../../Updates.md)), but only when it runs from
where it is installed. The manual end-to-end check found that a quarantined
Enigma that Finder did not move into Applications runs from an App
Translocation copy (a random, read-only path under
`/private/var/folders/.../AppTranslocation/`). Sparkle cannot replace that copy
and fetched nothing. Dragging the app into Applications in Finder fixed it.

This change makes a misplaced Enigma offer, at launch, to move itself into
Applications and reopen, so that friends who skip the drag still get updates.
Success: a translocated or misplaced Enigma offers the move. After the friend
accepts, Enigma relaunches from Applications, runs in place (not translocated),
and Sparkle can update it.

## Decisions

1. **Ask at every launch until moved, with an opt-out.** A translocated copy
   can never update, so declining once is not remembered. The alert has a
   **Don't ask again** checkbox (`NSAlert.showsSuppressionButton`). Checking it
   stores `true` under the `UserDefaults` key `installLocation.dontAskToMove`,
   and Enigma never asks again.
2. **Without write access to `/Applications`, use `~/Applications`.** A
   standard (non-admin) account cannot write to `/Applications`. Enigma then
   moves to `~/Applications/Enigma.app`, creating the folder if needed. Sparkle
   updates there without an administrator password. There is no admin
   authorization path.
3. **An existing copy is replaced only after confirmation, and goes to the
   Trash.** The confirmation names both versions and warns when the existing
   copy is newer.
4. **Approach A: our own small mover, no new dependency.**
   - Rejected, B — vendor LetsMove: Objective-C, largely unmaintained since
     2020, brings its own localized wording, and uses the deprecated
     `AuthorizationExecuteWithPrivileges` for the admin path we do not want.
   - Rejected, C — path check only: without the original path, the download is
     left behind and the "reopen in place" case below cannot be recognized.
5. **Debug builds and hosted unit tests never offer the move.** Debug builds
   run from DerivedData, like Sparkle's refusal of background checks in Debug.
   The check runs after `ApplicationDelegate`'s test-host early return.
6. **Quarantine is removed from the installed copy.** A copy moved by a
   process other than Finder keeps `com.apple.quarantine` and would be
   translocated again on relaunch. The user has already approved this build
   (it is running), and Sparkle and LetsMove both remove the attribute after
   installing. Gatekeeper only assesses quarantined apps, so the relaunch is not
   blocked. The code signature is unchanged, so Screen Recording,
   Accessibility and other signature-based approvals carry over.

## Architecture

Three new files in `Enigma/App/`, added to the `Enigma` target in
`Enigma.xcodeproj`. Two new test files in `EnigmaTests/`.

### `InstallLocation.swift` — pure decision and wording

No AppKit, no file-system access, no globals. Everything is passed in.

```swift
struct InstallLocationContext: Equatable {
  /// `Bundle.main.bundleURL`; may be a translocated path.
  var bundleURL: URL
  var isTranslocated: Bool
  /// The bundle's real location when translocated and the system reports it; else nil.
  var originalURL: URL?
  var homeDirectory: URL
  var systemApplicationsIsWritable: Bool
  var dontAskAgain: Bool
  var isDebugBuild: Bool
}

enum InstallLocationDecision: Equatable {
  case stay
  /// Translocated, but the original already sits in an Applications folder.
  case reopenInPlace(original: URL)
  case move(destination: URL, inHomeFolder: Bool)
}

enum InstallLocation {
  static let dontAskAgainKey = "installLocation.dontAskToMove"
  static func decide(_ context: InstallLocationContext) -> InstallLocationDecision
  /// True when `url` is inside `/Applications` or `<home>/Applications`.
  static func isInApplicationsFolder(_ url: URL, homeDirectory: URL) -> Bool
}
```

Rules for `decide`, in order:

1. `isDebugBuild` or `dontAskAgain` → `.stay`.
2. Not translocated and `isInApplicationsFolder(bundleURL)` → `.stay`.
3. Translocated, `originalURL` known and inside an Applications folder →
   `.reopenInPlace(original:)`.
4. Otherwise → `.move`, to `/Applications/Enigma.app` when
   `systemApplicationsIsWritable`, else `<home>/Applications/Enigma.app`
   (`inHomeFolder: true`).

`isInApplicationsFolder` resolves symlinks and standardizes both paths, then
compares path components, case-insensitively, as a strict prefix. So
`/ApplicationsFoo/Enigma.app` and `/Applications` itself do not count, and
`/Applications/Utilities/Enigma.app` does. The destination name is always
`Enigma.app`, whatever the running bundle is called (a duplicate download may
be `Enigma 2.app`).

Version comparison and alert text are also pure:

```swift
enum ExistingCopyAge: Equatable { case older, same, newer, unknown }

enum InstallLocation {
  /// Compares dotted numeric versions ("0.10.2" vs "0.10.1"); nil or non-numeric → .unknown.
  static func age(ofExisting existing: String?, comparedTo running: String) -> ExistingCopyAge
}

struct InstallLocationAlertText: Equatable {
  var title: String
  var message: String
  var confirmButton: String
  var cancelButton: String

  static func moveOffer(inHomeFolder: Bool) -> Self
  static let reopenOffer: Self
  static func replace(existingVersion: String?, runningVersion: String, age: ExistingCopyAge) -> Self
  static func failure(reason: String) -> Self
}
```

### `ApplicationMover.swift` — file operations

A `struct ApplicationMover` whose side effects outside the given folders are
injected, so tests can run it in a temporary directory:

```swift
struct ApplicationMover {
  var fileManager: FileManager = .default
  /// Moves an item to the Trash. Default: `FileManager.trashItem`.
  var trash: (URL) throws -> Void
  /// Quits any running Enigma whose bundle is at the URL and waits briefly
  /// for it to exit. Default: `NSRunningApplication` by bundle URL, `terminate()`.
  var quitRunningCopy: (URL) -> Void

  /// Bundle version of an existing copy at `url` (CFBundleShortVersionString), or nil.
  func existingVersion(at url: URL) -> String?

  /// Installs `source` at `destination`. Throws `MoveError` on failure.
  func install(from source: URL, to destination: URL, replacingExisting: Bool) throws

  /// Removes `com.apple.quarantine` from `bundle` and everything inside it.
  func removeQuarantine(from bundle: URL) throws

  /// Trashes the downloaded original; logs and ignores failures.
  func discardOriginal(_ original: URL)
}
```

`install` steps:

1. Create the destination's parent folder if missing (the `~/Applications`
   case).
2. Copy `source` to a hidden staging name in the same folder,
   `.Enigma-<UUID>.app`, so the final step is a same-volume rename.
3. If an item exists at `destination`: if `replacingExisting` is false, throw.
   Otherwise call `quitRunningCopy(destination)`, then `trash(destination)`.
4. Rename the staged copy to `destination`.
5. `removeQuarantine(from: destination)`.

If any step up to 4 fails, the staged copy is removed. An existing copy is
untouched unless it was already in the Trash when the rename failed. The error
names the step for the failure alert. `removeQuarantine` walks the bundle
(including the bundle directory itself and symlinks, without following them)
and calls `removexattr` for `com.apple.quarantine`, ignoring `ENOATTR`.

`discardOriginal` is called with the original location: `originalURL` when
translocated, else `bundleURL`. It does nothing when the original is unknown or
equals the destination. A failure, for example on a read-only disk image, is
logged with `NSLog` and the original is left alone.

### `MoveToApplicationsPrompt.swift` — the AppKit layer

```swift
@MainActor enum MoveToApplicationsPrompt {
  /// Returns true when Enigma is relaunching and launch should stop.
  static func runIfNeeded() -> Bool
}
```

It:

1. Builds the context: `Bundle.main.bundleURL`, translocation status and
   original path (below), `FileManager.default.homeDirectoryForCurrentUser`,
   `FileManager.isWritableFile(atPath: "/Applications")`, the
   `dontAskAgain` default, and `#if DEBUG`.
2. Calls `InstallLocation.decide`. On `.stay` it returns false.
3. Activates the app (`NSApp.activate()`, since Enigma is an accessory app) and
   shows the offer as a modal `NSAlert` with the suppression checkbox. If the
   checkbox is checked, it stores `dontAskAgain`, whichever button was chosen.
   On **Not Now** it returns false.
4. For `.move`, if `destination` exists, reads its version and shows the
   replace confirmation. **Cancel** returns false; the offer comes back next
   launch.
5. Runs the mover. For `.reopenInPlace`, it only calls
   `removeQuarantine(from: original)`. For `.move`, it calls `install`, then
   `discardOriginal`.
6. On failure, shows the failure alert and returns false. Enigma keeps running
   from where it is.
7. On success, relaunches and returns true.

**Translocation detection.** `dlopen` Security.framework and `dlsym`
`SecTranslocateIsTranslocatedURL` and
`SecTranslocateCreateOriginalPathForURL`. These are SPI with stable C
signatures used by LetsMove and Sparkle:

```c
Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef *error);
CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef translocatedPath, CFErrorRef *error);
```

If the symbols are missing or fail, Enigma treats a bundle path containing
the component `AppTranslocation` as translocated, with the original unknown.

**Relaunch.** Start `/bin/sh -c 'while /bin/kill -0 "$1" 2>/dev/null; do
/bin/sleep 0.2; done; /usr/bin/open "$2"' sh <pid> <app path>` through
`Process`, then `NSApp.terminate(nil)`. The new copy starts only after this
process has exited, so the two never hold the global shortcuts at once.

### `ApplicationDelegate`

In `applicationDidFinishLaunching`, directly after the test-host early return
and `setActivationPolicy(.accessory)`, and before `AppUpdater.shared.start()`:

```swift
if MoveToApplicationsPrompt.runIfNeeded() { return }
```

Sparkle, the menu bar, shortcuts and the panel therefore do not start in a
process that is about to quit.

## Wording

Plain, short sentences, as in `docs/design/UI-Style.md`. Enigma shows its
versions as "0.10.1".

| Alert | Title | Message | Buttons |
| --- | --- | --- | --- |
| Move offer | Move Enigma to Applications? | Enigma can only update itself from the Applications folder. It will move there and reopen. | **Move to Applications** / **Not Now**, checkbox **Don't ask again** |
| Move offer, home folder | Move Enigma to Applications? | Enigma can only update itself from an Applications folder. It will move to the Applications folder in your home folder and reopen. | as above |
| Reopen in place | Reopen Enigma from Applications? | macOS is running Enigma from a temporary copy, so it can't update itself. Enigma will reopen from Applications. | **Reopen** / **Not Now**, checkbox **Don't ask again** |
| Replace, older or same | Replace the Enigma in Applications? | Applications already has Enigma 0.10.0. The old copy goes to the Trash. | **Replace** / **Cancel** |
| Replace, newer | Replace the Enigma in Applications? | Applications already has a newer Enigma (0.10.2). Replacing it installs 0.10.1. The old copy goes to the Trash. | **Replace** / **Cancel** |
| Replace, unknown | Replace the Enigma in Applications? | Applications already has a copy of Enigma. The old copy goes to the Trash. | **Replace** / **Cancel** |
| Failure | Enigma couldn't move to Applications | `<reason>` Drag Enigma into Applications in Finder instead. | **OK** |

In the replace texts "Applications" means the destination folder; for the home
folder case the text still says "Applications", which is what Finder shows.

## Failure handling

| Situation | Result |
| --- | --- |
| No write access to `/Applications` | Move to `~/Applications` (decision 2). |
| `~/Applications` cannot be created or written | Failure alert; Enigma runs in place. |
| Copy fails (disk full, permissions) | Staged copy removed; failure alert; runs in place. |
| Existing copy cannot be trashed | Staged copy removed; existing copy untouched; failure alert. |
| Existing copy is running | Quit first, then trashed. |
| Original cannot be trashed (read-only disk image) | Logged; original left; relaunch continues. |
| Quarantine cannot be removed | Failure alert after install; the installed copy stays; Enigma runs in place. |
| Translocation SPI missing | Path fallback; original unknown, so it is not trashed. |
| User declines | Runs in place; asked again next launch unless **Don't ask again** was checked. |

## Testing

Offline and deterministic. Nothing in the tests calls the SPI, shows an alert,
relaunches, or touches `/Applications`, the Trash or `UserDefaults.standard`.

- `EnigmaTests/InstallLocationTests.swift`:
  - every `decide` branch: Debug, don't ask again, in `/Applications`, in a
    subfolder of it, in `~/Applications`, in Downloads with and without write
    access, translocated with the original in Applications, translocated with
    the original in Downloads, translocated with the original unknown;
  - `isInApplicationsFolder`: `/ApplicationsFoo`, `/Applications` itself,
    different case, a symlinked home folder (a temporary directory);
  - `age(ofExisting:comparedTo:)`: older, same, newer, `"0.10"` vs
    `"0.10.0"` (same), nil and non-numeric (unknown);
  - every alert text in the table above.
- `EnigmaTests/ApplicationMoverTests.swift`, in a temporary directory with a
  fake bundle (`Contents/Info.plist` with a version) and fake `trash` and
  `quitRunningCopy` closures:
  - install into a missing parent folder creates it;
  - install with no existing copy leaves only `Enigma.app` (no staging item);
  - install over an existing copy calls quit, then trash, and the new contents
    win;
  - install over an existing copy with `replacingExisting: false` throws and
    leaves the existing copy;
  - a throwing `trash` leaves the existing copy and no staging item;
  - `removeQuarantine` clears the attribute from the bundle and a nested file;
  - `existingVersion(at:)` reads the version, and returns nil for a missing
    or malformed bundle;
  - `discardOriginal` trashes the original, skips nil and the destination,
    and swallows a trash error.

Manual check, recorded in `docs/Updates.md`, with a signed Release build zipped
and quarantined like a download:

1. Open it from Downloads. The move offer appears; accept. Enigma reopens from
   `/Applications/Enigma.app`, is not translocated (`ps` shows the real path),
   and the download is in the Trash.
2. With an older copy already in `/Applications`, the replace confirmation
   names both versions.
3. Move a quarantined copy into `/Applications` with `mv` and open it. The
   reopen offer appears, and after **Reopen** it runs in place.
4. **Not Now** returns at the next launch; **Don't ask again** stops it.

## Documentation

- `docs/Updates.md`: a "Moving into Applications" section describing the
  offer, the home-folder fallback and the opt-out; the "Install location
  matters" note in the manual check updated; the new tests listed.
- `README.md`, Install: keep "drag `Enigma.app` into Applications", and add
  that if Enigma is opened from anywhere else it offers to move itself there.

## Out of scope

- An admin-password path into `/Applications`.
- A Settings row for install location or for undoing **Don't ask again**.
- Ejecting a disk image Enigma was opened from (releases are zips).
