# F29 overnight decision log

**How to read this:** every decision the owner would otherwise have made during
the unattended run of 2026-10-30 (CP1b to CP10), newest last. Each entry gives
when, which checkpoint, what was decided, why, the alternatives and how to
switch, and whether it's reversible. "Owner, 2026-10-30" entries are the
owner's own decisions from the run's instructions, logged where they apply.
The summary at the top is written when the run ends.

## Summary

*Written when the run ended (after CP10, 2026-10-31). One line per decision, by checkpoint. "R" = reversible; "(owner)" = the owner's own decision.*

**Run setup**
- D1 Overnight process replaces the workflow's owner role (owner) — R
- D2 Speed bar relaxed (owner) — R
- D3 Quality gate relaxed (owner) — R
- D4 If the relaxed gate fails, keep Brave (owner) — R
- D5 Dependencies and document amendments allowed (owner) — R
- D6 Spot-check and live-run rules (owner) — R
- D25 Hosted UI tests while the screen is locked — R
- D91 Stop after CP6 instead of starting CP7 at 82% — R

**CP1b**
- D7 Which times let a weather question use the current location — R
- D8 Test pointed at the new "local" query — R
- D9 Weather place stops before a trailing time; "forecast" stays a "now" word — R
- D10 Fix all seven round-1 Should fixes, including the pre-existing ones — R
- D11 Reopen D7: parts of the day use the current location — R
- D12 "temperature in <named place>" is weather — R
- D13 Weather candidates end at the next preposition; a loose timing guard — R
- D14 Word lists for D10 and D12 — R
- D15 Fix round 2's six routing findings; narrow "outside" and D12 — R
- D16 Review round 3 runs; later misroutes go to CP7 unless they leak location — R
- D17 Details of the round-2 fixes — R
- D18 Fix round 3's findings, plus "<city> weather today"; round 4 runs — R
- D19 Round-3 details: the city-before-"weather" rule, "temperature like", and a repointed test — R
- D20 Fix round 4; anchor new weather patterns to the whole question; round 5 runs — R
- D21 Round-4 details — R
- D22 Fix round 5; regression-check every fix against the reviewers' 830-question probe; round 6 runs — R
- D23 Round-5 details and fixes from the regression probe — R
- D24 Fix round 6's two location leaks and test gaps; round 7 is the last unless it finds a leak — R
- D26 Round-6 details — R
- D27 Round 7's leak fix, then a focused round 8 — R
- D28 Round-7 details — R
- D29 Apply round 8's verified leak fix without a round 9, then commit — R
- D30 Round-8 port details — R
- D31 Stop the hung full-suite run; rerun with per-test time limits — R
- D32 Full-suite failures sorted as environment failures (D25) — R
- D44 A flaky CI test re-run, not changed — R

**CP2**
- D33 The owner's lineup applied: what CP2 skips — R
- D34 Header set A splits `SafariHeaders` into GET and form-POST headers — R
- D35 DuckDuckGo gets its own region codes — R
- D36 One extra live request to find DuckDuckGo's "no results" marker — R
- D37 Runner and health details the brief leaves open — R
- D38 Result count: DuckDuckGo's first page only, page 2 ported but unused — R
- D39 Which 30 Wikipedia editions count as "the largest" — R
- D40 Work around an NSXMLNode XPath bug for `//text()` — R
- D41 Only real block signs start DuckDuckGo's cooldown; a lone 202 doesn't — R
- D42 Region codes from DuckDuckGo's own list — R
- D43 Round-1 fix details — R
- D45 A challenged query sits out alone; two different challenged queries cool the site down — R
- D46 Round-2 fix details (the per-query strike) — R
- D47 Round 3's fixes, then commit without a round 4 — R
- D48 Round-3 fix details — R

**CP3**
- D49 The unsafe lists don't fit 3 MB: a keep order, malware dropped first — R
- D50 Reading Wikipedia's Perennial sources — R
- D51 A list that shrinks by more than half counts as a parse failure — R
- D52 `authority.txt` and `unreadable.txt` drafted without the owner's approval — R
- D53 Ranking tuning in one place; ties favour trust — R
- D54 Authority domains match on the host; the settings load the lists lazily — R
- D55 Keep Wikipedia, Stack Overflow, Healthline and MSN usable — R
- D56 What blocks MSN and Healthline, and how D55's overrides work — R
- D57 More overrides: crowdfunding/petition sites readable, preprints and AWS docs not penalised — R
- D58 Round-1 fix details — R
- D59 Keep security entries under allowed domains; no round 3; cut-off left for CP7 — R
- D60 Round-2 fix details — R

**CP4**
- D61 Readability sits in `SearchData/readability/`, outside the lists' 3 MB budget — R
- D62 More date sources, a modified date, and a plausibility check — R
- D63 One view, extractions in turn, tuning in named constants — R
- D64 The local-network guard refuses a little more, fails closed, and a refusal is its own outcome — R
- D65 Downloading details the brief leaves open — R
- D66 Page checks: more wall phrases, order, non-readerable long pages kept, CJK word counts — R
- D67 The block-all rule list is compiled into WebKit's default store — R
- D68 Extracted text capped at 200,000 characters — R
- D69 Round-1 fixes: unresolved isn't refused; lenient UTF-8; one static rule-list file; drop responses from non-public addresses — R
- D70 Round-1 fix details (D69) — R
- D71 Pages over https only (ATS stays strict); round-2 fixes; no round 3 — R
- D72 Round-2 fix details (D71) — R

**CP5**
- D73 Pipeline tuning defaults inside the owner's speed bar — R
- D74 Pipeline details the brief leaves open — R
- D75 `web_search` on the on-device provider is capped to F32's budget — R
- D76 WebKit's own extraction errors become a normal failure, retried once on a fresh view — R
- D77 Replace D76: CI failures were slow-runner timeouts; warm the WebKit process; site outages aren't "no results" — R
- D78 How D77's warm-up and fixes are built — R
- D79 Round-2 fixes, then commit without a round 3 — R
- D80 Round-2 fix details (D79) — R

**CP6**
- D81 Geocoding asks for 5 results and prefers an exact name match; names as returned — R
- D82 The tools' activity text is two new phases that count as searching — R
- D83 Places and weather are in `NativeToolPlan.offeredParts`, not `parts` — R
- D84 How `/maps` travels and what it conflicts with — R
- D85 Tool details the brief leaves open — R
- D86 Three F30/F32 assertions follow spec §6.2's intended changes — R
- D87 A declined location stays declined for the places and weather tools; round-1 fixes — R
- D88 How the round-1 fixes (D87) are built — R
- D89 A declined location lasts for the rest of the chat; round-2 fixes; no round 3 — R
- D90 How the round-2 fixes (D89) are built — R

**CP7**
- D92 Haiku worker, Sonnet reviewers, Sonnet judge (owner) — R
- D93 The usage stop moves from 86% to 92% for CP7 (owner) — R
- D94 Owner approvals the brief asks for are deferred; judge and models as the orchestrator set — R
- D95 Answers come from the installed models through the app's llama-server; the evaluator makes them — R
- D96 Question set, gate reading, and F30's evaluator scoped to its 20 — R
- D97 Evaluation pacing and one retry for DuckDuckGo's rate limit (harness only) — R
- D98 Answers come from one model (Gemma 4 12B) with the evidence capped — R
- D99 Two flaky UI tests left unchanged — R
- D100 Paused at the owner's request; work saved to a wip branch (owner) — R
- D101 Answers with the model's thinking turned off — R
- D102 DuckDuckGo gave much less on-device coverage in later runs with the same code — R
- D103 Speed-up: parallel judge, early read, cached answers, two-slot test — R
- D104 Owner adds four search features (owner) — R
- D105 A Sonnet worker builds D104's features — R
- D106 Pivot: stop the DuckDuckGo-only evaluation; an Opus worker builds D104's features (owner) — R
- D107 How the local-model query rewrite is built (D104, feature 1) — R
- D108 How the "enough?" check and its one retry are built (D104, feature 2) — R
- D109 How the Wikidata facts source is built (D104, feature 3) — R
- D110 How Google News RSS is built, and what its links do (D104, feature 4) — R
- D111 Site-outcome trace finished; step timings traced; two new evidence kinds — R
- D112 How the features' smoke check runs — R
- D113 Speed tuning after the first smoke run (features-1) — R
- D114 The smoke runs' rewrite time was mostly a stale connection; third run — R
- D115 Two DuckDuckGo queries stay, though the speed bar isn't met yet — R
- D116 Speed bar relaxed to 5.0 s / 7.0 s; the second query stays if it improves answers (owner) — R
- D117 Round-1 run: relaxed speed bar, fair evidence cap, head-to-head judge, one-query override, Brave reused — R
- D118 Task 7.5 (the live tool-use eval) deferred until the owner says the Mac is free — R
- D119 Opus reviewers, up to three rounds; no tuning round (owner) — R
- D120 Option A: the rewrite and check stay on the small-model path (owner) — R
- D121 Evaluation stopped after the typed half (owner) — R
- D122 Review round 1's fixes, decided on the cautious side — R
- D123 Review round 2 runs — R
- D124 How review round 1's fixes are built — R
- D125 Round 2's fixes; Google News kept under its feed terms; no round 3 (owner) — R
- D126 How round 2's fixes (D125) are built — R
- D127 Verification before the commit — R

**CP8**
- D128 On-device by default; Brave only with a saved key (owner) — R
- D129 Where the Brave-or-on-device choice lives, and when it updates — R
- D130 `missingAPIKey` and the other Brave-only errors — R
- D131 The footer, gate 3's card and other labels name the provider used — R
- D132 Blocked sites also filter Brave's results — R
- D133 Settings and welcome text under D128 — R
- D134 No launch cleanup; the brief's cleanup tests are not written — R
- D135 Scope cut for usage: no review round by this worker — R
- D136 Brave gets only the city; the blocked-sites note names who can't enforce it — R
- D137 Smaller choices — R
- D138 With a Brave key, places and weather stay on-device — R
- D139 Online seam for live tests; offline places and weather defaults in the test host — R
- D140 One review round; the orchestrator verifies the fixes — R
- D141 How review round 1's nits are built — R
- D142 The reading sentence and the "what leaves the Mac" table — R
- D143 Tests for round 1, and a mutation check — R
- D144 Commit with one known flaky UI test — R

**CP9**
- D145 The live map exists only while the card is on screen — R
- D146 When places reach the reply — R
- D147 Pin matching details and the singular label — R
- D148 The card's look — R
- D149 Scrolling passes through the map — R
- D150 Opening Apple Maps — R
- D151 How the view tests check the card — R
- D152 Steps left to the owner and the orchestrator — R
- D153 A stopped reply with text keeps its card; places never attach late — R
- D154 Owner's Recents check relaunches first; pin names hidden — R
- D155 A short review round 2 — R
- D156 No stale places: request-scoped, cleared at every start — R
- D157 Camera, matching and opening after review — R
- D158 New route tests use local fakes — R
- D159 Round 2: Open in Maps' time limit resumes the wait itself; the request guard gets a test — R
- D160 Accepted limits; no round 3 — R
- D161 The place lookup's time limit resumes the wait itself — R
- D162 A late request's places, and the screen fallback — R
- D163 Commit with one unrelated flaky test — R

**CP10**
- D164 The docs follow D128, not the brief's "Brave removed" — R
- D165 How the ddgs watch compares and reports — R
- D166 The workflow's issue handling — R
- D167 The stale-lists warning — R
- D168 Notices: nothing to add for Wikidata or Google News — R
- D169 Local-Model-Selection gets no new tool-choice scores — R
- D170 to-do.md and the map card screenshot are left for the owner — R
- D171 Docs say gate 3's one answer covers search, places and weather; Apple's reverse geocoding is listed — R
- D172 One review round — R
- D173 Review round 1's fixes — R

**Checks not run or failed**
- The relaxed quality gate (D3) failed on the typed judge share: on-device equal or better on 47% (26 on-device, 32 Brave, 2 ties of 60). Hence D128: on-device by default, Brave kept as an option with a saved key.
- Recency 65% (bar 70%); authority sources 39% / 61% (bar 80%, not blocking).
- Not run: the model-style half of the evaluation, the one-query vs two-query A/B (D116), the tool-use eval (Task 7.5) — deferred until the owner is away from the Mac (D121).
- Not run: the live search checks with the network after CP8, and the signed-app checks of CP8, CP9 (map card) and the final audit — the owner's.
- Full-suite flakes not caused by F29: `EnigmaMainWindowTests.testSendNowDuringAPendingSend…` under load (D144), `ClaudeCodeSubscriptionTests.testClaudeCodeRestartDeliversNothing` (D163).

**What's next (owner):** the signed-app audit in `cp10-docs-and-maintenance.md`'s Hand-off; the map card screenshot; confirm spec §7's amended Apple row (D171); decide whether gate 3 keeps one grant for search, places and weather (D171); the deferred evaluations; the possible llama-server keep-alive issue (D114); then merge the PR, mark F29 done in `to-do.md`, add the release note and run the ddgs watch once.

## Index by checkpoint

- **Run setup:** D1–D6, D25 (all checkpoints)
- **CP1b:** D7–D24, D26–D32, D44 (CI)
- **CP2:** D33–D43, D45–D48
- **CP3:** D49–D60
- **CP4:** D61–D72
- **CP5:** D73–D80
- **CP6:** D81–D90
- **Run end:** D91
- **CP7:** D92–D127
- **CP8:** D128–D144
- **CP9:** D145–D163
- **CP10:** D164–D173

## Entries

### D1 — 2026-10-30 00:35, run setup — Overnight process replaces the workflow's owner role

- **Decided (owner, 2026-10-30):** an orchestrator session runs CP1b to CP10
  in order. Per checkpoint: one Opus worker (effort high for CP2–CP8, medium
  for CP1b, CP9, CP10), a fresh Opus reviewer at xhigh effort each round
  (normally at most 3 rounds; another round after any real-bug fix, even past
  3), the worker fixes findings, full suite plus build and analyze once, one
  commit `<summary> (F29 CPn)` pushed to `feat/f29-on-device-search`. No merge
  to `main`. Weekly usage 83% stops new work, 86% is a hard stop.
- **Why:** owner unavailable overnight.
- **Alternatives:** resume the workflow file's owner-driven chats from any
  checkpoint commit.
- **Reversible:** yes.

### D2 — 2026-10-30 00:35, run setup — Speed bar relaxed

- **Decided (owner, 2026-10-30):** median search 4.0 s or less and 90th
  percentile 6.0 s or less on this Mac, replacing the spec's 3.0 / 4.5 s. Spend
  the room on quality (more results, more pages read, better ranking) where it
  measurably helps.
- **Why:** owner prefers reliability and facts over speed.
- **Alternatives:** the spec's 3.0 / 4.5 s bar (spec §9 and the CP7 brief).
- **Reversible:** yes (timing constants in `OnDeviceSearchTiming`, gate values
  in CP7's evaluation).

### D3 — 2026-10-30 00:35, run setup — Quality gate relaxed

- **Decided (owner, 2026-10-30):** Brave is removed in CP8 only when all hold:
  on-device judged equal or better on 65%+ of questions (was 80%) on both
  query styles; in no category does Brave win more than half; recency on news
  and changing-facts questions equal or better 70%+; no ad, blocklisted or
  known-spam source; 2+ sources on 95%+ of web questions and at least one page
  read on 90%+; the speed bar (D2); the tool-use eval bar (0.90+, places and
  weather tools right on 10 of 12+). The authority-source check (80% on health,
  finance, docs) is measured and logged, not blocking; tune toward it while it
  helps, stop once the relaxed gate passes and changes stop improving.
- **Why:** a keyless search with current, useful answers is worth shipping even
  if marginally worse than Brave.
- **Alternatives:** the spec's original gate (CP7 brief).
- **Reversible:** yes.

### D4 — 2026-10-30 00:35, run setup — If the relaxed gate fails, keep Brave

- **Decided (owner, 2026-10-30):** if the relaxed gate can't pass after
  tuning, skip CP8's Brave removal, keep on-device search behind its switch
  with Brave as default, log why, and still build CP9 and CP10.
- **Reversible:** yes.

### D5 — 2026-10-30 00:35, run setup — Dependencies and document amendments allowed

- **Decided (owner, 2026-10-30):** new dependencies (e.g. SwiftSoup) are
  allowed if needed, after checking maintenance, licence, security and app
  size; pinned and logged. Spec, plan and brief changes are allowed when they
  serve the goal, marked in the file "Amended overnight (orchestrator, owner to
  confirm)" and logged here. This overrides the workflow's "no new
  dependencies" and "never edit the spec or another brief" for this run.
- **Reversible:** yes.

### D6 — 2026-10-30 00:35, run setup — Spot-check and live-run rules

- **Decided (owner, 2026-10-30):** the spec's ~15-pair spot-check is done
  blind by a fresh reviewer agent; pairs saved outside the repo, path logged.
  Live runs of the kinds F29/F30 already ran are allowed; cloud models only
  Claude Code (sonnet) and ChatGPT via Codex (gpt-5.6-luna); local models
  fine; Brave key only through `TEST_RUNNER_ENIGMA_BRAVE_KEY="$(cat
  ~/.enigma-brave-key)"`; no header changes beyond CP0b's set A.
- **Reversible:** yes.

### D7 — 2026-10-30 00:39, CP1b — Which times let a weather question use the current location

- **Decided (worker CP1b):** the times spec §6.1 adds (noon, midnight,
  breakfast, lunch, lunchtime, dinner, sunrise, sunset, dawn, dusk and the
  holidays) and home, work and school never block the current location, so
  "is it going to rain at noon" and "what's the weather at home today" are
  weather with the current location, as the brief's rows expect. CP1's own
  times (months, weekdays, "the weekend", "an hour") keep owner decision 2
  of 2026-10-27: they still block the location, so "will it snow in
  december" and "what's the forecast for the weekend" stay on the web route.
  All of these are skipped as the weather's named place. CP1 gave every new
  time row the time itself as the named place (for example "noon"), never
  "no location and no place".
- **Why:** both sets of rows are tested; keeping CP1's rows unchanged avoids
  weakening tests and keeps owner decision 2, and seasonal or far-off
  questions are better served by web search than by today's local forecast.
- **Alternatives:** treat every time alike (months and weekdays would then
  use the current location too): add CP1's time words to the exclusion list
  `nearTime` in `LocationService.swift` and change the two CP1 rows in
  `SearchRoutingTests` (needs the owner).
- **Reversible:** yes.

### D8 — 2026-10-30 00:39, CP1b — Test pointed at the new "local" query

- **Decided (worker CP1b):** `testWebQueryDropsCueWithoutCity` expected
  `webQuery("local cafes", city: nil) == "cafes"`; spec §6.1 now keeps
  "local <place word>" without a city, so the assertion now expects "local
  cafes" (plus a "local gyms" case). It still checks that the query has no
  "current area" and no double space.
- **Why:** behavior changed on purpose (spec §6.1, owner-approved
  2026-10-29); dropping "local" loses the nearby intent.
- **Alternatives:** none within the spec.
- **Reversible:** yes.

### D9 — 2026-10-30 00:39, CP1b — Weather place stops before a trailing time; "forecast" stays a "now" word

- **Decided (worker CP1b):** (1) a weather place candidate ends before
  "in/at/for/near <time>", so "what's the weather in rome in the evening"
  finds "rome", not "rome in the evening" (an extra row beyond the brief, the
  mirror of its "in the evening in rome"). (2) "forecast" stays in CP1's
  `asksAboutNow` list, although spec §6.1's "now" words don't list it: the
  existing `testLocationIntentOnlyUsesNearbyQuestions` requires "Weather
  forecast" to use the current location. A first attempt removed it and that
  test failed, so it was put back. Side effect kept from CP1: any question
  with "forecast" and a place after in/at/for/near ("sales forecast for q3")
  routes to weather; CP6's geocoding failure falls back to web search.
- **Why:** spec §6.1 says the place runs "up to a time word"; the existing
  test pins "Weather forecast" and mustn't be weakened.
- **Alternatives:** remove "forecast" from `asksAboutNow` in
  `LocationService.swift` and change that test (owner); drop the
  `trailingTime` cut.
- **Reversible:** yes.

### D10 — 2026-10-30 00:58, CP1b — Fix all seven round-1 Should fixes, including the pre-existing ones

- **Decided (orchestrator):** the worker fixes all seven round-1 findings:
  (1) "local" plus an ambiguous word (library, bar, park, pub, atm…) doesn't
  count as a nearby cue in how-to or developer questions (import, install,
  pip, npm, package, module, python, swift…), and the place word must end at a
  word boundary that isn't `/` or `-`; (2) easter, christmas, sunrise, sunset,
  dinner… count as a time only when they are the whole candidate (optionally
  "the …", "… eve/day"), so "easter island" and "sunrise florida" stay named
  places; (4) "local <ambiguous word> in <area>" goes to places again, as spec
  §6.1 says; (5) rows that kill the two surviving mutants; (6) language names
  aren't named areas ("restaurant in spanish" is web); (7) `weatherPlace` stops
  at the first acceptable place so long drafts stay fast.
- **Why:** (1) is a privacy issue: a programming question would send the city
  to search sites and show F30's share-location card. (6) is pre-existing but
  the same misroute the brief's finding 6 fixes. The rest are concrete
  misroutes or test gaps (reviewer round 1).
- **Alternatives:** leave (6) for CP7's evaluation to catch; revert any rule
  in `LocationService.swift` / `SearchRouting.swift` in the CP1b commit.
- **Reversible:** yes.

### D11 — 2026-10-30 00:58, CP1b — Reopen D7: parts of the day use the current location

- **Decided (orchestrator):** "in the morning / afternoon / evening / night"
  (and "this …", "tonight") count like noon: a weather question with only such
  a time uses the current location. Months, weekdays and "the weekend" still
  block it (CP1 owner decision 2's web rows), and CP1's existing rows,
  including "is it going to rain in an hour", stay as they are.
- **Why:** the brief's principle is that a time is never the place, so the
  current location is used; CP1 owner decision 2 lists "in the morning" with
  "in 2 hours" and "at 5pm", which already use the location. "will it rain in
  the afternoon" giving no weather was a misroute (reviewer round 1,
  finding 3).
- **Alternatives:** keep D7 as the worker first built it (remove the
  part-of-day words from the `nearTime` exclusion in `LocationService.swift`).
- **Reversible:** yes.

### D12 — 2026-10-30 00:58, CP1b — "temperature in <named place>" is weather

- **Decided (orchestrator):** "what's the temperature in denver" routes to
  weather for "denver", as CP1 did, although "temperature" is a bare topic
  word under spec §6.1. Not when the "place" is a unit (fahrenheit, celsius,
  kelvin) or starts with "the" ("the oven", "the sun"), so cooking and science
  questions stay on the web route. Bare "what's the temperature" (no place, no
  time) stays web, as the spec says. Spec §6.1 gets an "Amended overnight"
  note.
- **Why:** it is a weather question; Open-Meteo gives a current, factual
  answer; the narrow exclusions keep CP1b's web rows (bake salmon, sun,
  chicken) web.
- **Alternatives:** follow spec §6.1 literally (drop the rule in
  `LocationService.swift`, and the amendment note).
- **Reversible:** yes.

### D13 — 2026-10-30 01:01, CP1b — Weather candidates end at the next preposition; a loose timing guard

- **Decided (worker CP1b):** each weather-place candidate now ends at the
  next in/at/for/near (or a time word), and `weatherPlace` stops at the first
  acceptable one (`enumerateMatches` with stop). This replaces D9's
  `trailingTime` cut: "rome in the evening" and "paris at noon" give the
  city. `testLongDraftStaysFast` builds an 88K-character draft and asserts
  `weatherPlace` plus `decide` take under 2.0 s. It ran in 0.025 s, and the
  quadratic version took about 10 s, so the bound has about 80 times
  headroom.
- **Why:** reviewer round 1, finding 7: the lazy candidate scanned to the end
  of the draft once per preposition (7–10 s per keystroke on long drafts).
- **Alternatives:** drop the timing assertion and keep only the correctness
  assertion in `SearchRoutingTests.testLongDraftStaysFast`; a place name
  containing "in/at/for/near" as a word is now cut there (none found in
  the rows).
- **Reversible:** yes.

