# CP10: Docs, maintenance and the final audit

Read [agent-workflow.md](agent-workflow.md), the spec ("Docs",
"Maintenance", §6, §7), and the Hand-offs of CP2 to
[CP9](cp9-map-card.md#hand-off). Use the tuned values from CP7's report
wherever the docs give numbers.

## Goal

The docs describe how search works now, with nothing about Brave left. The
lists and the ddgs ports have the light maintenance loop the spec promises.
The worker and the owner then audit the finished feature in the running
app, and merge it.

## Starting point

- **These docs still describe Brave:** `docs/Web-Search.md` (19 mentions),
  `Welcome-and-Settings.md` (7), `Slash-Commands.md` (3), `Screen-Skill.md`
  (3), `Selection-Context.md` (2), `Chat.md` (1) and `README.md` (1).
  `Cloud-Model-Selection.md` quotes Auto's message.
- **`docs/Testing.md`** has an "Opt-in real-model and CLI checks" section,
  and documents the script tests.
- **The Settings screenshot** in `Web-Search.md` is
  `design/ui-revamp/screenshots/phase-5/settings-cloud-full-paper.png`.
- **`.github/workflows/ci.yml`** pins `actions/checkout` by SHA. New
  workflows do the same.

## Tasks

### Task 10.1: `docs/Web-Search.md`

- [ ] **Rewrite it** in the existing feature-doc shape: what it does, how to
  use it, what it sends where, how it works, limitations, tests. The
  sections:
  1. **Set up:** none.
  2. **Automatic search and the chip:** keep today's rules, minus the key.
  3. **`/search`.**
  4. **Places and weather:** small models' routing (with the
     `/search cafe near me` example), capable models' `find_places` and
     `get_weather`, `/maps`, and the map card (session-only). Keep the
     section "On models that choose their own tools" from F32 and F30, now
     without a key: the three tools, gate 3 on each, and F30's provider
     search beside the places and weather tools.
  5. **Sources:** the activity panel, the "web search" footer, "Never use
     this site", and blocked sites in Settings.
  6. **Privacy:** spec §7's recipients table, what's never sent, what's
     stored, and the Brave key cleanup.
  7. **Location.**
  8. **How it works:** every new file, with one line each.
  9. **Limitations:**
     - English wording only for automatic search;
     - AI-written content can't be reliably detected;
     - PDFs aren't read;
     - script-only pages fall back to snippets;
     - Open-Meteo's non-commercial terms;
     - MapKit has no opening hours;
     - the search sites' terms.
  10. **Maintenance:** the list refresh, and the ddgs watch.
  11. **Tests:** the new test classes, live checks and evaluation.
- [ ] **Check every number against the code,** after CP7's tuning: timings,
  limits, weights.

### Task 10.2: The other docs

- [ ] **Update the docs:**
  - `docs/README.md`'s Web Search row: "On-device web search, places and
    weather, sources and blocked sites";
  - `Welcome-and-Settings.md`: the new Settings section and welcome row;
  - `Slash-Commands.md`: `/search` needs no key; `/maps`; the native-tools
    table gains `find_places` and `get_weather`;
  - `Messages.md`: gate 3 covers places and weather too;
  - `Local-Model-Selection.md`: CP7's tool-choice scores;
  - `Chat.md`: the map card, and its Brave mention; `Screen-Skill.md` and
    `Selection-Context.md`: their Brave mentions;
  - `Cloud-Model-Selection.md`: Auto's message;
  - `Testing.md`: the `ENIGMA_LIVE_SEARCH`, `ENIGMA_SEARCH_FIXTURE_DIR` and
    `ENIGMA_SEARCH_EVAL` checks, and the new script tests;
  - `Updates.md`: the release checklist gets "Run
    `scripts/update-search-lists.py` and the live search checks".
- [ ] **Check that nothing is left:**
  `grep -rni "brave" docs/*.md docs/design/UI-Style.md` lists only history
  and the Brave browser.

### Task 10.3: The screenshot

- [ ] **Find the snapshot test** that renders the Cloud and search Settings
  page.
- [ ] **Run it** with
  `TEST_RUNNER_ENIGMA_SNAPSHOT_DIR=<folder> scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>/<test>`.
- [ ] **Replace** `docs/design/ui-revamp/screenshots/phase-5/settings-cloud-full-paper.png`,
  and place CP9's map card screenshot in `Web-Search.md` and `Chat.md`.
- [ ] **Look at it,** with the image reader, before handing off.

### Task 10.4: The upstream watch

**Files:**

- Create `scripts/check-ddgs-upstream.py`, standard library only.
- Tests: `scripts/tests/test_check_ddgs_upstream.py`, with saved API
  responses in `scripts/tests/fixtures/ddgs-upstream/`.
- Create `.github/workflows/ddgs-watch.yml`.

