# CP6: Quality check, docs and audit

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing", "Docs"),
and every earlier Hand-off.

## Goal

Measure each turned-on route against the spec's gate, keep only the routes
that pass, write the report and the docs, audit the feature in the running
app with the owner, and merge.

## Starting point

- `CloudProviderID.nativeWebSearchProviders` holds every provider whose live
  check passed (CP4 and CP5 Hand-offs). The API-key routes are deferred
  (owner, 2026-10-29), so the quality check covers ChatGPT and Claude Code.
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
- [ ] **Get the owner's approval** (plan usage on each subscription), run, and apply the gate: the eval passes; it searched
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
  spec's privacy table; costs (plan usage, no Brave key); the API-key
  routes keep Enigma's search; the location card per provider, spec
  §2a, also in the "Location" section; Gemini).
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
  - "cafes near me" on a shipped route shows the location card naming that
    provider; For this conversation sends the area; another provider asks
    again; Don't allow makes the model ask which city;
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

1. **Summary:** Both shipped routes passed the gate with the owner's two
   decisions, and the docs now describe provider search. Built:
   - the 20-question set, `scripts/web-search-queries.json`;
   - F32's eval on provider-search routes: the provider's real search, counted
     as the `web_search` decision, and the app's restart for Messages reads;
   - the comparison test, the blind judge and the gate script, with tests;
   - the report, `docs/history/2026-10-29-native-search-evaluation.md`, and the
     docs the spec lists.

   Results: ChatGPT (`gpt-5.6-luna`) eval 58/60, searched 20/20, 2+ sources
   19/20 (second run), no unsafe source; Claude Code (`sonnet`) eval 58/60,
   searched 19/20, 2+ sources 19/20, no unsafe source. The judge wasn't run
   (owner). `nativeWebSearchProviders` stays `[.chatGPT, .claudeCode]`.
   Task 6.6 (the in-app audit and the merge) follows this commit, with the
   owner.
2. **Files:**
   - `scripts/web-search-queries.json` (new): the 20 questions.
   - `EnigmaTests/NativeToolsEvalTests.swift`: `Run.providerSearch` (set from
     `nativeWebSearchProviders`); on such a run the toolbox has
     `ProviderSearchPart` instead of the stub, `ChatRequest.providerSearch`
     is set, each `.searching` event is logged as a `web_search` call, and
     `RestartingGate` ends a request whose Messages read returns text
     (`Result.restarted`, not an error); `evaluate(…cloud:)` takes a fake
     client; `Report.providerSearch`; new
     `testEvalScoresProviderSearchAsSearch`.
   - `EnigmaTests/NativeWebSearchEvaluationTests.swift` (new, registered in
     the test target): `testQuestionSetIsWellFormed`,
     `testRecordKeysMatchTheScript`, the opt-in `testCompare`;
     `NativeSearchEvaluation` (questions, the run record, one run) and
     `NativeSearchTurn.ask`, one flagged turn through `submitNative`.
   - `EnigmaTests/NativeWebSearchLiveTests.swift`: its `ask` now calls
     `NativeSearchTurn.ask` (moved, not changed, except that a failed turn
     throws instead of failing and returning the reply).
   - `scripts/search_judge.py`, `scripts/evaluate-native-search.py` and
     `scripts/tests/test_evaluate_native_search.py` (new).
   - `docs/history/2026-10-29-native-search-evaluation.md` (new) and its row
     in `docs/history/README.md`.
   - `docs/Web-Search.md` ("Cloud models' own search", and "On models that
     choose their own tools", "Location", "How it works", "Limitations",
     "Tests"), `docs/ChatGPT-Setup.md`, `docs/Claude-Code-Setup.md`,
     `docs/Cloud-Model-Selection.md`, `docs/Messages.md`, `docs/Chat.md`,
     `docs/Testing.md`.
   - `Enigma.xcodeproj/project.pbxproj`: the new test file.
   - Outside the brief, from review round 2:
     - `Enigma/Chat/EnigmaConversationLogic.swift` (`ReplyMetaLine`): a
       searched reply with no recorded origin (reopened after a relaunch)
       says "web search", not "brave search". CP1's `ReplyOrigin` is
       session-only, so such a reply can't tell which search it used, and
       "brave search" claimed Brave saw a query only the provider saw. A test
       line in `EnigmaConversationTests`.
     - `Enigma/Search/WebSearchSettingsSection.swift`: the automatic-search
       subtitle said "Without a key, automatic search stays inactive"; it now
       says that without a key only ChatGPT and Claude Code search, with their
       provider's own search.
     - `docs/Slash-Commands.md`: `/search` and the native tools list name the
       provider's search.
   - The plan's progress-log row and this Hand-off.
