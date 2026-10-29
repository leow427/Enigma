# CP3: Messages

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §3, §5,
"Testing"), and the Hand-offs of every earlier brief. CP2's
[Task 2.3](cp2-search.md#task-23-the-switch-over-test) is the switch-over
procedure.

## Goal

Train the `messages` model, wire it into `MessagesIntentPolicy.isRequested`,
and switch over if it passes. `messages` leans off: at most 2% of its yeses
may be wrong, and its share of wrong yeses can't be higher than the rules'.

## Starting point

- **`Enigma/Messages/MessagesIntentPolicy.swift`:**
  - `isRequested(_:)` cleans and calls `isRequested(normalized:)`, which is
    the long pattern set (`messagingWord`, `readPlain`, `links`,
    `subjectVerbs`, `shape`, `vetoes`, `namesMessages`, `otherService` and
    their building blocks);
  - `isFollowUp(_:)` and `isFollowUpCue(normalized:)` use `followUpCue` and
    `followUpNearMiss`. They stay rules.
- **Callers:** `ComposerIntent.resolve` (with `previousTurnUsedMessages` and
  the conflicts), and Messages' own request paths.
- **Tests that assert it:** `MessagesIntentPolicyTests` in
  `EnigmaTests/ComposerIntentTests.swift`, `MessagesTests`, and
  `ComposerIntentPhrasingTests.testMessagesPhrasings` and
  `testMessagesPhrasingsNeverSearch`.

## Tasks

### Task 3.1: Train

- [ ] **Run** `scripts/train-intent-models.sh messages`, record the output,
  and register `IntentMessages.mlmodel` in the app target. Stop and report
  on a non-zero exit.

### Task 3.2: Wire it in

**Files:** modify `Enigma/Messages/MessagesIntentPolicy.swift`. Tests go in
`EnigmaTests/ComposerIntentTests.swift` and `IntentModelsTests`.

`isRequested(normalized:)` becomes
`!text.isEmpty && IntentModels.shared.answer(.messages, cleaned: text) == "yes"`.
Remove every pattern only it used. Keep `isRequested(_:)`, `isFollowUp(_:)`,
`isFollowUpCue(normalized:)`, `followUpCue`, `followUpNearMiss`, `matches`
and `expression`, and update the type's doc comment to say the model
decides and the follow-up cue stays a rule.

**Steps:**

- [ ] **Write the failing tests:**
  - `testShippedMessagesModelLoads` (`IntentModelsTests`), as in CP2.
  - `testMessagesNeverInfersAlongsideFilesOrScreenshots`
    (`ComposerIntentTests`), if no existing test already covers it:
    `ComposerIntent.resolve` with `hasFileSelection: true`, and separately
    `hasScreenshot: true`, on "what did my dad text me today" never infers
    `messages`.
- [ ] **Implement,** then run `ComposerIntentTests`, `MessagesTests`,
  `ComposerIntentPhrasingTests` and `IntentModelsTests`. Fix failures as
  CP2 Task 2.2 says.

### Task 3.3: The switch-over test

- [ ] **Follow CP2 Task 2.3** for `messages`, including the wrong-yes
  condition.
- [ ] **On a switch,** remove `ComposerIntentPhrasingTests.testMessagesPhrasings`.
  Keep `testMessagesPhrasingsNeverSearch`; CP4 moves it.

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- Every pre-existing test passes unedited, except the removed
  `testMessagesPhrasings`.
- `messages` is in `floors.json`, or the owner decided otherwise.
- `IntentPins.shipped.count(.messages) <= 20`.

## Reviewer checklist

- **Privacy:** only the cleaned typed draft reaches the model; the follow-up
  cue and `ComposerIntent`'s conflicts are unchanged; Messages still never
  combines with files, screenshots or search.
- **Lean:** the cut-off in the model's metadata came from the lean-off rule
  (check `report.json`), and the wrong-yes share is within the baseline's.
- **Removed code:** nothing removed that `isFollowUp` or another caller
  uses.

## Hand-off

*Filled in by the CP3 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP2's CI result, the training output, the
   switch-over numbers, and every pin.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
