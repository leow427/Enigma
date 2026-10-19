# Phase 10: Switch Over

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read every debrief at the end of
the phase 3 to 9 briefs in this folder.

## Goal

The new UI becomes the only UI. No old view, style, asset, setting, or doc
remains. Nothing a person can do today is lost, and no test coverage is lost.

## Build

1. **Remove the flag.**
   - Delete `NewUIPreference`, its "Use new UI" toggle, its tests, and every
     `isEnabled` branch.
   - Keep only the new path.
2. **Delete the old UI.** At least:
   - `ForestBackdrop`, `NatureGlass`, `NatureGlassSurface`,
     `NatureButtonStyle`, `natureSurface`, and `naturePresentation`;
   - `GlassAppearanceSettings` and the liquid-glass Developer Tools controls;
   - `EnigmaCoalescenceView`, `ThinkingComposerGlow`, and the old
     `ThinkingStatusView`;
   - `EnigmaHelloView` and `EnigmaHelloLetter`;
   - the old `WelcomeSetupView` and the old tour card;
   - the old `SettingsView` body;
   - the old sidebar, composer, pickers, and Help;
   - the old `LocalMessageView` and old cards;
   - every old section view that phases 4 to 8 replaced.

   Delete the assets `ForestBackdrop`, `LeafThinking`, `EnigmaHello`, and
   `EnigmaCoalescence`, and any other asset nothing references any more.
   Remove deleted files from `project.pbxproj`. Search the whole repository
   for leftovers: `Nature`, `glass`, `Glass`, `forest`, `Forest`, `leaf`,
   `Leaf`, `Coalescence`, `hello`, `.ultraThinMaterial`, `.regularMaterial`,
   `glassEffect`, `LinearGradient`, `AngularGradient`, hard-coded `Color(`,
   `.white.opacity`, and `.black.opacity` in views. Each remaining hit must
   be something the new UI genuinely uses.
3. **Tidy the names.** If phases 4 to 8 named new views to tell them apart
   from old ones, such as `EnigmaSettingsView` next to `SettingsView`, rename
   them where the plain name is now clearer. Keep the
   `SettingsView.SettingsDestination` deep links working, or rename them
   consistently.
4. **Clean up `AppShellView`.** Remove the dead branches and modifiers. Keep
   it the owner of state and handlers. Split it into files by area if that
   makes the result clearer, without changing behavior.
5. **Migrate the tests.**
   - Every test that hosted an old view now hosts its replacement, with the
     same assertions.
   - Tests that only checked old-UI artwork, such as
     `testWelcomeAnimationIncludesAllFiveOriginalLetters`, are removed
     together with that artwork.
   - List every removed test in the debrief, with the reason.
   - The total test count may drop only by those.
6. **Update the docs.**
   - Delete `docs/Liquid-Glass-UI.md`.
   - Rewrite `UI-Style.md` as the reference for the new style, built from
     the spec, and remove its "Revamp in progress" note.
   - Update each doc in `docs/` that describes the old look.
   - Replace or remove screenshots in `docs/images/` that show the old UI,
     including `docs/images/liquid-glass/`, `welcome-setup/`, and
     `screen-consent/`. Use the snapshot helper to re-shoot those a doc
     still needs.
   - In the spec, mark the rollout done and drop the flag from "Rollout".
