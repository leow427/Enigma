# UI Revamp: Paper, Ink, and the Character

This is the spec and rollout plan for Enigma's new interface. The approved
mockups are interactive HTML pages in this folder:

- [main-window.html](main-window.html): the welcome screen, the main page, the
  chat, and the character dropping from the main page into the conversation.
- [panel-and-settings.html](panel-and-settings.html): the compact panel over
  another app, and the Settings window.

Open either file in a browser. The controls under each window switch themes
and force character states. The mockups load their fonts and icons from the
web. Their models, sizes, and speeds are placeholders.

## Direction

The new look replaces the liquid-glass forest style. Its goals:

- **Warm and plain, not glossy.** Surfaces are opaque. There is no backdrop
  blur, no gradient, and no glow. Menus and the model picker are solid so
  text is always readable.
- **One character, flat and hand-drawn.** A small lime creature gives the app
  its personality. Everything around it stays quiet.
- **Keyboard-first details.** Commands, metadata, and hints are set in
  monospace like command lines, so the app reads as a tool rather than a
  generic chatbot.
- **No boxes around lists.** History rows and Settings navigation are plain
  text. The selected item is marked by a small dot and darker text, not a
  filled capsule.

## Color tokens

Two palettes, plus a System mode that follows the Mac's appearance. The code
names are `EnigmaPalette.paper` and `EnigmaPalette.ink`
(`AI-Spotlight/App/EnigmaTheme.swift`). Translucent tokens are the base hex at
the given opacity.

| Token | Paper | Ink | Use |
| --- | --- | --- | --- |
| `background` | `#F3EEE4` | `#141512` | Window and chat canvas |
| `sidebar` | `#E8E1D3` | `#0E0F0D` | Sidebar and Settings navigation |
| `surface` | `#FCFAF5` | `#1E1F1B` | Composer, compact panel |
| `menu` | `#FFFFFF` | `#282923` | Model picker and other menus, always opaque |
| `userBubble` | `#E6DFD0` | `#262721` | The user's own messages |
| `textPrimary` | `#211E19` | `#EFE8D8` | Body text |
| `textSecondary` | `#5B554A` | `#ABA496` | Supporting text |
| `textTertiary` | `#827B6D` | `#827D70` | Timestamps, placeholders, hints |
| `hairline` | `#24201A` at 10% | `#EDE6D6` at 8% | Row dividers |
| `border` | `#24201A` at 18% | `#EDE6D6` at 15% | Window and menu edges |
| `hover` | `#24201A` at 5% | `#EDE6D6` at 5% | Hover fill |
| `accent` | `#3F5A12` | `#CDEB78` | Send button, primary buttons, switches |
| `onAccent` | `#F5F8EA` | `#1A2306` | Text and icons on `accent` |
| `accentText` | `#4A6A14` | `#CDEB78` | Command names, selection dots, links |
| `characterBody` | `#C3DE5E` | `#CDEB78` | Character fill |
| `characterInk` | `#211E19` | `#EFE8D8` | Character outline, legs, antenna |
| `warning` | `#E0A33B` | `#E0A33B` | The character's error state |

`textTertiary` reaches 3:1 on every surface, which is enough for text a
person doesn't need to read, like timestamps, shortcut hints, and
placeholders. Anything people must read uses `textSecondary` or darker, which
reach 4.5:1. `EnigmaThemeTests` checks both rules on every surface. The
mockups use these final tertiary values, a touch darker in Paper and lighter
in Ink than the first drafts.

Use at most one `accent`-filled control per view. Every other button is a
plain outlined or text button.

## Typography

| Role | Font | Notes |
| --- | --- | --- |
| Chrome, labels, buttons, headings | System (SF Pro) | Headings are semibold with slightly negative tracking. No italics. |
| Assistant replies only | New York (`.serif` design) | About 15 pt with roomy line spacing. The serif marks who is speaking. |
| Commands, metadata, hints, stats | SF Mono (`.monospaced` design) | 11 to 12 pt, in `textTertiary` or `accentText`. |

The mockups use Source Serif 4 and JetBrains Mono as web stand-ins. The app
uses the built-in New York and SF Mono, so there are no fonts to bundle or
license.

## Layout notes

- **Sidebar:** the app mark and "Enigma" at the top, then New chat (`⌘N`) and
  Search, then "Recents" as plain rows. Cloud chats show a small cloud glyph.
  Settings sits at the bottom. Double-tap Control still toggles the sidebar.
- **Main page:** the character centered, a short time-of-day greeting, a
  monospace status line (`qwen3-8b is loaded · on this mac`), the composer,
  then the slash commands as monospace example lines, for example
  `› /translate "Bạn khỏe không?" ⟶ "How are you?"`.
- **Chat:** after the first send, the composer springs to the bottom. User
  messages are right-aligned bubbles. Replies are serif text, with the
  character in a 30 pt slot to their left and a monospace line under them:
  `model · where it ran · time`. Earlier replies keep a small outline glyph
  where the character stood.
- **Composer:** one rounded opaque box, with Attach and `/` on the left, a
  monospace `● local` or `○ cloud` indicator, the model picker, and an accent
  send button.
- **Compact panel:** an optional `› selected "…"` line, the input row with the
  character on the left, an answer area that springs open, and a monospace
  hint row.
- **Settings:** plain-text navigation with a dot on the selected section,
  hairline-divided rows, and switches, never pill segments. Appearance is a
  System / Paper / Ink text control.