### D14 — 2026-10-30 01:01, CP1b — Word lists for D10 and D12

- **Decided (worker CP1b):** (1) the "local" developer veto covers bar(s),
  park(s), atm(s), library/libraries and pub(s) (`localVetoWords` in
  `SearchRouting.swift`); "pub" stays a named-area place word. Developer
  words: import, install, link, package, module, dependency, pip, npm,
  yarn, pnpm, cargo, cmake, gradle, maven, cocoapods, spm, python, swift,
  swiftui, java, javascript, typescript, node, rust, golang, ruby, php,
  cpp, xcode, compile(r), framework, sdk, api, code, repo, git, github,
  docker (`developerWords` in `LocationService.swift`), plus how-to
  questions. (2) Languages (about 40 names, `LocationIntent.languages`)
  are excluded as named areas and as weather places ("what's the weather in
  spanish" is web). (3) "temperature in <x>" also excludes degrees,
  centigrade, f/c/k, a few programming names and languages. (4) Only
  easter, christmas, sunrise, sunset and dinner need to stand alone to be a
  time; the other new times (noon, lunch, dawn, …) stay plain exclusions.
- **Why:** the orchestrator's D10/D12 name examples ("and so on"); these
  fill them in with the common cases while keeping each list small.
- **Alternatives:** edit the lists in those two files; each word has its own
  row or is covered by the list's comment.
- **Reversible:** yes.

### D15 — 2026-10-30 01:16, CP1b — Fix round 2's six routing findings; narrow "outside" and D12

- **Decided (orchestrator):** the worker fixes all six round-2 findings:
  (1) "outside" counts as a weather time word only next to the topic word
  ("temperature outside", "outside temperature", "raining/snowing outside"),
  so "what temperature is too cold to sleep outside" stays web with no
  location; (2) "right now", "now" and "later" end a weather place; (3) D12's
  "temperature in <place>" only when the question starts with the phrase
  ("what's the current temperature in …") and never before
  which/what/pronouns; (4) "is it supposed to / gonna / expected to rain",
  "chance(s) of rain/snow" are weather; (5) "temperature near me / in my area /
  around me" is weather, like "weather near me"; (6) "how to open/start/run/
  own/market a local <word>" isn't a nearby cue. Spec §6.1's overnight note is
  updated for (1), (3), (4), (6).
- **Why:** (1) and (6) newly sent the city off the Mac for questions that
  don't need it (privacy); (2)–(5) are concrete misroutes, several of them
  regressions from cc48a19 (reviewer round 2, 131-question probe).
- **Also logged:** the reviewer checklist's "needsLocation change is limited
  to local <place word>" isn't literally true: the location is also used, as
  intended, for "is it raining", the home/work/time weather questions (D7,
  D11), and "cafes near me open at lunch" (times are no longer a place),
  which CP1 had wrongly dropped.
- **Alternatives:** revert any of these rules in `LocationService.swift`.
- **Reversible:** yes.

### D16 — 2026-10-30 01:16, CP1b — Review round 3 runs; later misroutes go to CP7 unless they leak location

- **Decided (orchestrator):** round 3 runs because round 2 found real
  misroutes. Regex routing will always have another phrasing to find, so from
  round 3 on, a misroute that doesn't newly send the location off the Mac and
  isn't a plausible everyday question is recorded as a limitation for CP7's
  evaluation rather than fixed in a further round.
- **Why:** small-model routing is a heuristic; CP7 measures the places route
  on real questions. Usage budget matters for the remaining checkpoints.
- **Alternatives:** keep reviewing until a clean round.
- **Reversible:** yes.

### D17 — 2026-10-30 01:16, CP1b — Details of the round-2 fixes

- **Decided (worker CP1b):** (1) the business how-to veto also covers "how
  do i / do you / can i open|start|run|own|market"; (2) "temperature nearby"
  counts like "temperature near me"; (3) D12's place may not start with the,
  which, what, who, whom, a, an, me, us, them, this, that, these, those or a
  possessive; (4) "right now", "now" and "later" also end a holiday-like
  time ("sunset now"), the same stop list as the place; (5)
  `testLongDraftStaysFast` now uses "weather at home in the morning " ×
  2,800 + "in paris" (87K characters), so every candidate before "paris" is
  rejected and the loop runs to the end (0.036 s).
- **Why:** the orchestrator's D15 gives the examples; these are the
  obvious variants of the same phrasing.
- **Alternatives:** narrow the lists in `LocationService.swift`
  (`businessHowTo`, `bareWeatherTiming`, `temperatureInPlace`, `stopWords`).
- **Reversible:** yes.

### D18 — 2026-10-30 01:28, CP1b — Fix round 3's findings, plus "<city> weather today"; round 4 runs

- **Decided (orchestrator):** the worker fixes round 3's four findings:
  (1) "what's the current temperature", "what temperature is it (now)",
  "what's the temperature now/like" are weather with the location, and "what
  temperature is it in chicago" is weather for "chicago" (CP1b regressions);
  (2) a month or season after in/during ("paris in may", "rome in the
  summer", "weather in winter") makes the question background, so it goes to
  web, as D7's seasonal rows do; (3) "what's the weather(?)" is weather with
  the location (CP1 misroute of an everyday question); (4) rows that kill the
  two surviving mutants. Also (5): a city named just before "weather" with only
  a time after it ("nyc weather today", "london weather tomorrow") is weather
  for that city, not the current location.
- **Why:** (1) and (3) are everyday questions; (5) used the wrong city and
  sent the user's location off the Mac for a question naming another city
  (D16's privacy test), though it dates from CP1. Round 4 runs because these
  are real bugs (owner rule).
- **Alternatives:** leave (3) and (5) for CP7; revert in
  `LocationService.swift`.
- **Reversible:** yes.

### D19 — 2026-10-30 01:30, CP1b — Round-3 details: the city-before-"weather" rule, "temperature like", and a repointed test

- **Decided (worker CP1b):**
  1. D18's (5) is `LocationIntent.cityBeforeWeather`. It takes one to three
     words before "weather", followed only by today, tonight, tomorrow, this
     week, this weekend, (right) now or forecast, then punctuation. Every
     word must be outside `notACityWord`: local, my, current, the question
     words, about 20 weather adjectives including "nice" (so "nice weather
     today" isn't Nice, France), the seasons, and activity words such as
     marine, ski and golf. The words also can't be times, developer words,
     languages, home, work or school. `weatherPlace` returns this city
     first.
  2. "what's the temperature like" was in round 3's list but not in the
     reviewer's pattern, so `bareWeatherTiming` gains `temperature
     like(?= *(?:[?.!]|$))`.
  3. `WebSearchTests.testLocationCheckReadsTheQuestionWithoutCommands`
     pinned "What is the weather?" as conceptual. D18 makes it a here-and-now
     question, so the test now uses "What is weather?". It still checks that
     a command in front doesn't hide a conceptual question from the location
     check, so the test isn't weakened.
  4. "current weather today" is a row, rather than "current weather" alone:
     "current" isn't a now word, and adding it wasn't asked for.
  5. "swift weather app tomorrow" still routes to weather with the location
     (CP1 behavior). This is left for CP7 (D16).
- **Why:** these complete D18's examples without widening other rules.
- **Alternatives:** edit `notACityWord` or `cityWeatherPattern` in
  `LocationService.swift`; restore the old test wording if D18 (3) is
  reverted.
- **Reversible:** yes.

### D20 — 2026-10-30 01:42, CP1b — Fix round 4; anchor new weather patterns to the whole question; round 5 runs

- **Decided (orchestrator):** the worker fixes round 4's four findings:
  (1) the "current temperature / temperature now / temperature like / what
  temperature is it / outside temperature" patterns match only the whole
  question (so "how do i check my cpu's current temperature" stays web with no
  location), and `temperatureInPlace` allows "like / now / right now" before
  in/at/near; (2) "<city> weather" counts as fresh information, so automatic
  search still runs (fixed through `asksAboutWeatherNow`, which also covers
  "what temperature is it in chicago"); (3) descriptive words before
  "weather" (nearby, hourly, todays, area, regional, outdoor, hiking, humid,
  perfect, daily, weekly…) are never the city; (4) rows that kill the
  surviving mutants. Principle from here on: a new weather pattern for a bare
  topic word matches the whole question, not a phrase anywhere in it.
- **Why:** (1) was a location leak caused by round 3 (D16a); (2) and (3) are
  round-3 regressions on everyday questions. Real bugs, so round 5 runs (owner
  rule). D18's timestamp was corrected to 01:28 (it was written then; the
  entry had a wrong time).
- **Alternatives:** revert D18's city rule (`cityBeforeWeather` in
  `LocationService.swift`) instead of narrowing it.
- **Reversible:** yes.

### D21 — 2026-10-30 01:47, CP1b — Round-4 details

- **Decided (worker CP1b):**
  1. **New `temperatureNow`:** the reviewer's whole-question pattern is now
     its own regex. The anywhere-phrases were removed from
     `bareWeatherTiming`: current temperature, temperature (right) now,
     temperature like, what temperature is it, temperature (is it)
     outside, and outside temperature. "raining/snowing outside" and
     "temperature near me" stay there, and so does "right now" alone.
  2. **Possessive day words:** "todays", "tonights" and "tomorrows" join
     `asksAboutNow`. Without them "todays weather" has no now word.
  3. **Fresh information:** `WebSearchPolicy.needsFreshInformation` also
     returns true for `asksAboutWeatherNow`. This covers every named-place
     weather question, not only the city-before-"weather" ones.
  4. **Mutants:** "removing the lookaheads" no longer applies, since those
     lookaheads are gone. Its stand-in is removing `temperatureNow`'s `^`
     anchors, and that mutant is killed. "los angeles county fire weather"
     (web) kills the `{0,5}` mutant.
- **Why:** these complete D20's findings. Without (2), "todays weather"
  stays on the web route.
- **Alternatives:** the patterns in `LocationService.swift`, and the extra
  line in `WebSearchPolicy.needsFreshInformation`.
- **Reversible:** yes.

### D22 — 2026-10-30 01:58, CP1b — Fix round 5; regression-check every fix against the reviewers' 830-question probe; round 6 runs

- **Decided (orchestrator):** the worker fixes round 5's three findings:
  (1) a descriptive word rejects the city in "<city> weather" only as the
  first word ("bay area weather today" → "bay area", "boston hourly weather
  today" → "boston"), function words anywhere still reject it — this closes
  the location leak round 4 reintroduced; (2) the temperature patterns take
  repeated modifiers ("what's the temperature outside in london", "what is
  the current temperature outside now"); (3) web rows that kill the
  `temperatureNow` anchor mutants. Also: D21's wider fresh-information check
  skips developer questions ("what's the weather api for python"). Before
  reporting, the worker runs the reviewers' probe
  (`/private/tmp/claude-501/cp1b-review5-probe`) against cc48a19 and the
  current code, and fixes any change for a plausible question that isn't
  intended.
- **Why:** rounds 3–5 each found regressions caused by the previous round's
  fixes; a broad regression probe before review stops that cycle. (1) is a
  privacy leak; (2) are everyday questions.
- **Alternatives:** stop at round 5 and record the rest for CP7.
- **Reversible:** yes.

### D23 — 2026-10-30 02:03, CP1b — Round-5 details and fixes from the regression probe

- **Decided (worker CP1b):**
  1. **Splitting `notACityWord`.** It now has three lists:
     - `functionWord` rejects a city anywhere ("hows the weather");
     - `descriptiveWeatherWord` rejects it only as the first word;
     - `weatherModifier` (hourly, daily, weekly, regional, real-time, live,
       current, local, outdoor) is dropped from the end of a city, so
       "boston hourly weather" gives "boston" while "bay area" and "long
       beach" are kept whole.
  2. **Fresh-information exception.** D22's check uses
     `isAboutWeatherSoftware` (`isDeveloperQuestion` plus app(s) and
     widget(s)). It isn't applied inside `asksAboutWeatherNow`, because
     "swift weather today" must stay weather.
  3. **Fixes from the probe.** I ran the reviewers' probe against cc48a19
     and the current code, on about 740 questions, and fixed these
     unintended changes:
     - about 25 descriptive first words that became junk cities ("lovely",
       "camping", "world", "national", "react"…), plus "see" as a function
       word;
     - more developer words (project, elixir, kotlin, react, flutter,
       django…);
     - "local bar association" and "local bar exam" aren't nearby
       questions;
     - a language rejects a place only as the whole candidate, so "dutch
       harbor" and "latin america" are places again;
     - "temperature at the moment" is weather;
     - "temperature in" a common non-place (space, mars, refrigerator,
       oven, room, pool, body…) is web.
  4. **Probe result.** 249 questions differ from cc48a19 in route, location
     or place, and 25 more differ only in freshness. The rest are intended
     (spec §6.1, D7–D22) or left for CP7 (Hand-off, Limitations).
- **Why:** D22 asked for the regression check, and these were plausible
  questions newly misrouted by CP1b.
- **Alternatives:** the word lists in `LocationService.swift` and
  `SearchRouting.swift`.
- **Reversible:** yes.

### D24 — 2026-10-30 02:21, CP1b — Fix round 6's two location leaks and test gaps; round 7 is the last unless it finds a leak

- **Decided (orchestrator):** the worker fixes round 6's three findings:
  (1) "right now", "this weekend" and "this morning/afternoon/evening" make a
  bare topic word (temperature, rain, snow, umbrella) weather only as the
  whole question or when a place is found, so "my baby's temperature is 101
  right now" and "snow tires sale this weekend" stay web with no location
  (changes spec §6.1's time-word list and D21); (2) "forecast" counts as a
  "now" word only after "weather" or a topic word, or as a short whole
  question ("forecast", "10 day forecast"), so "sales forecast" and "how to
  forecast demand" no longer send the location (changes D9); (3) rows that
  kill the three surviving round-5 mutants. Round 7 then runs; after it,
  CP1b commits unless round 7 finds a location leak or a Blocker. Other
  misroutes go to CP7 (D16).
- **Why:** both are location leaks for everyday questions (health, shopping,
  business). Six rounds have each found new regex edge cases; the remaining
  ones are measured by CP7's evaluation, and the usage budget must cover CP2–
  CP10.
- **Alternatives:** keep reviewing until a clean round.
- **Reversible:** yes.

### D25 — 2026-10-30 02:21, all checkpoints — Hosted UI tests while the screen is locked

- **Decided (orchestrator):** the Mac's screen is locked overnight, so hosted
  UI tests that wait for a key window time out in the local full suite
  (round-6 reviewer saw `ComposerIntentChipsTests` do this). Each
  checkpoint's full-suite run still happens; key-window timeouts in tests
  that don't touch the checkpoint's code are recorded as environment failures,
  and GitHub Actions CI (which runs the full suite on every push to the PR) is
  the check for them. Any other failure blocks the commit.
- **Why:** the owner can't unlock the screen overnight; CI runs the same
  tests unattended.
- **Alternatives:** rerun the UI tests locally in the morning with the screen
  unlocked: `scripts/verify-xcode.sh test`.
- **Reversible:** yes.

### D26 — 2026-10-30 02:23, CP1b — Round-6 details

- **Decided (worker CP1b):**
  1. **"forecast" is a weather word in two cases.** It counts after a topic
     word ("weather/rain/snow/temperature forecast", `forecastAfterTopic`),
     or when it leads the question (`forecastAsWeather`): "what's the
     forecast for new york tomorrow", "10 day forecast", "check the
     forecast". It counts as a now word only after a topic word or as a
     short whole question (`shortForecastQuestion`). "local forecast" joins
     the nearby cues, so it still uses the location. A forecast-led
     question naming a non-place ("what is the forecast for q3 sales")
     still routes to weather with that junk place. It uses no location, and
     geocoding falls back to the web.
  2. **"nyc forecast", "vail snow this weekend", "seattle rain right now"
     and "miami temperature this weekend" go to web with no location.** I
     didn't extend the city-before-"weather" rule to topic words: "heavy
     rain today" would then name the city "heavy".
  3. **"this weekend", "right now" and parts of the day (`placedTime`)**
     count anywhere only when `weatherPlace` finds a place: "rain in
     seattle this weekend". Otherwise they need the whole question
     (`bareTopicNow`).
  4. **`ComposerIntentChipsTests`:** two hosted UI tests time out waiting
     for the key window while the screen is locked. They failed in the
     wider run and again when rerun alone.
     `testMainComposerShowsRecognizedCommandsAndDismissesThem` and
     `testShellChipFollowsTheDraftAndDismissingTurnsItOff` render chips for
     typed commands and don't touch routing, so they are recorded as
     environment failures under D25.
- **Why:** these complete D24 without adding new kinds of misroute.
- **Alternatives:** the patterns in `LocationService.swift`.
- **Reversible:** yes.

### D27 — 2026-10-30 02:34, CP1b — Round 7's leak fix, then a focused round 8

- **Decided (orchestrator):** the worker applies round 7's reviewer-verified
  fix: "forecast" leaves `nearbyCue` and "local" joins the forecast topic
  lists ("what's the local forecast for denver" is weather for denver, no
  location); "today's / tomorrow's / this weekend's forecast", "check / show
  me the forecast", "how's the forecast looking" and "forecast for this
  weekend" are weather with the location again; rows kill the four mutants
  that re-open round 6's leaks. Because round 7 found a leak (D24), a round 8
  runs, scoped to this fix only. CP1b commits after it unless it finds
  another leak or a Blocker.
- **Why:** owner rule — a real bug gets another round; the fix is small and
  already prototyped, so the round is narrow.
- **Alternatives:** skip round 8 (the reviewer's prototype passed the tests
  and the 738-question probe).
- **Reversible:** yes.

### D28 — 2026-10-30 02:38, CP1b — Round-7 details

- **Decided (worker CP1b):**
  1. **The reviewer's prototype minus `forecastLed`.** I applied D27's fix
     as the orchestrator listed it. I left out the prototype's extra
     `forecastLed` rule (a forecast-led question plus a found place), so
     "forecast for chicago" goes to web, as the round-7 brief records for
     CP7.
  2. **Mutants.** The four round-7 mutants were each killed in a scratch
     copy:
     - removing `forecastAsWeather`'s `^`;
     - letting `weatherWord` match "forecast";
     - removing `$` from `shortForecastQuestion`;
     - removing `$` from `bareTopicNow`.
  3. **Probe.** Against cc48a19, 98 questions newly use the location. All
     fall in categories D7–D26 accepted, and none changed since round 6:
     - "local <place word>", including the non-finding questions listed
       for CP7;
     - times, home, work and school;
     - the weather verbs;
     - "what's the weather" and the "temperature now" forms;
     - "todays weather";
     - the whole-question bare-topic times;
     - the "is it raining" questions listed for CP7.
- **Why:** D27's scope.
- **Alternatives:** add the prototype's `forecastLed` rule
  (`/private/tmp/claude-501/cp1b-review7-probe/fix2/LocationIntent.swift`).
- **Reversible:** yes.

### D29 — 2026-10-30 02:46, CP1b — Apply round 8's verified leak fix without a round 9, then commit

- **Decided (orchestrator):** the worker applies round 8's prototype
  (`/private/tmp/claude-501/cp1b-review8-probe/fixB/LocationIntent.swift`):
  for a forecast-only question, a home/work/school/time word after
  in/at/for/near counts as a time only when it stands alone, so "what's the
  forecast for home prices / school enrollment / thanksgiving sales" go to web
  with no location; adds "new year's eve/day". Rows pin it. No round 9: the
  round-8 reviewer prototyped this exact fix and showed it changes only those
  23 rows across the 738-question corpus, round 7's sets and every test row.
  The worker re-runs the probe to confirm, then runs the full suite, build and
  analyze, and CP1b commits.
- **Why:** a location leak (pre-dating round 7), fixed narrowly and already
  verified; eight rounds have used ~4% of the weekly budget, which CP2–CP10
  need.
- **Alternatives:** run a round 9 on this fix.
- **Reversible:** yes.

### D30 — 2026-10-30 02:58, CP1b — Round-8 port details

- **Decided (worker CP1b):**
  1. **Port.** I ported round 8's prototype. Its check goes after the
     `namedDestination` check in `needsLocation`, as in the prototype. My
     first attempt put it earlier, which broke "cafes near me", so it was
     moved.
  2. **"new year's eve/day."** As the orchestrator asked, "new year's
     eve/day" is now a near time, so "what's the forecast for new year's
     eve" uses the location. On the reviewer's 1,138 questions, this is the
     one row where my port differs from the prototype.
  3. **Probe.** On the 738-question corpus, no row changed since round 7.
     The corpus has no forecast-business questions, and the six new rows
     cover them.
- **Why:** D29's scope.
- **Alternatives:** drop "(?: eve| day)?" from `nearTime`.
- **Reversible:** yes.

### D31 — 2026-10-30 04:06, CP1b (and later checkpoints) — Stop the hung full-suite run; rerun with per-test time limits

- **Decided (orchestrator):** the local full suite hung for over 20 minutes on
  `LocalVisionTests.testGuidedDownloadViewShowsChoicesWithoutFilePickers` (a
  UI test, with the screen locked) after 895 tests. The orchestrator stopped
  that `xcodebuild` (PID 92305) and the worker reruns the full suite with
  `-test-timeouts-enabled YES -default-test-execution-time-allowance 60`, so a
  hung UI test fails after about a minute instead of stalling the run. Failures
  are then sorted by D25. Later checkpoints use the same flags for the full
  suite while the screen is locked.
- **Why:** the run can't finish otherwise; the flags only bound how long a
  test may run, they don't skip or weaken any test.
- **Alternatives:** run the full suite with the screen unlocked, without the
  flags (`scripts/verify-xcode.sh test`).
- **Reversible:** yes.

### D32 — 2026-10-30 04:18, CP1b — Full-suite failures sorted as environment failures (D25)

- **Decided (worker CP1b):** The full suite was run with
  `-test-timeouts-enabled YES -default-test-execution-time-allowance 60`
  while the screen was locked. 81 tests failed, in nine hosted-UI classes:
  - AppCommandTests 2
  - ChatCopyTests 2
  - ComposerIntentChipsTests 2
  - EnigmaCompactPanelTests 15
  - EnigmaConversationTests 18
  - EnigmaMainWindowTests 29
  - FileModeUITests 1
  - ScreenCaptureTests 1
  - ScreenViewTests 11

  None of these classes touch Search, routing or `LocationIntent`. 77
  failures are "Timed out waiting for visible control", or the shortcut
  test's "test host must be frontmost". I checked the other four
  separately:
  - `ScreenViewTests.testRepeatedScreenSubmissionsKeepFullPanelInsideWindow`
    asserts `window.isKeyWindow`;
  - `EnigmaMainWindowTests.testCharacterFallsFromTheWelcomeRatherThanJumping`
    and `testCharacterGlidesFromTheWelcomeHeroIntoTheStepHeader` sample an
    animation that draws no frames while the screen is locked;
  - all three fail the same way on a cc48a19 copy, made with `git archive`
    in a scratch folder;
  - `FileModeUITests.testMenuActivationPresentsPickerAndAllowsFileAndFolderSelection`
    hung, and the 60 s allowance killed it. Its class passes 18 of 18 when
    run alone on CP1b.

  So all 81 are recorded as environment failures for CI to check. Unlike
  D25's "rerun each alone", I didn't rerun them one by one (orchestrator,
  D31).
- **Why:** D25 and the orchestrator's policy for this run. CP1b changes
  only `LocationService.swift` (`LocationIntent`), `SearchRouting.swift`
  and `WebSearchPolicy.swift`, and their tests.
- **Alternatives:** rerun `scripts/verify-xcode.sh test` with the screen
  unlocked in the morning.
- **Reversible:** yes.

### D33 — 2026-10-30 04:25, CP2 — The owner's lineup applied: what CP2 skips

- **Decided (worker CP2):** following CP0b's owner row, CP2 skips Task 2.3
  (Mojeek) and Task 2.4 (Startpage) entirely: no `MojeekEngine.swift` or
  `StartpageEngine.swift`, no `.mojeek` or `.startpage` case in
  `SearchEngineID` (it keeps only `.duckDuckGo`), none of their tests, live
  checks (`testLiveMojeek`, `testLiveStartpage`) or `UPSTREAM.json` entries.
  Task 2.7 drops the Startpage rule and `SearchSiteRunner.startpageBudget`:
  the runner queries DuckDuckGo and, when asked, Wikipedia, and nothing else.
  Its three Startpage tests are replaced by tests of the same rules that still
  apply (a cooling-down site is skipped, a timeout is a failure, enough
  results need no backup). Without the live variable, 2 tests skip, not 4.
- **Why:** owner decision of 2026-10-29 (CP0b Hand-off): both sites refused
  every request on two networks; the brief says to skip a dropped site's
  tasks.
- **Alternatives:** if a second index is found later, add its `SearchEngineID`
  case, its engine file and its `UPSTREAM.json` entry; the runner already
  runs every engine it is given at once.
- **Reversible:** yes.

### D34 — 2026-10-30 04:25, CP2 — Header set A splits `SafariHeaders` into GET and form-POST headers

- **Decided (worker CP2):** header set A (owner, CP0b) differs between GET
  and POST, so `SafariHeaders.standard(acceptLanguage:)` gives the GET set
  (User-Agent, Accept, Accept-Language, `Sec-Fetch-Dest: document`,
  `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Site: none`, `Priority: u=0, i`),
  and a new `SafariHeaders.formPost(to:acceptLanguage:)` adds
  `Sec-Fetch-Site: same-origin`, `Origin: <scheme>://<host>` and
  `Referer: <scheme>://<host>/`, exactly the values CP0 and CP0b measured for
  DuckDuckGo (`https://html.duckduckgo.com`, `https://html.duckduckgo.com/`).
  DuckDuckGo's form sends `kl`, not `l` (owner, CP0b).
- **Why:** the brief's interface has one `standard` set (set B's fields);
  set A needs the method-specific fields. No header beyond set A is sent
  (owner rule).
- **Alternatives:** set B is `standard` without `Priority` and with
  `Sec-Fetch-Site: none` everywhere (in `SearchHTTPClient.swift`).
- **Reversible:** yes.

### D35 — 2026-10-30 04:25, CP2 — DuckDuckGo gets its own region codes

- **Decided (worker CP2):** `SearchRegion.code` stays `<country>-<language>`
  ("us-en") as the brief says, but DuckDuckGo's `kl` comes from
  `DuckDuckGoEngine.regionCode(for:)`, a table of DuckDuckGo's own region
  values (the list `duckduckgo_search` documented): Britain is `uk-en`, Japan
  `jp-jp`, Korea `kr-kr`, Taiwan `tw-tzh`, Canada `ca-en`/`ca-fr` by
  language, and so on. A country DuckDuckGo doesn't list sends `wt-wt` (all
  regions), which is what every search got before `kl` (CP0b Q2).
- **Why:** `kl` only localizes when the value is one DuckDuckGo knows; plain
  ISO codes such as `gb-en` or `ja-jp` aren't. For a US user nothing changes
  (`us-en`).
- **Alternatives:** send `SearchRegion.code` as is (one line in
  `DuckDuckGoEngine.request`).
- **Amended by D42:** the table is now rebuilt from DuckDuckGo's own
  region menu, so the codes and examples above are partly superseded.
- **Reversible:** yes.

### D36 — 2026-10-30 04:25, CP2 — One extra live request to find DuckDuckGo's "no results" marker

- **Decided (worker CP2):** besides the brief's live check, send DuckDuckGo
  one search for a quoted nonsense phrase, at least 30 s after the live
  check, to see the page it returns when nothing matches. The parser treats
  a `no-results` class or the text "No results." as `.noResults`; if the
  probe returns such a page, a sanitized copy becomes the
  `duckduckgo-no-results.html` fixture, otherwise the fixture is synthetic
  and this stays unverified.
- **Why:** CP0 found no real marker (its nonsense query got fuzzy results).
  With DuckDuckGo the only web index, mistaking an empty search for a layout
  change would log a false alarm and put DuckDuckGo in a 1-minute cooldown,
  leaving the next searches with Wikipedia alone.
- **Alternatives:** skip the probe and keep the synthetic fixture.
- **Reversible:** yes.
- **Outcome (worker CP2, 04:37):** the probe ran once, about 13 s after the
  live check's DuckDuckGo request rather than the planned 30 s (the script
  started sooner than expected); HTTP 200, 9.4 KB, 722 ms, no challenge. The
  page has one `result--no-result` item holding a `no-results` message and
  no link; neither "No results." spelling appears. It is saved as
  `duckduckgo-no-results.html` (it holds only the nonsense query; no token,
  address or region data). So the parser reads `no-results` /
  `result--no-result` as an empty search, and a page whose items all lack a
  usable link is `.unrecognized` (a layout change), not `.noResults`; a page
  of nothing but ads is `.noResults`.

### D37 — 2026-10-30 04:25, CP2 — Runner and health details the brief leaves open

- **Decided (worker CP2):**
  1. A site skipped because it is cooling down is not recorded again, and a
     run cancelled from outside (Stop) records nothing, so neither lengthens
     the cooldown.
  2. A failure recorded while the site is already cooling down doesn't climb
     the ladder (two searches failing together count once).
  3. `EngineHealth.reservePacingSlot(_:)` (new) returns the wait and books
     the slot in one actor call, so two searches started together are still
     paced; `pacingDelay(_:)` stays as the read-only query. The pacing wait
     happens before the 2.0 s request timeout starts.
  4. Wikipedia isn't tracked by `EngineHealth` (it has no `SearchEngineID`,
     as in the brief); it gets the same 2.0 s timeout.
  5. An unrecognized page's status and size reach `SearchLogging` through a
     small wrapper around the HTTP client, so `EngineOutcome` stays as the
     brief defines it.
