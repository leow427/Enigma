# Building and installing Enigma

Enigma is a menu-bar app (`LSUIElement`), so it has no Dock icon. It targets
macOS 26.0 and builds from the shared `Enigma` scheme in `Enigma.xcodeproj`.

## Running from Xcode

Open `Enigma.xcodeproj`, select the `Enigma` scheme, and choose **Product → Run**.
Run uses the Debug configuration.

The app target uses automatic signing with an Apple Development team. If you
are not on the project's team, choose your own team under **Signing &
Capabilities**. Keep using the same team and identity: macOS ties Screen
Recording, Accessibility, Full Disk Access, Automation, and Keychain approvals
to the app's signature, and a stable identity lets them carry over between
builds.

The unsigned product of `scripts/verify-xcode.sh` is for automated checks only;
do not use it for permission testing. See [Testing.md](Testing.md).

## Installing a signed copy in /Applications

`scripts/install-app.sh` builds a signed Release copy of the current checkout
and installs it as `/Applications/Enigma.app`:

```sh
scripts/install-app.sh                 # build, install, and launch
scripts/install-app.sh --no-launch     # build and install only
scripts/install-app.sh --install-hooks # reinstall after each commit or pull on main
scripts/install-app.sh --remove-hooks  # stop reinstalling automatically
```

The script:

- builds the Release configuration with `-allowProvisioningUpdates`, using
  derived data in `~/Library/Caches/Enigma-Install/DerivedData`;
- signs with the project's Apple Development team, as a run from Xcode does, so
  permissions and Keychain access carry over between updates;
- checks the result with `codesign --verify --deep --strict`;
- quits a running installed copy and waits briefly for it to exit;
- copies the new app beside the old one and swaps it in with a rename;
- launches it (unless `--no-launch` is given).

Set `ENIGMA_INSTALL_DIR` to install somewhere other than `/Applications`.

Only one install runs at a time. A request that arrives during a build is
remembered, and one more build runs when the current one finishes, so the
installed app ends on the newest commit.

### Automatic reinstall hooks

`--install-hooks` writes `post-commit` and `post-merge` hooks into the
checkout's Git hooks directory. They are local and never committed. It will not
overwrite an existing hook that it did not create.

After a commit or a pull, each hook does nothing unless `main` is checked out.
On `main`, it runs `scripts/install-app.sh --if-running` in the background,
which rebuilds and reinstalls Enigma and relaunches it only if it was already
running. Output goes to `~/Library/Logs/Enigma-Install.log`.

`--remove-hooks` deletes only the hooks that `--install-hooks` created.

## Signing, Hardened Runtime, and entitlements

Hardened Runtime is on for both the Debug and Release configurations of the app
target. Code signing uses `Enigma/Resources/Enigma.entitlements`, which grants:

| Entitlement | Used for |
| --- | --- |
| `com.apple.security.automation.apple-events` | Sending an approved message through Messages. See [Messages.md](Messages.md). |
| `com.apple.security.personal-information.addressbook` | Showing contact names and finding recipients for `/messages`. |
| `com.apple.security.personal-information.location` | Approximate location for local weather and nearby places. |

Each has a matching usage description in `Enigma/Resources/Info.plist`, and
macOS still asks the user before granting access. The app requests no JIT,
unsigned-executable-memory, DYLD-environment, or library-validation exceptions,
and App Sandbox is not enabled.

The `LlamaBridge` package's llama.cpp framework is embedded in the app as
`Contents/Frameworks/llama.framework` and signed with the app. A downloaded
`llama-server` and the installed Codex and Claude Code CLIs run as separate
processes; they are not loaded into Enigma.

To inspect a signed build:

```sh
codesign -dvv /Applications/Enigma.app                         # flags include "runtime"
codesign --verify --deep --strict --verbose=2 /Applications/Enigma.app
codesign -d --entitlements - /Applications/Enigma.app
```

## Archiving and notarization

The scheme's Archive action builds Release. To make an archive, choose
**Product → Archive** in Xcode, then distribute it from the Organizer with the
appropriate identity. Archive again after any signing or entitlement change; an
existing archive keeps the settings it was built with.

The project is configured for Apple Development signing only. Developer ID
signing and notarization are not set up in the project or scripts and are
separate steps done from the Organizer or with Apple's tools. A distribution
export must not contain `com.apple.security.get-task-allow`. Passing tests does
not show that a build is notarized.

Before sharing a build, check with the signed app: a local model, a cloud
sign-in, screen and selection capture, a nearby or weather question, and
`/messages`. Automated tests cover mocked permission paths but cannot grant or
verify real macOS consent.

## The bundle identifier stays com.leow427.AISpotlight

The app is named Enigma, but its bundle identifier is still
`com.leow427.AISpotlight`. This is a deliberate choice. macOS keys permission
approvals, the app's preferences, and access to its Keychain items (stored under
services named `com.leow427.AISpotlight.*`) to the bundle identifier and
signature. Changing the identifier would make existing installs lose their
permissions, saved API keys, and settings. The test target's identifier,
`com.leow427.AISpotlightTests`, is unchanged as well.

For the same reason, Enigma keeps its chats, downloaded models, and other data in
`~/Library/Application Support/AI Spotlight`. That folder name is fixed in the
code, not derived from the bundle identifier, so renaming it would also need a
migration.
