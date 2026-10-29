# CP5: Auto's coding and reasoning checks

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §3, "Testing"),
and the Hand-offs of every earlier brief. CP2's
[Task 2.3](cp2-search.md#task-23-the-switch-over-test) is the switch-over
procedure.

## Goal

Train the `coding` and `reasoning` models, wire them into `AutoRouter`, and
switch each over if it passes. Both lean Local (off): a wrong yes sends a
request to Cloud.

## Starting point

- **`AutoRouter.requiresCoding(_:)` and `requiresAdvancedReasoning(_:)`**
  (`Enigma/Chat/AutoRouter.swift`) are internal and take the raw prompt
  (CP1). `requiresCoding` is a phrase list; `requiresAdvancedReasoning` is a
  word set plus a points score.
- **`requiresWebSearch` stays a rule** (spec §2), as does everything else in
  `automaticDecision`: modes, the context-budget check, capabilities and
  limitations.
- **Tests:** `AutoRouterTests`, plus `ScreenRoutingTests` and any other test
  that calls `AutoRouter.decide`.

## Tasks

### Task 5.1: Train both

- [ ] **Run** `scripts/train-intent-models.sh coding reasoning`, record the
  output, and register `IntentCoding.mlmodel` and `IntentReasoning.mlmodel`
  in the app target. Stop and report on a non-zero exit.

### Task 5.2: Wire them in

**Files:** modify `Enigma/Chat/AutoRouter.swift`. Tests go in
`IntentModelsTests` and `AutoRouterTests`.

Each check becomes
`IntentModels.shared.answer(<skill>, cleaned: WebSearchPolicy.questionText(prompt)) == "yes"`.
Remove the phrase list, the word sets and the points score, and the
`containsAny` helper if nothing else uses it.

**Steps:**

- [ ] **Write the failing tests:**
  - `testShippedAutoModelsLoad` (`IntentModelsTests`), as in CP2.
  - `testAutoKeepsEverydayQuestionsLocal` (`AutoRouterTests`): with a local
    model and a cloud configuration, `AutoRouter.decide` keeps "who is
    Taylor Swift dating" and "logo design ideas for a bakery" on the Local
    route. They fail on today's rules.
  - `testAutoStillAsksForSearchOnExplicitLookup` (`AutoRouterTests`), if no
    existing test covers it: "search the web for the latest news" with
    automatic search off still gives the `.requiresWebSearch` limitation.
- [ ] **Implement,** then run `AutoRouterTests`, `ScreenRoutingTests` and
  `IntentModelsTests`. Fix failures as CP2 Task 2.2 says.

### Task 5.3: The switch-over tests

- [ ] **Follow CP2 Task 2.3** for `coding`, then `reasoning`, with the
  wrong-yes condition for both.

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- Every pre-existing test passes unedited.
- `coding` and `reasoning` are in `floors.json`, or the owner decided
  otherwise.
- Pins for both are within 20.

## Reviewer checklist

- **Only the two checks changed** in `AutoRouter`: the order of checks, the
  context-budget path, `requiresWebSearch` and every limitation message are
  untouched.
- **Lean:** both cut-offs came from the lean-off rule; each p95 is within
  20 ms.

## Hand-off

*Filled in by the CP5 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP4's CI result, both training outputs, both
   switch-over results, and every pin.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
