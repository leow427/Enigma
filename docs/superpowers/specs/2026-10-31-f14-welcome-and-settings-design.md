# F14: Welcome setup, hands-on tour, and Settings

Status: design, approved through the in-app spike (branch `spike/f14-welcome`,
last commit 927c2d3). This spec describes what the owner approved there and
how it lands on `main` properly. The spike is the reference for every look and
behaviour below; where this spec and the spike differ, this spec wins.

## Goal

Enigma's welcome and Settings predate most of what it does now. F14 replaces
them:

- a setup that is fun and short, with the character following the user;
- a hands-on tour in the real main window that shows every feature by
  doing it, with scripted replies so nothing real is sent;
- a Settings window that is easy to find things in: grouped pages, search,
  short rows, one Permissions page, and shortcuts the user can change.

Success: a new user finishes setup and the tour knowing how to summon
Enigma, ask about a selection, use files and Messages, and which
permissions they turned on; an existing user is invited to the tour once;
anything in Settings is reachable in two clicks or by search.

## Decisions already made by the owner

- Setup stays as slides: Welcome, Model, Cloud plans, Tour. The first slide
  is a fun welcome sign with a typewriter of example prompts. The character
  flies between slides and to whatever the user clicks.
- The tour runs in the normal main window, fully scripted: demos type
  themselves, Return or the card's button takes each beat, the user never
  has to type. Demos are Chicago-based. Natural language first; `/` is shown
  once (`/think`).
- Ten stops at most, some with substeps shown as a checklist on the card:
  ask (search, places, weather), code and `/think`, keys, selection, files,
  Messages (read, ask for a text, approve on the real approval card), new
  chat, modes, permissions, done.
- The tour card sits in a rail the window grows by, beside the page and
  level with its target. The page keeps its width while the window grows
  and shrinks, and window moves are display-synced.
- The selection stop opens a pretend "Shmoogle Docs" window. Enigma's window
  fades aside; ⌥⌥ or Return opens the real compact panel under the selected
  line; a send moves the chat into the window with the real revision card;
  Replace text goes through the real replace path into the pretend document.
- All permissions are on one optional stop near the end, so nothing
  restarts unexpectedly. Only Screen Recording needs a restart; a restart
  mid-tour resumes at the same stop.
- Existing users are not put through setup again. They get a one-time
  invite to the tour; Replay stays in Settings → General.
- Settings: a grouped sidebar with search (Enigma: General, Shortcuts;
  Models: On this Mac, Cloud; Abilities: Search and maps, Selection, Screen,
  Files, Messages; Privacy: Permissions, Approvals; About). Rows are short
  with at most one short subtitle; details go behind an ⓘ popover. Each page
  has its own "› Advanced" disclosure, not a global toggle. Every macOS
  permission is on Permissions. SF Pro throughout, no monospace.
- Settings groups each section's rows on a rounded card with faint dividers
  between rows, under a bold heading.
- Shortcuts: every global action, window action and slash command can be
  given its own shortcut: keys with modifiers, modifiers pressed together, or
  a double tap of one modifier. The selection shortcut stays separate from
  summon by default, with a "Same as summon" switch.
- Brave stays as an optional key under Search and maps → Advanced.

## Approach

Port, don't rewrite. The spike's behaviour is approved, and rewriting it
from scratch risks drifting from what the owner saw. The new branch
`feat/f14-welcome-settings` starts from `main`, brings the spike's changes
over in one commit, then cleans them up in checkpoints:

1. **Structure.** Move spike code out of the files it was squeezed into
   (the spike could not add files) into its own files, added to the Xcode
   project. Rename spike-only names and keys. Delete what the spike
   replaced.
2. **Finish the gaps** the spike left (listed below).
3. **Tests**: rewrite the tests the spike broke on purpose; add the new
   ones.
4. **Docs and screenshots.**

The alternative, rebuilding each piece on `main` with the spike open beside
it, was rejected: it costs more and its only benefit, a cleaner history, is
covered by the structure checkpoint.

## Structure

New files (all in `Enigma/App/` unless noted):

| File | Holds | From the spike's |
|------|-------|------------------|
| `GuidedTour.swift` | `GuidedTour`, its stops, steps, beats, scripts, placement, card | `WelcomeSetup.swift` |
| `TourDocumentWindow.swift` | The Shmoogle Docs window, header, logo, `TourScene` | `WelcomeSetup.swift` |
| `WelcomeTypewriter.swift` | The welcome sign's typewriter and `welcomePerch` | `WelcomeSetupView.swift` |
| `SettingsPages.swift` | General, Search, Selection, Files, Permissions, About pages; `SettingsLink`, `SettingsAdvanced` | `SettingsView.swift` |
| `SettingsCards.swift` | The card marks, preference key and background | `EnigmaControls.swift` |
| `ShortcutStore.swift` | `KeyBinding`, `ShortcutAction`, `ShortcutStore` | `PanelShortcut.swift` |
| `ShortcutEditor.swift` | `ShortcutEditor`, `ShortcutRecorder` | `KeyboardShortcutsHelpView.swift` |

`SettingsDestination` stays in `SettingsView.swift`. The tour's window
plumbing (fades, `pageWidth`, display-link moves) stays in
`SpotlightPanelController.swift` and `AppShellView.swift`, where it belongs;
only its "F14 spike" comments are rewritten as ordinary ones.

Renames:

