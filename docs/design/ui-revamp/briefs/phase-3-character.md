# Phase 3: The Character

Read [../agent-workflow.md](../agent-workflow.md) and the spec first,
especially "The character", "Motion", and "Accessibility" in
[../README.md](../README.md).

## Goal

Build the lime character as a native SwiftUI component, along with the slot
system screens will use to place it. Nothing in the app changes yet. No screen
shows the character until phase 4, and `EnigmaCoalescenceView` stays until the
switchover.

## Source

The `Glyph` function in [../main-window.html](../main-window.html), starting
near line 187, is the reference implementation. Port its math faithfully:

- the outline radius by angle, made of lobes, the attention bump, ripples, and
  jitter;
- the porthole, which splits into three while thinking;
- the antenna, its spring, and its length cap of 1.25 × L;
- the three legs with dot feet, and the contact shadow;
- the mode table: idle, listen, think, answer, and error;
- the falls, with crouch, hop, gravity, stretch, landing squash, dust puffs,
  and impact lines;
- drag and throw.

[../panel-and-settings.html](../panel-and-settings.html) uses the same
function at panel size.

Slot sizes in the mockups:

| Slot | Size |
| --- | --- |
| Welcome | 150 pt |
| Main page | 92 pt |
| Compact panel | 40 pt |
| Chat reply | 30 pt |

The character must read well at every one of these sizes. At 30 pt the
outline thickness and jitter need to scale down so it doesn't turn to mush.

## Build

1. **Theme environment.** Add `EnvironmentValues.enigmaPalette` and a root
   modifier, for example `.enigmaTheme(_ appearance: EnigmaAppearance)`. The
   modifier resolves the palette from the appearance and the system color
   scheme. With `.paper` or `.ink` it also forces the matching
   `preferredColorScheme`, so native text and menus agree with the palette.
   Every new view reads colors from the palette. Phase 5 adds the saved
   Appearance setting. Keep this phase's part minimal.

2. **Simulation, a pure and testable model.** For example, an
   `EnigmaCharacterModel` struct with:
   - `step(dt:)`;
   - the state;
   - the events `key(towards:)`, `token()`, `poke()`, drag begin, move, and
     end with a release velocity, and `fall(to:)`;
   - output values for the drawing: outline points, holes, antenna, legs and
     feet, shadow, puffs, and impact lines.

   It must have no SwiftUI drawing and no wall-clock reads. The jitter (12
   times a second) uses a seeded random number generator keyed on the frame
   index, so a given time always gives the same outline. Use `EnigmaMotion`
   for the springs and `characterGravity`. Add named constants for the mode
   table's other values.

3. **Drawing.**
   - The character is a `Canvas` inside a `TimelineView(.animation)`.
   - Colors are `characterBody`, `characterInk`, and `warning` for the error
     state.
   - The fill rule is even-odd, so the holes cut through.
   - Pause the timeline when any of these is true:
     - the window is hidden or occluded (check `NSWindow.occlusionState`);
     - Reduce Motion is on;
     - the character has come fully to rest and has no work.

4. **Controller.** An `ObservableObject`, or `@Observable` if the code base
   already uses it, that screens hold to:
   - set the state;
   - send events, such as a `token()` per streamed token or a `key()` per
     keystroke.

5. **Slots and stage.**
   - Screens mark where the character sits with
     `.enigmaCharacterSlot(id:size:)`, using anchor preferences.
   - One `EnigmaCharacterStage` overlay at the window root draws the
     character at the active slot.
   - When the active slot changes, the stage moves the character:
     - if the new slot is below, it falls with gravity;
     - if the new slot is above, it glides there on `characterFollow`;
     - with Reduce Motion, it moves instantly.
   - Dragging and throwing happen on the stage, and the throw springs back to
     the slot carrying the release velocity.
   - A click pokes the character.

6. **Static mark.** Add an `EnigmaMark` view: the same body shape at rest,
   with no animation and no legs if that reads better at small sizes. Earlier
   chat replies show it where the character stood (spec, "Chat"). Make it work
   from 14 to 30 pt.

7. **Accessibility.**
   - The character is one element labeled "Enigma".
   - Its value reads "Idle", "Listening", "Thinking", "Answering", or
     "Something went wrong".
   - It is never a button, and VoiceOver users don't need to poke or drag it.
   - With Reduce Motion it stays still, the states still read through color
     and the hole, and slot moves are instant.

8. **Previews.** Add a `#Preview` for every state at the main page size, one
   at chat size, and a stage demo with two slots that shows a fall.

9. **Tests** (new test file, deterministic). At least:
   - the outline is closed, and its radius stays positive and bounded;
   - each state has the right base lobe count: 5 at rest, and thinking cycles
     through 3, 4, 6, and 7;
   - thinking splits the hole into three;
   - the antenna length never exceeds 1.25 × L;
   - a fall to a lower slot lands within a sensible time and settles exactly
     on the slot;
   - a move to a higher slot glides there instead of falling;
   - a throw carries its release velocity;
   - Reduce Motion places the character instantly and freezes the outline;
   - the same seed and time give the same outline;
   - the error state uses `warning`;
   - the accessibility label and value strings;
   - `enigmaTheme` resolves Paper, Ink, and System correctly.

