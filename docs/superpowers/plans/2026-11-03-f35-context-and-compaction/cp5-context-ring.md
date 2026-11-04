# CP5: Context ring and merge

Read [agent-workflow.md](agent-workflow.md), the F35 entry (above all
"Context ring around the character"), the plan, and the Hand-offs of
CP0–CP4.

## Goal

A thin ring around the resting character shows the exact share of the
current route's input budget the chat fills. Then the docs, the screenshot
and the merge to `main`.

## Starting point

- **Stage** (`Enigma/App/EnigmaCharacterStage.swift`): one stage per window
  (`.enigmaCharacterStage(character, tracksPointer: false)` in
  `AppShellView`). `EnigmaCharacterLayer` is a `TimelineView` with a
  `ZStack(alignment: .topLeading)`: a non-hit-testable, accessibility-hidden
  `Canvas` that draws the character, and a `handle` (`Color.clear`, side
  `max(bodyRadius × 2.5, 12)`, at `model.position`) that carries the
  `DragGesture(minimumDistance: 0)`, the pointer style and the "Enigma"
  accessibility element. A release under 4 pt (`EnigmaCharacterTuning.pokeDistance`)
  pokes; otherwise it's a throw that springs back to the slot. Under Reduce
  Motion the gesture is off.
- **Model** (`EnigmaCharacterModel.swift`): `position`, `bodyRadius`
  (`slot.size × 0.34`), `isDragging`, `isFalling`, `isAtRest`, `slot`;
  `throwTimer` is private. There's no single "away from the slot" flag.
  `controller.isPresent` is false when no slot is laid out.
- **Slots:** reply `chat.reply.<uuid>` size 30 (`ConversationTranscript.slotSize`,
  `EnigmaLatestReplySlot` in `EnigmaMessageList.swift`); compact panel
  `panel.input` size 40 (`CompactPanelLayout`); main page `main.hero` 92;
  tour card `tour.card` 54. `AppShellView.windowCharacterSlot` picks one.
- **Hide conditions:** `AppShellView.isChatEmpty` (empty new-chat page);
  `guidedTour.isActive`; `welcomeSetup.isPresented`.
- **Usage:** `LocalChatViewModel.contextUsage` (CP3, kept current by CP4),
  and `ToolStepBudget.usage` while a tool turn runs (CP1).
- **Colours** (`EnigmaPalette` in `Enigma/App/EnigmaTheme.swift`, Paper and
  Ink, documented in `docs/design/UI-Style.md`, checked by
  `EnigmaThemeTests`): `accent` (green), `warning` (amber), `border` /
  `hairline` (greys). **There is no red token.**
- Character tests drive the stage through `NSHostingView` in
  `EnigmaMainWindowTests` and `EnigmaConversationTests`;
  `EnigmaCharacterTests` covers the model.
- **The entry says the ring "replaces a separate indicator in the composer".**
  There is no such indicator on `main`: the ring is the only one. Confirm
  this and say so in the Hand-off.

## Interfaces

**Produces** (`Enigma/App/ContextRing.swift`):

```swift
/// Drawn inside EnigmaCharacterLayer's ZStack, at the character's position.
struct ContextRing: View {
  let usage: ContextUsage
  let radius: CGFloat          // from bodyRadius
  let palette: EnigmaPalette
  let reduceMotion: Bool
}
// EnigmaCharacterController gains:
@Published var contextUsage: ContextUsage?   // nil hides the ring
var isAwayFromSlot: Bool { get }             // dragging, falling, thrown or moving between slots

// EnigmaPalette gains (Paper and Ink): contextFull (red), contextTrack (grey)
```

## Decisions this plan fixes

- **Shape:** an ellipse 1.12 × the body's width and 1.25 × its height
  around the character's centre, stroked 2 pt with round caps, open at the
  bottom with a 50° gap centred straight down. The fill runs from the gap's
  left end, over the top, to its right end; the unfilled part is drawn in
  `contextTrack`.
- **Colours:** `accent` below 70%, `warning` from 70%, the new `contextFull`
  from 90%. `contextFull` and `contextTrack` are added to both palettes, to
  `UI-Style.md` and to `EnigmaThemeTests` (≥ 3:1 against `surface` for the
  three fill colours, as non-text graphics).
- **Hover and click:** hovering the ring shows a tooltip with the plan's
  "Ring help" copy; clicking it shows a small popover with the plan's "Ring
  popover" token line (`12K of 32K tokens used`, owner request 2026-11-03)
  above the same help text. Its
  hit area is the ring's stroke widened to 8 pt, outside the character's
  handle, so a click on the character still pokes it and dragging still
  drags. The ring is its own accessibility element, labelled
  `Context` with the popover's two lines as its value.
- **Visibility:** shown when `contextUsage` is non-nil, the character is
  present and at rest in a reply or compact-panel slot, not on the empty
  page, not in the tour or welcome. While `isAwayFromSlot` it fades out over
  0.15 s and back in after it settles; with Reduce Motion it hides and shows
  without fading.
- **Changes** (new usage after a send, compaction or a route change)
  animate the fill over 0.25 s ease-out; with Reduce Motion they jump.
- **Route change** recounts at once from the current chat with the new
  route's budget, without sending anything.

## Tasks

### Task 5.1: The ring view and tokens

- [ ] **Failing tests:** `testRingLevelColours` (69.9% accent, 70% warning,
  89.9% warning, 90% contextFull); `testRingFillIsExactFraction` (no
  steps); `testRingGapIsAtTheBottom`; `testNewTokensMeetContrast`; the help
  text at 71.4% used ("28% of context left") and at 92% used, with the
  summary sentence; `testRingTokenLineFormatsThousands` (640, 8,192 → `8.2K`,
  12,345 → `12K`, 65,536 → `66K`, as `<U> of <L> tokens used`).

### Task 5.2: On the stage

- [ ] **Failing tests** (`EnigmaMainWindowTests`, `EnigmaConversationTests`):
  `testRingFillIsThePreparedRequestsFraction` (a local and a cloud route);
  `testRingShowsBesideLatestReply` and `testRingShowsInCompactPanelSlot`;
  `testRingHiddenOnEmptyPageAndInTour`; `testRingFadesWhileDraggedAndReturns`;
  `testClickOnCharacterStillPokes`; `testClickOnRingShowsShareLeft` (the token
  line and the share left);
  `testRingDropsAfterCompaction`; `testRingChangesWithRoute`;
  `testRingUpdatesDuringToolTurn`; `testRingVoiceOverLabel`.

### Task 5.3: Docs, screenshot, merge

- [ ] `docs/Chat.md` → "Context budgets": rewrite as one section covering
  everything F35 changed, with the ring and a screenshot in Paper and Ink
  (owner approves capturing it; `docs/images/`). Check `docs/README.md`
  descriptions. Move F35 to done in `to-do.md` with a short "Solved" note
  (the owner approves the wording).
- [ ] Full `build`, `test`, `analyze`; read the whole branch diff against
  `main`; then, with the owner's approval, mark the PR ready and merge it.

## Exit checks

- The classes above and `EnigmaThemeTests`, `EnigmaCharacterTests` pass;
  full `build`, `test`, `analyze`; CI green on the PR.
- With the owner's approval, a look at the real app in Paper and Ink: the
  ring at green, yellow and red, the tooltip, and a drag.

## Hand-off

_To be filled in by the CP5 worker._