- **Why:** these keep the backoff from punishing DuckDuckGo for things that
  aren't its fault, which matters more now it is the only web index.
- **Alternatives:** record every outcome literally (edit `SearchSiteRunner.run`
  and `EngineHealth.recordFailure`).
- **Reversible:** yes.

### D38 — 2026-10-30 04:25, CP2 — Result count: DuckDuckGo's first page only, page 2 ported but unused

- **Decided (worker CP2):** a search asks DuckDuckGo for its first page
  (about 10 results) and Wikipedia for 3 hits (`srlimit=3`), as the brief
  says. `DuckDuckGoEngine.request(for:page:)` also ports ddgs's page field
  (`s = 10 + (page − 2) × 15`), default page 1, so CP3 or CP7 can try a
  second page if the evaluation shows more results help. Nothing calls it
  with page 2 yet.
- **Why:** owner allows more results if they measurably help, but a second
  page doubles DuckDuckGo requests per search and the bot check (HTTP 202)
  already answers about 1 in 4; that needs measuring, not guessing.
- **Alternatives:** call page 2 from the runner (one more request per search,
  log it first).
- **Reversible:** yes.

### D39 — 2026-10-30 04:35, CP2 — Which 30 Wikipedia editions count as "the largest"

- **Decided (worker CP2):** `WikipediaSearch.editions` is 30 large editions
  by article count, leaving out the mostly bot-generated ones (Cebuano,
  Waray, Egyptian Arabic, Chechen, Tatar, South Azerbaijani) and adding the
  next largest instead (Hebrew, Romanian, Danish, Basque, Armenian). macOS's
  Norwegian Bokmål and Nynorsk (`nb`, `nn`) use the `no` edition. Any other
  language uses English, as the brief says.
- **Why:** the brief says "the 30 largest editions"; a bot-generated edition
  is large but mostly stub articles, so a user of that language gets better
  facts from English.
- **Alternatives:** edit the set in `WikipediaSearch.swift`.
- **Reversible:** yes.

### D40 — 2026-10-30 04:35, CP2 — Work around an NSXMLNode XPath bug for `//text()`

- **Decided (worker CP2):** `SERPDocument.text` keeps ddgs's XPath strings
  verbatim, but for a path ending in `//text()` it lets XPath select the
  elements (`./a`, `.//h2`) and collects their descendant text nodes itself.
- **Why:** found while testing, on the synthetic `duckduckgo-ads.html`:
  there `./a//text()` evaluated on one result also returns the text of every
  later result's links (`./a/descendant::text()` too, even after re-parsing
  without tidy), so each snippet ran on into the next results. *Corrected
  after review round 1:* on the real `duckduckgo-results.html`, plain XPath
  and the workaround give identical text, so the bug doesn't show on that
  page, and only `testDuckDuckGoDropsAds` guards the workaround. It is kept
  because the cause isn't understood and a real page could trigger it.
- **Alternatives:** none that keep `XMLDocument`; a different parser
  (SwiftSoup) would be a new dependency.
- **Reversible:** yes.


### D41 — 2026-10-30 04:48, CP2 — Only real block signs start DuckDuckGo's cooldown; a lone 202 doesn't

- **Decided (orchestrator):** amends D37 and overrides brief Task 2.7's
  "timeouts included" (marked "Amended overnight" in the brief): a timeout or
  transport error (`.failed`) records nothing in `EngineHealth`; only
  `.blocked`, `.unrecognized` and a **second consecutive** `.rateLimited`
  (HTTP 202 challenge) start or climb the 60 s → 3,600 s ladder. A single 202
  marks a pending strike that the next success clears.
- **Why:** spec §2's block signs don't include timeouts. DuckDuckGo is the
  only web index, so a wake-from-sleep network error or a slow network would
  otherwise leave searches on Wikipedia alone for 1–60 minutes. CP0 and CP0b
  saw HTTP 202 on one query every time (5 of 5, two networks) and never on
  the other queries (0 of 15), so one 202 is usually about that query, not the
  network; at most one more request reaches DuckDuckGo before the ladder
  starts (reviewer round 1, finding 1).
- **Alternatives:** brief Task 2.7 as written (every failure climbs the
  ladder), or a 202 starting it at once — in `SearchSiteRunner.swift` /
  `EngineHealth`.
- **Reversible:** yes.

### D42 — 2026-10-30 04:48, CP2 — Region codes from DuckDuckGo's own list

- **Decided (orchestrator):** DuckDuckGo's `kl` table is rebuilt from the
  `<select name="kl">` options in the captured `duckduckgo-no-results.html`
  (replacing ten codes DuckDuckGo doesn't list, adding `is-is` and
  `pk-en`), with a test that every code the table sends is in that list.
  Amends D35.
- **Why:** codes DuckDuckGo doesn't know give unlocalized or odd results
  (reviewer round 1, finding 4).
- **Alternatives:** D35's table as first built (`DuckDuckGoEngine.swift`).
- **Reversible:** yes.

### D43 — 2026-10-30 04:50, CP2 — Round-1 fix details

- **Decided (worker CP2):**
  1. D41's strike is `EngineHealth.recordRateLimited(_:)`: a pending strike
     per site, cleared by `recordSuccess`, turned into a `recordFailure`
     by the next `.rateLimited`. A strike has no time limit: two 202s an
     hour apart with no success between them still start the ladder.
  2. The client exposes `configuration` (the session's own copy) so
     `testSessionStoresNothing` can check the cookie, cache and credential
     settings.
  3. After the pacing wait the runner checks `isCoolingDown` again and, if
     so, returns `.failed` and records nothing.
  4. D42's table (63 codes in DuckDuckGo's menu): the ten codes it doesn't
     list are replaced or dropped. United Arab Emirates and Venezuela now
     get `wt-wt`. Indonesia, Israel, Malaysia, the Philippines, Thailand and
     Vietnam get their only listed code, the English one. Spain's Catalan
     is `es-ca`, and the US's Spanish is `us-es`. Iceland (`is-is`) and
     Pakistan (`pk-en`) are added; Catalonia's separate `ct-ca` isn't a
     country, so it isn't used.
- **Why:** D41 and D42's scope.
- **Alternatives:** a strike that expires after a set time
  (`EngineHealth`); the table in `DuckDuckGoEngine.swift`.
- **Reversible:** yes.


### D44 — 2026-10-30 04:51, CP1b (CI) — A flaky CI test re-run, not changed

- **Decided (orchestrator):** CI on c90ecf3 failed one test,
  `ScreenViewTests.testLongScreenSearchConversationSettlesAtBottom` (a
  5 s UI wait timed out); every other test passed and `main`'s last three
  runs passed. The failed job was re-run once and passed, so the test was
  treated as flaky and left unchanged. Log:
  `/private/tmp/claude-501/f29-overnight/ci-c90ecf3.log` (outside the repo).
- **Why:** a re-run passing on the same commit shows a timing flake, not a
  CP1b regression; CP1b doesn't touch that view.
- **Alternatives:** lengthen that test's wait in `EnigmaTests/ScreenViewTests.swift:502`
  if it flakes again.
- **Reversible:** yes.

### D45 — 2026-10-30 05:00, CP2 — A challenged query sits out alone; two different challenged queries cool the site down

- **Decided (orchestrator):** amends D41/D43. A 202 (or 429) for a query puts
  that query's in-memory fingerprint (`query.text.hashValue`, seeded per
  launch, never logged or stored) in a short per-query skip for the first
  ladder step (60 s): retrying the same query in that window skips DuckDuckGo
  without sending a request and without climbing the ladder. A 202/429 for a
  **different** query while a strike is pending starts the site-wide ladder. A
  success clears the strike. 429 shares the 202 rule.
