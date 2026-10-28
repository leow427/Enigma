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
  **Coding (owner, 2026-10-27):** in-depth coding work is reasoning yes as
  well as coding yes: designing functions, classes, data structures or APIs,
  explaining what code does, debugging, finding a root cause, implementing,
  reviewing, refactoring and performance work. Quick syntax, command and tool
  lookups ("how do I exit vim", "how do I install a package with pip") are
  reasoning no.

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

1. **Summary:** every skill now has training, held-out test and must-pass examples. `IntentScoreTests` checks the files' sizes and overlaps, writes the end-to-end score report, and will hold switched skills to their floors. `IntentTraining/baseline.json` scores today's rules on the test sets. Auto's coding and reasoning checks are internal and take the raw prompt. No model is trained or wired in, and no recognizer changes behavior.
2. **Files:**
   - `Enigma/Chat/AutoRouter.swift`: `requiresCoding(_:)` and `requiresAdvancedReasoning(_:)` are internal and lowercase the prompt themselves; `automaticDecision` passes `request.prompt`.
   - `EnigmaTests/AutoRouterTests.swift`: `testCodingAndReasoningChecksTakeTheRawPrompt`.
   - `EnigmaTests/IntentScoreTests.swift` (new): `IntentExamples` and the six tests in the brief, plus `testRulesMatchTheBaseline` (round 1): every skill not in `floors.json` must score exactly what `baseline.json` records, so a change to the rules or to the cleanup can't leave the baseline stale.
   - `Enigma.xcodeproj/project.pbxproj`: `IntentScoreTests.swift` registered in `EnigmaTests`.
   - `IntentTraining/config.json`: `allowsBERT` is `true`.
   - `IntentTraining/<skill>/train.jsonl`, `must-pass.jsonl` (new, by me) and `test.jsonl` (new, by the test-set writers), for all six skills.
   - `IntentTraining/README.md` (new): format and sources. `IntentTraining/floors.json` (new): `{}`. `IntentTraining/baseline.json` (new).
   - This Hand-off, and the plan's progress-log row.
