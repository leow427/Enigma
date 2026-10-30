# F29 overnight run — report (2026-10-30)

## RESUME

- **Weekly usage when it stopped:** 82% ("Weekly · all models"). The run stopped
  on purpose at a checkpoint boundary rather than start CP7 one point under the
  83% line (decision D91).
- **Where it stopped:** CP6 is committed (`fb17df8`) and pushed. CP7 has not
  started: no files, no eval set, no live runs. Nothing was in progress.
- **Review round:** none open. Every checkpoint's findings were fixed before its
  commit.
- **wip branch:** none. The worktree `/private/tmp/claude-501/enigma-f29` is
  clean on `feat/f29-on-device-search` at `fb17df8`.
- **Live runs cut off:** none.
- **Next 3 steps:**
  1. **Start CP7 (evaluation and tuning)** from
     `cp7-evaluation.md`: the 60-question set with model-style queries, the
     evaluation test and script, the tool-use prompts, then tuning against the
     relaxed gate (D2, D3). Tuning knobs live in `OnDeviceSearchTiming`
     (`Enigma/Search/OnDeviceSearch.swift`) and `RankingTuning`
     (`Enigma/Search/ResultRanking.swift`). Items earlier checkpoints left for
     CP7 to measure: the ranking cut-off (0.08 now; D59 suggests 0.05–0.08),
     the 800 ms extraction limit on ~1 MB pages and on macOS 26 (D77), Stack
     Overflow and `blogspot.com` trust (D55, D59), page checks letting listing
     pages through (D66), and the routing misroutes listed "for CP7" in the CP1b
     Hand-off (`cp1b-routing-fixes.md`).
  2. **Owner checks before CP8:**
     - the drafted `authority.txt` and `unreadable.txt` (D52) and `overrides.tsv`
       (D55–D57) in `Enigma/Resources/SearchData/`;
     - the spec amendments marked "Amended overnight" in §4, §6.1, §6.2 and §7;
     - the `/maps` welcome-page line (D84) and the GeoNames credit (D87);
     - CP6's manual check of the Debug switch in a Debug build.
  3. **Unlock the screen and rerun** `scripts/verify-xcode.sh test`. The 81
     hosted UI failures in nine classes are key-window timeouts from the locked
     screen (D25, D31). Then check CI on `fb17df8`, which was still running at
     the stop.

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
