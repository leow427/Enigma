# Agent workflow

Every code change in this repository is built one checkpoint at a time, each
in its own worker chat. A feature with a plan has several checkpoints, each
with a brief in the plan's folder; a small to-do item is one checkpoint, and
its plan doubles as its brief. Specs and plans themselves skip this loop: the
owner reviews them.

Each checkpoint goes through the same steps:

1. The owner starts a fresh worker chat (Opus, medium effort), using the
   prompt in [Starting a checkpoint](#starting-a-checkpoint). The worker
   builds that one checkpoint from its brief, writing tests first.
2. The worker starts a fresh reviewer (Opus, extra-high effort; both
   settings are required).
3. The worker fixes what the reviewer found, then decides whether another
   round is needed:
   - Round 2 runs unless round 1 found only small fixes. Small means a
     wording change, a missing test or a one-line correction, which the
     worker fixes and checks itself.
   - Round 3 runs only if round 2 still found real issues.
   - No round 4. If round 3 still finds a Blocker, fix what you can, then
     stop and ask the owner before committing.
4. The worker verifies, commits once and pushes. The commit holds the code,
   the filled-in brief and the progress-log row.

There is no coordinator: the owner talks to the worker directly. Checkpoints
never run in parallel, and each one gets its own chat.

**Before you start, read:**

1. `AGENTS.md`;
2. the feature's spec in `docs/superpowers/specs/`, in full, if it has one;
3. the plan in `docs/superpowers/plans/`: its global constraints, review
   focus and interface map, where it has them;
4. your brief;
5. the Hand-off sections of every earlier brief;
6. the feature's own `agent-workflow.md` in the plan's folder, if there is
   one. Its feature-specific rules add to this file.

## Roles

**Owner:** starts one worker chat per checkpoint, answers the worker's
questions, and makes every decision the brief marks for the owner.

**Worker:** the chat the owner starts (Opus, medium effort). It:

- sets up the worktree if it doesn't exist yet (the first checkpoint's job):
  the branch `feat/<id>-<name>` from `main`, in a folder outside
  `~/Documents`. Test hosts that run inside `~/Documents` set off macOS
  privacy prompts;
- builds exactly one checkpoint, test-first, in the order its brief gives;
- runs the brief's exit checks;
- fills in the brief's Hand-off section;
- starts a fresh reviewer for each review round (at most three), and fixes
  its findings;
- commits the checkpoint and its progress-log row in one commit, and pushes
  the branch.

**Reviewer:** an agent the worker starts with the Agent tool, set to
`model: "opus"` and `effort: "xhigh"`, in every round, even if the worker
runs on a cheaper model. It audits the worker's changes, never edits a file,
and reports findings to the worker. Never trim a review to save usage; its
size follows what it finds.

## Rules for workers

**Git and scope:**

- One commit, at the end, after the last review round. No `git stash`,
  `checkout`, `reset`, `clean` or `rebase`.
- Stay inside the brief, plus whatever it strictly needs. List anything
  extra in the Hand-off, with the reason.
- **Brief vs. spec:** if they disagree, or the code no longer matches the
  brief, stop and ask the owner. Don't improvise a different design. Never
  edit the spec or another checkpoint's brief; propose changes in the
  Hand-off.

**Tests:**

- **Test first:** write each task's failing test, watch it fail, implement,
  then watch it pass.
- Never delete, skip or weaken a test. When a test must change because
  behavior changed on purpose, keep what it checks, point it at the new
  behavior, and say so in the Hand-off.
- Tests stay offline and deterministic: fakes for the network, a fake clock
  for time, `UserDefaults(suiteName:)` for preferences.

**Product:**

- No new dependencies: no Swift packages, binary frameworks or Python
  packages. Scripts use the Python standard library only.
- Keep the existing permission prompts, consent steps and fallback paths,
  and test their failure paths.
- Never log what the user typed or what Enigma read for them: prompts,
  queries, URLs, page, file, screen or message text.
- Write nothing to disk beyond what the spec names.
- Use the spec's exact wording, follow `docs/design/UI-Style.md`, and reuse
  `EnigmaControls.swift` (`EnigmaRow`, `EnigmaStatusLine`, `EnigmaNote`,
  `EnigmaSectionHeader`, `EnigmaHairline` and the button styles) rather
  than making local copies.
- Every control gets a VoiceOver label.

## Project mechanics

- **Registering a new Swift file.** The Xcode project has no synchronized
  groups. Each file needs four entries in
  `Enigma.xcodeproj/project.pbxproj`, following the files added most
  recently:
  1. a `PBXBuildFile`;
  2. a `PBXFileReference` with `path = "Enigma/<Folder>/<File>.swift"` and
     `sourceTree = SOURCE_ROOT`;
  3. a child entry in the main group `A70000000000000000000001`;
  4. an entry in the Sources phase: `A80000000000000000000001` for the app
     target, `A80000000000000000000002` for `EnigmaTests`.

  Use new, unique 24-character hex IDs, and check the result with
  `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Test fixtures.** The test target has no resources phase, so fixtures
  live under `EnigmaTests/Fixtures/` and are read through `#filePath`.
  Fixtures contain no personal data: no IP address, account, location or
  username.
