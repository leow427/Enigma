# UI Style Specification

Enigma's interface uses two themes, Paper and Ink, on opaque surfaces, with
one flat, hand-drawn character for personality. This file is the reference
for every screen. The full design record, with the reasoning and the
interactive mockups, is in
[docs/design/ui-revamp/README.md](ui-revamp/README.md).

## Direction

- **Warm and plain, not glossy.** Every surface is opaque. There is no
  backdrop blur, material, gradient, glow, or shadow. Menus and the model
  picker are solid, so text is always readable.
- **One character.** A small lime creature is the only decoration. Everything
  around it stays quiet.
- **Keyboard first.** Commands, metadata, shortcuts, and hints are set in
  monospace, like command lines.
- **No boxes around lists.** History rows and Settings navigation are plain
  text. The selected item has a small dot and darker text, not a filled
  capsule.

## Themes and color tokens

Appearance is a System / Paper / Ink choice in Settings → General (key
`enigma.appearance`, default System). System follows the Mac. Every window
and sheet applies it at its root with `.enigmaTheme(_:)`, which sets the
palette in the environment and the matching color scheme.

Colors come only from the palette in the environment
(`@Environment(\.enigmaPalette)`), defined in
`Enigma/App/EnigmaTheme.swift`. Translucent tokens are the base color at the
given opacity.

| Token | Paper | Ink | Use |
| --- | --- | --- | --- |
| `background` | `#F3EEE4` | `#141512` | Window and chat canvas |
| `sidebar` | `#E8E1D3` | `#0E0F0D` | Sidebar and Settings navigation |
| `surface` | `#FCFAF5` | `#1E1F1B` | Composer, compact panel, cards |
| `menu` | `#FFFFFF` | `#282923` | Menus and the model picker, always opaque |
| `userBubble` | `#E6DFD0` | `#262721` | The person's own messages |
| `textPrimary` | `#211E19` | `#EFE8D8` | Body text |
| `textSecondary` | `#5B554A` | `#ABA496` | Supporting text |
| `textTertiary` | `#827B6D` | `#827D70` | Timestamps, placeholders, hints |
| `hairline` | `#24201A` at 10% | `#EDE6D6` at 8% | Row dividers |
| `border` | `#24201A` at 18% | `#EDE6D6` at 15% | Window, card, and menu edges |
| `hover` | `#24201A` at 5% | `#EDE6D6` at 5% | Hover fill |
| `accent` | `#3F5A12` | `#CDEB78` | Send, primary buttons, switches |
| `onAccent` | `#F5F8EA` | `#1A2306` | Text and icons on `accent` |
| `accentText` | `#4A6A14` | `#CDEB78` | Command names, selection dots, links, the What's new? label |
| `characterBody` | `#C3DE5E` | `#C3DE5E` | Character fill |
| `characterInk` | `#211E19` | `#D9D1BF` | Character outline, legs, antenna |
| `warning` | `#E0A33B` | `#E0A33B` | The character's error state |

Rules:

- Text people must read uses `textSecondary` or darker (4.5:1). `textTertiary`
  (3:1) is only for text people don't need to read, like hints and
  placeholders. `EnigmaThemeTests` checks both on every surface.
- Use at most one `accent`-filled control per view: Send in the composer, the
  primary button on a step or card. Every other button is outlined or text.
- Never hard-code a color, and never use a material, `glassEffect`, blur,
  gradient, or glow.

## Typography

Fonts come from `EnigmaTypography`.

| Role | Font | Notes |
| --- | --- | --- |
| Chrome, labels, buttons, headings | System (SF Pro), `EnigmaTypography.ui` | Headings are semibold with slightly negative tracking. No italics. |
| Assistant replies only | New York, `EnigmaTypography.reply` | About 15 pt with roomy line spacing. The serif marks who is speaking. The one exception is the What's new? sheet, whose release notes use the reply renderer, `ChatMarkdownView`. |
| Commands, metadata, hints, stats | SF Mono, `EnigmaTypography.mono` | 11 to 12 pt, in `textTertiary` or `accentText`. |

