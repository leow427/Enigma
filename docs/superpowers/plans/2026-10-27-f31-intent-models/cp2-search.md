# CP2: Automatic search

Read [agent-workflow.md](agent-workflow.md), the spec (§1, §2, §3,
"Failure handling", "Testing"), and the Hand-offs of
[CP0](cp0-check-and-tooling.md#hand-off) and
[CP1](cp1-examples-and-baseline.md#hand-off).

## Goal

Train the `search` model, wire it into
`WebSearchPolicy.needsFreshInformation` behind its privacy rules, and switch
over only if it passes the switch-over test. This is the first model in the
app, so it also proves that a bundled model loads in the app (Q3's second
half). CP3–CP5 repeat this checkpoint's switch-over procedure for their
skills.

## Starting point

- **`WebSearchPolicy.needsFreshInformation(normalized:now:)`** returns
  false for empty text, `optOut`, `isAboutOwnCommunications` and `thisChat`;
  true when `LocationIntent.needsLocation(normalized:)`; and otherwise
  `needsFreshFacts(text, now:)`.
- **`needsFreshFacts`** uses `explicitLookup`, `transformation`,
  `localTask`, `recentDevelopments`, `factualRequest`, `recency`,
  `changingFact`, `historicalTopic`, `conceptualQuestion`, `eventTopic` and
  `fourDigitWord`.
- **Kept for other callers:** `isOfflineOrTransformation` (used by
  `LocationIntent`) needs `optOut`, `transformation` and `localTask`.
  F29's branch adds `recency(_:now:)`, which uses `fourDigitWord`.
- **Callers:** `ComposerIntent.resolve` (the search chip) and
  `LocalChatViewModel` (the `/search`-less automatic path).
- **The score tests** (CP1) check every skill listed in
  `IntentTraining/floors.json`, which is `{}`.

## Tasks

### Task 2.1: Train

- [ ] **Run** `scripts/train-intent-models.sh search`. Record the printed
  kind, cut-off, validation accuracy and p95 in the Hand-off.
- [ ] **If it exits non-zero** for a missing cut-off or the speed limit,
  stop and report to the owner. Don't change the limits.
- [ ] **Register** `Enigma/Resources/IntentModels/IntentSearch.mlmodel` in
  the app target (agent-workflow, "Registering a model").

### Task 2.2: Wire it in

**Files:** modify `Enigma/Search/WebSearchPolicy.swift`. Tests go in
`EnigmaTests/WebSearchTests.swift` and `EnigmaTests/IntentModelsTests.swift`.

`needsFreshInformation(normalized:now:)` keeps its guard and its location
line, then returns
`IntentModels.shared.answer(.search, cleaned: text, now: now) == "yes"`.
Remove `needsFreshFacts` and the patterns only it used:
`explicitLookup`, `recentDevelopments`, `factualRequest`, `recency`,
`changingFact`, `historicalTopic`, `conceptualQuestion` and `eventTopic`.
Keep `fourDigitWord` (F29), and everything `isOfflineOrTransformation`,
`isAboutOwnCommunications` and `thisChat` use.

**Steps:**

- [ ] **Write the failing tests:**
  - `testShippedSearchModelLoads` (`IntentModelsTests`):
    `IntentModels.shared.info(.search)` isn't nil, and its fingerprint
    equals the fingerprint of `IntentTraining/search/train.jsonl`.
  - `testSearchGatesRunBeforeTheModel` (`WebSearchTests`), each through
    `WebSearchPolicy.needsFreshInformation`:
    - false: "did my sister text me about the game score tonight", "what
      were the latest messages from my dad", "who won the game last night?
      don't search", "what was the first message I sent you";
    - true: "good coffee near me", "will it rain tomorrow".
- [ ] **Run** them before wiring. The gate tests describe today's behavior
  and pass on the rules; they must keep passing. `testShippedSearchModelLoads`
  passes once Task 2.1's model is registered; if it fails, the model isn't
  in the app bundle, so fix the registration before going on.
- [ ] **Implement,** then run `WebSearchTests`, `ComposerIntentTests`,
  `ComposerIntentPhrasingTests`, `LocalInferenceTests` and
  `IntentModelsTests`.
- [ ] **Fix failures** in existing tests per agent-workflow ("Keep tests
  honest"): more training examples and retraining first, then a pin in
  `IntentPins.shipped`. Never edit the test.

### Task 2.3: The switch-over test

This procedure is the same for every skill (CP3–CP5 refer to it):

- [ ] **Run the score report** for the skill.
- [ ] **Compare** with `IntentTraining/baseline.json`:
  1. the test accuracy is higher than the baseline's;
  2. for lean-off skills only, `wrongYesShare` is no higher than the
     baseline's;
  3. no must-pass failures;
  4. the test accuracy is at least 0.80 (owner, 2026-10-27).
- [ ] **If all four hold,** add the skill to `IntentTraining/floors.json`
  with its accuracy minus 0.02, rounded down to 3 decimals, and run
  `IntentScoreTests`. Expect them to pass.
- [ ] **If one fails:**
  - a must-pass failure may be fixed with training examples or a pin
    (never by copying test examples), then retrain and rerun;
  - accuracy under 0.80 may be fixed with more varied training examples,
    chosen from the model's mistakes on the validation share (never the
    test set), then retrain and rerun. If the lean-off wrong-yes cap is what
    holds it under 0.80, stop and ask the owner;
  - otherwise stop and report the numbers to the owner. If the owner
    decides the skill keeps its rules, undo this checkpoint's wiring by
    hand, keep the trained model out of the app target, and record the
    decision.
- [ ] **For `search`:** remove `ComposerIntentPhrasingTests.testSearchPhrasings`
  (its phrasings are in the training file; the owner approved this in the
  spec). Keep every other method in that file.

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- Every pre-existing test passes unedited, except the removed
  `testSearchPhrasings`.
- `search` is in `floors.json`, or the owner decided otherwise.
- `IntentPins.shipped.count(.search) <= 20`.

## Reviewer checklist

- **Gates:** every check in spec §2's "Stays as rules" column for search runs
  before the model, and `isOfflineOrTransformation` still works for
  `LocationIntent`.
- **Removed code:** nothing removed that another caller (including
  `LocationIntent`) uses; `fourDigitWord` kept.
- **Switch-over numbers** match a rerun of the score report; the floor is
  computed as the plan says.
- **Pins:** each has a must-pass or existing test that needs it.

## Hand-off

*Filled in by the CP2 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP1's CI result, the training output, the
   switch-over numbers against the baseline, and every pin with the example
   that needed it.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
