# Trained models for recognizing commands and routing (F31) — design

Status: approved design, not yet implemented. Date: 2026-10-27.
Plan: [2026-10-27-f31-intent-models.md](../plans/2026-10-27-f31-intent-models.md).
Blocks: F29 (on-device web search) resumes after F31 is merged to `main`.

## Goal and users

Enigma guesses several things from the wording of a draft:

- whether a question needs a web search (automatic search);
- whether to show the `messages`, `think`, `edit` and `translate` chips;
- whether Auto should send a request to Cloud because it is a coding or a
  harder reasoning request.

Each guess is a set of hand-written English rules today. They have grown
into long lists of exceptions (`MessagesIntentPolicy` alone is about 170
lines of patterns, mostly vetoes), and every new miss means another
exception. Some rules misfire in obvious ways: Auto counts "swift" anywhere
as a coding request ("who is Taylor Swift dating"), and "design" alone as
advanced reasoning ("logo design ideas").

F31 replaces those guesses with small classifiers trained on labelled
examples, built with Create ML and run on the Mac by Apple's NaturalLanguage
framework. The privacy rules around them stay as fixed rules.

**What the owner asked for:**

- A trained classifier "for every skill for auto detection and auto routing"
  (2026-10-27), built now, before the rest of F29, because F29 and F30 sit
  downstream of routing.
- The guesses that hurt most in practice: search turning on or off wrongly,
  and the command chips. F29's weather/places/web routing hasn't been used
  yet (it can't run in the app until F29's CP5 and CP6).

**Success means:**

- **Fewer wrong guesses.** For each skill that switches, the model gets more
  of an independent test set right than today's rules do.
- **No privacy regression.** Everything the rules guarantee today about what
  can turn a skill on still holds, enforced by the same kind of fixed rules.
- **Nothing else changes.** Same chips, settings, defaults and speed while
  typing. Nothing leaves the Mac, and there is no extra model call.

## Decisions

Made with the owner on 2026-10-27:

| Topic | Decision |
| --- | --- |
| Approach | Per-skill Create ML text classifiers (`NLModel`), bundled in the app, inside today's privacy rules |
| Rejected: Apple's on-device language model (Foundation Models) | A throwaway check on the owner's Mac (M5 Pro, macOS 27.0.1) took 440–870 ms per draft, refused "think hard about whether I should refinance" as sensitive, hung on "write a haiku about autumn" with the `.contentTagging` use case, and got 1–3 of 6 drafts right with a plain prompt. Too slow for chips while typing, and its refusals and hangs would need today's rules as a complete second system |
| Rejected: Laya | An open-source intent model that needs Python and PyTorch or a new ONNX dependency, is 0.8–1.7 GB, and is weak until fine-tuned |
| Rejected: the selected local model | It may not be loaded, competes with the reply for the GPU, and behaves differently from one model to the next |
| Tests | Each switched skill keeps a score floor on a held-out test set, plus a must-pass list that is always right |
| Examples | The training set and the test set have different writers; the owner spot-checks 100 test labels |
| Search's lean | None: the cut-off that gets the most answers right |
| Old rules | A skill's regex recognizer is deleted once its model switches, except the parts that are privacy or conflict rules |
| Weather/places/web | Not in F31. When F29 resumes, a small F29 step builds that model with F31's tools, before F29's CP5 |
| Order | F29 is paused after its CP1 until F31 is merged |

## Design

### 1. Architecture and data flow

```
draft ──► IntentText.normalize ──► privacy and conflict rules ──► model ──► cut-off ──► fixed overrides ──► yes/no
                                    (can only say no, or force       (probability)  (per skill)   (must-pass pins)
                                     yes where a rule says so today)
```

- **`Enigma/Intent/IntentText.swift`** (new) holds the text cleanup the rules
  use today (`WebSearchPolicy.questionText`): `/think` removed, quoted,
  backticked and code-block text removed, lowercased, curly apostrophes
  straightened, "whats" read as "what's", whitespace collapsed. It has no
  dependency on other app types, so the training script compiles the same
  file and the model always sees text cleaned the same way.
  `WebSearchPolicy.questionText` calls it.