3. **Decisions:**
   - **Q1, CI half: yes.** CP0's run on `fa08e93` (run 40619282024, `macos-26`) passed `testBERTFixturePredictsOffline` in 2.1 s, not skipped. Q1 was also yes on the owner's Mac, so `allowsBERT` is `true`. BERT is still over the 5 ms chip limit (CP0, Q2), so only `coding` and `reasoning` can come out BERT.
   - **Spot-check: 0 of 100 wrong.** The owner checked the 100 test examples whose `fingerprint(Data(text.utf8))` sorts first (17 each for search, messages, think and selection; 16 each for coding and reasoning) and found every label correct. No label was changed.
   - **Example counts:**

     | Skill | Training (yes / no) | Near-misses among negatives | Over 1,000 characters | Test | Must-pass |
     | --- | --- | --- | --- | --- | --- |
     | search | 2,020 (634 / 1,386) | 61% | 23 | 258 | 31 |
     | messages | 1,375 (471 / 904) | 57% | 22 | 250 | 26 |
     | think | 1,735 (416 / 1,319) | 41% | 22 | 258 | 26 |
     | selection | 1,087 (375 edit, 253 translate / 459 none) | 86% | 15 | 256 | 26 |
     | coding | 959 (458 / 501) | 41% | 22 | 256 | 26 |
     | reasoning | 1,154 (655 / 499) | 57% | 23 | 287 | 31 |

   - **How training examples were made.**
     - Every phrasing the existing tests assert was added with the label they assert. That covers the four `PhrasingCorpus` lists, `MessagesIntentPolicyTests`, `ThinkIntentTests`, `SelectionIntentPolicyTests`, the `ComposerIntentResolveTests` drafts, `WebSearchTests`' `needsFreshInformation` lists, and `AutoRouterTests`' prompts, privacy prefixes included. The Slash-Commands "Recognized commands" examples went in too. A typed `/think` or `/search` was dropped from the text.
     - `SelectionContextTests` and `MessagesTests` assert no recognizer directly, so nothing came from them.
     - A seed phrasing for one skill went into every skill it says something about, as the brief's example does: `PhrasingCorpus.messages` is search no and think no.
     - `selection`, `coding` and `reasoning` had about 50 seeds each, so most of their examples are new. Hand-written drafts were labelled by the meanings in Task 1.2. Other skills' hand-written drafts were added as plain negatives to `selection`, `coding` and `reasoning`. Sentence patterns were filled from short lists of cities, teams, names and tasks. Casual prefixes and suffixes and one-letter-swap typos were added to some examples. Long drafts set three neutral paragraphs around the request.
   - **`nearMiss`.** It's true on hand-written near-miss lists and on long drafts with a negative label. Other negatives get it when they use the skill's vocabulary (a per-skill word list). Every selection `none` that asks something of the selection is marked, since it is a request, just not an edit or a translation.
   - **Seven search labels differ from `needsFreshInformation` alone.** These are `PhrasingCorpus.messages` phrasings such as "who texted me last night", labelled search `no` per the brief. Today `ComposerIntent` drops search for them because Messages is inferred. They are the person's own communications, so `no` is the right meaning. CP2 should expect them, and they shouldn't need a pin.
   - **Must-pass lists** come from privacy cases, the docs' headline examples, the non-English and emoji-only drafts Review Focus 5 asks for, and the spec's misfires. Where a must-pass draft would have matched a seed phrasing, I reworded the must-pass draft and left the seed alone. Hand-written training drafts that matched a must-pass draft were dropped from training.
   - **Test-set writers.**
     - The first writer got the brief's prompt verbatim, with two lines added before it: the worktree path, since the agent starts in the main checkout, and "never write /think" (CP0's hand-off).
     - The overlap check found 82 test lines that matched training after cleanup: search 15, messages 6, think 8, selection 36, coding 6, reasoning 11. I deleted them from `test.jsonl` without rewording.
     - A second writer got the same prompt plus "write N more for <skill>, all different from your earlier ones". It was allowed to read only the six test files, and appended its replacements.
     - The second writer said it read a few lines past "What each skill means" (the training-file rules and the start of Task 1.3), but no training file. The first writer listed `IntentTraining/` but opened only spec §2 and the meanings.
     - I read no test example beyond the 100 in the spot-check.
   - **Owner decision (2026-10-27): in-depth coding is reasoning too.** The owner asked that coding requests also count as reasoning in most cases, then narrowed it. Designing functions, classes, data structures or APIs; explaining code; debugging and root causes; implementing; reviewing; refactoring; and performance work are reasoning yes. Quick syntax, command and tool lookups are reasoning no.
     - It's added to "What each skill means", marked as the owner's.
     - Reasoning's training file gained 354 coding examples under it: hand-written examples from the coding list, sorted one by one, plus filled patterns and typo variants. It also has 3 relabelled lines: "Implement this Swift function and debug the stack trace." in its plain and typo form, and "i think my code is broken, can you look".
     - Must-pass gained 5 coding cases.
     - Its test set had no existing label that contradicts the rule, and almost no coding drafts. A third writer, given the same prompt plus "write 30 more for reasoning" about coding, appended 18 yes and 12 no. The owner checked all 30 and found none wrong.
     - **One rule for every coding draft (round 1).** Asking to write, convert, port, fix, explain, review or design code is yes, short scripts, queries, configs and "Write Swift code." with its privacy-prefix variants included. Quick "how do I …" syntax, command and tool lookups and "is there a … library" are no. The coding examples in reasoning's training file were relabelled to that rule from one list; the 30 test lines already follow it.
     - Routing is unchanged: Auto checks coding first, so this matters when the coding check misses a coding request. The reasoning model then still sends it to Cloud.
   - **Round 1 fixes to the examples:**
     - 38 broken pattern lines left `coding` ("taylor swift the grammys", "convert this sql code to sql", "a infinite loop"), 4 left `reasoning`, and "have a" became "have an". 26 hand-written coding near-misses replace them.
     - "what language is this" left selection's training file, since must-pass has "what language is this?".
     - Search's must-pass list gained Web-Search.md's "the current file", "my latest draft" and "latest SMS rules" examples.
     - Five test lines repeated must-pass lines word for word, two of them examples from this brief's rules and the spec's goal. So the first writer read further into the brief, or the spec, than it said. They were deleted, and a fourth writer appended replacements with the same prompt and "write N more". `testHeldOutExamplesDontOverlapTraining` now also checks test against must-pass.
   - **Round 2 fixes to the examples:**
     - Search's "what are the latest SMS rules for my store" must-pass is `no`. Web-Search.md says the own-communications rule holds it back ("type `/search` for those"), and that rule stays ahead of the model, so `yes` could never pass.
     - Must-pass drafts that had come into training as casual or typo variants, or inside long drafts, were removed. That's 2 in coding, 1 in reasoning, 1 in search, 4 in selection (including "translate to english") and 2 pip lines in coding. A punctuation-insensitive scan finds no more. 12 hand-written coding near-misses keep coding's share above 40%.
     - "traduce esto al ingles" and its typo copy are selection `none`, since recognition is English-only.
     - Reasoning's "how do i write code in <language> that …" pattern lines became "write <language> code that …". That keeps "how do I …" for quick lookups, which are no.
   - **Review rounds: two.** The owner said to fix round 2's findings and commit with no third round (2026-10-27).
   - **Owner correction (2026-10-27):** the owner's first name, used by one test line as an invented name, became "Tomas" (`messages/test.jsonl`, line 158). It was "leo" in some training and must-pass lines too, and is "ravi" there now.
   - **Not done:** CP0's proposal to also compare `modelInput` text in the overlap check. The brief keeps the check on cleaned text.
