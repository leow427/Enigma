# CP0: Check and tooling — open questions, cleanup, training script, loader

Read [agent-workflow.md](agent-workflow.md), the spec in full, and the
plan's Global Constraints and Interface map.

## Goal

Answer the spec's four open questions, then build everything the skills
share, without changing what any recognizer decides:

- `IntentText` cleans drafts, and `WebSearchPolicy.questionText` uses it;
- `IntentSkill` and `IntentTrainingSupport` hold the labels, cut-off rules,
  scoring and file format, shared by the app, the tests and the script;
- the training script trains, picks, checks speed, and writes models;
- `IntentModels` and `IntentPins` load models and answer, ready for CP2.

No recognizer calls `IntentModels` yet, and no model ships in the app.

## Starting point

- **`Enigma/Search/WebSearchPolicy.swift`:** `questionText(_:)` removes
  `/think` through `ThinkCommand.message(prompt).content`, then replaces
  `literalMaterial` with a space, straightens `’`, lowercases, rewrites
  `whatsWithoutApostrophe` to "what's", collapses `whitespaceRun`, and trims
  spaces. Every recognizer reads its output.
- **Recognizers:** `MessagesIntentPolicy` (`Enigma/Messages/`),
  `ThinkCommand.isRequested` (`Enigma/Screen/ScreenAttachment.swift`),
  `SelectionIntentPolicy` (`Enigma/Chat/ConversationContext.swift`),
  `AutoRouter` (`Enigma/Chat/AutoRouter.swift`). CP0 doesn't change them.
- **SDK facts checked on 2026-10-27** (Xcode's macOS 27 SDK):
  - `MLTextClassifier.ModelAlgorithmType` is `maxEnt(revision:)`,
    `crf(revision:)` or `transferLearning(FeatureExtractorType, revision:)`;
    `FeatureExtractorType` includes `.bertEmbedding` (macOS 14+);
  - `MLTextClassifier.write(to:metadata:)` takes `MLModelMetadata`, whose
    `additional` dictionary becomes the model's creator-defined metadata;
  - `NLModel.predictedLabelHypotheses(for:maximumCount:)` returns label
    probabilities (macOS 11+).
- **The owner's Mac** is an M5 Pro on macOS 27.0.1. CI runs on GitHub's
  `macos-26` runner, on pull requests only.

## Tasks

### Task 0.1: Worktree and probes (Q1 on this Mac, Q2)

- [ ] **Create the worktree:** branch `feat/f31-intent-models` from
  `origin/main`, in the folder the owner named.
- [ ] **Write a throwaway probe** in a scratch folder outside the repository:
  a Swift script that trains two text classifiers from the same 40 invented
  examples (20 "yes" requests for fresh information, 20 "no"), one with
  `.maxEnt(revision: nil)` and one with
  `.transferLearning(.bertEmbedding, revision: nil)`, and then:
  - prints `NLContextualEmbedding(language: .english)?.hasAvailableAssets`;
  - loads each written model with `NLModel(contentsOf:)` after
    `MLModel.compileModel(at:)`, and predicts one draft;
  - times `predictedLabelHypotheses(for:maximumCount: 2)` over 1,000 drafts
    of 5–60 words, and prints the p50 and p95 per prediction.
- [ ] **Record Q1 (this Mac) and Q2** in the findings table. If BERT training
  or prediction fails here, Q1's answer is "no" and the CI check below is
  skipped.

### Task 0.2: `IntentText`

**Files:** create `Enigma/Intent/IntentText.swift` (app target). Modify
`Enigma/Search/WebSearchPolicy.swift`. Tests go in the new
`EnigmaTests/IntentTextTests.swift`.

**Interfaces.** This task produces:

```swift
/// Text cleanup shared by the rules, the models and the training script.
/// Depends on Foundation only: the training script compiles this file.
enum IntentText {
  static let modelCharacterLimit = 500
  /// Today's `questionText` without `/think` removal: literal material
  /// (code blocks, backticks, straight and curly double quotes) replaced by
  /// a space, `’` → `'`, lowercased, "whats" → "what's", whitespace runs
  /// collapsed to one space, spaces trimmed.
  static func clean(_ text: String) -> String
  /// For models only: each four-digit number from 1000 to 2999 becomes
  /// `yearpast`, `yearrecent` or `yearfuture` relative to `now`'s Gregorian
  /// year (≤ year−2, year−1...year+1, ≥ year+2); then, when longer than
  /// 1,000 characters, the first 500 and last 500 joined by one space.
  static func modelInput(_ cleaned: String, now: Date) -> String
}
```

`WebSearchPolicy.questionText(_:)` becomes
`IntentText.clean(ThinkCommand.message(prompt).content)`. Move
`literalMaterial`, `whatsWithoutApostrophe` and `whitespaceRun` into
`IntentText`. `fourDigitWord` stays in `WebSearchPolicy`: F29's branch uses
it.

**Steps:**

- [ ] **Write the failing tests** in `IntentTextTests`:
  - `testCleanMatchesTodaysQuestionText`, table-driven:

    | Input | `IntentText.clean` |
    | --- | --- |
    | `"What's   the\nWeather?"` | `"what's the weather?"` |
    | `"whats new"` | `"what's new"` |
    | `"Don’t search"` | `"don't search"` |
    | `"  Hello  "` | `"hello"` |

    and for each input, `WebSearchPolicy.questionText(input) == IntentText.clean(input)`.
  - `testCleanRemovesLiteralMaterial` (Review Focus 1):

    | Input | `IntentText.clean` |
    | --- | --- |
    | `#"what does "text Alex" mean"#` | `"what does mean"` |
    | ``"`message Sam` is a command"`` | `"is a command"` |
    | `"```swift\nsearch the web\n``` explain"` | `"explain"` |
    | `"“text me back” lyrics"` | `"lyrics"` |

  - `testQuestionTextStillRemovesThink`:
    `WebSearchPolicy.questionText("/think What's new") == "what's new"`.
  - `testYearsBecomeWordsRelativeToNow` (Review Focus 2), with `now` at
    2026-06-15 12:00 UTC:

    | Cleaned input | `modelInput` |
    | --- | --- |
    | `"election results 2024"` | `"election results yearpast"` |
    | `"2025 2026 2027"` | `"yearrecent yearrecent yearrecent"` |
    | `"plans for 2028"` | `"plans for yearfuture"` |
    | `"in 1999"` | `"in yearpast"` |
    | `"12345 and 3000 and 0999"` | unchanged |

  - `testLongInputKeepsBothEnds` (Review Focus 4): a cleaned text of
    `"start "` + 2,000 × `"x"` + `" end"` gives a result whose first 500
    characters equal the input's first 500, whose last 500 equal the
    input's last 500, and whose count is 1,001.
  - `testModelInputLeavesShortTextAlone`: a 1,000-character input without
    years is returned unchanged.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/IntentTextTests`.
  Expect a compile failure.
- [ ] **Implement,** then run `IntentTextTests`, `WebSearchTests`,
  `ComposerIntentTests` and `ComposerIntentPhrasingTests`. Expect all to
  pass unedited.

### Task 0.3: `IntentSkill` and `IntentTrainingSupport`

**Files:** create `Enigma/Intent/IntentSkill.swift` (app target) and
`IntentTraining/IntentTrainingSupport.swift` (`EnigmaTests` target only).
Tests go in the new `EnigmaTests/IntentTrainingSupportTests.swift`.

`IntentTrainingSupport.swift` uses `IntentText` and `IntentSkill`. In the
test target they come from the app module, and in the script they're
compiled alongside, so the file starts with
`#if canImport(Enigma)` / `@testable import Enigma` / `#endif`.

