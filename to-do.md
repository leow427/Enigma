# To-do

> **Note for agents:** This file has two lists: **Bug fixes** and
> **Features**. Each list is ranked by priority, most important first. Bug
> fixes generally come before features. Bug fixes use IDs B1, B2, …; features
> use F1, F2, …. Keep that split, the ranking and the IDs when you add,
> reorder or finish items. Remove an item, or tick it off, once it is done and
> on `main`, and update any cross-references to it.

## Bug fixes

### B1. ✅ Done: The chat jumps away from the conversation after sending a message

> **Solved:** The cause was the `LazyVStack` in `EnigmaMessageList`, not the
> animations or the observer. It sizes rows it hasn't drawn from an estimate,
> so after a tall reply a new message grew the chat by hundreds of points of
> empty space, and following the end scrolled into it. The list is now a plain
> `VStack`, so its height is exact. A hosted test sends a second and third
> message after tall replies, with Reduce Motion on and off. The trade-off:
> every row is laid out on each streaming update, which costs more in very long
> chats (see `docs/Chat.md`).

**Problem:** After the first message, sending another makes the main chat view
jump: it shoots down past the conversation, and the user has to scroll back up
to find the new message and the reply as it streams in.

**Where to look:** `EnigmaMessageList.swift`. The list is a `LazyVStack` in a
`ScrollView` with `minHeight` equal to the view and bottom alignment, plus
`.defaultScrollAnchor(.bottom, for: .initialOffset)` and
`.defaultScrollAnchor(.top, for: .alignment)`. Following the end of the chat
is done separately in AppKit by `ConversationScrollObserver`, which scrolls the
clip view to the document's bottom 30 ms after each content or frame change.
Likely suspects, to confirm by reproducing:

- Lazy rows are first laid out with estimated heights, so the document can be
  taller than the real content when the observer scrolls; the view ends up
  below the messages until rows are measured, or stays there.
- The row-enter animations (`.animation(..., value: transcript.rows.map(\.id))`,
  the new message's `offset(y: 18)` and the reply's delayed transition) animate
  the layout in SwiftUI while the observer jumps the clip view in AppKit, so the
  two disagree about where the bottom is.
- The `.top` alignment anchor and the pending-message row being replaced by
  the saved message (see the "waiting row" comment in `boundsChanged`) may
  also move the offset.

**Wanted:** Sending a message keeps the new message and its reply in view,
pinned to the bottom like ChatGPT, with no jump past the content. Streaming
keeps following while the reader is at the bottom, and stops following when
they scroll up (as now). Add a UI test or an observer unit test for the second
and third message in a chat, and check with Reduce Motion on and off.

### B2. Signing in to ChatGPT or Claude means installing a command-line tool first

**Problem:** Enigma's ChatGPT route runs the Codex CLI (`codex app-server`)
and its Claude route runs Claude Code (`claude`), and both must already be
installed. On a Mac without them, **Sign in** in Settings → Cloud and search
(and setup) is disabled, with a note that the tool is required and a link to
its install page, so signing in means Terminal, Homebrew or npm first. The
lookups are `CodexRuntimeConfiguration.executableURL()`
(`CodexAppServer.swift`) and `ClaudeCodeRuntime.executableURL()`
(`ClaudeCodeSubscriptionClient.swift`). Signing in should be one click.

- People with the ChatGPT desktop app already have a working Codex, but
  Enigma looks in the wrong place: it checks
  `/Applications/ChatGPT.app/Contents/Resources/codex`, while the app ships it
  at `Contents/Resources/codex-cli/bin/codex` (a small wrapper around a bundled
  `CodexCLI.app`).
- Both tools run with a fixed `PATH` (`/opt/homebrew/bin:/usr/local/bin:…`),
  so a Node-based install (Homebrew's `codex` is a `#!/usr/bin/env node`
  script; npm or nvm installs of either tool) fails to start when `node` lives
  somewhere else.

**Quick fix first:** replace the `ChatGPT.app` candidate with
`ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, so ChatGPT desktop users
can sign in now.

**Wanted, ChatGPT: a built-in Codex runtime.** Codex is open source
(Apache-2.0) and OpenAI publishes standalone, signed macOS packages that don't
need Node, so Enigma can provide its own copy:

- Use Enigma's own pinned Codex first, and drop the hard-coded app-bundle
  candidates (`Codex.app`, `ChatGPT.app`) once it works. Sign-in already goes
  through Codex's browser login (`account/login/start` in
  `CodexSubscriptionClient.swift`), so with Codex present, **Sign in** is one
  click.
- **Ship the whole package, not one binary.** Enigma turns on
  `features.code_mode_host` for File Mode and tool calls (`CodexFileMode.swift`,
  `CloudToolCalling.swift`), which needs the separate `codex-code-mode-host`
  binary (about 65 MB) next to `codex`. OpenAI's package also carries `rg` and
  a resources folder.
- **Download it, don't bundle it.** The package is roughly 250 MB per
  architecture (ChatGPT.app's `codex-cli` folder is 325 MB), against a 25 MB
  Enigma.app, and Sparkle updates always download the full zip
  (`--maximum-deltas 0` in `scripts/release.sh`). So the first time someone
  presses **Sign in**, download the pinned package for this Mac's architecture
  into Application Support, with progress, Cancel and a clear failure message.
  The vision runtime already does exactly this: `LocalVisionRuntime`
  (`LlamaServerVisionEngine.swift`) pins a URL, size and SHA-256 per
  architecture, extracts safely, runs a smoke test and installs into a
  versioned folder, driven by `LocalFileRuntimeSetup`. Follow it.
  (`Packages/LlamaBridge` is the wrong model: SwiftPM binary targets only work
  for linked frameworks, not helper executables.) New Codex versions ship with
  Enigma releases by bumping the pin.
- **Keep OpenAI's signature.** The binaries are already Developer ID-signed
  with the hardened runtime and their own entitlements, while Enigma is signed
  with Apple Development and isn't notarized (`docs/Distribution.md`).
  Re-signing would also change which code identity owns the Codex login in the
  Keychain (`cli_auth_credentials_store="keyring"`), which could sign existing
  users out.
- Keep the existing isolation (`CODEX_HOME`, the disabled features) and the
  check result from B3. "Codex not found" should no longer be reachable, or
  only when a download failed.
- Add Codex's license to `Enigma/Resources/ThirdPartyNotices.txt`, update
  `docs/ChatGPT-Setup.md`, and check OpenAI's current terms for embedding
  `codex app-server` in a third-party app.

**Wanted, Claude: one-click install, not a bundled runtime.** Claude Code is
proprietary ("All rights reserved", under Anthropic's Commercial Terms), so
Enigma can't redistribute it. Anthropic's Agent SDK docs also say that,
unless previously approved, third-party developers may not offer claude.ai
login or rate limits in their products. So:

- When Claude Code isn't found, offer an **Install Claude Code** button that
  runs Anthropic's official installer (in Terminal, like the sign-in script
  today), then re-detects and goes on to **Sign in**. The installer puts
  `claude` in `~/.local/bin`, which Enigma already checks first. Also show the
  install command with a Copy button and short steps for people who prefer
  Terminal:
  1. Open Terminal (Applications → Utilities → Terminal).
  2. Paste `curl -fsSL https://claude.ai/install.sh | bash` and press Return.
  3. Come back and press **Check again**, then **Sign in**.

  Check the command against Anthropic's install docs when implementing (it
  changes), and mention it once in `docs/Claude-Code-Setup.md`.
