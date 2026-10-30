# F29 overnight run — report (2026-10-30)

## Status (after CP10, 2026-10-31): done, PR ready for review

- **State:** CP1b to CP10 are committed and pushed on
  `feat/f29-on-device-search`; PR leow427/Enigma#25 is marked ready for
  review and is not merged. `main` is untouched.
- **Owner decision D128:** the relaxed gate failed (typed: on-device equal
  or better on 47%), so on-device search is the default for everyone with no
  setup, and Brave runs only while a key is saved, only for web searches
  (D138).
- **Left for the owner** (details in the decision log's summary and the
  CP10 Hand-off): the signed-app audit, including CP8's Settings and
  blocking and CP9's map card; the map card screenshot; confirming spec
  §7's amended Apple row (D171); the deferred
  evaluations (model-style half, the one- vs two-query A/B, the tool-use
  eval; D121); the possible llama-server keep-alive issue (D114); then the
  merge, `to-do.md`, the release note and one run of the ddgs watch.
- **After CP10 (owner, D174):** web search, places and weather each have
  their own gate 3 grant.
- **Review rule now:** reviewers are always Opus at effort xhigh; big changes
  get up to three rounds, stopping when a round finds only small fixes.

## What's done

| Checkpoint | Commit | Review rounds | Decisions | Notes |
| --- | --- | --- | --- | --- |
| CP1b routing fixes | `c90ecf3` | 8 | D7–D32, D44 | Opened draft PR leow427/Enigma#25 with Auto-fix on. Rounds 2–8 each found new regex edge cases; the fixes were checked against an 830-question probe. Several location leaks were closed. |
| CP2 search sites | `3563716` | 3 | D33–D48 | DuckDuckGo and Wikipedia, header set A, `kl`. The cooldown starts only on real block signs. A challenged query sits out alone. |
| CP3 quality and ranking | `c094b6c` | 2 | D49–D60 | 3 MB of quality data. The overrides keep Wikipedia, Stack Overflow, Healthline and MSN usable, and never lift a security block. |
| CP4 page reading | `44e4711` | 2 | D61–D72 | Local-network guard, plus a check of the address actually reached. Pages are fetched over https only. Extraction happens in a sealed WebKit view with Readability 0.6.0. |
| CP5 passages and pipeline | `5523f78` | 2 | D73–D80 | The on-device provider sits behind the Debug-only switch; Brave stays the default. Live median 1.65 s. Also fixes CP4's macOS 26 CI failure (D77); CI passed. |
| CP6 places and weather | `fb17df8` | 2 | D81–D90 | Open-Meteo weather and geocoding, Apple Maps places, `find_places`, `get_weather` and `/maps`. A declined location card holds for the rest of the chat. |
| CP7 evaluation and search features | `82e5fb3` | 2 | D92–D127 | Evaluation harness and 60 questions; owner-added query rewrite, "enough?" check, Wikidata facts and Google News headlines. Typed verdict: on-device 26, Brave 32, tie 2 (was 13 to 27 of 40). Both gates fail on the judge share. |
| CP8 switch-over | `3fc315c` | 1 | D128–D143 | Owner's D128: on-device search by default with no key or setup; Brave only while a key is saved, and only for web searches (places and weather stay on Apple Maps and Open-Meteo). "Never use this site" with Undo; blocked sites filter Brave and go to ChatGPT's and Claude Code's own search. Brave gets the city only. |
| CP9 map card | `670e105` | 2 | D145–D163 | A still Apple map under replies that used places, with numbered pins for the places the reply names (all places when it names none); pins and Open in Maps open Apple Maps; never saved. Round 1 fixed places attaching to the wrong reply after Stop; round 2 fixed Open in Maps hanging on a stalled lookup. |
| CP10 docs and maintenance | (this commit) | 1 | D164–D173 | Docs describe on-device search with Brave as an option (D128), with numbers checked against the code; the privacy table lists every recipient, including Apple's reverse geocoding (D171). Settings screenshot regenerated; weekly ddgs upstream watch; stale-lists warning in `release.sh`; notices already complete. |

The PR stays a draft: CP8–CP10 remain, and the branch merges only after CP10.

## Gate results

From CP7's round 1 (typed half only; D121). Full table in the CP7 Hand-off.

- **Passed:** clean sources; 2+ sources (100% typed, 98% model); a page read
  (100%); 3+ domains; speed against the relaxed bar (median 2.27 s, p90
  6.51 s across both styles; typed alone 5.45 s and 7.57 s).
- **Failed:** on-device equal or better on 47% of typed questions (relaxed bar
  65%, original 80%); Brave wins more than half of news, docs and reviews;
  recency equal or better 65% (bar 70%).
- **Measured, not blocking:** authority sources 39% typed, 61% model (bar
  80%).
- **Not run:** the model-style judge, the A/B and the tool-use eval.

## Spot-check pairs

`spot-check.md` for round 1 is in `/private/tmp/claude-501/f29-cp7/runs/round-1/`
(outside the repo), with no owner picks yet.

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