- **Years.** The rules compare years in the text with today's date ("2024
  election results" is historical in 2026). A classifier can't know the date,
  so `IntentText` replaces each four-digit year with a word for how it
  relates to a reference date: `yearpast` (two or more years before),
  `yearrecent` (the year before, this year or next) or `yearfuture`. The app
  uses today's date; the training script uses the date each example file
  records as its `asOf`.
- **Long drafts.** The model reads the first 500 and last 500 characters of
  the cleaned text, since requests usually sit at the start or the end
  ("…summarize this").
- **`Enigma/Intent/IntentModels.swift`** (new) loads each bundled model once,
  lazily, and has one function per skill that returns a probability. It knows
  nothing about chips, routing or privacy.
- **The existing functions keep their names and callers.** Each one runs its
  privacy and conflict rules first, then asks `IntentModels`, applies the
  skill's cut-off, then its fixed overrides.
- **Fixed overrides** are a short per-skill list of patterns that force yes
  or no. One is added only when a must-pass example fails and more examples
  don't fix it. Each skill has at most 20; a review finding more is a sign
  the examples need work, not another pattern.

### 2. Skills

| Skill | Function (callers unchanged) | Stays as rules | The model decides | Cut-off |
| --- | --- | --- | --- | --- |
| Automatic search | `WebSearchPolicy.needsFreshInformation(normalized:now:)` | No for: empty text, "don't search" opt-outs (`optOut`), the person's own communications (`isAboutOwnCommunications`), this chat (`thisChat`). Yes for: questions that need the location (`LocationIntent.needsLocation`) | Everything `needsFreshFacts` decides today | Most answers right |
| `messages` | `MessagesIntentPolicy.isRequested(normalized:)` | `isFollowUpCue` (it depends on the previous turn), and `ComposerIntent`'s conflicts | Whether the draft asks to read, search or send the person's own messages | Lean off |
| `think` | `ThinkCommand.isRequested(normalized:)` | `ComposerIntent`'s conflicts | Whether the draft asks for careful or deeper thinking | Most answers right |
| `edit`, `translate` | `SelectionIntentPolicy.command(normalized:)` | Only asked when a selection is attached; `leadIn` and `SelectionResponseMode` unchanged; translation wins | One model with three answers: edit, translate, neither | Lean off |
| Auto: coding | `AutoRouter.requiresCoding` (private) | Everything else in `AutoRouter`: modes, context budgets, capabilities, limitations | Whether the request is a coding request | Lean Local |
| Auto: harder reasoning | `AutoRouter.requiresAdvancedReasoning` (private) | As above | Whether the request needs advanced reasoning | Lean Local |

- **Auto's "search the web" check stays a rule.** `requiresWebSearch` only
  matches explicit phrases ("search the web", "latest news"), and when it
  matches with automatic search off, Auto stops the send with "Use /search…"
  because no cloud configuration supports web search today. Swapping in the
  broader search model would stop many more sends, so it is out of scope.
- **The parts of `WebSearchPolicy` that `LocationIntent` uses**
  (`isOfflineOrTransformation`, and the `transformation` and `localTask`
  patterns behind it) stay, since location stays all rules.
- **What `ComposerIntent` already enforces doesn't move:** only the typed
  draft is read; `/screen` and `/snapshot` are never inferred, and a capture
  picks up no inferences; dismissed chips stay off; typed commands win;
  Messages never combines with files, screenshots or search; search is never
  inferred with Messages or files.

**Cut-offs.** The training script sets them from a validation share it holds
back from the training examples, never from the test set.

- **Most answers right:** the cut-off with the highest accuracy.
- **Lean off and Lean Local:** the cut-off with the most correct yeses while
  at most 2% of its yeses are wrong. A wrong yes reads the person's messages,
  changes their selection, or sends a request off the Mac.

### 3. Models and training