10. **CPU check.**
    - Measure the cost of one simulation step plus building the paths, for
      example with a test using `measure` or a timed loop, and report the
      number.
    - The goal is well under 1 ms per frame on this Mac.
    - Confirm the timeline pauses when the view is hidden. Test the pause
      decision as logic, if you can.

11. **Snapshot helper** (`AI-SpotlightTests/EnigmaSnapshotSupport.swift`).
    - It renders a SwiftUI view to PNG through `NSHostingView` and
      `cacheDisplay(in:to:)`, in Paper and Ink, at 2x.
    - It writes the files only when `ENIGMA_SNAPSHOT_DIR` is set, and the
      calling tests are skipped otherwise.
    - Use it to save every state in Paper and Ink, plus `EnigmaMark`, to
      `docs/design/ui-revamp/screenshots/phase-3/`.
    - Later phases reuse this helper, so keep its API small and clear.

12. **Spec.** Update the "Implementation" paragraph under "The character" in
    the spec if the type names or the approach differ from what it says.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- The app looks and behaves as before, with the flag on or off.
- The screenshots show a character that matches the mockup's look: a flat lime
  body, a thick dark outline, the porthole, the antenna with its ball, three
  legs with dot feet, and the soft shadow.
- The tests listed above exist and pass.
- The CPU cost is reported.

## Debrief

**Built.** The phase added these parts:

- `EnigmaCharacterModel.swift`: a pure simulation. It has no clock reads,
  uses seeded per-frame jitter, and includes `stillFrame` for the still pose.
- `EnigmaCharacterDrawing.swift`: `EnigmaCharacterRenderer` and `EnigmaMark`,
  with outline and filled styles. The mark is drawn from the character's still
  pose.
- `EnigmaCharacterStage.swift`: `EnigmaCharacterController`, the
  `.enigmaCharacterSlot(id:size:)` and `.enigmaCharacterTarget` anchors, and
  the `.enigmaCharacterStage(_:)` overlay. The overlay handles drag, throw,
  and poke, reads occlusion, presents one accessibility element, and sets the
  pacing.
- `EnigmaTheme.swift`: `enigmaPalette` and `.enigmaTheme(_:)`.
- `EnigmaSnapshotSupport.swift`: the snapshot helper. It writes Paper and Ink
  PNGs at 2x, and only when `ENIGMA_SNAPSHOT_DIR` is set.
- `EnigmaCharacterTests.swift`: 26 tests.

Screenshots are in `screenshots/phase-3/`. No screen uses the character yet,
so the app is unchanged.

**Use.** Screens use the character like this:

1. Create `@StateObject var character = EnigmaCharacterController()`.
2. At the window root, apply `.enigmaTheme(...)` and then
   `.enigmaCharacterStage(character)`.
3. Mark each slot with `.enigmaCharacterSlot(id:size:)`.
4. Call `character.move(to:)`. The first move is instant. After that the
   character falls to a lower slot and glides to a higher one, unless the
   call passes `.glide` or `.instant`.
5. While someone types, set `attention` and call `key()` for each keystroke.
   Call `token()` for each streamed token.
6. On the welcome screen, call `assemble()` to grow the character in.

**Decisions.**

- **Pacing.** The idle loop never fully rests, as in the mockup. Once
  settled, it redraws at 24 fps. Motion runs every frame. The timeline pauses
  in three cases: the window is hidden or occluded, Reduce Motion is on, or
  nothing is drawn.
- **Rest pose.** The rest pose is rotation 0, the mockup's starting pose. It
  is the basis for the app icon in phase 9.
- **Mark legs.** The filled mark drops its legs below 32 pt, and the outline
  mark below 40 pt.
- **Small sizes.** The outline and jitter scale down at small sizes.
- **Dust puffs.** The assemble effect's dust puffs weren't ported. In the
  mockup they are created with radius 0, so they never show.

**Review.** There were no blockers. Five findings were fixed, each with a
test:

- The timeline now rests when nothing is drawn.
- Actor-isolation warnings in the tests are gone.
- Events the model ignores no longer wake the timeline.
- A move during a drag keeps the throw.
- The filled mark's legs are dropped below 32 pt.

**Verification.**

- **Build and analyze:** both succeeded with no warnings.
- **Character and theme tests:** 34 run, 1 skipped (the screenshot test,
  which needs `ENIGMA_SNAPSHOT_DIR`), 0 failed. The coordinator re-ran them
  and got the same result.
- **Full suite:** 664 run, 11 skipped, and 10 failures in 9 existing tests.
  The failing tests are in `AppCommandTests`, `ScreenCaptureTests`, and
  `ScreenViewTests`. All are window or key-focus timeouts in the background
  test host. The same tests fail on an untouched export of the previous
  commit, so this phase didn't cause them. They depend on which app is in
  front on the Mac during the run.
- **CPU:** a simulation step plus path building takes about 63 µs per frame,
  measured in a Debug build.

**Not yet checked by a person in the signed app:**

- the timeline pausing on occlusion;
- drag and throw with a real pointer;
- VoiceOver.
