# F29 overnight run — report (2026-10-30)

## RESUME (CP7 paused, 2026-10-30 10:38)

- **Why it stopped:** the owner had to turn the computer off (D100). Weekly
  usage was 82%; for CP7 the hard stop is 92% and no new review round or live
  run starts from 90% (D93).
- **Models for CP7 (D92):** worker on Haiku (effort high), each review round
  a fresh Sonnet reviewer (effort xhigh), the evaluation's judge
  `claude -p --model sonnet`.
- **Where CP7 stopped:** the worker had written the evaluation harness and
  was running the first full baseline when it was stopped.
  - Done, uncommitted on the feature branch: the 60-question set
    (`scripts/web-search-queries.json`, 40 new questions written by the
    worker, not yet reviewed by the owner, D94, D96), `WebSearchEvaluationTests`
    with the on-device trace, `scripts/evaluate-web-search.py` with its tests
    and fixtures, the 12 new tool-use prompts and their offline scoring test,
    F30's evaluator scoped to its 20 questions, test pacing for DuckDuckGo's
    rate limit (D97), answers from Gemma 4 12B with evidence capped (D98).
    Python tests passed when it stopped.
  - Not done: the full baseline (`baseline-2` was cut off mid-run), the judge
    run, any tuning, Task 7.5's live tool-use eval, the gate report, the
    spot-check, the Hand-off, and every review round.
- **wip branch:** `wip/f29-cp7-20261030-1037` (commit `9f02355`) holds all of
  the above. The feature branch has only this report and the decision log.
- **Live run cut off:** `baseline-2` in
  `/private/tmp/claude-501/f29-cp7/runs/` (incomplete; rerun it). `baseline-1`
  ran without pacing and isn't used for the gate (D97).
- **Full suite** on `bf4d115`, screen unlocked: 1957 tests, 1 flaky UI
  failure that passes alone (D99). CI on `bf4d115` hit the known
  `ScreenViewTests` flake; the failed job was rerun.
- **Next 3 steps:**
  1. In `/private/tmp/claude-501/enigma-f29`, bring the wip work back onto
     the feature branch without committing it:
     `git merge --squash wip/f29-cp7-20261030-1037` (the decision log on both
     branches is identical up to D98, so it merges cleanly or keeps the
     feature branch's copy, which has D99–D100).
  2. Resume CP7 with a new Haiku worker: give it the CP7 brief, this RESUME,
     D92–D100 and `/private/tmp/claude-501/f29-overnight/agent-rules.md`, and
     tell it to rerun the baseline (`baseline-3`), then judge, tune, run the
     tool-use eval, write the gate report, the spot-check (outside the repo)
     and the Hand-off. Optional first: the owner reviews the 40 new questions
     and 12 tool prompts (D94), since changing them later means rerunning.
  3. Then the review rounds (fresh Sonnet reviewer each), the full suite,
     build and analyze, and the `(F29 CP7)` commit; then CP8–CP10.

## What's done

| Checkpoint | Commit | Review rounds | Decisions | Notes |
| --- | --- | --- | --- | --- |
| CP1b routing fixes | `c90ecf3` | 8 | D7–D32, D44 | Opened draft PR leow427/Enigma#25 with Auto-fix on. Rounds 2–8 each found new regex edge cases; the fixes were checked against an 830-question probe. Several location leaks were closed. |
| CP2 search sites | `3563716` | 3 | D33–D48 | DuckDuckGo and Wikipedia, header set A, `kl`. The cooldown starts only on real block signs. A challenged query sits out alone. |
| CP3 quality and ranking | `c094b6c` | 2 | D49–D60 | 3 MB of quality data. The overrides keep Wikipedia, Stack Overflow, Healthline and MSN usable, and never lift a security block. |
| CP4 page reading | `44e4711` | 2 | D61–D72 | Local-network guard, plus a check of the address actually reached. Pages are fetched over https only. Extraction happens in a sealed WebKit view with Readability 0.6.0. |
| CP5 passages and pipeline | `5523f78` | 2 | D73–D80 | The on-device provider sits behind the Debug-only switch; Brave stays the default. Live median 1.65 s. Also fixes CP4's macOS 26 CI failure (D77); CI passed. |
| CP6 places and weather | `fb17df8` | 2 | D81–D90 | Open-Meteo weather and geocoding, Apple Maps places, `find_places`, `get_weather` and `/maps`. A declined location card holds for the rest of the chat. |

The PR stays a draft: CP7–CP10 remain, and the branch merges only after CP10.

## Gate results

Not measured. The quality evaluation, judge run, tool-use eval and
authority-source check are CP7's job, and CP7 hasn't started. For CP8 the bars
are the relaxed gate in D3, with the original bars and the authority-source
check measured and logged but not blocking.

## Spot-check pairs

None yet. The blind spot-check of about 15 pairs is part of CP7 (D6).

## Things done outside the worktree that the owner may want to know

- **WebKit rule-list file.** The test host shares the app's bundle ID, so a
  static WebKit rule-list file exists at
  `~/Library/WebKit/com.leow427.AISpotlight/ContentRuleLists/`. It holds only
  the block-all rule (D69, D71).
- **Reviewer mutants moved.** Two reviewers' mutant runs created WebKit folders
  under `~/Library`. They were moved, not deleted, to:
  - `/private/tmp/claude-501/cp4-review1-logs/mutant-webkit-artifacts/`
  - `/private/tmp/claude-501/cp4-review2-logs/created-by-review/`
- **One stray connection.** A reviewer's scratch test made one connection
  attempt to example.com's documented address. No query or user data was sent.
- **Hung test run stopped.** During CP1b the orchestrator stopped one hung
  full-suite `xcodebuild` run (D31).
- **Logs.** Per-checkpoint logs and probes are in folders under
  `/private/tmp/claude-501/` named `cp*-review*`, `f29-cp*` and `cp1b-*`. The
  orchestrator's notes are in `/private/tmp/claude-501/f29-overnight/`.