**Interfaces.** This task produces:

```swift
// IntentSkill.swift — Foundation only; the script compiles it.
enum IntentSkill: String, CaseIterable, Sendable {
  case search, messages, think, selection, coding, reasoning
  enum Lean: Sendable { case none, off }
  static let maximumWrongYesShare = 0.02
  var labels: [String]          // ["yes", "no"]; selection: ["edit", "translate", "none"]
  var negativeLabel: String     // "no"; selection: "none"
  var lean: Lean                // per the plan's skills table
  var modelName: String         // "IntentSearch", "IntentMessages", …
  var isChip: Bool              // search, messages, think, selection
  /// Binary: "yes" when probabilities["yes"] ≥ cutoff, else "no".
  /// Selection: "translate" when its probability ≥ cutoff, else "edit" when
  /// its probability ≥ cutoff, else "none" (translation wins).
  func answer(probabilities: [String: Double], cutoff: Double) -> String
}

// IntentTrainingSupport.swift — Foundation and CryptoKit only.
struct IntentExample: Codable, Equatable, Sendable {
  var text: String
  var label: String
  var nearMiss: Bool? = nil
  var why: String? = nil        // must-pass only: why it must pass
}
struct IntentExampleFile: Equatable, Sendable {
  var asOf: Date                // first line: {"asOf": "YYYY-MM-DD"}, UTC noon
  var examples: [IntentExample] // one JSON object per following line
  /// Throws an error naming the 1-based line on bad JSON, a missing `asOf`
  /// line, or a label not in `skill.labels`.
  static func parse(_ data: Data, skill: IntentSkill) throws -> IntentExampleFile
}
struct IntentScore: Codable, Equatable, Sendable {
  var total: Int
  var correct: Int
  var yesCount: Int             // answers other than the negative label
  var wrongYes: Int             // yes answers that don't equal the expected label
  var accuracy: Double { get }
  var wrongYesShare: Double { get }   // wrongYes / yesCount, 0 when yesCount is 0
  init(answers: [(expected: String, actual: String)], negativeLabel: String)
}
enum IntentTrainingSupport {
  static let cutoffCandidates: [Double]   // 0.05...0.95 in steps of 0.01
  /// SHA-256 of `IntentText.clean(text)`; first byte divisible by 5.
  static func isValidation(_ text: String) -> Bool
  /// Lean none: highest accuracy, ties to the candidate nearest 0.5.
  /// Lean off: most correct yeses with wrongYesShare ≤ 0.02, ties to the
  /// higher cut-off; nil when no candidate qualifies.
  static func chooseCutoff(for skill: IntentSkill,
                           validation: [(expected: String, probabilities: [String: Double])]) -> Double?
  /// Cleaned texts that appear in both lists.
  static func overlaps(_ first: [IntentExample], _ second: [IntentExample]) -> [String]
  /// Lowercase hex SHA-256.
  static func fingerprint(_ data: Data) -> String
}
```

