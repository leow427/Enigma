# CP6: Quality check, docs and audit

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing", "Docs"),
and every earlier Hand-off.

## Goal

Measure each turned-on route against the spec's gate, keep only the routes
that pass, write the report and the docs, audit the feature in the running
app with the owner, and merge.

## Starting point

- `CloudProviderID.nativeWebSearchProviders` holds every provider whose live
  check passed (CP2–CP5 Hand-offs).
- **F32's eval:** `NativeToolsEvalTests.testEval` runs the 60 prompts in
  `EnigmaTests/Fixtures/F32/eval.jsonl` on a real route, with a stub search,
  invented Messages chats and every card answered For this conversation,
  and writes `report.json`. API routes read keys from the environment
  (`EnvironmentCredentials`).
- **CP0's Q6** lists 5 latency questions to reuse.
- **`docs/history/`** holds F32's reports for format.

## Tasks

### Task 6.1: The question set

**Files:** create `scripts/web-search-queries.json`.

- [ ] **Write 20 fixed, non-personal web questions,** ids `web-01`…`web-20`:
  4 `news`, 4 `facts` (changing facts), 4 `docs` (how-to and software
  docs), 3 `health-finance`, 2 `reviews`, 3 `encyclopedic`, CP0's 5 among
  them. These are F29's category names. Each entry is `{"id", "category",
  "question"}`. F29 extends this file to 60 and adds a `query` field; keep
  the format open for that (extra keys are ignored).

### Task 6.2: The eval with provider search

- [ ] **Make `NativeToolsEvalTests.testEval` run with provider search** on
  routes in the set: its stub search stands in only for Enigma's
  `web_search`; on a provider-search route the provider searches for real,
  and the scoring counts a provider search as the search decision. Add
  `testEvalScoresProviderSearchAsSearch` (offline, from a fixture
  transcript).
- [ ] **Get the owner's approval** (about 15 searches per route, plus
  tokens), hand them the commands, and record each route's score and its
  per-category counts.

### Task 6.3: The comparison

**Files:** create `EnigmaTests/NativeWebSearchEvaluationTests.swift`,
`scripts/search_judge.py` (the blind judge and its A/B order, as an
importable module F29 reuses) and `scripts/evaluate-native-search.py`
(standard library only, tests in `scripts/tests/test_evaluate_native_search.py`).

- [ ] **The test** (opt-in, `ENIGMA_SEARCH_EVAL=<folder>` plus the live
  variables): for each route, each question runs twice on the same model,
  provider search and Enigma's `web_search` on Brave (the owner's key, from
  the environment, never the Keychain). It writes per run: whether it
  searched, sources (title, URL), times, and the answer, to the folder.
- [ ] **The script:** reads the folder, computes the gate's metrics, and
  runs a blind side-by-side judgment through a cloud model's CLI (Claude
  Code or Codex, the owner's choice), randomizing which answer is A,
  judging correctness, recency and sourcing. Its unit tests use fixture
  folders and a fake judge command.
- [ ] **Get the owner's approval** (20–100 paid searches per API route,
  plus plan usage), run, and apply the gate: the eval passes; it searched
  on 18 or more; 2 or more sources on 18 or more; no unsafe source; the
  judge prefers provider search or ties on 80% or more.
- [ ] **A route that fails** comes out of the set, and the owner decides
  what's next.

### Task 6.4: The report

- [ ] **Write** `docs/history/<date>-native-search-evaluation.md`: per route
  the eval score, the gate metrics, judge results and latency (CP0's and
  the comparison's). No answers or page text.

### Task 6.5: Docs, `to-do.md` and release notes

- [ ] **`docs/Web-Search.md`:** a "Cloud models' own search" section (which
  routes; only without message text; the restart; sources and fallback; the
  spec's privacy table; costs, checked on the OpenAI and Anthropic pricing
  pages on the day, with the date; near-me questions until F29; Gemini).
  Update "On models that choose their own tools" (no key needed on those
  routes), "How it works" and "Tests".
- [ ] **`docs/ChatGPT-Setup.md`, `docs/Claude-Code-Setup.md`,
  `docs/Cloud-Model-Selection.md`, `docs/Messages.md`, `docs/Chat.md`,
  `docs/Testing.md`,** as the spec's Docs section lists.
- [ ] **Release notes:** if `docs/release-notes/` has a file for an
  unreleased version, add "Cloud models can search the web with their
  provider's own search, with no Brave key." Otherwise put the line in the
  Hand-off for the owner.
- [ ] **`to-do.md`:** F30 keeps its lines until the merge; then tick it off.

### Task 6.6: Final audit and merge (worker, with the owner)

- [ ] **Install the signed app** with `scripts/install-app.sh`. Then, in the
  running app, with the owner:
  - a search question on each shipped route, without a Brave key: the
    activity steps, the sources list, the "web search" footer;
  - a chat that reads Messages, then searches: the restart on screen, then
    gate 3's card (with a Brave key) or no search (without);
  - "cafes near me" on a shipped route asks which city;
  - a Gemini search uses Enigma's `web_search`;
  - Stop during a provider search.
- [ ] **Merge.** Run the final `build`, `test` and `analyze`, mark the draft
  pull request ready, and merge `feat/f30-native-cloud-search` to `main`
  once CI passes.
- [ ] **After the merge:** confirm CI passes on `main`, tick F30 off in
  `to-do.md`, update the progress log, and leave the checkout on `main`.

## Exit criteria

- The report is in `docs/history/`, and every shipped route passed the gate.
- The docs match the behavior and name only the shipped providers.
- Python tests, `build`, `test` and `analyze` pass. CI passes on `main`
  after the merge.

## Reviewer checklist

- The gate's numbers come from the recorded runs; no route ships on a
  failed gate.
- The report and docs hold no answers, page text, keys or private paths.
- The judge is blind (A/B randomized) and the script's tests cover it.

## Hand-off

*Filled in by the CP6 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:** none; F29 extends the question set and the
   script.