- Point to the Anthropic API key route as the officially supported way to
  use Claude in a third-party app.
- Bundle Claude Code only if Anthropic approves it in writing. Confirm
  Enigma's current Claude subscription route fits Anthropic's terms too.

**Also harden detection** (lower priority): an app opened from Finder gets a
minimal `PATH`, so Claude Code installed via a Node version manager
(`~/.nvm/versions/node/*/bin`, `~/.volta/bin`, fnm, asdf), a custom npm prefix
(`~/.npm-global/bin`), Bun (`~/.bun/bin`) or in `~/Applications` is not found.
Ask the login shell once (`$SHELL -lc 'command -v claude'`, with a timeout),
add those folders, run the tool with its own folder on `PATH` so a Node-based
install can find `node`, and offer a "Choose Claude Code…" picker as a last
resort. Until the built-in Codex ships, do the same for `codex`.

**Notes:** B3 (done) changed the same controls; build on its check result.
Its "not found" message doesn't yet say where Enigma looked ("looked in …");
add that here.

### B3. ✅ Done: "Check sign-in status" gives no feedback and no way to set up

> **Solved:** `CloudSettingsModel` gained a per-provider "checking" flag and a
> `SignInCheck` result (signed in, not signed in, not installed, failed) set
> only by the button. The shared controls show "Checking…", then the result
> with its next step, and announce it to VoiceOver. Sign in is disabled
> during a check, and any other account refresh clears an old result so it
> never contradicts the live state.

**Problem:** In Settings → Cloud and search (`CloudConnectionControls.swift`),
"Check sign-in status" for ChatGPT and Claude re-runs
`refreshChatGPTAccount()` / `refreshClaudeCodeAccount()`. When the result
doesn't change, for example still not signed in, nothing visible happens: no
progress, no "checked just now", no message. When the CLI is missing it
returns early without any error. It also never leads to a sign-in or setup
page.

**Wanted:**

- Show that a check is running, then always show the result: "Signed in as
  …", "Not signed in", "Codex/Claude Code not found on this Mac (looked in …)",
  or the error.
- Each result offers the next step: not signed in → **Sign in**; not installed
  → the setup guide (`docs/ChatGPT-Setup.md`, `docs/Claude-Code-Setup.md`) or
  the official installation page; error → what to try.
- Applies to both setup's connections step and Settings, since they share
  these controls.

### B10. Two contacts with the same name are treated as one person

**Problem:** Asking Enigma to text someone by name merges every contact card
with that name. With two different people called "Alex Kim", their numbers are
pooled, and the most recent conversation (or, with none, B6's phone and mobile
preferences) picks one of them without asking. `docs/Messages.md` says the
model asks when a name matches more than one person. The approval card still
shows the exact number, which is the only safeguard left. Reproduced with
temporary tests in `MessagesTests`.

**Cause:** `MessagesTools.resolve` treats the candidates as one person when
`Set(candidates.map(\.name)).count == 1`, so cards that share a name pool their
handles.

**Wanted:**

- Treat each contact card as a separate person, and apply the
  existing-conversation and phone preferences (B6) only within one card.
- When a name matches more than one card, ask which person, with something
  that tells them apart (the number or email, its label, the company).
- Add tests for two same-name cards: with a conversation with one of them,
  with only one mobile-labelled number, and with a phone on one card and only
  an email on the other.

### B11. Web search can send more than the user saw or meant

**Problem:** Brave can receive text it shouldn't, in three ways. Each was
reproduced with a failing test.

