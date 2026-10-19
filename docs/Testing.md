# Testing Enigma

Enigma's tests are one XCTest target, `EnigmaTests`, hosted inside the app. The
shared `Enigma` scheme runs them through the `Enigma.xctestplan` test plan. The
normal suite is offline and needs no accounts, models, or macOS permissions.

## The verification helper

Use `scripts/verify-xcode.sh` for local builds and test runs:

```sh
scripts/verify-xcode.sh build
scripts/verify-xcode.sh test
scripts/verify-xcode.sh analyze
```

The helper runs `xcodebuild <action>` on `Enigma.xcodeproj` with the `Enigma`
scheme and `platform=macOS` as the destination. It also:

- puts derived data in `/tmp/Enigma-Verification`, away from Xcode's own;
- sets `CODE_SIGNING_ALLOWED=NO`, so the product is unsigned;
- sets `REGISTER_WITH_LAUNCH_SERVICES=NO`, and unregisters any `Enigma.app` left
  in its Debug or Release products from Launch Services before and after the
  run, including when the run is interrupted. A hosted test app can register
  itself even with registration turned off, and this keeps macOS from opening
  the unsigned copy in place of your installed Enigma;
- runs the hosted test app in the background (see below).

Any further arguments go straight to `xcodebuild`. To run one test class or one
test:

```sh
scripts/verify-xcode.sh test -only-testing:EnigmaTests/ScreenViewTests
scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaThemeTests/testContrastRatioMatchesWCAGExtremes
```

To repeat a suite across fresh launches of the test host, without retrying
failures away:

```sh
scripts/verify-xcode.sh test -only-testing:EnigmaTests/ScreenViewTests \
  -test-iterations 10 -test-repetition-relaunch-enabled YES
```

### Background test host

By default the helper sets `TEST_RUNNER_ENIGMA_BACKGROUND_TESTS=1`. `xcodebuild`
passes `TEST_RUNNER_`-prefixed variables to the test host without the prefix, so
the app sees `ENIGMA_BACKGROUND_TESTS=1`. In a Debug test host, Enigma then uses
the accessory activation policy (no Dock icon) and hands focus back to the app
that was in front when the run started. Some tests activate the host on purpose,
for example when Settings calls `NSApp.activate`. After each test,
`TestFocusObserver` in `EnigmaTests/AppUITestSupport.swift` (the test bundle's
principal class) returns focus to the app you were using.

Hosted UI tests still put Enigma's floating panels on screen, and some make a
panel key, so a keystroke typed at that moment can briefly land in the panel.

CI and Xcode's Test action keep the foreground host, which the timing-sensitive
UI tests were tuned for. To reproduce that locally:

```sh
ENIGMA_FOREGROUND_TESTS=1 scripts/verify-xcode.sh test
```

### What CI runs

GitHub Actions (`.github/workflows/ci.yml`) runs on `macos-26` for pushes to
`main` and for pull requests. It runs only:

```sh
xcodebuild test -project Enigma.xcodeproj -scheme Enigma \
  -destination 'platform=macOS' -resultBundlePath "$RUNNER_TEMP/Enigma.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 120 CODE_SIGNING_ALLOWED=NO
```

Each test gets two minutes; the slowest normally takes about 10 seconds on
the runner. A test that runs longer is treated as hung: XCTest records a
spindump (a stack sample of every thread in the test host), fails that test,
and runs the rest of the suite in a fresh host. The job stops after 30
minutes as a last resort. When a run fails or is cancelled, its result bundle
is uploaded as the `Enigma-xcresult-…` artifact on the run's summary page.
Download it and open the `.xcresult` in Xcode to see each failure, its
attachments, and any spindump.

CI does not run the `build` or `analyze` actions, so run those locally when a
change could affect them. GitHub's macOS runners have Reduce Motion turned on;
tests that depend on animation set it explicitly with
`enigmaTestReduceMotion(_:)`.

### Stress runs on CI

A test that passes once can still fail now and then on GitHub's runners,
which are several times slower than a recent Mac and vary from run to run.
The **Stress tests** workflow (`.github/workflows/stress.yml`) measures that.
Five runners each build once and run the suite several times (six by
default, so 30 runs), with the same time allowances as CI and no retries.
A summary job then lists every run and how many runs each test failed in.

Start it from the repository's **Actions** tab: choose **Stress tests**, then
**Run workflow**. The inputs are the number of runs per runner and an optional
`-only-testing` filter, such as `EnigmaTests/ScreenViewTests`, to stress one
class or test. With the GitHub CLI:

```sh
gh workflow run stress.yml -f runs=6 -f only-testing=EnigmaTests/ScreenViewTests
```

To stress a change before it is merged, push it to a branch whose name starts
with `stress/`, which runs the workflow with the defaults:

```sh
git push origin HEAD:refs/heads/stress/my-change
```

