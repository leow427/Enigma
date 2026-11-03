# F35 agent workflow

F35 is built one checkpoint at a time on `feat/f35-context`. The repository
rules in [`docs/Agent-Workflow.md`](../../../Agent-Workflow.md) apply in full:
this page adds only what checkpoints need on top.

**Before you start, read:**

1. `AGENTS.md` and `docs/Agent-Workflow.md`;
2. the F35 entry in `to-do.md`, in full;
3. the [plan](../2026-11-03-f35-context-and-compaction.md): Global
   Constraints, Review Focus, Interface map;
4. your brief;
5. the Hand-off sections of every earlier brief.

## Roles

**Owner:** starts one worker chat per checkpoint and answers its questions.
Approves every live run (real models, ChatGPT or Claude Code sign-ins) and
the merge.

**Worker:** the chat the owner starts. It builds exactly one checkpoint
itself (never through a worker subagent), test-first, in the brief's order;
fills in the brief's Hand-off; starts a fresh reviewer each round
(`model: "opus"`, `effort: "xhigh"`), at most three rounds, as
`docs/Agent-Workflow.md` says; then commits once and pushes. CP0 also
creates the worktree: branch `feat/f35-context` from `main`, in a folder
outside `~/Documents` (test hosts there set off macOS privacy prompts).

**Reviewer:** given this file, the brief, `docs/reviewer.md` and the
previous checkpoint's commit to diff against. Follows the reviewer rules in
`docs/Agent-Workflow.md`, and also checks that every value and copy string
the brief uses matches the plan's tables exactly.

## Rules on top of the repository's

- **Stay in your checkpoint.** Make only your brief's changes, plus what
  they strictly need. List anything else in the Hand-off with the reason.
- **Follow the brief, the plan and the entry.** When they disagree, or the
  code no longer matches what the brief says exists, stop and ask the owner.
  Never edit the entry or another checkpoint's brief; propose changes in the
  Hand-off.
- **Find code by symbol,** not by line number. Briefs were written against
  `main` at `8a27b28` (2026-11-03).
- **Existing tests stay unedited** unless the brief names them as tests
  whose expected values F35 changes (for example the old 32,768 cloud cap).
  Each such edit is listed in the Hand-off.
- **Live runs** need the owner's approval in the chat first, with an
  estimate of the calls. The owner has no OpenAI, Anthropic or Gemini API
  keys: API-route behaviour is tested from fixtures only.
- **Never handle keys or sign-ins.** Hand owner-run commands to the owner.

## Project mechanics

- **New Swift files** need four `project.pbxproj` entries (build file, file
  reference with `sourceTree = SOURCE_ROOT`, main-group child
  `A70000000000000000000001`, and the Sources phase
  `A80000000000000000000001` for the app or `A80000000000000000000002` for
  `EnigmaTests`), with new unique 24-character hex IDs. Check with
  `plutil -lint Enigma.xcodeproj/project.pbxproj`.
- **Verifying:** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>`
  while iterating; `build`, the full `test` and `analyze` once before the
  commit. Report build result, test counts (executed, skipped, failed) and
  the analyzer result. Save logs outside the repository.
- **Unreliable failures:** key-window UI tests that time out during a full
  run usually mean another checkout's tests ran at the same time; rerun them
  alone first. `EnigmaConversationTests`' character-fall test flakes on CI;
  rerun failed tests before treating them as real.
- **Shared preferences:** the test host shares `Enigma.app`'s defaults.
  Never touch `UserDefaults.standard` in a test; inject
  `UserDefaults(suiteName:)` and remove it in `tearDown`.
- **CI:** CP0 opens a draft pull request from `feat/f35-context` to `main`
  after the owner approves it, and turns on Auto-fix for it. Every
  checkpoint's push runs CI. A failure the checkpoint caused gets one
  follow-up commit, `Fix CI after F35 CP<N>`; the next worker records the CI
  result in its Hand-off.

## Hand-off

Fill in your brief's **Hand-off** before the first review and keep it
current. It goes into the commit:

1. **Summary:** what you built, in a few sentences.
2. **Files:** every file added, changed or removed, one line each.
3. **Decisions:** choices the brief left open, and any departure, with the
   reason.
4. **Verification:** the commands you ran and their results, live runs the
   owner approved, the CI run.
5. **Limitations:** anything unfinished, unverified or risky.
6. **For the next checkpoint:** names and facts the next worker needs,
   especially where the code differs from the Interface map.

## Starting a checkpoint

The owner starts a new chat in the repository and sends:

> Read
> `docs/superpowers/plans/2026-11-03-f35-context-and-compaction/agent-workflow.md`,
> then `cp<N>-<name>.md` in the same folder, and build checkpoint CP<N> in
> the worktree at `<path>`.

For CP0, `<path>` is where to create the worktree (for example under
`/private/tmp/claude-501/`).

## Worker checklist

1. Read everything under "Before you start". CP0 creates the worktree.
2. Build the checkpoint test-first; run its exit checks; fill in the
   Hand-off.
3. Start a fresh reviewer (Opus, xhigh). Tell the owner each Blocker and
   Should fix it found, then fix them. Repeat as `docs/Agent-Workflow.md`
   says, at most three rounds; after round 3 ask the owner before committing
   if a Blocker remains.
4. Rerun the exit checks, read the whole diff, check `git status` for strays
   and private data.
5. Update your row in the plan's progress log.
6. One commit, `<summary> (F35 CP<N>)`, with the code, the filled-in brief
   and the progress log. No attribution lines. Push, and report the commit,
   the review rounds, the CI result and anything for the owner.
