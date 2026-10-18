# UI Revamp Agent Workflow

The revamp is built one phase at a time on the `feat/ui-revamp` branch. Each
phase follows the same steps:

1. A worker agent builds it from its brief in [briefs/](briefs/).
2. A fresh reviewer agent checks it.
3. If the reviewer finds problems, the same worker fixes them.
4. The worker sends a debrief.
5. The coordinating agent checks the result and commits it.

Phases never run in parallel. Read this file, the phase brief, and the spec
([README.md](README.md)) before starting.

## Context

- Enigma is a macOS 26 menu-bar app written in Swift 6 and SwiftUI. Read
  `AGENTS.md` first. Its rules apply to every phase.
- The approved design is in [README.md](README.md) (the spec) and the two
  interactive mockups, [main-window.html](main-window.html) and
  [panel-and-settings.html](panel-and-settings.html). When the spec and a
  mockup disagree, the spec wins. Report anything that can't be built as
  specified instead of improvising a different design.
- The tokens are in `AI-Spotlight/App/EnigmaTheme.swift`:
  - colors: `EnigmaPalette.paper` and `.ink`, chosen through `EnigmaAppearance`;
  - type: `EnigmaTypography`;
  - motion: `EnigmaMotion`.
- Phases 1 to 9 built the new UI behind a temporary "Use new UI" switch.
  Phase 10 removed the switch and the old UI, so the new UI is the only one.
- Phase 2 moved the main window's logic into small models that the new screens
  share:
  - `ShellPresentation`: which panels are open, the routing mode, and composer
    focus;
  - `ComposerSubmission`: what Send does with a draft;
  - `ChatHistoryList`: the sidebar's history rows.

## Rules for workers

- **Don't commit or touch git state.** No `git add`, `commit`, `stash`,
  `checkout`, `reset`, or `clean`. The coordinator commits.
- **Leave the strays alone.** Never edit, move, or delete the untracked
  `Enigma 2026-09-10 18-04-09/` folder or the three SVGs at the repository root
  (`elastic-juggle.svg`, `enigma-coalescence.svg`, `leaf-thinking.svg`).
- **Stay in scope.** Make only the brief's changes plus whatever they strictly
  need. List any change outside the brief in the debrief, with the reason.
- **Keep tests honest.** Don't delete, disable, or weaken a test. If an
  existing test has to change because a view moved, keep what it checks.
- **Keep the old UI intact while the flag is off.** Until the switchover
  phase, the app with "Use new UI" off must look and behave exactly as before.
  The new UI must also work: turning the flag on swaps in whatever screens are
  done so far.
  (This rule and the reviewer's "Old UI" check applied to phases 1 to 9. Phase
  10 removed the flag and the old UI, so they no longer apply.)
- **Separate logic from views.**
  - `AppShellView` stays the owner of state and event handling.
  - New screens are new view files that take the existing models, bindings,
    and closures. Don't copy handlers.
  - When a screen needs new logic, put it in a small testable type, like the
    phase 2 models.
- **Use the tokens.**
  - Colors come only from the palette in the environment (see phase 3's
    `enigmaPalette`).
  - Never use hard-coded colors, materials, `glassEffect`, blur,
    `NatureGlass`, `ForestBackdrop`, gradients, or glows.
  - Fonts come from `EnigmaTypography`, and springs from `EnigmaMotion`.
- **Reuse the shared controls.**
  - Shared controls (buttons, switches, rows, menus, text fields, hints) live
    in one place.
  - Extend them rather than making a local copy.
  - The first phase that needs a control adds it there.
- **Accessibility.**
  - Support Reduce Motion: cross-fade instead of sliding, and keep the
    character still.
  - Support Increase Contrast: borders and hairlines at double opacity.
  - Give every control a VoiceOver label.
  - Make every clickable row reachable with Tab, with an `accent` focus ring.
