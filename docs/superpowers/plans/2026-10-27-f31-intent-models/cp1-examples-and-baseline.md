# CP1: Examples and baseline

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §4, §5,
"Testing"), and [CP0's Hand-off](cp0-check-and-tooling.md#hand-off).

## Goal

Write every skill's examples, have the test sets written independently and
checked by the owner, and score today's rules on them:

- `IntentTraining/<skill>/train.jsonl` and `must-pass.jsonl`, by you;
- `IntentTraining/<skill>/test.jsonl`, by a separate test-set writer;
- the owner's 100-label spot-check;
- `IntentScoreTests`, which checks the files and reports end-to-end scores;
- `IntentTraining/baseline.json`, today's rules scored.

No model is trained or wired in this checkpoint, and no recognizer changes
behavior.

## Starting point

- **CP0** built `IntentText`, `IntentSkill`, `IntentTrainingSupport`, the
  script (with `--check`) and `IntentModels`. `IntentTraining/config.json`
  is `{"allowsBERT": false}`.
- **Phrasings that exist today,** each a source for training examples:
  - `EnigmaTests/ComposerIntentPhrasingTests.swift`: `PhrasingCorpus.messages`,
    `.think`, `.search` and `.none` (300+ phrasings);
  - `EnigmaTests/ComposerIntentTests.swift`: `MessagesIntentPolicyTests`,
    `ComposerIntentTests` and the selection and think tests in the file;
  - `EnigmaTests/WebSearchTests.swift`, `EnigmaTests/AutoRouterTests.swift`,
    `EnigmaTests/SelectionContextTests.swift`, `EnigmaTests/MessagesTests.swift`;
  - the tables in `docs/Slash-Commands.md` ("Recognized commands") and
    `docs/Web-Search.md` ("Automatic search").
- **`AutoRouter.requiresCoding(_:)` and `requiresAdvancedReasoning(_:)`**
  are private and take a lowercased prompt from `automaticDecision`.

## Tasks

### Task 1.1: Q1's CI half, and Auto's checks made testable

**Files:** modify `IntentTraining/config.json` (maybe) and
`Enigma/Chat/AutoRouter.swift`. Tests go in `EnigmaTests/AutoRouterTests.swift`.

- [ ] **Read CP0's CI run** with `gh pr checks` and the run's test results.
  Record in your Hand-off whether `testBERTFixturePredictsOffline` passed or
  skipped there. Set `allowsBERT` to `true` only if it passed on CI and Q1
  was "yes" on the owner's Mac.
- [ ] **Write the failing test** `testCodingAndReasoningChecksTakeTheRawPrompt`:
  `AutoRouter.requiresCoding("Write Swift code.") == true` and
  `AutoRouter.requiresAdvancedReasoning("Design a fault-tolerant payment system that handles duplicate events and regional outages.") == true`.
- [ ] **Implement:** both become `static func … (_ prompt: String) -> Bool`,
  internal, and lowercase the prompt themselves; `automaticDecision` passes
  `request.prompt`. Behavior is unchanged: run `AutoRouterTests`.

### Task 1.2: Training examples and must-pass lists

**Files:** create `IntentTraining/<skill>/train.jsonl` and
`IntentTraining/<skill>/must-pass.jsonl` for all six skills, and
`IntentTraining/README.md` (the format and where examples came from, in a
few lines).

Every file starts with `{"asOf": "2026-10-27"}`. Each example line is
`{"text": …, "label": …}`, with `"nearMiss": true` on negatives that look
like a request but aren't, and, in must-pass files, a `"why"`.

**What each skill means** (the same words the test-set writer gets):

- **`search`, yes:** answering well needs information that changes or is
  newer than a model's training: news, scores, prices, weather for a named
  place, who holds an office now, releases, schedules, opening hours, "the
  latest version of …", explicit requests to look something up online.
  **No:** timeless facts, how-to, writing, code, maths, opinions, advice,
  questions about this chat, rewriting or translating given text, history
  (`yearpast`), concepts ("what is a stock price"), and anything about the
  person's own messages, calls or email.
- **`messages`, yes:** asks to read, search, summarize or send the person's
  own Apple Messages: "what did my dad text me", "has Dad replied yet",
  "catch me up on the group chat", "text Alex that I'm running late". **No:**
  noun compounds ("text classification", "error message"), other services
  (email, Slack, WhatsApp), "send me a summary", how-to and advice about
  texting, news about someone else's message, pasted content ("Sam sent me
  this article, summarize it"), "my" things that aren't people ("messages
  from my queue"), titles and slang, this chat ("your last message"),
  drafting or reviewing a message, questions without a messaging word.
- **`think`, yes:** asks the assistant to think harder, more carefully, step
  by step, or to take its time. **No:** opinions ("what do you think"),
  "I think …", "think of a name", "it'll take a while", "how to think about
  …", "what does think it over mean".
- **`selection`** (the person has selected text in another app):
  **translate:** asks to translate it. **edit:** asks to rewrite, reword,
  shorten, proofread, fix its grammar, or change its tone. **none:**
  questions about it, summaries, explanations, "is it hard to translate
  this?", and anything else.
- **`coding`, yes:** a request to write, fix, explain, review or run code,
  or about a stack trace, regex, SQL, a programming language or a library.
  **No:** the same words in other senses: "Taylor Swift", "implement layoffs",
  "a python in the garden", "a swift reply", "debug my morning routine".
- **`reasoning`, yes:** needs careful multi-step reasoning: analysing
  trade-offs, designing a system, proving or deriving, optimizing under
  constraints, diagnosing a root cause, comparing options against criteria.
  **No:** simple facts, chit-chat, short summaries, everyday advice, and the
  same words used lightly ("logo design ideas", "solve for x in 2x = 4").

**Rules for the training files:**

- [ ] **Seed from today's phrasings.** Every phrasing in the sources above
  goes into the training file of each skill it says something about, with
  the label today's tests assert. For example, a `PhrasingCorpus.messages`
  phrasing is `messages` yes, `search` no and `think` no; a
  `PhrasingCorpus.none` phrasing is no for `messages`, `think` and
  `search`. Phrasings that existing tests assert go in training, not
  must-pass.
- [ ] **Add new wording** until the plan's counts are met: casual and
  misspelled wording, long drafts (some over 1,000 characters with the
  request at the start or the end), drafts that need two skills, and
  near-misses, at least 40% of each skill's negatives.
- [ ] **Write must-pass lists** of at least 25 per skill, none of them in
  training:
  - privacy cases: own-communication questions are `search` no ("did my
    sister text me about dinner tonight"); "don't search" opt-outs are
    `search` no;
  - the headline examples in the two docs' tables that aren't already in
    training;
  - for `messages` and `selection`, at least three non-English drafts and
    two emoji-only drafts, labelled negative (Review Focus 5);
  - for `coding` and `reasoning`, the misfires named in the spec ("who is
    Taylor Swift dating", "logo design ideas"), labelled no.
- [ ] **Run** `scripts/train-intent-models.sh --check search messages think selection coding reasoning`.
  It passes once test files exist (Task 1.3); until then it checks training
  and must-pass only.

### Task 1.3: Test sets, by a separate writer

- [ ] **Start the test-set writer** with the Agent tool (`model: "opus"`,
  `effort: "medium"`), only after Task 1.2's files are finished, with this
  prompt and nothing else:

  > You are writing held-out test sets for six text classifiers in a macOS
  > chat app. Read only these files:
  > `docs/superpowers/specs/2026-10-27-f31-intent-models-design.md` (§2) and
  > `docs/superpowers/plans/2026-10-27-f31-intent-models/cp1-examples-and-baseline.md`
  > (only the section "What each skill means" under Task 1.2). Do not open
  > any other file in `IntentTraining/`, `Enigma/`, `EnigmaTests/` or
  > `docs/`, and don't search the repository.
  >
  > For each skill, write `IntentTraining/<skill>/test.jsonl`: a first line
  > `{"asOf": "2026-10-27"}`, then about 250 lines of
  > `{"text": …, "label": …}` (add `"nearMiss": true` to negatives that look
  > like a request but aren't). Labels are `yes`/`no`, or for `selection`
  > `edit`/`translate`/`none`. Aim for about 45% yes (selection: 30% edit,
  > 25% translate, 45% none). Write drafts the way people type into a chat
  > box: short and long, casual, misspelled, polite, blunt, with and
  > without question marks, some with two requests. Cover every "yes" and
  > "no" kind in the skill's meaning, and invent new everyday situations
  > rather than echoing its examples. Use invented names only, and no real
  > phone numbers, addresses or account names. Don't write anything else.

- [ ] **Run** `--check` on all six skills. If a test example overlaps
  training, delete it from `test.jsonl` (never move it or reword it
  yourself), and ask a new writer agent, with the same prompt plus "write N
  more for <skill>, all different from your earlier ones", for
  replacements.
- [ ] **Don't read the test files** beyond what the check and the
  spot-check show you.

### Task 1.4: The owner's spot-check

- [ ] **Pick 100 test examples:** across all six skills, those whose
  `fingerprint(Data(text.utf8))` sorts first, about 17 per skill.
- [ ] **Show them to the owner** in the chat as a numbered table: skill,
  text, label. Ask which labels are wrong.
- [ ] **Five or fewer wrong:** correct those labels as the owner says, and
  record the numbers in the Hand-off. **More than five:** stop. Report which
  skills they came from, and ask the owner whether to have those skills'
  test sets rewritten by a new writer agent with the owner's notes added to
  its prompt.

### Task 1.5: `IntentScoreTests`

**Files:** create `EnigmaTests/IntentScoreTests.swift` and
`IntentTraining/floors.json` (`{}`).

**Interfaces.** This task produces:

```swift
/// Reads IntentTraining/ through #filePath.
enum IntentExamples {
  static func file(_ skill: IntentSkill, _ name: String) throws -> IntentExampleFile   // "train", "test", "must-pass"
  static func floors() throws -> [IntentSkill: Double]                                 // floors.json
  /// The app's end-to-end answer for a raw draft:
  ///   search:    WebSearchPolicy.needsFreshInformation(text, now: asOf) ? "yes" : "no"
  ///   messages:  MessagesIntentPolicy.isRequested(text)
  ///   think:     ThinkCommand.isRequested(by: text)
  ///   selection: SelectionIntentPolicy.command(for: text) → "edit" / "translate" / "none"
  ///   coding:    AutoRouter.requiresCoding(text)
  ///   reasoning: AutoRouter.requiresAdvancedReasoning(text)
  static func appAnswer(_ skill: IntentSkill, text: String, asOf: Date) -> String
}
```

**Steps:**

- [ ] **Write the tests:**
  - `testExampleFilesMeetSizes`: for each skill, training ≥ 800 (`search`
    ≥ 1,400) with ≥ 40% of negatives `nearMiss`; test ≥ 200; must-pass
    ≥ 25; every file parses.
  - `testHeldOutExamplesDontOverlapTraining`:
    `IntentTrainingSupport.overlaps` of training with test, and of training
    with must-pass, is empty for every skill.
  - `testWriteScoreReport`: skips unless `ENIGMA_INTENT_REPORT` is set; then
    writes `<folder>/<skill>.json` for every skill with the test set's
    `IntentScore` from `appAnswer`, and the must-pass texts it got wrong.
  - `testSwitchedSkillsMeetFloors`, `testSwitchedSkillsPassMustPass`,
    `testSwitchedModelsMatchTrainingData`: for each skill in `floors.json`,
    the test accuracy is at least its floor; every must-pass example is
    right; and `IntentModels.shared.info(skill)?.trainingFingerprint` equals
    the fingerprint of its `train.jsonl`. With `floors.json` empty they have
    nothing to check yet.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/IntentScoreTests`.
  Expect them to pass (the report test skips).

### Task 1.6: The baseline

- [ ] **Run the score report** (agent-workflow, "The score report") on
  today's rules.
- [ ] **Write** `IntentTraining/baseline.json`:
  `{"<skill>": {"accuracy": …, "wrongYesShare": …, "total": …,
  "mustPassFailures": n}, …}`, with accuracies to 4 decimals.
- [ ] **Show the owner** the six baselines in the chat, in one table.

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass; every
  pre-existing test passes unedited.
- `--check` passes for all six skills.
- The owner's spot-check found five or fewer wrong labels, and they're
  fixed.
- `baseline.json` has all six skills.

## Reviewer checklist

- **Labels:** spot-check 30 training examples per skill and every
  must-pass example. Report wrong labels as Should fix.
- **Independence:** the test sets read like a different writer (not
  paraphrases of training examples); nothing in the Hand-off suggests the
  worker edited test examples beyond the owner's corrections.
- **Privacy:** no real contact details or anything that looks taken from a
  Mac.
- **The baseline** matches a rerun of the report.

## Hand-off

*Filled in by the CP1 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include Q1's CI result and the `allowsBERT` value, and the
   spot-check result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
