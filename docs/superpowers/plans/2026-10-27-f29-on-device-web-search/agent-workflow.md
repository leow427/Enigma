# F29 agent workflow

F29 is built one checkpoint at a time, on the branch
`feat/f29-on-device-search`. Each checkpoint goes through the same steps:

1. The owner starts a fresh chat with a worker, using the prompt in
   [Starting a checkpoint](#starting-a-checkpoint).
2. The worker builds it from its brief.
3. The worker starts a fresh reviewer agent to audit it.
4. The worker fixes what the reviewer found. Rounds repeat, with a new
   reviewer each time, until a round finds no Blocker or Should fix.
5. The worker verifies the result, commits it, pushes the branch, and
   updates the progress log in the [plan](../2026-10-27-f29-on-device-web-search.md).

There is no coordinator: the owner talks to the worker directly. Checkpoints
never run in parallel, and each one gets its own chat.

**Before you start, read:**

1. `AGENTS.md`;
2. the [spec](../../specs/2026-10-27-f29-on-device-web-search-design.md), in
   full;
3. the plan's Global Constraints, Review Focus and Interface map;
4. your brief;
5. the Hand-off sections of every earlier brief.

## Roles

**Owner:** starts one worker chat per checkpoint, answers the worker's
questions, and makes every decision the brief marks for the owner.

**Worker:** the chat the owner starts (Opus, medium effort). It:

- sets up the worktree if it doesn't exist yet, which is CP0's job: the
  branch `feat/f29-on-device-search` from `main`, in a folder outside
  `~/Documents`. Test hosts that run inside `~/Documents` set off macOS privacy prompts.
- builds exactly one checkpoint, test-first, in the order its brief gives;
- runs the brief's exit checks;
- fills in the brief's Hand-off section;
- starts a fresh reviewer for each review round, and fixes its findings;
- commits the checkpoint, pushes the branch, and updates the progress log.

**Reviewer:** an agent the worker starts (Opus, extra high effort). It
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

**Tests:**

- **Test first.** Write each task's failing tests, run them and watch them
  fail, implement, then run them and watch them pass. The brief names the
  tests and their key assertions. Add more where they help.
- **Keep tests honest.**
  - Never delete, disable, skip or weaken a test.
  - When a test must change because behavior changed on purpose (for example
    `/search` no longer needs a key), keep what it checks and point it at the
    new behavior. Say so in your Hand-off.
  - Tests stay offline and deterministic: fakes for the network, a fake
    clock for time, `UserDefaults(suiteName:)` for preferences.

**Product rules:**

- **No new dependencies.** No Swift packages, binary frameworks or Python
  packages. Scripts use the Python standard library only.
- **Privacy and fallbacks.**
  - Keep the existing permission prompts, consent steps and error paths, and
    test their failure paths.
  - Never log a query, a URL or page text.
  - Never write search data to disk, except the blocked-sites preference.
- **Copy and UI.**
  - Use the exact strings in the spec.
  - Follow `docs/design/UI-Style.md`.
  - Reuse `EnigmaControls.swift` (`EnigmaRow`, `EnigmaStatusLine`,
    `EnigmaNote`, `EnigmaSectionHeader`, `EnigmaHairline` and the button
    styles) rather than making local copies.
  - Every control gets a VoiceOver label.

## Project mechanics

- **Registering a new Swift file.** The Xcode project has no synchronized
  groups. Use the convention newer files already follow (see
  `WebSearchSettingsSection.swift`). Each file needs four entries in
  `Enigma.xcodeproj/project.pbxproj`:
  1. a `PBXBuildFile`;
  2. a `PBXFileReference` with `path = "Enigma/Search/<File>.swift"` and
     `sourceTree = SOURCE_ROOT`;
  3. a child entry in the main group `A70000000000000000000001`;
  4. an entry in the Sources phase: `A80000000000000000000001` for the app
     target, `A80000000000000000000002` for `EnigmaTests`.

  Use new, unique 24-character hex IDs, and check the result with
  `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Bundled data.** `Enigma/Resources/SearchData/` is one folder reference,
  modelled on `docs/release-notes`: a `PBXFileReference` with
  `lastKnownFileType = folder`, plus an entry in the Resources phase
  `A90000000000000000000001`. Files added inside it later need no project
  edits. At runtime it's
  `Bundle.main.url(forResource: "SearchData", withExtension: nil)`.
- **Test fixtures.** The test target has no resources phase, so fixtures
  live in `EnigmaTests/Fixtures/Search/` and are read through `#filePath`:

  ```swift
  URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/Search/<name>")
  ```

  Fixtures must contain no personal data: no IP address, account, location
  or username.
- **Verifying.** Run these from the worktree, and save logs outside the
  repository:

  ```sh
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>   # while iterating
  scripts/verify-xcode.sh build
  scripts/verify-xcode.sh test
  scripts/verify-xcode.sh analyze
  python3 -I -B -m unittest discover -s scripts/tests               # when scripts change
  ```

  Report the build result, the test counts (executed, skipped, failed) and
  the analyzer result.
- **Unreliable failures.** If key-window UI tests fail with "Timed out
  waiting for … key window" during a full run, another checkout's tests are
  probably running at the same time. Rerun those tests alone before calling
  them broken.
- **Opt-in network tests.** These variables reach the test host with the
  `TEST_RUNNER_` prefix removed, as in `docs/Testing.md`:

  | Set | Test host sees | Purpose |
  | --- | --- | --- |
  | `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1` | `ENIGMA_LIVE_SEARCH` | Live checks, from CP2 |
  | `TEST_RUNNER_ENIGMA_SEARCH_FIXTURE_DIR=<folder>` | `ENIGMA_SEARCH_FIXTURE_DIR` | Fixture capture |
  | `TEST_RUNNER_ENIGMA_SEARCH_EVAL=<folder>` | `ENIGMA_SEARCH_EVAL` | Evaluation, CP7 |

  Without them, these tests skip.
- **Shared app preferences.** The test host shares `Enigma.app`'s user
  defaults. Never read or write `UserDefaults.standard` in a test, and keep
  new `.shared` singletons inert when `TestHost.isActive`.
- **Files beyond the spec's table.** The plan adds three files the spec
  doesn't list, each with one job:
  - `Enigma/Search/SearchHTTPClient.swift`;
  - `Enigma/Search/PublicSuffixList.swift`;
  - `Enigma/Search/Engines/SearchSiteRunner.swift`.

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
   needs, especially where the code differs from the Interface map.

## Rules for reviewers

Follow `docs/reviewer.md`, and these rules:

- **Don't edit files or touch git state.** Read, run commands, and report.
- **Scope:** the checkpoint's changes. That's `git diff` against the
  previous checkpoint's commit, plus every new untracked file.
- **Check, in this order:**
  1. **Correctness:** bugs, crashes, retain cycles, main-actor and
     concurrency mistakes, cancellation that doesn't propagate, timeouts
     that don't fire.
  2. **Privacy and security,** against spec §7:
     - no coordinates to search sites;
     - no location in saved sources;
     - no query or URL in logs;
     - the local-network guard holds;
     - page scripts never run.
  3. **Spec values:** limits, timings, weights, exact copy.
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
  `build` and `analyze` if you doubt the worker's results.
- **Processes:** never use a broad `pkill -f`. A pattern such as "Monitor"
  can kill unrelated processes. Kill only by PID.
- **Report** findings ranked from most to least severe. Mark each one
  **Blocker**, **Should fix** or **Nit**, and give:
  - the file and line;
  - what's wrong;
  - a concrete failure scenario;
  - a suggested fix.

  If nothing needs fixing, say so plainly. Don't report style preferences
  that the spec and the surrounding code don't support.

## Starting a checkpoint

The owner starts a new chat (Opus, medium effort) in the repository and
sends:

> Read
> `docs/superpowers/plans/2026-10-27-f29-on-device-web-search/agent-workflow.md`,
> then `cp<N>-<name>.md` in the same folder, and build checkpoint CP<N> in
> the worktree at `<path>`.

## Worker checklist (each checkpoint)

1. Read everything under "Before you start". For CP0, create the worktree
   first.
2. Build the checkpoint, run its exit checks, and fill in the Hand-off.
3. Start a fresh reviewer agent (Opus, extra high effort). Give it the
   workflow file, the brief, `docs/reviewer.md`, and the base commit to diff
   against. Don't add your own account of the changes; it reads the code.
4. Fix every Blocker and Should fix. Start a new reviewer for each round,
   until a round has neither. Ask the owner about any finding you think is
   wrong rather than skipping it.
5. Rerun the brief's exit checks. Read the whole diff. Check `git status`
   for strays, and check the Hand-off for private data.
6. Commit `<summary> (F29 CP<N>)` on
   `feat/f29-on-device-search`, including the filled-in brief. No attribution
   lines. Push the branch.
7. Update the plan's progress log (status, commit, review rounds, one-line
   notes), commit it as `Log F29 CP<N>`, and push.
8. End with a short report to the owner: the commits, the review rounds, and
   anything marked for the owner. The next checkpoint starts in a new chat.
