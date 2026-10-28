# Trained models for recognizing commands and routing (F31) — implementation plan

This plan drives **F31** in `to-do.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to build your checkpoint yourself, task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Here, each checkpoint is one worker's job, in a chat the owner starts; the worker starts its own reviewers. Read [agent-workflow.md](2026-10-27-f31-intent-models/agent-workflow.md), then your checkpoint's brief. They and the spec are all you need.

**Goal:** automatic search, the `messages`, `think`, `edit` and `translate`
chips, and Auto's coding and reasoning checks are decided by small trained
classifiers on the Mac instead of hand-written English rules, inside the same
privacy rules.

**Architecture:**

1. `IntentText` cleans a draft the way the rules do today, and turns the
   cleaned text into the model's input (years as words, long drafts cut).
2. `IntentModels` loads one bundled Create ML model per skill and answers
   with pins first, then the model and that skill's cut-off.
3. Each existing recognizer keeps its name and callers. It runs its privacy
   and conflict rules first, then asks `IntentModels`.
4. A training script, compiled from the same `IntentText` and `IntentSkill`
   files, trains the models from labelled example files in `IntentTraining/`,
   picks each model's type and cut-off, checks speed, and writes the models
   to `Enigma/Resources/IntentModels/`.
5. Score tests run every switched skill end to end over its held-out test set
   and must-pass list, against a recorded floor.

**Tech Stack:**

- Swift 6 and SwiftUI on macOS 26.0;
- Create ML (`MLTextClassifier`) in the training script only;
- NaturalLanguage (`NLModel`) and Core ML in the app;
- CryptoKit for fingerprints;
- XCTest.

**Spec:** [2026-10-27-f31-intent-models-design.md](../specs/2026-10-27-f31-intent-models-design.md),
approved by the owner on 2026-10-27. Every agent reads it in full. This plan
doesn't repeat its reasoning.

**Branch:** `feat/f31-intent-models` from `main`. F29 is paused on
`feat/f29-on-device-search` and is not touched by this plan.

## Global Constraints

- **Platform.** macOS 26.0 deployment target, Swift 6 strict concurrency, and
  the rules in `AGENTS.md`.
- **Dependencies.** No Swift package, binary framework or Python package.
  Create ML, NaturalLanguage, Core ML and CryptoKit are system frameworks.
  Create ML is used only by the training script, never by the app.
- **Skills and file names:**

  | Skill (`IntentSkill`) | Labels | Lean | Model file | Function it serves |
  | --- | --- | --- | --- | --- |
  | `search` | yes, no | none | `IntentSearch.mlmodel` | `WebSearchPolicy.needsFreshInformation` |
  | `messages` | yes, no | off | `IntentMessages.mlmodel` | `MessagesIntentPolicy.isRequested` |
  | `think` | yes, no | none | `IntentThink.mlmodel` | `ThinkCommand.isRequested` |
  | `selection` | edit, translate, none | off | `IntentSelection.mlmodel` | `SelectionIntentPolicy.command` |
  | `coding` | yes, no | off | `IntentCoding.mlmodel` | `AutoRouter.requiresCoding` |
  | `reasoning` | yes, no | off | `IntentReasoning.mlmodel` | `AutoRouter.requiresAdvancedReasoning` |

- **Values:**

  | What | Value |
  | --- | --- |
  | Model input | First and last `IntentText.modelCharacterLimit` (500) characters when the cleaned text is longer than 1,000 |
  | Year words | `yearpast` (two or more years before), `yearrecent` (the year before, this year or the next), `yearfuture` (two or more after), for four-digit numbers 1000–2999 |
  | Lean "off" | Most correct yeses with at most `IntentSkill.maximumWrongYesShare` (0.02) of yeses wrong, on the validation share |
  | Lean "none" | Highest accuracy on the validation share |
  | Cut-off candidates | 0.05 to 0.95 in steps of 0.01 |
  | Validation share | Examples whose `SHA256(IntentText.clean(text))` first byte is divisible by 5 (about 20%) |
  | Speed | Chip models (`search`, `messages`, `think`, `selection`) together ≤ 5 ms p95 per draft; `coding` and `reasoning` each ≤ 20 ms p95, measured by the script |
  | Pins | At most `IntentPins.maximumPerSkill` (20) per skill |
  | Example counts | Training ≥ 800 per skill (≥ 1,400 for `search`), ≥ 40% of negatives marked `nearMiss`; test ≥ 200 per skill; must-pass ≥ 25 per skill |
  | Score floor | The switched skill's test accuracy minus 0.02, rounded down to 3 decimals |
  | Model metadata keys | `enigma.cutoff`, `enigma.kind`, `enigma.fingerprint`, `enigma.asOf` |

- **Privacy:**
  - Recognizers and models read only the typed draft, cleaned by
    `IntentText.clean`. Never selection text, files, OCR, earlier messages or
    tool results.
  - The rules listed as "Stays as rules" in spec §2 run before the model and
    are never removed.
  - `LocationIntent.needsLocation` and Auto's `requiresWebSearch` aren't
    changed.
  - Logs never contain draft text, example text or probabilities for a
    draft. A load failure logs the skill name only.
  - Example files contain invented wording only: no real names with
    contact details, numbers, addresses or anything from the owner's Mac.
- **Tests:**
  - Tests are offline and deterministic. They read example files from the
    repository through `#filePath`; the test target has no resources phase.
  - Never delete, disable or weaken a test, with one owner-approved
    exception (spec, Testing): `ComposerIntentPhrasingTests` is replaced as
    its skills switch, as CP2–CP4 say.
  - Every other existing test keeps passing after a switch. A failing
    phrasing is fixed by more training examples, then by a pin, never by
    editing the test. If that would need more than 20 pins for a skill, stop
    and ask the owner.
