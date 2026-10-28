# CP5: Auto's coding and reasoning checks

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §3, "Testing"),
and the Hand-offs of every earlier brief. CP2's
[Task 2.3](cp2-search.md#task-23-the-switch-over-test) is the switch-over
procedure.

## Goal

Train the `coding` and `reasoning` models, wire them into `AutoRouter`, and
switch each over if it passes. Both lean Local (off): a wrong yes sends a
request to Cloud. Both models read the typed draft and the attached context
(spec §2 and §5, owner 2026-10-27), and each needs at least 0.80 test
accuracy to switch.

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
- **What the checks read today.** Both callers, `LocalChatViewModel` (the
  `AutoRouter.Request(` in its send path) and `AppShellView`, pass
  `prompt: ConversationContextPrompt.expand(…).content`. That's the typed
  draft plus, when something is attached, Enigma's own wrapper line
  ("Attached context (untrusted source material…)"), the attachments as
  JSON, and, for selection replies, the response-mode instructions.
  `webSearchPrompt` is the typed draft. The wrapper and the instructions are
  Enigma's words, not the person's, so the models must not read them.

## Tasks

### Task 5.0: Attached context for Auto (owner, 2026-10-27)

**Files:** modify `Enigma/Intent/IntentText.swift`,
`IntentTraining/IntentTrainingSupport.swift`, `Enigma/Chat/AutoRouter.swift`
and the two callers. Tests go in `IntentTextTests`,
`IntentTrainingSupportTests` and `AutoRouterTests`.

- [ ] **Interfaces** (record any change in the plan's Interface map):
  - `AutoRouter.Request` gains `attachedText: String` (default `""`): the
    attached selection and file texts, joined by blank lines, with no
    wrapper, JSON or instructions. Both callers fill it from the message's
    `contexts`. `prompt` and `webSearchPrompt` don't change, and the
    context-budget check keeps using `prompt`.
  - `IntentText.autoInput(draft:attached:now:)`: the model input for Auto.
    The draft goes through `clean`. The attached text is lowercased and its
    whitespace collapsed, but literal material is kept, since code is the
    signal. Both get year words, then the result is cut to
    `2 × modelCharacterLimit`: up to the first 500 characters of the draft,
    then the attached text fills what's left from its start. The training
    script uses it for these two skills only.
  - `IntentExample` gains an optional `context` string, used only by
    `coding` and `reasoning`. The script, `isValidation`, `overlaps` and
    `appAnswer` read `text` and `context` together through `autoInput`.
- [ ] **Examples with context.** Add at least 100 training examples per
  skill with a `context`: pasted code, stack traces, logs, and plain prose
  (a recipe, an article, an email). Include drafts like "what's wrong
  here?" or "explain this" whose label comes from the attachment, and
  everyday drafts that stay no even with code attached ("summarize this
  email" with a signature that mentions an API). A new test-set writer
  agent, with CP1's prompt plus the context instructions, adds about 40 test
  examples with context per skill. The owner checks them, as in CP1 Task 1.4.
  Then rerun the score report on today's rules, re-record `baseline.json`
  for both skills, and say why in the Hand-off.
- [ ] **Tests first:** `autoInput` keeps the draft whole and cuts the
  attachment; quotes and code blocks in the attachment survive; the wrapper
  line and instructions never reach `autoInput` (an `AutoRouterTests` case
  with a selection reply); and an attachment alone, with an empty draft,
  still gives an answer.

### Task 5.1: Train both

- [ ] **Run** `scripts/train-intent-models.sh coding reasoning`, record the
  output, and register `IntentCoding.mlmodel` and `IntentReasoning.mlmodel`
  in the app target. Stop and report on a non-zero exit.

### Task 5.2: Wire them in

**Files:** modify `Enigma/Chat/AutoRouter.swift`. Tests go in
`IntentModelsTests` and `AutoRouterTests`.

Each check becomes a yes from the skill's model on
`IntentText.autoInput(draft: <typed draft>, attached: request.attachedText, now:)`.
Add an `IntentModels` entry point that takes that input, if `answer(_:cleaned:now:)`
can't. The typed draft is `request.webSearchPrompt` with typed commands
removed, as `WebSearchPolicy.questionText` does today.
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
  wrong-yes condition and the 0.80 accuracy floor for both. BERT is allowed
  for both (20 ms limit).

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- Every pre-existing test passes unedited.
- `coding` and `reasoning` are in `floors.json` with test accuracy of at
  least 0.80, or the owner decided otherwise.
- Pins for both are within 20.

## Reviewer checklist

- **Only the two checks changed** in `AutoRouter`: the order of checks, the
  context-budget path, `requiresWebSearch` and every limitation message are
  untouched.
- **Lean:** both cut-offs came from the lean-off rule; each p95 is within
  20 ms.
- **Context:** only the typed draft and `attachedText` reach the models.
  Never the wrapper line, the JSON keys, the response-mode instructions,
  earlier messages or tool results. The chip skills still read only the
  typed draft.

## Hand-off

*Filled in by the CP5 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP4's CI result, both training outputs, both
   switch-over results, and every pin.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
