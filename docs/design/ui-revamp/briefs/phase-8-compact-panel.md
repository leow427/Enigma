# Phase 8: Compact Panel

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debriefs at the end of
the phase 3 to 7 briefs in this folder. This phase reuses the phase 6
composer pieces and the phase 7 reply and card views.

## Goal

With "Use new UI" on, the compact selection panel uses the new design: the
panel that opens over another app when you select text and double-tap `⌥`.
That includes its expanded answer. With the flag off, nothing changes.

## What exists today

- **In `AppShellView`:**
  - `shell.isSelectionComposer` is the compact composer.
  - `shell.isSelectionPresentation` keeps the window sized as the panel after
    it expands into a conversation.
  - `shellLayout` shows "No text selected", the `SelectionContextCard`s, and a
    screenshot attachment.
  - `composer(compact:)` adds the selection status button and the
    `isSelectionDetailsPresented` popover with the accessories. It uses the
    slash-command popover (`usesPopover`).
  - `SelectionComposerHeight` reports the height to the panel.
- **`SpotlightPanelController.swift`** sizes and places the panel:
  - `SelectionPanelPlacement` and `SelectionPanelExpansion`, with
    `composerSize` 720 × 92 and a minimum height of 72;
  - the expansion to 600 pt;
  - the `.selectionPanel…` notifications.
- **`SelectionContextService.swift` and `SelectionShortcut.swift`** capture the
  selection.
- **Tests:** `SelectionContextTests` covers this flow in depth. It must keep
  passing for the old UI.

## Design

The mockup is the panel in
[../panel-and-settings.html](../panel-and-settings.html) (`#pnl`), together
with the spec's "Compact panel" layout note. From top to bottom:

1. An optional `› selected "…"` line with a remove button. When no text is
   selected, it shows its own plain line.
2. The input row: the character in a 40 pt slot on the left, the input, and a
   monospace chip with the route and `↵`, such as `auto · local ↵`.
3. An answer area that springs open (`EnigmaMotion.panelAnswer`) and shows the
   reply with the mark, the serif body, and the meta line, using phase 7's
   reply view.
4. A monospace hint row.

Hints must be real. Only list shortcuts that exist today, for example
`/ commands`, how to expand into the full window, and `esc close`. Check the
code. If the mockup's `⌘O` doesn't exist, use the real way to expand, or leave
it out and say so in the debrief.

- The selection status and details popover becomes an opaque menu-style
  surface.
- The panel itself is an opaque `surface` with the `border` edge and the
  mockup's radius.
- The character listens while you type and thinks while the panel answers.
  It shows the error state when the selection can't be read or a permission
  is missing, and then the details open as they do today.

## Build

1. **`EnigmaCompactPanelView`**, or a set of compact variants of the phase 6
   and 7 views. Prefer variants of the shared pieces over copies.
   - Keep `SelectionComposerHeight` reporting, so the panel sizes correctly.
   - Change the panel size constants only if the new layout needs it. Keep
     the old values when the flag is off, and test both.
2. **Flag wiring** in `AppShellView` and, if needed, in
   `SpotlightPanelController`. Everything must work the same:
   - the selection, permission, and replacement paths;
   - /edit with automatic or manual replace;
   - growing into the conversation;
   - reset when a saved chat replaces the temporary one;
   - double-tap `⌥` and `⇧⌥Space`.
3. **Tests.** Mirror the `SelectionContextTests` checks that host the old
   compact UI against the new one. Add tests for the new logic, the height
   reporting, and live flag swapping.
4. **Screenshots.** Paper and Ink of:
   - the panel with a selection;
   - the panel with no selection;
   - the slash popover;
   - the details popover;
   - the opened answer;
   - an /edit revision.

   Save them to `docs/design/ui-revamp/screenshots/phase-8/`.
5. **Manual checks.** The global shortcut and the selection permissions only
   work in the signed app. List the exact steps a person should take with the
   signed build (`scripts/install-app.sh`) to verify this phase, and the
   expected result of each.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- With the flag off, the panel is unchanged, and `SelectionContextTests`
  passes unchanged.
- With the flag on, every selection flow behaves the same, and the panel
  sizes itself correctly as it opens and expands.

## Debrief

**Built.** With "Use new UI" on, the selection panel is `EnigmaCompactPanel`:
one opaque `surface` with the `border` edge and 16 pt corners. From top to
bottom it holds:

