# Phase 5: Settings

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debriefs at the end of
[phase-3-character.md](phase-3-character.md) and
[phase-4-welcome.md](phase-4-welcome.md). They describe the theme
environment, the shared controls in `EnigmaControls.swift`, the snapshot
helper, and the new-UI model and connection views that phase 4 built for
reuse here.

## Goal

With "Use new UI" on, the Settings window uses the new design and gains the
System / Paper / Ink appearance choice. With it off, nothing changes.

## What exists today

- **The window.** `SettingsView` in `AI-Spotlight/App/AppShellView.swift` is
  the Settings window: an 820 × 680 view with a side navigation and five
  destinations.

  | Destination | Contents |
  | --- | --- |
  | General | permissions, Replay Welcome Setup, New chats, Location, and Messages |
  | Local Models | `LocalModelManagerSection` |
  | Discover | `LocalModelDiscoveryView`, with the Hugging Face rows, download sheet, and progress |
  | Cloud & Search | `cloudForm`: ChatGPT and Claude subscriptions, `ScreenSettingsSection`, `WebSearchSettingsSection`, advanced provider, model, thinking and effort settings, API keys in the Keychain, and connection tests |
  | Selection Context | permissions and automatic replace |

- **Where the sections live:**
  - `MacPermissionControls` and `ScreenSettingsSection`:
    `AI-Spotlight/Screen/ScreenSettings.swift`.
  - `WebSearchSettingsSection`:
    `AI-Spotlight/Search/WebSearchControls.swift`.
  - `MessagesSettingsSection`:
    `AI-Spotlight/Messages/MessagesControls.swift`.
  - The model views: `AI-Spotlight/LocalInference/`.
- **The window controller.** `SettingsWindowController` in
  `AI-Spotlight/App/AI_SpotlightApp.swift` hosts the view:
  - It forces `darkAqua` and the forest background.
  - It opens a destination through the `.settingsDestinationRequested`
    notification.
- **The welcome.** Its "More Connection Settings" sheet still opens the old
  `SettingsView`. Look for the `// Phase 5:` note.
- **Tests.** `ScreenViewTests`, `LocalModelSelectionTests` (which renders
  Settings), `LocalModelDiscoveryTests`, `HuggingFaceModelDownloadsTests`, and
  `WebSearchTests` host these views. They must keep passing unchanged for the
  old UI.

## Design

The mockup is the Settings window in
[../panel-and-settings.html](../panel-and-settings.html). Its pages are built
by the script, so read it.

- **Navigation.** Plain text in the `sidebar` color, with a dot and darker
  text on the selected section. No capsules and no icons, unless the mockup
  shows them.
- **Header.** Each page has a semibold heading and one secondary line.
- **Rows.** Hairline-divided rows, each with:
  - a title;
  - a secondary explanation;
  - a control on the trailing side.
- **Controls.**
  - Switches with a spring knob (`EnigmaMotion.switchKnob`), never pill
    segments.
  - Appearance as a System / Paper / Ink text control.
  - Status as monospace lines, such as `● connected · 12 models`.
- **Pickers.** Opaque menus (`menu` token) that open from their trigger with
  `EnigmaMotion.menu`.
- **API key fields.** The new text field style, secure.
- **Buttons.** At most one `accent` button per page. Everything else is
  outlined or a text button.

Keep every setting, every explanation's facts, every permission control, and
every error message. Tighten the copy only where the meaning stays the same.

## Build

1. **Appearance setting.** Add a saved appearance preference: an
   `ObservableObject` backed by UserDefaults, default `.system`, like
   `NewUIPreference`.
   - Every new-UI root applies it through the phase 3 theme modifier: the
     welcome, Settings, and later the panel and main window.
   - With the flag on, the Settings window's `NSWindow` follows it too:
     `appearance` is `aqua`, `darkAqua`, or `nil` for System, and
     `backgroundColor` is the palette's `background`.
   - Changes apply live, without reopening the window.
   - Tests cover the default, saving, and the mapping to color scheme and
     window appearance.
2. **Shared controls.** Add to `EnigmaControls.swift`:
   - a switch;
   - the text segmented control;
   - an opaque menu or picker, built so phase 6's model picker can reuse it;
   - a secure field variant;
   - a settings row and section header, if phase 4's row doesn't cover
     them.

   Each has previews and supports keyboard focus, VoiceOver (a switch reads as
   a switch, with its value), Reduce Motion, and Increase Contrast.
3. **`EnigmaSettingsView`** (new file, or a few files by destination). It
   covers all five destinations with the same behavior as today:
   - It keeps the `SettingsDestination` enum and the
     `.settingsDestinationRequested` deep links.
   - It reuses phase 4's model and connection views.
   - Create new-UI versions of the sections that live in other folders, next
     to the originals: permissions, screen, web search, Messages, the local
     model manager, discovery, and the download sheet and rows.
   - Logic that's currently inline in a view and needed by both versions
     (key saving, connection tests, picker contents) moves into a small shared
     type or function, so the versions can't drift. Add tests for it.
