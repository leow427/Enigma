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
| Q1 | BERT models offline, on this Mac and on CI | | | |
| Q2 | Prediction time of each type, here and on CI | | | |
| Q3 | Models with class generation off: build, test, analyze; loading compiled models (the app-bundle half is CP2's `testShippedSearchModelLoads`) | | | |
| Q4 | `IntentText.swift` compiles alone in the script | | | |

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