- **Why:** round 2 showed that retrying the challenged query (a regenerate, or
  a model calling `web_search` again) gave the second 202 in a row and cooled
  DuckDuckGo down for every query. Skipping the challenged query alone keeps
  other searches on DuckDuckGo and stops re-sending a request DuckDuckGo just
  challenged (more polite than the reviewer's "retry it anyway").
- **Alternatives:** D41 as built (any second 202 cools down), or the
  reviewer's version (same-query 202s never climb) — `EngineHealth` in
  `SearchEngine.swift`.
- **Reversible:** yes.

### D46 — 2026-10-30 05:02, CP2 — Round-2 fix details (the per-query strike)

- **Decided (worker CP2):**
  1. `EngineHealth.recordRateLimited(_:query:)` takes the fingerprint, and
     the new `isSkipped(_:query:)` is true while that query sits out. The
     runner computes `query.text.hashValue` once and checks the skip before
     booking a pacing slot, so a skipped query neither waits nor sends.
  2. The same query challenged again after its minute renews its own
     strike and skip without climbing the ladder. Only a different query's
     challenge, while a strike is pending, starts the ladder. A strike has
     no expiry for that rule (as D43).
  3. Only one strike is kept per site: a new challenge replaces it.
  4. The tests drive time through `TestInstant`, which is `EngineHealth`'s
     injected clock, not `ManualClock`: the minute is measured by
     `EngineHealth`, which never sleeps.
- **Why:** D45's scope.
- **Alternatives:** expire the strike after the skip window; `EngineHealth`
  in `SearchEngine.swift`.
- **Reversible:** yes.


### D47 — 2026-10-30 05:08, CP2 — Round 3's fixes, then commit without a round 4

- **Decided (orchestrator):** the worker fixes round 3's three findings:
  (1) after the pacing wait the runner re-checks the per-query skip as well as
  the cooldown; (2) an unexpected 3xx, 400, 403, 404, 405 or 410 from
  DuckDuckGo is `.unrecognized` (logged with status and size, climbs the
  ladder) — a sign the port needs updating — while 413/414 (query too long)
  and 5xx stay `.failed` but are logged with their status; (3) a per-query
  skip returns `.rateLimited` (recording nothing), so CP5 shows "limiting
  requests" rather than a connection error. Amends the brief's "anything else
  → `.failed`" row (marked "Amended overnight") and D41. Rows also kill the
  two surviving mutants. No round 4: each fix is small and comes with the
  reviewer's own failing test; the worker reruns the CP2 classes, the live
  check, build, analyze and the full suite before the commit.
- **Why:** concrete failures from round 3; three rounds done; usage budget
  for CP3–CP10.
- **Alternatives:** a round 4 on these fixes.
- **Reversible:** yes.

### D48 — 2026-10-30 05:11, CP2 — Round-3 fix details

- **Decided (worker CP2):**
  1. D47 lists 403 among the statuses that become `.unrecognized`, but the
     brief's outcome table and spec §2 make 403 and 503 a block (`.blocked`)
     and `testDuckDuckGoBotCheckIsBlocked` pins it. 403 and 503 stay
     `.blocked`. That climbs the ladder too; the only difference is that
     they aren't logged as unrecognized. All 3xx, plus 400, 404, 405 and
     410, are `.unrecognized`. Every other non-200 status (413, 414, 5xx,
     other 4xx) is `.failed` and logged.
  2. The status of a `.failed` page is logged through a new
     `SearchLogging.failedPage(engine:status:bytes:)`, at error level like
     `unrecognizedPage`, with site, status and size only. It is logged only
     when a response arrived; a thrown error or timeout logs nothing.
  3. Both skip checks (before booking the pacing slot, and after the wait)
     return `.rateLimited` and record nothing. A cooldown found after the
     wait still returns `.failed`.
- **Why:** D47's scope, without weakening the brief's block rows or their
  test.
- **Alternatives:** treat 403 as `.unrecognized` too (one `case` in
  `DuckDuckGoEngine.parse`, and the test changed with the owner).
- **Reversible:** yes.

### D49 — 2026-10-30 05:28, CP3 — The unsafe lists don't fit 3 MB: a keep order, malware dropped first

- **Decided (worker CP3):** `unsafe.bin` is filled in this keep order until
  the 3 MB folder budget is reached: the Block List Project's scam list, its
  fraud list, its phishing list, Phishing.Database's active domains, then its
  malware list. The budget step drops from the end of that order (malware
  first, then Phishing.Database, as the brief says, then phishing, then
  fraud; scam is never dropped), and within a list being trimmed it keeps
  whole domains before subdomains (fewest labels, then shortest, then
  alphabetical). Before trimming, a domain whose parent (at or below the
  registrable domain) is already listed is removed, since the lookup finds
  the parent anyway. The manifest records `dropped` per source. The 3 MB
  budget is unchanged; 16 KB of it is left free when filling `unsafe.bin`,
  so hand edits to the curated files don't push the folder over. Result on
  today's lists: scam, fraud and phishing in full; 65,586 of
  Phishing.Database's and 64,305 of malware's domains still covered.
- **Why:** measured on today's pinned copies: Block List Project malware has
  2,656,393 domains (21 MB as hashes, seven times the whole budget),
  Phishing.Database 392,163, fraud 285,200, phishing 190,215, scam 8,527.
  The brief's rule (drop Phishing.Database until it fits, else fail) can
  never pass with the malware list in. Malware-distribution hosts rarely
  appear as search results; fake shops, investment fraud and tech-support
  scams do, so fraud and scam are kept first. The budget wasn't raised
  because it's the spec's app-size limit.
- **Alternatives:** raise `BUDGET_BYTES` (spec §3.6, `scripts/update-search-lists.py`)
  to keep everything (about 27.5 MB) or everything but malware (about 7 MB);
  or reorder `UNSAFE_KEEP_ORDER` in the same script and rerun it.
- **Reversible:** yes.

### D50 — 2026-10-30 05:28, CP3 — Reading Wikipedia's Perennial sources

- **Decided (worker CP3):** the main page's wikitext holds no rows; it
  transcludes eight subpages (`…/Perennial sources/1` to `/8`). The script
  fetches the main page (the brief's URL), finds the transcluded subpages and
  fetches each the same way; the manifest's version lists every revision ID.
  Status per row comes from `{{WP:RSPSTATUS|…}}`: `b=y` (on Wikipedia's spam
  blacklist) gives `b` whatever the base status; `m` (no single status) rows
  are skipped and counted. Domains come from `{{WP:RSPUSES|…}}`; entries with
  a path are skipped and counted. A domain listed by several rows with
  different statuses gets `nc` (no adjustment), unless every row is `d` or
  `b`, which gives `b` if any row is `b`, else `d`.
- **Why:** blocking or boosting a domain on one row while another row says
  otherwise (for example a site rated differently by topic or period) would
  be a guess; `nc` is neutral.
- **Alternatives:** take the most severe status per domain (one function,
  `merge_statuses`, in the script).
- **Reversible:** yes.

### D51 — 2026-10-30 05:28, CP3 — A list that shrinks by more than half counts as a parse failure

- **Decided (worker CP3):** besides a download or parse error, a source
  counts as failed (its previous file is kept, exit status 1) when it parses
  to no entries, or to fewer than half the entries the previous manifest
  recorded for it.
- **Why:** a silent format change (a renamed template, a list moved to a new
  path) usually parses to almost nothing rather than raising, and would ship
  an empty block list.
- **Alternatives:** drop the check (`check_shrink` in the script).
- **Reversible:** yes.

### D52 — 2026-10-30 05:28, CP3 — `authority.txt` and `unreadable.txt` drafted without the owner's approval

- **Decided (worker CP3):** the brief needs the owner's approval of both
  drafts before the commit; the owner is asleep. The worker drafts them from
  spec §3.3, leaning (as the owner asked) toward authoritative health,
  finance and developer-documentation sources: the spec's suffixes and
  domains plus national government suffixes, health bodies and journals,
  financial regulators and central banks, and official language and platform
  docs. `unreadable.txt` is the spec's nine plus Pinterest's country domains
  and Threads. Both are marked for owner review in the Hand-off.
- **Why:** the run can't wait for the owner; both files are plain text the
  owner can edit, and the factors are CP7's to tune.
- **Alternatives:** the spec's lists only (delete the added lines).
- **Reversible:** yes.

### D53 — 2026-10-30 05:28, CP3 — Ranking tuning in one place; ties favour trust

- **Decided (worker CP3):** every ranking number (engine weights, the four
  trust factors, the 15% cut-off, the read batch of 6) lives in
  `RankingTuning` in `ResultRanking.swift`; `DuckDuckGoEngine.weight` reads
  it. When two candidates score the same after trust factors, the one with
  the higher trust factor goes first, then the better position, then the URL
  key, so the order is stable and authority wins ties.
- **Why:** CP7 tunes these; the owner wants authority favoured where the
  brief leaves room. Recency can't be used here: DuckDuckGo's HTML results
  carry no dates; CP4/CP5's stale check covers it.
- **Alternatives:** score-only order (one comparator in `ResultRanking.select`).
- **Reversible:** yes.

### D54 — 2026-10-30 05:41, CP3 — Authority domains match on the host; the settings load the lists lazily

- **Decided (worker CP3):**
  1. An `authority.txt` domain matches the host and any subdomain of it,
     not just the domains down to the registrable domain as blocks do:
     `nhs.uk` is itself a public suffix, so `www.nhs.uk` is its own
     registrable domain and the brief's lookup never reached `nhs.uk`.
  2. `WebSearchSettings`'s `publicSuffixes` parameter is an
     `@autoclosure` (same call sites, same default), resolved on the first
     `block(_:)`, so creating `WebSearchSettings.shared` at launch doesn't
     load the 3 MB of lists (about 31 ms in a release build, measured).
- **Why:** found by checking the real data: `https://www.nhs.uk/…` scored
  1.0 instead of 1.3. The owner's product is low-latency; the lists are
  only needed when a search runs or a site is blocked.
- **Alternatives:** the brief's plain parameter (`WebSearchSettings.swift`),
  and candidate-only matching for authority (`SourceQuality.isAuthority`).
- **Reversible:** yes.


### D55 — 2026-10-30 05:43, CP3 — Keep Wikipedia, Stack Overflow, Healthline and MSN usable

- **Decided (orchestrator):** the real lists down-weight `wikipedia.org`,
  `stackoverflow.com` and `investopedia.com` to 0.5 (Wikipedia's Perennial
  sources mark them "generally unreliable" — as *citations inside Wikipedia*),
  and block `msn.com` and `healthline.com`. A small, reviewed override file
  in `SearchData/` (bundled, documented in the manifest) sets Wikipedia, Stack
  Overflow/Stack Exchange sites and Investopedia to the neutral 1.0 factor, and
  un-blocks `msn.com` (a news syndicator) and `healthline.com` unless they are
  on a security (unsafe/phishing/malware) list — overrides never lift a
  security block. The worker checks which list blocks each and records it.
- **Why:** the Perennial-sources rating judges citations in encyclopedia
  articles, not answers to search questions; Stack Overflow is the main source
  for developer questions, Wikipedia is a core factual source, and blocking a
  major health site and a major news aggregator would hurt the owner's
  health and news categories. CP7 measures the effect.
- **Alternatives:** take the lists as they are (delete the override file).
- **Reversible:** yes.

### D56 — 2026-10-30 05:44, CP3 — What blocks MSN and Healthline, and how D55's overrides work

- **Decided (worker CP3):**
  1. **What blocks them** (today's pinned copies):
     - `msn.com`: popcar2/BadWebsiteBlocklist (commit 8c1cee4), line 25,
       `*://*.msn.com/*`, under its "Low Effort Articles (AI spam,
       copy-pasting other articles, etc)" heading → `spam.bin`. No unsafe
       list holds `msn.com` itself, but the Block List Project's malware
       list holds five of its subdomains (`0.r.msn.com`, `ac2.msn.com`,
       `anrfrm.msn.com`, `unicast.msn.com`, `zone.msn.com`); those stay
       blocked. *Corrected by D60:* as first built, D49's budget trim had
       dropped them from `unsafe.bin`, so the override did unblock them;
       the refresh script now always keeps unsafe entries under an `allow`
       domain.
     - `healthline.com`: Wikipedia's Perennial sources, subpage 4, row
       `id="Healthline"`, `{{WP:RSPSTATUS|d|b=y}}` (deprecated and on
       Wikipedia's spam blacklist) → `reliability.tsv` status `b`. No
       unsafe or spam list holds it.
  2. **`overrides.tsv`** (hand-curated, bundled, never regenerated; listed
     under the manifest's new `curated` key with its entry count and
     SHA-256): `domain<TAB>neutral` ignores the Perennial status (factor 1.0
     from reliability) for that domain and its subdomains; `domain<TAB>allow`
     lifts a spam-list or Perennial `d`/`b` block for it (and, like
     `neutral`, ignores its Perennial status). Entries: neutral
     for wikipedia.org, stackoverflow.com, stackexchange.com, superuser.com,
     serverfault.com, askubuntu.com, investopedia.com; allow for msn.com and
     healthline.com.
  3. An override never lifts an `unsafe.bin` block, the user's own block or
     an `enigma-blocked.txt` entry, and leaves the authority and unreadable
     factors alone. A missing `overrides.tsv` loads as no overrides (the
     lists then apply as they are).
- **Why:** D55's scope; the narrowest change that keeps the security lists
  authoritative and the user's choices final.
- **Alternatives:** delete `overrides.tsv` (lists as they are), or also let
  `allow` lift `enigma-blocked.txt` (`SourceQuality.isBlocked`).
- **Reversible:** yes.


### D57 — 2026-10-30 05:59, CP3 — More overrides: crowdfunding/petition sites readable, preprints and AWS docs not penalised

- **Decided (orchestrator):** extends D55/D56. `overrides.tsv` adds `allow`
  for kickstarter.com, gofundme.com, indiegogo.com, change.org and lulu.com
  (blocked only because Wikipedia's link-spam blacklist flags them, `gu|b=y`);
  `neutral` for arxiv.org, biorxiv.org, medrxiv.org and aws.amazon.com, so
  their authority bonus isn't cancelled by a "generally unreliable" rating on
  the preprint row or on amazon.com; and academia.edu loses the `.edu`
  authority bonus (it's a commercial site). D50's mapping of `gu|b=y` to
  blocked stays for everything else (naturalnews.com, globalresearch.ca…).
  Security blocks are still never lifted.
- **Why:** reviewer round 1: questions about a named campaign or petition
  could never read its page; arXiv (named as research authority in spec §3.3)
  and AWS docs ranked below an unknown blog.
- **Alternatives:** map `gu|b=y` to `gu` in `scripts/update-search-lists.py`
  (also unblocks misinformation sites), or let authority override a parent's
  rating in `SourceQuality.swift`.
- **Reversible:** yes.

### D58 — 2026-10-30 06:00, CP3 — Round-1 fix details

- **Decided (worker CP3):**
  1. D57's entries go into `overrides.tsv` (`allow` for the five
     crowdfunding/petition sites; `neutral` for arxiv.org, biorxiv.org,
     medrxiv.org and aws.amazon.com). biorxiv and medrxiv aren't added to
     `authority.txt`, so they get 1.0, not 1.3.
  2. academia.edu loses the `.edu` bonus through a new exclusion line in
     `authority.txt`: `!academia.edu` (PSL-style; it covers subdomains and
     wins over any suffix or domain rule). `SearchDataBundle` gains
     `authorityExclusions` (default empty, so existing initializers still
     compile).
  3. `URLNormalizer.key`: `/amp` matched case-sensitively; only `amp=1` and
     `outputType=amp` dropped (names and the value `amp` compared without
     case); a `www.`/`m.`/`mobile.`/`amp.` prefix is stripped only when what
     remains still contains a dot (`mobile.de` keeps its host).
- **Why:** reviewer round 1 findings 1, 2 and 4, within D57.
- **Alternatives:** a separate `authority-exclusions.txt` file; or keep the
  looser key (more merges, some wrong).
- **Reversible:** yes.


### D59 — 2026-10-30 06:14, CP3 — Keep security entries under allowed domains; no round 3; cut-off left for CP7

- **Decided (orchestrator):** (1) the refresh script always keeps unsafe-list
  entries that are an `allow` domain or its subdomain when trimming to the
  budget (like `NEVER_DROPPED`), so the five malware-listed msn.com hosts are
  blocked again; a Python test and a bundled-data Swift assertion
  (`zone.msn.com` is blocked) pin it, and D56/the Hand-off wording is
  corrected. No round 3: the fix is narrow and the reviewer's own failing
  check becomes the regression test. (2) The 15% cut-off stays for now; with
  DuckDuckGo alone it keeps about 6–8 results, which leaves CP5's "read 6,
  refill" step little to refill from — CP5 keeps the cut-off in
  `RankingTuning` and CP7 measures a lower one (0.05–0.08) against the
  owner's "more pages read". (3) Blogs on `blogspot.com` (a public suffix)
  get 1.0 while `*.wordpress.com` blogs get 0.5 — noted for CP7.
- **Why:** (1) restores D55's promise that an override never lifts a
  security block (reviewer round 2); (2)/(3) are tuning questions CP7
  measures.
- **Alternatives:** lower the cut-off now (`RankingTuning` in
  `ResultRanking.swift`).
- **Reversible:** yes.

### D60 — 2026-10-30 06:14, CP3 — Round-2 fix details

- **Decided (worker CP3):** `run` reads the `allow` domains from the output
  folder's `overrides.tsv` (missing or unreadable: none) and passes them to
  `fit_unsafe`, which puts every unsafe-list entry equal to an allowed
  domain or under it into `unsafe.bin` before the keep order, never
  dropping them; if those alone exceed the budget the script fails. The
  lists are regenerated with `--sources` from the cached copies of
  2026-10-30 (same pins, renamed to the script's file names in a scratch
  folder), so nothing new is fetched; the manifest's `fetched` dates become
  the regeneration date, as for any `--sources` run.
- **Why:** D59 (reviewer round 2): the trim had dropped the five
  malware-listed msn.com hosts, so `allow msn.com` unblocked them.
- **Alternatives:** have the app ignore `allow` for any host below the
  allowed domain (would also re-block legitimate msn.com subdomains on the
  spam list).
- **Reversible:** yes.


### D61 — 2026-10-30 06:32, CP4 — Readability sits in `SearchData/readability/`, outside the lists' 3 MB budget

- **Decided (worker CP4):** Readability.js 0.6.0, `Readability-readerable.js`,
  its `LICENSE.md`, a `README.md` with the SHA-256 values and Enigma's
  `EnigmaExtract.js` go in `Enigma/Resources/SearchData/readability/`, as the
  brief says (about 100 KB). The lists already use 3,129,228 of the
  3,145,728 bytes, so the scripts can't share that budget.
  `testBundledDataLoads` and `scripts/update-search-lists.py` count only the
  folder's top-level files, so the budget stays the lists' budget (spec §3.6
  is titled "The bundled lists"). The files are checked against the tag
  (commit `04fd32f7`) two ways: a raw download and a shallow clone gave the
  same SHA-256, matching CP0's copy byte for byte.
- **Why:** the brief fixes the location; shrinking `unsafe.bin` by 100 KB
  would drop about 12,000 malware domains for no gain.
- **Alternatives:** move the scripts to their own folder reference
  (`Enigma/Resources/Readability/`, one project entry), or rerun the list
  script with 100 KB more headroom.
- **Reversible:** yes.

### D62 — 2026-10-30 06:32, CP4 — More date sources, a modified date, and a plausibility check

- **Decided (worker CP4):** the owner wants recency, so `EnigmaExtract.js`
  collects date candidates beyond spec §4's three, in this order:
  `article:published_time` (property or name), JSON-LD `datePublished`
  (string scan of the page HTML passed in as an argument, CP0 Q2; `@graph`
  and arrays walked, article types first), `dateCreated`, Readability's
  `publishedTime`, `itemprop="datePublished"`, `parsely-pub-date`,
  `sailthru.date`, `dc.date`/`dcterms.created`/`dc.date.issued`, `date`,
  `pubdate`, `publish-date`, `time[pubdate]`, and the first `time[datetime]`.
  Modified dates (`article:modified_time`, `og:updated_time`, JSON-LD
  `dateModified`, `itemprop="dateModified"`, `last-modified`) are collected
  separately. The JSON keys are `publishedTimes` and `modifiedTimes`
  (arrays of raw strings) instead of the brief's single `publishedTime`;
  Swift parses them (ISO 8601 with and without time, offset or fractions;
  RFC 1123; "October 29, 2026" and "29 October 2026") and keeps the first
  date between 1995 and two days after now. Last resort for `published`: a
  `/2026/10/29/` or `2026-10-29` date in the URL path. `ExtractedArticle`
  gains `modified: Date?`; `PageChecks.staleFactor` keeps using `published`
  only, as the spec says, and CP5 may choose `published ?? modified`.
- **Why:** many pages (CP0's BBC article among them) carry the date only in
  JSON-LD or `<time>`; a future or 1970 date would wrongly pass or fail the
  stale check.
- **Alternatives:** spec §4's three sources only: trim the candidate list in
  `EnigmaExtract.js` and drop `ArticleDates.fromURLPath`.
- **Reversible:** yes.

### D63 — 2026-10-30 06:32, CP4 — One view, extractions in turn, tuning in named constants

- **Decided (worker CP4):** one hidden `WKWebView` (spec §4), so
  extractions run one at a time in arrival order. Each one's 500 ms limit
  starts when its turn starts, not when it was queued (the caller's reading
  window bounds the whole); a queued extraction that is cancelled leaves the
  queue at once. Any failed extraction (timeout, cancellation, script error,
  WebContent crash) stops loading and discards the view, because Readability
  may still be running in its WebContent process; the next extraction makes
  a new one. The limits are named constants
  (`ArticleExtractor.defaultTimeout`, `.defaultIdleRelease`,
  `PageReader.maximumBytes`, `.maximumRedirects`, `ExtractedArticle`'s
  text cap) so CP5's `OnDeviceSearchTiming` and CP7 can pass or change them;
  the pages-read count stays `RankingTuning.readBatch` (CP3).
- **Why:** a single WebContent process can only hold one document; reusing
  a view whose script is stuck would make every later page time out.
- **Alternatives:** a pool of two or three views to extract in parallel, if
  CP7 finds extraction is the bottleneck (change `ArticleExtractor` only).
- **Reversible:** yes.

### D64 — 2026-10-30 06:32, CP4 — The local-network guard refuses a little more, fails closed, and a refusal is its own outcome

- **Decided (worker CP4):** besides the brief's names and ranges, the guard
  refuses names ending `.localhost`, `.localdomain`, `.home`, `.corp`,
  `.intranet` and `.onion` (none is a public TLD), `fec0::/10` (old
  site-local), and judges IPv4-compatible `::a.b.c.d` and NAT64
  `64:ff9b::a.b.c.d` by their IPv4 address, like IPv4-mapped ones. A
  resolver error or an empty answer refuses the page (fails closed). A URL
  carrying a user name or password is refused. `PageFetchOutcome` gains
  `.refused`: the guard, the blocklist or a non-http(s) redirect said no,
  so CP5 should use neither the page nor its snippet (a redirect to a
  blocked site means the result really is that site). `.failed` stays for
  network and HTTP failures, where the snippet is still fair to use.
- **Why:** each extra is cheap and only refuses addresses that can't be a
  public web page; spec §7 says blocked sites never appear.
- **Alternatives:** the brief's exact lists (`NetworkGuard` in
  `PageReader.swift`), and folding `.refused` into `.failed`.
- **Reversible:** yes.

### D65 — 2026-10-30 06:32, CP4 — Downloading details the brief leaves open

- **Decided (worker CP4):** ~~an `http` link falls back to `http` after any
  `.failed` https attempt (network error or non-2xx), never after
  `.refused` or `.skipped`.~~ *Corrected by D71/D72: App Transport Security
  blocks plain http, so pages are read over https only, with no fallback.* 2xx other than 204 and 205 is a page; 301, 302,
  303, 307 and 308 with a `Location` are redirects (relative locations
  resolved against the hop); anything else is `.failed`. A response with no
  `Content-Type` counts as HTML only when its first 512 bytes hold
  `<!doctype html` or `<html`; otherwise it's skipped. A body cut at 3 MB is
  still used, and a UTF-8 sequence cut at the end is trimmed so the page
  doesn't fall back to Windows-1252. A UTF-8 or UTF-16 byte-order mark wins
  over every declaration. Cancellation gives `.failed`.
- **Why:** these are the behaviours a browser would show for the same page,
  within spec §4's rules.
- **Alternatives:** skip type-less responses, or fall back to http only on
  connection errors (`PageReader.fetch`).
- **Reversible:** yes.

### D66 — 2026-10-30 06:32, CP4 — Page checks: more wall phrases, order, non-readerable long pages kept, CJK word counts

- **Decided (worker CP4):** (1) `wallPhrases` adds, to spec §3.4's and the
  brief's, "verify you are a human", "please enable cookies", "javascript is
  disabled", "checking your browser", "unusual traffic", "complete the
  security check", "subscribe to read", "sign in to read", "log in to read",
  "subscribers only", "create a free account to continue" and "to continue
  reading, subscribe"; they only count on pages under 400 words. (2) Order:
  wall, then not-an-article, then wrong language. (3) A page that
  `isProbablyReaderable` calls false but whose extracted text has at least
  `PageChecks.minimumWordsWhenNotReaderable` (250) words is kept: FAQ, spec
  sheet and API reference pages often fail Readability's paragraph-length
  test yet hold the facts asked for. (4) `wordCount` uses the system's word
  boundaries, so Japanese and Chinese pages aren't counted as one word each.
  (5) Wikipedia, read through its API, is exempt from the wall check as well
  as the length check (a stub about a film called "Access Denied" isn't a
  wall). (6) The language check reads prose blocks only (not code or table
  rows) and needs at least 200 letters, else the language is undetermined
  and the page kept: `NLLanguageRecognizer` called a page of model numbers
  Polish at 98% confidence.
- **Why:** the owner wants factual answers; dropping long docs pages costs
  facts, and a CJK page would otherwise always fail the 120-word minimum.
- **Alternatives:** spec §3.4 exactly: set
  `minimumWordsWhenNotReaderable` to `Int.max`; trim `wallPhrases`.
- **Reversible:** yes.

### D67 — 2026-10-30 06:32, CP4 — The block-all rule list is compiled into WebKit's default store

- **Decided (worker CP4):** the content rule list is compiled once per
  launch into `WKContentRuleListStore.default()` under the identifier
  `EnigmaBlockAll` (recompiled rather than looked up, so a changed rule
  can't be served stale), the only API WebKit offers. That
  writes WebKit's compiled form of the one static rule to the app's
  container; it holds no search data. No extraction starts until the list
  is installed; if it can't be compiled, extraction throws `.unavailable`.
- **Why:** "nothing is written to disk" is about search data (queries,
  URLs, pages); WebKit has no in-memory rule list.
- **Alternatives:** a store in a temporary folder
  (`WKContentRuleListStore(url:)`), deleted at quit.
- **Reversible:** yes.

### D68 — 2026-10-30 06:32, CP4 — Extracted text capped at 200,000 characters

- **Decided (worker CP4):** `EnigmaExtract.js` stops adding blocks once
  200,000 characters are collected (about 30,000 words, longer than nearly
  any article), and cuts a single block at 20,000 characters.
- **Why:** bounds the JSON that crosses into the app from a 3 MB page;
  CP5 keeps at most 2,048 tokens per source anyway.
- **Alternatives:** change the two constants at the top of
  `EnigmaExtract.js`.
- **Reversible:** yes.

### D69 — 2026-10-30 07:20, CP4 — Round-1 fixes: unresolved isn't refused; lenient UTF-8; one static rule-list file; drop responses from non-public addresses

- **Decided (orchestrator):** (1) the guard has three answers — allowed,
  refused, unresolved; a cancelled or failed lookup gives `.failed` (snippet
  kept), `.refused` stays for names, addresses, blocklist, schemes and
  credentials. (2) Declared UTF-8 decodes with replacement characters; fall
  back to Windows-1252 only when most non-ASCII bytes are invalid. (3) Revises
  D67: the block-all rule list uses a versioned identifier
  (`EnigmaBlockAll-v1` or the rule's hash), is looked up first and compiled
  only when missing, and the old entry is removed once — one static 142-byte
  file per rule version holding only the rule text, no per-search timestamp.
  Spec §4/§7 get an "Amended overnight" note naming this file. (4) A test pins
  the sealed configuration (non-persistent store, scripts off, no message
  handlers). (5) Extra hardening against DNS rebinding: a response whose
  `URLSessionTaskTransactionMetrics.remoteAddress` isn't public is dropped as
  `.refused`.
- **Why:** reviewer round 1 — (1) a read-window cancel lost snippets; (2) one
  bad byte garbled non-English pages; (3) the default store rewrote the file at
  each launch's first search, leaving a search timestamp on disk; (4) a
  persistent-store mutant passed every test; (5) closes most of the rebinding
  gap spec §4 accepted, at no cost.
- **Alternatives:** a temp-folder rule store (a crash can leave it behind); no
  remote-address check.
- **Reversible:** yes.

### D70 — 2026-10-30 07:22, CP4 — Round-1 fix details (D69)

- **Decided (worker CP4):** (1) `NetworkGuard.check(_:)` returns
  `.allowed`, `.refused` or `.unresolved`; `allows(_:)` stays as
  `check == .allowed`. A lookup error, an empty answer or cancellation is
  `.unresolved`, which `PageReader` reports as `.failed`; an `http` link
  then still gets its http attempt unless the task is cancelled. (2) The
  majority rule applies to every UTF-8 attempt, declared or not: strict
  UTF-8 (with the cut-tail trim) first; otherwise UTF-8 with replacement
  characters when at most half the non-ASCII bytes are invalid; otherwise
  the next declaration, then Windows-1252. (3) The old `EnigmaBlockAll`
  entry is removed only when the `EnigmaBlockAll-v1` lookup misses, so it
  happens once per Mac and never again after. (4) `SealedWebView` becomes
  internal with `makeConfiguration(contentController:)`; a test also checks
  from JavaScript that `window.webkit` is undefined in both the page world
  and the `EnigmaExtract` world (no message handlers). (5)
  `SearchHTTPResponse` gains `remoteAddress: String?` (default nil);
  `URLSessionSearchHTTPClient` reads it from the last transaction's metrics
  through a per-task delegate (which also refuses redirects), waiting at
  most 250 ms after the body for the metrics. It stays nil through a proxy
  (`isProxyConnection`), since the proxy's address says nothing about the
  site and is often private; nil means unknown and the page is kept. A
  non-public address drops the hop as `.refused`, redirects included.
- **Why:** D69; the proxy case would otherwise break page reading for
  everyone behind a local or corporate proxy.
- **Alternatives:** refuse when the address is unknown (breaks proxies);
  apply the majority rule only to declared UTF-8.
- **Reversible:** yes.

### D71 — 2026-10-30 07:40, CP4 — Pages over https only (ATS stays strict); round-2 fixes; no round 3

- **Decided (orchestrator):** App Transport Security blocks plain-http loads
  (URLError -1022) and is not loosened, so pages are read over https only: the
  http fallback in `PageReader` is removed and an https→http redirect ends as
  `.failed`. Corrects D65 and the Hand-off; spec §4 gets an "Amended overnight"
  note. Also fixed: a byte-order mark decodes leniently (UTF-8 and UTF-16 with
  replacement characters); D70's proxy selection moves into a tested static
  function; the rule-list versioning test uses a temporary
  `WKContentRuleListStore(url:)` and checks the file's inode and mtime don't
  change, instead of rewriting the installed app's store. Plain-HTTP proxies
  report `isProxyConnection == false` — irrelevant while ATS forbids http, noted
  in a code comment. No round 3: each fix is small and comes with the
  reviewer's own failing check as a test; usage is at 77%.
- **Why:** reviewer round 2. Loosening ATS would weaken transport security for
  the whole app; https covers nearly all quality sources.
- **Alternatives:** an ATS exception for the page reader only
  (`NSAllowsArbitraryLoads` in `Enigma/Resources/Info.plist` — not
  recommended).
- **Reversible:** yes.

### D72 — 2026-10-30 07:41, CP4 — Round-2 fix details (D71)

- **Decided (worker CP4):** (1) An `http` link is still read, as `https`
  (port 80 dropped), with one attempt and no fallback. An `http` hop
  reached by redirect still goes through the scheme, blocklist and guard
  checks first, so a redirect to a blocked or local address stays
  `.refused`; otherwise it ends as `.failed` without a request. (2) With a
  byte-order mark, UTF-8 decodes strictly with the cut-tail trim, else with
  replacement characters; UTF-16 drops an odd trailing byte and a trailing
  lone high surrogate (a cut tail), then decodes with replacement
  characters. (3) The proxy rule is
  `URLSessionSearchHTTPClient.reachedAddress(_:)` over (isProxy, address)
  pairs: the last transaction with an address, nil if it went through a
  proxy. (4) The rule-list test uses a store in a temporary folder, removed
  afterwards.
- **Why:** D71 (reviewer round 2).
- **Alternatives:** treat an https-to-http redirect as `.refused` (it
  would drop the snippet of a page that only moved).
- **Reversible:** yes.

### D73 — 2026-10-30 08:00, CP5 — Pipeline tuning defaults inside the owner's speed bar

- **Decided (worker CP5):** `OnDeviceSearchTiming` holds every pipeline
  number CP7 measures: `readingWindow` 3.0 s (spec 2.5 s), `readLimit` 6
  reads at a time (spec; also spec §7's "at most 6 downloads"),
  `earlyStopPages` 5 (spec 4), `extractionTimeout` 800 ms (spec 500 ms),
  `rankingCutoff` 0.08 (spec and `RankingTuning.cutoff` 0.15, which stays
  as CP3's tested default for `select`), `snippetFallbackSources` 4,
  `tokensPerWord` 1.4, `collectionAllowance` 1.5, and
  `maximumWordsScoredPerPage` 15,000 (passages past it aren't scored, which
  bounds lemmatizing on very long pages).
- **Why:** owner's bar is a 4.0 s median and 6.0 s p90 (D2) and asks for
  more pages read. Sites take up to 2.0 s, so a 3.0 s window keeps the worst
  case near 5–5.5 s while giving serial extractions more room; CP4's live
  check saw 1 MB pages miss 500 ms (Wikipedia's 1.3 MB took 386 ms). With
  DuckDuckGo alone, 0.15 keeps about positions 1–6, leaving nothing to
  refill a failed read from (D59); 0.08 keeps about 1–12. A fifth passing
  page adds a source for capable models at little time cost.
- **Alternatives:** the spec's values (2.5 s, 4 pages, 500 ms, 0.15): change
  the constants in `Enigma/Search/OnDeviceSearch.swift`.
- **Reversible:** yes.

### D74 — 2026-10-30 08:00, CP5 — Pipeline details the brief leaves open

- **Decided (worker CP5):** (1) The stale check uses `published ?? modified`
  (D62); the excerpt's `published` stays the page's own publish date. (2)
  Wikipedia's order score uses the top read candidate's score as its base
  (it has no search score), times its passage match; a read page that
  near-duplicates the Wikipedia article is dropped, Wikipedia kept. (3)
  Wikipedia's plain extract puts one paragraph per line, so its lines are
  paragraphs (`passages(fromPlainText:lineBreaks:)`); `text/plain` pages
  split at blank lines as the brief says. (4) The snippet fallback takes
  unread, failed, skipped, wall and not-an-article candidates and
  `snippetOnly` ones, best score first; never `.refused` (D64), off-topic,
  duplicate or wrong-language ones; read pages and Wikipedia count toward
  the 4. (5) Passages are collected round-robin, each source's best
  passage first, so one long page can't take the whole 1.5 × budget; each
  source also stops at `WebSearchLimits.tokensPerSource`. (6) The query sent
  to sites is cut to 50 words and 400 characters (spec §2; CP2 left it to
  CP5). (7) The question's language (`NLLanguageRecognizer`) plus the Mac's
  preferred languages are the allowed page languages.
- **Why:** each follows the spec's intent; (5) keeps several sources in a
  small budget.
- **Alternatives:** per-source order (first source fills the budget); the
  modified date in `published`; all in `OnDeviceSearch.swift`.
- **Reversible:** yes.

### D75 — 2026-10-30 08:00, CP5 — `web_search` on the on-device provider is capped to F32's budget

- **Decided (worker CP5):** the provider collects up to 1.5 × the request's
  tokens because `WebSearchContext` trims again with the model's tokenizer
  (spec §5). `web_search`'s result isn't trimmed again, so on capable turns
  served by `OnDeviceSearchProvider`, `nativeToolbox` fits the results to
  F32's budget (2,048 local, 8,192 cloud) by the same words × 1.4 estimate,
  sharing it fairly between sources (`WebSearchExcerpts.fitted`). Brave's
  results pass unchanged, as today, since Brave already measures its own.
- **Why:** keeps F32's budgets, and a local model's prefill time, unchanged
  when the Debug switch is on.
- **Alternatives:** no fitting (up to 50% more evidence on capable turns):
  drop the `fitted` call in `LocalChatViewModel.nativeToolbox`.
- **Reversible:** yes.

### D76 — 2026-10-30 08:10, CP5 (CP4 CI fix) — WebKit's own extraction errors become a normal failure, retried once on a fresh view

*Superseded by D77 (reviewer round 1):* the retry below could never run,
because every error `extract` sees is already Enigma's own, and the
"InvalidTransition" text comes from Apple's private Gestures framework when a
view is released, not from extraction. The CI failures were most likely the
500 ms limit on a slow runner. The retry and `.unknownFailure` are removed
(D78); `normalized` stays as a guard.

- **Decided (worker CP5, at the orchestrator's request):** CI (Xcode 26.6,
  macOS 26) failed four `ArticleExtractorTests` on 44e4711 with a foreign
  error, `InvalidTransition { phase: idle targetPhase: failed(deinit) }`,
  thrown out of `extract`; they pass on macOS 27 locally. Not reproducible
  here, so the fix is defensive: (1) any failure discards the view, as
  before, and any error that isn't `CancellationError` or
  `ArticleExtractorError` becomes `.unknownFailure`
  (`ArticleExtractor.normalized`); (2) `extract` retries such a failure
  once on a fresh sealed view (same configuration, rule list and delegate),
  then throws `.scriptFailed`, so the pipeline falls back to the snippet;
  (3) `SealedWebView` keeps the finished `WKNavigation` referenced until the
  next load or the view's release, instead of releasing it inside the
  delegate callback. A deterministic test pins (1). Every sealed-view
  guarantee is unchanged. CI is the check; if the four tests still fail
  there, extraction on macOS 26 needs a closer look on a macOS 26 machine.
- **Why:** orchestrator's report of CI on 44e4711; the error's
  "failed(deinit)" points at an object released while idle.
- **Alternatives:** skip the WebKit tests on macOS 26 (weakens tests, not
  done); raise the deployment target (owner's call).
- **Reversible:** yes (`ArticleExtractor.swift`).

### D77 — 2026-10-30 08:40, CP5 — Replace D76: CI failures were slow-runner timeouts; warm the WebKit process; site outages aren't "no results"

- **Decided (orchestrator):** (1) D76's retry is unreachable and the
  "InvalidTransition" text comes from Apple's private Gestures framework when a
  discarded view is released, so the four CI failures were almost certainly
  extractions passing the 500 ms default on a slow macOS 26 runner (they ended
  at 0.585–0.795 s). The unreachable retry is removed; tests that check
  extracted content use a long explicit timeout through a helper, and
  `testExtractionTimesOut` still pins the limit. (2) `warmUp` makes the sealed
  view load an empty page so the WebContent process is running before the first
  real extraction (a fresh process costs 0.4–0.9 s on the CI runner), and a
  view discarded after a timeout is re-warmed in the background. (3) When no
  page or snippet remains and the sites failed or were rate-limited, the error
  comes from the sites' outcomes ("limiting requests", unreachable), not
  `noResults`. (4) Tests for `WebSearchExcerpts.fitted`, a user-blocked
  wikipedia.org, and wrong-language pages left out of the snippet fallback.
  A focused round 2 follows (a Blocker was found).
- **Why:** reviewer round 1 (Blocker 1, Should fixes 2–3); macOS 26 is the
  deployment target, so first-extraction latency matters to real users too.
- **Alternatives:** keep D76's retry; raise the production extraction limit
  instead of warming (`OnDeviceSearchTiming`).
- **Reversible:** yes.

### D78 — 2026-10-30 08:40, CP5 — How D77's warm-up and fixes are built

- **Decided (worker CP5):** (1) `ArticleExtractor.normalized` maps any error
  that isn't `CancellationError` or `ArticleExtractorError` to `.scriptFailed`;
  `.unknownFailure` and the retry are gone. (2) `warmUp()` creates the view
  and, once the rule list is ready, loads a blank page (`<html></html>`, no
  base URL) through the same sealed `load`, taking an extraction turn so it
  never overlaps a page; it runs once per view (skipped once the view has
  loaded anything) and ends after at most 2 s. (3) Any extraction failure that
  discards the view (timeout, script failure, cancellation) re-warms a fresh
  view in the background; the 60 s idle release doesn't. (4)
  `ArticleExtractorTests` that check extracted content use
  `ArticleExtractor(timeout: .seconds(10))` through a helper;
  `testExtractionTimesOut` still uses 1 ms. (5) With no page or snippet left,
  the error is the sites' (`.rateLimited` or `.unavailable`) when DuckDuckGo
  returned nothing, `.noResults` otherwise.
- **Why:** D77, reviewer round 1.
- **Alternatives:** warm without taking a turn (an extraction could replace
  the blank load mid-flight); re-warm only after timeouts.
- **Reversible:** yes (`ArticleExtractor.swift`, `OnDeviceSearch.swift`).

### D79 — 2026-10-30 08:49, CP5 — Round-2 fixes, then commit without a round 3

- **Decided (orchestrator):** the warm-up's limit task returns on
  cancellation instead of stopping the view (a latent race that could cancel
  the next real page load), with a test that no stop follows a completed
  warm-up; and a test pins `ArticleExtractor.shared` to
  `OnDeviceSearchTiming.extractionTimeout` so the production limit can't
  silently drop to 1 ms. No round 3: both fixes are small, each comes with the
  reviewer's own check as a test, and weekly usage is about 80% (the run stops
  new work at 83%).
- **Why:** reviewer round 2 (two Should fixes, no Blockers).
- **Alternatives:** a round 3 on these two fixes.
- **Reversible:** yes.

### D80 — 2026-10-30 08:50, CP5 — Round-2 fix details (D79)

- **Decided (worker CP5):** the warm-up's limit task returns when cancelled;
  `SealedWebView` counts its stops (`stopCount`, read through
  `ArticleExtractor.viewStops`, for tests) and `ArticleExtractor.timeout` is
  readable. Tests: `testNoStopFollowsACompletedWarmUp`,
  `testSharedExtractorUsesThePipelinesLimit`.
- **Why:** D79, reviewer round 2.
- **Alternatives:** none worth keeping.
- **Reversible:** yes.

### D81 — 2026-10-30 09:05, CP6 — Geocoding asks for 5 results and prefers an exact name match; names as returned

- **Decided (worker CP6):** `OpenMeteoGeocoder` sends `count=5` (spec §6.4 says
  `count=1`) and picks the first result whose `name` equals the place's name
  (ignoring case and diacritics), preferring one whose admin1, country or
  country code matches the text after a comma ("springfield, illinois");
  otherwise the first result. A comma-qualified place is searched by its first
  part, since Open-Meteo matches names only. The resolved name is `name`,
  `admin1` (left out when equal to the name) and `country` exactly as
  returned, so the Paris fixture gives "Paris, Île-de-France Region, France"
  (CP0b Q4), not the brief's "Paris, Île-de-France, France", and its latitude
  48.85341 rounds to 48.85, not the brief's 48.86 (MapKit's figure).
- **Why:** CP0b Q4: a typo resolves silently to another place ("Pariss" →
  Parisse, Haiti) and `count=1` returns the most populous match; asking for 5
  and preferring an exact name costs nothing in latency (one request) and
  avoids that. Stating admin1 and country lets the user spot a wrong match.
- **Alternatives:** `count=1`, first result: `OpenMeteoGeocoder.resultCount`
  and `best(_:for:)` in `Enigma/Search/WeatherLookup.swift`.
- **Reversible:** yes.

### D82 — 2026-10-30 09:05, CP6 — The tools' activity text is two new phases that count as searching

- **Decided (worker CP6):** `AssistantActivity.Phase` gains `findingPlaces`
  ("Finding places…") and `checkingWeather` ("Checking the weather…"), with
  `isSearching` true for them and `.searching`; the activity panel's
  "Waiting for search results…" line uses `isSearching`. Spec §6.2 says "both
  as `.searching` phases with their own text"; `Phase` is a plain enum whose
  label is fixed per case, so separate cases are the smallest way to give them
  their own text.
- **Why:** the brief's `testToolActivityText` needs the two labels; a payload
  on `.searching` would change every switch over `Phase`.
- **Alternatives:** an associated label on `.searching` (`AssistantActivity.swift`).
- **Reversible:** yes.

### D83 — 2026-10-30 09:18, CP6 — Places and weather are in `NativeToolPlan.offeredParts`, not `parts`

- **Decided (worker CP6):** `NativeToolPart` gains `.places` and `.weather`,
  but `NativeToolPlan.make` sets `offersPlacesAndWeather` instead of inserting
  them into `parts`; `offeredParts` (`parts` plus the two) is what
  `nativeToolbox` builds from. A typed `/maps` offers search like `/search`
  (when a backend exists) and always offers places and weather, key or not,
  with `find_places` required; a declined provider-search card
  (`searchDeclined`) offers none of them.
- **Why:** the brief says F32's and F30's tests stay green unchanged, and
  `NativeToolPlanTests.testPlanTable` pins `parts` exactly; inserting the new
  parts there would change it.
- **Alternatives:** insert them into `parts` and update `testPlanTable`
  (`Enigma/Chat/AssistantToolbox.swift`).
- **Reversible:** yes.

### D84 — 2026-10-30 09:18, CP6 — How `/maps` travels and what it conflicts with

- **Decided (worker CP6):** the submitted prompt keeps `/maps ` (as `/edit` and
  `/translate` stay in theirs), so every route sees it: `shouldSearch` and
  `search()` read `ComposerCommands(prompt).maps`, and the native plan reads it
  from the prompt as before. The user's message therefore shows "/maps
  bookshops". `/maps` with a screenshot or `/screen`/`/snapshot` gives the new
  `.mapsConflict` ("/maps can't be combined with a screenshot. Remove /screen,
  /snapshot, or the screenshot, then send again."); alone it gives
  `.nothingToFind` ("There's nothing to look for."), shown through
  `messages.report` like the Messages conflict, draft kept. On a capable turn,
  `web_search` ignores `/maps` for its own routing, so `/maps` alone never
  sends the location to Brave. Help gets a `/maps` row next to `/search` (with
  the key requirement); the main page's command examples list it last; the
  welcome page's fixed "/screen /search /edit" line is unchanged.
- **Why:** a separate flag would need new parameters on `submit`,
  `submitCloud`, `submitAuto` and the queue; the welcome line is sized to its
  text (`EnigmaControls.swift` comment), and the owner should choose which
  command it drops.
- **Alternatives:** strip `/maps` from the shown message (`ThinkCommand.message`)
  and pass a flag; add `/maps` to the welcome line (`WelcomeSetupView.swift`,
  `EnigmaControls.swift`).
- **Reversible:** yes.

### D85 — 2026-10-30 09:18, CP6 — Tool details the brief leaves open

- **Decided (worker CP6):** (1) `find_places`'s saved source is
  `https://maps.apple.com/?q=<query>` without the `area`, since a model can
  fill `area` with the user's city (it learns it from `get_weather`'s place
  name); (2) near the user, the tools check the location (on the Mac, nothing
  sent) before the gate-3 card, so a Mac with location off never shows a card
  for a lookup that can't run; (3) the gate-3 card is a new
  `ToolPermission.lookUpAfterMessages(title:service:)` whose grant is
  `searchAfterMessages`'s, with the detail "…It will be sent to Apple Maps."
  or "…to Open-Meteo."; (4) `get_weather` with no place asks "Check the
  weather for your area?"; (5) the shared instructions sit on `find_places`,
  and `AssistantToolbox` skips empty instruction strings; (6) `onPlaces`
  fills an in-memory `LocalChatViewModel.replyPlaces[messageID]` for CP9.
- **Why:** saved sources must never carry the location (spec §6.5); the
  rest follow spec §6.2 with the least new surface.
- **Alternatives:** each is local to `Enigma/Search/PlacesAndWeatherTools.swift`,
  `Enigma/Chat/ToolPermissions.swift` or `LocalChatViewModel.nativeToolbox`.
- **Reversible:** yes.

### D86 — 2026-10-30 09:19, CP6 — Three F30/F32 assertions follow spec §6.2's intended changes

- **Decided (worker CP6):** in `NativeToolRequestTests`, the flagged local
  turn's tool set now includes `find_places` and `get_weather`; the
  provider-search instruction check uses `ProviderSearchPart(offersPlacesAndWeather: true)`;
  and `askClause` is spec §6.2's replacement sentence ("use find_places or
  get_weather, which know the user's approximate location"). The tests still
  check the same things (the tools a turn gets, that the provider instruction
  is sent, that a declined or missing location tells the model what to do).
  The brief asks both for these behavior changes and for F30's and F32's tests
  to stay unchanged; the two can't both hold, and the spec wins.
- **Why:** 5 tests (6 assertions) failed only on these intended changes.
- **Alternatives:** none that meets spec §6.2.
- **Reversible:** yes.

### D87 — 2026-10-30 09:31, CP6 — A declined location stays declined for the places and weather tools; round-1 fixes

- **Decided (orchestrator):** amends spec §6.2 (marked "Amended overnight"):
  when the user taps "Don't allow" on F30's share-location card, that turn's
  `find_places`/`get_weather` get no location (they answer "The user's
  location isn't available…"), F30's "ask which city they mean" clause is kept
  for that turn, and `testLocationDeclinedSendsNothing`'s original assertion is
  restored. Also: `/maps` applies the weather rule's exclusions (times, home,
  work, school) before counting a named area; `find_places`'s saved link drops
  the city's words from the query (or links to bare maps.apple.com); tests for
  gate 3 on both tools and both backends, and for the 3 s/2 s time limits; and
  a GeoNames (CC BY 4.0) credit beside Open-Meteo in ThirdPartyNotices, since
  Open-Meteo's geocoding is built on GeoNames.
- **Why:** reviewer round 1 — the decline could be bypassed and addresses and
  distances near the user would reach the provider the user refused
  (privacy, Blocker); the others are concrete failures or untested rules.
- **Alternatives:** spec §6.2 as written (tools keep the location after a
  decline) — `NativeWebSearch.swift`, `LocalChatViewModel.swift`.
- **Reversible:** yes.

### D88 — 2026-10-30 09:33, CP6 — How the round-1 fixes (D87) are built

- **Decided (worker CP6):** (1) `providerSearchLocation` also reports whether
  the user declined F30's card; `nativeToolbox(…locationDeclined:)` then gives
  the places and weather tools a location closure that returns nil, and
  `ProviderSearchPart` keeps "ask which city they mean"
  (`offersPlacesAndWeather` false for its clause). (2) `/maps` counts a named
  area only when `LocationIntent.mapsArea` finds an in/at/near candidate that
  isn't a time, home, work or school (the weather place rule's exclusions),
  as well as `SearchRouting`'s area pattern. (3) Near the user,
  `find_places`'s link drops the city's words (`searchCity`, split into
  words, matched ignoring case and accents) and a dangling in/near/at; if the
  query is then empty, or still holds a city word or a digit run that could
  be a coordinate, it links to bare `https://maps.apple.com/`. (4) The time-limit
  tests use `ManualClock` with a hanging fake. (5) The notice credits GeoNames
  (CC BY 4.0) beside Open-Meteo.
- **Why:** reviewer round 1 (D87).
- **Alternatives:** in `LocalChatViewModel.swift`, `SearchRouting.swift`,
  `LocationService.swift`, `PlacesAndWeatherTools.swift`.
- **Reversible:** yes.

### D89 — 2026-10-30 09:41, CP6 — A declined location lasts for the rest of the chat; round-2 fixes; no round 3

- **Decided (orchestrator):** amends D87: a "Don't allow" on the
  share-location card is remembered in memory for the rest of that chat and
  provider (never saved), and cleared by a later Allow — so later turns'
  `find_places`/`get_weather`/`web_search` get no location either. Also: the
  fallback to Enigma's `web_search` after a decline skips the location lookup;
  `find_places`'s saved link strips `near?.searchCity ?? area` and falls back
  to bare `https://maps.apple.com/` when a city word appears inside the query
  (covers Japanese/Chinese queries without spaces); a test pins
  `MapKitPlaceSearch.timeout` at 3 s. No round 3: each fix is narrow and comes
  with the reviewer's failing probe as a test, and weekly usage is ~82% (the
  run stops new work at 83%).
- **Why:** reviewer round 2 — the city could still reach the provider after a
  decline (fallback path, next turn, explicit area, CJK queries).
- **Alternatives:** a decline for that turn only (D87 as written).
- **Reversible:** yes.

### D90 — 2026-10-30 09:43, CP6 — How the round-2 fixes (D89) are built

- **Decided (worker CP6):** (1) `LocalChatViewModel.declinedLocations` holds
  "chat session | provider" keys in memory; a Don't allow on the
  share-location card adds one, an Allow (or an Always grant answering without
  a card) removes it. A cloud turn whose chat and provider hold one gets
  `locationDeclined`, which now also reaches `web_search` (`search(…skipsLocation:)`
  skips the location lookup, so the nearby cue is dropped with no city). (2)
  `find_places`'s link strips `near?.searchCity ?? area`; a city word found
  inside the folded query also gives the bare link: whole words for Latin
  words of one or two letters, substrings otherwise, and for CJK words also
  without a trailing 区/市/都/府/県/道/町/村/省/县 ("渋谷区" matches "渋谷").
- **Why:** reviewer round 2 (D89).
- **Alternatives:** `LocalChatViewModel.swift`, `PlacesAndWeatherTools.swift`.
- **Reversible:** yes.

### D91 — 2026-10-30 09:56, run end — Stop after CP6 instead of starting CP7 at 82%

- **Decided (orchestrator):** weekly usage was 82% after CP6's commit, one
  point under the run's 83% "start nothing new" line. CP7 is not started:
  each checkpoint has used 2–4 points, and CP7's evaluation sends every
  question through Claude Code (sonnet), which draws on the same weekly
  budget, so it would cross 83% before finishing its first task and likely
  reach the 86% hard stop mid-evaluation, leaving a half-built harness and a
  cut-off live run. The run ends cleanly with CP1b–CP6 committed, the worktree
  clean, no wip branch, the PR left as a draft (CP7–CP10 remain), and a RESUME
  section in `overnight-report.md`.
- **Why:** a clean stop at a checkpoint boundary is easier to resume than a
  wip branch, and keeps the owner's buffer under 86%.
- **Alternatives:** start the CP7 worker now and hard-stop when usage reaches
  86% (WIP to `wip/f29-overnight-<time>`).
- **Reversible:** yes (resume from the RESUME steps).

### D92 — 2026-10-30 10:05, CP7 — Haiku worker, Sonnet reviewers, Sonnet judge

- **Decided (owner, 2026-10-30):** to save weekly usage, CP7's worker runs on
  Haiku (effort high) instead of Opus, and each review round's fresh reviewer
  runs on Sonnet (effort xhigh) instead of Opus. The evaluation's blind judge
  stays Claude Code with sonnet (`claude -p --model sonnet`), as D6 allows.
- **Why:** the owner asked for Haiku to reduce usage; the judge's results
  decide whether CP8 removes Brave, and its ~120 short calls cost far less
  than the worker and reviewers.
- **Alternatives:** Haiku for the judge too (cheaper, weaker gate evidence);
  Opus reviewers (stronger review). If the Haiku worker stalls on a design
  question or a reviewer finds a Blocker, the orchestrator may resume the
  work with a Sonnet worker and log it.
- **Reversible:** yes.

### D93 — 2026-10-30 10:05, CP7 — The usage stop moves from 86% to 92% for CP7

- **Decided (owner, 2026-10-30):** CP7 starts at 82% weekly usage and may
  finish unless usage reaches 92%, which is now the hard stop (same steps as
  the overnight hard stop: stop agents, WIP to `wip/f29-cp7-<time>`, RESUME
  in `overnight-report.md`). The orchestrator starts no new reviewer round or
  live run from 90%.
- **Why:** the owner is present and chose to run CP7 now rather than wait
  about 16 hours for the weekly reset.
- **Alternatives:** keep 86%; wait for the reset.
- **Reversible:** yes.

### D94 — 2026-10-30 10:08, CP7 — Owner approvals the brief asks for are deferred; judge and models as the orchestrator set

- **Decided (worker CP7):** (1) The 40 new questions are written by hand once, before any run, and marked "for owner review" in the CP7 Hand-off. The brief's "get the owner's approval in the chat before Task 7.4" can't be met overnight (agent-rules: owner asleep), so the runs go ahead on this list and any owner edit means rerunning. The same applies to the tool-use prompts (Task 7.5), the spec deviations and any list edits. (2) The judge is `claude -p --model sonnet` only. The brief's Gemini route is skipped, because the orchestrator's rules allow no other cloud model. (3) Brave runs only through `TEST_RUNNER_ENIGMA_BRAVE_KEY`, read by the test host as `ENIGMA_BRAVE_KEY`. (4) The worker is the one writing code here; no reviewer round is started unless the orchestrator asks for one.
- **Why:** agent-rules says the owner is asleep and every routine decision is the worker's; D92 sets Sonnet for the judge; D6 and the orchestrator's brief limit cloud models to sonnet and gpt-5.6-luna, and Gemini isn't in that list.
- **Alternatives:** wait for the owner in the morning (a day lost); add a Gemini judge (not allowed).
- **Reversible:** yes. Question list, tool prompts and judge model are data files; a rerun takes minutes.

### D95 — 2026-10-30 10:12, CP7 — Answers come from the installed models through the app's llama-server; the evaluator makes them

- **Decided (worker CP7):** (1) `WebSearchEvaluationTests` writes each provider's evidence (the excerpts the app would send: title, URL, kind, snippets) to `contexts.jsonl`; it does not build the grounded prompt with `WebSearchContext.prepare`, because that needs the model's tokenizer inside the test host. (2) `scripts/evaluate-web-search.py` builds the answer prompt from that evidence and asks the installed model through the app's bundled `llama-server`, started and stopped by the script (its own PID only). (3) Typed style answers come from Gemma 4 12B Q5_K_M, and model style from Qwen3.8 27B IQ3_XXS. Both are native-tools flagged (`LocalMultimodalProfile.nativeTools`), so no unflagged small model is installed; Gemma is the smaller of the two and is the closer match for the small-model style. (4) Brave runs are cached in the run folder and reused across tuning rounds (its results drift only slowly); on-device runs repeat every round.
- **Why:** the evaluation has to measure answers from the installed models, and the test host has no tokenizer hook. Using the app's own llama-server keeps the model and the runtime as the app ships them.
- **Alternatives:** Swift inference inside the test (more code, same model); a cloud model for answers (not allowed); Brave answers regenerated each round (slower, same conclusion).
- **Reversible:** yes. Mapping is `--answer typed=<gguf> --answer model=<gguf>`.

### D96 — 2026-10-30 10:16, CP7 — Question set, gate reading, and F30's evaluator scoped to its 20

- **Decided (worker CP7):** (1) The 40 new questions are written (IDs `<category>-NN`, four non-English: news-06 German, health-finance-05 Spanish, encyclopedic-02 Italian, places-03 French); F30's 20 keep their IDs and text and get a hand-written `query` each (the spec requires one per web question). Counts match the spec's table exactly (validated by `test_query_set_shape`). (2) `evaluate-native-search.py` and its test read only the `web-` IDs, so F30's own comparison stays at 20 questions. Its assertions are unchanged; only the input set was retargeted (noted here, per the workflow's rule on tests). (3) Gate reading, as the script computes it: the relaxed bar (D3) has no variety or authority check, so both are measured and shown but not blocking under relaxed (authority stays original-only as D3 says). Recency is checked per style on news and facts (20 questions). "10 of 12" is read as 10 or more of the 12 new tool prompts right, near misses included. The judge share is over all 60 questions per style, and a missing judgment makes the check incomplete, never a pass.
- **Why:** the brief and spec require these shapes; F30's evaluator and tests broke on the 60-entry file and needed the scope to keep their assertions; missing data must never pass (F30's rule).
- **Alternatives:** a separate F30 question file (more churn); count only the 8 positive tool prompts (weaker than D3's wording).
- **Reversible:** yes; the file and the two constants are the switches.

### D97 — 10:27, CP7 — Evaluation pacing and one retry for DuckDuckGo's rate limit (harness only)

- **Decided (worker CP7):** `WebSearchEvaluationTests` pauses 5 s between searches, and a search DuckDuckGo answers "rateLimited" waits 30 s and tries once more (`attempts` in each run row says which). Latency and trace are the last try's. Product code is unchanged. Written after the first baseline (`baseline-1`, no pacing, typed on-device 11 of 60 rate-limited, model 0 of 60, all of them about 50 ms replies), so the baseline's typed numbers are not used for the gate; `baseline-2` is.
- **Why:** a person searches at a human pace; a back-to-back run of 120 searches isn't how the app is used. The evidence is that the failures come in fast replies, with no site outage.
- **Alternatives:** count rate-limited runs as failures (measures the harness, not the search); run the sites slower (same as the pause). Disclosed in the report.
- **Reversible:** yes (the pause and retry constants in the test).

### D98 — 10:27, CP7 — Answers come from one model (Gemma 4 12B) with the evidence capped

- **Decided (worker CP7):** D95's mapping changes: both styles are answered by Gemma 4 12B Q5_K_M, which is native-tools flagged (`nativeTools`). Qwen3.8 27B stays for the tool-use eval only. The evidence text an answer sees is capped at 12,000 characters, the same for both providers, and an answer has at most 400 tokens. `scripts/evaluate-web-search.py` starts one llama-server per model path.
- **Why:** on this Mac a 27B answer takes minutes, and two styles plus three tuning rounds of 120 on-device answers each wouldn't fit in one night. Gemma is the smaller of the two, so the mapping in D95 becomes one model for both styles. The cap is the same for both providers, so the comparison is fair, but answers are shorter evidence than the app's full 8,192-token budget.
- **Alternatives:** the full budget (about 3–4× longer per answer); Qwen for model style (about 2× longer again).
- **Reversible:** yes (`--answer` mapping, `EVIDENCE_CHARACTERS`).

### D99 — 2026-10-30 10:38, CP7 — Two flaky UI tests left unchanged

- **Decided (orchestrator):** (1) The full suite on `bf4d115` with the screen
  unlocked ran 1957 tests: 38 skipped, 1 failure,
  `EnigmaMainWindowTests.testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`
  (a UI wait timed out). It passed 3 of 3 runs on its own, and F29 doesn't
  touch that test file. (2) CI on `bf4d115` (docs only; its code is
  `fb17df8`, which passed) failed
  `ScreenViewTests.testLongScreenSearchConversationSettlesAtBottom` on its
  5 s wait, the same flake as D44; the failed job was rerun. Neither test is
  changed in F29.
- **Why:** both are timing flakes in UI tests outside F29's code; changing
  them belongs in its own fix. *Update 10:50:* the `ScreenViewTests` test
  then failed again at `d5286b5` (failures at `c90ecf3`, `bf4d115` twice and
  `d5286b5`; `main` passed its last 6 runs), so it may be caused by F29
  after all. It is now step 3 of the RESUME in `overnight-report.md`. *Update (CP7):* it wasn't F29. The F30 branch failed the
  same test on CI, and `main`'s passing runs took 8.5 s against the 5 s wait;
  the burst wait was raised to 15 s in `8626f32`, after which it passed on
  CI (9.3 s). That run then failed
  `ComposerIntentResolveTests.testResolvingIsFast` by 5 ms over its 5 s
  bound on a slow runner; locally F29 doesn't slow that draft (1.39–1.43 s
  on `main`, 1.39–1.40 s on the branch per 1,000 runs), so the job was
  re-run and the test left unchanged.
- **Alternatives:** lengthen `ScreenViewTests`' 5 s wait in a separate change
  (it has now flaked twice on CI).
- **Reversible:** yes.

### D100 — 2026-10-30 10:38, CP7 — Paused at the owner's request; work saved to a wip branch

- **Decided (owner, 2026-10-30):** the owner had to turn the computer off, so
  the CP7 worker was stopped mid-task (no reviewer round had started). Its
  uncommitted work is on `wip/f29-cp7-20261030-1037` (commit `9f02355`); the
  feature branch gets only this log and the RESUME section.
- **Why:** owner request.
- **Alternatives:** none.
- **Reversible:** yes (resume from the RESUME steps).

### D101 — 11:58, CP7 — Answers with the model's thinking turned off

- **Decided (worker CP7):** `evaluate-web-search.py` sends `chat_template_kwargs: {enable_thinking: false}` with each answer request. Gemma 4 on the bundled llama-server otherwise spends the 400-token budget on reasoning, and a timed test with thinking off took about 20 s per answer (2.9k prompt tokens, 400 generated). The first attempt, with thinking on, produced no answer in seven minutes and was stopped.
- **Why:** the evidence; answers need the answer text, not the reasoning.
- **Alternatives:** raise the token budget (slower); `--reasoning-budget 0` on the server (same effect, one place).
- **Reversible:** yes (one line).

### D102 — 11:58, CP7 — DuckDuckGo gave much less on-device coverage in later runs with the same code

- **Decided (worker CP7):** no product change. The runs differ in how many sources DuckDuckGo returned for the same question in the same code path: model-style questions such as "men's marathon world record" had 5 sources in `baseline-1` and 1 in `baseline-3` and in `recheck-1` (a rerun of the 20 short questions). Typed style recovered in the recheck. A plain curl request (GET and POST, same query) returned normal results. The cause isn't known; the app's engine doesn't log the site outcome (`unrecognized`, `blocked` or no results), so this can't be split further without a probe that the brief doesn't cover.
- **Why:** the gate's two-source and variety checks depend on this, so the report must say so.
- **Alternatives:** retry an empty site page once (a product change; not tried, since it only treats symptoms); pace the requests further (not tried in time).
- **Reversible:** yes. Reported as a limitation in the CP7 Hand-off.

### D103 — 12:36, CP7 — Speed-up: parallel judge, early read, cached answers, two-slot test

- **Decided (orchestrator, owner asked to speed up CP7):** (1) The judge runs up to 6 `claude -p --model sonnet` calls at once (same prompt, same hash-based order, same JSON check); a failed or unparseable call is tried once more, then counts as missing, which never passes. (2) Early read: the first 40 judged pairs (typed style) went to the orchestrator at 12:36, from `--judge-limit 40`; `early-read.md` in the run folder. (3) Answers are cached in `runs/answer-cache.jsonl`, keyed by a hash of the model, the exact prompt and the settings (temperature 0.2, 400 tokens, thinking off). Answers already in a folder are skipped; cached answers are copied; the 121 earlier answers were backfilled with keys. Brave answers are shared across rounds through the same cache. Judge results are also resumed from `judgments.jsonl`. (4) Two parallel answer slots were measured on the same model, with the same settings for both providers: about 16.4 s per answer against about 16.8 s for one slot. That's far under the 30% bar, so the run uses one slot.
- **Why:** owner asked for speed; the cache makes tuning rounds regenerate only the on-device answers whose evidence changed.
- **Alternatives:** two slots (not kept, measured); a second model in parallel (not allowed: one local model at a time).
- **Reversible:** yes (`--answer-workers`, `--workers`, `--judge-limit`, the cache file).

### D104 — 2026-10-30 12:42, CP7 — Owner adds four search features

- **Decided (owner, 2026-10-30):** after the early read (typed style: on-device
  13, Brave 27; news and facts 0 of 12), CP7 adds:
  1. **Local-model query rewrite** on the small-model path: the chat's local
     model turns a typed question into 1–3 keyword queries, searched and
     merged;
  2. **An "enough?" check with one retry:** after reading, the local model
     judges whether the passages answer the question and, if not, searches
     once more with the missing term;
  3. **Wikidata** as a keyless facts source (Wikimedia, already a third party
     through Wikipedia);
  4. **Google News RSS** for news questions. This adds Google as a third party
     that sees news queries; the owner accepted that.
  The spec is amended for each, marked "*Amended (owner approved 2026-10-30)*".
- **Why:** typed questions search badly as whole sentences; news and facts
  lose every judged question; a keyword rewrite, specialised sources first
  and a sufficiency check target exactly these.
- **Alternatives:** code-only keyword clean-up only (already in tuning round
  1); keep news on DuckDuckGo only.
- **Reversible:** yes; each is a separate engine or step behind the
  on-device provider, and Brave stays the default until CP8.

### D105 — 2026-10-30 12:42, CP7 — A Sonnet worker builds D104's features

- **Decided (orchestrator):** the Haiku worker finishes tuning round 1 and
  its report, then stops. A Sonnet worker (effort high) builds D104's four
  features with tests, since they are design work (local-model calls in the
  search path, two new sources, privacy review). The Haiku worker then runs
  round 2's evaluation. One worker writes code at a time.
- **Why:** D92 allows a Sonnet worker for design questions Haiku shouldn't
  settle alone.
- **Alternatives:** Haiku builds them (cheaper, riskier).
- **Reversible:** yes.

### D106 — 2026-10-30 12:44, CP7 — Pivot: stop the DuckDuckGo-only evaluation; an Opus worker builds D104's features

- **Decided (owner, 2026-10-30):** rather than spend more time and tokens
  measuring the DuckDuckGo-only version, build D104's four features now on the
  current code, with an Opus worker at effort high (replacing D105's Sonnet
  worker). The Haiku worker was stopped mid-way through baseline-3's
  model-style answers and tuning round 1; its eval run and llama-server were
  stopped by PID. Its uncommitted harness and the started site-outcome trace
  (`SearchTracing.recordSites`) stay in the worktree for the new worker.
  The full evaluation (judge, tuning, tool-use eval, gate report) runs after
  the features land.
- **Why:** the early read showed the DuckDuckGo-only version losing for
  reasons the features target; measuring it fully first would cost hours.
- **Alternatives:** finish round 1 first (D105).
- **Reversible:** yes.

### D107 — 2026-10-30 12:49, CP7 — How the local-model query rewrite is built (D104, feature 1)

- **Decided (worker CP7):** (1) A new `isTypedQuestion` flag on `WebSearchRequest` marks a query that is the user's typed question (set by `LocalChatViewModel.search` only when no query was written or refined from attached text). Only those are rewritten. A capable model's `web_search` query and a screen- or attachment-written query are searched as written: the model already wrote keywords, and rewriting them would cost a second model call for no evidence of gain. (2) On the small-model local path the chat's own installed model (the same `engine.installedModel()` and engine the answer uses, as the existing attached-text refine does; nothing new is loaded) writes 1–3 `query:` lines and one `entity:` line, temperature 0, at most 64 tokens, within 2.0 s. The engines have no grammar or JSON-schema hook (the embedded llama.cpp bridge and the llama-server client take only messages, tokens and temperature), and adding one means C++ bridge changes, so the output is constrained by a short line format with few-shot examples and a strict parser: each query 1–10 words, at most 80 characters, no URL, no newline junk; anything else is junk. (3) Fallback when there is no assistant (cloud route, test host), the model fails, times out or returns junk: a code-only clean-up of the typed question (drops question words, auxiliaries, "please", filler and punctuation; keeps entities, numbers, years and qualifiers such as "latest"). (4) At most 2 queries go to DuckDuckGo (its 1 s per-site pacing and D97's rate limits make a third cost a second more and raise the block risk); Wikipedia gets the first query. (5) Merge: each query's results are merged and scored as today, then the per-query scores are summed per URL — reciprocal-rank fusion with k = 0, matching the existing `weight / position` scoring — so a single query ranks exactly as before and the 0.08 cutoff keeps its meaning (the common k = 60 would flatten scores so the cutoff drops nothing).
- **Why:** baseline-3: typed whole-sentence queries searched badly; model-style keyword queries did better. Spec privacy unchanged: the rewrite runs on the Mac and only keywords derived from the question are sent.
- **Alternatives:** grammar-constrained output (needs bridge work; switch in `SearchQueryRewrite`); rewrite for capable models too (set `isTypedQuestion` in the tool path); 3 DuckDuckGo queries (`SearchAssistTuning.maximumSiteQueries`); RRF k = 60.
- **Reversible:** yes.

### D108 — 2026-10-30 12:49, CP7 — How the "enough?" check and its one retry are built (D104, feature 2)

- **Decided (worker CP7):** small-model local path only (an assistant is passed only there; capable models can call `web_search` again). After passages are ordered, the model sees the question and each source's best passages, capped at 600 words (*superseded by D113: 350 words*), and answers `yes` or `no: <missing words>` (temperature 0, at most 24 tokens, within 2.5 s). Junk, a timeout, a failure or `yes` means no retry. On `no`, one more DuckDuckGo search runs with the first query plus the missing words (at most 6 words, cleaned like a query), its new candidates (not read or seen before) are read within a 2.0 s window (*superseded by D113: 1.5 s*), and the new sources join the old before the off-topic check, ordering and collection. At most one retry. A retry that finds nothing keeps the first results.
- **Why:** Nobel literature: the right pages were read but the answer missed the fact; a sufficiency check targets this. Bounded so the worst case stays near the p90 bar.
- **Alternatives:** capable models too; a longer passage cap (slower prefill); no retry, only the judgment (cheaper).
- **Reversible:** yes (`SearchAssistTuning`, the assistant parameter).
- **Update (D122, D124):** the check and its retry may also run on the places route's web search: the retry query holds only what DuckDuckGo already receives. A timed-out call can overrun its limit by one prefill the engine can't interrupt. Page text in the passages can steer the one retry's words, which are capped at 6, carry no URL, and the prompt holds nothing private. The word budget goes to page passages first, then facts and headlines.

### D109 — 2026-10-30 12:49, CP7 — How the Wikidata facts source is built (D104, feature 3)

- **Decided (worker CP7):** `WikidataFacts` uses Wikidata's keyless action API on `https://www.wikidata.org/w/api.php`, with Wikipedia's headers (Wikimedia User-Agent policy: app name, version, project URL; `Accept: application/json`) through the search HTTP client (ephemeral, no cookies). The entity comes from the rewrite's `entity:` line (`wbsearchentities`, first hit) or, without one, from the Wikipedia article this search found (`wbgetentities` by sitelink). Then one `wbgetentities` call for the claims and one for the labels of the values, units and qualifiers. Live probes: full-text search on keyword queries finds nothing useful (keyword queries about the latest Swift release and a Nobel winner returned no items or unrelated ones), while `wbsearchentities` on the entity name found Rust, Swift, Japan, Mount Everest and the Nobel Prize in Literature first. Only a whitelist of properties is shown (versions, population, area, height, elevation, heads of state and government, CEO, capital, currency, founders, inception, dates of birth and death, winners, GDP, employees, headquarters, official website); deprecated statements are dropped; values are ordered newest first by their point-in-time, publication or start date and shown with that date, the preferred value marked "current"; at most 3 values per property (5 for winners). Hosts are fixed and https, so like Wikipedia it doesn't go through `NetworkGuard`, which checks arbitrary result URLs. It runs whatever the recency, since its facts carry dates (Wikipedia skips day and week questions, and "latest" makes a week question). The facts become one `facts` excerpt placed first, kept only when the entity's label shares a content word with the question, within a 2.5 s limit that runs beside the sites and the reading.
- **Why:** facts questions lost 0 of 6; Wikidata holds versions (Rust 1.99.1 preferred, Swift 6.4.2), populations, prize winners with dates.
- **Alternatives:** SPARQL (one query, harder to keep safe and fast); full-text item search (probed, poor); the full claim list (Japan is 1.5 MB, 421 properties).
- **Reversible:** yes; one lane in `OnDeviceSearchProvider`.

### D110 — 2026-10-30 12:49, CP7 — How Google News RSS is built, and what its links do (D104, feature 4)

- **Decided (worker CP7):** trigger: the request's recency is day, week or month (`WebSearchPolicy.recency`: "today", "latest", "recent", "news", "breaking", "this week", "yesterday", "this month") or the question has a news cue ("headline(s)", "announced", "announcement", "election(s)", "who won", "won the", "winner of"). Request: `https://news.google.com/rss/search?q=<query>&hl=<lang>-<COUNTRY>&gl=<COUNTRY>&ceid=<COUNTRY>:<lang>` from the Mac's region, through the search HTTP client (no cookies are stored or sent), with the app's API-style headers (Wikipedia's User-Agent, `Accept: application/rss+xml`). Live probe: the response sets no cookie; each item's `<link>` is `news.google.com/rss/articles/<opaque token>`, which answers 302 to another `news.google.com` URL, and the token is an encoded ID, not the publisher URL (decoding needs Google's own `batchexecute` call). The item's `<source url>` is only the publisher's home page. So no further Google request is made and no publisher page is read: each item's headline, publisher and date are the evidence, up to 8 items newest first, as one `news` excerpt linked to Google News's search page, placed after the facts excerpt.
- **Why:** news lost 0 of 6; headlines with dates make recency visible; following the links would send more requests to Google than the owner approved.
- **Alternatives:** decode links with Google's batchexecute (more Google calls; refused); a wider trigger (more queries to Google).
- **Reversible:** yes; one lane in `OnDeviceSearchProvider`.

### D111 — 2026-10-30 12:49, CP7 — Site-outcome trace finished; step timings traced; two new evidence kinds

- **Decided (worker CP7):** the Haiku worker's `SearchTracing.recordSites` is kept; it now records every lane of a search ("duckDuckGo", "duckDuckGo#2" for the second query, "retry", "wikipedia", "wikidata", "googleNews") with `results:N` or the outcome's name (`noResults`, `blocked`, `rateLimited`, `unrecognized`, `failed`). A new `recordStep(_:milliseconds:outcome:)` (default no-op) records the rewrite's and the check's time and outcome (`model`, `fallback`, `timeout`, `junk`; `yes`, `no`, `skipped`) with no query text, so the evaluation can measure each local-model call. `EvidenceKind` gains `facts` and `news`; the envelope already carries the kind as text.
- **Why:** D102's empty DuckDuckGo answers can't be told apart without it; the speed bar needs each call's latency.
- **Alternatives:** none needed.
- **Reversible:** yes.

### D112 — 2026-10-30 13:01, CP7 — How the features' smoke check runs

- **Decided (worker CP7):** `WebSearchEvaluationTests` gains three switches: `ENIGMA_SEARCH_EVAL_STYLES` (only `typed` here), `ENIGMA_SEARCH_MODEL_URL` (typed style's rewrite and check go to a llama-server the worker starts, as the app's vision path asks Gemma: thinking off, temperature 0), and typed requests now carry `isTypedQuestion`. Each run row gets `steps` (the rewrite's and check's outcome and milliseconds). The provider gets the Wikidata and Google News lanes. The smoke run is `features-1`: the 20 news and facts questions (web-01–08, news-01–06, facts-01–06), typed style, on-device only, no Brave, no answers, no judge. The model is Gemma 4 12B Q5_K_M (D98's answer model, the chat's model for typed style) through the app's own bundled `llama-server` binary, started by the worker and stopped by its PID. The installed app's idle llama-server (not the worker's) already maps the same file; no other model is loaded.
- **Why:** the brief asks for a light live check against baseline-3 with latency per helper call.
- **Alternatives:** the full evaluation (runs after the features land).
- **Reversible:** yes.

### D113 — 2026-10-30 13:07, CP7 — Speed tuning after the first smoke run (features-1)

- **Decided (worker CP7):** features-1 (20 news and facts questions, typed, Gemma 4 12B) measured median 5.90 s and p90 7.63 s against baseline-3's 1.37 s and 2.18 s on the same questions; the rewrite timed out on 10 of 20 at 2.0 s (server time 0.9–1.9 s: about 250 prompt tokens at ~650 tokens/s, then 15–28 output tokens at ~28 tokens/s), and the check took a median 1.75 s (about 1,060 prompt tokens). Changes: the rewrite's limit goes to 2.5 s and its prompt asks for one query unless the answer could take another form; the check sees at most 350 words of passages (from 600); the retry's reading window goes to 1.5 s (from 2.0 s). Then a second smoke run, features-2.
- **Why:** a rewrite that times out half the time costs 2 s and gives nothing; the check's time is mostly prefill, which scales with the passage words.
- **Alternatives:** start DuckDuckGo with the clean-up's query while the model writes its own (hides the rewrite, but sends more queries to DuckDuckGo, D97's rate-limit risk); skip the check when Wikidata answered; a smaller model for the helper calls (would load a second model; not allowed).
- **Reversible:** yes (`SearchAssistTuning`).

### D114 — 2026-10-30 13:13, CP7 — The smoke runs' rewrite time was mostly a stale connection; third run

- **Decided (worker CP7):** features-2 still measured the rewrite at a median 2.33 s (7 of 20 over 2.5 s) while llama-server's own log put each rewrite at 0.7–1.4 s. A keep-alive probe showed llama-server closing an idle connection after about 5 s; the harness pauses 5 s between questions, so every rewrite (the first call after the pause) went out on a dead pooled connection, while the check, about 2 s later, did not (its client time matched the server's). The harness's `ServerAssistant` now opens a fresh connection per call, and a third smoke run (features-3) measures the features. No product change: in the app the rewrite and the check run only on the small-model path (models without native tools), with the embedded text engine (no HTTP). *Corrected (D120, D124):* the installed Gemma and Qwen are native-tools models, so they never run the rewrite or check; but the app's own llama-server session for vision models may meet the same stale connection after 5 s idle on its ordinary requests; that is outside this change and is reported for the owner.
- **Why:** the harness, not the model, was adding the time.
- **Alternatives:** a longer server keep-alive (`--timeout` is the read timeout, not keep-alive).
- **Reversible:** yes.