SF Symbols use the shared symbol tokens (`EnigmaTypography.symbol` and its
named sizes), always at regular weight and in outline style. The one filled
glyph is Stop, on the solid Send button.

## Layout

- **Window.** An opaque `background` with 12 pt corners and a `border` edge.
  `⌃⌘S` shows or hides the sidebar.
- **Sidebar.** The app mark and "Enigma", New chat (`⌘N`), then "Recents" as
  plain rows with a dot on the open chat, then Help, Settings, and, in Debug
  builds, Developer Tools. When it's hidden, a slim bar keeps Show chat
  history, New chat, Help, and Settings in reach.
- **Top-right slot.** The right end of that bar (`EnigmaTopBar`) is the
  window's top-right slot, for things that come and go, like **What's new?**
  after an update: an outlined button with an `accentText` label
  (`EnigmaButtonKind.notice`), since the palette has no blue. While the
  sidebar is shown, the bar appears only when the slot has something in it.
  When it's opened, the button fades out; with the sidebar shown the whole
  bar goes and the page moves up into its place. Under Reduce Motion both
  happen at once.
- **Main page.** The character centered, a time-of-day greeting, a monospace
  status line built from the real route state, the Auto / Local / Cloud text
  control, the composer, and the slash commands as monospace example lines.
  On short windows the examples drop first, then the character.
- **Composer.** One rounded opaque `surface` box with the message field,
  Attach and `/` on the left, a monospace `● local` or `○ cloud` indicator,
  chips for any commands recognized from the wording, the mode and model
  menu, and the `accent` Send button, which becomes Stop while a reply runs.
  Typing goes on during a reply; once the field has text, an outlined icon
  Send beside Stop queues the message, so Stop stays the one `accent` control.
  After the first send it springs to the bottom. `⌘K` opens the mode and
  model menu.
- **Chat.** The person's messages are right-aligned `userBubble` bubbles.
  Replies are serif text with the character in a 30 pt slot to their left and
  a monospace meta line under them: `model · where it ran · time`, with a
  dimmed copy icon at its right that brightens when the pointer is over the
  reply. A code block has a header with its language and a Copy icon. Earlier
  replies keep the outline mark where the character stood. Request activity
  is a monospace line that opens to show the steps and sources. Queued
  messages wait under the reply as unfilled bubbles with a dashed `border`
  outline (1 pt, 4 on 3 off, `EnigmaEdgeStroke(isDashed:)`), an x icon button
  to their left and a monospace "Send now" text button with a clock under
  them. Dashed means not sent yet: it's the only dashed line in the app, and
  a sent message is the usual solid `userBubble`.
- **Cards.** Notices, consent, approvals, attachments, and errors in a chat
  are opaque `surface` cards with a `border` edge and one accent button each.
- **Compact panel.** An optional `› selected "…"` line, the input row with
  the character on the left, and a monospace hint row whose every hint is a
  real shortcut. Sending the first question moves the chat into the window,
  which travels from the panel to its normal frame.
- **Settings.** Plain-text navigation with a dot on the selected page, a
  semibold heading, hairline-divided rows, switches, and opaque menus.
  Appearance is a System / Paper / Ink text control, never pill segments.
- **Welcome.** The character large on the first step, then a pinned header
  with the character in a 40 pt slot, a monospace `2/4` counter, hairline
  rows, and one primary button. A six-stop tour over the main window follows.

Write shortcuts as the app does: `⌥⌃` opens Enigma, a double-tap of `⌥` asks
about a selection (people can change the key or turn it off), `⌃⌘S` toggles
the sidebar, and `⌘K` is the mode palette. Copy is plain, short sentences.

## Shared controls

