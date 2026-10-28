# F31 agent workflow

F31 is built one checkpoint at a time, on the branch
`feat/f31-intent-models`. Each checkpoint goes through the same steps:

1. The owner starts a fresh chat with a worker, using the prompt in
   [Starting a checkpoint](#starting-a-checkpoint).
2. The worker builds it from its brief.
3. The worker starts a fresh reviewer agent to audit it.
4. The worker fixes what the reviewer found. Rounds repeat, with a new
   reviewer each time, until a round finds no Blocker or Should fix, for
   at most three rounds.
5. The worker verifies the result and commits it in one commit, together
   with its row in the progress log in the [plan](../2026-10-27-f31-intent-models.md).

There is no coordinator: the owner talks to the worker directly. Checkpoints
never run in parallel, and each one gets its own chat.

**Before you start, read:**

1. `AGENTS.md`;
2. the [spec](../../specs/2026-10-27-f31-intent-models-design.md), in full;
3. the plan's Global Constraints, Review Focus and Interface map;
4. your brief;
5. the Hand-off sections of every earlier brief.

## Roles

**Owner:** starts one worker chat per checkpoint, answers the worker's
questions, does CP1's spot-check, and makes every decision the brief marks
for the owner.

**Worker:** the chat the owner starts (Opus, medium effort). It:

- sets up the worktree if it doesn't exist yet, which is CP0's job: the
  branch `feat/f31-intent-models` from `main`, in a folder outside
  `~/Documents`. Test hosts that run inside `~/Documents` set off macOS
  privacy prompts.
- builds exactly one checkpoint, test-first, in the order its brief gives;
- runs the brief's exit checks;
- fills in the brief's Hand-off section;
- starts a fresh reviewer for each review round (at most three), and fixes
  its findings;
- commits the checkpoint and its progress-log row in one commit, pushes the
  branch, and checks the draft pull request's CI run.

**Test-set writer (CP1 only):** an agent the CP1 worker starts with the Agent
tool, using the brief in CP1. It writes the held-out test sets and nothing
else.

**Reviewer:** an agent the worker starts with the Agent tool, set to
`model: "opus"` and `effort: "xhigh"`. Both settings are required. It
audits the worker's changes, never edits a file, and reports findings to the
worker.

## Rules for workers

**Git and scope:**

- **Commit only at the end.** Commit the checkpoint after its last review
  round, as the [checklist](#worker-checklist-each-checkpoint) says. No
  other commits, and no `git stash`, `checkout`, `reset`, `clean` or
  `rebase`.
- **Stay in scope.** Make only your brief's changes, plus whatever they
  strictly need. List anything outside the brief in your Hand-off, with the
  reason.
- **Follow the brief and the spec.** When they disagree, or the code no
  longer matches what the brief says exists, stop and ask the owner.
  Don't improvise a different design. Never edit the spec or another
  checkpoint's brief; propose changes in your Hand-off instead.
- **Find code by symbol,** not by line number. Line numbers in briefs are
  from `main` on 2026-10-27.

**Tests:**

- **Test first.** Write each task's failing tests, run them and watch them
  fail, implement, then run them and watch them pass. The brief names the
  tests and their key assertions. Add more where they help.
- **Keep tests honest.**
  - Never delete, disable, skip or weaken a test, except the
    `ComposerIntentPhrasingTests` methods CP2–CP4 name. Those are replaced
    under the owner's approval in the spec.
  - Every other existing test must still pass after a skill switches. Fix a
    failing phrasing with more training examples first, then a pin. Never
    edit the test. If a skill would need more than 20 pins, stop and ask
    the owner.
  - Tests stay offline and deterministic.

**Models and examples:**

- **Retrain only with the script.** `scripts/train-intent-models.sh` is the
  only way a model in `Enigma/Resources/IntentModels/` changes. Never edit a
  model by hand, and always commit a model together with the training file
  it was trained from.
- **Don't tune to the test set.** Cut-offs and model types come from the
  validation share of the training file. Don't read a skill's `test.jsonl`
  while writing or changing its training examples, except to run the score
  tests. When a test example fails, don't copy it or a paraphrase of it into
  the training file.
- **Examples are invented.** No real people's contact details, phone
  numbers, addresses, account names, or anything taken from this Mac.

**Product rules:**

- **No new dependencies.** No Swift packages, binary frameworks or Python
  packages.
- **Privacy.**
  - Keep every rule in spec §2's "Stays as rules" column, and test it.
  - Never log draft text, example text, or a draft's probabilities.
- **No visible change.** No UI, setting, default or copy changes, except the
  docs in CP6.

## Project mechanics

- **Registering a new Swift file.** The Xcode project has no synchronized
  groups. Follow the convention newer files use: see
  `EnigmaTests/ComposerIntentTests.swift` in
  `Enigma.xcodeproj/project.pbxproj`. Each file needs four entries:
  1. a `PBXBuildFile`;
  2. a `PBXFileReference` with `path = "Enigma/Intent/<File>.swift"` (or
     `"EnigmaTests/<File>.swift"`, or `"IntentTraining/<File>.swift"`) and
     `sourceTree = SOURCE_ROOT`;
  3. a child entry in the main group `A70000000000000000000001`;
  4. an entry in the Sources phase: `A80000000000000000000001` for the app
     target, `A80000000000000000000002` for `EnigmaTests`.

  `IntentTraining/IntentTrainingSupport.swift` goes in the `EnigmaTests`
  Sources phase only, never the app's. Use new, unique 24-character hex IDs,
  and check the result with `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Registering a model.** A `.mlmodel` goes in the app target's Sources
  phase (`A80000000000000000000001`), with `lastKnownFileType =
  file.mlmodel`. Xcode compiles it into `<Name>.mlmodelc` in the app bundle.
  The project sets `COREML_CODEGEN_LANGUAGE = None` (CP0), so no Swift class
  is generated.
- **Reading example files in tests.** Through `#filePath`, by the
  `IntentExamples` helper (CP1):

  ```swift
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "IntentTraining/<skill>/<file>.jsonl")
  ```

- **Training.** From the worktree:

  ```sh
  scripts/train-intent-models.sh <skill>...      # writes models and IntentTraining/<skill>/report.json
  ```

  The script prints each model's type, cut-off, validation accuracy, share
  of wrong yeses and p95 time. It exits non-zero, writing nothing, on an
  overlap, a missing cut-off, or a speed limit missed.
- **Verifying.** Run these from the worktree, and save logs outside the
  repository:

  ```sh
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>   # while iterating
  scripts/verify-xcode.sh build
  scripts/verify-xcode.sh test
  scripts/verify-xcode.sh analyze
  ```

  Report the build result, the test counts (executed, skipped, failed) and
  the analyzer result.
- **The score report.** `IntentScoreTests.testWriteScoreReport` writes each
  skill's end-to-end scores when the test host sees `ENIGMA_INTENT_REPORT`:

  ```sh
  TEST_RUNNER_ENIGMA_INTENT_REPORT=<folder outside the repo> \
    scripts/verify-xcode.sh test -only-testing:EnigmaTests/IntentScoreTests
  ```

  Without the variable, that test skips.
- **CI.** CI runs on pull requests. CP0 opens a draft pull request from
  `feat/f31-intent-models` to `main`, after the owner approves it in the
  chat. Every checkpoint's push runs CI on it. A commit can't contain its
  own CI result, so the worker reports it to the owner, and the next
  checkpoint's worker records it in its Hand-off. Read results with
  `gh pr checks`; never re-run or cancel a run.
- **A CI failure after the commit.** If the run fails because of the
  checkpoint (not a known unreliable UI test), the same worker fixes it in
  one follow-up commit, `Fix CI after F31 CP<N>`, after one review round of
  the fix. That is the only extra commit allowed.
- **Unreliable failures.** If key-window UI tests fail with "Timed out
  waiting for … key window" during a full run, another checkout's tests are
  probably running at the same time. Rerun those tests alone before calling
  them broken.
- **Shared app preferences.** The test host shares `Enigma.app`'s user
  defaults. Never read or write `UserDefaults.standard` in a test, and keep
  new `.shared` singletons inert when `TestHost.isActive` if they touch
  defaults. `IntentModels.shared` only reads the bundle.

## Hand-off

Fill in your brief's **Hand-off** section before the first review, and keep
it current through the fixes. It goes into the commit, and the next
checkpoint's worker reads it:

1. **Summary:** what you built, in a few sentences.
2. **Files:** every file added, changed or removed, with one line each on
   why.
3. **Decisions:** choices the brief left open, and any departure from the
   brief or spec, with the reason.
4. **Verification:** the exact commands you ran and their results: build;
   test counts (executed, skipped, failed); analyzer; training output; the
   score report; the CI run.
5. **Limitations:** anything unfinished, unverified or risky.
6. **For the next checkpoint:** names, quirks and facts the next worker
   needs, especially where the code differs from the Interface map.

## Rules for reviewers

Follow `docs/reviewer.md`, and these rules:

- **Don't edit files or touch git state.** Read, run commands, and report.
- **Scope:** the checkpoint's changes. That's `git diff` against the
  previous checkpoint's commit, plus every new untracked file.
- **Check, in this order:**
  1. **Correctness:** bugs, crashes, main-actor and concurrency mistakes,
     a model loaded more than once, a lock held while calling out, text
     cleaned differently in the app and the script.
  2. **Privacy,** against spec §5:
     - every "Stays as rules" check in spec §2 still runs before the model;
     - models read only the cleaned typed draft;
     - no draft or example text in logs;
     - example files contain only invented wording.
  3. **Spec values:** the Values table in the plan, the lean of each skill,
     and the switch-over test.
  4. **The brief:** every task and exit criterion is done.
  5. **Tests:** they're meaningful, deterministic and offline, and none was
     weakened beyond the named `ComposerIntentPhrasingTests` methods.
     Mutation-test the key assertions in a scratch copy
     (`rsync -a --exclude .git <worktree>/ <scratch>/`): break the code, and
     confirm a test fails.
  6. **Examples:** spot-check 30 training examples per changed skill for
     wrong labels and for paraphrases of test examples. Check pin counts.
  7. **The Xcode project:** files and models are registered in the right
     targets. `plutil -lint` passes.
  8. **No unrelated changes:** no stray files, private paths, credentials or
     attribution lines.
- **Run** at least the checkpoint's tests and the full `test` action. Run
  `build` and `analyze` if you doubt the worker's results. Never retrain a
  model; reason from the committed models and reports.
- **Processes:** never use a broad `pkill -f`. Kill only by PID.
- **Report** findings ranked from most to least severe. Mark each one
  **Blocker** or **Should fix**, and give:
  - the file and line;
  - what's wrong;
  - a concrete failure scenario;
  - a suggested fix.

  Report nothing else: no nits, style preferences or polish that wouldn't
  change behavior, correctness or maintainability. If nothing needs fixing,
  say so plainly.

## Starting a checkpoint

The owner starts a new chat (Opus, medium effort) in the repository and
sends:

> Read
> `docs/superpowers/plans/2026-10-27-f31-intent-models/agent-workflow.md`,
> then `cp<N>-<name>.md` in the same folder, and build checkpoint CP<N> in
> the worktree at `<path>`.

For CP0, `<path>` is where the worker should create the worktree.

## Worker checklist (each checkpoint)

1. Read everything under "Before you start". For CP0, create the worktree
   first.
2. Build the checkpoint, run its exit checks, and fill in the Hand-off.
3. Start a fresh reviewer agent with the Agent tool, passing
   `model: "opus"` and `effort: "xhigh"`. Give it the workflow file, the
   brief, `docs/reviewer.md`, and the base commit to diff against. Don't add
   your own account of the changes; it reads the code.
4. Fix every Blocker and Should fix. Start a new reviewer for each round,
   until a round has neither, for at most three rounds. If the third round
   still finds one, fix what you can, then stop and ask the owner before
   committing. Ask the owner about any finding you think is wrong rather
   than skipping it.
5. Rerun the brief's exit checks. Read the whole diff. Check `git status`
   for strays, and check the Hand-off and the example files for private
   data.
6. Update your row in the plan's progress log: status, review rounds and
   one-line notes.
7. Make one commit, `<summary> (F31 CP<N>)` on `feat/f31-intent-models`,
   with the checkpoint's changes, the filled-in brief and the progress log.
   No attribution lines. Push the branch, and wait for the draft pull
   request's CI run. Fix a failure the checkpoint caused as "CI" in
   Project mechanics says.
8. End with a short report to the owner: the commit hash, the review
   rounds, the CI result, and anything marked for the owner. The next
   checkpoint starts in a new chat.