3. **Decisions:**
   - **No Brave runs (owner, 2026-10-29):** "i do have one, but id rather not
     test with it, since we're scrapping brave all together literally right
     after this". The comparison ran provider search only; the Brave half and
     the judge are built and tested for F29.
   - **Ship without the judge check (owner, 2026-10-29):** both routes ship
     with it recorded as not run. `evaluate-native-search.py` stays strict
     and prints "does not pass" for an unrun check; the report records the
     waiver.
   - **ChatGPT's questions reworded (owner, 2026-10-29):** the first run gave
     2+ sources on 10/20: Codex linked exactly one page on 10 of the 11
     questions that said "Link your source." or "Link the docs" (and the
     like). The owner chose to change those eleven to "Link your sources."
     and rerun ChatGPT; Claude Code's run, on the first wording, stands. Both
     runs are in the report.
   - **The judge** is Claude Code (owner), with no tools, MCP servers,
     customizations or saved session; it reads the prompt on standard input
     and answers with JSON. The A/B order is random per question
     (`--seed` repeats it); the prompt never names a search or a provider.
   - **The gate script** uses shares of the whole question set (90% for
     searched and sources, 80% for the judge), so F29's 60 questions use the
     same bar; on 20 that's 18 and 16. Missing runs or judgments make a check
     `incomplete`, never `pass`. The eval check needs `providerSearch: true`
     and F32's search and none counts minus one (`F32_BASELINE`, from F32
     CP5; `--eval-baseline` for other routes). A failed judgment is recorded
     per question, and the summary is always written (review round 1).
   - **Proposed spec change (review round 1; workers don't edit the spec):**
     add to the spec's status lines "Amended 2026-10-29 after CP6 (owner): no
     Brave runs, so the judge check wasn't run and both routes ship without
     it; eleven questions were reworded to ask for sources and ChatGPT rerun
     (see the CP6 report)." The spec's Success line and Testing gate still
     read as if every check ran.
   - **The eval's Messages reads** end the request, as the app's restart
     does, so the invented chats never reach a provider. Injections can't
     arrive on these routes (they ride on the stub), so that category
     measures only search-then-no-Messages.
   - **First text time** is sampled every 50 ms from the reply on screen.
   - **`/search` without a key** still isn't suggested (suggestions, Help, the
     tour), though typed on ChatGPT or Claude Code it works with the
     provider's search. The docs say so; whether to suggest it there is left
     for the owner.
   - **Release notes:** 0.12.0 is released and there's no file for the next
     version. The owner asked for no release now (2026-10-29), so no notes
     file was started; the next version's notes, under **New**, get: "Cloud
     models can search the web with their provider's own search, with no
     Brave key."
4. **Verification:** (filled in below as each step completes)
   - Live, run by the worker with the owner's approval (2026-10-29), reports
     in the worker's scratch folder, not committed:
     - `TEST_RUNNER_ENIGMA_F32_EVAL=chatgpt-codex:gpt-5.6-luna` and
       `claude-code:sonnet` with `TEST_RUNNER_ENIGMA_F32_REPORT`,
       `-only-testing:EnigmaTests/NativeToolsEvalTests/testEval`: 58/60 each.
     - `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 TEST_RUNNER_ENIGMA_SEARCH_EVAL=<folder>`,
       `-only-testing:EnigmaTests/NativeWebSearchEvaluationTests/testCompare`:
       both routes, then ChatGPT again with
       `TEST_RUNNER_ENIGMA_SEARCH_EVAL_ROUTES=chatgpt-codex` after the
       rewording.
     - `python3 -I -B scripts/evaluate-native-search.py <folder> --no-judge
       --eval chatgpt-codex=… --eval claude-code=…`: the gate table in the
       report.
   - Review round 1 (Opus, xhigh): no Blocker; six Should fix, all fixed or
     proposed:
     - the gate's eval check ignored the category floors and stub-search
       reports;
     - shares counted only the records present, so a partial folder could
       pass;
     - four doc claims were wrong (an enforced cap of 5, "nothing new is
       saved", and the fallback "to `web_search`" without a Brave key, on
       ChatGPT and Claude Code);
     - the judge bar and ties were untested;
     - one failed judgment, or braces in its reason, aborted the run;
     - the spec doesn't record CP6's waivers (proposed above).
     The reviewer's surviving mutations (ties not counted, `>` for the bar,
     the bar at 0.5) and two more (floors off by two, `providerSearch` not
     checked) each fail a test now. The real runs' gate is unchanged.
   - `python3 -I -B -m unittest discover -s scripts/tests`: 36 tests, OK.
   - `NativeToolsEvalTests`, `NativeWebSearchEvaluationTests`,
     `NativeWebSearchLiveTests`, `NativeToolsLatencyTests`: 13 executed,
     5 skipped (opt-in), 0 failed (review round 2's count; an earlier count
     here was wrong).
   - Review round 2 (Opus, xhigh): no Blocker; round 1's fixes hold; it
     recomputed every number in the report from the recorded runs. Three
     small Should fix, fixed by the worker without a third round (owner's
     rule):
     - the "web search" footer reverted to "brave search" after a relaunch
       (fixed in `ReplyMetaLine`, above);
     - docs and the Settings subtitle still said search needs a Brave key;
     - the gate script accepted another route's eval report; it now needs
       the report's route to match (a ChatGPT report given for Claude Code
       fails), and the built-in baselines note the models F32 measured.
     After the fixes: `EnigmaConversationTests/testMetaLineSaysWhichModelWhereItRanAndWhen`,
     `NativeToolsEvalTests`, `NativeWebSearchEvaluationTests` and
     `WebSearchTests`: 64 executed, 2 skipped, 0 failed; the real runs' gate
     unchanged.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings in the changed files. `plutil -lint`: OK.
   - Full suite (`scripts/verify-xcode.sh test`, once, before the commit):
     1626 executed, 31 skipped, 0 failed.