- UserDefaults keys lose `.spike`: `guidedTour.stop.v1`,
  `enigma.shortcuts.overrides.v1`, `enigma.shortcuts.selectionSameAsSummon.v1`.
  Nothing reads the spike keys; values saved by the spike are dropped.
- `enigmaStrongDividers` becomes `enigmaSettingsStyle`, since it now means
  "drawn as Settings" (bold headings, cards, roomier notes).

Deleted:

- The six-stop overlay tour: `WelcomeTourStep`, `welcomeTourTarget`, the
  overlay in `AppShellView`, `WelcomeSetup.tour` and `nextTourStep()`, and
  their tests.
- Settings rows and copy that moved elsewhere (the old General page's
  Messages and permission sections, the Help sheet's selection-key rows).
- `ConnectionSettingsSheet` and its snapshot test: the spike's Cloud slide
  no longer opens it.

Setup keeps its four steps in the same order, so `welcomeSetup.step.v1` and
`welcomeSetup.completed.v1` keep their meaning and need no migration.

## Gaps the spike left, to finish here

1. **Existing-user invite.** Shown once, in the main window's empty chat, to
   users whose setup was finished before this version: "See what Enigma can
   do" with **Take the tour** and **Not now**. Either choice retires it
   (`guidedTour.invite.v1`). Fresh installs never see it; they get setup.
   The release notes for the version mention the tour and the new Settings.
2. **No monospace in Settings.** Status lines, model fit and catalogue lines
   and badges use the UI font when drawn as Settings. The chat keeps mono.
3. **Shorter cloud sign-in blocks** on Settings → Cloud: one row per plan
   with its status and one button, details behind ⓘ.
4. **Help shows your shortcuts.** The Help sheet's list reads
   `ShortcutStore`, so custom shortcuts appear there.
5. **The model menu's "Advanced settings…"** opens Cloud with Advanced
   already open. `settingsDestinationRequested` carries an optional
   "open Advanced" flag; old raw destination values still work.
6. **Cards and hover.** A clickable row's hover fill stays inside the card's
   rounded shape. Custom rows that are not `EnigmaRow` (API key rows, model
   rows) start and divide cards like `EnigmaRow` does.
7. **Shortcut conflicts.** The editor refuses a shortcut that another Enigma
   action has, and warns, without refusing, on the common macOS ones it
   knows (⌘Q, ⌘W, ⌘Tab, ⌘Space and the like). Not exhaustive; said in a
   code comment.

Not doing (from the original F14 entry, overruled by the owner or the
prototype): a global Advanced toggle, section-level deep links, highlighting
the matched setting after a search (search opens the page), an Abilities
setup slide, and a `welcomeSetup.step.v2` migration.

## Behaviour that must hold

- Nothing in the tour sends, saves or changes anything real: tour chats are
  temporary and never in Recents; the Messages stop never sends; the
  selection stop only writes into the pretend document; demo replies are
  scripted.
- Leaving the tour at any stop (Skip, Esc, closing the window, ⌘N outside the
  new-chat stop) restores the window's normal size and closes the pretend
  document.
- Reduce Motion: no flying, typing or rising; fades only.
- Every permission button opens the right System Settings pane and shows
  live status; the tour and setup never grant anything themselves.
- Custom shortcuts take effect immediately, survive relaunch, and Reset
  restores today's defaults. A global shortcut that fails to register says so
  on its row.
- The test host never saves tour progress, shortcuts or the invite (it
  shares the app's defaults).

## Testing

Rewrite (broken on purpose by the spike):

- `EnigmaMainWindowTests`: `testTourCardDrawsAboveTheCharacterAndTakesTheClickOnNext`,
  `testTourTargetsAreOnTheNewControls` → the rail card takes Return and its
  button; each stop with a target sits level with it.
- `EnigmaSettingsTests`: the eight that look for controls on the old pages
  (API keys, Brave key, blocked sites, connection test, updates, web search
  text, destinations list) → find them on their new pages, opening Advanced
  where needed.

Keep (already in the spike): the tour's selection stop end to end, the
Messages approval stop, shortcut defaults/persistence/reset and conflict
refusal, card grouping, every destination rendering in Paper and Ink, the
margin test.

Add:

- existing users skip setup and see the invite once; fresh installs don't;
- leaving the tour from each stop restores the window and closes the
  pretend document;
- a restart mid-tour resumes at the saved stop; the test host never saves it;
- settings search: keyword hits, Return opens the first match, "No matches";
- old destination raw values (`general`, `local`, `cloud`, `selection`,
  `discover`) open the right pages; "Advanced settings…" opens Cloud with
  Advanced open;
- Help lists a custom shortcut;
- no monospace font in any Settings page (a render check on the status
  rows).

The full suite runs once before the push to `main`.

## Docs

- Rewrite `docs/Welcome-and-Settings.md` for the new setup, tour and
  Settings, with screenshots in Paper and Ink.
- Fix "Settings → …" paths in `Selection-Context.md`, `Messages.md` and
  `Web-Search.md`.
- `docs/design/UI-Style.md`: Settings now groups rows on cards (replacing
  "no boxes" for Settings only), bold section headings, the ⓘ and
  "› Advanced" patterns, and the tour rail.
- `to-do.md`: mark F14 done; note where F13, F15, F16, F19 and F20 now live.
- Release notes for the shipping version.

## Out of scope

Personalization (F13), context size (F15), F16's features, occupation (F19)
and F20's setup step; changes to how permissions, cloud or models work; the
chat UI outside the tour.