- **Verifying.** Run these from the worktree, and save logs outside the
  repository:

  ```sh
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>   # while working and in review
  scripts/verify-xcode.sh build
  scripts/verify-xcode.sh test                                      # once, right before the commit
  scripts/verify-xcode.sh analyze
  python3 -I -B -m unittest discover -s scripts/tests               # when scripts change
  ```

  While working and between review rounds, run only the checkpoint's test
  classes and the classes its changes touch: the full suite's hosted UI
  tests take over the screen and keyboard focus. Opt-in network and
  real-model tests are described in `docs/Testing.md`.
- **CI.** CI runs on the branch's draft pull request, with Auto-fix on. The
  first checkpoint that pushes code opens it (`gh pr create --draft`). After
  each push, a failure the checkpoint caused is fixed, tested and pushed
  before the next checkpoint starts. CI runs Xcode 26.6, and a local Mac may
  run a newer one.
- **Unreliable failures.** If key-window UI tests fail with "Timed out
  waiting for … key window" during a full run, another checkout's tests are
  probably running at the same time. Rerun those tests alone before calling
  them broken.
- **Shared app preferences.** The test host shares `Enigma.app`'s user
  defaults. Never read or write `UserDefaults.standard` in a test, and keep
  new `.shared` singletons inert when `TestHost.isActive`.

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
   test counts (executed, skipped, failed); analyzer; Python tests where
   relevant.
5. **Limitations:** anything unfinished, unverified or risky, including
   anything that needs the signed app, the network, or a person to check.
6. **For the next checkpoint:** names, quirks and facts the next worker
   needs, especially where the code differs from the plan.

## Rules for reviewers

Follow `docs/reviewer.md`, and these rules:

- **Don't edit files or touch git state.** Read, run commands, and report.
- **Scope:** the diff since the previous checkpoint's commit, plus every new
  untracked file.
- **Check, in this order:**
  1. **Correctness:** bugs, crashes, retain cycles, main-actor and
     concurrency mistakes, cancellation that doesn't propagate, timeouts
     that don't fire.
  2. **Privacy,** against the spec's privacy section, and always:
     - no user content in logs;
     - nothing new written to disk beyond what the spec names;
     - no location or personal data sent where the spec doesn't allow it;
     - where web content is fetched, the guard against reaching
       local-network addresses holds and page scripts never run.
  3. **The spec's exact values and copy.**
  4. **Every task and exit check in the brief.**
  5. **Tests:** meaningful, deterministic and offline, and none weakened.
     Mutation-test the key assertions in a scratch copy
     (`rsync -a --exclude .git <worktree>/ <scratch>/`): break the code, and
     confirm a test fails.
  6. **Xcode project registration:** files are in the right targets, and
     `plutil -lint` passes.
  7. **No stray files,** private paths, credentials or attribution lines.
- **Run** the affected test classes (`-only-testing:`), not the full suite.
  Run `build` and `analyze` if you doubt the worker's results.
- **Processes:** never use a broad `pkill -f`; kill only by PID.
- **Report** only Blocker and Should fix findings, ranked from most to least
  severe, each with the file and line, what's wrong, a concrete failure
  scenario and a suggested fix. No nits. If nothing needs fixing, say so
  plainly.

## Starting a checkpoint

The owner starts a new chat (Opus, medium effort) in the repository and
sends:

> Read `docs/Agent-Workflow.md`, then `<brief>`, and build checkpoint
> CP<N> of <ID> in the worktree at `<path>`.

## Worker checklist (each checkpoint)

1. Read everything under "Before you start". For the first checkpoint,
   create the worktree first.
2. Build the checkpoint, run its exit checks, and fill in the Hand-off.
3. Start a fresh reviewer with the Agent tool, passing `model: "opus"` and
   `effort: "xhigh"`. Give it this workflow, the brief, `docs/reviewer.md`
   and the base commit to diff against, but not your own summary of the
   changes; it reads the code.
4. Fix every Blocker and Should fix, then:
   - After round 1: if every finding was small, fix and test them yourself
     and go to step 5. Otherwise start a new reviewer for round 2.
   - After round 2: if it still finds real issues, fix them and run round 3.
     If its findings are small, fix and test them yourself and go to step 5.
   - After round 3: fix what it found. If a Blocker remains, stop and ask
     the owner before committing.
   - Throughout: ask the owner about any finding you think is wrong rather
     than skipping it. Each round gets a fresh reviewer.
5. Rerun the exit checks, run the full `test` once, read the whole diff, and
   check `git status` and the Hand-off for strays and private data.
6. Update your row in the plan's progress log: status, review rounds and
   one-line notes.
7. Make one commit, `<summary> (<ID> CP<N>)`, with the checkpoint's changes,
   the filled-in brief and the progress-log row. No attribution lines. Push
   the branch, and fix any CI failure the checkpoint caused (see CI).
8. End with a short report to the owner: the commit hash, the review rounds,
   and anything marked for the owner. The next checkpoint starts in a new
   chat.