4. **Flag wiring.**
   - `SettingsWindowController` and the `Settings` scene choose the old or
     new view from `NewUIPreference.shared.isEnabled`, and switch live.
   - The welcome's "More Connection Settings" sheet uses the new Settings
     when the flag is on.
   - Add the Appearance control on the General page.
5. **Tests.**
   - New logic and the shared logic you extracted.
   - The new Settings renders every destination at 820 × 680 in Paper and
     Ink without clipping.
   - Deep links select the right destination.
   - Window appearance follows the setting.
   - The flag swaps the view while the app runs.
   - Permission and consent failure paths, such as a missing key, a failed
     test, or a denied permission, show the same messages as before.
6. **Screenshots.** Paper and Ink of each destination, plus one open menu and
   one sheet. Save them to `docs/design/ui-revamp/screenshots/phase-5/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- With the flag off, Settings is unchanged, and its existing tests pass
  unchanged.
- With the flag on, every setting can be changed with the same effect as in
  the old view, including Keychain saves and removals, connection tests,
  permission buttons, model installs and deletes, and discovery downloads.
- Appearance switches Paper and Ink live in Settings and in the new welcome.

## Debrief

**Built.** With "Use new UI" on, the Settings window is
`EnigmaSettingsView`:

- plain-text navigation with the mockup's icons and a dot on the selected
  page;
- a semibold heading on each page;
- hairline rows;
- switches, the System / Paper / Ink control, opaque menus, secure key fields,
  and monospace status lines.

All five destinations and the `.settingsDestinationRequested` deep links are
kept. `SettingsWindowContent` chooses the old or new view, and the window
switches live.

`EnigmaAppearancePreference` (key `enigma.appearance`, default System) drives
the new Settings window and its `NSWindow` appearance and background, the new
welcome, the tour, and the model sheet. All of them update live. The welcome's
connection settings sheet (`EnigmaConnectionSettingsSheet`) now opens the new
Settings, with "Back to setup" in its own bar.

New-UI versions of the Screen, Web Search, Messages, Local models, Discover,
download sheet, and file-tools sections sit next to their originals. Logic
that both versions need now lives in shared types, and the old views use them
too:

- `CloudSettingsForm`;
- `LocalModelSettingsLogic`;
- `WebSearchSettings` helpers;
- `MessagesPermissionStatus`;
- `LocalFileToolsInstallation`.

`EnigmaControls.swift` gains:

- `EnigmaSwitch`;
- `EnigmaSegmentedControl`;
- `EnigmaMenu`, with a host overlay (`.enigmaMenuHost()`), keyboard control,
  focus returned to the trigger, and live anchor and row updates;
- `EnigmaDisclosure`, `EnigmaNote`, and `EnigmaProgressBar`.

Screenshots are in `screenshots/phase-5/`, including full-length pages.

**Decisions.**

- **Navigation.** The order is kept, and Settings opens on General.
- **Subtitles.** Mockup lines the app can't back up are replaced with
  accurate ones.
- **API key errors.** Each provider's error shows under its own row.
- **Return.** Return in any key field saves the key.
- **Unsaved keys.** A typed but unsaved key clears when you change pages.
  This is deliberate, because it's safer.
- **Switch knob.** When the switch is on, the knob is `onAccent`, so it stays
  visible on lime.
- **Unselected segments.** They use `textSecondary` so they stay readable.
- **Accent buttons.** Only Discover's featured model and the download sheet
  use one.
- **Menu triggers.** They are always a Tab stop, so focus can return to them.
- **Window frame.** The window keeps its old frame. The content runs under a
  transparent title bar, and the controller locks the appearance it applies.

**Review.** There were no blockers. The reviewer confirmed line by line that
the refactored old views behave exactly as before. These fixes were made, with
tests:

- Menus give focus back to the trigger on every way of closing.
- Two existing `AppCommandTests` and the welcome tests no longer read the
  installed app's real flag or appearance setting.
- An open menu follows its trigger and its rows.
- The Settings root no longer re-renders on every chat update.
- Each API key field has its own VoiceOver label.
- The unsupported-model reason is drawn in `textSecondary`.
- The Discover lists are lazy again.
- The Local models actions and the download button have hosted tests.
- The full-length pages have screenshots.
- "Back to setup" no longer covers content.

**Verification.**

- **Build and analyze:** both succeeded.
- **Full suite:** 737 executed, 13 skipped, 0 failed. None of the known
  environmental focus timeouts occurred in this run.
- **Coordinator re-run:** the settings, controls, and welcome tests ran 71,
  skipped 2, and failed 0. The only changes to existing tests are the
  isolated preferences in their constructors. No assertion changed.

**Not yet checked by a person in the signed app:**

- VoiceOver;
- Increase Contrast;
- real Keychain prompts;
- real downloads and folder picking;
- the traffic lights over the navigation.
