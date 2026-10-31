# CP7: Evaluation and the quality gate

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing" → "Quality
gate", §3.7, §6.2), F30's [CP6 Hand-off](../2026-10-27-f30-native-cloud-search/cp6-quality-docs-audit.md#hand-off),
and the Hand-offs of CP2 to [CP6](cp6-places-and-weather.md#hand-off).

## Goal

Measure on-device search against Brave on 60 fixed questions, in both query
styles (the typed question, as small models send it, and a short query, as
capable models write it), check that capable models still choose the right
tool with places and weather added, tune until the spec's gate passes, and
write up the result. **Brave is removed (CP8) only
after this gate passes.** If it can't pass after three tuning rounds, stop and
ask the owner to decide.

## Starting point

- `OnDeviceSearchProvider` handles every route, and `web_search`,
  `find_places` and `get_weather` on capable turns. Brave still exists and
  is the default.
- **From F30:** `scripts/web-search-queries.json` with 20 web questions
  (`web-01`…`web-20`), the blind judge in `scripts/search_judge.py`, and
  `scripts/evaluate-native-search.py`. F32's `NativeToolsEvalTests` and
  `EnigmaTests/Fixtures/F32/eval.jsonl` (60 prompts).
- The tuning knobs are constants from CP2 to CP5, each pinned by a test:
  - site weights (`SearchEngine.weight`);
  - trust factors (`SourceQuality`);
  - the cut-off (`ResultRanking.select`);
  - `OnDeviceSearchTiming`;
  - `PageChecks` thresholds and wall phrases;
  - `PassageRanker` constants;
  - which recency hints reach the sites (CP1 and CP2);
  - `enigma-blocked.txt`, `authority.txt` and `unreadable.txt`.

## Tasks

### Task 7.1: The question set

**Files:** extend `scripts/web-search-queries.json` (F30's 20 stay, with
their IDs).

**Interfaces.** This task produces an array of
`{"id": "news-01", "category": "news", "question": "…", "query": "…"}`.
`query` is the short search a capable model would write (a few words, as
F32 measured). Places and weather entries carry `"tool": {"name":
"find_places" | "get_weather", "arguments": {…}}` instead of `query`. The
categories and counts, F30's 20 included, are exactly the spec's:

| Category | Count |
| --- | --- |
| `news` | 10 |
| `facts` | 10 |
| `docs` | 10 |
| `health-finance` | 8 |
| `reviews` | 6 |
| `places` | 6 |
| `weather` | 4 |
| `encyclopedic` | 6 |

**The questions:**

- are nothing personal, and the way people really ask;
- mix wordings, including `/search`-style, "near me" and named places;
- include 4 questions not in English, spread over the categories;
- have answers on the public web.

**Steps:**

- [ ] **Draft the 40 new questions,** and write every entry's `query` or
  `tool` by hand, once, before any run. A Python test,
  `test_query_set_shape`, in `scripts/tests/test_evaluate_web_search.py`,
  checks the counts, unique IDs, categories, and that every entry has
  exactly one of `query` and `tool`.
- [ ] **Run** `python3 -I -B -m unittest discover -s scripts/tests`. Expect
  it to pass.
- [ ] **Get approval.** Mark the list "for owner review" in your Hand-off. Get the
  owner's approval in the chat before Task 7.4 runs.

### Task 7.2: The ranking trace and the evaluation test

**Files:**

- Modify `Enigma/Search/OnDeviceSearch.swift`, adding an optional trace.
- Create `EnigmaTests/WebSearchEvaluationTests.swift`. It skips unless
  `ENIGMA_SEARCH_EVAL` names a folder.

**Interfaces.** This task produces the trace:

```swift
struct SearchTraceEvent: Codable, Equatable, Sendable {
  let url: String; let domain: String
  let positions: [String: Int]        // by engine
  let score: Double; let trustFactor: Double
  let verdict: String                 // "read", "snippet", "blocked", "cutoff", "notArticle", "wall", "offTopic", "duplicate", "wrongLanguage", "unread"
}
protocol SearchTracing: Sendable { func record(_ event: SearchTraceEvent) }
```

`OnDeviceSearchProvider.init` gains `trace: (any SearchTracing)? = nil`.
`live()` passes `nil`, so production records nothing.

**What the evaluation test does,** for each question and each style
(`typed`, then `model`), building the request the way `LocalChatViewModel`
does:

- **`typed` style:** the question, routed by `SearchRouting.decide`, as
  below.
- **`model` style:** the entry's `query` on the web route, with
  `WebSearchPolicy.recency(query)`; or its `tool`, run through
  `PlaceSearchTool` or `WeatherTool` for on-device, and as a Brave search of
  "<query> near Chicago" or "weather <place>" for Brave.

- **The request.** Route and named place come from `SearchRouting.decide`,
  and the recency from `WebSearchPolicy.recency`. Wherever location is
  needed, use the fixed city "Chicago" at 41.88, -87.63; never the Mac's
  location. `maximumTokens` is 8,192.
- **Brave.** Run `BraveSearchClient` with its key read from the environment
  variable `ENIGMA_BRAVE_KEY`. The owner passes it as
  `TEST_RUNNER_ENIGMA_BRAVE_KEY` when running. Never write or log the key.
- **On-device.** Run `OnDeviceSearchProvider`, built like `live()` but with
  an empty user block list and a trace recorder.
- **Results.** Append to `<folder>/runs.jsonl`:
  - `id`, `category`, `style`, `provider` (`"brave"` or `"onDevice"`);
  - `latencyMs` and `error`;
  - `sources`: url, domain, kind, title, site, published;
  - `trace`.
- **Answers.** When a local model is installed, ground each provider's
  results with `WebSearchContext.prepare` and the installed model, generate
  an answer, and append `{id, style, provider, answer}` to
  `<folder>/answers.jsonl`. With both a small and a flagged model
  installed, the `typed` style uses the small one and the `model` style the
  flagged one. Without a model, record that and skip the answers.

**Steps:**

- [ ] **Write a failing trace test,** `testTraceRecordsVerdicts`, in
  `OnDeviceSearchTests`. With fakes, a blocked candidate, a wall page and a
  read page record `blocked`, `wall` and `read`.
- [ ] **Run** `OnDeviceSearchTests`. Expect a failure.
- [ ] **Implement** the trace and `WebSearchEvaluationTests`.
- [ ] **Run** `OnDeviceSearchTests`. Expect it to pass. Without the variable,
  `WebSearchEvaluationTests` skips.

### Task 7.3: The evaluation script

**Files:**

- Create `scripts/evaluate-web-search.py`, standard library only. It imports
  the hashing and list loading from `scripts/update-search-lists.py`, and the
  blind judge from F30's `scripts/search_judge.py`.
- Tests: `scripts/tests/test_evaluate_web_search.py`, with fixtures in
  `scripts/tests/fixtures/web-search-eval/`.

**Interfaces.** This task produces the command
`python3 -I scripts/evaluate-web-search.py <folder> [--judge-command "claude -p"] [--lists Enigma/Resources/SearchData]`,
which writes `<folder>/report.md` and `<folder>/spot-check.md`.

**The gate,** exactly as the spec states it. It passes when:

- **Clean sources:** on-device uses no source that is an ad link
  (`duckduckgo.com/y.js`, `bing.com/aclick`, `googleadservices`,
  `doubleclick`) or that matches `unsafe.bin` or `spam.bin`;
- **Two sources:** at least 2 sources on 95% or more of web-route questions;
- **Pages read:** at least one `article` or `wikipedia` source on 90% or
  more of web-route questions;
- **Speed:** on-device's median latency is 3.0 s or less and its 90th
  percentile 4.5 s or less, across all its runs;
- **Variety:** 3 or more distinct registrable domains on 80% or more of
  web-route questions;
- **Authority:** an `authority.txt` match on 80% or more of the
  `health-finance` and `docs` questions;
- **Answers.** The judge prefers on-device or calls a tie on 80% or more of
  questions, in each style, and no category is clearly worse in either.
  "Clearly worse" means Brave wins more than half that category's
  questions.
- **Tool choice:** Task 7.5's eval passes.

**The judge.** For each question, the judge command receives the question,
two answers labelled A and B, each answer's source domains, and the rubric:
correct, current, sourced, no unsupported claims.

- The order is shuffled, seeded by a hash of the question's ID.
- The judge must reply with JSON: `{"winner":"A"|"B"|"tie","reason":"…"}`.

**The spot check.** `spot-check.md` holds 15 pairs, chosen with a fixed seed,
for the owner to judge blind.

**Steps:**

- [ ] **Write the failing tests:**
  - `test_metrics_from_fixture_runs`;
  - `test_blind_order_is_deterministic_and_balanced`;
  - `test_gate_verdict`: one fixture just inside each threshold and one just
    outside;
  - `test_ad_and_blocklist_detection`;
  - `test_on_device_only_reports_metrics_without_judge`: runs with no Brave
    entries, which is the situation after CP8, report every source and speed
    metric, mark the answer gate "not run", and print the CP7 report path for
    comparison;
  - `test_query_set_shape`, from Task 7.1.
- [ ] **Run** `python3 -I -B -m unittest discover -s scripts/tests`. Expect
  failures.
- [ ] **Implement** the script.
- [ ] **Run** the Python tests. Expect them to pass.

### Task 7.4: Run, tune, report

- [ ] **Run the evaluation**, once the owner has approved the question set:

  ```sh
  TEST_RUNNER_ENIGMA_SEARCH_EVAL=<folder outside the repo> \
  TEST_RUNNER_ENIGMA_BRAVE_KEY=<owner's key> \
  scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchEvaluationTests
  ```

  Then run `python3 -I scripts/evaluate-web-search.py <folder>`.
- [ ] **Tune, at most three rounds.** Change one knob family at a time:
  - Rerun the evaluation after each change.
  - Update the constant's test to the tuned value.
  - Log the before and after metrics.

  Known lever: if the recency filters at the sites hurt "latest" and "recent"
  questions (for example "latest swift version"), drop the site-side filter
  for those words but keep the ranking penalty. That's a spec deviation and
  needs the owner's approval. Changes to `authority.txt` and
  `unreadable.txt` also need the owner's approval.
- [ ] **The embedding experiment,** from spec §5.
  - Behind a test-only switch in `PassageRanker`, rerank each page's
    passages by `0.5 ×` normalized BM25 `+ 0.5 ×` cosine similarity from
    `NLEmbedding.sentenceEmbedding(for:)` in the question's language. Leave
    BM25 alone when no embedding exists for that language.
  - Run the evaluation with the switch on and off.
  - Report the judge results and the added passage-ranking time at the 90th
    percentile.
  - Recommend adopting it only if it clearly wins and adds under 100 ms.
    Adopting it is the owner's decision. Until they decide, the switch stays
    off and isn't reachable in the app.
- [ ] **Owner spot check.** Give `spot-check.md` to the
  owner, and records how often the owner agrees with the judge.
- [ ] **Write the report** to
  `docs/history/<date>-web-search-evaluation.md`. Include:
  - the question categories;
  - the metrics table, with pass or fail per threshold;
  - the judge results per category and style;
  - the tool-choice scores per model;
  - the spot-check agreement;
  - the tuning log;
  - the 20 most frequent domains per provider.

  No answers and no page text. Raw output stays outside the repository.

### Task 7.5: Tool choice on capable models

**Files:** extend `EnigmaTests/Fixtures/F32/eval.jsonl` and
`NativeToolsEvalTests`.

- [ ] **Add about 12 invented prompts:** 4 should find places ("any good
  ramen near me?", "bookshops in Soho"), 4 should check the weather ("do I
  need an umbrella tomorrow?", "weather in Lisbon this weekend"), and 4 near
  misses that should call neither ("what is the temperature to bake
  salmon", "progress bars in swiftui", "who founded Apple Maps", "history of
  the Weather Channel"). Each names its expected tool, or none.
- [ ] **Score** them strictly, as F32's eval does: the first call must be the
  expected tool (or no places or weather call for a near miss). Add an
  offline scoring test from a fixture transcript.
- [ ] **Get the owner's approval,** then run `testEval` with the on-device
  backend on each flagged model the owner has installed, and on one cloud
  route F30 doesn't serve (Gemini) if the owner has it. The gate: 0.90 or
  more overall, and 10 of 12 or more on the new prompts. Record the scores
  in the report.

## Exit criteria

- [ ] Every gate threshold passes, in both styles, and the report is
  written.
- [ ] `scripts/verify-xcode.sh build` and `analyze` pass, the touched test
  classes and the Python tests pass, and the full `test` runs once before
  the commit.
- [ ] The owner has approved the question set, every spec deviation, and the
  list edits, in the chat.

## Reviewer checklist

- **The key and the location:** no key in any file, log or output. The fixed
  Chicago location is used, never the Mac's.
- **Fair judging:** the blind order really hides the provider, and the
  judge's prompt doesn't name either one.
- **Honest tuning:** each tuned value has a test that pins it, the tuning
  log matches the diff, and no test was loosened rather than retargeted.
- **The report** contains only domains and numbers.

## Hand-off

*Filled in by the CP7 worker, 2026-10-30. Decisions D92–D124 in
[overnight-decisions.md](overnight-decisions.md).*

1. **Summary:** the evaluation harness, the 60-question set and the gate
   report are built (D94–D103). After the DuckDuckGo-only early read (typed:
   on-device 13, Brave 27 of 40 judged pairs; news and facts 0 of 12) the
   owner added four features (D104): a local-model query rewrite and an
   "enough?" check with one retry on the small-model path (models without
   native tools only, D120), Wikidata facts and Google News headlines as
   keyless sources. Round 1 ran with them; the owner stopped it after the
   typed half (D121). Both gates fail on the judge share; speed passes the
   relaxed bar (D116). Brave stays the default; on-device stays behind its
   Debug switch.

   Gate as measured (round 1; typed fully judged, model style 3 of 60):

   | Check | Value | Original bar | Relaxed bar |
   | --- | --- | --- | --- |
   | Ad, blocklisted or spam sources | 0 | passed | passed |
   | 2+ sources, web questions (typed / model) | 1.00 / 0.98 | passed | passed |
   | 1+ page read, web questions (typed / model) | 1.00 / 1.00 | passed | passed |
   | 3+ domains, web questions (typed / model) | 1.00 / 0.98 | passed | not a relaxed check |
   | Authority source, health and docs (typed / model) | 0.39 / 0.61 | failed | not a relaxed check |
   | Median search time, all 120 runs | 2.27 s | passed (3.0 s) | passed (5.0 s) |
   | 90th percentile search time, all 120 runs | 6.51 s | failed (4.5 s) | passed (7.0 s) |
   | On-device equal or better, typed | 0.467 | failed (0.8) | failed (0.65) |
   | On-device equal or better, model style | — | not run | not run |
   | Largest Brave-win share in one category | — | not run | not run |
   | Recency equal or better, news and facts, typed | 0.65 | — | failed (0.7) |
   | Recency, model style | — | not run | not run |
   | Tool-use eval, lowest flagged model | — | not run | not run |
   | New places and weather prompts (of 12) | — | not run | not run |

   **Typed verdict:** on-device 26, Brave 32, tie 2 of 60 (equal or better
   0.467), against baseline-3's early read of 13 to 27 of 40 judged pairs
   (0.325). By category (on-device–Brave–tie): news 3–7–0, facts 3–5–2,
   docs 4–6–0, health-finance 5–3–0, reviews 1–5–0, places 5–1–0, weather
   2–2–0, encyclopedic 3–3–0. News and facts went from 0 of 12 to 6 of 20
   wins plus 2 ties; reviews stay weakest (Brave's Reddit and Yelp results).
   Round 1's typed run used a capable helper model (Gemma 4 12B through a
   test llama-server) for the rewrite and check, so it describes small
   models with a strong helper, not the installed native-tools models'
   path (D120).
2. **Files:** harness `EnigmaTests/WebSearchEvaluationTests.swift`,
   `scripts/evaluate-web-search.py` and its tests, the question set
   `scripts/web-search-queries.json`, the tool prompts
   `EnigmaTests/Fixtures/F32/eval.jsonl`; features
   `Enigma/Search/SearchAssist.swift`,
   `Enigma/Search/Engines/WikidataFacts.swift`,
   `Enigma/Search/Engines/GoogleNewsSearch.swift`, changes in
   `OnDeviceSearch.swift`, `WebSearch.swift` and
   `LocalChatViewModel.swift`; tests `SearchAssistTests`,
   `SearchFactsAndNewsTests` with fixtures in `EnigmaTests/Fixtures/Search/`;
   spec §2, §6.1 and §7 amended (owner approved 2026-10-30).
3. **Decisions:** D92–D126. The owner's: D104 (features), D106, D116
   (speed bar 5.0 s / 7.0 s; the second query stays while it helps), D119,
   D120 (option A), D121 (stop after the typed half); the orchestrator's
   D122 (no location or query to Google), D125 (round 2's fixes; Google
   News kept under its feed terms); the workers' D107–D115, D117, D124,
   D126.
4. **Verification:** affected classes only (no full suite, D119):
   `SearchAssistTests`, `SearchFactsAndNewsTests`, `OnDeviceSearchTests`,
   `NativeToolsEvalTests`, `WebSearchTests`, `NativeWebSearchTests`,
   `WebSearchEvaluationTests`, `LocalInferenceTests`,
   `ScreenPipelineTests`, `RequestLifecycleTests`,
   `NativeToolRequestTests`, `PlacesAndWeatherTests`; `build` and
   `analyze`; the Python harness tests. Review round 1's findings are fixed
   (D124); round 2 found no Blocker, and its fixes (blocked sites in the
   new lanes, names kept by the clean-up, cancellation tests; D125, built
   as D126) are checked by re-running the affected tests and mutants, with
   no round 3. The owner keeps Google News RSS despite its feed terms
   (D125).
5. **Limitations:**
   - Not run (D121): the model-style half (3 of 60 judged), the one- versus
     two-query A/B (D116), and the tool-use eval with the 12 new places and
     weather prompts (Task 7.5, D118). The full suite waits for the Mac.
   - Speed: typed searches with the rewrite and check took a median 5.45 s
     and p90 7.57 s in round 1 (rewrite median 1.39 s, check 1.24 s);
     model-style searches 1.19 s and 2.14 s. The smoke run features-3 (20
     news and facts questions) measured 4.81 s and 6.65 s; a second
     DuckDuckGo query costs about 1 s of pacing (D115).
   - Possible app issue (D114): llama-server drops idle keep-alive
     connections after about 5 s, which made the harness's first call after
     each pause a second or more slower; the app's own llama-server session
     for vision models may meet the same on its ordinary requests. Not
     checked in the app.
   - Round 1 ran before D124: its Google News citations linked to a Google
     search page holding the query (now the publisher's home page), and the
     news lane wasn't yet skipped for requests with a city or a blocked
     publisher (D124, D125).
   - DuckDuckGo's coverage varied between runs with the same code (D102);
     the site-outcome trace now tells the cases apart.
   - Spot check: `spot-check.md` exists in the round-1 folder; the owner's
     picks (`spot-check-picks.json`) don't, so it isn't compared yet.
6. **For the next checkpoint:**
   - Open questions for the owner: does a 0.467 typed share (relaxed bar
     0.65) still allow CP8, or does Brave stay (D4)? Run the model-style
     half, the A/B and the tool-use eval when the Mac is free? Is the
     typed speed (median 5.45 s, inside the relaxed 5.0 s bar only for all
     runs together) acceptable for small models? Should the installed
     native-tools models also get the "enough?" check (option B, D120)?
     The spot-check picks.
   - Run folders, outside the repository, under
     `/private/tmp/claude-501/f29-cp7/runs/`: `baseline-1` to `baseline-3`,
     `recheck-1`, `features-1` to `features-3` (smoke runs), and `round-1`
     (`report.md`, `summary.json`, `spot-check.md`, judgments and contexts).