- **Model type.** Create ML's text classifier offers a maximum-entropy model
  (word features, well under a millisecond) and transfer learning on the
  BERT embedding built into macOS 14 and later (understands wording better,
  adds little to the app, slower). For each skill the training script trains
  both and keeps the one that scores better on the validation share within
  the speed limits. BERT is allowed only if CP0 confirms it works offline
  with no asset download (see Open questions).
- **Speed limits.** While typing, every chip model together must take at most
  5 ms per keystroke on Apple silicon. Auto's two models run at send, with
  20 ms. The training script measures on the machine it runs on and rejects
  a model over its limit.
- **Files.**
  - `IntentTraining/<skill>/train.jsonl`, `test.jsonl`, `must-pass.jsonl`:
    one example per line, `{"text": …, "label": …}`, and a first line with the
    file's `asOf` date.
  - `IntentTraining/train.swift` and `scripts/train-intent-models.sh`: trains,
    picks model types and cut-offs, checks speed, and writes the models.
  - `Enigma/Resources/IntentModels/<skill>.mlmodel`: committed, like F29's
    generated `SearchData/`. Xcode compiles them at build time, with model
    class generation off. CI never retrains.
  - Each model's metadata records its cut-off, its model type, and a
    SHA-256 fingerprint of its training file.
- **Overlap check.** The script refuses to train if a test or must-pass
  example matches a training example after `IntentText.normalize`.

### 4. Examples

- **Training set (written by the F31 worker):** starts from the phrasings in
  `ComposerIntentPhrasingTests` and the drafts in `ComposerIntentTests`,
  `MessagesTests`, `WebSearchTests` and `AutoRouterTests`, and the example
  tables in `docs/Slash-Commands.md` and `docs/Web-Search.md`. It adds casual
  wording, typos, long drafts, drafts that need two skills, and near-misses
  ("text classification", "what do you think", "it'll take a while"). At
  least 800 examples per skill (about 1,500 for search), with at least 40% of
  the "no" examples being near-misses.
- **Test set (written by a separate agent):** its brief gives only what each
  skill means in plain words and the kinds of case to cover. It never sees
  the training set or the rule code. About 250 per skill.
- **Owner check:** the owner checks a random 100 test labels across skills
  before anything is measured. More than 5 wrong sends the test set back to
  its writer.
- **Must-pass list:** about 30 per skill: privacy cases, the headline
  examples in the docs, and every miss the owner reports from now on.
- **Baseline:** today's rules are scored on the test set before any model is
  trained, and the numbers recorded.

### 5. Privacy

- The models read only the cleaned typed draft, exactly what the rules read
  today. Selection text, files, screenshots, OCR, earlier messages and tool
  results are never passed to them.
- Everything runs on the Mac. No example, draft or score is sent anywhere.
- The privacy rules in section 2 run before the model and can't be overridden
  by it: message contents never become a web search, location is read only
  for the person's own question, "don't search" is respected, and only
  `LocationIntent` decides whether the location is read.
- Training data contains no personal data: examples are invented wording.

### 6. What users see

- No new UI, setting or default. "Recognize commands from your wording"
  stays off until turned on; automatic search keeps its own switch.
- Only the guesses change, and only for skills that passed their switch-over
  test. Recognition stays English-only.
- The app grows by the models' size: from a few hundred KB to a few MB.

## Failure handling

| Failure | Behavior |
| --- | --- |
| A model fails to load or predict (a damaged app) | That skill recognizes nothing: no chip, no automatic search, Auto stays Local. Fixed overrides still apply. Logged once; never a crash |
| A draft is empty after cleanup | No; the model isn't asked |
| A very long draft | The model reads its first and last 500 characters |
| A model's training file changed but the model wasn't retrained | A unit test fails (fingerprint mismatch) |

## Testing

- **`IntentModelScoreTests`** (new): runs the bundled models over each
  switched skill's `test.jsonl` and `must-pass.jsonl`, offline. Each skill
  must stay at or above its recorded floor (its test score when it switched,
  minus 2 points), and every must-pass example must be right. It also checks
  each model's fingerprint against its training file. The test bundle carries
  the example files.
- **`IntentTextTests`** (new): the cleanup, including the year words and the
  long-draft cut.