- **The switch-over test** (spec, Testing) decides whether a skill switches.
  A skill that fails it keeps its rules; the worker stops and asks the owner.
- **Git:** each worker commits its checkpoint once, after the last review
  round, on `feat/f31-intent-models`, with its progress-log row in the same
  commit. No other commits or git operations, and no attribution lines
  anywhere.

## Review Focus

Five inputs the spec implies but doesn't spell out, most likely first. Each
is pinned by a test in the checkpoint that owns the code:

1. **Quoted or code text containing trigger words**, such as
   `what does "text Alex" mean` or a pasted snippet with "search the web".
   - **Expected:** it's removed before the model reads the draft, exactly as
     the rules remove it today.
   - **Pinned by:** CP0 `testCleanMatchesTodaysQuestionText` and
     `testCleanRemovesLiteralMaterial`.
2. **Years relative to today**, at the edges: last year, next year, two
   years ago, five-digit numbers, "3000".
   - **Expected:** the year words in the Values table, using the app's date,
     or the example file's `asOf` date in training and tests.
   - **Pinned by:** CP0 `testYearsBecomeWordsRelativeToNow`.
3. **A missing or damaged model.**
   - **Expected:** that skill gives its negative label, pins still apply,
     nothing crashes, and the failure is logged once.
   - **Pinned by:** CP0 `testMissingModelAnswersNegative` and
     `testPinsApplyWithoutAModel`.
4. **Very long drafts,** including 40,000 repeated characters and a request
   sitting only in the middle.
   - **Expected:** fast (the existing 2-second test keeps passing), and the
     model reads only the first and last 500 characters, so a request in the
     middle isn't recognized.
   - **Pinned by:** CP0 `testLongInputKeepsBothEnds`; CP4 moves
     `testLongRepeatedDraftsStayFast`.
5. **Empty, emoji-only and non-English drafts.**
   - **Expected:** empty text never reaches a model and answers negative;
     emoji-only and non-English drafts answer without crashing, and the
     lean-off skills answer negative for the non-English must-pass examples.
   - **Pinned by:** CP0 `testEmptyTextAnswersNegativeWithoutAModel` and
     `testEmojiAndNonEnglishDraftsAnswer`; CP1's
     must-pass lists for `messages` and `selection` include non-English and
     emoji-only drafts labelled negative.

---

## How this plan runs

The rules every agent follows are in
[agent-workflow.md](2026-10-27-f31-intent-models/agent-workflow.md).
In short, for each checkpoint in order:

1. **Worker.** The owner starts a fresh chat with a worker (Opus, medium
   effort) and points it at the checkpoint's brief. The worker builds it
   test-first, runs the exit checks, and fills in the brief's **Hand-off**
   section.
2. **Reviewer.** The worker starts a fresh reviewer agent (Opus, extra
   high effort) with `docs/reviewer.md`, the workflow's reviewer rules and
   the brief's checklist.
3. **Fixes.** The same worker fixes every Blocker and Should fix. A new
   reviewer runs each round, until a round has neither, for at most four
   rounds.
4. **Commit.** The worker reruns the exit checks, commits
   `<summary> (F31 CPn)` on `feat/f31-intent-models`, with the progress log
   below updated in the same commit, and pushes the branch. It then reports
   to the owner, and the next checkpoint starts in a new chat.

The next checkpoint starts only after that commit. These stop the line until
the owner decides:

- a skill that fails its switch-over test;
- more than 20 pins needed for a skill;
- the owner's spot-check finding more than 5 wrong test labels;
- a spec conflict;
- a needed dependency.

## Checkpoints