**Interfaces:**

- **The script:**
  `python3 -I scripts/check-ddgs-upstream.py [--api-fixtures <folder>]`.
  1. It reads `Enigma/Search/Engines/UPSTREAM.json`.
  2. It gets the latest release tag from
     `https://api.github.com/repos/deedy5/ddgs/releases/latest`.
  3. For each recorded file, it gets
     `contents/<path>?ref=<tag>`'s `sha`.
  4. It prints JSON: `{"tag": …, "changed": [paths], "compare": "https://github.com/deedy5/ddgs/compare/<old tag>...<new tag>"}`.

  It exits with status 0 whether or not anything changed, and status 1 only
  on errors.
- **The workflow:**
  - triggers: a weekly `schedule` (`17 6 * * 1`) and `workflow_dispatch`;
  - permissions: `contents: read` and `issues: write`;
  - runs on `ubuntu-latest`, with checkout pinned to the SHA `ci.yml` uses;
  - when `changed` isn't empty, it uses `gh` with `GITHUB_TOKEN` to open, or
    update, one issue labelled `ddgs-upstream`, titled "ddgs changed:
    <files> (<tag>)" and linking the compare URL;
  - it never contacts a search site.

**Steps:**

- [ ] **Write the failing tests:**
  - `test_detects_changed_files`;
  - `test_no_change_reports_empty`;
  - `test_compare_url`.
- [ ] **Run** `python3 -I -B -m unittest discover -s scripts/tests`. Expect
  failures.
- [ ] **Implement** the script and the workflow. Check the workflow with
  `actionlint` if it's installed. Otherwise, run it once
  through `workflow_dispatch` after the merge.
- [ ] **Run the tests,** then the script live. With today's tag it should
  print `"changed": []`, unless ddgs changed after CP2.

### Task 10.5: Warning about stale lists

**Files:**

- Create `scripts/check-search-lists-age.py`.
- Test: `scripts/tests/test_check_search_lists_age.py`.
- Modify `scripts/release.sh`.

**Interfaces:**

- **The script:**
  `python3 -I scripts/check-search-lists-age.py [--manifest <path>] [--today YYYY-MM-DD]`.
  When the manifest's `generated` date is more than 60 days old, it prints
  `warning: search lists are <N> days old. Run scripts/update-search-lists.py before releasing.`
  It always exits with status 0.
- **`release.sh`** runs it during preflight. It only warns, and never
  blocks.

**Steps:**

- [ ] **Write the failing tests:**
  - `test_warns_after_sixty_days`: 61 days old warns;
  - `test_quiet_within_sixty_days`: 60 days old doesn't.
- [ ] **Run** the Python tests. Expect failures.
- [ ] **Implement** the script and the `release.sh` call.
- [ ] **Run** the Python tests. Expect them to pass.

### Task 10.6: Notices and release notes

- [ ] **Check the notices.** `ThirdPartyNotices.txt` must credit:
  - ddgs;
  - Readability.js;
  - the Public Suffix List;
  - Phishing.Database;
  - the Block List Project;
  - the three uBlacklist lists;
  - Wikipedia's Perennial sources (CC BY-SA 4.0);
  - Open-Meteo (CC BY 4.0).

  Add anything missing.
- [ ] **Draft the release-note text** in your Hand-off. Include: web search
  now runs on your Mac with no key; Apple Maps and Open-Meteo answer places
  and weather; "Never use this site"; and the saved Brave key was removed.
  Put it in the next version's file once the owner picks the version.

## Exit criteria

- [ ] `scripts/verify-xcode.sh build`, `test` and `analyze` pass. The Python
  tests pass.
- [ ] No doc describes Brave search as current.
- [ ] The workflow and scripts are in place, and their tests pass.

## Final audit and merge (worker, with the owner)

After CP10 is committed:

1. **Verify everything.** Run `scripts/verify-xcode.sh build`, `test` and
   `analyze`; the Python tests; and the live checks with
   `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1`.
2. **Check the running app**, in a signed build from Xcode or
   `scripts/install-app.sh`. With the owner:
   - first launch shows search ready, and the old Brave key is gone;
   - searches work on Local, Cloud, Auto and Screen;
   - on a small and a capable model: "cafe near me" and `/maps bookshops`
     use Apple Maps and show the map card; "will it rain tomorrow" uses
     Open-Meteo; "what is the temperature to bake salmon" doesn't;
   - after a Messages read, a search, a places lookup and a weather check
     each ask first;
   - on a cloud route F30 serves, a web question uses the provider's search
     and a nearby question uses `find_places`;
   - "Never use this site" and Undo work, and Settings lists and removes
     blocked sites;
   - Console (category `search`) shows no queries or URLs;
   - Stop during a search cancels at once.
