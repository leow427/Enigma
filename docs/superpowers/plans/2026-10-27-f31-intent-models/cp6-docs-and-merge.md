# CP6: Docs, report and merge

Read [agent-workflow.md](agent-workflow.md), the spec ("Docs", "Delivery"),
and the Hand-offs of every earlier brief.

## Goal

Describe what shipped, record the evaluation, audit the whole branch, and
merge it to `main`. Write the docs from what the branch actually does: a
skill that kept its rules is described as rules.

## Starting point

- **Docs that describe recognition today:**
  - `docs/Slash-Commands.md`, "Recognized commands" and "How commands are
    recognized" ("It checks fixed English rules on this Mac, with no extra
    model call");
  - `docs/Web-Search.md`, "Automatic search";
  - `docs/Cloud-Model-Selection.md`, Auto's routing and its file and test
    tables;
  - `docs/Testing.md`, the opt-in test variables;
  - `docs/README.md`, the feature index;
  - `AGENTS.md`, "Build, Test, and Development Commands".
- **`to-do.md`:** F31's entry, and F29's **Status** line ("paused after CP1
  … until F31 is merged").
- **Evaluation reports** live in `docs/history/evaluations/`.

## Tasks

### Task 6.1: Feature docs

- [ ] **`docs/Intent-Models.md`** (new), in the style of the other feature
  pages:
  - what the models decide, per skill, and which rules stay rules (spec §2);
  - what they read and what never leaves the Mac (spec §5);
  - the example files, the script, cut-offs and leans, the speed limits,
    pins and their cap, fingerprints;
  - how to add a reported miss: add it to `must-pass.jsonl`, add a few
    similar training examples (never test examples), retrain with
    `scripts/train-intent-models.sh <skill>`, run `IntentScoreTests`, and
    commit the model with its training file;
  - limitations: English only, the first and last 500 characters of long
    drafts, no learning on the Mac;
  - the tests that cover it.
- [ ] **`docs/README.md`:** a row for the new page.
- [ ] **`docs/Slash-Commands.md`:** replace "fixed English rules on this
  Mac, with no extra model call" with small trained models on this Mac plus
  fixed privacy rules, with nothing leaving the Mac and no extra model
  call, and link `Intent-Models.md`. Keep the recognized and not-recognized
  examples that are still true.
- [ ] **`docs/Web-Search.md`** and **`docs/Cloud-Model-Selection.md`:** the
  same change for automatic search and for Auto's coding and reasoning
  checks, and their file and test tables. Say that Auto's two checks read
  the typed message and the attached selection or file text, and that the
  chips read only what you type (spec §5).
- [ ] **`docs/Testing.md`:** `ENIGMA_INTENT_REPORT`, and what
  `IntentScoreTests` checks.
- [ ] **`AGENTS.md`:** one line under "Build, Test, and Development
  Commands": `scripts/train-intent-models.sh <skill>` retrains a recognition
  model; see `docs/Intent-Models.md`.

### Task 6.2: The evaluation report

- [ ] **Write** `docs/history/evaluations/<date>-f31-intent-models.md`: for
  each skill, the rules' baseline and the model's test accuracy and share of
  wrong yeses, the must-pass result, the model type, cut-off and p95, the
  pin count, and whether it switched (and if not, the owner's decision). Add
  the example counts and the owner's spot-check result.
- [ ] **Index it** in `docs/history/README.md` if that file lists reports.

### Task 6.3: `to-do.md`

- [ ] **Mark F31 done** in the file's "✅ Done" style, with a short summary
  and the evaluation report's link.
- [ ] **Change F29's Status line** to say F31 is merged and F29 resumes:
  CP1's unfinished review, merging `main` into its branch, then the
  weather/places/web model built with F31's tools before CP5.

### Task 6.4: Final audit and merge

- [ ] **Run** `scripts/verify-xcode.sh build`, `test` and `analyze`.
- [ ] **Start a final reviewer** (`model: "opus"`, `effort: "xhigh"`) on the
  whole branch against `main`, with the workflow's reviewer rules and spec
  §5. Fix its findings as in any round, at most four rounds.
- [ ] **Commit** this checkpoint as the workflow says, push, and wait for CI
  on the pull request.
- [ ] **Merge,** with the owner's go-ahead in the chat: mark the pull
  request ready, merge it with a merge commit (no squash or rebase), and
  respect any branch protection. Confirm the merge commit is on
  `origin/main` and its CI run passes. Leave the main checkout on the
  updated `main`.
- [ ] **Report** to the owner: the merge commit, the CI result, and each
  skill's outcome in one table.

## Exit criteria

- Every doc above matches the shipped behavior.
- `build`, `test` and `analyze` pass; CI passes on the merge commit.
- `to-do.md` marks F31 done and F29 ready to resume.

## Reviewer checklist

- **Docs match the code,** skill by skill, including any skill that kept its
  rules.
- **No private data** in the report or docs: no home paths, emails or
  example text that looks real.
- **The whole branch:** privacy rules intact, no stray files, no leftover
  fixture or probe code, every model committed with the training file it
  was trained from (fingerprints match).

## Hand-off

*Filled in by the CP6 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:** include CP5's CI result and the merge commit's CI
   result.
5. **Limitations:**
6. **For F29:** what F29's worker needs to resume, including any conflicts
   expected when `main` is merged into `feat/f29-on-device-search`
   (`WebSearchPolicy.swift`, `LocationService.swift`).