The results are on the run's summary page. The run fails if any suite run
failed, and each failing run's result bundle and log are uploaded as
`stress-failures-…` artifacts. Delete the `stress/` branch when you are done.

## Screenshots and snapshot rendering

`EnigmaTests/EnigmaSnapshotSupport.swift` renders SwiftUI views offscreen into
sRGB bitmaps at 2x. Tests use it two ways:

- **Pixel checks** read colors from a rendered view (`render`, `capture`,
  `pixel`, `matches`). These always run.
- **Screenshot files** are written by `EnigmaSnapshot.save`, once in Paper and
  once in Ink, as `<name>-paper.png` and `<name>-ink.png`. They are written only
  when `ENIGMA_SNAPSHOT_DIR` names a folder; otherwise the calling test is
  skipped.

Pass the folder to the test host with the `TEST_RUNNER_` prefix, using an
absolute path:

```sh
TEST_RUNNER_ENIGMA_SNAPSHOT_DIR=/tmp/enigma-screenshots \
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaMainWindowTests
```

The screenshot tests live in the `EnigmaMainWindowTests`, `EnigmaConversationTests`,
`EnigmaSettingsTests`, `EnigmaWelcomeTests`, `EnigmaCharacterTests`, and
`EnigmaIconTests` classes. The committed screenshots of the redesigned UI are
under `docs/design/ui-revamp/screenshots/`; copy new ones there when the visible
UI changes materially. See [UI-Style.md](design/UI-Style.md) for the visual
reference.

## App icons

The app icon (`AppIcon`) and the menu bar template (`EnigmaMenuBarMark`) are drawn
from the character's Swift drawing code. After changing that drawing or
`EnigmaAppIcon`, redraw them into `Enigma/Resources/Assets.xcassets`:

```sh
scripts/generate-app-icons.sh
```

The script runs `EnigmaIconTests/testGenerateAppIdentityAssets` through the
verification helper with `TEST_RUNNER_ENIGMA_ICON_ASSET_DIR` pointing at the
asset catalog. Extra arguments go to `xcodebuild`. The rest of `EnigmaIconTests`
fails until the committed icons match a fresh render.

## Opt-in real-model and CLI checks

Some tests exercise real models, installed command-line tools, or signed-in
accounts. They are skipped unless you provide a configuration file or
environment variable, and they never run in CI.

- **Screen and vision:** the `ScreenNativeSmokeTests` and
  `ScreenSearchNativeSmokeTests` classes read JSON configuration files in `/tmp`.
  [Screen-Skill.md](Screen-Skill.md) describes the files and how to run them.
- **File Mode:** `FileModeRuntimeTests` has opt-in local-model, Codex, and
  evaluation checks, and `scripts/evaluate-file-mode.py` and
  `scripts/verify-file-mode-codex.py` run model evaluations and a Codex
  app-server check outside XCTest. See [File-Mode.md](File-Mode.md).

## Permissions need a stable signed build

Screen Recording, Accessibility, Full Disk Access, and Automation approvals are
tied to the app's code signature. The helper's product is unsigned and its
identity changes between builds, so macOS cannot keep an approval for it, and
the changing identity can invalidate approvals already granted. Do not use
it to test permission prompts, screen capture, the selection shortcut, or
Messages.

For interactive permission testing, run Enigma from Xcode with a stable Apple
Development identity, or install a signed copy with `scripts/install-app.sh`.
Both keep the same identity across rebuilds. See
[Distribution.md](Distribution.md).

Automated tests cover mocked permission states and fallbacks but cannot grant
or verify real macOS consent, multi-display capture, or live provider quality.

## Keeping tests deterministic and offline

- **No network.** Cloud, search, and download tests use injected transports
  (such as `ScreenTestTransport` in `ScreenTestSupport.swift`) or a custom
  `URLProtocol`. Credentials come from in-memory stores or injected Keychain
  calls, never the real Keychain.
- **No real CLIs.** Codex and Claude Code tests replace the executable with
  shell scripts, so no login or paid request is needed.
- **Isolated state.** Tests write to their own temporary directories and
  named `UserDefaults` suites, not the app's real data or preferences.
- **No fixed sleeps.** UI tests wait with `waitForUI`, a bounded poll of the
  condition they need (editor present, focus, hit testing, frame). A missing
  state fails at the call site.
- **Real clicks on real controls.** `TestControlMarker` places invisible,
  non-interactive markers behind buttons; `clickTestControl` sends a native
  mouse click at the marker's bounds instead of calling the button's action.
  No Accessibility permission is needed.
- **No first-run side effects.** In a test host, the app delegate does not start
  the real panel, so a test run shows no onboarding and does not ask for the
  personal Keychain.
- Do not delete, disable, or weaken a test to make a check pass, and add
  regression coverage for fixes where practical.