- **Copy.** Plain, short sentences. Shortcuts are written as in the spec:
  - `⌥⌃` opens Enigma;
  - by default, a double-tap of `⌥` asks about a selection;
  - double-tap Control toggles the sidebar;
  - `⌘K` is the mode palette.
- **Privacy and fallbacks.** Keep the existing permission prompts, consent
  steps, and error paths, and exercise their failure paths in tests.

## Project mechanics

- **Register new files by hand.** The Xcode project has no synchronized
  groups. Each new Swift file needs four entries in
  `AI-Spotlight.xcodeproj/project.pbxproj`:
  - a `PBXBuildFile`;
  - a `PBXFileReference`, with its path relative to `SOURCE_ROOT`;
  - an entry in the main group `A70000000000000000000001`;
  - an entry in the right target's Sources phase. App files go next to
    `MessagesControls.swift in Sources`, and test files next to
    `MessagesToolCallingTests.swift in Sources`.

  Use new unique 24-character hex IDs. Check the result with `plutil -lint`.
- **Verify** with `scripts/verify-xcode.sh build`, `test`, and `analyze`. Save
  the logs outside the repository and report the results:
  - the build result;
  - test counts: executed, skipped, failed;
  - the analyzer result.

  While iterating, run only the relevant tests with
  `-only-testing:EnigmaTests/<Class>`.
- **Screenshots.**
  - Phase 3 adds a snapshot helper to the test target. It renders a view in
    Paper and Ink to PNG files, and only when the `ENIGMA_SNAPSHOT_DIR`
    variable is set. Pass it to the test host as
    `TEST_RUNNER_ENIGMA_SNAPSHOT_DIR`. Without the variable the snapshot tests
    are skipped.
  - Each phase saves Paper and Ink screenshots of what it changed in
    `docs/design/ui-revamp/screenshots/phase-N/`. Keep the set small and the
    files reasonably sized.
  - Look at your own screenshots, with the image reader, and compare them with
    the mockups before you debrief.

## Debrief (worker to coordinator)

End every report with:

1. **Summary:** what was built, in a few sentences.
2. **Files:** each file added, changed, or removed, with one line on why.
3. **Decisions:** choices the brief left open, and any departure from the
   spec, with the reason.
4. **Verification:** the build, test, and analyze results, with counts, plus
   the screenshots you saved.
5. **Limitations:** anything unfinished, unverified, or risky. This includes
   anything that needs the signed app or a person to check by hand.
6. **Notes for later phases:** anything the next worker should know.

## Rules for reviewers

- **Don't edit files or touch git state.** Read, run commands, and report.
- **Scope.** Review the phase's changes: `git status`, `git diff`, and every
  new untracked file the phase added. Ignore the strays listed above.
- **Check, in this order:**
  1. **Correctness:** bugs, crashes, retain cycles, main-actor and
     concurrency mistakes, and broken bindings.
  2. **Old UI:** with the flag off, nothing has changed.
  3. **Parity:** with the flag on, behavior matches the old screen. That means
     the same actions, shortcuts, permission and consent steps, error states,
     and empty states.
  4. **The brief:** it is fully done.
  5. **The spec:** tokens, type, motion values, opaque surfaces, one accent
     control per view, and the accessibility rules.
  6. **Tests:** they are meaningful, deterministic, and offline, and none was
     weakened.
  7. **The Xcode project:** files are registered in the right targets.
  8. **No unrelated changes:** no strays, private paths, or attribution lines.
- **Run** `scripts/verify-xcode.sh test`, and `build` or `analyze` if you doubt
  the worker's results. Look at the phase's screenshots and compare them with
  the mockups.
- **Report** findings ranked from most to least severe. Mark each one
  **Blocker**, **Should fix**, or **Nit**, and give:
  - the file and line;
  - what is wrong;
  - a concrete failure scenario;
  - a suggested fix.

  Don't report style preferences that the spec and the surrounding code don't
  support. If nothing needs fixing, say so plainly.
