# F32 agent workflow

F32 is built one checkpoint at a time, on the branch
`feat/f32-native-tool-calling`. Each checkpoint goes through the same steps:

1. The owner starts a fresh chat with a worker, using the prompt in
   [Starting a checkpoint](#starting-a-checkpoint).
2. The worker builds it from its brief.
3. The worker starts a fresh reviewer agent to audit it.
4. The worker fixes what the reviewer found. Rounds repeat, with a new
   reviewer each time, until a round finds no Blocker or Should fix, for
   at most three rounds.
5. The worker verifies the result and commits it in one commit, together
   with its row in the progress log in the [plan](../2026-10-28-f32-native-tool-calling.md).

There is no coordinator: the owner talks to the worker directly. Checkpoints
never run in parallel, and each one gets its own chat.

**Before you start, read:**

1. `AGENTS.md`;
2. the [spec](../../specs/2026-10-28-f32-native-tool-calling-design.md), in full;
3. the plan's Global Constraints, Review Focus and Interface map;
4. your brief;
5. the Hand-off sections of every earlier brief.

## Roles

**Owner:** starts one worker chat per checkpoint, answers the worker's
questions, approves every batch of live runs, runs the commands that need
API keys, and makes every decision the brief marks for the owner.

**Worker:** the chat the owner starts (Opus, medium effort). It:

- sets up the worktree if it doesn't exist yet, which is CP0's job: the
  branch `feat/f32-native-tool-calling` from `main`, in a folder outside
  `~/Documents`. Test hosts that run inside `~/Documents` set off macOS
  privacy prompts.
- builds exactly one checkpoint, test-first, in the order its brief gives;
- runs the brief's exit checks;
- fills in the brief's Hand-off section;
- gets the owner's approval for live runs, and hands owner-run commands to
  the owner;
- starts a fresh reviewer for each review round (at most three), and fixes
  its findings;
- commits the checkpoint and its progress-log row in one commit, pushes the
  branch, and checks the draft pull request's CI run.

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
  from `main` on 2026-10-28.

**Tests:**

- **Test first.** Write each task's failing tests, run them and watch them
  fail, implement, then run them and watch them pass. The brief names the
  tests and their key assertions. Add more where they help.
- **Keep tests honest.** Never delete, disable, skip or weaken a test.
  Every existing test must still pass, unedited, at every checkpoint. The
  internal switch (`NativeTools.isEnabled`) stays `false` until CP5, so
  today's behavior, and its tests, don't change before then. A test that
  needs the new path turns it on for that test only, through the injection
  point its brief names, never through the static switch.
- **Offline and deterministic.** Provider streams are tested from recorded,
  scrubbed fixtures through a stub transport; `llama-server` through a stub
  server. No test reaches the network or a real model.

**Accounts and keys:**

- **Never handle API keys.** A probe or eval that needs one reads it from an
  environment variable (`TEST_RUNNER_ENIGMA_OPENAI_KEY`,
  `TEST_RUNNER_ENIGMA_ANTHROPIC_KEY`, `TEST_RUNNER_ENIGMA_GEMINI_KEY`). Hand
  the command to the owner, who sets the variable with `read -rs` and runs
  it.
- **Don't run live probes on your own.** Cloud calls, ChatGPT and Claude
  Code subscription probes, and real local models run only after the owner
  approves that batch in the chat, with an estimate of the calls.
- **Never commit raw recordings.** Only scrubbed fixtures go in the
  repository: no keys, account IDs, request IDs, organization names, or
  anything from the owner's Messages.

**Product rules:**

- **No new dependencies.** No Swift packages, binary frameworks or Python
  packages.
- **Privacy.** The spec's Privacy section is the contract. The gates run in
  Swift before a tool executes, and only a click on a card can grant.
  Never log message text, queries after a Messages read, tool arguments or
  tool results.
- **Small models don't change.** Any change to an unflagged route is a bug.

## Project mechanics

- **Registering a new Swift file.** The Xcode project has no synchronized
  groups. Follow the convention newer files use: see
  `EnigmaTests/ComposerIntentTests.swift` in
  `Enigma.xcodeproj/project.pbxproj`. Each file needs four entries:
  1. a `PBXBuildFile`;
  2. a `PBXFileReference` with `path = "Enigma/<Folder>/<File>.swift"` (or
     `"EnigmaTests/<File>.swift"`) and `sourceTree = SOURCE_ROOT`;
  3. a child entry in the main group `A70000000000000000000001`;
  4. an entry in the Sources phase: `A80000000000000000000001` for the app
     target, `A80000000000000000000002` for `EnigmaTests`.

  Use new, unique 24-character hex IDs, and check the result with
  `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Fixtures.** Recorded provider streams live in
  `EnigmaTests/Fixtures/F32/<provider>/<case>.txt` and are read through
  `#filePath` (the test target has no resources phase):

  ```swift
  URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/F32/<provider>/<case>.txt")
  ```

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
- **CI.** CI runs on pull requests. CP0 opens a draft pull request from
  `feat/f32-native-tool-calling` to `main`, after the owner approves it in
  the chat. Every checkpoint's push runs CI on it. A commit can't contain its
  own CI result, so the worker reports it to the owner, and the next
  checkpoint's worker records it in its Hand-off. Read results with
  `gh pr checks`; never re-run or cancel a run.
- **A CI failure after the commit.** If the run fails because of the
  checkpoint (not a known unreliable UI test), the same worker fixes it in
  one follow-up commit, `Fix CI after F32 CP<N>`, after one review round of
  the fix. That is the only extra commit allowed.
- **Unreliable failures.** If key-window UI tests fail with "Timed out
  waiting for … key window" during a full run, another checkout's tests are
  probably running at the same time. Rerun those tests alone before calling
  them broken. `testSendNowDuringAPendingSend…` is known to fail under load
  and pass alone.
- **Shared app preferences.** The test host shares `Enigma.app`'s user
  defaults. Never read or write `UserDefaults.standard` in a test; inject a
  suite (`UserDefaults(suiteName:)`, removed in `tearDown`). Keep new
  `.shared` singletons inert when `TestHost.isActive` if they touch defaults.
- **Interactive checks.** Don't use the helper's unsigned build for
  interactive Messages or Screen testing (`AGENTS.md`); ask the owner to run
  the app from Xcode or `scripts/install-app.sh`.

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
   test counts (executed, skipped, failed); analyzer; live runs the owner
   approved and their results; the CI run.
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
     continuations resumed twice or never, a stream that leaks a task after
     cancellation, a half-built tool call that runs.
  2. **Privacy,** against the spec's Privacy section:
     - no message text reaches a model, and no web query leaves after a
       Messages read, without the matching grant;
     - nothing but a click on a card can create a grant;
     - no message text, tool arguments or results in logs;
     - fixtures are scrubbed.
  3. **Small models unchanged:** unflagged routes behave exactly as on
     `main`, and the switch stays off before CP5.
  4. **The brief:** every task and exit criterion is done.
  5. **Tests:** they're meaningful, deterministic and offline, and none was
     weakened. Mutation-test the key assertions in a scratch copy
     (`rsync -a --exclude .git <worktree>/ <scratch>/`): break the code, and
     confirm a test fails.
  6. **The Xcode project:** files are registered in the right targets.
     `plutil -lint` passes.
  7. **No unrelated changes:** no stray files, private paths, credentials or
     attribution lines.
- **Run** at least the checkpoint's tests and the full `test` action. Run
  `build` and `analyze` if you doubt the worker's results. Never run a live
  probe.
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
> `docs/superpowers/plans/2026-10-28-f32-native-tool-calling/agent-workflow.md`,
> then `cp<N>-<name>.md` in the same folder, and build checkpoint CP<N> in
> the worktree at `<path>`.

For CP0, `<path>` is where the worker should create the worktree.

## Worker checklist (each checkpoint)

1. Read everything under "Before you start". For CP0, create the worktree
   first.
2. Build the checkpoint, run its exit checks, and fill in the Hand-off.
   When the brief needs a live run, get the owner's approval first, with an
   estimate of the calls. Hand owner-run commands to the owner, and wait
   for their output.
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
   for strays, and check the Hand-off and the fixtures for private data.
6. Update your row in the plan's progress log: status, review rounds and
   one-line notes.
7. Make one commit, `<summary> (F32 CP<N>)` on
   `feat/f32-native-tool-calling`, with the checkpoint's changes, the
   filled-in brief and the progress log. No attribution lines. Push the
   branch, and wait for the draft pull request's CI run. Fix a failure the
   checkpoint caused as "CI" in Project mechanics says.
8. End with a short report to the owner: the commit hash, the review
   rounds, the CI result, and anything marked for the owner. The next
   checkpoint starts in a new chat.
