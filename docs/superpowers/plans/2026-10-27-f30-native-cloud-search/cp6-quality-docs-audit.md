# CP6: Quality check, docs and final audit

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing" → "Quality
check", §6, "Docs"), and the Hand-offs of CP0 to
[CP5](cp5-claude-code.md#hand-off).

## Goal

1. **Compare.** For each provider that's on, compare provider search with
   on-device search on the same model.
2. **Ship only what passes.** Keep provider search on only for the routes
   that pass the spec's gate.
3. **Update the copy and docs.** Update the Settings text and the docs.
4. **Audit and merge.** Run the final audit in the running app, then merge.

## Starting point

- **Turned on:** the providers in `CloudProviderID.nativeWebSearchProviders`
  after CP5. Each brief's Hand-off says which are on, and why any isn't.
- **F29's evaluation tools:**
  - `scripts/web-search-queries.json`, with IDs and categories;
  - `scripts/evaluate-web-search.py`, with its blind judge, ad and list
    checks, and tests in `scripts/tests/`;
  - `WebSearchEvaluationTests`, which shows how to run
    `OnDeviceSearchProvider` and write `runs.jsonl`.
- **CP2's live-test helpers:** `EnvironmentCredentials` and `liveEvents`.
- **F29's Settings → Web search** section shows the note and the
  blocked-sites list. CP0's Q0 names the file and any snapshot test.

## Tasks

### Task 6.1: The comparison run

**Files:** create `EnigmaTests/NativeWebSearchEvaluationTests.swift`,
registered in the test target.

**The test** skips unless both `ENIGMA_SEARCH_EVAL` (a folder) and
`ENIGMA_NATIVE_SEARCH_LIVE == "1"` are set.

**The questions:** 20, the first of each category in file order from
`scripts/web-search-queries.json`, read through `#filePath`:

| Category | Count |
| --- | --- |
| `news` | 4 |
| `facts` | 4 |
| `docs` | 4 |
| `health-finance` | 3 |
| `reviews` | 2 |
| `encyclopedic` | 3 |

**The routes:** each provider in the set whose account is available:

- **OpenAI and Anthropic** with an `ENIGMA_*_KEY`, through
  `EnvironmentCredentials`;
- **ChatGPT and Claude Code** when `account()` reports a sign-in.

Models come from `ENIGMA_*_MODEL`, or the live tests' defaults.

**For each route and question,** two runs, 2 s apart:

1. **`native`:** the provider client, with `webSearch: CloudWebSearch()`.
2. **`onDevice`:** `OnDeviceSearchProvider.live()` with a web
   `WebSearchRequest` and `WebSearchLimits.evidenceTokens`, then
   `WebSearchContext.prepare`, then the same client with no `webSearch`.

**The output:**

- **`<folder>/runs.jsonl`:**
  - `id`, `category`, `route` (the provider's raw value), `model` and
    `provider` (`"native"` or `"onDevice"`);
  - `searched`: a `.phase(.searching)` was seen, or the on-device search
    returned results;
  - `firstTokenMs`, `latencyMs` and `error`;
  - `sources`: url, domain and title.
- **`<folder>/answers.jsonl`:** `{id, route, provider, answer}`.

Never log or write a key.

**Steps:**

- [ ] **Write the test, and run it without the variables.** Expect a skip.

### Task 6.2: The comparison in the script

**Files:** modify `scripts/evaluate-web-search.py`. Tests go in
`scripts/tests/test_evaluate_web_search.py`, with fixtures in
`scripts/tests/fixtures/native-search-eval/`.

**Interfaces.** This task produces:

```text
python3 -I scripts/evaluate-web-search.py <folder> --compare native,onDevice [--judge-command "claude -p"]
```

It writes `<folder>/compare-report.md`. F29's existing modes and their
tests keep working unchanged.

**Per route, the report gives:**

- **For the first label (`native`):**
  - the share of questions that searched;
  - the share with at least 2 sources;
  - unsafe sources (`isSafeWebLink`'s rules), and matches against F29's
    unsafe and spam lists;
  - the median and 90th-percentile time to first token and total time.
- **For the second label:** the same latency figures.
- **The judge:** F29's blind A/B judge on the paired answers. It reports
  the share of questions where the first label wins or ties, and the
  results per category.

**The gate,** from the spec, passes when:

- it searched on 18 or more of 20;
- at least 2 sources on 18 or more;
- no unsafe source and no list match;
- wins plus ties are 80% or more.

**Steps:**

- [ ] **Write the failing tests:**
  - `test_compare_mode_groups_by_route`;
  - `test_compare_gate_verdict`: fixtures at 18/20 and 17/20 searched, at
    18/20 and 17/20 with two sources, at 80% and 75% judged, and one with a
    `javascript:` source;
  - `test_compare_requires_both_labels`: a clear error when one label has
    no runs;
  - `test_compare_without_judge_marks_answers_not_run`.
- [ ] **Run** `python3 -I -B -m unittest discover -s scripts/tests`. Expect
  failures.
- [ ] **Implement,** then run. Expect every Python test to pass, F29's
  included.

### Task 6.3: Run, decide, report

- [ ] **Get approval.** Get the owner's approval in the chat, with the
  estimate:
  - up to 100 searches per API route (at most about $1 each, plus tokens);
  - 20 turns per subscription route;
  - the judge's Claude Code usage.
- [ ] **The owner runs the comparison** with the keys:

  ```sh
  read -rs OPENAI_KEY && read -rs ANTHROPIC_KEY && TEST_RUNNER_ENIGMA_SEARCH_EVAL=<folder outside the repo> TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 TEST_RUNNER_ENIGMA_OPENAI_KEY="$OPENAI_KEY" TEST_RUNNER_ENIGMA_ANTHROPIC_KEY="$ANTHROPIC_KEY" scripts/verify-xcode.sh test -only-testing:EnigmaTests/NativeWebSearchEvaluationTests; unset OPENAI_KEY ANTHROPIC_KEY
  ```

  Then `python3 -I scripts/evaluate-web-search.py <folder> --compare native,onDevice --judge-command "claude -p"`.
- [ ] **Decide per route.**
  - **Passes:** it stays on.
  - **Fails:** report the numbers to the owner. Two
    tuning rounds are allowed, each an owner-approved change to the
    instruction or to `maximumSearches`, with the spec updated to match.
  - **Still fails, or the owner declines:** take the provider out of
    `nativeWebSearchProviders`, update `testNativeWebSearchProviders`, and
    record it.
- [ ] **Write the report** to `docs/history/<date>-native-search-evaluation.md`:
  - the routes and models;
  - the metrics table, with pass or fail per threshold;
  - the judge results per category;
  - the latency against on-device search;
  - any tuning, and the final provider set.

  Domains and numbers only: no answers, no page text. Raw output stays
  outside the repository.

### Task 6.4: Settings text

**Files:** the file CP0's Q0 named for F29's Web search note and
blocked-sites list, plus its snapshot test if one exists.

**Steps:**

- [ ] **Write the failing tests,** or update F29's snapshot of the section:
  - the note ends with spec §6's sentence, "With OpenAI, Anthropic, ChatGPT
    and Claude Code, …";
  - the blocked-sites list shows "Cloud models that use their provider's
    search are asked to avoid these sites, but only Anthropic enforces it."
- [ ] **Implement,** using F29's existing note and caption controls.
- [ ] **Regenerate the screenshot** F29's CP9 regenerated, if the text
  appears in it.

  If the final provider set lacks some providers, the sentence names only
  the ones that shipped, and the reason is noted in the Hand-off.

### Task 6.5: Docs, `to-do.md` and release notes

- [ ] **`docs/Web-Search.md`:** a new section, "Cloud models' own search".
  It covers which routes use it and when, sources and fallback, the privacy
  table from spec §5, and costs. Check the costs on the OpenAI and Anthropic
  pricing pages on the day, and give the date. It also covers the
  limitations: blocked sites, screen and selection turns, Gemini. Update
  "How it works" with the new files, and "Tests".
- [ ] **`docs/ChatGPT-Setup.md`:** web search is on for search requests
  only, in `live` mode, and its "How it works" table is updated.
- [ ] **`docs/Claude-Code-Setup.md`:** `WebSearch` is the only tool, for
  search requests only.
- [ ] **`docs/Cloud-Model-Selection.md`:** which providers search natively,
  and Gemini's on-device search.
- [ ] **`docs/Chat.md`:** the provider-search branch of "Request
  lifecycle": acceptance at the first event, and the fallback.
- [ ] **`docs/Testing.md`:** the live checks and the comparison, with their
  variables.
- [ ] **Release notes:** if `docs/release-notes/` has a file for an
  unreleased version, add one line: "Cloud models now search the web with
  their provider's own search, with on-device search as the fallback."
  Otherwise put that line in the Hand-off for the owner.
- [ ] **`to-do.md`:** F30 keeps its Spec and Plan lines until the merge. Tick it
  off after the merge.

### Task 6.6: Final audit and merge (worker, with the owner)

- [ ] **Install the signed app** with `scripts/install-app.sh`. Then, in the
  running app, with the owner:
  - one search question on each shipped route: check the activity steps,
    the sources list, and the "web search" footer;
  - on OpenAI, if shipped, `/search cafe near me` uses Apple Maps, not
    provider search;
  - a Gemini search uses on-device search;
  - Stop during a provider search keeps the draft.
- [ ] **Merge.** Run the final `build`, `test` and `analyze`, then merge
  `feat/f30-native-cloud-search` to `main`, through a pull request if
  branch rules require one.
- [ ] **After the merge:**
  - confirm CI passes;
  - tick F30 off in `to-do.md`, per its note for agents;
  - update the progress log.

## Exit criteria

- [ ] The report is in `docs/history/`, and every shipped route passed the
  gate.
- [ ] The docs match the behavior, and the Settings text names only the
  shipped providers.
- [ ] Python tests, `build`, `test` and `analyze` pass. CI passes on `main`
  after the merge.

## Reviewer checklist

- **Fair comparison:**
  - same model, questions and order on both sides;
  - the judge never sees which side is which;
  - the gate uses the spec's numbers;
  - no key in any file or log.
- **The report** holds only domains and numbers, and its provider set
  matches `nativeWebSearchProviders`.
- **Docs:**
  - the privacy table matches spec §5;
  - costs carry a date;
  - nothing claims search runs on Gemini, places, weather, screen or
    selection turns.

## Hand-off

*Filled in by the CP6 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