**Steps:**

- [ ] **Write the failing tests** in `IntentTrainingSupportTests`:
  - `testBinaryAnswerUsesCutoff`: `.search.answer(probabilities: ["yes": 0.6, "no": 0.4], cutoff: 0.5) == "yes"`; with cutoff 0.7, `"no"`.
  - `testSelectionAnswerPrefersTranslate`: `["edit": 0.5, "translate": 0.5, "none": 0]` at 0.5 gives `"translate"`; `["edit": 0.8, "translate": 0.1, "none": 0.1]` gives `"edit"`; `["edit": 0.3, "translate": 0.3, "none": 0.4]` gives `"none"`.
  - `testSkillsTable`: every skill's `labels`, `negativeLabel`, `lean`,
    `modelName` and `isChip` match the plan's skills table.
  - `testParseExampleFile`: a three-line file gives `asOf` 2026-10-27 and two
    examples; a bad JSON third line throws an error whose description
    contains "line 3"; a file without the `asOf` line throws; a `"maybe"`
    label for `.search` throws.
  - `testScoreCountsWrongYeses`: answers `(yes, yes), (no, yes), (yes, no),
    (no, no)` give accuracy 0.5, `yesCount` 2, `wrongYes` 1,
    `wrongYesShare` 0.5. For `.selection`, `(translate, edit)` counts as a
    wrong yes and `(edit, none)` doesn't.
  - `testChooseCutoffLeanNone`: a synthetic validation set whose accuracy
    peaks only at 0.60 returns 0.60.
  - `testChooseCutoffLeanOff`: a set whose accuracy peaks at 0.40 but whose
    wrong-yes share first falls to 0.02 at 0.75 returns 0.75; a set where no
    candidate reaches 0.02 returns nil.
  - `testValidationSplitIsStable`: the same text always gives the same
    answer; over 1,000 generated distinct texts, between 15% and 25% are
    validation.
  - `testOverlapsUseCleanedText`: `"What's new?"` and `"whats   new?"`
    overlap.
  - `testFingerprintIsSHA256Hex`: `fingerprint(Data("abc".utf8)) ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`.
- [ ] **Run** the tests. Expect a compile failure.
- [ ] **Implement,** register the files, then run the tests. Expect them to
  pass.

### Task 0.4: The training script

**Files:** create `IntentTraining/train.swift`,
`IntentTraining/config.json` and `scripts/train-intent-models.sh`. Modify
`Enigma.xcodeproj/project.pbxproj`: `COREML_CODEGEN_LANGUAGE = None` in both
of the app target's build configurations.

**Interfaces.** This task produces:

```text
scripts/train-intent-models.sh [--data <dir>] [--out <dir>] [--check] [--kind maxEnt|bert] <skill>...
  --data   default IntentTraining         (reads <dir>/<skill>/train.jsonl, test.jsonl, must-pass.jsonl)
  --out    default Enigma/Resources/IntentModels
  --check  parse and overlap only; trains nothing (IntentScoreTests checks sizes)
  --kind   force one model type (fixtures and probes only)
IntentTraining/config.json: {"allowsBERT": false}
```

The shell script compiles `IntentTraining/train.swift`,
`IntentTraining/IntentTrainingSupport.swift`,
`Enigma/Intent/IntentText.swift` and `Enigma/Intent/IntentSkill.swift` with
`swiftc -O -parse-as-library` into a temporary folder, runs it, and deletes
it. `train.swift` holds an `@main` type and imports CreateML. For each skill
it:

1. parses the three files (missing `test.jsonl` and `must-pass.jsonl` are
   allowed) and exits non-zero on any overlap between the training file and
   either of the others;
2. splits the training file with `isValidation`, and trains `maxEnt` on the
   rest, plus `bert` when `config.json` allows it (or only the `--kind`),
   with the text column set to `IntentText.modelInput(IntentText.clean(text), now: asOf)`;
3. for each trained type, scores the validation share at
   `chooseCutoff`'s cut-off, and keeps the type with the higher validation
   accuracy (ties to `maxEnt`); exits non-zero if no cut-off qualifies;
4. times 1,000 predictions of the kept model and computes its p95;
5. for chip skills, adds the p95 of every other chip model already in
   `--out`, and exits non-zero, writing nothing, if the sum is over 5 ms;
   for `coding` and `reasoning`, exits non-zero if the p95 is over 20 ms;