Buttons, icon buttons, switches, segmented text controls, menus, rows, text
fields, keycaps, hints, status lines, notes, disclosures, progress bars, and
card chrome live in `Enigma/App/EnigmaControls.swift`. Extend them
rather than making a local copy. Every control has a VoiceOver label, and
every clickable row is reachable with Tab and shows an `accent` focus ring.

## Motion

Every animation is a spring that starts from the current on-screen value, so
it can be interrupted. The values are in `EnigmaMotion`.

| Motion | `EnigmaMotion` | Response | Damping |
| --- | --- | --- | --- |
| Screen changes: welcome out, empty state to chat, compact panel into the window | `screenChange` | 0.5 | 1.0 |
| Menus opening from their trigger | `menu` | 0.28 | 1.0 |
| Settings page change | `pageChange` | 0.3 | 1.0 |
| Composer moving to the bottom | `composerDock` | 0.5 | 0.86 |
| New rows and messages arriving | `rowEnter` | 0.42 | 0.9 |
| Switch knob | `switchKnob` | 0.32 | 0.62 |
| Character following its slot | `characterFollow` | 0.5 | 0.8 |
| Character squash and stretch | `characterSquash` | 0.34 | 0.32 |

Screen changes, menus, and page changes never overshoot. Things that travel
into place settle with a barely visible overshoot. A real bounce is only for
physical moments: a switch flipping, or the character landing, being thrown,
or being poked.

## The character

A flat 2D figure: a lime body with a hole through the middle, an antenna with
a ball, three thin legs with dot feet, and a contact shadow. It has no face.
Its outline is thick and redrawn with a slight jitter 12 times a second.

| State | Behavior |
| --- | --- |
| Idle | A slow turn and gentle bob. Leans toward the cursor. |
| Listening | Turns toward the composer and nudges with each keystroke. |
| Thinking | Morphs between lobe counts while spinning; the hole splits into three. |
| Answering | One ripple and a small bounce per streamed update. |
| Error | Turns `warning` amber, sags, and droops its antenna. |

Screens hold an `EnigmaCharacterController`, mark where it sits with
`.enigmaCharacterSlot(id:size:)`, and the window root draws it once with
`.enigmaCharacterStage(_:)`. It falls to a lower slot and glides to a higher
one. Open menus and the welcome tour draw above the character, and take the
clicks on their rows and buttons: the window has one `.enigmaMenuHost()`,
outside the stage. The slash-command list opens in place, under the stage, so
it marks itself with `.enigmaCharacterCover(cornerRadius:)`; the stage doesn't
draw the character or let it be grabbed where the list covers it. Because the
menus and the tour sit outside the stage, the window passes
`tracksPointer: false` to the stage and applies `.enigmaCharacterPointer(_:)`
outside them, so the character still follows the pointer while one is open.

The app icon, the menu bar template (`EnigmaMenuBarMark`), and the sidebar
mark (`EnigmaMark`) are all drawn from the character's still pose by its own
Swift code. Regenerate the committed icons with `scripts/generate-app-icons.sh`.

## Accessibility

- **Reduce Motion:** the character stays still and moves between slots
  instantly. Screens cross-fade instead of sliding.
- **Reduce Transparency:** nothing changes, because every surface is opaque.
- **Increase Contrast:** hairlines and borders use the `border` token at
  double opacity (`EnigmaEdge`).
- **VoiceOver:** the character is one element labeled "Enigma" that announces
  its state. It is never a control.
- **Keyboard:** every clickable row is reachable with Tab, with an `accent`
  focus ring.

## Screenshots

`EnigmaSnapshot` in the test target renders a view in Paper and Ink when
`ENIGMA_SNAPSHOT_DIR` is set (pass it to the test host as
`TEST_RUNNER_ENIGMA_SNAPSHOT_DIR`). The current set of every screen is in
[docs/design/ui-revamp/screenshots/phase-10/](ui-revamp/screenshots/phase-10/).
