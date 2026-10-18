# Phase 6: Main Window

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debriefs at the end of
the phase 3, 4, and 5 briefs in this folder. They cover the character and its
stage, the theme and appearance setting, the shared controls (including the
opaque menu), and the snapshot helper.

## Goal

With "Use new UI" on, the main window's frame uses the new design: the
window, the sidebar, the main page (the empty state), the composer, the model
picker, the mode palette, and Help. With the flag off, nothing changes. The
message list is phase 7. In this phase, the new frame may show the old
message list when a chat has messages.

## What exists today

All of this is in `AI-Spotlight/App/AppShellView.swift`:

- **`shellLayout`** lays out the window in a `ZStack` over `ForestBackdrop`:
  - the sidebar, or `hiddenSidebarNavigation` when it's hidden;
  - `conversation`, where the empty state is "How can I help?" with the logo
    and `compactModeControls`;
  - `composerAccessories`: attachments, notices, and route status;
  - `composer(compact:)`.
- **`sidebar(compact:)`** has the logo, a hide button, New chat, the history
  rows (`ChatHistoryList`), Help, Settings, and `DeveloperToolsView`. That
  last one holds the "Use new UI" and liquid-glass toggles.
- **The composer** is the file tool button, `SlashCommandComposer` (in
  `SlashCommandComposer.swift`, with `CommandTextEditor`, an AppKit text view,
  and the slash-command list), the mode and model button, and Send or Stop.
  `ThinkingComposerGlow` shows while a request runs.
- **The pickers:** `modePalette` (`⌘K`), `modelMenu`, `cloudModelMenu`, and
  the route status views (`routeStatus`, `inactiveRouteStatus`,
  `autoRouteStatus`).
- **Help:** `KeyboardShortcutsHelpView`, presented as a sheet.
- **Tour anchors:** `.welcomeTourTarget(...)` on history, composer, commands,
  files, model, and help.
- **The window:** `AppShellView` clips to a 24 pt rounded rectangle with a
  `NatureGlass` edge. The `NSPanel` comes from `SpotlightPanelController.swift`.
- **Tests:** `FileModeUITests`, `LocalModelSelectionTests`,
  `SelectionContextTests`, `AppCommandTests`, `ScreenViewTests`, and
  `WebSearchTests` host these views. They must keep passing for the old UI.

## Design

The mockup is [../main-window.html](../main-window.html), and the spec's
"Layout notes" describe the sidebar, main page, and composer.

- **Sidebar** (`#sb`), in the `sidebar` color:
  - At the top, the app mark and "Enigma".
  - Then the New chat row with its `⌘N` hint, and Recents as plain rows with
    a selection dot and darker text, without boxes.
  - Settings and Help at the bottom, plus Developer Tools restyled.
  - Double-tap Control still toggles it.

  If something in the mockup doesn't exist in the app today, leave it out and
  list it in the debrief. Don't build new features in this phase. Examples:
  the sidebar Search, the cloud glyph on cloud chats if a session doesn't
  record its route, and any shortcut that doesn't exist.
- **Main page** (`#empty`):
  - the character in a 92 pt slot;
  - a short time-of-day greeting;
  - a monospace status line built from real state, such as
    `qwen3-8b is loaded · on this mac`, or what's missing;
  - the composer;
  - the slash commands as monospace example lines, built from
    `SlashCommand.available(...)`.

  "Choose GGUF Model" and the other empty-state actions stay, restyled.
- **Composer:** one rounded opaque `surface` box containing:
  - Attach, and `/` to open commands, on the left;
  - a monospace `● local` or `○ cloud` route indicator;
  - the model picker;
  - an `accent` Send button, which becomes Stop while responding.

  After the first send, the composer springs to the bottom
  (`EnigmaMotion.composerDock`). With Reduce Motion it cross-fades. There's
  no glow. While a request runs, the character shows the state instead.
- **Model picker and mode palette:** opaque menus (`menu` token), reusing
  phase 5's menu, that open from their trigger with `EnigmaMotion.menu`.
  `⌘K` still opens the mode palette.
- **Slash command list:** new styling for both the inline list and the
  popover. Restyle the text view's font, color, caret, and placeholder from
  the palette.
- **Window:** an opaque `background`, with the corner radius and `border`
  edge from the mockup. No glass, whatever the liquid-glass setting says.
  The window follows the appearance setting.

## Build

1. **New view files** for the sidebar, the main page, the composer (with the
   slash command styling), the pickers, and Help.
   - They take bindings and closures from `AppShellView`, which keeps every
     handler.
   - Logic that's inline in today's views and needed by both versions moves
     into small shared types with tests. Examples: the status line text, the
     route indicator, the greeting by time of day, and picker contents.
2. **Flag wiring in `AppShellView`.** The flag chooses between the old and
   new `shellLayout` pieces, and switches live.
   - With the flag on, the old `preferredColorScheme(.dark)`, the
     `NatureGlass` tint, and the clip and edge don't apply. The new theme
     modifier applies instead.
   - The phase 4 welcome keeps working above the new frame.
3. **The character across the window.**
   - Move the character stage to the window root.
   - When the welcome finishes, the character falls from the welcome slot
     into the main page slot.
   - The character listens while you type, sending `key(towards:)` per
     keystroke toward the composer.
   - It thinks while a request is preparing.
   - It shows the error state when the route can't run.