3. **Mark the draft pull request ready** (CP1b opened it). Its description
   explains the behavior change, the decisions, the verification, the known
   limitations and the evaluation report, with screenshots of the new
   Settings section, a blocked source row and the map card. Wait for CI to
   pass, then merge.
4. **Finish up:**
   - leave the checkout on the updated `main`;
   - mark F29 done in `to-do.md`;
   - put the release-note text in the version file the owner chooses;
   - run the ddgs watch once through `workflow_dispatch`.
5. **Next:** none; F30 shipped first.

## Reviewer checklist

- **Every number in the docs** matches the code after CP7's tuning.
- **The privacy section** matches spec §7 and the real behavior: no
  coordinates to search sites; nothing saved but blocked domains.
- **The workflow** has the least permissions it needs, actions pinned by
  SHA, and no search-site traffic.
- **The release warning** never blocks a release.

## Hand-off

*Filled in by the CP10 worker, 2026-10-30. Decisions D164–D170 in
[overnight-decisions.md](overnight-decisions.md). Built under the owner's D128,
not this brief's "Brave removed" (D164).*

1. **Summary:** Tasks 10.1–10.6 are done; the final audit and merge are the
   owner's. `docs/Web-Search.md` is rewritten: no setup; on-device search as how
   search works, with Brave as an optional key in Settings for web searches only
   (places and weather stay on Apple Maps and Open-Meteo); places, weather,
   `/maps` and the session-only map card; the three tools on capable models with
   gate 3; F30's provider search kept; sources and "Never use this site"; the
   §7 recipients table with Wikidata, Google News and Brave rows; how it works
   in seven steps with every number taken from the code; limitations;
   maintenance; tests. No key cleanup is documented (D134). The other docs drop
   Brave as required or default. The full Cloud and search Settings screenshot
   is regenerated (Paper and Ink). The ddgs watch (script, saved-response tests,
   weekly workflow) and the stale-lists warning in `release.sh` are in. The
   notices already credit everything (D168).