6. writes `<out>/<modelName>.mlmodel` with metadata `enigma.cutoff`,
   `enigma.kind`, `enigma.fingerprint` (of `train.jsonl`'s bytes) and
   `enigma.asOf`, and writes `<data>/<skill>/report.json`: kind, cut-off,
   the validation `IntentScore`, p95 in milliseconds, fingerprint, and the
   training and validation counts.

**Steps:**

- [ ] **Write the fixture data:** `EnigmaTests/Fixtures/IntentModels/search/train.jsonl`
  with `asOf` 2026-10-27 and 60 invented examples (30 "yes" such as
  "latest news about the election", 30 "no" such as "write a poem about the
  sea"), and `think/train.jsonl` the same way for "think hard about this"
  style requests. Mark them as fixtures in
  `EnigmaTests/Fixtures/IntentModels/README.md`. Fixture models aren't added
  to any target; tests compile them at run time.
- [ ] **Run** `scripts/train-intent-models.sh --data EnigmaTests/Fixtures/IntentModels --out EnigmaTests/Fixtures/IntentModels --kind maxEnt search`.
  Expect `IntentSearch.mlmodel` and a report. Run `--check search` and
  expect success.
- [ ] **If Q1 on this Mac was "yes",** train the think fixture with
  `--kind bert`, giving `IntentThink.mlmodel` (a BERT model).
- [ ] **Check the refusals by hand:** add a training text to a scratch copy
  of the fixture's `test.jsonl` and confirm the script exits non-zero,
  naming the overlap. Record it in the Hand-off.

### Task 0.5: `IntentModels` and `IntentPins`

**Files:** create `Enigma/Intent/IntentModels.swift` and
`Enigma/Intent/IntentPins.swift` (app target). Tests go in the new
`EnigmaTests/IntentModelsTests.swift`.

**Interfaces.** This task produces:

```swift
struct IntentModelInfo: Equatable, Sendable {
  let cutoff: Double
  let kind: String              // "maxEnt" or "bert"
  let trainingFingerprint: String
  let asOf: String
}

struct IntentPins: Sendable {
  static let maximumPerSkill = 20
  /// The app's pins; empty until a must-pass example needs one.
  static let shipped: IntentPins
  /// Patterns are fixed source literals, matched against cleaned text, in order.
  init(_ table: [IntentSkill: [(pattern: String, label: String)]])
  func answer(_ skill: IntentSkill, cleaned: String) -> String?
  func count(_ skill: IntentSkill) -> Int
}

final class IntentModels: Sendable {
  static let shared = IntentModels(bundle: .main)
  /// Looks up `<modelName>.mlmodelc` in the bundle.
  init(bundle: Bundle, pins: IntentPins = .shipped)
  /// Looks up `<modelName>.mlmodelc` in a folder of compiled models (tests).
  init(compiledModelsIn directory: URL, pins: IntentPins = .shipped)
  func info(_ skill: IntentSkill) -> IntentModelInfo?
  func probabilities(_ skill: IntentSkill, for modelInput: String) -> [String: Double]?
  /// Empty text: the negative label, without loading a model. Otherwise the
  /// pins, then the model at its cut-off. A missing or damaged model gives
  /// the negative label and logs the skill's name once.
  func answer(_ skill: IntentSkill, cleaned: String, now: Date = Date()) -> String
}
```

Each model loads lazily, once, under a `Mutex` from `Synchronization`, and
predictions run under the same lock. Log with `Logger` (subsystem: the
bundle identifier, category `IntentModels`), the skill's name only.

**Steps:**

- [ ] **Write the failing tests** in `IntentModelsTests`. A `setUp` compiles
  the fixture models (read through `#filePath`) with
  `MLModel.compileModel(at:)` into a temporary folder.
  - `testLoadsFixtureModelAndMetadata`: `info(.search)` has `kind ==
    "maxEnt"`, a cut-off from 0.05 to 0.95, and a fingerprint equal to
    `IntentTrainingSupport.fingerprint` of the fixture's `train.jsonl`.
  - `testFixtureModelAnswers`: `answer(.search, cleaned: "latest news about
    the election")` is `"yes"` and `answer(.search, cleaned: "write a poem
    about the sea")` is `"no"`.
  - `testMissingModelAnswersNegative` (Review Focus 3): an `IntentModels` on
    an empty folder gives `info(.messages) == nil`, `answer(.messages,
    cleaned: "text mom") == "no"` and `answer(.selection, cleaned:
    "translate this") == "none"`.
  - `testPinsApplyWithoutAModel` (Review Focus 3): on an empty folder with
    `IntentPins([.messages: [(#"^check my texts$"#, "yes")]])`,
    `answer(.messages, cleaned: "check my texts") == "yes"`.
  - `testEmptyTextAnswersNegativeWithoutAModel` (Review Focus 5):
    `answer(.search, cleaned: "") == "no"` on the fixture folder.
  - `testEmojiAndNonEnglishDraftsAnswer` (Review Focus 5):
    `answer(.search, cleaned: "🎉🎉")` and `answer(.search, cleaned:
    "¿dónde está la biblioteca?")` return `"yes"` or `"no"` without crashing.
  - `testShippedPinsStayWithinLimit`: for every skill,
    `IntentPins.shipped.count(skill) <= 20`.
  - `testBERTFixturePredictsOffline` (Q1 on CI), only if the BERT fixture
    exists: skips with `XCTSkip` when
    `NLContextualEmbedding(language: .english)?.hasAvailableAssets != true`;
    otherwise `probabilities(.think, for: "think hard about this")` is not
    nil.
- [ ] **Run** the tests. Expect a compile failure.
- [ ] **Implement,** register the files, then run the tests. Expect them to
  pass.

### Task 0.6: Exit checks and the draft pull request

- [ ] **Run** `scripts/verify-xcode.sh build`, `test` and `analyze`. Every
  existing test passes unedited.
- [ ] **Ask the owner** in the chat to approve opening a draft pull request
  from `feat/f31-intent-models` to `main`, titled "F31: trained models for
  recognizing commands and routing". After the commit and push, open it
  with `gh pr create --draft` (body: one paragraph from the spec's Goal, and
  "Built in checkpoints; see the plan"), and report its CI run, including
  whether `testBERTFixturePredictsOffline` passed or skipped. CP1 records
  that result.

## Exit criteria

- `scripts/verify-xcode.sh build`, `test` and `analyze` pass.
- No recognizer's behavior changed: every pre-existing test passes
  unedited.
- `IntentTraining/config.json` is `{"allowsBERT": false}`. CP1 sets it from
  Q1.
- The findings table is filled in, with Q1's CI half marked "pending, CP1
  records".
- No probe code is left in the worktree.

## Reviewer checklist

- **Cleanup parity:** `questionText`'s output is unchanged for every input
  (compare the old and new implementations in a scratch copy on the
  phrasings in `ComposerIntentPhrasingTests` and `ComposerIntentTests`).
- **Script and app agree:** the script compiles the same `IntentText` and
  `IntentSkill` files, and builds model input the same way as
  `IntentModels.answer`.
- **Concurrency:** no model loaded twice; no lock held across a call that
  could block on another lock.
- **Values:** cut-off candidates, the 2% share, speed limits, metadata
  keys.

## Hand-off

*Filled in by the CP0 worker.*

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q1 | BERT models offline, on this Mac and on CI | **This Mac: yes.** CI: pending, CP1 records | Probe on the owner's M5 Pro, macOS 27.0.1, Xcode 27.1: `NLContextualEmbedding(language: .english)?.hasAvailableAssets == true`; `.transferLearning(.bertEmbedding, revision: nil)` trained 40 examples in 2.7–4.0 s, compiled, loaded with `NLModel(contentsOf:)` and predicted with no download. `testBERTFixturePredictsOffline` passed here (not skipped). CI's result comes from the draft PR's run | `allowsBERT` stays `false` until CP1 reads the CI result. Even then, BERT can only serve `coding` and `reasoning` (see Q2) |
| Q2 | Prediction time of each type, here and on CI | **This Mac:** maxEnt p50 0.037 ms, p95 0.05 ms; BERT p50 6.4 ms, p95 6.7–6.9 ms. **CI:** not measured. CI never trains, and CP1 records only whether the BERT fixture predicts there. The CI half of this question is dropped, since the speed limits are enforced where the script runs | Probe: 1,000 drafts of 5–60 words. The script's own timings agree: the search fixture's maxEnt p95 is 0.02–0.03 ms; BERT p95 is 6.4–6.5 ms | **One BERT model alone exceeds the 5 ms chip budget.** The script drops any type over its skill's own limit before comparing accuracy, so the chip skills come out maxEnt on this Mac even with `allowsBERT` true. BERT fits Auto's 20 ms limit, for `coding` and `reasoning` only |
| Q3 | Models with class generation off: build, test, analyze; loading compiled models (the app-bundle half is CP2's `testShippedSearchModelLoads`) | **Yes** | In a scratch copy (outside the repo), the search fixture registered as `Enigma/Resources/IntentModels/IntentSearch.mlmodel` in the app's Sources phase: `build`, `analyze` and a probe test all passed. `coremlc` wrote `Enigma.app/Contents/Resources/IntentSearch.mlmodelc`; no `IntentSearch` Swift class was generated; `IntentModels(bundle: .main).answer(.search, …)` answered in the test host. In the worktree, `IntentModelsTests` loads compiled fixtures through `init(compiledModelsIn:)` | Register each model as the workflow says; models land in `Contents/Resources/`, which `Bundle.url(forResource:withExtension: "mlmodelc")` finds |
| Q4 | `IntentText.swift` compiles alone in the script | **Yes** | `swiftc -typecheck -parse-as-library Enigma/Intent/IntentText.swift` and the same for `IntentSkill.swift` pass alone; the script compiles the four files together with `-O -parse-as-library`, and they also type-check together under `-swift-version 6` | Keep both files Foundation-only; `IntentTrainingSupport.swift` may add CryptoKit only |

1. **Summary:** CP0 answers the four open questions and adds the shared machinery, without changing any recognizer. `IntentText.clean` is today's cleanup, which `WebSearchPolicy.questionText` now calls. `IntentText.modelInput` adds year words and the long-draft cut. `IntentSkill` holds the skills table and how a probability becomes an answer. `IntentTrainingSupport` holds the example format, scoring, the validation split, cut-off choice, overlaps and fingerprints. `scripts/train-intent-models.sh` trains, picks a type and cut-off, checks speed and writes models plus reports. `IntentModels` and `IntentPins` load models and answer. Nothing calls `IntentModels` yet, and no model ships in the app.
2. **Files:**
   - `Enigma/Intent/IntentText.swift` (new, app): `clean`, `modelInput`, `modelCharacterLimit`; holds `literalMaterial`, `whatsWithoutApostrophe` and `whitespaceRun`, moved from `WebSearchPolicy`.
   - `Enigma/Intent/IntentSkill.swift` (new, app): skills, labels, leans, model names, `answer(probabilities:cutoff:)`.
   - `Enigma/Intent/IntentPins.swift` (new, app): per-skill override patterns; `shipped` is empty.
   - `Enigma/Intent/IntentModels.swift` (new, app): lazy, once-only loading under a `Mutex`; metadata into `IntentModelInfo`; answers.
   - `Enigma/Search/WebSearchPolicy.swift`: `questionText` is now `IntentText.clean(ThinkCommand.message(prompt).content)`; the three moved patterns are gone, and `fourDigitWord` stays.
   - `IntentTraining/IntentTrainingSupport.swift` (new, `EnigmaTests` target only, and the script): example files, `IntentScore`, split, cut-offs, overlaps, fingerprint.
   - `IntentTraining/train.swift` (new, script only): the trainer.
   - `IntentTraining/config.json` (new): `{"allowsBERT": false}`.
   - `scripts/train-intent-models.sh` (new): compiles the trainer into a temporary folder, runs it, and deletes it.
   - `EnigmaTests/IntentTextTests.swift`, `IntentTrainingSupportTests.swift`, `IntentModelsTests.swift` (new): the brief's tests, plus a few more (see Decisions).
   - `EnigmaTests/Fixtures/IntentModels/`: `README.md`, with the exact training commands; `search/train.jsonl` (70 invented examples, ten of them with years) and `think/train.jsonl` (60); `IntentSearch.mlmodel` (maxEnt) and `IntentThink.mlmodel` (BERT, 1.3 MB), trained by the script; the two `report.json` files. In no target.
   - `Enigma.xcodeproj/project.pbxproj`: eight Swift files registered: four in the app, and in `EnigmaTests` the three test files plus `IntentTrainingSupport.swift`; `COREML_CODEGEN_LANGUAGE = None` in the app's Debug and Release.
   - This brief's Hand-off, and the plan's progress-log row.
3. **Decisions:**
   - **Worktree:** `/private/tmp/claude-501/enigma-f31`, since the owner named no folder. The branch's upstream is unset, so a bare `git push` can't reach `main`; push with `git push -u origin feat/f31-intent-models`.
   - **Owner approval (2026-10-27):** the owner approved both departures from the brief below: choosing the model type within the speed limits, and `--kind` not enforcing speed limits.
   - **Model type within the speed limits (spec over brief).** The brief's steps 3–5 pick the type by accuracy, then refuse the run if it's too slow. The spec (§3) keeps the better type "within the speed limits". The spec binds, so the script times each trained type, drops any over its skill's own limit (5 ms for chips, 20 ms for `coding` and `reasoning`), and keeps the most accurate of the rest (ties to maxEnt). The shared chip check (this run's chip models plus those already in `--out`, at most 5 ms together) is still the final gate. Checked by hand in a scratch copy with `allowsBERT` true: for one data set, `messages` kept maxEnt (BERT's 6.4 ms was dropped despite its 1.000 accuracy), and `coding` kept BERT.
   - **`--kind` doesn't enforce speed limits, and can't touch the app's files.** The brief asks for a BERT think fixture, but think is a chip, and BERT's 6.4 ms is over the 5 ms budget. `--kind` is documented as "fixtures and probes only", so with it the script prints "speed limits not enforced" and still reports p95. Because it also skips the `allowsBERT` gate, a training run with `--kind` is refused unless both `--data` and `--out` are given, and neither is `IntentTraining` or `Enigma/Resources/IntentModels`. The comparison uses `realpath` of the deepest existing folder, lowercased, so a different case, a symlink (`/tmp` for `/private/tmp`) or a folder that doesn't exist yet can't slip past. `--check` with `--kind` is still allowed, since it writes nothing.
   - **A chip model already in `--out` that won't compile fails the run.** Counting it as 0 ms would hide it from the shared budget.
   - **Lean off needs at least one correct yes.** A cut-off that says yes to nothing has a wrong-yes share of 0, and would otherwise always "qualify" (0.95, a model that never fires). `chooseCutoff` returns nil instead, so the script refuses.
   - **Years are digit-bounded,** `(?<![0-9])[0-9]{4}(?![0-9])`, like the rules' own year check, which splits on non-digits. So "v2024" becomes "vyearpast" (about the same as the rules), not left alone as `\b` would leave it.
   - **Example files:** blank lines are skipped. The `asOf` line must come first; a later line without `text` or `label` is "bad example JSON".
   - **Training:** `MLTextClassifier` gets a `DataFrame` (the `MLDataTable` initializer is deprecated), `validation: .none` (the script holds back its own validation share) and `language: .english`. Every skill in a run is trained and checked before anything is written, so one failing skill writes nothing at all. The kept model is timed on its own training inputs; other chip models already in `--out` are compiled and timed on 200 invented drafts of 5–60 words.
   - **Model metadata:** `enigma.cutoff` is written as `%.2f`; `enigma.asOf` is `YYYY-MM-DD`. A model whose metadata lacks any of the four keys, or whose cut-off doesn't parse, counts as damaged.
   - **`IntentModels`:** each skill has its own `Mutex`, so a first load, or a BERT prediction at send, never holds up another skill's chip. Loading and predicting run under that skill's lock, and nothing else is locked inside it. A load failure is cached and logged once (skill name only, outside the lock). A prediction that returns no hypotheses answers negative without logging. `loadAttempts(_:)`, an addition for tests, counts loads per skill (at most 1).
   - **`IntentText.modelInput`** builds its result in one forward pass. Editing the string in place made it quadratic on long non-ASCII drafts with many years: 1.5 s for 80,000 characters.
   - **Example files** end lines only at `\n`, with a trailing `\r` dropped. So CRLF files read correctly, and a raw U+2028 inside a JSON string doesn't break its line.
   - **`parse` refuses a typed `/think`** (`(?i)(?<!\S)/think(?=$|\s|[.,!?;:])`, the `SlashCommand` token rule, quoted or not). The app removes a typed `/think` before any recognizer or model reads the draft, but the script and `isValidation`/`overlaps` start from `IntentText.clean`, which per the brief keeps `/think`. Without the refusal, an example seeded from `WebSearchTests` such as "/think What happened yesterday?" would train on text the app never shows the model. The brief's definition of `clean` is unchanged. The error reads "line N: remove the typed /think; …".
   - **`IntentModelInfo(metadata:)`** is a failable initializer, split out of `IntentModels.load` so "missing metadata counts as damaged" can be tested. A cut-off outside 0...1, NaN included, counts as damaged too.
   - **`IntentPins`:** a pin with a label outside `skill.labels` is a `precondition` failure, since pins are source literals.
   - **Extra tests,** beyond the brief:
     - `testCutoffCandidates`, `testChooseCutoffLeanNoneTiesToTheMiddle`, `testChooseCutoffLeanOffForSelection`, and a never-right case in `testChooseCutoffLeanOff`, which pins "needs one correct yes";
     - CRLF, U+2028 and typed-`/think` cases in `testParseExampleFile`;
     - the year edges 1000 and 2999, and digit-bounded years ("v2024", "the 1990s"), in `testYearsBecomeWordsRelativeToNow`; no model load for empty text in `testEmptyTextAnswersNegativeWithoutAModel`; exactly 2% wrong yeses in `testChooseCutoffLeanOffAllowsExactlyTwoPercent`; two known members of the validation split; `testMetadataNeedsEveryKey`;
     - `testManyYearsInALongNonASCIIDraftStayFast`;
     - `testDamagedModelAnswersNegative`, `testPinsWinOverTheModelInOrder`, `testConcurrentAnswersAgree` and `testModelLoadsOnce`;
     - `testUsesTheModelInputForYears`: "in 2026" is below the fixture's cut-off and "in yearrecent" above it, so it fails if the app skips `modelInput`;
     - `testAnswerUsesTheRecordedCutoff`: the cut-off is 0.66, and a draft between 0.5 and 0.66 must answer "no".
   - **The BERT fixture compiles inside its own test,** after the asset check, so a BERT problem on CI fails only that test.
   - **Hand checks of the refusals** (scratch copies): a training text in `test.jsonl` exits 1 with `search: train.jsonl overlaps test.jsonl: latest news about the election`, both when training and with `--check`, and writes nothing. With the budgets lowered in a scratch build, the chip-total and send limits both exit 1 and write nothing.
4. **Verification** (owner's M5 Pro, macOS 27.0.1, Xcode 27.1, final state):
   - `scripts/verify-xcode.sh build`: BUILD SUCCEEDED.
   - `scripts/verify-xcode.sh test`: 1,369 executed, 20 skipped (the existing opt-in screenshot, installed-model and smoke tests), 0 failed. Earlier full runs, made while other compiles ran, twice timed out in `EnigmaMainWindowTests.testSendNowDuringAPendingSend…` and once crashed the host in `LocalVisionTests.testCancellingGuidedDownloadRemovesPartialPackage`. Each passed when rerun alone, and reviewers saw the same send test fail under load at `bd28305` too.
   - The CP0 classes (`IntentTextTests`, `IntentTrainingSupportTests`, `IntentModelsTests`, `WebSearchTests`, `ComposerIntentPhrasingTests` and the five classes in `ComposerIntentTests.swift`): 128 executed, 1 skipped (`testRecognizedChipsScreenshot`), 0 failed. `testBERTFixturePredictsOffline` passed, not skipped.
   - `scripts/verify-xcode.sh analyze`: ANALYZE SUCCEEDED, with no warnings in the new or changed files.
   - Training: `scripts/train-intent-models.sh --data EnigmaTests/Fixtures/IntentModels --out EnigmaTests/Fixtures/IntentModels --kind maxEnt search` gives cut-off 0.66, validation 9 of 10, p95 0.026 ms. `… --kind bert think` gives cut-off 0.47, validation 9 of 11, p95 6.4 ms. `--check search think` passes.
   - Review: three rounds (Opus, xhigh). Rounds 1 and 2 found Should-fix items, all fixed test-first, with every surviving mutation re-checked. Round 3 found no Blocker or Should fix, and I fixed its cheap Nits myself, test-first. Reviewers checked cleanup parity on more than 250,000 inputs with no mismatch, and caught 26 of 28 mutations in round 3; the 2 survivors are now pinned.
   - CI: the draft pull request's first run follows this commit; CP1 records it.
5. **Limitations:**
   - CI hasn't run yet; Q1 and Q2's CI halves wait for the draft pull request.
   - The speed limits are measured on whatever Mac runs the script. Those limits are the owner's M5 Pro numbers, not CI's.
   - Retraining from unchanged data still changes bytes. `report.json`'s p95 changes from run to run. In the `.mlmodel`, Core ML writes the four metadata keys in a different order each time. `SWIFT_DETERMINISTIC_HASHING` doesn't help, because the order comes from Core ML, not from the script.
   - **Create ML's BERT trainer ignores `validation: .none`.** It holds back its own share: "40 training samples and 9 validation samples" for the think fixture's 49. So BERT trains on about 18% fewer examples than maxEnt, and `report.json`'s `trainingCount` overstates what BERT used. That tilts CP5's type comparison slightly against BERT.
6. **For the next checkpoint:**
   - **CP1:** when seeding examples from `WebSearchTests` or elsewhere, drop a typed `/think` from the text. The parser refuses it in every example file, `test.jsonl` and `must-pass.jsonl` included, so tell the test-set writer too, and treat that error like an overlap: remove the line and ask for a replacement.
   - **Known corner (round 3, not fixed):** a chip type is dropped against its own 5 ms, not against the 5 ms the other chip models leave. On a Mac where BERT took 3 ms, two BERT chips could pass one by one and fail the shared check together, although maxEnt would fit. It can't happen here, since BERT takes 6.4–7.9 ms.
   - **Proposal for CP1 (not done):** the overlap check compares `IntentText.clean` text, but the model reads `modelInput`. So "election results 2025" in training and "election results 2026" in a test file both become "election results yearrecent" and pass the check. Comparing `modelInput(clean(text), now: asOf)` as well would close that. The brief defines the check on cleaned text, so I left it.
   - Interfaces match the plan's Interface map, with two additions: `IntentExampleFileError` (`line`, `reason`), whose description reads "line N: …", and `IntentModels.loadAttempts(_:)` for tests.
   - `-only-testing:EnigmaTests/ComposerIntentTests` runs nothing: that file's classes are `MessagesIntentPolicyTests`, `ThinkIntentTests`, `SelectionIntentPolicyTests`, `ComposerIntentResolveTests` and `ComposerIntentChipsTests`.
   - Each `IntentModels.answer` call builds its own `modelInput`. Four chip skills per keystroke means four passes over the draft. They're cheap after the fix, but a caller that asks several skills could build the input once and call `probabilities` itself.
   - Run the script from the worktree root. `--data` and `--out` paths are relative to the repository root, since the script `cd`s there, and it always reads `IntentTraining/config.json`.
   - `IntentTrainingSupport.swift` is in the `EnigmaTests` Sources phase and starts with `#if canImport(Enigma)` / `@testable import Enigma`.
   - Set `allowsBERT` from the draft PR's `testBERTFixturePredictsOffline` result. Expect the chip skills to come out maxEnt either way (BERT is over their limit), with no failed run.
   - The fixture models are trained by the script, so retrain them with it if the metadata format ever changes. `IntentModelsTests` checks the search fixture's fingerprint against its `train.jsonl`.