1. **Commands go into the query.** `/think` reaches Brave on the Local,
   Auto → local and local vision routes ("/think What happened in the news
   today?"), and `/edit` and `/translate` on every route, since they stay in
   the message text. When nothing is attached, the private `search` in
   `LocalChatViewModel` passes the text as it is, and
   `BraveSearchClient.query(from:)` only shortens it. `docs/Web-Search.md` says
   queries are sent without slash commands.
2. **Refining from attached text has no privacy rule.** With selected text or
   a draft attached, the query-writing prompt in `LocalChatViewModel.search`
   never says to leave out personal details and credentials. The screenshot
   prompt (`ScreenSearchContext.queryPrompt`) does, and `Web-Search.md`
   promises it for both.
3. **A search nobody saw after a typed `/screen` or `/snapshot`.** While
   `/screen` is in the draft, no search chip shows. After the capture,
   `submitDraft(recognizesCommands: false)` resolves the draft again without
   `/screen`, automatic search is still on, and a query the model writes from
   the screenshot's text goes to Brave. That breaks the promises in
   `Slash-Commands.md` ("runs only the commands you typed") and `Web-Search.md`
   (the chip tells you before sending).

**Wanted:**

- Strip every slash-command token in `LocalChatViewModel.search` before
  refining or sending, so all routes are covered.
- One query-writing prompt for screenshots and attached text, with the "omit
  unrelated content, credentials and personal details" line.
- When `recognizesCommands` is false, turn off automatic search too
  (`composerIntent(recognizesCommands:)`), so the request after a capture runs
  only what the user typed.
- Keep the three reproductions as regression tests (`WebSearchTests`,
  `ComposerIntentResolveTests`, `ScreenViewTests`).

### B12. Denying Automation doesn't stop a Messages send

**Problem:** When macOS denies Automation while a Messages request runs (or
Full Disk Access is lost mid-request), the request carries on and the **Open
Automation Settings…** card never appears, although `docs/Messages.md` says
it stops there. The error goes back to the model, which answers "I couldn't
send that" or tries again. Each retry runs `osascript` again, and a failed send
isn't recorded, so nothing stops the retries. Reproduced on the local and API
routes with failing tests.

**Cause:** `MessagesTools.execute` marks these results `terminal: true`, but no
Messages route reads the flag: `LocalToolAgent.run` (`AgentToolLoop.swift`),
`CloudToolLoop.run` (OpenAI, Anthropic and Gemini), `CodexToolMode.handle`
(which drops it) and `ClaudeCodeToolMode.respond`. Only File Mode's loop checks
it. The card (`appleMessages.issue`) is set only by the checks before a request
starts.

**Wanted:**

- Every tool loop stops on a terminal result and raises its `MessagesError`;
  `submitMessages` reports any `MessagesError` with a `privacyPane`, so the card
  appears with the right button.
- `MessagesIssueCard` names its button after the pane (a Contacts pane would
  also read "Open Automation Settings…" today).
- `testAutomationDenialStopsTheRequestWithSettingsGuidance` checks only the
  flag; make it check that the request stops and the card shows, on each route.

### B13. Sending after scrolling up leaves the new message out of view

**Problem:** Scroll up in a chat, then send: the new message and its reply stay
below the view. In a reproduction the new message ended about 290 pt below the
bottom and the reply grew out of sight, with Reduce Motion on and off.
`docs/Chat.md` says sending brings the message and its reply into view.

**Cause:** `ConversationScrollObserver` (`EnigmaMessageList.swift`) resumes
following only when the reader scrolls back to the bottom (`endScrolling()`,
`boundsChanged()`). A send changes `conversationScrollRevision`, but
`contentChanged(_:)` → `scheduleScroll()` returns early while `followsLatest`
is false. B1's hosted test only sends while already at the bottom.

**Wanted:** Sending always resumes following and scrolls to the end, as smoothly
as B1's fix; scrolling up during the reply still stops following. Add a hosted
test next to B1's in `EnigmaConversationTests` that scrolls up, sends, and
checks the new message is visible, with Reduce Motion on and off.

### B4. The animated character covers the model picker

**Problem:** The Enigma character can sit on top of the model picker (the
Auto/Local/Cloud and model menu beside Send, ⌘K), hiding rows of the open
menu.

**Cause:** The character is drawn by `.enigmaCharacterStage(_:)` as an
`overlayPreferenceValue` layer over the whole window
(`EnigmaCharacterStage.swift`). Open menus are drawn by a menu host
(`.enigmaMenuHost()` and `EnigmaMenuPresenter` in `EnigmaControls.swift`) as a
full-window overlay too. But the main window's and the compact panel's hosts
sit inside `welcomeShell`, and the stage is applied outside them
(`AppShellView.swift`). So the stage draws over every hosted menu, and the
character's hit area (`handle`) catches clicks meant for the menu or for its
click-outside-to-close layer.

**Wanted:**

- Open menus always draw above the character and receive their clicks. The
  simple fix: apply one `.enigmaMenuHost()` to `welcomeShell`, between
  `.enigmaCharacterStage(character)` and `.enigmaTheme(...)` (the theme must
  stay outside so menus get the palette), and remove the two inner hosts.
  `EnigmaMenuRoom` finds the presenter through the environment, so the compact
  panel still grows to fit. Menus are then no longer clipped by
  `EnigmaWindowChrome`; check that still looks right.
- Move the tour's overlay (`overlayPreferenceValue(WelcomeTourAnchors.self)`)
  outside the stage too, so the character can't cover its Next and End
  buttons.
- The slash-command list is an in-place overlay in `SlashCommandComposer.swift`,
  not a hosted menu. Route it through the menu host, or have the stage hide
  the character and turn off `handle` while the list overlaps it.
- Check every in-window menu, on the empty page and in a chat, and in the
  compact selection panel: the model picker, the slash list, the tour, and the
  file-change menus ("Review saved file changes", "Earlier changes"). Sheets,
  the Attach file picker (`NSOpenPanel`) and the menu-bar menu are separate
  windows and aren't affected.

### B5. Selection chats stay in the compact panel and never reach Recents

**Problem:** A chat started from a selection stays in the compact panel UI
(`EnigmaCompactPanel`). It only becomes a normal window chat when the user
presses ⌘O or the panel's Open in window button
(`.selectionChatOpenInWindowRequested` →
`SpotlightPanelController.openSelectionChatInWindow()` →
`.selectionChatOpenedInWindow` in `AppShellView.swift`, which calls
`localChat.openTemporaryChatInWindow()`). Saving to Recents also happens only
in that function, so these chats never reach the sidebar, even with "Keep
selection chats private" off.

**Wanted:**

- The selection panel opens exactly as it does now. Once the question is
  sent, the chat always switches to the normal chat layout, no matter what.
- The privacy toggle only decides whether it is saved:
  - Off: an ordinary chat, saved to Recents.
  - On: the chat opens as a temporary chat. It is not saved and stays out of
    Recents. `openTemporaryChatInWindow()` already handles this case
    (`OpenedSelectionChat(isPrivate: true)`), so this doesn't wait for F10;
    the chat picks up ghost mode's look when F10 ships.
- The selection stays attached in memory for /edit and Replace text, as it
  does now. Selected text is never written to disk.

**Notes:** Every way of opening or expanding a selection chat should go
through the same conversion: the Open in window path above, and
`expandSelectionConversation()` in `AppShellView.swift`, which runs when a
question is sent (`.selectionPanelExpandRequested` → `expandSelectionPanel()`)
and is the natural place to convert. Reuse
`.selectionChatOpenInWindowRequested` rather than copying it. Add regression
tests for both toggle states.

### B8. Enigma reopens the last chat instead of a new one

**Problem:** After quitting and reopening Enigma, the window shows the most
recent chat. It does the same when summoned again after a long break, so
the user lands in an old conversation instead of a fresh page.

**Where to look:**

- `LocalChatViewModel.init` selects `sessions.first?.id` after loading saved
  chats (and restores that chat's file workspace), so launch always opens the
  most recent one. Leaving `selectedSessionID` nil is enough:
  `ensureSelectedSession()` creates a chat when one is needed, so nothing is
  written on every launch.
- `newChat()` in the same file stops any running reply, then always adds and
  saves a new empty chat.
- New chats from the UI go through the `.newChatRequested` handler in
  `AppShellView.swift` plus `restoreNormalPanel` in `SpotlightPanelController`.
  Use that path, not `localChat.newChat()` alone, or a compact panel keeps its
  frame.
- Summoning: `SpotlightPanelController.show()` and `hide()`, the show/hide
  shortcut (`toggle()` in `ApplicationDelegate`), the `show()` at launch, and
  the menu-bar item's Open and New chat (`MenuBarController`). Nothing records
  when the window was last hidden today.

**Wanted:**

- **On launch:** always open to a new chat. Saved chats stay in Recents.
- **After 5 minutes away:** if Enigma hasn't been shown or used for more than
  5 minutes, summoning it opens a new chat. Under 5 minutes, it comes back to
  the chat the user left. Record the time in `hide()` and check it in
  `show()`. Don't hang it on `.panelPresented`: selection, screen capture and
  text replacement post it too, and would throw away a selection chat the user
  just started. Decide whether a window left open behind other apps counts as
  away (it doesn't hide when Enigma loses focus).
- Don't pile up empty chats: if the current chat has no messages, reuse it
  instead of making another. Put this in `newChat()` so ⌘N and the menu bar's
  New chat benefit too.
- Never interrupt a reply that is still running: if `isBusy`, stay on that
  chat. Model downloads don't block chatting and `newChat()` leaves them
  alone, so they need nothing extra.
- Temporary chats (private selection chats, and F10) are discarded as usual
  when a new chat starts.
- Add tests for launch, coming back under and over 5 minutes, and an empty
  current chat. There is no injectable clock today, so put the rule in a small
  pure policy type (like `ShellPresentation`) that is given the times.

### B14. Attaching more than 16 items gives a vague error

**Problem:** Picking 17 files shows "The file operation was incomplete or
ambiguous. No change was made." without mentioning the limit. Files inside an
attached folder also count separately, so a folder plus 16 of its own files is
refused, although `docs/File-Mode.md` says a file inside an attached folder is
covered by that folder. Both reproduced with failing tests.

**Cause:** `FileModeCoordinator.activate` checks the count before
`WorkspaceSelection.normalized`, and throws `.invalidArguments`.

**Wanted:** Normalize first, then check the count, and show a message of its
own, such as "You can attach up to 16 files or folders." Keep the two
reproductions as tests in `FileModeUITests`. F4's drag and drop will use the
same path.

### B9. Some text names the wrong shortcut

**Problem:**

- The tour's history step (`WelcomeTourStep.history` in `WelcomeSetup.swift`)
  tells people to double-tap Control to show or hide the sidebar. That
  shortcut became ⌃⌘S in eefd872 ("Make Enigma's shortcuts consistent and
  collision-free"), so the tip doesn't work.
- The selection key can be Option, Command or Shift, but three texts always
  say Option: the Accessibility row ("…with double-Option…",
  `MacPermissionRows.swift`), the Accessibility note in the chat
  (`SelectionCards.swift`), and Settings → Selection ("Text is captured only
  when you double-tap Option.", `SettingsView.swift`).

**Wanted:** The tip says ⌃⌘S, and the selection texts name the chosen key (or
say "the selection shortcut"). Also fix the comments that still say
"double-tap Control" (`SpotlightPanelController.swift`,
`ShellPresentation.swift`, `CompactPanelHints` in
`EnigmaCompactPanelLogic.swift`) and rename
`testDoubleControlOpensThePanelsChatInTheWindowBeforeTheFirstAnswer` (opening
a selection chat in the window is ⌘O).

### B15. Messages can report a send as checked when it wasn't

**Problem:** `docs/Messages.md` says each send is checked against Messages'
history for three seconds. A send to someone you haven't messaged from this Mac
skips that check and returns "handed_to_messages" straight away; the tool's
text only says Messages accepted it, but the model may tell the user it was
sent. Reproduced with failing tests. Also, from reading the code: for existing
conversations `MessagesDatabase.latestOutgoing` ignores whether Messages
marked the message as failed, so "sent" can be reported for a message that
wasn't delivered.

**Wanted:** After a send to a new handle, find the conversation Messages
creates for it and run the same check. Leave out failed messages in
`latestOutgoing` (check which `chat.db` columns mark a failure). Add tests with
the existing fakes, and update `docs/Messages.md` to match.

### B6. ✅ Done: Messages asks "phone or email?" instead of using the contact's number

> **Solved:** `MessagesContact` now keeps the phones labelled mobile or iPhone.
> With no existing conversation, `resolve` picks phones over email and mobile
> over other phones, comparing normalised handles so one number in two formats
> isn't a tie. It asks only for a real tie, listing phones first. An existing
> conversation still wins.

**Problem:** Asking Enigma to text a contact by name finds the contact, then
asks whether to send to their phone number or email address. It only sends
once the user says "use the number" or types the number out.

**Cause (in code, not the model):** `MessagesTools.swift`, recipient
resolution for a contact name. If one of the contact's handles already has a
conversation, the most recent one is used. If none does, and the contact has
more than one handle (phones and emails together, `MessagesContact.handles` is
`phones + emails`), it throws `MessagesError.ambiguousRecipient` with every
handle, and the model has to ask. So this happens for any contact with a phone
and an email whom you haven't messaged from this Mac yet.

**Wanted:**

- Resolve it in code, not by prompting the model: when there's no existing
  conversation, prefer the contact's phone number over email.
- With several phone numbers, prefer the one labelled mobile or iPhone (keep
  the `CNLabeledValue` labels in `MessagesContactsLoader`, which drops them
  today). Only ask when that still leaves more than one equal choice, and then
  list phone numbers first.
- Use email only when the contact has no phone number.
- Keep the rest as is: an existing conversation still wins, and the "Send this
  message?" approval card still shows the exact number before anything is
  sent.
- Add tests for phone + email, several phones with and without a mobile label,
  email only, and an existing email conversation (which should still be used).
- Update `docs/Messages.md`.

### B7. ✅ Done: Setup runs the performance check again for the suggested model

> **Solved:** `downloadModel` takes `checkPerformance` (default true, so
> Settings is unchanged). Welcome setup marks itself calibrated once a check
> actually starts and passes false for later installs, so a cancelled or
> failed first install still gets its check. Replaying setup re-arms it.

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

### F1. Copy buttons on code blocks and replies, like ChatGPT

**Today:** code blocks (`ChatMarkdownView.swift`) are plain monospaced text in
a scrolling box: no copy button, no language label, no colours. There is no
copy control anywhere in the chat. Each paragraph is its own selectable
`Text`, and a selection can't cross them, so a whole reply can't even be
selected and copied in one go.

**Wanted:**

- **Code blocks:** a header bar with the language name on the left (the parser
  already has it as the block's `languageHint`) and a **Copy** icon in the top
  right that briefly turns into a check mark ("Copied").
- **Terminal commands** (`bash`, `sh`, `zsh`, `shell`, `console`): when some
  lines start with a `$ ` or `% ` prompt, Copy keeps only those lines (and
  their `\` continuation lines) without the prompt, and drops the rest as
  output. Otherwise it copies the block as shown. Never treat `# ` as a
  prompt; it is also a comment.
- **Whole replies:** a copy icon on the whole reply (on hover, top right or in
  the reply's meta line), for essays and other writing (emails, cover letters,
  posts).
- Code Copy writes plain text. Reply Copy writes plain text (as shown, without
  Markdown marks) plus rich text, so it pastes cleanly in editors and in Mail
  or Pages. There is no ready source of rich text: `AttributedString(markdown:)`
  has no fonts, paragraph breaks or list markers, so build the RTF from the
  parsed `ChatMarkdownBlock`s, without palette colours (Ink's light text would
  paste invisibly on white).
- Accessibility: "Copy code", "Copy reply" labels; keep the code block's
  existing "Code" accessibility label. Icons shown on hover must also be
  reachable with Tab and VoiceOver.
- Syntax highlighting is F8; standalone draft blocks and editing them in place
  are F22 (draft blocks aren't drawn as code blocks).

### F2. Keep typing while a reply streams

- Today the composer is read-only while `localChat.isBusy`
  (`composerIsEnabled` in `AppShellView.swift` sets the `SlashCommandTextView`'s
  `isEditable`), and the `/` button, suggestions and Attach turn off with it.
  `isBusy` also covers model operations, File Mode runs and applying a
  selection revision. Let people type their next message while a reply runs.
- Simplest version: typing works, Send stays disabled until the reply ends
  (Stop still works; Return already does nothing while busy). Queueing the
  next message can come later.
- Besides `isEditable`: `shell.requestBusyChanged` takes focus away while busy
  (`ShellPresentation.swift`), and `composerText` shows an empty field while
  `pendingUserMessage` is set, so text typed just after Send would be lost.
  Build on `draftAfterAcceptance` (`ComposerSubmission.swift`), which already
  keeps a draft edited after Send.
- Decide whether ⌘N and the selection shortcut, which clear the draft today,
  should discard text typed during a reply.
- Keep Attach disabled during a File Mode run (Stop revokes the live
  workspace). Make sure slash-command completion and the selection panel
  behave the same while a reply runs.

### F3. Regenerate the latest reply

**Today:** replies have no actions, only a meta line (`EnigmaMessageList.swift`);
there's no way to retry one.

**Wanted (like ChatGPT and Claude):**

- A retry icon on the latest reply to get a new answer, with an optional
  choice of route or model. Especially useful with small local models, whose
  first answer is often weak.
- Disabled while a reply is streaming. Works with history saving and
  temporary chats. Keep the old reply until the new request is accepted, so a
  failed retry doesn't lose it.
- Start with plain chat turns. There is no single send path to replay:
  `submitDraft` in `AppShellView.swift` picks Files, Messages, Screen, local or
  cloud from the composer's state, and a saved `ChatMessage` keeps only its
  text, sources and attachment names, not its screenshot, selection context or
  kind of turn. Re-running those turns after a relaunch needs more stored.
- Actions the reply already took (File Mode edits, sent iMessages) aren't
  undone by regenerating, so say so instead of implying they were reversed.
  For file edits, point to File Mode's existing Review and Undo.
- Regenerating is editing the last message without changing it (F9): build
  one truncate-and-resend path for both.

### F4. Drag and drop files, and paste images

- Drop files or folders onto the window or composer to attach them, as the
  Attach button (⇧⌘A) does today, within File Mode's limits (16 items, 2 MiB
  per file; access comes from the route, not a choice). Split the URL handling
  out of the picker in `FileModeCoordinator.activate` so drops can use it.
- Drop or paste (⌘V) images to attach them like a screenshot: a new
  `ScreenAttachment` source next to `screenRegion` and `fullDesktop`, with the
  same OCR, vision-model and cloud upload consent rules. Add an
  `attach(image:)` that reuses `capture()`'s OCR step, and update the labels
  that assume two sources (`ScreenSettings.swift` would call a pasted image a
  "selected region").
- Rules: image files go to the image attachment, other files to File Mode.
  File Mode and a screenshot can't be combined, so decide what a mixed drop
  does. There is one image attachment at a time.
- Today there is no `onDrop`/`dropDestination` or paste handling anywhere. The
  composer is an AppKit text view (`SlashCommandTextView`), which can insert a
  dropped file's path as text; handle drops and `paste(_:)` there, since a
  SwiftUI `.onDrop` won't get drops over the field.

### F5. One shared system prompt: Enigma, a friendly personal assistant

- Every route should know it is **Enigma: a friendly, general personal
  assistant that is concise, yet always useful.**
- Today the identity is inconsistent. Local models (`LlamaCPPModelEngine`,
  `LocalMultimodalClient`, agent runs, local File Mode in `AgentFileTools.swift`),
  the OpenAI and Anthropic API clients (`CloudProviderClients.swift`), Gemini
  (`GeminiContentClient.swift`) and API-key tool calling (`CloudToolLoop`) get
  only `ChatResponseStyle.instructions`, with no name at all. Claude Code,
  Codex, and their tool-calling prompts each hard-code their own "You are
  Enigma, a helpful general-purpose assistant…" line, and Codex File Mode says
  "a helpful assistant for file analysis and editing".
- Every route already includes `ChatResponseStyle.instructions`, so put one
  identity line at its top and remove the per-client copies so it lives in one
  place. Keep route-specific additions (text-only, file tools) after it. Make
  it a function rather than a constant: F13 adds the user's own text at run
  time.
- Keep it short: catalogue models run with an 8,192-token context, imported
  ones with 4,096. Check that small local models still follow the existing
  length and Markdown guidance. Existing tests compare prompts against
  `ChatResponseStyle.instructions` itself, so add one that checks the identity
  reaches every route.

### F27. Keep file edits and message sending off on small local models

**Today:** every local model gets the same skills. Local File Mode can create,
edit, move and delete files with any model (`LocalFileCapabilities.access(for:)`
takes the model but returns read & edit for all of them), and `/messages` gives
any model `send_message`. Small models make mistakes with tools (the wrong
file, a bad patch, the wrong recipient or text), and people tend to approve
what they're shown.

**Wanted:**

- **Which models:** sensitive skills need a local model of about 9B parameters
  or more, counted in total parameters so mixture-of-experts models qualify,
  that also scores at least 13.5 on the catalogue's quality index. In today's
  catalogue that allows Qwen3.5 9B, Gemma 4 12B, 26B-A4B and 31B, Qwen3.6
  35B-A3B and Qwen3.8 27B. It blocks Qwen3.5 2B and 4B, Gemma 4 E4B (a 4B
  model in effect, though 7.5B in total), and both Ministral 3 sizes, which
  score below Qwen3.5 4B. Imported GGUFs are blocked, since their size and
  quality are unknown. Store the result as a field on each catalogue family,
  so it is reviewed per model (for example with `scripts/evaluate-file-mode.py`
  at the family's smallest quantization) rather than worked out at run time.
- **Sensitive skills:** changing files (create, edit, move, delete) and sending
  messages. With a blocked model, File Mode stays read-only (return
  `.readOnly` from `LocalFileCapabilities.access(for:)`), and `/messages` can
  still read and search but isn't given `send_message`. Everything else stays
  on: chat, `/think`, `/search`, `/screen`, `/snapshot`, `/translate`, and
  `/edit` (nothing changes until the person clicks Replace text). New skills
  that act, such as F26's search before acting or F24's Maps, follow the same
  rule.
- **The model decides, not the Mac:** the check uses the model the next
  request runs on, so a capable Mac that switches to Qwen3.5 4B loses these
  skills too.
- **Cloud is never blocked:** Cloud mode keeps every skill it has today,
  whatever the local model (in Cloud, only the ChatGPT route edits files
  today). Auto keeps File Mode and Messages on this Mac by design, so with a
  blocked model it doesn't move them to the cloud on its own: it explains and
  offers **Switch to Cloud**.
- **A notice when it changes:** when the selected model changes which skills
  are on (choosing another local model, switching between Local and Cloud, or
  a model install finishing), show a short notice in the main window and the
  compact panel, such as "File edits and sending messages are off with
  Qwen3.5 4B. Use Cloud or a larger model to turn them on." and "File edits
  and sending messages are back on." Show it only on a change, not at launch;
  announce it to VoiceOver; respect Reduce Motion.
- **At the point of use:** attaching files with a blocked model shows **Read
  only** with the reason, and asking to send a message explains why, with
  **Switch to Cloud**, instead of failing later.
- Settings → Local models says on each model whether it can change files and
  send messages (see F18).
- Tests: the rule for every catalogue family and for imported models;
  read-only File Mode and no `send_message` with a blocked model; Cloud
  unchanged; the notice when switching each way. Update `docs/File-Mode.md`,
  `docs/Messages.md` and `docs/Local-Model-Selection.md`.

### F6. Warn slow Macs that small local models handle tools poorly

- When this Mac's recommendation or the model in use is small (F27's rule),
  the performance check says the model underperformed
  (`LocalModelBenchmark.underperformed`), or no model fits, show a short note:
  file edits and sending messages are off with small local models (F27), other
  tools may work poorly too, and connecting a cloud provider is strongly
  suggested. (Local web search fetches results before the model answers, so it
  isn't tool calling.)
- Show it in setup's model step, pointing to the Connections step that comes
  next, and in Settings → Local models, with a link to Cloud and search. Do not
  nag again once any cloud provider is connected
  (`CloudSettingsModel.isConfigured` checks only the preferred one).
- Use the advisor's existing hardware profile, recommendation roles and
  benchmark results (`LocalModelAdvisor`) to decide, not a new heuristic, and
  keep it consistent with the existing "ran slower than expected" note
  (`LocalModelViews.swift`).

### F26. Commands that work together: think with search, and search before acting

**Today:** typed commands combine, but each runs once in a fixed order.
`/search` (or automatic search) runs one search from the typed message before
the model starts, and `/think` then only makes the answer more careful, so the
model can't decide what to look up after thinking, or search again. Search
can't be used at all with attached files (File Mode) or `/messages`, and a
screenshot can't be used with either (the conflicts in `ComposerCommands` and
`ComposerIntent`, `docs/Slash-Commands.md` → Combining commands). Fix B11
first: commands leak into the query today.

**Wanted:**

- **Search, then think** (what `/think /search` does today) stays the default:
  one search from the typed request, then a careful answer over the results.
- **Think, then search:** when the model handles tools well, give it web
  search as a tool during `/think`, so it can plan its queries, search a few
  times (with a cap, for example three searches) and check what it found
  before answering. Each query shows in the activity line as it runs, and
  every source is listed as today. Cloud routes already run tools
  (`CloudToolLoop`, the Codex and Claude Code tool modes); on local models keep
  the single search unless the model passes F27's rule. Only in chats without
  files or Messages.
- **Search before acting:** allow `/search` with File Mode, `/messages` and
  `/edit` by running the search first, from the typed request only, and
  handing the results to the step that acts:
  - files: "update the README with the latest SwiftLint release";
  - `/messages`: "text Sam tomorrow's forecast" (the approval card still shows
    the exact text before sending);
  - `/edit`: "update these figures to this year's numbers".
- **Keep the privacy rule:** messages and file contents never become a search
  query, and selected text and screenshots only through the query-writing
  prompt that leaves out personal details and credentials (B11). So the
  combinations above search once, before acting, never as a tool the model
  drives.
- **Optional, a screenshot with an action:** `/snapshot` with File Mode ("make
  this page match the design on screen") or with `/messages` ("text Alex the
  address on my screen"). The screenshot's text goes only into the files or
  the message the user approves.
- Show every command that will run as a chip or highlighted word, in the order
  it runs. Update the conflict rules and their tests
  (`ComposerIntentResolveTests`), and `docs/Slash-Commands.md` and
  `Web-Search.md`.

### F7. ✅ Done: Show the version number in Settings

> **Solved:** Settings → General → Updates already has a Version row
> ("0.11.0 (4) · Last checked …") from `AppUpdater.versionText(info:)`, tested
> in `AppUpdaterTests`. It shipped in 5dcc378, before this item was written.

A small, quiet version line in Settings, such as `Enigma 0.11.0 (build)`.
`MoveToApplicationsPrompt.swift` already reads `CFBundleShortVersionString`.
Bug reports (F12) use the same value.

### F25. "What's new?" button after an update

**Today:** after Sparkle installs a new version, nothing in the app says what
changed. The notes exist (`docs/release-notes/<version>.md`, embedded in
`appcast.xml` by `scripts/release.sh`), but users only see them in Sparkle's
update window, if at all.

**Wanted:**

- After Enigma launches on a newer version than last time, show a small
  **What's new?** button in the top right of the main window.
  - Colour: the palette has no blue (`docs/design/UI-Style.md`,
    `EnigmaTheme.swift`) and colours aren't hard-coded, so either add a token
    with Paper and Ink values (and `EnigmaThemeTests` contrast coverage) or use
    `accentText` in an outlined style.
  - Place: the top right has no permanent home yet; its bar only shows while
    the sidebar is hidden (`EnigmaHiddenSidebarBar`). Make one slot there that
    F10's ghost button shares.
- Clicking it shows everything added in that update: the release notes for the
  new version (and any versions skipped since the last one seen), rendered with
  `ChatMarkdownView` in a sheet or popover.
- Once it has been opened, the button goes away for good for that version.
  Remember the last build seen (`CFBundleVersion`) in `UserDefaults`. A fresh
  install doesn't show it; since the first release with this feature has no
  saved build to compare, treat a finished welcome setup
  (`WelcomeSetup.completedKey`) as the sign of an existing user.
- Bundle the release notes with the app so it works offline: add
  `docs/release-notes/*.md` to the app's resources (the project lists files
  explicitly, so use a folder reference or a copy phase). `scripts/release.sh`
  already requires the notes before it builds. Sparkle's copy is only reachable
  in its callbacks before the relaunch, and misses copies installed with
  `scripts/install-app.sh`.
- Accessibility: label it "What's new in Enigma X". Respect Reduce Motion for
  any appear/disappear animation.

### F8. Syntax highlighting and terminal blocks

Builds on F1's code block header.

- **Syntax highlighting:** keywords, strings, numbers, comments, types and
  variables in different colours that work in both Paper and Ink. The palette
  has no syntax colours yet (only greys, `accentText` and `warning`), so add
  tokens to `EnigmaPalette` and the UI-Style table, covered by
  `EnigmaThemeTests`' contrast checks.
- **Terminal commands** (`bash`, `sh`, `zsh`, `shell`, `console`): styled as
  a terminal block, with commands, flags, paths and variables coloured
  differently.
- **Highlighter choice:** a small built-in tokenizer for the common languages
  (Swift, Python, JavaScript/TypeScript, shell, JSON, HTML/CSS, SQL) is
  probably enough. If a library is used, assess its maintenance, license and
  bundle size first (AGENTS.md), and avoid web-view-based highlighters.
- Streaming: an unfinished fence already renders as code (`ChatMarkdownStream`);
  keep that. While a fence is open its block is parsed again on every
  fragment, so highlight line by line or cache finished lines rather than
  re-highlighting the whole block per token, without flicker or layout jumps.
- F22's draft blocks aren't code and aren't highlighted.

### F9. Edit a sent message, and rewind the chat

**Today:** sent messages are static (`EnigmaUserMessage` in
`EnigmaMessageList.swift`); there's no way to change one or go back.

**Wanted (like ChatGPT and Claude):**

- **Edit:** hover a sent message, click a pencil, change the text and send.
  Everything after that message is replaced by a new reply to the edited one.
- **Rewind:** go back to an earlier point in the chat and continue from there,
  dropping the later messages (with a confirmation, or Undo).
- Optional later: keep the earlier versions as branches ("2 / 3" arrows)
  instead of discarding them, for edits and regenerated replies (F3) alike.
- One truncate-and-resend path serves this and F3. Truncating must also drop
  the removed messages' selection revisions and expanded activity state.
- Edge cases: screenshots and selection context aren't saved and attachments
  are kept by name only, so start with plain chat turns (as F3 does); actions
  already taken (File Mode edits, sent iMessages) can't be undone by
  rewinding, so say so instead of implying they were reversed; disabled while
  a reply is streaming; history saving and temporary chats.

### F10. Temporary chat (ghost mode)

- Works like temporary chat in other chat apps: a tiny ghost button in the
  top-right of the main window starts a temporary chat. It shares F25's slot
  there, which also has to exist while the sidebar is shown.
- In ghost mode the Enigma character wears a silly bedsheet ghost costume with
  eye holes (new drawing in the character renderer). The "Temporary · not
  saved" tag already exists for temporary chats
  (`CompactPanelHints.temporaryTag`); reuse it.
- The private-chat machinery already exists: temporary chats are never
  written to disk, stay out of Recents, and are discarded when you leave them
  (`temporarySessionID`, `isTemporaryChat`, `historySessions`,
  `discardTemporaryChat` in `LocalChatViewModel`), and the Claude Code and
  Codex routes don't keep sessions either. Build on it instead of a second one.
- `startTemporaryChat(context:)` is selection-only: it also sets
  `selectionSessionID`, which turns on selection behaviour such as the
  Accessibility card. Add a variant for ghost mode, and reset the shell and
  panel the way `.newChatRequested` does.
- Private selection chats (B5) open in this same mode.

### F11. Sources as a small expandable icon, not typed out in the reply

**Today:** with web search, the prompt tells the model "Cite only supporting
URLs below" (`WebSearchContext.swift`), so replies often spell out every URL
or end with a list of sources. The sources are already under the reply,
collapsed in its activity line ("Activity · 3 sources",
`AssistantActivityView.swift`), so the reply repeats them and gets long.

**Wanted:**

- The reply text stays clean: no typed-out URLs or source lists. That is
  mostly a prompt change.
- Under the reply, a small sources icon (for example a link or globe glyph
  with a count, "3") that expands to the list: title, site and link, as the
  activity panel shows them now. Collapsed by default. Reuse
  `ActivitySourceRow` and the existing disclosure rather than a second list.
- Optional: small inline markers ([1], [2]) in the text that match the
  expanded list and open the source on click. `searchSources` is already in
  the same order as the excerpts sent to the model, but the excerpts carry no
  number, so add one. Clickable markers mean passing the sources to
  `ChatMarkdownView`, which today gets only the text.
- Change the grounding prompt to cite with those short markers (or not at
  all) instead of URLs, and keep the existing source data
  (`WebSearchSource`, saved per message as `searchSources`) as the list.
- Keep it accessible: the icon has a label such as "3 sources, collapsed".
  Update `docs/Web-Search.md`.

### F12. Bug reporting

- A very short form: what happened, optional steps to reproduce, and optional
  contact email.
- An "Include logs" checkbox, **unchecked by default**. Enigma has almost no
  logs today (a few `NSLog` errors; llama-server and Codex output go to
  `/dev/null`), so first add event-only logging (`os.Logger`) that never
  records chat content or model output. `OSLogStore` only reads the current
  launch, so keep a small rolling log file for earlier ones.
- An "Include this conversation" toggle, **off by default**, to help
  understand what happened. Directly under it, a clear note: "Never turn this
  on if the chat contains anything sensitive, such as passwords, personal or
  financial details, or private messages."
  - Lets the user pick which chat (the current one by default) and shows what
    will be sent before sending.
  - Sends the chat's text only: no attachments, screenshots, file contents,
    selected text or Messages data unless they are already in the visible
    text, and it says so.
  - Not available for temporary chats (F10), which are never saved.
- Adds diagnostics automatically: app version (`AppUpdater.versionText`),
  macOS version, chip and memory, and the active route and model. It never
  includes chat content unless the user turns on "Include this conversation",
  and logs must not contain chat content either.
- Reports go to the owner's email address. Keep it in one place in the app
  (for example an `Info.plist` key), not in this file.
- **Delivery (the easiest option):** open a ready-to-send email in the user's
  mail app with the report filled in (`NSSharingService(named: .composeEmail)`;
  `mailto:` as a fallback). It needs no account, API key, server or new
  dependency. Logs attach only when the mail app supports it (Mail does);
  `mailto:` can't attach, so the fallback puts them in the body or offers
  "Show log in Finder". A silent in-app form service can replace it later if
  wanted.
- Put it in Settings and in the Help sheet (the sidebar's Help button; as a
  menu-bar app, Enigma has no Help menu), and optionally the menu-bar menu.

### F13. Personalization tab in Settings (custom instructions)

- A new **Personalization** tab in Settings, like Claude's and ChatGPT's,
  where people add to the system prompt:
  - "What should Enigma know about you?" (for example "I'm a Swift developer
    on macOS").
  - "How should Enigma respond?" (for example "Answer briefly, use British
    spelling").
  - An on/off switch, so people can pause it without deleting the text.
- Added after the shared Enigma prompt (F5) for every route: local text and
  vision, agent runs, the cloud APIs and the Claude Code / Codex subscriptions.
  It can never replace the built-in safety and tool rules.
- Cap its length (show a character count) and count it in the context budget
  against the model's real context (`LocalModel.contextWindow`: 8,192 for
  catalogue models, 4,096 for imported ones, and changeable with F15), since
  long instructions crowd out chat history.
- Stored locally only, never sent anywhere except as part of a request.
  Temporary chats (F10) still use it.
- The occupation picker (F20) can pre-fill it.

### F14. Settings revamp with an Advanced toggle

- Simpler default view: the active model, connections, and the common toggles.
- An "Advanced" toggle reveals the detailed options, such as Start mode,
  performance checks, catalogue details, local context size (F15) and
  keyboard shortcuts (F16). Fold in the "Advanced" pieces that exist today:
  `AdvancedCloudSettings`, Local models' "Advanced: Import text GGUF…" and the
  main window's "Advanced settings…" menu item. Find a place for F13's tab
  too.
- Do this before F19 and F20 so they have a clear place to link to.

### F15. Local context size (Advanced)

- An Advanced setting for how much conversation the local model can see.
  Catalogue packages run with 8,192 tokens today (`recommendedContextSize`),
  and imported models fall back to 4,096. File Mode clamps to 4,096–16,384 but
  in practice uses the same 8,192.
- **Worth it, with guardrails.** A larger context keeps longer chats and bigger
  pasted text without trimming, but the KV cache grows with it (more memory),
  and long prompts take longer to process. A smaller one saves memory on 8 GB
  Macs.
- Offer a few presets (for example Smaller 4K / Default 8K / Larger 16K /
  Max 32K), limited by the model's trained maximum (a new catalogue field) and
  this Mac's memory. Re-run the memory-fit estimate (`LocalCacheLayout` already
  models the KV cache per model) and warn before applying a size that may not
  fit.
- Make it a runtime override, not a package change: compatibility, memory
  estimates and the install manifest all assume `recommendedContextSize` is
  8,192, and a mismatch makes the installed model ask to Update. Pass the
  chosen size to llama-server's `--ctx-size` and `LocalModel.contextWindow`.
- Benchmarks are matched by context size (`LocalModelSelection`), so
  `LocalModelAdvisor.record` must save the size actually used, not
  `recommendedContextSize`. A new size needs its own performance check, or
  should say the figures are for the default size.
- The llama-server runtime caps context at 32,768 (`LlamaServerVisionEngine`).

### F16. Remappable keyboard shortcuts with collision warnings

- Let people change Enigma's shortcuts: show/hide (⌥⌃), the selection
  shortcut (double-tap Option/Command/Shift, backup ⇧⌥Space) and the in-app
  ones (⌘N, ⌘K, ⌘., ⇧⌘A, ⌃Tab, ⌃⌘S, ⌘O). Keep ⌘, (Settings) and Esc (hide)
  fixed.
- They work three ways today: ⌥⌃ and the selection double-tap are `NSEvent`
  monitors (`PanelShortcutChord`, `SelectionShortcut.swift`), ⇧⌥Space is one
  hard-coded Carbon hot key (`GlobalHotKeyMonitor`), and in-app keys are
  matched by hand in `PanelShortcut.swift`. Their labels are hard-coded in
  several places (`EnigmaMainWindowLogic.swift`, `EnigmaCompactPanelLogic.swift`,
  `EnigmaComposer.swift`); read them all from one shortcut model.
- Warn when a new shortcut collides with another Enigma shortcut, and with
  known macOS ones (Spotlight ⌘Space, input source ⌃Space, Dictation, Mission
  Control). Read system shortcuts with Carbon's `CopySymbolicHotKeys()`
  rather than parsing the `com.apple.symbolichotkeys` preferences. Neither
  lists Dictation's press-twice shortcuts or other modifier-only gestures, so
  keep a short fixed list for those (like `selectionKeyNote`). Other apps'
  global shortcuts cannot be listed reliably, so the warning should say it only
  checks Enigma and macOS.
- Offer "Restore defaults". Put the section in Settings (under Advanced, F14)
  and move the selection-shortcut settings there from the Help sheet.

### F17. Saved prompts and custom slash commands

- Let people define their own commands, such as `/summarize` → "Summarize this
  in three bullet points:", that appear in the completion list next to the
  built-in ones.
- `SlashCommand` is a fixed enum, and completion, highlighting and parsing all
  use it, so custom commands need their own suggestion type, stored
  separately. Simplest: expand the saved text when the suggestion is accepted
  (`accept` in `SlashCommandComposer.swift`), so nothing downstream sees a new
  command.
- Names are letters only (commands are matched as `/[A-Za-z]*`) and must not
  clash with any built-in command, including hidden ones (`/search` is hidden
  without an API key, so check `SlashCommand.allCases`).
- Optional per-command route (Local / Cloud / Auto), which needs more than text
  expansion.

### F18. Browse every quantization in Settings

- Settings → Local models → "All models" already lists every model size,
  including ones that don't fit: in the catalogue a family is one size
  (`familyID` is the display name). What it hides is the other quantizations:
  `LocalModelRecommendations.allFamilies` shows one per size (the
  best-fitting, or the smallest). Let people browse **every** catalogue
  package.
- Keep it behind a "Show all quantizations" disclosure (or the Advanced
  toggle, F14), so the default view stays simple.
- Every row says how it fits this Mac, as a warning on its label:
  - **Too big:** already shown as "Insufficient memory" or "Insufficient disk
    space" with the reason, installable with a warning where the memory
    override allows it (`permitsMemoryOverride`), disabled otherwise. Reuse
    it, at most reworded as "Too large for this Mac".
  - **Too small:** a new "Smaller than this Mac can run, so answers may be
    weaker" warning when a much larger size of the same or a better model line
    runs comfortably here (rank with `rankedQualityScore`, with a set
    threshold for "much larger"). Smaller models get noticeably less capable,
    especially with tools (see F6).
  - Fine fits keep the current labels (Excellent fit, Good fit, May be slow).
- Sort by family then size, and mark the recommended pick so people can find
  their way back.

### F19. Model list revamp

- There is no Explore page: the model lists are Settings → Local models
  ("All models") and setup's model step. Revamp those.
- Add newer models that suit the app better. The catalogue only admits
  image-capable models with an inference profile (`LocalModelSelection`), so
  text-only models, such as many coding models, need that rule changed first.
- Group models by what they are good for (coding, writing, everyday use,
  studying, documents and research) instead of only by size and fit.
- Tag catalogue entries with these use cases (a new field on
  `LocalModelFamily` and in the signed catalogue), and add the step to
  `docs/Updating-the-Model-Catalogue.md`. F20 needs the tags.

### F20. Welcome page asks your occupation

- A setup step asks what you do, then suggests models for it. Setup saves its
  progress as a step number (`WelcomeSetup`), so inserting a step would resume
  people at the wrong one; migrate the saved value.
- Choices: **Programmer, Writer, General user, Student, Researcher/Analyst**.
  - Student leans toward fast, light models for explanations and studying.
  - Researcher/Analyst leans toward long-context models for summarising
    documents. Every package runs at 8,192 tokens today, so this needs F15.
- Occupation picks the use-case tags (F19); hardware fit then narrows the
  list, as the recommendations do today (`LocalModelSelector.select`,
  `WelcomeSetup.choices`). Say how it combines with the three recommendation
  roles. It can also pre-fill custom instructions (F13).

### F21. Voice dictation

- A microphone button in the composer using on-device speech recognition, so
  audio never leaves the Mac. On macOS 26, use `SpeechAnalyzer` with
  `SpeechTranscriber` (on-device; its model downloads through
  `AssetInventory`), falling back to `DictationTranscriber` where it isn't
  available, rather than the older `SFSpeechRecognizer`.
- Needs a microphone usage string in `Info.plist` (and a speech-recognition
  one if the API asks for it) and the `com.apple.security.device.audio-input`
  entitlement, which the hardened runtime requires. Add a Microphone row to
  `MacPermissionRows` and handle denied permission like the existing rows.
- If dictation gets a shortcut, don't use a double-tapped modifier: macOS
  Dictation already uses those, which is why the selection shortcut's
  double-tap Command option warns about it.

### F22. Draft blocks and in-place editing

Builds on F1's copy buttons.

- **Standalone drafts** (emails, cover letters, posts): when the reply
  contains a standalone draft, show the draft in a document-style block with
  its own Copy icon, so the user copies just the piece and not the surrounding
  chat. Ask the model (in `ChatResponseStyle.instructions`) to put such drafts
  in a dedicated fence such as ```` ```draft ```` so they can be found
  reliably. Not ```` ```text ````: models use it for logs and file trees, and
  F1 and F8 draw it as code. Fenced text isn't rendered as Markdown. `/edit`
  already parses a structured block and hides it while streaming
  (`<enigma-revision>` in `ConversationContext.swift`); follow that.
- **Edit the draft in place:** next to Copy, a pencil icon turns the
  document block into an editor (like ChatGPT's canvas-style editing). The
  user changes the text directly, then **Save** or **Cancel**. Saved edits
  replace the draft in that reply (rewrite the fence in the saved message,
  lengthening it if the text contains ```` ``` ````), are kept in history (not
  for temporary chats), and are what the model sees in later turns, so "make
  it shorter" works on the edited version. Copy then copies the edited text.
  The selection revision card's editor (`SelectionCards.swift`) saves on every
  keystroke with no Save or Cancel, and its text isn't kept, so reuse only its
  look.

### F23. Better, more complete tour

- The tour has 6 steps today (`WelcomeTourStep`: history, composer, commands,
  files, model, help).
- Add the missing features: selection, temporary chat (ghost mode), screen,
  Messages and web search, plus whatever of the features above has shipped
  (copy and editing, regenerate and rewind, drag and drop, personalization,
  shortcuts, saved prompts, dictation and so on). Selection is a global
  shortcut with nothing on screen to point at, so it needs a step without a
  target (`welcomeTourTarget`).
- Do this after the features above, since they change what the tour should
  show.

### F24. Maps integration (later)

- Eventually: answer place and direction questions with Apple Maps, for
  example nearby search, travel times and "open in Maps".
- MapKit (`MKLocalSearch`, `MKDirections`) needs no API key, and
  `LocationService` already uses MapKit for the approximate location web
  search uses. Keep location rounded and unsaved as it is now; the rounding
  makes travel times approximate. Requests go to Apple, so say so in the docs.
- Likely a new tool or slash command (`/maps`), with the same small-model
  caveat as F6.
