# Phase 9: Icons

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debriefs at the end of
the phase 3 to 8 briefs in this folder, especially phase 3's `EnigmaMark`.

## Goal

Every icon the app draws itself fits the new design. The app also gets a
real app icon. Today it has none, so Finder and the privacy panes in System
Settings show a generic one.

## What exists today

In `AI-Spotlight/Resources/Assets.xcassets`:

| Asset | Use |
| --- | --- |
| `SpotlightLogo` | The old leaf logo. A template in the menu bar (`MenuBarController`, 18 pt) and in the old sidebar, empty state, and Settings. |
| `WebSearch`, `ScreenCapture`, `MessagesTool`, `TemplateAttachment` | Tool icons. Template SVGs, shown in the composer and in native menus through `ToolMenuLabel.menuImage` (16 pt). |
| `FileMode` | A tool icon, kept as a PNG. |
| `ForestBackdrop`, `LeafThinking`, `EnigmaHello`, `EnigmaCoalescence` | Old-UI art. Phase 10 deletes these. Don't redraw them. |

The project has no `AppIcon` set, and `ASSETCATALOG_COMPILER_APPICON_NAME`
isn't set. There are also about 30 SF Symbols across the views.

## Design

The app icon is the character itself. See "App icon and mark" in the spec.
This was the owner's decision, and it isn't open to reinterpretation. Don't
use an abstract logo, a letter, or a different creature.

- **App mark.** Base it on the character: the lime body with its porthole,
  the antenna, and the thick `characterInk` outline. Draw it as a still
  pose, using `EnigmaMark` or the character model's rest shape, so the mark
  and the character are the same creature. In the color version the body is
  `characterBody`.
- **Menu bar icon.** A monochrome template version of the mark, which must
  read at 18 pt:
  - the outline and porthole, the antenna, and no legs if they turn to noise;
  - a clean silhouette in both menu bar appearances.
- **Tool icons.** One family, in the same line style as the mockups' icons
  (the mockups use Tabler icons as the stand-in):
  - a 24-unit grid;
  - one stroke weight, about 1.75;
  - rounded caps and joins;
  - no fills except small dots.

  They must sit well next to the SF Symbols the new UI uses, at
  `.regular` weight. Redraw the four tool icons and `FileMode` as template
  vector assets (SVG or PDF, with "Preserve Vector Data"). Replace the
  `FileMode` PNG.
- **SF Symbols.** Go through every SF Symbol in the new-UI views:
  - Use one weight and consistent sizes per context.
  - Swap any symbol that clashes with the flat, line-drawn style, such as
    filled glyphs next to outline glyphs, or a different metaphor for the
    same action.
  - Keep VoiceOver labels unchanged.
- **App icon.**
  - A macOS app icon: a rounded square in the Paper `background`, with the
    colored mark centered, drawn flat. No gloss, gradient, or glow.
  - Provide the full macOS set (16 to 1024 pt at 1x and 2x) in an `AppIcon`
    set, and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for the app
    target in both configurations.
  - Generate the PNGs from the same Swift drawing code, for example with a
    snapshot-style test or a small script that uses the app's types, rather
    than by hand. Commit the generator or document how to rerun it.
- **Old artwork.** Replace `SpotlightLogo`'s artwork with the new mark under
  the same asset name, so the old UI and the menu bar pick it up without code
  churn. If you rename it, update every use.

## Build

1. Draw the mark, menu bar, tool, and app icon assets as described above.
2. Update `MenuBarController`, `ToolMenuLabel`, and the new-UI views to use
   them. The old UI can show the new artwork too, since it's going away in
   phase 10, but it must not break.
3. Tests:
   - every asset name the code references exists in the catalog and loads as
     an image;
   - template assets are templates;
   - the app icon set is complete;
   - the built app's `Info.plist` or bundle has an icon, by extending
     `AppBundleTests` if it fits.
4. Screenshots:
   - a sheet of every icon at 16, 18, 24, and 32 pt, on Paper and Ink;
   - the app icon at 16, 32, 128, and 512;
   - the menu bar icon over a light and a dark bar.

   Save them to `docs/design/ui-revamp/screenshots/phase-9/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- The menu bar, the composer's tool icons, the native tool menus, the
  sidebar, and Settings all show the new artwork.
- The built `Enigma.app` has an app icon.
- No SF Symbol in the new UI clashes with the line style.

## Debrief

**Built.** Every app-identity image is drawn from the character's own Swift
code. `EnigmaAppIcon` composes them from `EnigmaCharacterModel.stillFrame`
and `EnigmaCharacterRenderer`.

- **App icon.** The filled still pose, flat and centered on a Paper rounded
  square with a `border`-token edge, in a new `AppIcon` set (16–512 pt at 1x
  and 2x). `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set for the app
  target.
- **Menu bar.** `SpotlightLogo` is now an 18 pt vector PDF template of the
  outline pose, with no legs and a 1.4 pt line, served by
  `MenuBarController.statusImage()`.
- **Sidebar mark.** It is `EnigmaMark`, which uses the same pose.
- **Tool icons.** `WebSearch`, `ScreenCapture`, `MessagesTool`,
  `TemplateAttachment`, and `FileMode` are redrawn as one original line family
  (24 grid, 1.75 stroke, round caps and joins). The `FileMode` PNG became an
  SVG.
- **Symbols.** The new UI's SF Symbols use shared `EnigmaTypography` symbol
  tokens, always at regular weight.
- **Credits.** `ThirdPartyNotices.txt` drops the Noun Project credits,
  because none of that art ships any more.
- **Generator.** The test generator, rerun with
  `scripts/generate-app-icons.sh`, produces byte-identical files on every run.
  `EnigmaIconTests` fails if the committed icons drift from the drawing.

Screenshots are in `screenshots/phase-9/`.

**Decisions.**

- The menu bar uses the line style, because it matches the system glyphs and
  keeps the porthole open.
- At 16 and 32 pt the character fills more of the tile and draws a heavier
  line.
- `stop.fill` stays filled inside the solid Send button.
- The 9 pt chevrons stay semibold.

**Review.** There were no blockers. The reviewer confirmed that the owner's
decision is met, that the icon set and build setting are correct, that the
old UI isn't broken, and that removing the credits is correct. These fixes
were made:

- The menu bar PDF had a random `/ID`. It is now zeroed, so a rerun leaves the
  file unchanged, and a test checks it.
- The drift check is tightened to 0.2% of pixels.
- The committed icons were regenerated to match the generator exactly.
- The generator now clears stale `icon_*.png` files.

**Verification.**

- **Build and analyze:** both succeeded.
- **Full suite:** 833 executed, 18 skipped, 0 failed. This run came before the
  final test-only fix, which added one test.
- **Coordinator re-run:** the icon, bundle, and main window tests ran 45,
  skipped 3, and failed 0.
- **Built app:** it has `CFBundleIconName = AppIcon`, and `AppIcon` is in
  `Assets.car`.

**Not yet checked by a person in the signed app:**

- the real menu bar;
- the Dock, Finder, and System Settings panes;
- the dark and tinted icon styles that macOS generates.

On macOS 26 the system adds its own glass rim and shadow to the icon. A fully
flat look would need an Icon Composer `.icon` file. That is the owner's call.
