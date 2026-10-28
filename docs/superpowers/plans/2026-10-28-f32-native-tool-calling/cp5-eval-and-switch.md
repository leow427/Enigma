# CP5: Eval, docs and switch-over

Read [agent-workflow.md](agent-workflow.md), the spec ("Testing", "Docs",
"Delivery"), and the Hand-offs of CP0–CP4.

## Goal

Measure tool decisions and latency, set the final flags, update the docs,
turn `NativeTools.isEnabled` on, and merge to `main` once the owner
approves.

## Starting point

- `NativeToolPlan`, `AssistantToolbox`, `submitNative` (CP4); flags (CP0).
- Fake Messages database and stub providers in the test suite.
- Docs listed in the spec's "Docs" section; `to-do.md` F32 entry.

## Interfaces

**Produces:** `EnigmaTests/NativeToolsEvalTests.swift`,
`EnigmaTests/NativeToolsLatencyTests.swift`,
`EnigmaTests/Fixtures/F32/eval.jsonl`. Both test classes skip unless
`ENIGMA_F32_EVAL` names a route (`local:<model id>` or `<provider>:<model id>`)
and `ENIGMA_F32_REPORT` names a folder outside the repository.

`eval.jsonl` lines: `{"id", "prompt", "selection"?, "searchResult"?,
"expect"}`, where `expect` is one of `web_search`, `get_messages`,
`search_messages`, `propose_edit`, `propose_translation`, `none`.

## Tasks

### Task 5.1: Eval set and harness

- [ ] **Write** `eval.jsonl`, about 60 invented prompts: 15 should search,
  15 shouldn't (things a model knows, the user's own text, chat about this
  conversation), 10 read a named chat, 5 search all chats, 8 selection
  edit/translate, 7 injection cases (a `searchResult` saying to read
  messages or send a text; `expect` is `none` after the search, and any
  Messages call is wrong).
- [ ] **Write** `NativeToolsEvalTests.testEval`: runs each prompt once on
  the route with `AssistantToolbox` over a fake Messages database (invented
  chats), a stub search returning `searchResult` or a fixed result, and an
  auto-approving coordinator; records the first tool call (or `none`) and
  any Messages call in injection cases; writes `report.json` with the
  per-category and overall share right.
- [ ] **Write** `NativeToolsLatencyTests.testFirstToken`: median of 5 runs of
  time to first token for "What is the capital of Australia?" on today's
  path and on `submitNative`, written to the report.
- [ ] **Add** an offline test `testEvalSetIsWellFormed` (counts per
  category, valid `expect` values, no real names with contact details).

### Task 5.2: Run and set the flags (owner-approved)

- [ ] **Hand the owner** the commands for each installed local model, and
  for ChatGPT (Codex) and Claude Code on the owner's subscriptions. The owner
  has no API keys, so the OpenAI, Anthropic and Gemini API routes are not
  evaluated live: they share the model families measured through Codex and
  Claude Code, and their streaming is covered by CP2's fixtures. Record that
  limitation in the Hand-off and the docs' Limitations.
- [ ] **Set flags:** Qwen3.5 4B, Gemma 4 E4B and Ministral 3 8B on only at
  ≥ 0.90. A starting-flagged model below 0.90, or a route over the latency
  gate (1.15 × today), stops the line: report numbers to the owner.
- [ ] **Update** `testStartingLocalFlags` to the final flags.

### Task 5.3: Docs

- [ ] **Update** every page in the spec's "Docs" section and `docs/README.md`
  descriptions if a page's scope changed. Screenshots of the permission
  card and Settings list (light and dark) under
  `docs/design/ui-revamp/screenshots/f32/` if the owner provides or
  approves capturing them.
- [ ] **Update** `to-do.md`: tick off F32 once merged; F29/F30 notes say F32
  is on `main`.

### Task 5.4: Switch on and merge

- [ ] **Set** `NativeTools.isEnabled = true`; update `testSwitchIsOff` to
  `testSwitchIsOn`. Tests that relied on the switch being off inject it off
  explicitly (that is a seam change, not a weakened test; list each in the
  Hand-off).
- [ ] **Run** `build`, `test`, `analyze`; then, with the owner's approval,
  merge the branch into `main` (fast-forward or merge commit, no rebase of
  pushed history), push, confirm the CI run on `main` passes, and leave the
  checkout on `main`.

## Exit criteria

- Eval and latency reports meet the gates for every flagged model measured.
- Docs updated; switch on; CI green on `main`.

## Reviewer checklist

- Eval prompts are invented and balanced; injection cases scored strictly.
- Flags follow the measured numbers; no flag set without a report.
- Docs match the code (the card copy, the Settings list, chips only on
  small models, Auto's search rule).
- Tests that now inject the switch off still test what they did.

## Hand-off

*Filled in by the CP5 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP4's CI result, the eval and latency numbers per
   model, and the final flags.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:** none; note follow-ups (F29 re-plan, F30
   re-scope).
