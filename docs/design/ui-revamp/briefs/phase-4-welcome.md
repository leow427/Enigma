# Phase 4: Welcome Screen and Shared Controls

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debrief at the end of
[phase-3-character.md](phase-3-character.md). It describes the character, the
slot and stage API, the theme environment, and the snapshot helper you'll use.

## Goal

With "Use new UI" on, first-run setup uses the new design. With it off,
nothing changes. This phase also adds the shared controls that every later
screen reuses.

## What exists today

- `AI-Spotlight/App/WelcomeSetup.swift` has:
  - `WelcomeSetup`, the flow model. Its steps are welcome, models,
    connections, and walkthrough, plus the tour state.
  - `WelcomeSetupView`, the four steps.
  - `EnigmaHelloView`, the old animated lettering.
  - `WelcomeTourOverlay` and `WelcomeTourStep`, the six-stop tour over the
    main window.
  - `ChatGPTConnectionControls` and `ClaudeCodeConnectionControls`.
- The welcome uses `LocalModelChoiceCard` and `LocalModelOperationView`, from
  `AI-Spotlight/LocalInference/LocalModelManagerView.swift`.
  `LocalModelOnboardingView` is the model sheet that `AppShellView` presents
  from `modelAdvisor.isOnboardingPresented`.
- `AppShellView.welcomeShell` lays the welcome over the window and the tour
  overlay over the main window. The old shell forces
  `.preferredColorScheme(.dark)` and `NatureGlass` tint. Your new screens must
  not inherit either:
  - Give the new welcome its palette and color scheme explicitly, through the
    phase 3 theme modifier.
  - Check that `preferredColorScheme` from the old shell doesn't win.
  - Check that the new UI's preference doesn't leak into old screens that are
    still shown.
- Tests that cover this flow are in `LocalModelSelectionTests` (welcome
  behavior, rendering at minimum and default panel sizes, and editable chat
  after every exit), `AppCommandTests`, and `AppShellStateTests`. They must
  keep passing. Add the same coverage for the new views wherever those tests
  host the old ones.

## Design

The mockup's welcome is in [../main-window.html](../main-window.html), in the
`#wel` element and its CSS:

- the character in a 150 pt slot;
- "Enigma" and "A small assistant that lives on your Mac.";
- three monospace command lines, each starting with `›`;
- "Get started" with a `↵` keycap;
- the monospace hint "next: pick a local model, about a minute".

Only the first step is mocked. Design the models, connections, and
walkthrough steps in the same language:

- an opaque `background` canvas;
- semibold headings with slightly negative tracking;
- supporting text in `textSecondary`;
- monospace hints and stats in `textTertiary`;
- lists as hairline-divided plain rows with a selection dot, never cards or
  boxes;
- exactly one `accent`-filled button per step, with a `↵` keycap;
- Back as a text button;
- a monospace step counter such as `2/4`.

Use [../panel-and-settings.html](../panel-and-settings.html) as the reference
for rows and connection status. The character stays with you:

- After the first step, it moves to a smaller slot (about 40 pt) in the step
  header, gliding up.
- It thinks while hardware is detected or a model downloads and verifies.
- It shows the error state when an install or connection fails.
- It listens while you type an API key.

Keep every fact and safeguard from the current copy:
- memory and free storage;
- download size and verification;
- that speed estimates vary;
- that cloud and web search send requests online;
- the ChatGPT and Claude subscription billing and limit notes;
- that the Brave key is billed separately;
- that permissions are requested when you use a feature;
- that setup can be replayed from Settings.

You may tighten the wording, but don't drop any of these.

## Build

1. **Shared controls** in `AI-Spotlight/App/EnigmaControls.swift`. Each one
   reads the palette from the environment and has previews.
   - Button styles: primary (`accent` fill, `onAccent` label), secondary
     (outlined in `border`), and text.
   - A keycap.
   - A monospace hint.
   - A command line: `›`, then the command, then the description.
   - A text field style: opaque `surface`, `border` edge, and an `accent`
     focus ring.
   - A hairline-divided row: title, optional subtitle, optional trailing
     content, and an optional selection dot.
   - A selection dot.
   - A status line, like `● connected` or `○ not connected`, in monospace.

   Every control:
   - responds on press;
   - uses `EnigmaMotion` springs;
   - supports keyboard focus with the `accent` ring;
   - supports Increase Contrast.

   Don't add controls this phase doesn't use. Later phases add switches,
   menus, and the rest.

2. **`EnigmaWelcomeView`** (new file). It is the four steps plus the footer,
   and it drives the same `WelcomeSetup` model. All step logic stays in
   `WelcomeSetup`:
   - which choices to show;
   - whether you can continue;
   - start, finish, and replay.

   Add to that model any new logic, such as which character slot or state a
   step uses, with tests.
   - The view has to fit and scroll correctly at the panel's minimum size,
     640 × 420, and its default size, 1200 × 780.
   - "More Connection Settings" may still open the old `SettingsView` in this
     phase. Phase 5 replaces it, so leave a `// Phase 5:` note there.

3. **New-UI versions of the welcome's parts:**
   - the model choice row, replacing `LocalModelChoiceCard`;
   - the model operation and progress view, replacing
     `LocalModelOperationView`;
   - the ChatGPT and Claude Code connection controls.

   Same behavior, new look. Phase 5's Settings will reuse them, so give them
   clear names and put them next to the code they present. Restyle
   `LocalModelOnboardingView`'s sheet for the new UI the same way.