- the `› selected "…"` line, or `› no text selected`, with a status button
  and a remove button;
- the input row: the character in a 40 pt slot, the field, Attach, a
  monospace route chip that opens the mode and model menu, and a `↵` key that
  sends and becomes `stop` while a reply runs;
- the answer area, which reuses phase 7's message list and cards;
- a monospace hint row: `/ commands`, `⌃⌃ history`, `esc close`, and
  `⌘. stop` while a reply runs. Every hint is a real shortcut.

The panel grows downward on `panelAnswer` while the input stays in place. The
old details popover is now an opaque `menu` surface under the input. Near the
bottom of the screen, the command list and mode menu open above the input,
and the panel returns to its resting place when they close.

`SpotlightPanelController` learns which design is showing from the height
report and never reads the flag. With the flag off, the old panel's size,
upward growth, and placement are exactly as before.

**Decisions.**

- **Width.** The panel stays 720 wide, because the mockup's sizes are
  placeholders.
- **Expanding.** There is no `⌘O`. Double-tap Control is the real way to
  expand the panel and show the history.
- **Input row.** Attach, the chip menu, and the `↵` key keep parity with the
  old composer's controls.
- **Character errors.** The error state is limited to missing Accessibility,
  or no selection plus a capture notice.
- **`⌃` glyph.** It is the system font's own Control mark, the same one macOS
  menus use.

**Review.** There were no blockers. These fixes were made, each with tests:

- Escape closes the details first, through a shared `EnigmaEscapeDismissal`.
- Near the bottom of the screen, the lists open above the input and the
  panel returns to its place.
- The panel reopens at its resting height.
- The send key has a 24 × 24 target.
- Approval cards in the answer stay in view.
- The test fixture stubs Accessibility.
- The old panel opens at 92 after the flag is flipped.
- Key glyphs are set through a shared `EnigmaKeyedText`.

**Verification.**

- **Build and analyze:** both succeeded.
- **Full suite:** 821 executed, 16 skipped, 0 failed.
- **Coordinator re-run:** the compact panel, selection context, and main
  window tests ran 105, skipped 3, and failed 0.
- **`SelectionContextTests`:** unchanged.

**Manual checks in the signed build.** Run `scripts/install-app.sh`, then
turn on Developer Tools → "Use new UI".

1. Select text in Safari and double-tap ⌥. The panel opens near the
   selection, showing `› selected "…"`, the lime character, the
   `auto · local` chip, and the hints. The field has focus.
2. Press ⇧⌥Space with text selected. The same panel opens.
3. Double-tap ⌥ with nothing selected. The panel shows `› no text selected`,
   a status button with "!", and an amber character. Click the status button
   to open the details.
4. Type `/`. The command list opens. Press Escape to close only the list,
   then press Escape again to hide the panel.
5. Press ⌘K, or click the chip. The mode menu opens. Pick a model, and the
   chip updates.
6. Ask a question and press Return. The panel grows downward and the input
   stays put. The character falls into the reply, thinks, then answers, and
   the meta line appears. With Reduce Motion on, the panel grows at once.
7. Select text in TextEdit, double-tap ⌥, and send `/edit Make it formal`.
   Click Replace text. The panel hides, the text is replaced, the panel
   returns, and the card reads "Replacement sent".
8. Turn on automatic replacement in Settings → Selection, then repeat step 7.
   No card appears, and the text is replaced.
9. In a grown panel, double-tap Control. The full layout with the history
   appears. Double-tap Control again to go back.
10. Click a recent chat. The window goes back to its normal size and shows
    that chat.
11. Remove Enigma from Accessibility, then double-tap ⌥. The character turns
    amber, and the details offer "Open Accessibility Settings…". Grant
    access, and the character is lime again.
12. Send `/screen`. The screenshot card appears with Retake and Remove. Ask
    in cloud mode: the consent sheet appears, and "Keep Screenshots Local"
    keeps the draft.
13. With the details open, press Escape. The details close and the panel
    stays.
14. Double-tap ⌥ near the bottom of the screen, then type `/` and press ⌘K.
    Both open above the input, and the panel returns to its place when they
    close.
15. Turn the flag off and repeat steps 1 and 6. The old panel looks and grows
    upward exactly as before.

**Not yet checked by a person:**

- the live spring;
- VoiceOver, Increase Contrast, and Tab focus;
- the 320 pt threshold for opening above, on real screens.