### D115 — 2026-10-30 13:28, CP7 — Two DuckDuckGo queries stay, though the speed bar isn't met yet

- **Decided (worker CP7):** features-3 (20 news and facts questions, typed, Gemma 4 12B, fresh connections) measured median 4.81 s and p90 6.65 s, over D2's 4.0 s and 6.0 s (baseline-3: 1.37 s and 2.18 s, with fewer sources). The rewrite took a median 1.27 s (p90 1.53 s, all 20 from the model) and the check 1.12 s (p90 1.44 s; 6 of 20 said "no" and retried). Searches that sent a second DuckDuckGo query (10 of 20; it waits 1 s for the site's pacing) took about 4.8–8.0 s; single-query searches without a retry took 2.9–4.5 s. The second query stays (`SearchAssistTuning.maximumSiteQueries = 2`) until the full evaluation's judge shows whether it earns its time; setting it to 1 is the first lever if CP7 keeps the bar, then a shorter retry or skipping the check when Wikidata answered.
- **Why:** the brief asks for distinct queries for different answer shapes; there's no judged evidence yet on their worth; the bar is the owner's and is reported as missed.
- **Alternatives:** `maximumSiteQueries = 1` now (estimated median about 4 s).
- **Reversible:** yes (one constant).

### D116 — 2026-10-30 13:31, CP7 — Speed bar relaxed to 5.0 s / 7.0 s; the second query stays if it improves answers