7. **Screenshots.** A final Paper and Ink set covering:
   - the welcome;
   - the main page;
   - a chat;
   - the compact panel;
   - every Settings page.

   Save them to `docs/design/ui-revamp/screenshots/phase-10/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- The debrief explains every removed test.
- The repository-wide search in step 2 comes back clean, or each remaining
  hit is explained.
- The app starts in the new UI on a fresh install and on an existing
  install, with the old `enigma.newUI.isEnabled` and glass defaults present
  or absent.
- Every flow from phases 4 to 8 still works.

## Debrief

**Built.** The new UI is now the only UI.

- **Removed:** the "Use new UI" flag (`NewUIPreference`), the liquid-glass
  setting, and every old view, style and modifier.
- **Old assets removed:** `ForestBackdrop`, `LeafThinking`, `EnigmaHello`,
  `EnigmaCoalescence`, `SpotlightAccent`, and `AccentColor`.
- **Removed outright:** the `Icons/` source art, `docs/Liquid-Glass-UI.md`,
  and `docs/images/`.
- **Unused tool icons deleted:** the new UI never showed `WebSearch`,
  `ScreenCapture`, `TemplateAttachment`, or `FileMode`, so they are gone.
  `MessagesTool` stays, because the Messages card uses it.
- **`AppShellView`** keeps every handler. It shrank from 2632 to 928 lines,
  with one root `.enigmaTheme`. Sheets apply the theme themselves.
- **`SpotlightPanelController`** keeps only the new sizing.

**Renames.** New views whose old twin had the plain name took that name, in
files of the same name. For example, `EnigmaSettingsView` is now
`SettingsView`, so `SettingsView.SettingsDestination` and the
`.settingsDestinationRequested` deep links are unchanged. `SpotlightLogo` is
now `EnigmaMenuBarMark`, and its PDF is byte-identical. The design system,
main window, compact panel and message list keep the `Enigma` prefix.

**Docs.**

- `UI-Style.md` is rewritten from the spec.
- The spec marks the rollout done.
- The feature docs name the current Settings pages and point at the
  screenshots in `docs/design/ui-revamp/screenshots/`.

The final set is in `screenshots/phase-10/`: 11 screens in Paper and Ink.

**Copy.** These now name pages that exist:

- the Help notes;
- the Brave and cloud error messages;
- the Screen setting;
- the ⌥S shortcut, now "Open Settings".

The tour's history and model steps now describe the new sidebar and the menu
beside Send, which is a change outside this brief.

**Upgrade safety.** Nothing reads `enigma.newUI.isEnabled` or the
`aiSpotlight.glassAppearance.*` keys any more. New tests start an existing
install and a fresh install with those keys absent, on, off, or unreadable.
`SettingsDestination` raw values are never saved, and no Codable type
changed.

**Tests.** The count went from 834 to 822: 14 removed and 2 added. 24 more
were renamed to drop "old", "new UI", "flag", "glass" or "leaf".

- **Removed:**
  - three tests of the deleted flag and glass setting:
    - `testSavedGlassAppearanceIsRestored`;
    - both `NewUIPreferenceTests`.
  - six flag-swap tests: in Settings, the welcome, the main window, the
    conversation, and two in the compact panel;
  - `testTurningTheFlagOffOpensTheOldPanelAtItsOwnSize`;
  - two tests of the deleted embedded theme and system appearance;
  - three tests of old art or the unused `ToolMenuLabel`:
    - `testCoalescenceThinkingRendersAnimation`;
    - `testWelcomeAnimationIncludesAllFiveOriginalLetters`;
    - `testToolMenuImagesHaveCompactIntrinsicSizesWithoutChangingAssets`.
- **Added:** the two upgrade tests.
- **Changed assertions,** each matching the new design, not weakened:
  - top-edge anchoring and the `panelAnswer` spring for the panel;
  - marker checks where a control is now a glyph (Stop, the bar's Help);
  - the 30 × 28 icon-button target;
  - the flush sidebar;
  - palette colours in the slash text view;
  - no checks on the deleted assets.

**Review.** There were no blockers. The reviewer confirmed:

- Nothing the new UI could do is lost.
- The changed assertions are faithful.
- Upgrades are safe.
- The leftover search is clean.
- Every doc link resolves, and there is no private info.

These fixes were made:

- stale Cloud screenshots, retaken;
- Settings paths that no longer exist, in copy and docs;
- the unused tool assets, deleted;
- complete test accounting;
- stale test names and comments;
- the slash text view's system colours, replaced with palette ones;
- a note in `agent-workflow.md` that the flag rules applied to phases 1–9.

**Leftover search.**

- None of these appear in the code: Nature, forest, Coalescence, materials,
  gradients, `.white` or `.black` opacity, `NewUIPreference`, or `newUI`
  (outside the upgrade test).
- The remaining hits are explained:
  - "glass": the upgrade test's stale keys, the "never use glassEffect" rule,
    and rollout history;
  - "leaf": file-tree leaves in File Mode;
  - "hello": test fixtures;
  - `Color(`: the palette's own definitions.

**Verification.**

- **Build and analyze:** both succeeded. The one warning (the
  `enigmaTestMarker` `@Entry` closure) is also on HEAD.
- **Full suite:** 822 executed, 18 skipped, 0 failed.
- **Reviewer's runs:** 409 tests, 0 failed.
- **Coordinator re-run:** main window, Settings, icons, slash commands, file mode, bundle, compact panel, and web search tests ran 163, skipped 5, and failed 0.

**Not yet checked by a person in the signed app:**

- startup with real old settings saved;
- the menu bar mark;
- the sheets now themed with `.enigmaTheme`;
- VoiceOver and Increase Contrast.

The opt-in live smoke tests stay skipped.
