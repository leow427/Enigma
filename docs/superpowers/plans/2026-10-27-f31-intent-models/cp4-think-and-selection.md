# CP4: Think, edit and translate

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §3, "Testing"),
and the Hand-offs of every earlier brief. CP2's
[Task 2.3](cp2-search.md#task-23-the-switch-over-test) is the switch-over
procedure.

## Goal

Train the `think` and `selection` models, wire them in, switch each over if
it passes, and retire `ComposerIntentPhrasingTests`, keeping its two checks
that aren't about one skill's wording.

## Starting point

- **`ThinkCommand.isRequested(normalized:)`**
  (`Enigma/Screen/ScreenAttachment.swift`) uses `thinkWord`,
  `meaningQuestion`, `notARequest` and `thinkCue`. `ThinkCommand`'s other
  members (`guidance`, `remainder`, `message`, `enabled`,
  `localOutputTokens`) aren't recognizers and stay.
- **`SelectionIntentPolicy.command(normalized:)`**
  (`Enigma/Chat/ConversationContext.swift`) returns `.translate`, `.edit` or
  nil from `translate` and `edit`. `leadIn` stays: `SelectionResponseMode`
  uses it. `ComposerIntent` asks it only when `hasSelection`.
- **Tests:** `ThinkCommand` and `SelectionIntentPolicyTests` cases in
  `EnigmaTests/ComposerIntentTests.swift`, `SelectionContextTests`, and in
  `ComposerIntentPhrasingTests`: `testThinkPhrasings`,
  `testPhrasingsThatRecognizeNothing`, `testCorpusSize`,
  `testMessagesPhrasingsNeverSearch` and `testLongRepeatedDraftsStayFast`.

## Tasks

### Task 4.1: Train both

- [ ] **Run** `scripts/train-intent-models.sh think selection`, record the
  output, and register `IntentThink.mlmodel` and `IntentSelection.mlmodel`
  in the app target. Stop and report on a non-zero exit, including the chip
  speed sum.

### Task 4.2: Wire them in

**Files:** modify `Enigma/Screen/ScreenAttachment.swift` and
`Enigma/Chat/ConversationContext.swift`. Tests go in `IntentModelsTests` and
`ComposerIntentTests`.

- `ThinkCommand.isRequested(normalized:)` becomes
  `!text.isEmpty && IntentModels.shared.answer(.think, cleaned: text) == "yes"`.
  Remove `thinkWord`, `meaningQuestion`, `notARequest` and `thinkCue`.
- `SelectionIntentPolicy.command(normalized:)` maps
  `IntentModels.shared.answer(.selection, cleaned: text)`: `"translate"` to
  `.translate`, `"edit"` to `.edit`, `"none"` to nil. Remove `translate` and
  `edit`; keep `leadIn` and `lead` if `leadIn` needs it.

**Steps:**

- [ ] **Write the failing tests:**
  - `testShippedThinkAndSelectionModelsLoad` (`IntentModelsTests`), as in
    CP2.
  - `testSelectionIsOnlyAskedWithASelection` (`ComposerIntentTests`), if no
    existing test covers it: "translate this to French" with
    `hasSelection: false` infers neither `translate` nor `edit`.
- [ ] **Implement,** then run `ComposerIntentTests`,
  `SelectionContextTests`, `ComposerIntentPhrasingTests` and
  `IntentModelsTests`. Fix failures as CP2 Task 2.2 says.

### Task 4.3: The switch-over tests

- [ ] **Follow CP2 Task 2.3** for `think`, then for `selection` (lean off).

### Task 4.4: Retire `ComposerIntentPhrasingTests`

Do this only when `search`, `messages` and `think` have all switched. If one
didn't, keep the methods for the skills that kept their rules, and say so in
the Hand-off.

**Files:** remove `EnigmaTests/ComposerIntentPhrasingTests.swift` and its
four project entries. Modify `EnigmaTests/ComposerIntentTests.swift` and
`EnigmaTests/IntentScoreTests.swift`.

- [ ] **Move** `testLongRepeatedDraftsStayFast` unchanged into
  `ComposerIntentTests`, with the `resolve` helper and `now` it needs.
- [ ] **Replace** `testMessagesPhrasingsNeverSearch` with
  `IntentScoreTests.testMessagesRequestsNeverSearch`: for every `messages`
  example labelled yes in `train.jsonl` and `must-pass.jsonl`,
  `ComposerIntent.resolve(.init(draft: text, infersCommands: true,
  searchesAutomatically: true), now: asOf).search == false`. That covers
  every phrasing the old test did, and more.
- [ ] **Add** `IntentSpeedTests.testThousandDraftsResolveQuickly` in a new
  `EnigmaTests/IntentSpeedTests.swift`: the first 1,000 training texts
  across the chip skills, each resolved with `infersCommands: true`,
  `searchesAutomatically: true` and `hasSelection: true`, take under 10
  seconds in total.
- [ ] **Remove** the rest of the file: its phrasings are training examples,
  and the switched skills' score tests cover them (the owner approved this in
  the spec).

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- Every pre-existing test passes unedited, except the
  `ComposerIntentPhrasingTests` methods this brief moves or removes.
- `think` and `selection` are in `floors.json`, or the owner decided
  otherwise.
- Pins for both are within 20.

## Reviewer checklist

- **Moved tests** are byte-for-byte the same assertions;
  `testMessagesRequestsNeverSearch` covers every phrasing the old
  `PhrasingCorpus.messages` had (they're in `messages/train.jsonl`).
- **Selection** still never runs without an attached selection, translation
  still wins, and `SelectionResponseMode` is unchanged.
- **Speed:** the chip sum in the training output is within 5 ms.

## Hand-off

*Filled in by the CP4 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP3's CI result, both training outputs, both
   switch-over results, and every pin.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
