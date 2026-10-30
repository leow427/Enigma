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

*Filled in by the CP10 worker, including the draft release-note text.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the owner:**