- **Decided (owner, 2026-10-30):** with D104's features, on-device search
  measured a median 4.81 s and p90 6.65 s (features-3) against D2's 4.0 s and
  6.0 s. The owner relaxes the speed bar to a median of 5.0 s and a 90th
  percentile of 7.0 s, and keeps the second DuckDuckGo query (D115) as long
  as it gives better answers; it is not to be dropped just to save about a
  second. The full evaluation therefore also judges, on the questions where a
  second query runs, one query against two; the second query is dropped only
  if it doesn't improve the answers.
- **Why:** owner preference: better information over about a second.
- **Alternatives:** one query only (estimated median about 4.0 s, D115).
- **Reversible:** yes (the gate's speed constants; `maximumSiteQueries`).

### D117 — 13:33, CP7 — Round-1 run: relaxed speed bar, fair evidence cap, head-to-head judge, one-query override, Brave reused

- **Decided (worker CP7):** (1) `evaluate-web-search.py`'s relaxed speed bar is now median 5.0 s and p90 7.0 s (D116); the original 3.0 s and 4.5 s bars are still reported. (2) The evidence cap (D98) is now a fair share per source (water-filling: a short source keeps all of its text, the rest is shared among the longer ones), so one long page can't take the cap. Brave's contexts are under the cap, so their prompts, and cached answers, don't change; on-device prompts with long sources do. (3) `run_head_to_head` judges two folders' on-device answers blind (order hashed from the question). (4) The one-query A/B uses a test-only parameter, `maximumSiteQueries` on `OnDeviceSearchProvider.init` (default: `SearchAssistTuning.maximumSiteQueries`), set by `ENIGMA_SEARCH_MAX_SITE_QUERIES`; the product default stays at 2. (5) Round 1 runs on-device for all 60 questions in both styles, with the Gemma helper server for the typed rewrite and check, into `runs/round-1`; Brave rows and contexts are copied from `baseline-3`, the cached run.
- **Why:** the owner's bar and the orchestrator's read; a cap that favours short sources would hide the facts a long page holds.
- **Alternatives:** keep the cap per document order (drops late passages); run Brave again (same answers, 120 more searches).
- **Reversible:** yes (each is one constant or one parameter).

### D118 — 14:25, CP7 — Task 7.5 (the live tool-use eval) deferred until the owner says the Mac is free

- **Decided (orchestrator, owner asked to use the Mac):** the tool-use eval on the two installed flagged models is not run now. It needs the local models loaded, and the owner needs the Mac. The eval command and the new prompts are ready (`EnigmaTests/Fixtures/F32/eval.jsonl`, 12 new prompts; `testNewPromptsScoreFromFixtureTranscript` and `testEvalSetIsWellFormed` pass offline). Round-1's gate reports the tool-use row as not run.
- **Why:** owner request.
- **Alternatives:** run it on Gemma only now (still local: not allowed while the owner needs the Mac).
- **Reversible:** yes.

### D119 — 2026-10-30 14:30, CP7 — Opus reviewers, up to three rounds; no tuning round

- **Decided (owner, 2026-10-30):** every review round uses a fresh Opus
  reviewer at effort xhigh (replacing D92's Sonnet reviewers). CP7 is now a
  big change (four features), so it gets up to three rounds: round 2 runs
  unless round 1 finds only small fixes, round 3 only if round 2 still finds
  real issues. The owner judged the early read good enough (typed: on-device
  19, Brave 21, up from 13 to 27), so there is no tuning round: product code
  is frozen for review while round-1's evaluation finishes, and the owner may
  stop the evaluation early, with the report written from the results so far.
  The tool-use eval (Task 7.5) and the full suite wait until the owner is
  away from the Mac.
- **Why:** owner instructions.
- **Alternatives:** Sonnet reviewers (D92); one tuning round.
- **Reversible:** yes.

### D120 — 2026-10-30 14:53, CP7 — Option A: the rewrite and check stay on the small-model path

- **Decided (owner, 2026-10-30):** review round 1 found that the installed
  models (Gemma 4 12B, Qwen 3.8 27B) are native-tools models: they search
  through `web_search` with their own query, so the rewrite and the
  "enough?" check (D107, D108) never run for them in the app. The owner chose
  option A: keep the rewrite and the check for small models without native
  tools; capable models keep their own queries and still get the Wikidata
  and Google News lanes. The unused vision-model branch of the app's
  assistant is removed, and D113's sentence about Gemma's app path is
  corrected. Round-1's typed results therefore describe small models with a
  capable helper, not the installed models' path.
- **Why:** owner choice; the alternative adds about 1.1 s to every capable
  search before there's evidence it helps.
- **Alternatives:** B, also run the "enough?" check for capable models'
  `web_search`; wire the assistant into the vision path's typed search.
- **Reversible:** yes.

### D121 — 2026-10-30 14:53, CP7 — Evaluation stopped after the typed half

- **Decided (owner, 2026-10-30):** the owner stopped the evaluation to move
  on with F29. Round 1 has all typed answers (judged in the cloud to finish
  the typed verdict); the model-style answers (3 of 60 on-device), the
  one-query vs two-query A/B (D116), and the tool-use eval (Task 7.5) are not
  run. The CP7 report and Hand-off are written from these results, and the
  missing checks are listed as not run. The second DuckDuckGo query stays
  (D115, D116) since the A/B didn't run.
- **Why:** owner request; the early read was judged good enough.
- **Alternatives:** finish the model-style half (about 45 minutes of local
  model time).
- **Reversible:** yes (the harness and caches can resume the run).

### D122 — 2026-10-30 14:53, CP7 — Review round 1's fixes, decided on the cautious side

- **Decided (orchestrator):** the worker fixes all of round 1's findings.
  Choices the owner would otherwise make: (1) the Google News lane is skipped
  whenever the request carries a city, so Google never receives a location
  (spec §7 unchanged); (2) a Google News citation links to the item's
  publisher home page (its `<source url>`), or to `https://news.google.com/`
  with no query when there is none, so a click never sends the question to
  Google with the user's cookies; (3) the "enough?" check's word budget gives
  page passages priority, with facts and headlines filling what is left;
  (4) the check and retry may run on the places route (the retry query holds
  only what DuckDuckGo already receives), noted in D108; (5) D108 also notes
  that a timed-out call can overrun by one uninterruptible prefill, and that
  page text can steer the one retry's words (at most 6, no URLs, nothing
  private in the prompt).
- **Why:** never send more off the Mac than the spec allows; the reviewer's
  scenarios.
- **Alternatives:** amend §7 to allow the city and the query link instead.
- **Reversible:** yes.

### D123 — 2026-10-30 14:53, CP7 — Review round 2 runs

- **Decided (orchestrator):** round 1 found two Blockers, so a fresh Opus
  reviewer (effort xhigh) checks the fixes in round 2 (D119).
- **Why:** owner rule for big changes.
- **Alternatives:** none.
- **Reversible:** yes.

### D124 — 2026-10-30 14:54, CP7 — How review round 1's fixes are built

- **Decided (worker CP7):** (1) Cancellation: the search checks for cancellation right after the query plan, so a stop during the rewrite sends nothing to Google or Wikidata; the news and facts tasks are awaited through a cancellation handler that cancels them with the search, are cancelled when the search ends either way, and Wikidata's lookup stops between its requests once cancelled. Unstructured tasks stay (the facts task may start after the sites, from Wikipedia's title) rather than restructuring the pipeline into one task group. (2) Google News is skipped whenever the request has a city (D122.1). (3) The news excerpt links to the newest headline's publisher home page (its `<source url>`, https or http only), else `https://news.google.com/`; its title is "Google News headlines", without the query (D122.2). (4) Wikidata times carry their precision (9 year, 10 month, 11 day; coarser shows the year), and statements sort by a signed numeric date, so BCE dates order correctly. (5) The check's word budget goes to page passages first, then facts and headlines (D122.3). (6) The vision branch of the app's search assistant is removed (D120): the small-model path runs only the embedded text engine, and a vision model there gets no assistant (code-only clean-up, no check). (7) Tests added for each finding, including view-model tests for the typed-question flag.
- **Why:** review round 1, D120, D122.
- **Alternatives:** one task group for every lane (larger change during review).
- **Reversible:** yes.