5. **Limitations:**
   - The judge check is unrun (owner). Nothing compares provider search's
     answers with Brave's.
   - One run per question and route, on one evening's network.
   - The eval's injection category can't deliver an injection on provider
     routes; the provider's real results could carry one, and the eval
     doesn't measure that.
   - Task 6.6, the in-app audit (including CP4's and CP5's open checks: a
     nearby question with location allowed, on each route) and the merge,
     happens after this commit, with the owner.
6. **For the next checkpoint:** none; F29 extends the question set (adding a
   `query` field; extra keys are ignored by the tests and the script) and the
   script, and can run the judge with its own two backends through
   `search_judge.judge_pair`.
7. **Task 6.6, the in-app audit (owner, 2026-10-29):**
   - **Results:** steps 1 (a plain search question), 3 and 5 passed on the
     installed copy; no Gemini model was used for step 4. Step 2 (a ChatGPT
     turn that reads a chat and then searches) worked as the spec then said:
     the restart's second run used Enigma's search on Brave, and the reply
     said "brave search", with no card naming Brave.
   - **Rule change (owner, 2026-10-29):** "If a user is actively sending an
     'okay' with a title card to use chatgpt or claudes search as it is now,
     then they should use chatgpt and claudes search engine, not our in
     house made one or brave." The owner approved the design: in a chat that
     holds message text, and on a typed `/messages` turn, ChatGPT's and
     Claude Code's own search runs after a per-provider card, **Let
     ‹provider› search the web in this chat?**; declined, the turn has no
     search; the restart's second run asks the same card; the fallback when
     provider search is unavailable stays Enigma's search on Brave; and
     Enigma's own search card now says "It will be sent to Brave." ("Fix it
     now"). The spec carries the amendment (status line, Decisions,
     §1, §2, the privacy table and rules, Success, Docs).
   - **Files:**
     - `Enigma/Chat/ToolPermissions.swift`:
       `ToolPermission.providerSearchAfterMessages(provider:)` and its
       Always-grant kind, keyed by provider like the location grant (ChatGPT
       ≠ the OpenAI API, Claude Code ≠ the Anthropic API).
     - `Enigma/Chat/ToolPermissionCoordinator.swift`: the new card's title
       and detail; the Brave card's detail names Brave.
     - `Enigma/Chat/ToolPermissionCard.swift` (globe icon) and
       `Enigma/Messages/MessagesSettingsSection.swift` (the Always row).
     - `Enigma/Cloud/NativeWebSearch.swift`: `isAllowed` no longer checks
       message text.
     - `Enigma/Chat/AssistantToolbox.swift`: the typed `/messages` exclusion
       is gone; `NativeToolPlan.withoutSearch()` (a declined card, kept when
       the plan is remade).
     - `Enigma/LocalInference/LocalChatViewModel.swift` (`submitNative`):
       asks the card before the location card when the plan has provider
       search and the chat holds message text or `/messages` was typed;
       allowed, the gate delivers reads without a restart
       (`restartsProviderSearch` off); on a restart, asks the card before the
       second run. `allowsProviderSearch` checks for Stop after the card.
     - Tests: `NativeToolRequestTests` (the card on a `/messages` turn and in
       a chat holding message text, per-provider grants and the Settings row,
       Stop while the card shows, the restart allowed and declined, the
       location kept after an allowed restart), `NativeToolPlanTests`
       (`/messages` keeps provider search, `withoutSearch()`),
       `NativeWebSearchTests.testIsAllowed`, `ToolPermissionTests` (copy).
       Tests that encoded the old rule were changed on purpose:
       `testRestartRunsOnceWithoutProviderSearch` became
       `testRestartAsksThenSearchesWithTheProvider`, and
       `testRestartWithoutKeyHasNoSearch` became
       `testRestartDeclinedHasNoSearch`.
     - Docs: `Web-Search.md`, `Messages.md`, `Chat.md`, `ChatGPT-Setup.md`,
       `Claude-Code-Setup.md`, `Cloud-Model-Selection.md`,
       `Slash-Commands.md`, the plan's names table and progress log. The
       history report stays as measured.
   - **Outside F30 (owner):** the ChatGPT connection row now says
     "connected · selected for cloud" when ChatGPT is the cloud provider, as
     Claude Code's does (eabd97a).
   - **Review round 1 (Opus, xhigh):** no Blocker; no path found where
     message text reaches a provider search the user hasn't allowed. Fixed:
     - Should fix: the Stop test was stopping the "Send text from your
       messages" card, not the provider-search card, so removing the
       cancellation check after the card went unnoticed. It now stops only
       the provider-search card, and a second test stops the restart's card.
     - Should fix: a provider already allowed (an Always grant, or For this
       conversation) still restarted when a read came partway through a
       reply. `submitNative` now checks the grant without a card
       (`providerSearchGranted`), so the read goes through, as the docs say.
       New `testGrantedProviderSearchDoesNotRestart`.
     - Nits: stale spec, plan and code-comment lines about the second run
       having no provider search; the setup docs now mention a typed
       `/messages`; the Settings row reads "Let ‹provider› search the web
       after reading messages"; `providerSearchAllowed` lost an unused
       parameter; new `testRestartThenUnavailableFallsBack` (allowed on the
       restart, then unavailable: the third run uses Enigma's search);
       `testRestartKeepsTheReadGrant` asserts the exact cards.
     - Left for the owner: on a typed `/messages` turn in a new chat, the
       card says "This chat includes text from your messages." before any
       is in it. The owner approved that copy; a second wording would need
       a flag on the permission.
     - Not added: a ChatGPT-vs-OpenAI-API grant test; the key is the
       provider, and the Claude Code-vs-Anthropic API test covers it.
     Mutations checked after the fixes: no cancellation check after the card
     (2 tests fail), no grant check (`testGrantedProviderSearchDoesNotRestart`
     fails).
   - **Verification:**
     - 14 affected classes before review: 390 executed, 3 skipped, 1 failure,
       `ClaudeCodeSubscriptionTests/testClaudeCodeRestartDeliversNothing`
       (its stand-in process can die before creating the file the test
       reads; neither it nor its client changed here; 5/5 runs alone pass).
     - After round 1's fixes: `NativeToolRequestTests`,
       `ToolPermissionTests`, `NativeToolPlanTests`, `NativeWebSearchTests`:
       130 executed, 0 failed.
   - **Review round 2 (Opus, xhigh):** no Blocker or Should fix; it found no
     path to an unallowed provider search, and caught 8 of 9 mutations. Its
     four Nits, fixed by the worker without a third round:
     - stale "never delivered" and "in chats that hold no message text"
       lines in the spec (§2), the plan (Goal, Architecture), the
       `SavingMessagesGate` comment and `docs/Chat.md`;
     - the two Stop tests now await the task `stopStreaming()` returns, so
       they don't rely on job order;
     - the surviving mutation (only Always grants honoured) is now caught by
       `testConversationGrantSkipsTheRestartInItsChatOnly`, which also
       checks that another chat's grant doesn't count;
     - a declined card is now logged, since the turn's first log line is
       written before the card.
     After: `NativeToolRequestTests`, `ToolPermissionTests`,
     `NativeToolPlanTests`, `NativeWebSearchTests`: 131 executed, 0 failed.
     `scripts/verify-xcode.sh build` and `analyze`: succeeded, no warnings in
     the changed files.
     - Full suite (`scripts/verify-xcode.sh test`, once, before the commit):
       1634 executed, 31 skipped, 0 failed.
   - **Next:** the owner checks step 2 again on the reinstalled copy, then
     the rest of Task 6.6 (mark PR leow427/Enigma#23 ready, merge once CI
     passes, tick F30 in `to-do.md`).