4. **Tour.** Restyle the tour card in the new design: an opaque `surface`
   card, the `border` edge, a monospace `1/6`, an End tour text button, and a
   primary Next button. The tour's anchors still point at the old
   main-window controls. Phase 6 adds anchors to the new ones.

5. **Flag wiring.** Changes to `AppShellView` and `WelcomeSetup.swift` are
   limited to:
   - choosing the new or old welcome, tour card, and onboarding sheet from
     `NewUIPreference.shared.isEnabled`;
   - placing the character stage so the welcome shows the character.

   The flag must apply immediately while the app runs. Put the stage where
   phase 6 can move it to the window root, so the character can fall from
   the welcome into the main page. That fall is phase 6's work.

6. **Tests.**
   - New logic.
   - The new welcome renders at both panel sizes.
   - Every exit leaves the chat editable, as the existing old-UI test checks.
   - The flag swaps the welcome while the app runs.
   - The shared controls' states that can be tested as logic.

7. **Screenshots.** Paper and Ink for each of the four steps at the default
   size, the first step at the minimum size, and the tour card. Save them to
   `docs/design/ui-revamp/screenshots/phase-4/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- With the flag off, the welcome, the tour, and the onboarding sheet are
  unchanged, and their existing tests pass unchanged.
- With the flag on, all four steps work end to end with the same outcomes:
  - install, or skip local models;
  - connect, or skip;
  - take the tour, or finish without it.
- The screenshots match the mockup's language, with no glass, gradient, or
  forest anywhere.

## Debrief

**Built.** With "Use new UI" on, setup uses `EnigmaWelcomeView`:

- the mockup's welcome step, with the character in a 150 pt slot;
- the models, connections, and walkthrough steps, each with a pinned header,
  the character in a 40 pt slot, a monospace `2/4` counter, hairline rows,
  and one primary button.

The character glides between the slots. It thinks while hardware is detected
and while a model downloads, shows the error state when something fails, and
listens while a key is typed.

The shared controls are in `EnigmaControls.swift`:

- the button styles, applied with `.enigmaButtonStyle(_:)`, with an accent
  focus ring driven by `@FocusState`;
- a keycap, a hint, a command line, a text field, a section header, a
  hairline, a selection dot, `EnigmaRow`, `EnigmaStatusLine`, and
  `EnigmaEdge` (for Increase Contrast);
- a test-marker hook, `.enigmaTestMarker`, that hosted tests use to click
  controls.

New-UI versions of these views are next to the code they present:

- the model row, progress view, and onboarding sheet
  (`EnigmaLocalModelViews.swift`);
- the ChatGPT and Claude Code connections
  (`EnigmaCloudConnectionControls.swift`);
- the permission rows (`EnigmaMacPermissionRows.swift`).

The new tour card lives in `EnigmaWelcomeView.swift`.

`WelcomeSetup` gains only an extension, which holds the step logic, the
character slot and state, and the model action. `.enigmaEmbeddedTheme` gives
new screens their palette inside the old dark shell without changing its
`preferredColorScheme`. Screenshots are in `screenshots/phase-4/`.

**Decisions.**

- **Models step.** Install and Next are merged into one primary button. A
  test shows it offers Continue exactly when the old Next was enabled.
- **Skipping local models.** "Don't use local models" is now a Skip choice
  row.
- **Connections step.** It shows Claude Code next to ChatGPT, which keeps the
  Claude billing notes the brief requires.
- **Return.** Return in the Brave key field saves the key. Return never
  starts a download: Install and Update have no shortcut, and no `↵` keycap.
- **Welcome exit.** The welcome still exits instantly, so the chat is
  immediately editable. The exit motion and the fall are phase 6 work.
- **Tour scrim.** The scrim is `background` at 60%.
- **Connection settings sheet.** "More connection settings" still opens the
  old Settings, forced dark, until phase 5.

**Review.** There were no blockers. The reviewer had three should-fix
findings, and all are fixed with hosted tests:

- Return in the key field pressed Continue instead of saving the key.
- Return could start a multi-GB download.
- The key save, Skip, Install, and Use interactions had no tests.

These nits are also fixed:

- stale phase numbers in code notes;
- Replay didn't show the grow-in;
- a bouncy selection dot;
- an `EnigmaRow` action closure that could bind ambiguously;
- progress-bar contrast;
- VoiceOver reading the `›` chevron;
- the focus ring, which now uses `@FocusState` and has a pixel test;
- the key-glyph font.

**Verification.**

- **Build and analyze:** succeeded, with no warnings.
- **Welcome, controls, character, and model-selection tests:** all pass. The
  coordinator re-ran the welcome, controls, and model-selection tests: 71
  executed, 1 skipped, 0 failed.
- **Full suite:** 698 executed, 12 skipped, and only the 10 known
  environmental failures in 9 tests (see the phase 3 debrief).

**Not yet checked by a person in the signed app:**

- the live glide between slots;
- Tab focus with keyboard navigation turned on;
- VoiceOver;
- Increase Contrast;
- the palette following the Mac's appearance live.