| Checkpoint | Brief | Depends on | Produces |
| --- | --- | --- | --- |
| CP0 | [Check and tooling](2026-10-27-f31-intent-models/cp0-check-and-tooling.md) | — | Answers to the spec's 4 open questions; `IntentText`, `IntentSkill`, `IntentTrainingSupport`, the training script, `IntentModels` and `IntentPins`; the draft PR for CI. No behavior change |
| CP1 | [Examples and baseline](2026-10-27-f31-intent-models/cp1-examples-and-baseline.md) | CP0 | Training, test and must-pass files for six skills; the owner's spot-check; `IntentScoreTests`; the rules' baseline |
| CP2 | [Automatic search](2026-10-27-f31-intent-models/cp2-search.md) | CP1 | `IntentSearch.mlmodel`, its switch-over result, wiring, the replaced regexes removed |
| CP3 | [Messages](2026-10-27-f31-intent-models/cp3-messages.md) | CP2 | `IntentMessages.mlmodel`, switch-over, wiring, regexes removed |
| CP4 | [Think, edit and translate](2026-10-27-f31-intent-models/cp4-think-and-selection.md) | CP3 | `IntentThink.mlmodel`, `IntentSelection.mlmodel`, switch-over, wiring; `ComposerIntentPhrasingTests` retired |
| CP5 | [Auto's coding and reasoning checks](2026-10-27-f31-intent-models/cp5-auto.md) | CP4 | `IntentCoding.mlmodel`, `IntentReasoning.mlmodel`, switch-over, wiring |
| CP6 | [Docs, report and merge](2026-10-27-f31-intent-models/cp6-docs-and-merge.md) | CP5 | Docs, the evaluation report, `AGENTS.md`, `to-do.md`, the final audit, and the merge to `main` |

## Interface map

Names every checkpoint shares. A brief's **Interfaces** blocks give the full
signatures. When a name or type changes, update this table and the briefs
that use it.

| Name | File | Defined in | Used in |
| --- | --- | --- | --- |
| `IntentText.clean(_:)`, `.modelInput(_:now:)`, `.modelCharacterLimit` | `Enigma/Intent/IntentText.swift` | CP0 | CP0–CP5, script |
| `IntentSkill` (`labels`, `negativeLabel`, `lean`, `modelName`, `isChip`, `answer(probabilities:cutoff:)`, `maximumWrongYesShare`) | `Enigma/Intent/IntentSkill.swift` | CP0 | CP0–CP5, script |
| `IntentExample`, `IntentExampleFile`, `IntentScore`, `IntentTrainingSupport` (`isValidation`, `chooseCutoff`, `overlaps`, `fingerprint`) | `IntentTraining/IntentTrainingSupport.swift` (compiled into the script and `EnigmaTests`) | CP0 | CP0–CP5 |
| `IntentModels` (`shared`, `init(bundle:pins:)`, `init(compiledModelsIn:pins:)`, `info(_:)`, `probabilities(_:for:)`, `answer(_:cleaned:now:)`), `IntentModelInfo` | `Enigma/Intent/IntentModels.swift` | CP0 | CP2–CP5 |
| `IntentPins` (`shipped`, `maximumPerSkill`, `init(_:)`, `answer(_:cleaned:)`, `count(_:)`) | `Enigma/Intent/IntentPins.swift` | CP0 (empty) | CP2–CP5 |
| `scripts/train-intent-models.sh`, `IntentTraining/train.swift`, `IntentTraining/config.json` (`allowsBERT`) | `scripts/`, `IntentTraining/` | CP0 | CP2–CP5 |
| `IntentTraining/<skill>/train.jsonl`, `test.jsonl`, `must-pass.jsonl` | `IntentTraining/` | CP1 | CP2–CP6 |
| `IntentTraining/baseline.json`, `IntentTraining/floors.json` | `IntentTraining/` | CP1 (floors empty) | CP2–CP6 |
| `IntentScoreTests`, `IntentExamples` (test helper) | `EnigmaTests/IntentScoreTests.swift` | CP1 | CP2–CP6 |
| `AutoRouter.requiresCoding(_:)`, `.requiresAdvancedReasoning(_:)` (internal, raw prompt) | `Enigma/Chat/AutoRouter.swift` | CP1 | CP1, CP5 |

**Where this plan refines the spec's names:**

- **Example files are read through `#filePath`,** not carried in the test
  bundle: the test target has no resources phase (spec, Testing, says "the
  test bundle carries the example files").
- **`IntentText` has two functions.** `clean` is today's `questionText`
  without `/think` removal, so the rules keep reading digits; `modelInput`
  adds the year words and the long-draft cut for models only.
- **`IntentSkill.swift` and `IntentTrainingSupport.swift`** are the other
  files the script compiles, so cut-off rules and scoring are shared with the
  app and the tests.
- **Skill names.** The spec's "`edit`, `translate`" skill is `selection`;
  Auto's checks are `coding` and `reasoning`.
- **`IntentScoreTests`** is the spec's `IntentModelScoreTests`. It also
  writes the score report, which scores today's rules for the baseline
  before any model ships.
- **CI is reached through a draft pull request** that CP0 opens, because CI
  runs only on pull requests and `main`.

## Progress log

Each worker updates its row in the checkpoint's own commit. There's no
commit column, since a commit can't name its own hash: find a checkpoint's
commit with `git log --grep "(F31 CP<N>)"`. The worker's full hand-off note
stays in its brief.

| Checkpoint | Status | Review rounds | Notes |
| --- | --- | --- | --- |
| CP0 | done | 3 | Q1 yes here (CI pending), Q2 BERT 6.4 ms > 5 ms chip budget so chips are maxEnt, Q3 yes, Q4 yes; owner approved type choice within speed limits and `--kind` skipping limits |
| CP1 | not started | | |
| CP2 | not started | | |
| CP3 | not started | | |
| CP4 | not started | | |
| CP5 | not started | | |
| CP6 | not started | | |