### D125 — 2026-10-30 15:11, CP7 — Round 2's fixes; Google News kept under its feed terms; no round 3

- **Decided (owner and orchestrator, 2026-10-30):** review round 2 found no
  Blocker and four Should fixes. (1) Blocked sites apply to the new lanes:
  the facts excerpt is skipped when its URL is blocked, the news lane when
  `news.google.com` is blocked, and headlines whose publisher is blocked or
  on the unsafe lists are dropped. The news citation links to
  `https://news.google.com/` with no query (revising D122.2), because one
  excerpt holds several publishers' headlines, so blocking from it
  blocks Google News. (2) The code-only clean-up keeps proper nouns: a
  capitalized stop-word is dropped only as the first word, "I" after a
  capitalized word stays, and "how to" stays. (3) Tests for the facts and
  news lanes' cancellation. (4) **Owner:** keep Google News RSS despite its
  feed terms ("a personal feed reader for personal, non-commercial use"),
  accepting the terms risk as F29 already does for the search sites. Also
  noted: D122's "Google never receives a location" covers the request's
  city; a query the model wrote with a place name in it is sent as written,
  as spec §7 says. The round-2 reviewer judged these small, so per the
  owner's rule there is no round 3; the orchestrator checks the fixes by
  re-running the affected tests and the three surviving mutants.
- **Why:** reviewer round 2; owner choices.
- **Alternatives:** drop the Google News lane; a round 3.
- **Reversible:** yes.

### D126 — 2026-10-30 15:12, CP7 — How round 2's fixes (D125) are built

- **Decided (worker CP7):** (1) Blocked sites use `SourceQuality.isBlocked` (the user's list, unsafe, spam, Perennial and Enigma's own): the facts excerpt is dropped when its Wikidata URL is blocked; the news lane isn't asked at all when `https://news.google.com/` is blocked; a headline whose publisher home page is blocked is dropped, and an excerpt left empty is dropped. The news citation is always `https://news.google.com/` (D125). (2) The clean-up: a stop-word is dropped anywhere when lowercase; a capitalized one only as the first word, except "Will" or "May" followed by a capitalized word ("Will Smith"); "I" stays after a capitalized word ("World War I"); "how to" stays. (3) Domain-like words: both the rewrite's and the check's parsers reject a word starting with `www.` or ending in a common top-level domain (`.com`, `.org`, `.net` and others), not version numbers such as "3.12" or "node.js". (4) The optional `withTaskCancellationHandler` around the whole body isn't added: the lanes are already cancelled at the point they're awaited and on exit, and the new tests pin both.
- **Why:** D125; the reviewer's cases.
- **Alternatives:** a capitalization rule with no name exceptions (loses "Will Smith").
- **Reversible:** yes.

### D127 — 2026-10-30 15:33, CP7 — Verification before the commit

- **Decided (orchestrator):** the orchestrator checked round 2's fixes itself
  (no round 3, D125): with the `!Task.isCancelled` guard in
  `WikidataFacts` removed, `testStoppingWhileWikidataAnswersEndsTheSearchAndSendsNoMore`
  fails, and with it restored `SearchAssistTests`, `SearchFactsAndNewsTests`,
  `OnDeviceSearchTests` and `NativeToolsEvalTests` pass (96 tests). The full
  suite (screen unlocked) ran 2009 tests with 39 skipped and one failing
  test: F30's `NativeWebSearchEvaluationTests.testQuestionSetIsWellFormed`,
  which read all 60 questions after CP7 grew the shared file. Like D96's
  Python change, F30's Swift loader now reads only its 20 `web-` questions;
  that class and `WebSearchEvaluationTests` pass. The full suite isn't run
  again for this test-only change. Build and analyze succeed with no
  warnings.
- **Why:** AGENTS.md's one full suite per change; the fix touches only F30's
  test loader.
- **Alternatives:** a second full suite (about 10 minutes of the owner's
  screen).
- **Reversible:** yes.

### D128 — 2026-10-30 15:34, CP8 — On-device by default; Brave only with a saved key

- **Decided (owner, 2026-10-30):** CP7's relaxed gate failed (typed: on-device
  equal or better on 47%, bar 65%), so D4 would keep Brave as the default.
  The owner chose instead: on-device search becomes the default for
  everyone, so search, `/search`, `/maps` and the models' search tools work
  with no key; Brave is used only when a Brave key is saved, and isn't
  removed. Changes to CP8's brief: the Brave client and key storage stay;
  the launch-time Keychain cleanup is dropped (the key now selects Brave);
  the Debug-only provider switch is replaced by the key rule; Settings'
  Web search section shows on-device as the default with the Brave key as an
  optional extra; the welcome screen's Brave field goes. "Never use this
  site", F30's blocked domains, the new error messages and `/search` always
  available stay as the brief says.
- **Why:** keyless search by default while key holders keep Brave's
  stronger answers on news, docs and reviews.
- **Alternatives:** keep Brave the default (D4); remove Brave (the original
  CP8).
- **Reversible:** yes.

### D129 — 2026-10-30 15:37, CP8 — Where the Brave-or-on-device choice lives, and when it updates