2. **Files:**
   - Docs: `docs/Web-Search.md` (rewritten), `README.md`, `Welcome-and-Settings.md`,
     `Slash-Commands.md` (`/maps` row, the two tools, no key gate), `Messages.md`
     (gate 3 row for places and weather), `Local-Model-Selection.md` (D169),
     `Chat.md` (map card; footer and card text), `Screen-Skill.md`,
     `Selection-Context.md`, `Cloud-Model-Selection.md` (Auto's message),
     `Testing.md` (live checks, fixture refresh, evaluation, script tests),
     `Updates.md` (release step and the warning), `ChatGPT-Setup.md`,
     `Claude-Code-Setup.md`.
   - Screenshots: `docs/design/ui-revamp/screenshots/phase-5/settings-cloud-full-{paper,ink}.png`.
   - New: `scripts/check-ddgs-upstream.py`, `scripts/check-search-lists-age.py`,
     `scripts/tests/test_check_ddgs_upstream.py`,
     `scripts/tests/test_check_search_lists_age.py`,
     `scripts/tests/fixtures/ddgs-upstream/{changed,unchanged}/`,
     `.github/workflows/ddgs-watch.yml`.
   - Changed: `scripts/release.sh` (one warning line in preflight).
   - Plan: this Hand-off, the progress row, decisions D164–D170.
3. **Decisions:** D164 (docs follow D128; numbers from the code; audit left to
   the owner), D165 (the watch compares blob SHAs; a removed file counts as
   changed; `--upstream` added for tests), D166 (one issue, edited in place; label
   created with `--force`; `persist-credentials: false`), D167 (the warning never
   blocks, even without `python3`), D168 (no notices for Wikidata or Google News),
   D169 (no tool-choice scores exist for the new tools), D170 (`to-do.md` and the
   map card image left for the owner); review round 1: D171–D172 (orchestrator's),
   D173 (the fixes).
4. **Verification:**
   - Python tests: `python3 -I -B -m unittest discover -s scripts/tests`, 94 run,
     OK (RED first: the 2 new modules failed to import before the scripts existed).
     New: 7 for the watch (`test_detects_changed_files`,
     `test_no_change_reports_empty`, `test_compare_url`, removed file, errors,
     unreadable `UPSTREAM.json`, API URLs) and 4 for the warning
     (`test_warns_after_sixty_days`, `test_quiet_within_sixty_days`, unreadable and
     missing manifest).
   - Live: `python3 -I scripts/check-ddgs-upstream.py` (api.github.com only)
     printed `{"tag": "v9.16.1", "changed": [], ...}`, exit 0.
     `scripts/check-search-lists-age.py` is quiet today (lists generated
     2026-10-30) and warns at 94 days with `--today 2027-02-01`.
   - Review round 1 (no Blocker; D171–D173): the fixture API now requires the
     latest tag as the contents ref; mutants "no ref" (3 failures, 1 error) and
     "ref = recorded tag" (1 failure, 1 error) fail and were restored. Six new
     offline tests (`LiveAPI` with `urlopen` patched: 404, other errors, no token
     header, token header; empty `files`; non-GitHub repository). Python tests
     after the fixes: 100 run, OK. Docs fixed for gate 3's shared grant, Apple's
     reverse geocoding (spec §7 amended, owner to confirm), and the nits.
   - `sh -n scripts/release.sh`: OK. The workflow parses as YAML; `actionlint`
     isn't installed.
   - Snapshot: `EnigmaSettingsTests/testSaveSettingsScreenshots` alone, 1 test,
     0 failures; both full Cloud images looked at: the Web search section shows
     `ready`, the optional Brave row `not used` with an empty key field, the
     blocked-sites note and the DuckDuckGo/Wikipedia/Wikidata/Google News note.
     No private info: fixture settings, no account, no key, no home path.
   - `scripts/verify-xcode.sh build`: succeeded. No Swift changed, so no test
     classes, `test` or `analyze` were run.
   - `grep -rni brave docs/*.md`: Brave appears only as the optional key (Web
     Search, Welcome and Settings, Slash Commands, Messages, Chat), the opt-in
     Brave comparison in Testing, and the Brave browser in Selection Context.
5. **Limitations:**
   - No review round on CP10.
   - The map card has no screenshot (CP9 Task 9.4 is the owner's).
   - The workflow hasn't run on GitHub; `actionlint` wasn't available.
   - `Local-Model-Selection.md` has no scores for `find_places` and `get_weather`:
     Task 7.5 wasn't run.
   - `Web-Search.md`'s quality statement relies on CP7's typed half only
     (on-device 26, Brave 32, tie 2 of 60).
6. **For the owner:**
   - **Release note draft** (put it in `docs/release-notes/<version>.md` once you
     pick the version, under `# Enigma <version>`):

     > ### Web search on your Mac
     >
     > - Web search now works with no setup and no key. Enigma searches
     >   DuckDuckGo and Wikipedia, reads the result pages on your Mac, and lists
     >   the sources under each answer. Wikidata adds dated facts, and Google
     >   News adds headlines for news questions.
     > - Nearby places come from Apple Maps, with a map card under the reply,
     >   and the weather comes from Open-Meteo. Type `/maps` to look up places.
     > - Right-click a source and choose **Never use this site** to stop Enigma
     >   using it. Blocked sites are listed in Settings → Cloud and search → Web
     >   search.
     > - Have a Brave Search key? It still works: while it's saved, web searches
     >   go to Brave instead.

   - **Final audit, adapted to D128** (signed build from Xcode or
     `scripts/install-app.sh`):
     - with no Brave key, first launch shows Web search `ready · no setup needed`
       in the welcome and `ready` in Settings; searches work on Local, Cloud,
       Auto and Screen, and the footer says "web search";
     - with a Brave key saved, Settings shows `Brave in use`, a web search uses
       Brave (footer "brave search"), while "cafe near me" and "will it rain
       tomorrow" still use Apple Maps and Open-Meteo; removing the key goes back
       to on-device search on the next search;
     - on a small and a capable model: "cafe near me" and `/maps bookshops` show
       the map card; "will it rain tomorrow" uses Open-Meteo; "what is the
       temperature to bake salmon" doesn't;
     - after a Messages read, a search, a places lookup and a weather check each
       ask first, naming search sites (or Brave), Apple Maps and Open-Meteo;
     - on ChatGPT or Claude Code, a web question uses the provider's search and
       a nearby question uses `find_places`;
     - "Never use this site" and Undo work, and Settings lists and removes
       blocked sites;
     - Console (category `search`) shows no queries or URLs; Stop during a
       search cancels at once;
     - CP9's map card checks (Recents relaunch, scroll, pins, Open in Maps,
       attribution, Paper and Ink, far-apart places).
   - **Verification left:** `scripts/verify-xcode.sh test` (full suite, screen
     unlocked) and `analyze`; the live checks with
     `TEST_RUNNER_ENIGMA_LIVE_SEARCH=1`; then the PR, CI and merge.
   - **Map card screenshot:** from the signed app (CP9 Task 9.4), saved as
     `docs/design/ui-revamp/screenshots/phase-7/map-card-{paper,ink}.png` or
     similar, then linked under "Places and weather" in `Web-Search.md` and in
     `Chat.md`'s conversation bullet.
   - **ddgs watch:** after the merge, run it once from the Actions tab
     (`workflow_dispatch`) and check it ends with "No ported file changed."
   - **`to-do.md`:** mark F29 done after the merge (unchanged here, D170).
   - **Owner calls:** whether to add a courtesy Wikidata line to the notices
     (D168); confirm spec §7's amended Apple row (reverse geocoding for every
     nearby question, D171).