4. **Verification** (owner's M5 Pro, macOS 27.0.1, Xcode 27.1):
   - `scripts/verify-xcode.sh build`: BUILD SUCCEEDED. `scripts/verify-xcode.sh analyze`: ANALYZE SUCCEEDED, no warnings (final state).
   - `scripts/verify-xcode.sh test` (final state): 1,377 executed, 21 skipped (CP0's 20 plus `testWriteScoreReport` without the variable), 1 failed: `EnigmaMainWindowTests.testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`. CP0 saw this send test time out under load too, and round 2's reviewer hit the same failure. It passed when rerun alone, both times. Round 1's reviewer had a fully clean run (1,376 executed, 0 failed). No pre-existing test was edited.
   - `-only-testing:EnigmaTests/AutoRouterTests`: the new test failed to compile while the checks were private, then 18 executed, 0 failed.
   - `-only-testing:EnigmaTests/IntentScoreTests`: failed on the missing test files before Task 1.3. With them, 7 executed, 0 failed, and the report test skips without the variable.
   - `scripts/train-intent-models.sh --check search messages think selection coding reasoning`: passes, with no overlaps, after the 82 overlapping test lines were replaced and the 30 coding lines were added.
   - Score report: `TEST_RUNNER_ENIGMA_INTENT_REPORT=<scratch folder> scripts/verify-xcode.sh test -only-testing:EnigmaTests/IntentScoreTests/testWriteScoreReport` wrote the six reports, and `baseline.json` was written from them after the last test-set change. Then `IntentScoreTests` ran 7 tests: 0 failed, 1 skipped (the report, without the variable). Mutation: setting reasoning's baseline accuracy to 0.6887 fails `testRulesMatchTheBaseline`.
   - Seed check, in a scratch copy with each `test.jsonl` replaced by `train.jsonl`: every seed phrasing gets its asserted label from today's rules, except the seven search labels under Decisions.
5. **Limitations:**
   - Many `selection`, `coding` and `reasoning` training examples come from filled sentence patterns. They may teach the patterns' wording more than the meaning, so CP4 and CP5 may need more varied hand-written examples if those models underfit the test set. Training files may be extended, but never from test examples.
   - Typo and casual variants of an example can fall on both sides of the validation split, which may make validation accuracy look a little better than it is.
   - The `messages` test set has no non-English drafts (the writer left them out); the must-pass list has three.
   - The reasoning test set has only 30 coding drafts, all added for the owner's rule; its coding score rests on few examples.
6. **For the next checkpoint:**
   - **For CP5, and the owner to decide: which text Auto's checks read.** In the main send path (`LocalChatViewModel`), `AutoRouter.Request.prompt` is `ConversationContextPrompt.expand(…)`: the typed draft plus any attached selection or file text. Only `webSearchPrompt` is the typed draft. CP1 changes nothing here; the checks read `request.prompt` exactly as before. But spec §5 says models never read selection or file text, and with a long attachment the model's last 500 characters would be attachment text. CP5 should ask the owner whether the coding and reasoning models read `webSearchPrompt` (the typed draft; changes today's attachment-driven routing) or the expanded prompt. `IntentExamples.appAnswer` scores typed drafts only.
   - **Proposal (not done):** the overlap check compares cleaned text, so test lines that differ from training only in punctuation or case still pass it. Examples are "THINK. HARDER." against "think harder", and "Taylor Swift tour dates?" against "taylor swift tour dates". A check that ignores punctuation would catch them; the brief allows deleting only what the check finds.
   - **When a checkpoint changes shared rules or `IntentText.clean`** (CP2 does), `testRulesMatchTheBaseline` fails for any skill still on its rules whose score moved. Re-record that skill's line in `baseline.json` from the score report and say why in the Hand-off, before comparing a model with it.
   - Score with `IntentExamples.score(skill, file)` and `IntentExamples.mustPassFailures(skill, file)`. To switch a skill, add `"<skill>": <floor>` to `IntentTraining/floors.json`, and the three switched-skill tests start checking it.
   - Baseline (today's rules, end to end), the numbers each skill must beat:

     | Skill | Accuracy | Wrong-yes share | Test examples | Must-pass failures |
     | --- | --- | --- | --- | --- |
     | search | 0.7597 | 0.1828 | 258 | 6 |
     | messages | 0.8680 | 0.0235 | 250 | 0 |
     | think | 0.8876 | 0.0412 | 258 | 1 |
     | selection | 0.7617 | 0.0000 | 256 | 1 |
     | coding | 0.6641 | 0.2500 | 256 | 15 |
     | reasoning | 0.6760 | 0.2737 | 287 | 12 |

   - The report's `<skill>.json` lists the failing must-pass texts. It's written outside the repository; don't commit it.
   - The generator scripts I used aren't in the repository. To add examples, edit the JSONL files directly.