4. **Tour.** Add `.welcomeTourTarget(...)` anchors to the new controls, so
   the tour works with the flag on. Scroll the sidebar to its targets as the
   old one does.
5. **Tests.**
   - Every place that hosts the old frame with real interactions (clicks on
     the composer, the file tool, the mode palette, the editor taking focus,
     the selection composer) gets an equivalent for the new frame. Use
     `TestControlMarker` and `clickTestControl`.
   - The new shared logic.
   - The flag swaps the frame while the app runs.
   - The frame fits at the panel's minimum size (640 × 420) and default size
     (1200 × 780), with the sidebar shown and hidden.
6. **Screenshots.** Paper and Ink of the main page with and without the
   sidebar, the composer with the slash list open, the open model picker, the
   mode palette, and Help. Also the minimum-size layout. Save them to
   `docs/design/ui-revamp/screenshots/phase-6/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- With the flag off, the main window is unchanged.
- With the flag on, every action of the old frame works the same:
  - new chat, select a chat, and the sidebar toggle (including double-tap
    Control);
  - Help, Settings, and Developer Tools;
  - send and stop;
  - slash commands;
  - file mode;
  - mode, model, and `⌘K`;
  - the tour.
- The screenshots match the mockup.

## Debrief

**Built.** With "Use new UI" on, the main window uses the new frame:

- **Window:** an opaque `background`, 12 pt corners, and a `border` edge. It
  follows the appearance setting.
- **Sidebar:** the app mark, New chat (`⌘N`), Recents as plain rows with a
  dot, then Help, Settings, and Developer Tools.
- **Hidden sidebar:** a slim bar replaces the sidebar when it is hidden.
- **Main page:** the character in its 92 pt slot, a time-of-day greeting, a
  monospace status line built from the real route state, the Auto / Local /
  Cloud text control, and the slash-command example lines.
- **Composer:** Attach, `/`, the `● local` / `○ cloud` indicator, the mode
  and model menu, and Send or Stop. After the first send it springs to the
  bottom (`composerDock`).
- **Help:** new and themed.

The model picker and the `⌘K` palette are one `EnigmaMenu`, which opens 8 pt
below the composer.

The character stage sits at the window root:

- The character falls from the welcome slot to the main page.
- It listens while you type.
- It shows thinking and error states.

The tour anchors are on the new controls. New files:

- `EnigmaMainWindowLogic.swift`, the shared testable logic;
- `EnigmaSidebar.swift`;
- `EnigmaMainPage.swift`;
- `EnigmaComposer.swift`;
- `EnigmaHelpView.swift`.

`AppShellView` keeps every handler. Screenshots are in
`screenshots/phase-6/`.

**Decisions.**

- One menu holds mode and model, as the old palette did. It has a "more rows"
  strip when it doesn't fit.
- The route indicator is plain text, not a control.
- New chat keeps the mockup's accent plus glyph. Send is the only accent
  button.
- The mockup's shadows are left out, because they would need hard-coded
  colors.
- `→` replaces `⟶`, which SF Mono lacks.
- On short windows, the examples drop first, then the character.
- The new welcome fades out with `screenChange`.

**Not built**, because these features don't exist in the app today:

- sidebar Search;
- cloud glyphs on recent chats;
- the `⌘1`–`⌘3` shortcuts;
- dates on recent rows.

**Review.** There were no blockers. These fixes were made, each with tests:

- **The character's fall.** It jumped from the welcome to the main page
  instead of falling. The stage now hides a character whose slot vanished
  only one main-loop turn later, so a move sent in the same update falls from
  where it was. This also fixed the welcome's glide from hero to header.
- **Wasted work.** `AppShellView` re-rendered on every keystroke and pointer
  move. It now owns the character controller without observing it. The
  controller doesn't wake while hidden, and with the flag off the stage isn't
  attached at all.
- **Escape.** Escape with the menu open hid the whole panel. It now closes
  only the menu, and no menu outlives a hidden panel.
- **Tour corners.** The tour scrim showed square corners. It is now clipped
  to the window radius.
- **Smaller fixes:** a stale comment, attention left on the composer after
  Replay, a GGUF test that never clicked, a welcome test that couldn't tell
  dark from new, a mid-fade screenshot, and the menu's gap and long-menu
  reachability.

**Verification.**

- **Build and analyze:** both succeeded with no warnings.
- **Full suite:** 768 executed, 14 skipped, 0 failed.
- **Coordinator re-run:** the main window, character, welcome, and file mode
  tests ran 93, skipped 3, and failed 0.
- **Existing tests:** they now pass isolated preferences in their
  constructors. Two character tests allow the intended one-turn delay before
  hiding, and they still check the hide.

**Known gaps.** Phase 7 owns these:

- The old accessory cards inside the new frame still use glass. With Reduce
  Transparency on, they are unreadable in Paper.
- The thinking state isn't visible once a chat has messages.

**Not yet checked by a person in the signed app:**

- VoiceOver;
- Increase Contrast;
- keyboard-navigation focus rings;
- the live fall and dock animations;
- Escape and `⌘K` with a physical keyboard.