- **`ComposerIntentTests`**: unchanged. They test the privacy and conflict
  rules, which still decide.
- **`ComposerIntentPhrasingTests`**: replaced. Its phrasings move into the
  training set and the must-pass lists, and `IntentModelScoreTests` takes
  over. This replaces "every phrasing exactly right" with "a score floor plus
  a must-pass list", which the owner approved on 2026-10-27; it is not a
  weakened test under AGENTS.md.
- **`MessagesTests`, `WebSearchTests`, `AutoRouterTests`,
  `SelectionContextTests`**: assertions about rules that stay are unchanged.
  An assertion that only pinned one regex's wording moves into the examples
  as a must-pass item instead.
- **Speed:** a test resolves 1,000 drafts through `ComposerIntent.resolve`
  with a loose limit so slower CI machines don't fail at random. The strict
  5 ms limit is enforced by the training script. The existing
  "long repeated drafts stay fast" test stays.

**Switch-over test, per skill.** A skill switches to its model only if, on
its test set:

1. the model gets more examples right than today's rules;
2. for lean-off and lean-Local skills, the share of wrong yeses is no higher
   than the rules';
3. every must-pass example is right.

A skill that fails keeps its rules, and the evaluation report says why.

## Docs

- `docs/Slash-Commands.md`: "fixed English rules on this Mac" becomes small
  trained models on this Mac plus fixed privacy rules, with nothing leaving
  the Mac.
- `docs/Web-Search.md`: automatic search.
- `docs/Cloud-Model-Selection.md`: Auto's coding and reasoning checks.
- `docs/Intent-Models.md` (new): how the models work, the example files, and
  how to add a miss and retrain. Indexed in `docs/README.md`.
- `docs/history/evaluations/`: the report, with each skill's rules and model
  scores.
- `AGENTS.md`: the training script under "Build, Test, and Development
  Commands".
- `to-do.md`: the F31 entry.

## Delivery

- Branch `feat/f31-intent-models` from `main`, in a worktree outside
  `~/Documents`.
- Checkpoints, each one commit:
  - **CP0, check and tooling:** answer the open questions; `IntentText`;
    the training script, overlap check and fingerprints; the `IntentModels`
    loader.
  - **CP1, examples:** training sets, the separately written test sets,
    must-pass lists, the owner's 100-label check, and the rules' baseline.
  - **CP2, automatic search.**
  - **CP3, `messages`.**
  - **CP4, `think`, `edit` and `translate`.**
  - **CP5, Auto's coding and reasoning checks.**
  - **CP6, docs and the evaluation report;** merge to `main`.
- Each of CP2–CP5 trains its model, runs the switch-over test, wires the
  model in, deletes the replaced regexes, and adds its score tests.
- Then F29 resumes: CP1's unfinished review, merging `main` into its branch,
  and the weather/places/web model.

## Out of scope

- Weather/places/web routing (F29, after F31).
- `LocationIntent.needsLocation`, which stays all rules.
- Auto's "search the web" check (`requiresWebSearch`).
- The Messages follow-up cue.
- Pulling details out of a draft (who to text, which city) beyond what the
  rules do today.
- Languages other than English.
- Changing any setting or default.
- Learning from the person's use: there are no usage logs, and nothing is
  trained on the Mac.

## Open questions for CP0

1. **BERT assets.** Does a text classifier trained with
   `.transferLearning(.bertEmbedding, …)` predict on a fresh Mac and on the
   `macos-26` GitHub Actions runner without downloading assets
   (`NLContextualEmbedding`)? If not, only the maximum-entropy type is used.
2. **Speed.** Per-prediction time of each type on Apple silicon, and on the
   CI runner, for the 5 ms and 20 ms limits.
3. **Xcode.** Do committed `.mlmodel` files compile with class generation off
   and pass `scripts/verify-xcode.sh build`, `test` and `analyze`, and can
   `IntentModels` load them from the app bundle in the test host?
4. **Reproducible cleanup.** Can `IntentText.swift` be compiled by both the
   app and the training script with no other app files?
