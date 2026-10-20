# To-do

> **Note for agents:** This file has two lists: **Bug fixes** and
> **Features**. Each list is ranked by priority, most important first. Bug
> fixes generally come before features. Bug fixes use IDs B1, B2, …; features
> use F1, F2, …. Keep that split, the ranking and the IDs when you add,
> reorder or finish items. Remove an item, or tick it off, once it is done and
> on `main`, and update any cross-references to it.

## Bug fixes

### B1. Selection chats always open in the normal chat layout

**Problem:** A chat started from a selection stays in the compact panel UI
(`EnigmaCompactPanel`). It only becomes a normal window chat when the user
double-taps Control (`.selectionChatOpenedInWindow` in `AppShellView.swift`
calls `localChat.openTemporaryChatInWindow()`). Saving to Recents also happens
only in that function, so these chats never reach the sidebar, even with
"Keep selection chats private" off.

**Wanted:**

- A selection chat always opens in the normal chat layout, no matter what.
- The privacy toggle only decides whether it is saved:
  - Off: an ordinary chat, saved to Recents.
  - On: the chat opens in ghost mode (temporary chat, see F3). It is not
    saved and stays out of Recents.
- The selection stays attached in memory for /edit and Replace text, as it
  does now. Selected text is never written to disk.

**Notes:** Every way of opening or expanding a selection chat should go
through the same conversion as `openTemporaryChatInWindow()`. Add regression
tests for both toggle states.

### B2. Setup runs the performance check again for the suggested model

**Problem:** In welcome setup the flow is: pick model A → it installs →
performance check → recommendation. If you then install the suggested model,
it runs another performance check straight away, which can suggest yet
another model. Every download runs a check afterwards
(`LocalChatViewModel.downloadModel`), and the check can reorder the
recommendations (`WelcomeSetup.choices`).

**Wanted:** One performance check per setup. The first one calibrates this
Mac, so the suggested model installs without another check. "Check
performance" in Settings still runs one by hand.

## Features

### F1. Show the version number in Settings

A small, quiet version line in Settings, such as `Enigma 0.11.0 (build)`.
`MoveToApplicationsPrompt.swift` already reads `CFBundleShortVersionString`.
Bug reports (F2) use the same value.

### F2. Bug reporting

- A very short form: what happened, optional steps to reproduce, and optional
  contact email.
- An "Include logs" checkbox, **unchecked by default**.
- Adds diagnostics automatically: app version, macOS version, chip and memory,
  and the active route and model. It never includes chat content unless the
  user turns logs on.
- Reports go to walshleo427@gmail.com.
- **Delivery (the easiest option):** open a ready-to-send email in the user's
  mail app with the report filled in (`NSSharingService(named: .composeEmail)`,
  with logs as an attachment when checked; `mailto:` as a fallback). It needs
  no account, API key, server or new dependency. A silent in-app form service
  can replace it later if wanted.
- Put it in Settings and the Help menu.

### F3. Temporary chat (ghost mode)

- Works like temporary chat in other chat apps: a tiny ghost button in the
  top-right of the main window starts a temporary chat.
- In ghost mode the Enigma character wears a silly bedsheet ghost costume with
  eye holes, and a "Temporary · not saved" tag is shown.
- Temporary chats are never written to disk, stay out of Recents, and are
  gone when you leave them.
- Private selection chats (B1) open in this same mode.
- Reuse the existing private-chat machinery (`temporarySessionID`,
  `isTemporaryChat`, `historySessions`) instead of building a second one.

### F4. Settings revamp with an Advanced toggle

- Simpler default view: the active model, connections, and the common toggles.
- An "Advanced" toggle reveals the detailed options, such as the default
  model, performance checks and catalogue details.
- Do this before F5 and F6 so they have a clear place to link to.

### F5. Explore page revamp

- Add newer models that suit the app better.
- Group models by what they are good for (coding, writing, everyday use,
  studying, documents and research) instead of only by size and fit.
- Tag catalogue entries with these use cases; F6 needs the tags. See
  `docs/Updating-the-Model-Catalogue.md`.

### F6. Welcome page asks your occupation

- A setup step asks what you do, then suggests models for it.
- Choices: **Programmer, Writer, General user, Student, Researcher/Analyst**.
  - Student leans toward fast, light models for explanations and studying.
  - Researcher/Analyst leans toward long-context models for summarising
    documents.
- Occupation picks the use-case tags (F5); hardware fit then narrows the list,
  as the recommendations do today.

### F7. Better, more complete tour

- The tour has 6 steps today (`WelcomeTourStep`: history, composer, commands,
  files, model, help).
- Add the missing features: selection, temporary chat (ghost mode), screen,
  Messages and web search.
- Do this last, since B1 and F3–F6 change what the tour should show.