- **Decided (worker CP8):** `LocalChatViewModel` holds two providers: `webSearch` (on-device by default, `OnDeviceSearchProvider.live()`) and an optional `braveSearch` (`BraveSearchClient()` in `.shared` only). Each search, and each `web_search` call, picks Brave when `braveSearch` is set and `WebSearchSettings.hasAPIKey` is true, otherwise on-device. `hasAPIKey` is published and changes on save and remove, so the next search after a key is added or removed uses the new provider, with no relaunch. `WebSearchProviderFactory` and its Debug key `webSearch.debugProvider` are removed. Tests that inject only `webSearch` never reach Brave, even with a key in their settings, so no test can call Brave's network by accident.
- **Why:** the view model already reads the settings on the main actor and needs to know which provider ran (footer, budget fitting, Brave's blocked-site filter); one rule in one place.
- **Alternatives:** a composite provider in `Search/` that reads the key at each search (the caller would still need to ask which one it used). Switch: `LocalChatViewModel.searchProvider`.
- **Reversible:** yes.

### D130 — 2026-10-30 15:37, CP8 — `missingAPIKey` and the other Brave-only errors

- **Decided (worker CP8):** `invalidAPIKey`, `requestFailed` and `missingAPIKey` stay, for the Brave path only, with wording that names Brave and the renamed section ("Settings → Cloud and search → Web search"). When Brave reports `missingAPIKey` (the key was deleted outside Enigma, for example in Keychain Access, while the setting still says it's saved), the search runs on-device instead, since no key means on-device (D128). `unavailable`, `rateLimited` and `noResults` take the brief's exact messages, which are written for on-device search and also read correctly for Brave; `invalidResponse` becomes "A search site returned an invalid response. Try again."
- **Why:** D128 keeps Brave; its key and server errors still need messages.
- **Alternatives:** remove `missingAPIKey` and show nothing (the fallback makes it unreachable from search apart from saving an empty key, which the UI already disables).
- **Reversible:** yes.

### D131 — 2026-10-30 15:37, CP8 — The footer, gate 3's card and other labels name the provider used

- **Decided (worker CP8):** `ReplyOrigin` gains `braveSearch` (session-only, like the rest of the origin), set when Brave answered one of the reply's searches; the footer says "brave search" then and "web search" otherwise (on-device or the provider's own). Gate 3's card for `web_search` after message text says "It will be sent to Brave." when Brave would run and "It will be sent to search sites." otherwise (`searchAfterMessages` gains a `service` with that default). `AutoRouter`, `searchNote`, `locationExplanation` and the gallery placeholder take spec §8's text; `locationExplanation` adds no Brave clause, since Brave gets only what the search sites get (the city), as before.
- **Why:** D128: show the provider actually used.
- **Alternatives:** always "web search" (the original brief).
- **Reversible:** yes.

### D132 — 2026-10-30 15:37, CP8 — Blocked sites also filter Brave's results

- **Decided (worker CP8):** Brave's results are filtered in the view model after the search: a result whose host is a blocked domain or under it is dropped, and nothing left gives `noResults`. Checked first: Brave's client never saw the list. F30's provider search gets the list as the brief says (Task 8.5b).
- **Why:** "Never use this site" must hold whichever provider runs.
- **Alternatives:** ask Brave to exclude them in the query (`-site:`), which leaks the list to Brave and is capped by query length.
- **Reversible:** yes.

### D133 — 2026-10-30 15:37, CP8 — Settings and welcome text under D128

- **Decided (worker CP8):** the Settings section keeps the brief's rows and adds, after the status row, an optional Brave row: "Use Brave Search instead", subtitle "Optional. With a saved key, searches go to Brave instead of running on this Mac. Needs a Brave Search API key with LLM Context access; Brave bills it separately. Stored in macOS Keychain.", with the key field, Save key and Remove key, and the status `key saved` or `not used`. The status row reads "ready" with no key, and "Brave in use" (`.on`) with one. The note names CP0b's and CP7's lineup (DuckDuckGo and Wikipedia, Wikidata for facts, Google News headlines for news) rather than Mojeek and Startpage, which aren't used. The welcome row is the brief's, with no Brave field.
- **Why:** D128; spec §8 says CP8 adjusts the site names to the lineup.
- **Alternatives:** keep the key in an advanced disclosure.
- **Reversible:** yes.

### D134 — 2026-10-30 15:37, CP8 — No launch cleanup; the brief's cleanup tests are not written

- **Decided (worker CP8):** `BraveKeyCleanup`, its launch call and its three tests (`testBraveKeyCleanupRunsOnce`, `…RetriesAfterFailure`) are dropped (D128). Brave's own tests (wire format, key storage, redirect blocker) stay, since the client stays. The exit criterion "`grep -i brave` lists only the cleanup" no longer applies.
- **Why:** D128.
- **Alternatives:** none.
- **Reversible:** yes.

### D135 — 2026-10-30 15:37, CP8 — Scope cut for usage: no review round by this worker

- **Decided (worker CP8):** weekly usage was 87% at the start against the 92% stop; the worker builds and tests the change and leaves the review rounds to the orchestrator.
- **Why:** agent-rules usage stop.
- **Alternatives:** none.
- **Reversible:** yes.

### D136 — 2026-10-30 15:53, CP8 — Brave gets only the city; the blocked-sites note names who can't enforce it

- **Decided (worker CP8):** (1) Brave's query used to carry "Approximate current location: <area> (<lat>, <lon>)"; it now carries only the city, as the search sites do, and nothing without one. Spec §7 says coordinates never go to a search provider, and Brave is one again (D128). `testBraveAppendsLocationFromRequest` expects the city alone; `testBraveUsesUnknownAreaWithoutCity` became `testBraveSendsNoCoordinatesWithoutCity`. (2) Spec §8's sentence "…but only Anthropic enforces it" is wrong for the merged code: only ChatGPT and Claude Code use their provider's search (`CloudProviderID.nativeWebSearchProviders`), and the Anthropic API's `blocked_domains` tool isn't in the code. The note reads "ChatGPT and Claude Code, when they use their own search, are asked to avoid these sites, but Enigma can't enforce it." `ProviderSearch.blockedDomains` is filled anyway for when a provider can enforce it. (3) `locationExplanation` takes spec §8's text unchanged, which is now true for Brave too.
- **Why:** never send more than the spec allows; the code, not the spec's assumption.
- **Alternatives:** keep Brave's coordinates and add a Brave clause to `locationExplanation` (`BraveSearchClient.search(_:)`).
- **Reversible:** yes.

### D137 — 2026-10-30 15:53, CP8 — Smaller choices

- **Decided (worker CP8):** `OnDeviceSearchProvider.live()` in the test host uses `OfflineSearchHTTPClient` (every request fails at once) and a MapKit search that fails, so a default-constructed view model never reaches the network. `KeyboardShortcutsHelpView` loses its `searchSettings` parameter (it only gated the search rows). `WelcomeSetup.Activity.isEnteringKey` and the welcome's key-field state go, since no welcome field takes a key. The Settings empty-list note gets the test marker "No blocked sites". Source rows keep their link and show **Undo** beside it after blocking; "Never use <domain>" is a context-menu item and an accessibility action. `docs/Web-Search.md` and `docs/Slash-Commands.md` are left for CP10, as the brief's starting-point table says.
- **Why:** the brief's interfaces and "no dead key UI or plumbing".
- **Alternatives:** none needed.
- **Reversible:** yes.

### D138 — 2026-10-30 21:10, CP8 — With a Brave key, places and weather stay on-device

- **Decided (reviewer CP8, round 1):** Brave answers only `.web` requests. `.places` and `.weather` (from `/maps`, typed questions, screen, selection and attachments) stay on Apple Maps and Open-Meteo even when a Brave key is saved.
- **Why:** with a key, `search()` sent every route to Brave as a text query, so `/maps coffee` or "weather in Paris" on a small model lost CP6's places and weather answers, and the Settings note and `locationExplanation` became untrue.
- **Alternatives:** send all routes to Brave (the CP8 build before this fix) in `LocalChatViewModel.search`.
- **Reversible:** yes.

### D139 — 2026-10-30 21:10, CP8 — Online seam for live tests; offline places and weather defaults in the test host

- **Decided (reviewer CP8, round 1):** `OnDeviceSearchProvider.live()` gains an explicit online switch so `WebSearchLiveTests` and F30's evaluation keep reaching the network when opted in, while the test host's default stays offline. F30's evaluation injects `braveSearch` for its "brave" backend. The view model's default `placeSearch`, `weatherLookup` and `weatherGeocoder` are offline in the test host, which makes D137's claim true.
- **Why:** D137's offline guard silently broke the opt-in live tests, and the places and weather defaults still reached MapKit and Open-Meteo.
- **Alternatives:** keep the live defaults and rely on every test replacing them.
- **Reversible:** yes.

### D140 — 2026-10-30 21:10, CP8 — One review round; the orchestrator verifies the fixes

- **Decided (orchestrator):** no round 2. Round 1 found no Blocker and four small Should fixes (one route condition, test seams, one new test, one sentence), and the reviewer judged round 2 unnecessary. Per the owner's rule ("only 1 or 2 if reviewer 1 or 2 comes back with only small fixes"), I check the fixes with targeted test runs and a mutant for the gate 3 label. The nits are fixed too, except the Undo state living in the row (it can vanish if the sources list collapses), which is left as a known limitation. Brave's own errors now name Brave, superseding that part of D130.
- **Why:** owner's review rule; usage at 88%.
- **Alternatives:** run round 2 with a fresh Opus reviewer.
- **Reversible:** yes.

### D141 — 2026-10-30 16:11, CP8 — How review round 1's nits are built

- **Decided (worker CP8):** (1) `search` is a wrapper over `searchReportingProvider`, which returns whether Brave answered; `web_search`'s fitting uses that, not a value read before the search. (2) On `missingAPIKey`, `WebSearchSettings.refreshKeyState()` rereads the Keychain, so Settings, gate 3 and the next search stop naming Brave. (3) New cases `braveRateLimited`, `braveUnavailable`, `braveInvalidResponse` with Brave-named messages; the view model maps Brave's errors through `namingBrave`, so `BraveSearchClient` and its tests keep the shared cases, and the on-device messages stay the brief's. (4) The footer's record is one `braveSearchRequest: UUID?`, reset in `beginGeneration`, not a set that grows. (5) `NativeToolPlanTests`' dead key loops are removed (counts 6 × 8 and 8). (6) `ScreenNativeSmokeTests`' live mode uses `OnDeviceSearchProvider.live(offline: false)`. (7) `MapKitPlaceSearch.offline` is shared by `live()` and the view model's test-host defaults.
- **Why:** review round 1.
- **Alternatives:** have `BraveSearchClient` throw the Brave cases itself (changes its tests and the evaluation's).
- **Reversible:** yes.

### D142 — 2026-10-30 16:11, CP8 — The reading sentence and the "what leaves the Mac" table

- **Decided (worker CP8):** Settings' note says "Result pages are read on this Mac, up to six at a time, without scripts or images." Spec §7's table gains a Brave row (only with a saved key: query, city only, the key, the IP address; web searches only) and says result sites are read up to 6 at a time; §8's note and the Goals line are marked amended. The plan's goal and CP8 row say Brave stays with a saved key.
- **Why:** review round 1; six is the reading concurrency, not a total.
- **Alternatives:** state a total cap (none exists in the code).
- **Reversible:** yes.

### D143 — 2026-10-30 16:11, CP8 — Tests for round 1, and a mutation check

- **Decided (worker CP8):** new `WebSearchTests.testPlacesAndWeatherNeverReachBrave` and `testBraveFailuresNameBraveAndMissingKeyRefreshesState`, `NativeToolRequestTests.testSearchAfterMessagesCardNamesTheProviderUsed` (with `makeChat(braveSearch:)`), and an offline assertion on the test host's default provider in `testBraveRunsOnlyWithASavedKey`. Mutants "Brave for every route" and "gate 3 always says search sites" each fail their test; the code was restored from a copy.
- **Why:** review round 1, item 3.
- **Alternatives:** none.
- **Reversible:** yes.

### D144 — 2026-10-30 22:05, CP8 — Commit with one known flaky UI test

- **Decided (orchestrator):** CP8 is committed although the full suite had one failure, `EnigmaMainWindowTests.testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField` (timeout at "the held message pending, the stopped draft back in the field"). The full suite ran 2022 tests: 40 skipped, 1 failure.
- **Why:** the same seven UI classes run back to back fail this test the same way on CP7's commit `82e5fb3` (242 tests, 1 failure) and on CP8 (245 tests, 1 failure). It passes alone and in its class alone. So it is an existing timing flake under load, not caused by CP8. Logs: `/private/tmp/claude-501/f29-cp8/ui-base.log`, `ui-cp8.log`, `full-suite.log`.
- **Alternatives:** fix the test's timing as a separate change (it isn't F29's); watch it on CI.
- **Reversible:** yes.

### D145 — 2026-10-30 16:34, CP9 — The live map exists only while the card is on screen

- **Decided (worker CP9):** the brief and spec say the card is built when its row appears in the message list's lazy stack, but `EnigmaMessageList` is a plain `VStack` (its comment explains why it stopped being lazy). `MapCardView` instead swaps its `Map` for a same-size placeholder unless `onScrollVisibilityChange(threshold: 0.01)` reports it on screen, so no live map is kept once it scrolls away. The test host always gets the placeholder (`MapCardView.drawsLiveMap`).
- **Why:** the code no longer matches the brief's starting point; making the list lazy again would bring back the empty-space bug its comment describes.
- **Alternatives:** make the message list lazy (reopens that bug); keep the `Map` alive for every card (more memory in long chats). Switch by removing the `isOnScreen` condition in `MapCardView.body`.
- **Reversible:** yes.

### D146 — 2026-10-30 16:34, CP9 — When places reach the reply

- **Decided (worker CP9):** every search route collects places in `LocalChatViewModel.replyPlaces[messageID]` (the small-model `submit`, the screen path, cloud with search, and `find_places` on capable turns), merged in arrival order without duplicates by identifier. `finishGeneration` moves them onto `ChatMessage.mapPlaces` for every ending (finished, Stop or error) when the reply has text, then clears the store. `ConversationTranscript.Reply.mapPins` is nil while the reply is in progress, a second guard. `replyPlaces` became private.
- **Why:** spec §6.6 "on any route" and "appears once the reply finishes, so the pins match the text"; a stopped reply keeps its partial text, so its pins still match it.
- **Alternatives:** attach only on success (change the `attachReplyPlaces()` call to run under `error == nil, !Task.isCancelled`).
- **Reversible:** yes.

### D147 — 2026-10-30 16:34, CP9 — Pin matching details and the singular label

- **Decided (worker CP9):** text and names are folded for case and diacritics, `’` becomes `'`, and both are split into words on anything that isn't a letter or digit; a name matches as a contiguous run of whole words, a leading "The" dropped from names of two words or more. Where one name's match lies inside a longer name's match ("Joe's Pizza" inside "Joe's Pizza Broadway"), only the longer one counts there. Ties keep result order. One place reads "Map of 1 place".
- **Why:** the brief's "normalized substring search on whole words"; the overlap rule keeps a short name from pinning the wrong place.
- **Alternatives:** drop the overlap rule (both would pin); "Map of 1 places" verbatim.
- **Reversible:** yes.

### D148 — 2026-10-30 16:34, CP9 — The card's look

- **Decided (worker CP9):** 190 pt `Map` in `.standard` style, no map controls, camera on a region fitting the pins with a 1.5× margin and at least 0.01° across; pins are 22 pt circles in `textPrimary` with the number in `background` (SF Mono, semibold) and a `surface` ring, titled with the place name; 6 pt continuous corners and a `hairline` edge (`EnigmaEdgeStroke`), as the sources panel's rows; **Open in Maps** is a text button under the map's trailing edge, so nothing covers Apple's logo or legal link.
- **Why:** UI-Style allows one `accent` control per view, and several pins would break that; the button below the map keeps attribution clear at every width.
- **Alternatives:** `accent` pins; `.automatic` camera (zooms very close on one pin).
- **Reversible:** yes.

### D149 — 2026-10-30 16:34, CP9 — Scrolling passes through the map

- **Decided (worker CP9):** besides `interactionModes: []`, the live map has a transparent overlay (`MapScrollPassThrough`) that takes only scroll-wheel events and hands them to the enclosing scroll view; clicks, hovers and everything else reach the map, its pins and its legal link.
- **Why:** reviewer checklist "the map never takes scrolling"; an `MKMapView` with panning off may still swallow the wheel.
- **Alternatives:** none without covering the pins. Remove the `.overlay` to compare in the signed app.
- **Reversible:** yes.

### D150 — 2026-10-30 16:34, CP9 — Opening Apple Maps

- **Decided (worker CP9):** `MapCardOpener.appleMaps` asks MapKit for the place by its identifier (`MKMapItemRequest`) and falls back to an item at the coordinate with the name; one place uses `openInMaps()`, several `MKMapItem.openMaps(with:)`. The view takes the opener as a parameter, so tests never open Maps.
- **Why:** opening the real place shows its details; the fallback covers places without an identifier.
- **Alternatives:** always the coordinate item (no request to Apple).
- **Reversible:** yes.

### D151 — 2026-10-30 16:34, CP9 — How the view tests check the card

- **Decided (worker CP9):** view tests host the card in a borderless window at −10,000 that is never ordered front or made key, and find controls by test markers (each pin's marker is named by its VoiceOver label). The accessibility tree is empty and synthetic clicks don't fire in such a window, so the pin and Open in Maps actions are tested through `MapCardActions` (what the buttons call), and the card's label through `MapCard.label(count:)`.
- **Why:** the run must not take the owner's screen.
- **Alternatives:** a hosted window test with `clickTestControl` (takes the screen; for CP10 or the owner's check).
- **Reversible:** yes.

### D152 — 2026-10-30 16:34, CP9 — Steps left to the owner and the orchestrator

- **Decided (worker CP9):** not attempted: Task 9.3's check in a signed app and Task 9.4's screenshot (owner steps, in the Hand-off); no hosted UI class was run (none was changed; `EnigmaConversationTests` and the other message-list window classes are for the full suite before the commit); no reviewer round and no full suite (the orchestrator's). The `CodingKeys` mutation wasn't run: `MapPlace` isn't `Codable`, so adding `mapPlaces` there fails to compile, and `testMapPlacesAreNeverSaved` covers the saved JSON.
- **Why:** the orchestrator's instructions for this run.
- **Alternatives:** run them now.
- **Reversible:** yes.

### D153 — 2026-10-30 22:45, CP9 — A stopped reply with text keeps its card; places never attach late

- **Decided (orchestrator, from review round 1):** D146 stands: a reply stopped with text shows its card. `stopStreaming()` attaches the places before it clears the active request, and places from a request that is no longer active are dropped, so they can never attach at a later request's end or in another chat. A provider-search restart clears the reply's places.
- **Why:** round 1 showed a stopped reply's places staying in memory and attaching when the next request finished, possibly in another chat (S1), and a restarted reply keeping the first run's places (S2).
- **Alternatives:** clear the places on Stop, so stopped replies show no card (`LocalChatViewModel.stopStreaming`).
- **Reversible:** yes.

### D154 — 2026-10-30 22:45, CP9 — Owner's Recents check relaunches first; pin names hidden

- **Decided (orchestrator):** (1) The owner's "reopened from Recents shows no card" check is done after relaunching the app: within one run, switching chats keeps the session-only card, as it keeps `activity` and `origin`. (2) The pins show their numbers only (`.annotationTitles(.hidden)`); the names are in the reply and each pin's accessibility label, and ten name labels crowd a 190 pt map.
- **Why:** round 1 nits N9 and N5.
- **Alternatives:** show the titles (`MapCard.swift`), to judge in the signed app.
- **Reversible:** yes.

### D155 — 2026-10-30 22:45, CP9 — A short review round 2

- **Decided (orchestrator):** run round 2, focused on `stopStreaming`, `restartNativeReply`, `addReplyPlaces` and the new tests.
- **Why:** round 1's S1 was a real bug (places attaching to the wrong reply), so this is more than small fixes under the owner's rule.
- **Alternatives:** none.
- **Reversible:** yes.

### D156 — 2026-10-30 16:55, CP9 — No stale places: request-scoped, cleared at every start

- **Decided (worker CP9):** `addReplyPlaces` takes the request's ID and drops places when that request isn't running (so a `find_places` result after Stop is lost). `stopStreaming()` attaches the places before clearing `activeRequest` (D153), `restartNativeReply` drops the restarted message's places, and `beginGeneration` clears the store, so nothing from an earlier request can reach a later reply in any chat. Small-model, screen and cloud-with-search routes add a places result only when its source is in `grounded.sources`, the evidence the model saw (review N6).
- **Why:** review round 1, S1, S2 and N6.
- **Alternatives:** key the store by request ID as well as message ID (more state for the same effect).
- **Reversible:** yes.

### D157 — 2026-10-30 16:55, CP9 — Camera, matching and opening after review

- **Decided (worker CP9):** the camera is an `MKMapRect` union of the pins, padded 1.5×, at least 1 km across, intersected with the world rect (N2). "&" reads as "and"; a name with no words besides "The" never matches (N7). Open in Maps starts every identifier lookup at once, waits for each at most 2 s (`MapCardOpener.lookUpTime`) before using the coordinate and name, opens in pin order, ignores clicks while one is running (`MapCardOpening`), and does nothing in the test host (N3, N8). Off screen in the app the placeholder is a plain surface hidden from VoiceOver; only the test host's placeholder has pin controls (N4).
- **Why:** review round 1.
- **Alternatives:** a 1 s or 3 s lookup time (change `lookUpTime`).
- **Reversible:** yes.

### D158 — 2026-10-30 16:55, CP9 — New route tests use local fakes

- **Decided (worker CP9):** `MapCardTests` gets its own vision server (`MapCardVision`, answering without a model) and cloud provider (`MapCardCloud`) fakes to cover the screen path and cloud with search, plus `HeldPlaces` for a MapKit search that waits until released. The restart test (`testRestartDropsTheFirstRunsPlaces`) is in `NativeToolRequestTests`, which has the restart harness.
- **Why:** review round 1, S2 and S3.
- **Alternatives:** share the fakes in a support file.
- **Reversible:** yes.

### D159 — 2026-10-30 23:20, CP9 — Round 2: Open in Maps' time limit resumes the wait itself; the request guard gets a test

- **Decided (orchestrator, from review round 2):** (1) The 2 s identifier lookup resumes on whichever comes first, MapKit's answer or the timer, which cancels the request and resumes with nothing; it no longer waits for a cancelled request to call back, because MapKit never calls back an `MKMapItemRequest` cancelled while loading (checked on macOS 27.2). A test with a lookup that never answers checks it returns promptly. (2) `addReplyPlaces`'s request-ID guard gets a direct test through an internal seam; it matters on the ChatGPT (Codex) route, whose tool calls can land after Stop. (3) A screen fallback that grounds the results again replaces the reply's places rather than merging into the first attempt's.
- **Why:** round 2 found that a stalled lookup hung Open in Maps and disabled the card's controls for the session (a regression from the round-1 fix), and that the guard had no test.
- **Alternatives:** none for (1); for (3), keep merging (`LocalChatViewModel` screen fallback).
- **Reversible:** yes.

### D160 — 2026-10-30 23:20, CP9 — Accepted limits; no round 3

- **Decided (orchestrator):** accepted and listed as limitations: on ChatGPT, a `find_places` call running in parallel with the Messages read that restarts the reply can land on the restarted reply, as its sources already can (round 2 N2); places past a truncated places excerpt can be pinned when the reply names none (N3). No round 3: round 2 found one small fix plus a test, which I verify with targeted runs.
- **Why:** owner's review rule; both limits are narrow and match existing behaviour.
- **Alternatives:** a per-run epoch checked in `onPlaces` and `onSources`; limit places to names in the kept excerpt; a round 3 reviewer.
- **Reversible:** yes.

### D161 — 2026-10-30 17:17, CP9 — The place lookup's time limit resumes the wait itself

- **Decided (worker CP9):** `MapCardOpener.lookUp(within:start:cancel:)` waits on a checked continuation that the first of two things resumes: MapKit's completion handler (`getMapItem`) or the 2 s timer, which cancels the request and resumes with nil; a main-actor `ResumeOnce` lets only the first through. Open in Maps then falls back to the coordinate and name, and `MapCardOpening` frees the card for the next click. `testLookUpGivesUpWhenMapKitNeverAnswers` drives it with a lookup that never answers (50 ms limit); a mutant whose timer only cancels times out that test.
- **Why:** review round 2, S1 (D159): MapKit never calls back a request cancelled while loading, so awaiting the cancelled request hung Open in Maps and blocked the card's later clicks.
- **Alternatives:** none safe; a task group waits for the hung child.
- **Reversible:** yes.

### D162 — 2026-10-30 17:17, CP9 — A late request's places, and the screen fallback

- **Decided (worker CP9):** `addReplyPlaces(_:messageID:requestID:)` is internal so `testPlacesForAnEndedRequestAreDropped` can hand it a stopped request's places while the next request runs; a mutant without the request check fails that test. The screen path clears the reply's places before adding the grounded ones, so a fallback to the local vision model replaces the first attempt's places instead of merging (no test: the cloud-to-local fallback needs a cloud screen failure fixture).
- **Why:** review round 2, S2 and N1 (D159).
- **Alternatives:** a test seam on the view model instead of internal access.
- **Reversible:** yes.

### D163 — 2026-10-30 23:50, CP9 — Commit with one unrelated flaky test

- **Decided (orchestrator):** CP9 is committed although the full suite (2050 tests, 40 skipped) had one failure: `ClaudeCodeSubscriptionTests.testClaudeCodeRestartDeliversNothing`, which couldn't open the "input" file its fake Claude Code process writes. CP9 touches neither that class nor the Claude Code client, and the class passes alone (37 tests, 0 failed). The D144 flake didn't occur this time.
- **Why:** a timing race in F30's test under full-suite load, not caused by CP9. Logs: `/private/tmp/claude-501/f29-cp9/full-suite.log`, `claude-rerun.log`.
- **Alternatives:** make that test wait for the fake process's file as a separate change; watch it on CI.
- **Reversible:** yes.

### D164 — 2026-10-30 17:30, CP10 — The docs follow D128, not the brief's "Brave removed"

- **Decided (worker CP10, per the orchestrator's brief update):** the docs describe on-device search as how search works, with no setup, and Brave as an optional alternative in Settings that runs only while a key is saved and only for web searches (D128, D136, D138). No doc describes Brave as required or as the default; the exit check becomes "`grep -i brave` shows Brave only as the optional key, its privacy row, history and the Brave browser". There is no key cleanup to document (D134), and the release note doesn't say the key was removed. CP7's rewrite and "enough?" check (small models only, D120), Wikidata facts and Google News headlines (D104, D109, D110, D125) are documented with what each sends where. Every number in `Web-Search.md` is taken from the code (`OnDeviceSearchTiming`, `SearchAssistTuning`, `RankingTuning`, `WebSearchLimits`, the engines' and lookups' constants), not the brief or spec. The final audit, live network checks, the signed-app check and the merge are left to the owner and listed in the Hand-off.
- **Why:** owner decisions D128 and D134 supersede the brief's Task 10.1 item 6, Task 10.2's exit check and Task 10.6's release note.
- **Alternatives:** none; the brief's wording would describe code that doesn't exist.
- **Reversible:** yes.

### D165 — 2026-10-30 17:30, CP10 — How the ddgs watch compares and reports

- **Decided (worker CP10):** `scripts/check-ddgs-upstream.py` reads the repository (`owner/name`) and the recorded tag and blob SHAs from `UPSTREAM.json`'s real shape (`tag`, `files.<path>.blob`), asks `releases/latest` for the newest tag, then `contents/<path>?ref=<tag>` for each recorded file, and lists a path as changed when its `sha` differs from the recorded `blob` or the file is gone (404). It prints `{"tag", "changed", "compare"}` with `compare` from the recorded tag to the latest. It sends `GITHUB_TOKEN` as a bearer token only when that variable is set (the workflow sets it; locally it runs anonymously), with a fixed User-Agent and the GitHub JSON media type, a 30 s timeout, and only to `api.github.com`. `--api-fixtures <folder>` reads `release.json` and `contents/<path>.json` instead (a missing file is a 404). Any other HTTP error, bad JSON or an unreadable `UPSTREAM.json` exits 1. Fixtures are in two folders: `unchanged/` holds trimmed copies of the real v9.16.1 responses; `changed/` is synthetic (a made-up blob SHA for `duckduckgo.py` and a nonexistent tag, v9.17.0). *(Corrected in review round 1, D173.)*
- **Why:** blob SHAs are what CP2 recorded and what the contents API returns, so no file body is downloaded; a removed file needs porting attention too.
- **Alternatives:** compare commits (`compare` API) and filter its file list (one call, but its file list is capped at 300 and includes unrelated files); download and hash file bodies.
- **Reversible:** yes.

### D166 — 2026-10-30 17:30, CP10 — The workflow's issue handling

- **Decided (worker CP10):** `.github/workflows/ddgs-watch.yml` runs the script on `ubuntu-latest` with `actions/checkout` pinned to ci.yml's SHA and `persist-credentials: false`, a 10-minute limit and workflow-level permissions `contents: read`, `issues: write`. When `changed` isn't empty, `gh` ensures the `ddgs-upstream` label exists (`gh label create --force`, which needs only `issues: write`), then edits the newest open issue with that label (title and body) or creates one, titled "ddgs changed: <files> (<tag>)" and linking the compare URL. Values reach the shell only through `jq` reading the script's output file, never through `${{ }}` interpolation. `actionlint` isn't installed here, so the owner runs the workflow once through `workflow_dispatch` after the merge.
- **Why:** brief Task 10.4; one issue per drift rather than one per week.
- **Alternatives:** a comment on each run (noisy); a third-party issue action (another pinned dependency).
- **Reversible:** yes.

### D167 — 2026-10-30 17:30, CP10 — The stale-lists warning

- **Decided (worker CP10):** `scripts/check-search-lists-age.py` reads `generated` from `Enigma/Resources/SearchData/manifest.json` (or `--manifest`), compares with `--today` or the local date, and prints the brief's warning when the age is over 60 days. An unreadable manifest or date prints a warning naming the problem; it always exits 0. `release.sh` runs it in preflight after the release-notes checks, with its output on stderr and `|| true`, so a missing `python3` can't stop a release either.
- **Why:** brief Task 10.5; "only warns, never blocks".
- **Alternatives:** make it a `require` (blocks real releases).
- **Reversible:** yes.

### D168 — 2026-10-30 17:30, CP10 — Notices: nothing to add for Wikidata or Google News

- **Decided (worker CP10):** `ThirdPartyNotices.txt` already credits every item Task 10.6 lists (ddgs, Readability.js, the Public Suffix List, Phishing.Database, the Block List Project, the three spam lists, Wikipedia's Perennial sources, Open-Meteo with GeoNames). No entry is added for Wikidata or Google News: nothing from either ships in the app; Wikidata's data is CC0 (no attribution required), and Google News headlines are shown at runtime with their publisher and a link, under the feed's own terms, which `Web-Search.md`'s limitations name (D125). The notices file credits bundled code and data, and Open-Meteo only because its licence requires attribution of displayed data.
- **Why:** the file's existing scope; no licence requires an entry.
- **Alternatives:** a courtesy line for Wikidata (harmless; add under "Search quality lists" if the owner wants one).
- **Reversible:** yes.

### D169 — 2026-10-30 17:30, CP10 — Local-Model-Selection gets no new tool-choice scores

- **Decided (worker CP10):** the brief asks for CP7's tool-choice scores, but Task 7.5 (the live tool-use eval with the 12 places and weather prompts) wasn't run (D118, D121). `Local-Model-Selection.md` says the two new tools are offered with `web_search` and that their prompts are in the eval set but not yet measured, instead of quoting numbers that don't exist.
- **Why:** no invented numbers.
- **Alternatives:** leave the doc unchanged.
- **Reversible:** yes; fill in the scores when Task 7.5 runs.

### D170 — 2026-10-30 17:30, CP10 — to-do.md and the map card screenshot are left for the owner

- **Decided (worker CP10):** `to-do.md`'s F29 entry is unchanged: the brief marks F29 done only after the merge (final audit step 4), and AGENTS.md asks for nothing before it. The map card has no screenshot yet (CP9 Task 9.4 is the owner's, from the signed app), so `Web-Search.md` and `Chat.md` describe the card without an image; the Hand-off says where to add it.
- **Why:** the brief's order; never link an image that doesn't exist.
- **Alternatives:** none.
- **Reversible:** yes.

### D171 — 2026-10-31 00:40, CP10 — Docs say gate 3's one answer covers search, places and weather; Apple's reverse geocoding is listed

- **Decided (orchestrator, from review round 1):** (1) The docs describe gate 3 as it works since CP6: one grant covers `web_search`, `find_places` and `get_weather` together, so "For this conversation" or "Always" on any of their cards lets the other two through as well. (2) The privacy table, and spec §7 as an amendment, add that Apple receives your coordinates, rounded to about 1 km, to find your city for any nearby question (`LocationService` reverse geocoding), not only for places questions. (3) The ddgs watch's test checks that each file is read at the latest tag. (4) D165 is corrected: the `changed/` fixtures are synthetic.
- **Why:** the reviewer found the docs claimed each tool asks separately and the Apple row understated what is sent. A test reading the wrong tag would pass while the live watch never reported a change.
- **Alternatives:** separate grants per tool (a code change to `ToolPermissions`, for the owner to decide).
- **Reversible:** yes.

### D172 — 2026-10-31 00:40, CP10 — One review round

- **Decided (orchestrator):** no round 2; the findings are doc wording and small tests, which I check by rerunning the Python tests and the two `ref` mutants.
- **Why:** owner's review rule.
- **Alternatives:** a round 2 reviewer.
- **Reversible:** yes.

### D173 — 2026-10-31 00:55, CP10 — Review round 1's fixes

- **Decided (worker CP10):** (1) `FixtureAPI` raises unless a contents request carries the latest release's tag as its ref; the mutants "no ref" and "ref = recorded tag" each fail the watch tests now (3 failures and 1 error; 1 failure and 1 error) and were restored. (2) New offline tests: `LiveAPI` with `urlopen` patched (404 is None, other errors raise, no `Authorization` header without `GITHUB_TOKEN`, a bearer header with it, the exact API URL), an empty `files` map and non-GitHub repositories rejected. (3) Docs per D171: gate 3's one answer covers web searches, places lookups and weather checks in the chat, and Always covers them in every chat (`Web-Search.md`, `Messages.md`), with all four places and weather card titles; Apple's row lists the rounded coordinates reverse-geocoded for any nearby question, in `Web-Search.md` and in spec §7, marked "amended, orchestrator, owner to confirm". (4) Nits: Wikipedia isn't asked for today or this-week questions and keeps the first usable article among its top 3 hits; result sites read more when a read fails or the check reads again, following up to 5 redirects; "search adds only the blocked sites to preferences"; the Maintenance section notes that an issue edit sends no notification and that GitHub turns off scheduled workflows after 60 days without repository activity; D165's fixture description corrected.
- **Why:** review round 1 (no Blocker).
- **Alternatives:** per-ref fixture folders, or a recording fake that asserts each ref.
- **Reversible:** yes.
