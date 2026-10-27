# CP7: Evaluation and the quality gate

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing" → "Quality
gate", §3.7), and the Hand-offs of CP2 to
[CP6](cp6-places-and-weather.md#hand-off).

## Goal

Measure on-device search against Brave on 60 fixed questions, tune it until
the spec's gate passes, and write up the result. **Brave is removed (CP8) only
after this gate passes.** If it can't pass after three tuning rounds, stop and
ask the owner to decide.

## Starting point

- `OnDeviceSearchProvider` handles every route. Brave still exists and is the
  default.
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

**Files:** create `scripts/web-search-queries.json`.

**Interfaces.** This task produces an array of
`{"id": "news-01", "category": "news", "question": "…"}`. The categories and
counts are exactly the spec's:

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

- [ ] **Draft the 60 questions.** A Python test, `test_query_set_shape`, in
  `scripts/tests/test_evaluate_web_search.py`, checks the counts, unique IDs
  and categories.
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

**What the evaluation test does,** for each question, building the request
the way `LocalChatViewModel` does:

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
  - `id`, `category`, `provider` (`"brave"` or `"onDevice"`);
  - `latencyMs` and `error`;
  - `sources`: url, domain, kind, title, site, published;
  - `trace`.
- **Answers.** When a local model is installed, ground each provider's
  results with `WebSearchContext.prepare` and the installed model, generate
  an answer, and append `{id, provider, answer}` to `<folder>/answers.jsonl`.
  Without a model, record that and skip the answers.

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
  the hashing and list loading from `scripts/update-search-lists.py`.
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
  questions, and no category is clearly worse. "Clearly worse" means Brave
  wins more than half that category's questions.

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
  - the judge results per category;
  - the spot-check agreement;
  - the tuning log;
  - the 20 most frequent domains per provider.

  No answers and no page text. Raw output stays outside the repository.

## Exit criteria

- [ ] Every gate threshold passes, and the report is written.
- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass, and the
  Python tests pass.
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

*Filled in by the CP7 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
