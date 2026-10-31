# Agent workflow

Every code change is built by a worker chat (Opus, medium effort) and audited
by fresh reviewer agents. One task per chat.

## Workers

1. Read `AGENTS.md`, your task, and any spec it names.
2. Build it test-first: watch each test fail, then pass.
3. Start a fresh reviewer with the Agent tool, `model: "opus"` and
   `effort: "xhigh"`. Give it this file, the task, `docs/reviewer.md` and the
   base commit, not your own summary.
4. Fix every Blocker and Should fix, then:
   - After round 1: if every finding was small (a wording change, a missing
     test, a one-line correction), fix and test it yourself and stop.
     Otherwise run round 2.
   - After round 2: run round 3 only if it found real issues.
   - After round 3: if a Blocker remains, ask the owner before committing.
   - Each round gets a fresh reviewer. If you think a finding is wrong, ask
     the owner rather than skipping it.
5. Run the full suite once, read the whole diff, check `git status` for
   strays and private data, then make one commit and push. No attribution
   lines. Fix any CI failure you caused.
6. Report to the owner: the commit, the review rounds, anything outside the
   task, and anything left for the owner.

**Rules:**

- Git: one commit, at the end. No `stash`, `checkout`, `reset`, `clean` or
  `rebase`. Stay inside the task.
- If the task and the spec disagree, or the code doesn't match the task, stop
  and ask the owner. Never edit a spec; propose changes in your report.
- Never delete, skip or weaken a test. Tests stay offline and deterministic:
  fake network and clock, `UserDefaults(suiteName:)`.
- While working, run only the affected test classes (`scripts/verify-xcode.sh
  test -only-testing:EnigmaTests/<Class>`).
- No new dependencies. Keep existing permission prompts and fallback paths.
- Never log user content (prompts, queries, URLs, page or file text), and
  write nothing to disk the spec doesn't name.
- Use the spec's exact wording, follow `docs/design/UI-Style.md`, reuse
  `EnigmaControls.swift`, and give every control a VoiceOver label.

## Reviewers

Never edit a file or touch git state. Never trim a review to save usage.

- **Scope:** the diff since the base commit, plus new files.
- **Check, in order:**
  1. Correctness: bugs, crashes, concurrency, cancellation, timeouts.
  2. Privacy: no user content in logs or on disk, nothing sent where the
     spec doesn't allow, no local-network access or page scripts where web
     content is fetched.
  3. The spec's exact values and copy.
  4. Every part of the task.
  5. Tests, including mutation tests in a scratch copy: break the code and
     confirm a test fails.
  6. Xcode project registration (`plutil -lint` passes).
  7. No stray files, private paths, credentials or attribution lines.
- **Run** only the affected test classes. Kill processes by PID, never with a
  broad `pkill -f`.
- **Report** only Blocker and Should fix findings, ranked, each with
  file:line, what's wrong, a failure scenario and a fix. No nits. If nothing
  needs fixing, say so.
