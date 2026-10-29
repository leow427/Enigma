# F30 agent workflow

F30 is built one checkpoint at a time, on the branch
`feat/f30-native-cloud-search`. Each checkpoint goes through the same steps:

1. The owner starts a fresh chat with a worker, using the prompt in
   [Starting a checkpoint](#starting-a-checkpoint).
2. The worker builds it from its brief.
3. The worker starts a fresh reviewer agent to audit it.
4. The worker fixes what the reviewer found. Rounds repeat, with a new
   reviewer each time, until a round finds no Blocker or Should fix, for
   at most three rounds.
5. The worker verifies the result and commits it in one commit, together
   with its row in the progress log in the [plan](../2026-10-27-f30-native-cloud-search.md).

There is no coordinator: the owner talks to the worker directly. Checkpoints
never run in parallel, and each one gets its own chat.

**Before you start, read:**

1. `AGENTS.md`;
2. the [spec](../../specs/2026-10-27-f30-native-cloud-search-design.md), in
   full;
3. the plan's Global Constraints, Review Focus and Interface map;
4. your brief;
5. the Hand-off sections of every earlier brief.

## Roles

**Owner:** starts one worker chat per checkpoint, answers the worker's
questions, and makes every decision the brief marks for the owner.

**Worker:** the chat the owner starts (Opus, medium effort). It:

- sets up the worktree if it doesn't exist yet, which is CP0's job: the
  branch `feat/f30-native-cloud-search` from `main`, in a folder
  outside `~/Documents`. Test hosts that run inside `~/Documents` set off
  macOS privacy prompts.
- builds exactly one checkpoint, test-first, in the order its brief gives;
- runs the brief's exit checks;
- fills in the brief's Hand-off section;
- gets the owner's approval for live runs, and hands owner-run commands to
  the owner;
- starts a fresh reviewer for each review round (at most three), and fixes
  its findings;
- commits the checkpoint and its progress-log row in one commit, and pushes
  the branch.

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
- **Find code by its symbol.** F32 rewrote the cloud and local tool
  paths; briefs name symbols, not lines. F32's names are in its spec and its
  briefs' Hand-offs.

**Tests:**

- **Test first.** Write each task's failing tests, run them and watch them
  fail, implement, then run them and watch them pass. The brief names the
  tests and their key assertions. Add more where they help.
- **Keep tests honest.**
  - Never delete, disable, skip or weaken a test.
  - When a test must change because behavior changed on purpose (for example
    the provider set gains a provider), keep what it checks and point it at
    the new behavior. Say so in your Hand-off.
  - Tests stay offline and deterministic: fakes for the network and for
    processes, `UserDefaults(suiteName:)` for preferences.

**Accounts and keys:**

- **Never handle API keys.** A probe or test that needs one reads it from
  an environment variable. Ask the owner to run it.
- **Don't run subscription probes on your own.** ChatGPT and Claude Code
  probes use the Mac's sign-ins. Run them only after the owner approves
  that batch in the chat.
- **Never commit raw recordings.** Only scrubbed fixtures go in the
  repository.

**Product rules:**

- **No new dependencies.** No Swift packages, binary frameworks or Python
  packages. Scripts use the Python standard library only.
- **Privacy and fallbacks.**
  - Keep the existing sign-in, consent and error paths, and test their
    failure paths.
  - Never log a query, a URL, page text or answer text.
  - Never write search data to disk.
  - Never add a location field to a provider request.
- **Copy and UI.**
  - Use the exact strings in the spec.
  - Follow `docs/design/UI-Style.md`.
  - Reuse `EnigmaControls.swift` rather than making local copies.

## Project mechanics

- **Registering a new Swift file.** The Xcode project has no synchronized
  groups. Follow the convention newer files use: see
  `EnigmaTests/ComposerIntentTests.swift` in
  `Enigma.xcodeproj/project.pbxproj`. Each file needs four entries:
  1. a `PBXBuildFile`;
  2. a `PBXFileReference` with `path = "Enigma/Cloud/<File>.swift"` (or
     `"EnigmaTests/<File>.swift"`) and `sourceTree = SOURCE_ROOT`;
  3. a child entry in the main group `A70000000000000000000001`;
  4. an entry in the Sources phase: `A80000000000000000000001` for the app
     target, `A80000000000000000000002` for `EnigmaTests`.

  Use new, unique 24-character hex IDs, and check the result with
  `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Test fixtures.** The test target has no resources phase, so fixtures
  live in `EnigmaTests/Fixtures/CloudSearch/`. They're read through
  `#filePath`, by `CloudSearchFixture` (CP1):

  ```swift
  URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/CloudSearch/<name>")
  ```

- **Scrubbing fixtures.** Before a recording is saved, replace these with
  placeholders:
  - account, user, organization and project IDs, and email addresses;
  - request IDs and response IDs;
  - Codex thread and turn IDs, which become `thread-one` and `turn-one` to
    match `MockCodexTransport`;
  - Claude Code session IDs;
  - `encrypted_content`, `encrypted_index` and `signature` values, which
    become `REDACTED`;
  - any location, IP address or username.

  The questions are the fixed public questions in the briefs.
  `EnigmaTests/Fixtures/CloudSearch/README.md` has one line per file:
  source, date, question, what was scrubbed, and whether it's recorded or
  synthetic.
- **Verifying.** Run these from the worktree, and save logs outside the
  repository:

  ```sh
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>   # while iterating and in review
  scripts/verify-xcode.sh build
  scripts/verify-xcode.sh test                                      # once, before the commit
  scripts/verify-xcode.sh analyze
  python3 -I -B -m unittest discover -s scripts/tests               # when scripts change
  ```

  Report the build result, the test counts (executed, skipped, failed) and
  the analyzer result. While building and between review rounds, run only
  the checkpoint's test classes and the classes its changes touch: the full
  suite's hosted UI tests take over the screen and keyboard focus
  (`AGENTS.md`). The worker runs the full `test` once per checkpoint, right
  before the commit.
- **CI.** CI runs on the branch's draft pull request. The first checkpoint
  that pushes code opens it (`gh pr create --draft`) and turns on Auto-fix
  for it. After each push, check the result; a failure the checkpoint
  caused is fixed, tested and pushed before the next checkpoint starts. CI
  runs Xcode 26.6, and a local Mac may run a newer one.
- **Unreliable failures.** If key-window UI tests fail with "Timed out
  waiting for … key window" during a full run, another checkout's tests are
  probably running at the same time. Rerun those tests alone before calling
  them broken.
- **Opt-in network tests.** These variables reach the test host with the
  `TEST_RUNNER_` prefix removed, as in `docs/Testing.md`. Without them, these
  tests skip.

  | Set | Test host sees | Purpose |
  | --- | --- | --- |
  | `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1` | `ENIGMA_NATIVE_SEARCH_LIVE` | Live checks, CP2–CP5 |
  | `TEST_RUNNER_ENIGMA_OPENAI_KEY=<key>` | `ENIGMA_OPENAI_KEY` | OpenAI live check and evaluation; set by the owner |
  | `TEST_RUNNER_ENIGMA_ANTHROPIC_KEY=<key>` | `ENIGMA_ANTHROPIC_KEY` | Anthropic live check and evaluation; set by the owner |
  | `TEST_RUNNER_ENIGMA_OPENAI_MODEL`, `TEST_RUNNER_ENIGMA_ANTHROPIC_MODEL` | `ENIGMA_OPENAI_MODEL`, `ENIGMA_ANTHROPIC_MODEL` | Optional model overrides; defaults in the briefs |
  | `TEST_RUNNER_ENIGMA_SEARCH_EVAL=<folder>` | `ENIGMA_SEARCH_EVAL` | The CP6 comparison (F29 reuses it) |

  ChatGPT and Claude Code live tests use the app's runtimes and the Mac's
  sign-ins, as the app does.
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
   relevant; live checks, with who ran them.
5. **Limitations:** anything unfinished, unverified or risky, including
   anything that needs the signed app, an account, or a person to check.
6. **For the next checkpoint:** names, quirks and facts the next worker
   needs, especially where the code differs from the Interface map.

## Rules for reviewers

Follow `docs/reviewer.md`, and these rules:

- **Don't edit files or touch git state.** Read, run commands, and report.
- **Scope:** the checkpoint's changes. That's `git diff` against the
  previous checkpoint's commit, plus every new untracked file.
- **Check, in this order:**
  1. **Correctness:** bugs, crashes, retain cycles, main-actor and
     concurrency mistakes, cancellation that doesn't propagate, streams
     that never finish, a fallback that runs twice.
  2. **Privacy and security,** against spec §5:
     - no location field in any provider request;
     - provider search only on the web route, with no source material;
     - Claude Code's `WebFetch` stays off;
     - no query, URL or answer text in logs;
     - no key in any file, log or fixture;
     - fixtures scrubbed per the workflow.
  3. **Spec values:** limits, tool versions, exact copy.
  4. **The brief:** every task and exit criterion is done.
  5. **Tests:** they're meaningful, deterministic and offline, and none was
     weakened. Mutation-test the key assertions in a scratch copy
     (`rsync -a --exclude .git <worktree>/ <scratch>/`): break the code, and
     confirm a test fails.
  6. **The Xcode project:** files are registered in the right targets.
     `plutil -lint` passes.
  7. **No unrelated changes:** no stray files, private paths, credentials or
     attribution lines.
- **Run** the checkpoint's test classes and the classes its changes touch
  (`-only-testing:`), not the full suite (`AGENTS.md`). Run
  `build` and `analyze` if you doubt the worker's results. Never run a live
  test or probe yourself.
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
> `docs/superpowers/plans/2026-10-27-f30-native-cloud-search/agent-workflow.md`,
> then `cp<N>-<name>.md` in the same folder, and build checkpoint CP<N> in
> the worktree at `<path>`.

## Worker checklist (each checkpoint)

1. Read everything under "Before you start". For CP0, create the worktree
   first.
2. Build the checkpoint, run its exit checks, and fill in the Hand-off.
   When the brief needs a live run, get the owner's approval first, with an
   estimate of the searches. Hand owner-run commands to the owner, and wait
   for their output.
3. Start a fresh reviewer agent with the Agent tool, passing
   `model: "opus"` and `effort: "xhigh"`. Give it the
   workflow file, the brief, `docs/reviewer.md`, and the base commit to diff
   against. Don't add your own account of the changes; it reads the code.
4. Fix every Blocker and Should fix. Start a new reviewer for each round,
   until a round has neither, for at most three rounds. If the third round
   still finds one, fix what you can, then stop and ask the owner before
   committing. Ask the owner about any finding you think is wrong rather
   than skipping it. If a round's only finding is one small Should fix, fix
   it and test it yourself; it needs no further round (owner rule).
5. Rerun the brief's exit checks, with the full `test` once. Read the whole
   diff. Check `git status`
   for strays, and check the Hand-off and the fixtures for private data.
6. Update your row in the plan's progress log: status, review rounds and
   one-line notes.
7. Make one commit, `<summary> (F30 CP<N>)` on `feat/f30-native-cloud-search`, with the
   checkpoint's changes, the filled-in brief and the progress log. No
   attribution lines. Push the branch, and check its CI result (see CI).
8. End with a short report to the owner: the commit hash, the review rounds, and
   anything marked for the owner. The next checkpoint starts in a new chat.