- **Shortcuts in copy:** `⌥⌃` (Option and Control together) opens Enigma. By
  default, a double-tap of `⌥` asks about a selection (people can change the
  key or turn it off). `⌘K` is the mode palette.

## Motion

Every animation is a spring that starts from the current on-screen value, so
any motion can be interrupted. The mockups' values map directly to SwiftUI's
`.spring(response:dampingFraction:)`, and live in `EnigmaMotion`.

| Motion | `EnigmaMotion` | Response | Damping |
| --- | --- | --- | --- |
| Screen changes: welcome out, empty state to chat | `screenChange` | 0.5 | 1.0 |
| Menus opening from their trigger | `menu` | 0.28 | 1.0 |
| Settings page change | `pageChange` | 0.3 | 1.0 |
| Composer moving to the bottom | `composerDock` | 0.5 | 0.86 |
| New rows and messages arriving | `rowEnter` | 0.42 | 0.9 |
| Compact panel's answer area opening | `panelAnswer` | 0.45 | 0.9 |
| Switch knob | `switchKnob` | 0.32 | 0.62 |
| Character following its slot | `characterFollow` | 0.5 | 0.8 |
| Character squash and stretch | `characterSquash` | 0.34 | 0.32 |

Screen changes, menus, and page changes never overshoot. Things that travel
into place (the composer, new rows, the panel's answer area) settle with a
barely visible overshoot, at damping 0.86 to 0.9. A real bounce, below 0.85,
is only for physical moments: a switch flipping, or the character landing,
being thrown, or being poked.

## The character

It is a flat 2D figure: a lime body with a hole through the middle, an
antenna with a ball on top, three thin legs with dot feet, and a contact
shadow. It has no face. Its outline is thick and redrawn with a slight random
jitter 12 times a second, like hand-drawn animation.

**Shape.** The outline is a closed curve whose radius varies by angle: a
lobed base shape, plus a bump toward whatever it is paying attention to,
traveling ripples, and the jitter. Its resting shape has 5 soft lobes.

**States**

| State | Behavior |
| --- | --- |
| Idle | Slow turn and a gentle bob, with the feet planted. Leans and reaches toward the cursor. |
| Listening (typing) | Turns toward the composer. Each keystroke makes a bump toward it and nudges the antenna. |
| Thinking | Morphs between 3, 4, 6, and 7 lobes while spinning. The hole splits into three orbiting holes, and the feet tap in turn. |
| Answering | One ripple and a small bounce per streamed token. |
| Error | Turns `warning` amber, sags, droops its antenna, and its outline gets scratchier. |

**Events**

- `key(towards:)`: a typing nudge toward a point.
- `token()`: a ripple for each streamed token.
- `poke()`: a click, which wobbles it.
- Drag and throw: it follows the pointer from the point where it was
  grabbed, then springs back carrying the release velocity.
- `fall(to:)`: move to a new slot. If the slot is below, it crouches, hops,
  and falls with gravity (2600 pt/s²), stretching in the air with its legs
  dangling. On landing it squashes, dust puffs pop out, and short impact lines
  flash beside it. If the slot is above, it glides there on a spring.

**Implementation.** Draw it natively with SwiftUI `Canvas` inside a
`TimelineView(.animation)`, from the same math as the `Glyph` function in
`main-window.html`. Screens mark where it sits with anchor preferences. One
overlay at the window root draws it and runs the fall between slots. This
replaces `EnigmaCoalescenceView`, the web-view animation that looked low
resolution. Pause the timeline when the window is hidden or occluded.

## Accessibility

- **Reduce Motion:** the character stays still in its slot and moves between
  slots instantly. States still read through color and the hole. Screens
  cross-fade instead of sliding.
- **Reduce Transparency:** nothing changes, because every surface is already
  opaque.
- **Increase Contrast:** hairlines and borders use the `border` token at
  double opacity.
- **VoiceOver:** the character is one element labeled "Enigma" that announces
  its state ("Thinking", "Answering"). It is never a control.
- **Keyboard:** every clickable row is reachable with Tab and has a visible
  focus ring in `accent`.

## Rollout

The new UI is built next to the current one, behind the **Use new UI**
setting in Developer Tools. It stays off by default until every screen
reaches parity, so `main` always ships a working app.

1. **Foundations.** Save the mockups and this spec, add `EnigmaTheme`
   tokens with tests, and add the off-by-default flag. Nothing visible
   changes.
2. **Separate state from views.** Move chat, composer, and history state out
   of `AppShellView.swift` into small models, without changing visuals. Add
   tests for those models. This is the safety net for every later phase.
3. **Character component.** Build `EnigmaCharacter` alone, with previews for
   each state, Reduce Motion support, and a CPU check.
4. **Welcome screen,** behind the flag.
5. **Settings,** behind the flag.
6. **Compact panel,** behind the flag. Test it with the signed build, because
   it touches the global shortcut and selection permissions.
7. **Main chat window,** behind the flag.
8. **Switch over.** Turn the flag on by default, then remove the old views,
   the liquid-glass settings, and `docs/Liquid-Glass-UI.md` once the new UI
   has run as the default for a while.

Each phase is its own focused PR. It passes `scripts/verify-xcode.sh build`,
`test`, and `analyze`, and includes Paper and Ink screenshots of whatever it
changes.
